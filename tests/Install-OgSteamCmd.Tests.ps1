# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force

    function New-FakeSteamCmd {
        param([string] $Directory)
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        $exe = Join-Path $Directory 'steamcmd.exe'
        Set-Content -LiteralPath $exe -Value 'fake'
        $exe
    }
}

Describe 'steamcmd resolver and installer' {

    BeforeEach {
        $script:savedLocalAppData = $env:LOCALAPPDATA
        $script:savedOgSteamCmd   = $env:OG_STEAMCMD
        $script:sandbox           = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:LOCALAPPDATA         = Join-Path $sandbox 'local app data'
        $env:OG_STEAMCMD          = $null
        $script:defaultDir        = Join-Path $env:LOCALAPPDATA 'og-tools\steamcmd'
        $script:defaultExe        = Join-Path $defaultDir 'steamcmd.exe'

        Mock -ModuleName og-framework -CommandName Get-Command -ParameterFilter { $Name -eq 'steamcmd.exe' } -MockWith { }
        Mock -ModuleName og-framework -CommandName Invoke-WebRequest -MockWith {
            Set-Content -LiteralPath $OutFile -Value 'zip'
        }
        Mock -ModuleName og-framework -CommandName Expand-Archive -MockWith {
            Set-Content -LiteralPath (Join-Path $DestinationPath 'steamcmd.exe') -Value 'extracted'
        }
        Mock -ModuleName og-framework -CommandName Invoke-OgProcess -MockWith {
            [pscustomobject]@{ ExitCode = 0; LogPath = $null; Duration = [timespan]::FromSeconds(1) }
        }
    }

    AfterEach {
        $env:LOCALAPPDATA = $savedLocalAppData
        $env:OG_STEAMCMD  = $savedOgSteamCmd
    }

    Context 'Resolve-OgSteamCmd resolution order' {

        It 'prefers -Path over $env:OG_STEAMCMD, the default install and PATH' {
            $explicit = New-FakeSteamCmd (Join-Path $sandbox 'explicit')
            $env:OG_STEAMCMD = New-FakeSteamCmd (Join-Path $sandbox 'env')
            New-FakeSteamCmd $defaultDir | Out-Null
            $onPath = New-FakeSteamCmd (Join-Path $sandbox 'path')
            Mock -ModuleName og-framework -CommandName Get-Command -ParameterFilter { $Name -eq 'steamcmd.exe' } -MockWith { [pscustomobject]@{ Source = $onPath } }

            InModuleScope og-framework -Parameters @{ P = $explicit } { Resolve-OgSteamCmd -Path $P } | Should -Be $explicit
        }

        It 'uses $env:OG_STEAMCMD before the default install and PATH' {
            $env:OG_STEAMCMD = New-FakeSteamCmd (Join-Path $sandbox 'env')
            New-FakeSteamCmd $defaultDir | Out-Null
            $onPath = New-FakeSteamCmd (Join-Path $sandbox 'path')
            Mock -ModuleName og-framework -CommandName Get-Command -ParameterFilter { $Name -eq 'steamcmd.exe' } -MockWith { [pscustomobject]@{ Source = $onPath } }

            InModuleScope og-framework { Resolve-OgSteamCmd } | Should -Be $env:OG_STEAMCMD
        }

        It 'uses the default install location before PATH' {
            New-FakeSteamCmd $defaultDir | Out-Null
            $onPath = New-FakeSteamCmd (Join-Path $sandbox 'path')
            Mock -ModuleName og-framework -CommandName Get-Command -ParameterFilter { $Name -eq 'steamcmd.exe' } -MockWith { [pscustomobject]@{ Source = $onPath } }

            InModuleScope og-framework { Resolve-OgSteamCmd } | Should -Be $defaultExe
        }

        It 'falls back to steamcmd.exe on PATH' {
            $onPath = New-FakeSteamCmd (Join-Path $sandbox 'path')
            Mock -ModuleName og-framework -CommandName Get-Command -ParameterFilter { $Name -eq 'steamcmd.exe' } -MockWith { [pscustomobject]@{ Source = $onPath } }

            InModuleScope og-framework { Resolve-OgSteamCmd } | Should -Be $onPath
        }

        It 'accepts a folder for <Source>' -TestCases @(
            @{ Source = 'Path' }
            @{ Source = 'Env' }
        ) {
            param($Source)
            $dir = Join-Path $sandbox 'folder form'
            $exe = New-FakeSteamCmd $dir
            if ($Source -eq 'Env') {
                $env:OG_STEAMCMD = $dir
                InModuleScope og-framework { Resolve-OgSteamCmd } | Should -Be $exe
            }
            else {
                InModuleScope og-framework -Parameters @{ P = $dir } { Resolve-OgSteamCmd -Path $P } | Should -Be $exe
            }
        }

        It 'throws for a missing -Path instead of falling back' {
            New-FakeSteamCmd $defaultDir | Out-Null
            $missing = Join-Path $sandbox 'nope\steamcmd.exe'
            { InModuleScope og-framework -Parameters @{ P = $missing } { Resolve-OgSteamCmd -Path $P } } |
                Should -Throw "*-Path = '$missing'*does not exist*"
        }

        It 'throws for a missing $env:OG_STEAMCMD instead of falling back' {
            New-FakeSteamCmd $defaultDir | Out-Null
            $env:OG_STEAMCMD = Join-Path $sandbox 'nope\steamcmd.exe'
            { InModuleScope og-framework { Resolve-OgSteamCmd } } |
                Should -Throw '*$env:OG_STEAMCMD*does not exist*'
        }

        It 'throws naming Install-OgSteamCmd and every location tried when steamcmd is nowhere' {
            $err = { InModuleScope og-framework { Resolve-OgSteamCmd } } | Should -Throw -PassThru
            $err.Exception.Message | Should -BeLike '*Run Install-OgSteamCmd*'
            $err.Exception.Message | Should -BeLike "*$defaultExe*"
            $err.Exception.Message | Should -BeLike '*steamcmd.exe on PATH*'
        }
    }

    Context 'Install-OgSteamCmd' {

        It 'downloads Valve''s steamcmd.zip, extracts it, deletes the zip, bootstraps with +quit and returns the exe' {
            $dest = Join-Path $sandbox 'install dir'
            $r = InModuleScope og-framework -Parameters @{ D = $dest } { Install-OgSteamCmd -Destination $D }
            $exe = Join-Path $dest 'steamcmd.exe'

            $r | Should -Be $exe
            Should -Invoke -ModuleName og-framework -CommandName Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://client-update.steamstatic.com/installer/steamcmd.zip' -and $OutFile -eq (Join-Path $dest 'steamcmd.zip')
            }
            Should -Invoke -ModuleName og-framework -CommandName Expand-Archive -Times 1 -Exactly -ParameterFilter {
                $LiteralPath -eq (Join-Path $dest 'steamcmd.zip') -and $DestinationPath -eq $dest
            }
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq $exe -and (($ArgumentList -join ' ') -ceq '+quit') -and $WorkingDirectory -eq $dest -and -not $LogPath
            }
            Join-Path $dest 'steamcmd.zip' | Should -Not -Exist
        }

        It 'installs to the location Resolve-OgSteamCmd checks by default' {
            $r = InModuleScope og-framework { Install-OgSteamCmd }
            $r | Should -Be $defaultExe
            InModuleScope og-framework { Resolve-OgSteamCmd } | Should -Be $defaultExe
        }

        It 'is idempotent: an existing steamcmd.exe without -Force downloads and runs nothing' {
            $dest = Join-Path $sandbox 'installed'
            $exe  = New-FakeSteamCmd $dest

            InModuleScope og-framework -Parameters @{ D = $dest } { Install-OgSteamCmd -Destination $D } | Should -Be $exe
            Should -Invoke -ModuleName og-framework -CommandName Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Expand-Archive   -Times 0 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 0 -Exactly
            Get-Content -LiteralPath $exe | Should -Be 'fake'
        }

        It '-Force downloads, extracts and bootstraps again over an existing install' {
            $dest = Join-Path $sandbox 'installed'
            $exe  = New-FakeSteamCmd $dest

            InModuleScope og-framework -Parameters @{ D = $dest } { Install-OgSteamCmd -Destination $D -Force } | Should -Be $exe
            Should -Invoke -ModuleName og-framework -CommandName Invoke-WebRequest -Times 1 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Expand-Archive   -Times 1 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly
            Get-Content -LiteralPath $exe | Should -Be 'extracted'
        }

        It 'runs +quit a second time when the self-update run exits non-zero' {
            $script:bootstrapCalls = 0
            Mock -ModuleName og-framework -CommandName Invoke-OgProcess -MockWith {
                $script:bootstrapCalls++
                [pscustomobject]@{ ExitCode = $(if ($script:bootstrapCalls -eq 1) { 7 } else { 0 }); LogPath = $null; Duration = [timespan]::Zero }
            }
            $dest = Join-Path $sandbox 'retry'
            InModuleScope og-framework -Parameters @{ D = $dest } { Install-OgSteamCmd -Destination $D } | Should -Be (Join-Path $dest 'steamcmd.exe')
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 2 -Exactly
        }

        It 'throws when both bootstrap runs exit non-zero' {
            Mock -ModuleName og-framework -CommandName Invoke-OgProcess -MockWith {
                [pscustomobject]@{ ExitCode = 3; LogPath = $null; Duration = [timespan]::Zero }
            }
            $dest = Join-Path $sandbox 'broken'
            { InModuleScope og-framework -Parameters @{ D = $dest } { Install-OgSteamCmd -Destination $D } } |
                Should -Throw '*exited 3 twice*'
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 2 -Exactly
        }

        It 'throws when the archive does not contain steamcmd.exe, without running anything' {
            Mock -ModuleName og-framework -CommandName Expand-Archive -MockWith { }
            $dest = Join-Path $sandbox 'empty zip'
            { InModuleScope og-framework -Parameters @{ D = $dest } { Install-OgSteamCmd -Destination $D } } |
                Should -Throw '*did not contain steamcmd.exe*'
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 0 -Exactly
            Join-Path $dest 'steamcmd.zip' | Should -Not -Exist
        }

        It 'wraps a download failure and leaves no zip behind' {
            Mock -ModuleName og-framework -CommandName Invoke-WebRequest -MockWith {
                Set-Content -LiteralPath $OutFile -Value 'partial'
                throw 'network down'
            }
            $dest = Join-Path $sandbox 'offline'
            { InModuleScope og-framework -Parameters @{ D = $dest } { Install-OgSteamCmd -Destination $D } } |
                Should -Throw '*download of https://client-update.steamstatic.com/installer/steamcmd.zip failed: network down*'
            Should -Invoke -ModuleName og-framework -CommandName Expand-Archive -Times 0 -Exactly
            Join-Path $dest 'steamcmd.zip' | Should -Not -Exist
        }
    }
}
