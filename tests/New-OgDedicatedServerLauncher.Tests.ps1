# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force

    $script:templatePath = Join-Path $moduleRoot 'Private\templates\host_server.ps1'
    $script:joinPattern = 'GameSession: (?:(?<joined>joined)|(?<left>left)) players=(?<players>\d+) tested=(?<tested>\d+)(?: local=(?<local>\d+))?'
    $script:readyPattern = 'LogNet: GameNetDriver listening on port \d+'

    function New-TestLauncher {
        param([string] $Name, [hashtable] $Override = @{})
        $dest = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dest 'GameServer.exe') -Value 'exe'
        $arguments = @{
            Destination      = $dest
            ServerExecutable = 'GameServer.exe'
            ServerArguments  = '/Game/Maps/Arena'
            Port             = 7777
            JoinLinePattern  = $joinPattern
            ReadyLinePattern = $readyPattern
            Title            = 'Test Game server'
            ClientLaunch     = 'steam://rungameid/{AppId:game}'
            AppIds           = @{ game = 480; server = 481 }
            LocalHint        = 'Press Tab to add a local player.'
        }
        foreach ($key in $Override.Keys) { $arguments[$key] = $Override[$key] }
        New-OgDedicatedServerLauncher @arguments
    }
}

Describe 'New-OgDedicatedServerLauncher' {

    Context 'Generated files' {
        BeforeAll {
            $script:result = New-TestLauncher -Name 'gen'
        }

        It 'writes the two launchers, the script and the settings into the destination' {
            @(Get-ChildItem -LiteralPath $result.Destination -File | ForEach-Object Name | Sort-Object) |
                Should -Be @('GameServer.exe', 'Host Local Playtest.bat', 'Host Online Playtest.bat', 'host_server.ps1', 'host_server.settings.psd1')
            $result.LocalLauncher | Should -Be (Join-Path $result.Destination 'Host Local Playtest.bat')
            $result.OnlineLauncher | Should -Be (Join-Path $result.Destination 'Host Online Playtest.bat')
            $result.Script | Should -Be (Join-Path $result.Destination 'host_server.ps1')
            $result.Settings | Should -Be (Join-Path $result.Destination 'host_server.settings.psd1')
        }

        It 'writes each .bat as an ASCII CRLF shim into powershell.exe with its mode' -TestCases @(
            @{ File = 'Host Local Playtest.bat'; Mode = 'Local' }
            @{ File = 'Host Online Playtest.bat'; Mode = 'Online' }
        ) {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $result.Destination $File))
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
            $text = [System.Text.Encoding]::ASCII.GetString($bytes)
            $text | Should -BeExactly ("@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0host_server.ps1`" -Mode $Mode`r`nif errorlevel 1 pause`r`n")
        }

        It 'copies the template into host_server.ps1 as UTF-8 with BOM and CRLF' {
            $bytes = [System.IO.File]::ReadAllBytes($result.Script)
            $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
            $text = [System.IO.File]::ReadAllText($result.Script)
            ($text -split "`r`n").Count | Should -Be (([System.IO.File]::ReadAllText($templatePath) -split "`r?`n").Count)
            $text -replace "`r`n", "`n" | Should -BeExactly ([System.IO.File]::ReadAllText($templatePath) -replace "`r`n", "`n")
            [regex]::Matches($text, "(?<!`r)`n").Count | Should -Be 0
        }

        It 'keeps the template pure ASCII so every console and code page shows it' {
            $bytes = [System.IO.File]::ReadAllBytes($templatePath)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }

        It 'writes every value into host_server.settings.psd1, with the AppId token resolved' {
            [System.IO.File]::ReadAllBytes($result.Settings)[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
            $settings = Import-PowerShellDataFile -LiteralPath $result.Settings
            $settings.SchemaVersion | Should -Be 1
            $settings.Title | Should -BeExactly 'Test Game server'
            $settings.ServerExecutable | Should -BeExactly 'GameServer.exe'
            $settings.ServerArguments | Should -BeExactly '/Game/Maps/Arena'
            $settings.Port | Should -Be 7777
            $settings.JoinLinePattern | Should -BeExactly $joinPattern
            $settings.ReadyLinePattern | Should -BeExactly $readyPattern
            $settings.ClientLaunch | Should -BeExactly 'steam://rungameid/480'
            $settings.ClientLaunchSkipReason | Should -BeExactly ''
            $settings.LocalHint | Should -BeExactly 'Press Tab to add a local player.'
            @($settings.PublicIpServices).Count | Should -BeGreaterThan 1
            $result.ClientLaunch | Should -BeExactly 'steam://rungameid/480'
        }

        It 'round-trips quotes and non-ASCII text through the settings file' {
            $r = New-TestLauncher -Name 'quotes' -Override @{ Title = "O'Neil's server $([char]0xE9)"; LocalHint = "It's `$fun" }
            $settings = Import-PowerShellDataFile -LiteralPath $r.Settings
            $settings.Title | Should -BeExactly "O'Neil's server $([char]0xE9)"
            $settings.LocalHint | Should -BeExactly "It's `$fun"
        }
    }

    Context 'ClientLaunch tokens' {
        It 'turns a placeholder AppId 0 into an empty launch and a skip reason' {
            $r = New-TestLauncher -Name 'placeholder' -Override @{ AppIds = @{ game = 0 } }
            $r.ClientLaunch | Should -BeExactly ''
            $r.ClientLaunchSkipReason | Should -BeExactly "the Steam app 'game' has no AppId yet (placeholder 0)"
            (Import-PowerShellDataFile -LiteralPath $r.Settings).ClientLaunchSkipReason | Should -BeExactly $r.ClientLaunchSkipReason
        }

        It 'passes a launch without tokens through unchanged' {
            $r = New-TestLauncher -Name 'plainpath' -Override @{ ClientLaunch = '..\Client\GameClient.exe' }
            $r.ClientLaunch | Should -BeExactly '..\Client\GameClient.exe'
        }

        It 'rejects a token naming an unknown app' {
            { New-TestLauncher -Name 'unknownapp' -Override @{ ClientLaunch = 'steam://rungameid/{AppId:nope}' } } |
                Should -Throw "*ClientLaunch' references unknown app 'nope'*"
        }

        It 'rejects an absolute ClientLaunch path' {
            { New-TestLauncher -Name 'rooted' -Override @{ ClientLaunch = 'C:\Games\GameClient.exe' } } |
                Should -Throw "*ClientLaunch' must be a URI or a path relative*"
        }
    }

    Context 'Validation' {
        It 'rejects <Case>' -TestCases @(
            @{ Case = 'a JoinLinePattern that is not a regex'; Override = @{ JoinLinePattern = '(?<joined>' }; Message = "*JoinLinePattern' is not a valid regular expression*" }
            @{ Case = 'a JoinLinePattern without (?<joined>)'; Override = @{ JoinLinePattern = '(?<left>left) (?<players>\d+)' }; Message = '*missing: joined*' }
            @{ Case = 'a JoinLinePattern without (?<left>)'; Override = @{ JoinLinePattern = '(?<joined>joined) (?<players>\d+)' }; Message = '*missing: left*' }
            @{ Case = 'a JoinLinePattern without (?<players>)'; Override = @{ JoinLinePattern = '(?<joined>joined)|(?<left>left)' }; Message = '*missing: players*' }
            @{ Case = 'a ReadyLinePattern that is not a regex'; Override = @{ ReadyLinePattern = '[' }; Message = "*ReadyLinePattern' is not a valid regular expression*" }
            @{ Case = 'a Title with a double quote'; Override = @{ Title = 'My "best" server' }; Message = "*Title' must not contain a double quote*" }
            @{ Case = 'a blank Title'; Override = @{ Title = ' ' }; Message = "*Title' must not be empty*" }
            @{ Case = 'a LocalHint with a line break'; Override = @{ LocalHint = "one`ntwo" }; Message = "*LocalHint' must be a single line*" }
            @{ Case = 'ServerArguments with a line break'; Override = @{ ServerArguments = "/Game/A`r`n-x" }; Message = "*ServerArguments' must be a single line*" }
            @{ Case = 'a server executable that does not exist'; Override = @{ ServerExecutable = 'Missing.exe' }; Message = "*server executable 'Missing.exe' does not exist*" }
            @{ Case = 'a server executable outside the destination'; Override = @{ ServerExecutable = '..\GameServer.exe' }; Message = "*'ServerExecutable' must be a path inside the destination*" }
            @{ Case = 'a destination that does not exist'; Override = @{ Destination = 'Z:\no\such\folder' }; Message = "*destination 'Z:\no\such\folder' does not exist*" }
        ) {
            { New-TestLauncher -Name ('bad-' + [guid]::NewGuid().ToString('N')) -Override $Override } | Should -Throw $Message
        }

        It 'rejects port <Port>' -TestCases @(@{ Port = 0 }, @{ Port = 65536 }) {
            { New-TestLauncher -Name ('port-' + $Port) -Override @{ Port = $Port } } | Should -Throw '*Port*'
        }

        It 'writes nothing with -WhatIf' {
            $dest = Join-Path $TestDrive 'whatif'
            New-Item -ItemType Directory -Path $dest | Out-Null
            Set-Content -LiteralPath (Join-Path $dest 'GameServer.exe') -Value 'exe'
            $null = New-OgDedicatedServerLauncher -Destination $dest -ServerExecutable 'GameServer.exe' -JoinLinePattern $joinPattern -Title 'T' -WhatIf
            @(Get-ChildItem -LiteralPath $dest -File).Count | Should -Be 1
        }
    }

    Context 'Module surface' {
        It 'is exported and documents every parameter' {
            (Get-Command -Module og-framework -Name New-OgDedicatedServerLauncher).CommandType | Should -Be 'Function'
            $help = Get-Help New-OgDedicatedServerLauncher -Full
            foreach ($name in 'Destination', 'ServerExecutable', 'ServerArguments', 'Port', 'JoinLinePattern', 'ReadyLinePattern', 'Title', 'ClientLaunch', 'AppIds', 'LocalHint') {
                $parameter = $help.parameters.parameter | Where-Object name -EQ $name
                ($parameter.description | Out-String).Trim() | Should -Not -BeNullOrEmpty -Because "-$name needs help text"
            }
            ($help.parameters.parameter | Where-Object name -EQ 'JoinLinePattern').description | Out-String |
                Should -Match 'joined[\s\S]*left[\s\S]*players'
        }

        It 'keeps its helpers private' {
            Get-Command -Module og-framework -Name Assert-OgServerLauncherSettings -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }
}

Describe 'host_server.ps1 (generated)' {

    BeforeAll {
        $script:main = New-TestLauncher -Name 'host-main'
        $script:hostRoot = $main.Destination
        . $main.Script

        function Invoke-TestHost {
            param([string] $Mode, [string] $Root = $hostRoot)
            Invoke-OgHostMain -Mode $Mode -Root $Root
        }

        function Get-TestHostText {
            $hostOut -join "`n"
        }
    }

    BeforeEach {
        $script:hostOut = [System.Collections.Generic.List[string]]::new()
        $script:ruleExists = $false
        $script:ruleCheckThrows = $false
        $script:elevation = 'ok'
        $script:upnpCollection = 'COLLECTION'
        $script:upnpThrows = $false
        $script:upnpAddFails = $false
        $script:existingMapping = $null
        $script:routerIp = '198.51.100.7'
        $script:httpAnswers = @{ 'https://api.ipify.org' = '198.51.100.7' }
        $script:lan = @(
            [pscustomobject]@{ Address = '192.168.1.20'; InterfaceName = 'Ethernet'; HasGateway = $true }
            [pscustomobject]@{ Address = '172.20.0.1'; InterfaceName = 'vEthernet (WSL)'; HasGateway = $false }
        )
        $script:answer = ''
        $script:startFails = $false
        $script:tailFails = $false
        $script:removeFails = $false
        $script:logQueue = [System.Collections.Queue]::new()
        $logQueue.Enqueue(@('LogInit: engine starting', 'LogNet: GameNetDriver listening on port 7777'))
        $logQueue.Enqueue(@('GameSession: joined players=1 tested=3 local=1', 'noise'))

        Mock Write-OgHostLine { $hostOut.Add($Text) }
        Mock Read-OgHostAnswer { $hostOut.Add("PROMPT $Prompt"); $answer }
        Mock Wait-OgHostTick { }
        Mock Test-OgHostFirewallRule { if ($ruleCheckThrows) { throw 'COM failure' }; $ruleExists }
        Mock Invoke-OgHostElevated {
            switch ($elevation) {
                'declined' { throw [System.InvalidOperationException]::new('The operation was canceled by the user.') }
                'fail' { 1 }
                default { 0 }
            }
        }
        Mock Get-OgHostUpnpCollection { if ($upnpThrows) { throw 'no NAT COM' }; $upnpCollection }
        Mock Get-OgHostUpnpMapping { $existingMapping }
        Mock Add-OgHostUpnpMapping {
            if ($upnpAddFails) { throw 'The router refused the mapping' }
            [pscustomobject]@{ ExternalIPAddress = $routerIp; InternalClient = $InternalClient }
        }
        Mock Remove-OgHostUpnpMapping { if ($removeFails) { throw 'router gone' } }
        Mock Invoke-OgHostHttpGet {
            $a = $httpAnswers[$Uri]
            if ($null -eq $a) { throw "timeout for $Uri" }
            $a
        }
        Mock Get-OgHostLanAddresses { $lan }
        Mock Set-OgHostClipboard { }
        Mock Start-OgHostServerProcess {
            if ($startFails) { throw 'the server exe could not start' }
            [pscustomobject]@{ Id = 4242; ExitCode = 0 }
        }
        Mock Test-OgHostProcessRunning { $logQueue.Count -gt 0 }
        Mock Read-OgHostLogLines {
            if ($tailFails) { throw 'log disappeared' }
            if ($logQueue.Count -gt 0) { $logQueue.Dequeue() }
        }
        Mock Stop-OgHostServerProcess { }
        Mock Start-OgHostClientLaunch { }
    }

    Context 'Local mode' {
        It 'makes zero UPnP and zero HTTP calls' {
            Invoke-TestHost -Mode Local | Should -Be 0
            Should -Invoke Get-OgHostUpnpCollection -Times 0 -Exactly
            Should -Invoke Get-OgHostUpnpMapping -Times 0 -Exactly
            Should -Invoke Add-OgHostUpnpMapping -Times 0 -Exactly
            Should -Invoke Remove-OgHostUpnpMapping -Times 0 -Exactly
            Should -Invoke Invoke-OgHostHttpGet -Times 0 -Exactly
        }

        It 'tells how to stop the server without mentioning router forwarding' {
            Invoke-TestHost -Mode Local | Should -Be 0
            $text = Get-TestHostText
            $text | Should -Match 'Press Ctrl\+C here to stop the server\.'
            $text | Should -Not -Match 'forwarding'
        }

        It 'lists this PC and the LAN addresses, boxes and copies the LAN address and writes join_info.txt' {
            Invoke-TestHost -Mode Local | Should -Be 0
            $text = Get-TestHostText
            $text | Should -Match '\|  Join address: 192\.168\.1\.20:7777'
            $text | Should -Match 'This PC\s+127\.0\.0\.1:7777'
            $text | Should -Match 'LAN\s+192\.168\.1\.20:7777'
            $text | Should -Match 'LAN\s+172\.20\.0\.1:7777'
            $text | Should -Not -Match 'Internet'
            Should -Invoke Set-OgHostClipboard -Times 1 -Exactly -ParameterFilter { $Text -eq '192.168.1.20:7777' }
            [System.IO.File]::ReadAllText((Join-Path $hostRoot 'join_info.txt')) |
                Should -BeExactly "join=192.168.1.20:7777`r`nThis PC=127.0.0.1:7777`r`nLAN=192.168.1.20:7777`r`nLAN=172.20.0.1:7777`r`n"
        }

        It 'boxes the this-PC address when there is no LAN adapter' {
            $script:lan = @()
            Invoke-TestHost -Mode Local | Should -Be 0
            Get-TestHostText | Should -Match '\|  Join address: 127\.0\.0\.1:7777'
        }

        It 'starts the server with its arguments plus -port, -log and -abslog into HostLogs' {
            Invoke-TestHost -Mode Local | Should -Be 0
            $exe = Join-Path $hostRoot 'GameServer.exe'
            Should -Invoke Start-OgHostServerProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq $exe -and $WorkingDirectory -eq $hostRoot -and
                $Arguments -match ('^/Game/Maps/Arena -port=7777 -log -abslog="' + [regex]::Escape((Join-Path $hostRoot 'HostLogs')) + '\\server-\d{8}-\d{6}\.log"$')
            }
            Test-Path -LiteralPath (Join-Path $hostRoot 'HostLogs') -PathType Container | Should -BeTrue
        }

        It 'echoes friendly lines for join and leave matches and ignores the rest' {
            $logQueue.Clear()
            $logQueue.Enqueue(@('LogNet: GameNetDriver listening on port 7777', 'GameSession: joined players=2 tested=3 local=2'))
            $logQueue.Enqueue(@('GameSession: joined players=4 tested=3 local=1', 'GameSession: above tested size players=4 tested=3'))
            $logQueue.Enqueue(@('GameSession: left players=3 tested=3', 'GameSession: left players=0 tested=3', 'LogTemp: unrelated'))
            Invoke-TestHost -Mode Local | Should -Be 0
            $friendly = @($hostOut | Where-Object { $_ -match '^\[\d\d:\d\d:\d\d\] ' } | ForEach-Object { $_.Substring(11) })
            $friendly | Should -Be @(
                'Player joined (2/3)'
                'Player joined (4 players - above the tested 3, expect degraded performance)'
                'Player left (3/3)'
                'Player left (0/3)'
            )
        }

        It 'offers to start the game only after the ready line' {
            $logQueue.Clear()
            $logQueue.Enqueue(@('LogInit: booting'))
            $logQueue.Enqueue(@('LogNet: GameNetDriver listening on port 7777'))
            $logQueue.Enqueue(@('GameSession: joined players=1 tested=3 local=1'))
            Invoke-TestHost -Mode Local | Should -Be 0
            $ready = $hostOut.IndexOf('Server is ready on UDP 7777.')
            $prompt = $hostOut.IndexOf('PROMPT Start the game on this PC now? [Y/n]')
            $ready | Should -BeGreaterThan -1
            $prompt | Should -BeGreaterThan $ready
            Should -Invoke Read-OgHostAnswer -Times 1 -Exactly
        }

        It 'never offers the game when the server stops before it is ready' {
            $logQueue.Clear()
            $logQueue.Enqueue(@('LogInit: booting', 'Fatal error'))
            Invoke-TestHost -Mode Local | Should -Be 0
            Should -Invoke Read-OgHostAnswer -Times 0 -Exactly
            Should -Invoke Start-OgHostClientLaunch -Times 0 -Exactly
        }
    }

    Context 'Online mode' {
        It 'warns that closing the window leaves the router forwarding only when a mapping was added' {
            Invoke-TestHost -Mode Online | Should -Be 0
            Get-TestHostText | Should -Match 'Closing this window instead leaves the router forwarding in place'
            $script:hostOut = [System.Collections.Generic.List[string]]::new()
            $script:upnpCollection = $null
            $logQueue.Enqueue(@('LogNet: GameNetDriver listening on port 7777'))
            Invoke-TestHost -Mode Online | Should -Be 0
            Get-TestHostText | Should -Not -Match 'forwarding in place'
        }

        It 'maps the port via UPnP to the gateway adapter, lists the internet address first and removes the mapping at the end' {
            Invoke-TestHost -Mode Online | Should -Be 0
            Should -Invoke Add-OgHostUpnpMapping -Times 1 -Exactly -ParameterFilter {
                $Collection -eq 'COLLECTION' -and $Port -eq 7777 -and $InternalClient -eq '192.168.1.20' -and $Description -eq 'Test Game server'
            }
            Should -Invoke Remove-OgHostUpnpMapping -Times 1 -Exactly -ParameterFilter { $Collection -eq 'COLLECTION' -and $Port -eq 7777 }
            $text = Get-TestHostText
            $text | Should -Match '\|  Join address: 198\.51\.100\.7:7777'
            $text | Should -Not -Match 'WARNING'
            $all = @($hostOut | Where-Object { $_ -match '^  (Internet|This PC|LAN) ' })
            $all[0] | Should -Match '^  Internet\s+198\.51\.100\.7:7777'
            $all[1] | Should -Match '^  This PC\s+127\.0\.0\.1:7777'
            $all[2] | Should -Match '^  LAN\s+192\.168\.1\.20:7777'
            Should -Invoke Set-OgHostClipboard -Times 1 -Exactly -ParameterFilter { $Text -eq '198.51.100.7:7777' }
            (Get-Content -LiteralPath (Join-Path $hostRoot 'join_info.txt'))[0..1] | Should -Be @('join=198.51.100.7:7777', 'Internet=198.51.100.7:7777')
        }

        It 'continues with a manual forwarding hint when UPnP is unavailable (null collection)' {
            $script:upnpCollection = $null
            Invoke-TestHost -Mode Online | Should -Be 0
            $text = Get-TestHostText
            $text | Should -Match 'UPnP unavailable\. Forward UDP 7777 on your router to 192\.168\.1\.20 by hand'
            $text | Should -Match 'carrier-grade NAT was not checked'
            $text | Should -Match '\|  Join address: 198\.51\.100\.7:7777'
            Should -Invoke Add-OgHostUpnpMapping -Times 0 -Exactly
            Should -Invoke Remove-OgHostUpnpMapping -Times 0 -Exactly
            Should -Invoke Start-OgHostServerProcess -Times 1 -Exactly
        }

        It 'treats a failing UPnP COM object as unavailable' {
            $script:upnpThrows = $true
            Invoke-TestHost -Mode Online | Should -Be 0
            Get-TestHostText | Should -Match 'UPnP unavailable'
            Should -Invoke Start-OgHostServerProcess -Times 1 -Exactly
        }

        It 'continues when the router refuses the mapping, and removes nothing' {
            $script:upnpAddFails = $true
            Invoke-TestHost -Mode Online | Should -Be 0
            Get-TestHostText | Should -Match 'UPnP port forwarding failed \(The router refused the mapping\)\. Forward UDP 7777'
            Should -Invoke Remove-OgHostUpnpMapping -Times 0 -Exactly
            Should -Invoke Start-OgHostServerProcess -Times 1 -Exactly
        }

        It 'leaves a mapping that points at another PC alone' {
            $script:existingMapping = [pscustomobject]@{ InternalClient = '192.168.1.99'; ExternalIPAddress = '198.51.100.7' }
            Invoke-TestHost -Mode Online | Should -Be 0
            Get-TestHostText | Should -Match 'already forwarded to another PC \(192\.168\.1\.99\)'
            Should -Invoke Add-OgHostUpnpMapping -Times 0 -Exactly
            Should -Invoke Remove-OgHostUpnpMapping -Times 0 -Exactly
        }

        It 'reuses and then removes a mapping to this PC left by an earlier run' {
            $script:existingMapping = [pscustomobject]@{ InternalClient = '192.168.1.20'; ExternalIPAddress = '198.51.100.7' }
            Invoke-TestHost -Mode Online | Should -Be 0
            Get-TestHostText | Should -Match 'reusing the UDP 7777 forwarding'
            Should -Invoke Add-OgHostUpnpMapping -Times 0 -Exactly
            Should -Invoke Remove-OgHostUpnpMapping -Times 1 -Exactly
        }

        It 'does not ask the router when no adapter has a gateway' {
            $script:lan = @([pscustomobject]@{ Address = '172.20.0.1'; InterfaceName = 'vEthernet'; HasGateway = $false })
            Invoke-TestHost -Mode Online | Should -Be 0
            Get-TestHostText | Should -Match 'no network adapter with a gateway'
            Should -Invoke Get-OgHostUpnpCollection -Times 0 -Exactly
        }

        It 'warns about carrier-grade NAT when <Case>' -TestCases @(
            @{ Case = 'the router address is in 100.64.0.0/10'; Router = '100.72.13.5'; Public = '100.72.13.5' }
            @{ Case = 'the router and public addresses differ'; Router = '203.0.113.9'; Public = '198.51.100.7' }
            @{ Case = 'the router has a private address (double NAT)'; Router = '192.168.0.2'; Public = '198.51.100.7' }
        ) {
            $script:routerIp = $Router
            $script:httpAnswers = @{ 'https://api.ipify.org' = $Public }
            Invoke-TestHost -Mode Online | Should -Be 0
            $text = Get-TestHostText
            $text | Should -Match 'WARNING: your router''s internet address'
            $text | Should -Match 'carrier-grade NAT'
            $text | Should -Match 'Tailscale or ZeroTier'
        }

        It 'does not warn about carrier-grade NAT when the router and public addresses match' {
            Invoke-TestHost -Mode Online | Should -Be 0
            Get-TestHostText | Should -Not -Match 'carrier-grade NAT'
        }

        It 'falls back to the next IP service when <Case>' -TestCases @(
            @{ Case = 'the first one fails'; First = $null }
            @{ Case = 'the first one returns no IPv4 address'; First = '<html>blocked</html>' }
        ) {
            $script:httpAnswers = @{ 'https://api.ipify.org' = $First; 'https://checkip.amazonaws.com' = "198.51.100.7`n" }
            Invoke-TestHost -Mode Online | Should -Be 0
            Should -Invoke Invoke-OgHostHttpGet -Times 2 -Exactly
            Get-TestHostText | Should -Match '\|  Join address: 198\.51\.100\.7:7777'
        }

        It 'uses the router address when every IP service is down' {
            $script:httpAnswers = @{}
            Invoke-TestHost -Mode Online | Should -Be 0
            Should -Invoke Invoke-OgHostHttpGet -Times 3 -Exactly
            $text = Get-TestHostText
            $text | Should -Match 'Could not look up the public internet address'
            $text | Should -Match '\|  Join address: 198\.51\.100\.7:7777'
        }

        It 'falls back to the LAN address when neither the IP services nor UPnP answer' {
            $script:httpAnswers = @{}
            $script:upnpCollection = $null
            Invoke-TestHost -Mode Online | Should -Be 0
            $text = Get-TestHostText
            $text | Should -Match '\|  Join address: 192\.168\.1\.20:7777'
            $text | Should -Not -Match '  Internet '
        }
    }

    Context 'Firewall rule' {
        It 'skips elevation when the rule exists' {
            $script:ruleExists = $true
            Invoke-TestHost -Mode Local | Should -Be 0
            Should -Invoke Invoke-OgHostElevated -Times 0 -Exactly
            Get-TestHostText | Should -Match "rule 'Test Game server \(UDP 7777\)' already present"
        }

        It 'adds an inbound UDP rule for the server exe with one elevated netsh call' {
            Invoke-TestHost -Mode Local | Should -Be 0
            $exe = Join-Path $hostRoot 'GameServer.exe'
            Should -Invoke Test-OgHostFirewallRule -Times 1 -Exactly -ParameterFilter {
                $RuleName -eq 'Test Game server (UDP 7777)' -and $Program -eq $exe -and $Port -eq 7777
            }
            Should -Invoke Invoke-OgHostElevated -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'netsh.exe' -and
                $Arguments -eq "advfirewall firewall add rule name=`"Test Game server (UDP 7777)`" dir=in action=allow program=`"$exe`" protocol=UDP localport=7777 profile=any"
            }
            Get-TestHostText | Should -Match "rule 'Test Game server \(UDP 7777\)' added"
        }

        It 'adds the rule for the staged binary <Staged> that the root launcher starts' -ForEach @(
            @{ Staged = 'GameServer.exe' }
            @{ Staged = 'GameServer-Win64-Shipping.exe' }
        ) {
            $launcher = New-TestLauncher -Name ("host-staged-" + [guid]::NewGuid().ToString('N'))
            $binaries = Join-Path $launcher.Destination 'GameProject\Binaries\Win64'
            New-Item -ItemType Directory -Path $binaries -Force | Out-Null
            $real = Join-Path $binaries $Staged
            Set-Content -LiteralPath $real -Value 'real exe'
            Invoke-TestHost -Mode Local -Root $launcher.Destination | Should -Be 0
            Should -Invoke Test-OgHostFirewallRule -Times 1 -Exactly -ParameterFilter { $Program -eq $real }
            Should -Invoke Invoke-OgHostElevated -Times 1 -Exactly -ParameterFilter {
                $Arguments -eq "advfirewall firewall add rule name=`"Test Game server (UDP 7777)`" dir=in action=allow program=`"$real`" protocol=UDP localport=7777 profile=any"
            }
            Should -Invoke Start-OgHostServerProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq (Join-Path $launcher.Destination 'GameServer.exe')
            }
        }

        It 'continues with a warning when elevation is declined' {
            $script:elevation = 'declined'
            Invoke-TestHost -Mode Local | Should -Be 0
            Get-TestHostText | Should -Match 'permission was declined'
            Should -Invoke Start-OgHostServerProcess -Times 1 -Exactly
        }

        It 'continues with a warning when netsh fails' {
            $script:elevation = 'fail'
            Invoke-TestHost -Mode Local | Should -Be 0
            Get-TestHostText | Should -Match 'netsh exit code 1'
            Should -Invoke Start-OgHostServerProcess -Times 1 -Exactly
        }

        It 'tries to add the rule when the rules cannot be read' {
            $script:ruleCheckThrows = $true
            Invoke-TestHost -Mode Local | Should -Be 0
            Should -Invoke Invoke-OgHostElevated -Times 1 -Exactly
        }
    }

    Context 'Starting the game on this PC' {
        It 'launches the resolved Steam URI on Enter and prints the join hint and the local hint' {
            Invoke-TestHost -Mode Local | Should -Be 0
            Should -Invoke Start-OgHostClientLaunch -Times 1 -Exactly -ParameterFilter { $Target -eq 'steam://rungameid/480' }
            $text = Get-TestHostText
            $text | Should -Match "In the game, pick 'This PC' \(127\.0\.0\.1:7777\) and press Join\."
            $text | Should -Match 'Press Tab to add a local player\.'
        }

        It 'offers the game in Online mode too' {
            $script:answer = 'y'
            Invoke-TestHost -Mode Online | Should -Be 0
            Should -Invoke Start-OgHostClientLaunch -Times 1 -Exactly
        }

        It 'does not launch on <Answer>' -TestCases @(@{ Answer = 'n' }, @{ Answer = 'No' }) {
            $script:answer = $Answer
            Invoke-TestHost -Mode Local | Should -Be 0
            Should -Invoke Start-OgHostClientLaunch -Times 0 -Exactly
            Get-TestHostText | Should -Match "pick 'This PC'"
        }

        It 'skips the offer with the reason when the AppId is a placeholder' {
            $r = New-TestLauncher -Name 'host-placeholder' -Override @{ AppIds = @{ game = 0 } }
            Invoke-TestHost -Mode Local -Root $r.Destination | Should -Be 0
            Should -Invoke Read-OgHostAnswer -Times 0 -Exactly
            Should -Invoke Start-OgHostClientLaunch -Times 0 -Exactly
            Get-TestHostText | Should -Match "Not starting the game automatically: the Steam app 'game' has no AppId yet \(placeholder 0\)\. Start it yourself\."
        }

        It 'launches a relative client path from its own folder' {
            $r = New-TestLauncher -Name 'host-relpath\Server' -Override @{ ClientLaunch = '..\Client\GameClient.exe' }
            $clientDir = Join-Path $TestDrive 'host-relpath\Client'
            New-Item -ItemType Directory -Path $clientDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $clientDir 'GameClient.exe') -Value 'exe'
            Invoke-TestHost -Mode Local -Root $r.Destination | Should -Be 0
            Should -Invoke Start-OgHostClientLaunch -Times 1 -Exactly -ParameterFilter {
                $Target -eq (Join-Path $clientDir 'GameClient.exe') -and $WorkingDirectory -eq $clientDir
            }
        }

        It 'says so when the relative client path is missing' {
            $r = New-TestLauncher -Name 'host-missing\Server' -Override @{ ClientLaunch = '..\Client\GameClient.exe' }
            Invoke-TestHost -Mode Local -Root $r.Destination | Should -Be 0
            Should -Invoke Start-OgHostClientLaunch -Times 0 -Exactly
            Get-TestHostText | Should -Match 'The game was not found at .*GameClient\.exe.*Start it yourself'
        }

        It 'offers the game at once when ReadyLinePattern is empty' {
            $r = New-TestLauncher -Name 'host-noready' -Override @{ ReadyLinePattern = '' }
            $logQueue.Clear()
            $logQueue.Enqueue(@('LogInit: booting'))
            Invoke-TestHost -Mode Local -Root $r.Destination | Should -Be 0
            Should -Invoke Read-OgHostAnswer -Times 1 -Exactly
        }
    }

    Context 'Cleanup' {
        It 'removes the UPnP mapping and returns 1 when the server cannot start' {
            $script:startFails = $true
            Invoke-TestHost -Mode Online | Should -Be 1
            Should -Invoke Add-OgHostUpnpMapping -Times 1 -Exactly
            Should -Invoke Remove-OgHostUpnpMapping -Times 1 -Exactly
            Get-TestHostText | Should -Match 'ERROR: the server exe could not start'
        }

        It 'stops the server and removes the mapping when the session fails while the server runs' {
            $script:tailFails = $true
            Invoke-TestHost -Mode Online | Should -Be 1
            Should -Invoke Stop-OgHostServerProcess -Times 1 -Exactly
            Should -Invoke Remove-OgHostUpnpMapping -Times 1 -Exactly
        }

        It 'does not stop a server that already exited' {
            Invoke-TestHost -Mode Online | Should -Be 0
            Should -Invoke Stop-OgHostServerProcess -Times 0 -Exactly
            Get-TestHostText | Should -Match 'The server stopped \(exit code 0\)'
        }

        It 'warns when the mapping cannot be removed' {
            $script:removeFails = $true
            Invoke-TestHost -Mode Online | Should -Be 0
            Get-TestHostText | Should -Match 'could not remove the UDP 7777 forwarding \(router gone\)'
        }

        It 'fails with a clear message when the server exe is missing' {
            $r = New-TestLauncher -Name 'host-noexe'
            Remove-Item -LiteralPath (Join-Path $r.Destination 'GameServer.exe')
            Invoke-TestHost -Mode Local -Root $r.Destination | Should -Be 1
            Get-TestHostText | Should -Match "ERROR: The server program '.*GameServer\.exe' is missing"
            Should -Invoke Start-OgHostServerProcess -Times 0 -Exactly
        }
    }
}

Describe 'host_server.ps1 helpers (real, unmocked)' {
    BeforeAll {
        . (New-TestLauncher -Name 'helpers').Script
    }

        It 'formats <Line> as <Expected>' -TestCases @(
            @{ Line = 'GameSession: joined players=3 tested=3 local=3'; Expected = 'Player joined (3/3)' }
            @{ Line = 'x GameSession: joined players=5 tested=3'; Expected = 'Player joined (5 players - above the tested 3, expect degraded performance)' }
            @{ Line = 'GameSession: left players=4 tested=3'; Expected = 'Player left (4 players - still above the tested 3)' }
            @{ Line = 'GameSession: above tested size players=4 tested=3'; Expected = $null }
            @{ Line = 'unrelated'; Expected = $null }
        ) {
            ConvertTo-OgHostFriendlyLine -Line $Line -Pattern ([regex]::new($joinPattern)) | Should -Be $Expected
        }

        It 'reports only the count when the pattern has no tested group' {
            $pattern = [regex]::new('(?:(?<joined>in)|(?<left>out)) n=(?<players>\d+)')
            ConvertTo-OgHostFriendlyLine -Line 'in n=4' -Pattern $pattern | Should -Be 'Player joined (4 players)'
        }

        It 'classifies <Address> as shared (100.64.0.0/10): <Shared>' -TestCases @(
            @{ Address = '100.63.255.255'; Shared = $false }
            @{ Address = '100.64.0.0'; Shared = $true }
            @{ Address = '100.127.255.255'; Shared = $true }
            @{ Address = '100.128.0.0'; Shared = $false }
            @{ Address = 'not an ip'; Shared = $false }
        ) {
            Test-OgHostSharedAddress $Address | Should -Be $Shared
        }

        It 'returns a router mapping collection that holds no mappings yet instead of nothing' {
            $empty = [System.Collections.ArrayList]::new()
            Mock New-OgHostNatUpnp { [pscustomobject]@{ StaticPortMappingCollection = $empty } }
            $collection = Get-OgHostUpnpCollection
            $null -eq $collection | Should -BeFalse
            [object]::ReferenceEquals($collection, $empty) | Should -BeTrue
        }

        It 'returns nothing when the router has no UPnP' {
            Mock New-OgHostNatUpnp { [pscustomobject]@{ StaticPortMappingCollection = $null } }
            $null -eq (Get-OgHostUpnpCollection) | Should -BeTrue
        }

        It 'stops the server together with the child process a launcher stub started' {
            $parent = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c ping -n 60 127.0.0.1 >nul' -WindowStyle Hidden -PassThru
            $child = $null
            $deadline = (Get-Date).AddSeconds(10)
            while (-not $child -and (Get-Date) -lt $deadline) {
                $child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($parent.Id) AND Name='PING.EXE'"
                if (-not $child) { Start-Sleep -Milliseconds 100 }
            }
            $child | Should -Not -BeNullOrEmpty
            try {
                Stop-OgHostServerProcess -Process $parent
                $deadline = (Get-Date).AddSeconds(5)
                while ((Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
                Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            }
            finally {
                Stop-Process -Id $parent.Id -Force -ErrorAction SilentlyContinue
                Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }

        It 'tails a growing log file and holds back a partial line' {
            $path = Join-Path $TestDrive 'tail\server.log'
            $tail = New-OgHostLogTail -Path $path
            @(Read-OgHostLogLines -Tail $tail).Count | Should -Be 0
            New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
            [System.IO.File]::WriteAllText($path, "first`r`nsec", [System.Text.UTF8Encoding]::new($true))
            @(Read-OgHostLogLines -Tail $tail) | Should -Be @('first')
            [System.IO.File]::AppendAllText($path, "ond`r`nthird`n")
            @(Read-OgHostLogLines -Tail $tail) | Should -Be @('second', 'third')
            @(Read-OgHostLogLines -Tail $tail).Count | Should -Be 0
            Close-OgHostLogTail $tail
        }

        It 'rejects a damaged settings file' {
            $dir = Join-Path $TestDrive 'damaged'
            New-Item -ItemType Directory -Path $dir | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'host_server.settings.psd1') -Value "@{ Title = 'x'"
            { Read-OgHostSettings -Root $dir } | Should -Throw '*is damaged*'
        }
}

Describe 'host_server.ps1 in both shells' {
    BeforeAll {
        $script:generated = New-TestLauncher -Name 'shells'
        $script:windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    It 'parses with zero errors in pwsh' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($generated.Script, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It 'parses with zero errors and runs its offline helpers in Windows PowerShell 5.1' {
        if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
            Set-ItResult -Skipped -Because 'powershell.exe (Windows PowerShell 5.1) is not installed'
            return
        }
        $probe = Join-Path $TestDrive 'probe51.ps1'
        Set-Content -LiteralPath $probe -Encoding ascii -Value @"
`$errors = `$null
`$null = [System.Management.Automation.Language.Parser]::ParseFile('$($generated.Script)', [ref]`$null, [ref]`$errors)
"version=`$(`$PSVersionTable.PSVersion.Major).`$(`$PSVersionTable.PSVersion.Minor)"
"errors=`$(`$errors.Count)"
. '$($generated.Script)'
`$settings = Read-OgHostSettings -Root '$($generated.Destination)'
"port=`$(`$settings.Port)"
"friendly=`$(ConvertTo-OgHostFriendlyLine -Line 'GameSession: joined players=4 tested=3' -Pattern (New-Object System.Text.RegularExpressions.Regex(`$settings.JoinLinePattern)))"
"shared=`$(Test-OgHostSharedAddress '100.100.1.1')"
"box=`$((Format-OgHostBox @('ab'))[1])"
"@
        $output = & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe 2>&1 | ForEach-Object { "$_" }
        $output | Should -Be @(
            'version=5.1'
            'errors=0'
            'port=7777'
            'friendly=Player joined (4 players - above the tested 3, expect degraded performance)'
            'shared=True'
            'box=|  ab  |'
        )
    }
}
