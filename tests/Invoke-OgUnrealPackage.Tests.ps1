# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force

    function New-FakeEngine {
        param([string] $Root)
        $batchDir = Join-Path $Root 'Engine\Build\BatchFiles'
        New-Item -ItemType Directory -Path $batchDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $batchDir 'RunUAT.bat') -Value '@exit /b 99'
        $Root
    }

    function New-FakeProject {
        param([string] $Root, [string] $Association)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $path = Join-Path $Root 'Game.uproject'
        Set-Content -LiteralPath $path -Value (@{ FileVersion = 3; EngineAssociation = $Association } | ConvertTo-Json)
        $path
    }
}

Describe 'Invoke-OgUnrealPackage' {

    BeforeAll {
        $script:engine  = New-FakeEngine (Join-Path $TestDrive 'Engine Root')
        $script:project = New-FakeProject (Join-Path $TestDrive 'proj dir') '{11111111-2222-3333-4444-555555555555}'
        $script:archive = Join-Path $TestDrive 'out\client-depot'
    }

    BeforeEach {
        Mock -ModuleName og-framework -CommandName Get-Process -MockWith { }
        Mock -ModuleName og-framework -CommandName Invoke-OgProcess -MockWith {
            [pscustomobject]@{ ExitCode = 0; LogPath = $LogPath; Duration = [timespan]::FromSeconds(3) }
        }
    }

    Context 'UAT argument list' {
        It 'passes the exact BuildCookRun arguments for <TargetType>' -TestCases @(
            @{ TargetType = 'Client'; Configuration = 'Shipping';    TypeArgs = @('-client', '-clientconfig=Shipping', '-targetplatform=Win64') }
            @{ TargetType = 'Server'; Configuration = 'Development'; TypeArgs = @('-server', '-serverconfig=Development', '-serverplatform=Win64', '-noclient') }
            @{ TargetType = 'Game';   Configuration = 'Development'; TypeArgs = @('-clientconfig=Development', '-targetplatform=Win64') }
        ) {
            param($TargetType, $Configuration, $TypeArgs)
            InModuleScope og-framework -Parameters @{ P = $project; A = $archive; E = $engine; T = $TargetType; C = $Configuration } {
                Invoke-OgUnrealPackage -ProjectFile $P -TargetType $T -Configuration $C -ArchiveDirectory $A -EngineRoot $E | Out-Null
            }
            $expected = @('BuildCookRun', "-project=$project") + $TypeArgs + @(
                '-build', '-cook', '-stage', '-package', '-pak',
                '-archive', "-archivedirectory=$archive",
                '-unattended', '-nop4', '-utf8output'
            )
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq (Join-Path $engine 'Engine\Build\BatchFiles\RunUAT.bat') -and
                (($ArgumentList -join "`n") -ceq ($expected -join "`n"))
            }
        }

        It 'tees to the project Saved\Logs folder as og_package_Server_Shipping_yyyyMMdd-HHmmss.log by default' {
            $r = InModuleScope og-framework -Parameters @{ P = $project; A = $archive; E = $engine } {
                Invoke-OgUnrealPackage -ProjectFile $P -TargetType Server -Configuration Shipping -ArchiveDirectory $A -EngineRoot $E
            }
            $logDir = Join-Path (Split-Path -Parent $project) 'Saved\Logs'
            $r.LogPath | Should -Match ('^' + [regex]::Escape($logDir) + '\\og_package_Server_Shipping_\d{8}-\d{6}\.log$')
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly -ParameterFilter { $LogPath -eq $r.LogPath }
        }

        It 'honours -LogDirectory' {
            $logDir = Join-Path $TestDrive 'custom logs'
            $r = InModuleScope og-framework -Parameters @{ P = $project; A = $archive; E = $engine; L = $logDir } {
                Invoke-OgUnrealPackage -ProjectFile $P -TargetType Client -Configuration Shipping -ArchiveDirectory $A -EngineRoot $E -LogDirectory $L
            }
            Split-Path -Parent $r.LogPath | Should -Be $logDir
        }
    }

    Context 'S5: UnrealEditor running' {
        It 'throws before invoking UAT when an UnrealEditor process exists' {
            Mock -ModuleName og-framework -CommandName Get-Process -ParameterFilter { $Name -eq 'UnrealEditor' } -MockWith {
                [pscustomobject]@{ Id = 4242; ProcessName = 'UnrealEditor' }
            }
            {
                InModuleScope og-framework -Parameters @{ P = $project; A = $archive; E = $engine } {
                    Invoke-OgUnrealPackage -ProjectFile $P -TargetType Client -Configuration Shipping -ArchiveDirectory $A -EngineRoot $E
                }
            } | Should -Throw '*UnrealEditor is running (PID 4242)*'
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 0 -Exactly
        }
    }

    Context 'UAT failure and result validation' {
        It 'throws with the exit code and the log path when UAT exits non-zero' {
            Mock -ModuleName og-framework -CommandName Invoke-OgProcess -MockWith {
                [pscustomobject]@{ ExitCode = 25; LogPath = $LogPath; Duration = [timespan]::Zero }
            }
            $err = $null
            try {
                InModuleScope og-framework -Parameters @{ P = $project; A = $archive; E = $engine } {
                    Invoke-OgUnrealPackage -ProjectFile $P -TargetType Client -Configuration Shipping -ArchiveDirectory $A -EngineRoot $E
                }
            }
            catch { $err = $_.Exception.Message }
            $err | Should -Match 'exit code 25'
            $err | Should -Match 'Log: .*og_package_Client_Shipping_\d{8}-\d{6}\.log'
        }

        It 'throws when -ExpectedExecutable is absent from ContentRoot' {
            {
                InModuleScope og-framework -Parameters @{ P = $project; A = $archive; E = $engine } {
                    Invoke-OgUnrealPackage -ProjectFile $P -TargetType Client -Configuration Shipping -ArchiveDirectory $A -EngineRoot $E -ExpectedExecutable 'GameClient.exe'
                }
            } | Should -Throw "*expected executable '$(Join-Path $archive 'WindowsClient\GameClient.exe')' does not exist*"
        }

        It 'returns the result object when -ExpectedExecutable exists' {
            $archiveOk = Join-Path $TestDrive 'out\server-depot'
            New-Item -ItemType Directory -Path (Join-Path $archiveOk 'WindowsServer') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $archiveOk 'WindowsServer\GameServer.exe') -Value 'x'
            $r = InModuleScope og-framework -Parameters @{ P = $project; A = $archiveOk; E = $engine } {
                Invoke-OgUnrealPackage -ProjectFile $P -TargetType Server -Configuration Development -ArchiveDirectory $A -EngineRoot $E -ExpectedExecutable 'GameServer.exe'
            }
            $r.ContentRoot      | Should -Be (Join-Path $archiveOk 'WindowsServer')
            $r.ArchiveDirectory | Should -Be $archiveOk
            $r.ExitCode         | Should -Be 0
            $r.Duration         | Should -BeOfType [timespan]
            $r.Duration         | Should -Be ([timespan]::FromSeconds(3))
        }

        It 'rejects a rooted -ExpectedExecutable' {
            {
                InModuleScope og-framework -Parameters @{ P = $project; A = $archive; E = $engine } {
                    Invoke-OgUnrealPackage -ProjectFile $P -TargetType Client -Configuration Shipping -ArchiveDirectory $A -EngineRoot $E -ExpectedExecutable 'C:\x.exe'
                }
            } | Should -Throw '*ExpectedExecutable*'
        }

        It 'throws when the project file does not exist' {
            {
                InModuleScope og-framework -Parameters @{ A = $archive; E = $engine; P = (Join-Path $TestDrive 'missing\Nope.uproject') } {
                    Invoke-OgUnrealPackage -ProjectFile $P -TargetType Client -Configuration Shipping -ArchiveDirectory $A -EngineRoot $E
                }
            } | Should -Throw '*does not exist*'
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 0 -Exactly
        }
    }

    Context 'ContentRoot mapping' {
        It 'maps <TargetType> to <Folder>' -TestCases @(
            @{ TargetType = 'Client'; Folder = 'WindowsClient' }
            @{ TargetType = 'Server'; Folder = 'WindowsServer' }
            @{ TargetType = 'Game';   Folder = 'Windows' }
        ) {
            param($TargetType, $Folder)
            $r = InModuleScope og-framework -Parameters @{ P = $project; A = $archive; E = $engine; T = $TargetType } {
                Invoke-OgUnrealPackage -ProjectFile $P -TargetType $T -Configuration Development -ArchiveDirectory $A -EngineRoot $E
            }
            $r.ContentRoot | Should -Be (Join-Path $archive $Folder)
        }

        It 'uses ArchiveDirectory itself when a component starts with the cook platform or Win64 (UAT does not append)' -TestCases @(
            @{ TargetType = 'Client'; Sub = 'WindowsClient' }
            @{ TargetType = 'Server'; Sub = 'win64-server' }
        ) {
            param($TargetType, $Sub)
            $a = Join-Path $TestDrive "out\$Sub"
            $r = InModuleScope og-framework -Parameters @{ P = $project; A = $a; E = $engine; T = $TargetType } {
                Invoke-OgUnrealPackage -ProjectFile $P -TargetType $T -Configuration Development -ArchiveDirectory $A -EngineRoot $E
            }
            $r.ContentRoot | Should -Be $a
        }
    }
}

Describe 'Resolve-OgUnrealEngineRoot' {

    BeforeAll {
        $script:explicitEngine = New-FakeEngine (Join-Path $TestDrive 'explicit engine')
        $script:guidEngine     = New-FakeEngine (Join-Path $TestDrive 'guid engine')
        $script:versionEngine  = New-FakeEngine (Join-Path $TestDrive 'version engine')
        $script:guid           = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'
        $script:guidProject    = New-FakeProject (Join-Path $TestDrive 'p-guid') $guid
        $script:versionProject = New-FakeProject (Join-Path $TestDrive 'p-ver') '5.6'
        $script:badProject     = New-FakeProject (Join-Path $TestDrive 'p-bad') 'MyCustomEngine'
        $script:emptyProject   = New-FakeProject (Join-Path $TestDrive 'p-empty') ''
    }

    BeforeEach {
        $g = $guid; $ge = $guidEngine.Replace('\', '/'); $ve = $versionEngine
        Mock -ModuleName og-framework -CommandName Get-ItemProperty -ParameterFilter {
            $LiteralPath -eq 'HKCU:\Software\Epic Games\Unreal Engine\Builds'
        } -MockWith { [pscustomobject]@{ $g = $ge } }.GetNewClosure()
        Mock -ModuleName og-framework -CommandName Get-ItemProperty -ParameterFilter {
            $LiteralPath -eq 'HKLM:\SOFTWARE\EpicGames\Unreal Engine\5.6'
        } -MockWith { [pscustomobject]@{ InstalledDirectory = $ve } }.GetNewClosure()
        Mock -ModuleName og-framework -CommandName Get-ItemProperty -MockWith { }
    }

    It '1. explicit -EngineRoot wins and the registry is not read' {
        $r = InModuleScope og-framework -Parameters @{ P = $guidProject; E = $explicitEngine } {
            Resolve-OgUnrealEngineRoot -ProjectFile $P -EngineRoot $E
        }
        $r | Should -Be $explicitEngine
        Should -Invoke -ModuleName og-framework -CommandName Get-ItemProperty -Times 0 -Exactly
    }

    It '1. explicit -EngineRoot without RunUAT.bat throws and does not fall back to the registry' {
        {
            InModuleScope og-framework -Parameters @{ P = $guidProject; E = (Join-Path $TestDrive 'not-an-engine') } {
                Resolve-OgUnrealEngineRoot -ProjectFile $P -EngineRoot $E
            }
        } | Should -Throw '*explicit -EngineRoot*does not contain Engine\Build\BatchFiles\RunUAT.bat*'
        Should -Invoke -ModuleName og-framework -CommandName Get-ItemProperty -Times 0 -Exactly
    }

    It '2. a {GUID} association resolves through HKCU Builds (forward slashes normalised)' {
        $r = InModuleScope og-framework -Parameters @{ P = $guidProject } {
            Resolve-OgUnrealEngineRoot -ProjectFile $P
        }
        $r | Should -Be $guidEngine
        Should -Invoke -ModuleName og-framework -CommandName Get-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq 'HKCU:\Software\Epic Games\Unreal Engine\Builds'
        }
    }

    It '3. a version association resolves through HKLM InstalledDirectory' {
        $r = InModuleScope og-framework -Parameters @{ P = $versionProject } {
            Resolve-OgUnrealEngineRoot -ProjectFile $P
        }
        $r | Should -Be $versionEngine
        Should -Invoke -ModuleName og-framework -CommandName Get-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq 'HKLM:\SOFTWARE\EpicGames\Unreal Engine\5.6'
        }
    }

    It '4. an unregistered GUID throws naming the registry key and value tried' {
        $other = New-FakeProject (Join-Path $TestDrive 'p-other') '{00000000-0000-0000-0000-000000000000}'
        {
            InModuleScope og-framework -Parameters @{ P = $other } { Resolve-OgUnrealEngineRoot -ProjectFile $P }
        } | Should -Throw "*registry 'HKCU:\Software\Epic Games\Unreal Engine\Builds' value '{00000000-0000-0000-0000-000000000000}' not found*"
    }

    It '4. an unregistered version throws naming the registry key tried' {
        $other = New-FakeProject (Join-Path $TestDrive 'p-v9') '9.9'
        {
            InModuleScope og-framework -Parameters @{ P = $other } { Resolve-OgUnrealEngineRoot -ProjectFile $P }
        } | Should -Throw "*HKLM:\SOFTWARE\EpicGames\Unreal Engine\9.9*InstalledDirectory*not found*"
    }

    It '4. a registry entry that lacks RunUAT.bat throws naming the resolved path' {
        Mock -ModuleName og-framework -CommandName Get-ItemProperty -ParameterFilter {
            $LiteralPath -eq 'HKLM:\SOFTWARE\EpicGames\Unreal Engine\5.6'
        } -MockWith { [pscustomobject]@{ InstalledDirectory = 'C:\definitely\not\an\engine' } }
        {
            InModuleScope og-framework -Parameters @{ P = $versionProject } { Resolve-OgUnrealEngineRoot -ProjectFile $P }
        } | Should -Throw "*'C:\definitely\not\an\engine', which does not contain*"
    }

    It '4. an unrecognised association throws' {
        {
            InModuleScope og-framework -Parameters @{ P = $badProject } { Resolve-OgUnrealEngineRoot -ProjectFile $P }
        } | Should -Throw "*EngineAssociation 'MyCustomEngine'*neither a {GUID} nor a version*"
    }

    It '4. an empty association throws' {
        {
            InModuleScope og-framework -Parameters @{ P = $emptyProject } { Resolve-OgUnrealEngineRoot -ProjectFile $P }
        } | Should -Throw '*has no EngineAssociation*'
    }
}

Describe 'Invoke-OgProcess' {

    BeforeAll {
        $script:bat = Join-Path $TestDrive 'fake tool.bat'
        Set-Content -LiteralPath $bat -Value "@echo off`r`necho out [%~1]`r`necho err line 1>&2`r`nexit /b 7"
    }

    It 'tees merged output to -LogPath, keeps it off the pipeline and returns the exit code' {
        $log = Join-Path $TestDrive 'logs dir\tool.log'
        $out = InModuleScope og-framework -Parameters @{ B = $bat; L = $log } {
            Invoke-OgProcess -FilePath $B -ArgumentList '-project=C:\a b\c.uproject' -LogPath $L 6>$null
        }
        @($out).Count     | Should -Be 1
        $out.ExitCode     | Should -Be 7
        $out.LogPath      | Should -Be $log
        $out.Duration     | Should -BeOfType [timespan]
        $lines = Get-Content -LiteralPath $log
        $lines            | Should -Contain 'out [-project=C:\a b\c.uproject]'
        ($lines -join '|') | Should -Match 'err line'
    }

    It 'returns the exit code with no log when run attached to the console' {
        $out = InModuleScope og-framework -Parameters @{ B = $bat } {
            Invoke-OgProcess -FilePath $B -ArgumentList 'x'
        }
        $out.ExitCode | Should -Be 7
        $out.LogPath  | Should -BeNullOrEmpty
    }
}
