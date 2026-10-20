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
        Set-Content -LiteralPath (Join-Path $batchDir 'Build.bat') -Value '@exit /b 99'
        $Root
    }

    function New-FakeProject {
        param([string] $Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $path = Join-Path $Root 'Arena.uproject'
        Set-Content -LiteralPath $path -Value (@{ FileVersion = 3; EngineAssociation = '{11111111-2222-3333-4444-555555555555}' } | ConvertTo-Json)
        $path
    }
}

Describe 'Invoke-OgUnrealBuild' {

    BeforeAll {
        $script:engine  = New-FakeEngine (Join-Path $TestDrive 'Engine Root')
        $script:project = New-FakeProject (Join-Path $TestDrive 'proj dir')
        $script:buildBat = Join-Path $engine 'Engine\Build\BatchFiles\Build.bat'
    }

    BeforeEach {
        Mock -ModuleName og-framework -CommandName Get-Process -MockWith { }
        Mock -ModuleName og-framework -CommandName Invoke-OgProcess -MockWith {
            [pscustomobject]@{ ExitCode = 0; LogPath = $LogPath; Duration = [timespan]::FromSeconds(2) }
        }
    }

    It 'builds <Project>Editor Win64 Development with -NoHotReload by default' {
        $r = Invoke-OgUnrealBuild -ProjectFile $project -EngineRoot $engine
        $expected = @('ArenaEditor', 'Win64', 'Development', "-Project=$project", '-WaitMutex', '-FromMsBuild', '-NoHotReload')
        Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $buildBat -and (($ArgumentList -join "`n") -ceq ($expected -join "`n")) -and $WorkingDirectory -eq $engine
        }
        $r.Target | Should -Be 'ArenaEditor'
        $r.ExitCode | Should -Be 0
    }

    It 'expands the shorthands <Short> to <Full>' -TestCases @(
        @{ Short = 'Game';   Full = 'Arena' }
        @{ Short = 'Client'; Full = 'ArenaClient' }
        @{ Short = 'Server'; Full = 'ArenaServer' }
    ) {
        param($Short, $Full)
        Invoke-OgUnrealBuild -ProjectFile $project -EngineRoot $engine -Target $Short -Configuration Shipping | Out-Null
        Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -ceq $Full -and $ArgumentList[2] -eq 'Shipping' -and -not ($ArgumentList -contains '-NoHotReload')
        }
    }

    It 'passes other target names verbatim and builds them in order' {
        $r = Invoke-OgUnrealBuild -ProjectFile $project -EngineRoot $engine -Target Editor, OGSimulationTests, OGBrawlerTests
        ($r.Target -join ',') | Should -Be 'ArenaEditor,OGSimulationTests,OGBrawlerTests'
        Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 3 -Exactly
        Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'OGSimulationTests' -and -not ($ArgumentList -contains '-NoHotReload')
        }
    }

    It 'tees each target to Saved\Logs\og_build_<Target>_<Configuration>_yyyyMMdd-HHmmss.log by default' {
        $r = Invoke-OgUnrealBuild -ProjectFile $project -EngineRoot $engine
        $logDir = Join-Path (Split-Path -Parent $project) 'Saved\Logs'
        $r.LogPath | Should -Match ('^' + [regex]::Escape($logDir) + '\\og_build_ArenaEditor_Development_\d{8}-\d{6}\.log$')
    }

    It 'stops at the first failing target and throws with the log path' {
        Mock -ModuleName og-framework -CommandName Invoke-OgProcess -MockWith {
            [pscustomobject]@{ ExitCode = 6; LogPath = $LogPath; Duration = [timespan]::Zero }
        }
        { Invoke-OgUnrealBuild -ProjectFile $project -EngineRoot $engine -Target Editor, OGSimulationTests } |
            Should -Throw '*building ArenaEditor failed with exit code 6*'
        Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly
    }

    It 'refuses an Editor target while UnrealEditor runs' {
        Mock -ModuleName og-framework -CommandName Get-Process -MockWith { [pscustomobject]@{ Id = 4242 } }
        { Invoke-OgUnrealBuild -ProjectFile $project -EngineRoot $engine } | Should -Throw '*UnrealEditor is running (PID 4242)*'
        Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 0 -Exactly
    }

    It 'builds a non-Editor target while UnrealEditor runs' {
        Mock -ModuleName og-framework -CommandName Get-Process -MockWith { [pscustomobject]@{ Id = 4242 } }
        Invoke-OgUnrealBuild -ProjectFile $project -EngineRoot $engine -Target OGSimulationTests | Out-Null
        Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly
    }

    It 'builds an Editor target while UnrealEditor runs with -Force' {
        Mock -ModuleName og-framework -CommandName Get-Process -MockWith { [pscustomobject]@{ Id = 4242 } }
        Invoke-OgUnrealBuild -ProjectFile $project -EngineRoot $engine -Force | Out-Null
        Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly
    }

    It 'runs nothing under -WhatIf' {
        Invoke-OgUnrealBuild -ProjectFile $project -EngineRoot $engine -WhatIf | Should -BeNullOrEmpty
        Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 0 -Exactly
    }

    It 'finds the single .uproject in the current directory' {
        Push-Location (Split-Path -Parent $project)
        try { Invoke-OgUnrealBuild -EngineRoot $engine | Out-Null } finally { Pop-Location }
        Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[3] -eq "-Project=$project"
        }
    }

    It 'fails clearly when the current directory has no .uproject' {
        Push-Location $TestDrive
        try { { Invoke-OgUnrealBuild -EngineRoot $engine } | Should -Throw '*found 0 .uproject files*' } finally { Pop-Location }
    }
}
