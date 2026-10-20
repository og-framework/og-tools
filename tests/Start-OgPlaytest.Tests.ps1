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
        $binDir = Join-Path $Root 'Engine\Binaries\Win64'
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $binDir 'UnrealEditor.exe') -Value 'fake'
        $Root
    }

    function New-FakeProject {
        param([string] $Root, [string] $DefaultMap = '/Game/Maps/Arena.Arena')
        New-Item -ItemType Directory -Path (Join-Path $Root 'Config') -Force | Out-Null
        $path = Join-Path $Root 'Arena.uproject'
        Set-Content -LiteralPath $path -Value (@{ FileVersion = 3; EngineAssociation = '{11111111-2222-3333-4444-555555555555}' } | ConvertTo-Json)
        if ($DefaultMap) {
            Set-Content -LiteralPath (Join-Path $Root 'Config\DefaultEngine.ini') -Value @(
                '[/Script/EngineSettings.GameMapsSettings]', "GameDefaultMap=$DefaultMap", 'EditorStartupMap=/Game/Other.Other')
        }
        $path
    }
}

Describe 'Start-OgPlaytest' {

    BeforeAll {
        $script:engine  = New-FakeEngine (Join-Path $TestDrive 'Engine')
        $script:projDir = Join-Path $TestDrive 'proj'
        $script:project = New-FakeProject $projDir
        $script:exe     = Join-Path $engine 'Engine\Binaries\Win64\UnrealEditor.exe'
        $script:sessions = Join-Path $projDir 'Saved\Playtest'
    }

    BeforeEach {
        $script:nextPid = 1000
        Mock -ModuleName og-framework -CommandName Get-Process -MockWith { }
        Mock -ModuleName og-framework -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName og-framework -CommandName Write-Host -MockWith { }
        Mock -ModuleName og-framework -CommandName Start-Process -MockWith {
            $script:nextPid++
            [pscustomobject]@{ Id = $script:nextPid }
        }
    }

    Context 'a new session' {
        It 'starts the server, waits, then starts two clients, by default' {
            $r = Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Tag t1
            ($r.Role -join ',') | Should -Be 'Server,Client,Client'
            ($r.Index -join ',') | Should -Be '0,1,2'
            Should -Invoke -ModuleName og-framework -CommandName Start-Process -Times 3 -Exactly -ParameterFilter { $FilePath -eq $exe }
            Should -Invoke -ModuleName og-framework -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 25 }
        }

        It 'gives the server the default map, the port, the log, PIE emulation and the console' {
            $r = Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Tag t2 -Port 7777
            $server = $r | Where-Object Role -eq 'Server'
            $log = Join-Path $sessions 't2\server.log'
            $expected = @($project, '/Game/Maps/Arena', '-game', '-server', '-port=7777', '-log', "-abslog=$log",
                '-PktLagMin=15', '-PktLagMax=50', '-PktLoss=1', '-PktIncomingLagMin=15', '-PktIncomingLagMax=50', '-PktIncomingLoss=2')
            ($server.ArgumentList -join "`n") | Should -BeExactly ($expected -join "`n")
            $server.LogPath | Should -Be $log
        }

        It 'connects each client to the address and port, with its own log and a tiled window' {
            $r = Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Tag t3 -Port 7777 -Clients 2
            $c2 = $r | Where-Object { $_.Role -eq 'Client' -and $_.Index -eq 2 }
            $expected = @($project, '127.0.0.1:7777', '-game', '-windowed', '-ResX=1280', '-ResY=720', '-WinX=1290', '-WinY=40', '-log',
                ('-abslog=' + (Join-Path $sessions 't3\client2.log')))
            ($c2.ArgumentList -join "`n") | Should -BeExactly ($expected -join "`n")
        }

        It 'starts <N> clients' -TestCases @(@{ N = 0 }, @{ N = 1 }, @{ N = 4 }) {
            param($N)
            $r = Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Tag "n$N" -Clients $N
            @($r | Where-Object Role -eq 'Client').Count | Should -Be $N
            @($r | Where-Object Role -eq 'Server').Count | Should -Be 1
        }

        It 'does not wait when no client starts' {
            Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Tag n0w -Clients 0 | Out-Null
            Should -Invoke -ModuleName og-framework -CommandName Start-Sleep -Times 0 -Exactly
        }

        It 'applies -NoEmulation, -Trace, -NoConsole, -Map and the extra argument lists' {
            $r = Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Tag t4 -Clients 1 -NoEmulation -Trace -NoConsole `
                -Map /Game/Maps/Test -ExtraArgs '-a' -ServerArgs '-s' -ClientArgs '-c' -ServerLeadSeconds 3
            $server = ($r | Where-Object Role -eq 'Server').ArgumentList
            $client = ($r | Where-Object Role -eq 'Client').ArgumentList
            $server[1] | Should -Be '/Game/Maps/Test'
            $server | Should -Not -Contain '-log'
            ($server | Where-Object { $_ -like '-Pkt*' }) | Should -BeNullOrEmpty
            $server | Should -Contain '-trace=cpu,frame,bookmark,counters,task'
            $server | Should -Contain ('-tracefile=' + (Join-Path $sessions 't4\server.utrace'))
            $server[-2..-1] | Should -Be @('-a', '-s')
            $client[-2..-1] | Should -Be @('-a', '-c')
            $client | Should -Not -Contain '-log'
            Should -Invoke -ModuleName og-framework -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 3 }
        }

        It 'turns -LogLevels into sorted [Core.Log] ini overrides on every process' {
            $r = Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Tag t5 -Clients 1 -LogLevels @{ LogOGSim = 'Log'; LogOGNet = 'Verbose' }
            foreach ($p in $r) {
                $levels = $p.ArgumentList | Where-Object { $_ -like '-ini:Engine:`[Core.Log`]:*' }
                ($levels -join ',') | Should -Be '-ini:Engine:[Core.Log]:LogOGNet=Verbose,-ini:Engine:[Core.Log]:LogOGSim=Log'
            }
        }

        It 'quotes paths that contain a space' {
            $spaced = New-FakeProject (Join-Path $TestDrive 'my proj')
            $r = Start-OgPlaytest -ProjectFile $spaced -EngineRoot $engine -Tag q -Clients 0
            $r.ArgumentList[0] | Should -Be ('"' + $spaced + '"')
            $r.ArgumentList | Should -Contain ('-abslog="' + (Join-Path $TestDrive 'my proj\Saved\Playtest\q\server.log') + '"')
        }

        It 'refuses while UnrealEditor runs' {
            Mock -ModuleName og-framework -CommandName Get-Process -MockWith { [pscustomobject]@{ Id = 77 } }
            { Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Tag busy } | Should -Throw '*UnrealEditor is running (PID 77)*'
            Should -Invoke -ModuleName og-framework -CommandName Start-Process -Times 0 -Exactly
        }

        It 'starts while UnrealEditor runs with -Force' {
            Mock -ModuleName og-framework -CommandName Get-Process -MockWith { [pscustomobject]@{ Id = 77 } }
            Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Tag forced -Force | Out-Null
            Should -Invoke -ModuleName og-framework -CommandName Start-Process -Times 3 -Exactly
        }

        It 'fails clearly without a GameDefaultMap and no -Map' {
            $nomap = New-FakeProject (Join-Path $TestDrive 'nomap') -DefaultMap ''
            { Start-OgPlaytest -ProjectFile $nomap -EngineRoot $engine -Tag x } | Should -Throw '*no GameDefaultMap*pass -Map*'
        }

        It 'fails clearly when UnrealEditor.exe is missing' {
            $bare = Join-Path $TestDrive 'bare-engine'
            New-Item -ItemType Directory -Path (Join-Path $bare 'Engine\Build\BatchFiles') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $bare 'Engine\Build\BatchFiles\RunUAT.bat') -Value '@exit /b 0'
            { Start-OgPlaytest -ProjectFile $project -EngineRoot $bare -Tag x } | Should -Throw '*UnrealEditor.exe*does not exist*'
        }

        It 'uses a timestamp tag by default' {
            $r = Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Clients 0
            $r.LogPath | Should -Match ('^' + [regex]::Escape($sessions) + '\\\d{8}-\d{6}\\server\.log$')
        }

        It 'starts nothing under -WhatIf' {
            Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Tag wi -WhatIf | Should -BeNullOrEmpty
            Should -Invoke -ModuleName og-framework -CommandName Start-Process -Times 0 -Exactly
            Join-Path $sessions 'wi' | Should -Not -Exist
        }
    }

    Context '-Join' {
        It 'starts only clients, even while UnrealEditor runs, and numbers them after the existing client logs' {
            Mock -ModuleName og-framework -CommandName Get-Process -MockWith { [pscustomobject]@{ Id = 77 } }
            $dir = Join-Path $sessions 'live'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            'x' | Set-Content (Join-Path $dir 'client1.log'); 'x' | Set-Content (Join-Path $dir 'client2.log')
            $r = Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Tag live -Join -Clients 1
            @($r).Count | Should -Be 1
            $r.Role | Should -Be 'Client'
            $r.Index | Should -Be 3
            $r.LogPath | Should -Be (Join-Path $dir 'client3.log')
            $r.ArgumentList | Should -Contain '-WinX=2580'
            Should -Invoke -ModuleName og-framework -CommandName Start-Sleep -Times 0 -Exactly
        }

        It 'joins the newest session folder when no -Tag is given' {
            $old = New-Item -ItemType Directory -Path (Join-Path $sessions 'older') -Force
            $old.LastWriteTime = (Get-Date).AddDays(-2)
            $new = New-Item -ItemType Directory -Path (Join-Path $sessions 'newest') -Force
            $new.LastWriteTime = (Get-Date).AddMinutes(5)
            $r = Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Join
            $r.LogPath | Should -Be (Join-Path $sessions 'newest\client1.log')
        }

        It 'connects to -Address and -Port' {
            $r = Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Tag lan -Join -Clients 2 -Address 192.168.1.20 -Port 7777
            @($r).Count | Should -Be 2
            $r | ForEach-Object { $_.ArgumentList[1] | Should -Be '192.168.1.20:7777' }
        }

        It 'refuses -Clients 0' {
            { Start-OgPlaytest -ProjectFile $project -EngineRoot $engine -Join -Clients 0 } | Should -Throw '*-Join needs at least one client*'
        }
    }
}
