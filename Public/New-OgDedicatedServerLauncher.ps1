# SPDX-License-Identifier: MPL-2.0
function New-OgDedicatedServerLauncher {
    <#
    .SYNOPSIS
        Writes a self-contained host launcher for a packaged Unreal dedicated server into its folder.

    .DESCRIPTION
        Writes four files into -Destination (normally a server depot ContentRoot):

          Host Local Playtest.bat   runs host_server.ps1 -Mode Local
          Host Online Playtest.bat  runs host_server.ps1 -Mode Online
          host_server.ps1           the host script (Windows PowerShell 5.1 and PowerShell 7, no modules)
          host_server.settings.psd1 every value below, read by host_server.ps1

        The .bat files call powershell.exe -NoProfile -ExecutionPolicy Bypass -File, so a host
        PC needs neither og-tools nor PowerShell 7.

        Local mode: firewall rule on the UDP port for the program that listens (the staged binary
        behind an Unreal root launcher stub, else the server exe; one UAC prompt, skipped when the
        rule exists), the this-PC (127.0.0.1) and LAN join addresses, start the server, then
        offer to start the game. It makes no router (UPnP) or internet (HTTP) call.

        Online mode adds, after the firewall rule: a UPnP port mapping on the router (removed on
        exit or Ctrl+C), the public IP from an HTTPS service (with fallbacks), a carrier-grade NAT
        warning when the router's external IP differs from the public IP or lies in 100.64.0.0/10,
        and the internet join address, listed first.

        Both modes box the main join address, copy it to the clipboard and write join_info.txt.
        The server runs with <ServerArguments> -port=<Port> -log -abslog="HostLogs\server-<time>.log";
        the script tails that log, prints a friendly line for each JoinLinePattern match and,
        once ReadyLinePattern matches (or at once when it is empty), asks
        "Start the game on this PC now? [Y/n]" and runs ClientLaunch.

        All files are written with CRLF; the .ps1 and .psd1 as UTF-8 with BOM (so Windows
        PowerShell 5.1 reads non-ASCII text correctly), the .bat files as ASCII. Existing files are
        overwritten.

    .PARAMETER Destination
        Existing folder to write into, normally the server depot ContentRoot.

    .PARAMETER ServerExecutable
        Server exe relative to -Destination, e.g. MyGameServer.exe. It must exist.

    .PARAMETER ServerArguments
        Arguments put before -port, -log and -abslog, e.g. the map: /Game/Maps/Arena.

    .PARAMETER Port
        UDP port the server listens on and the launcher opens. Default 7777.

    .PARAMETER JoinLinePattern
        A .NET regex matched against every server log line. It must define the named groups
        joined and left (exactly one of them matches) and players (the player count after the
        event); tested (the tested session size) and local are optional. A match prints
        "Player joined (2/3)", "Player left (1/3)", or, when players exceeds tested,
        "Player joined (4 players - above the tested 3, expect degraded performance)".
        Example: 'Session: (?:(?<joined>joined)|(?<left>left)) players=(?<players>\d+) tested=(?<tested>\d+)'

    .PARAMETER ReadyLinePattern
        A .NET regex for the log line that shows the server is listening. The offer to start the
        game waits for it. '' offers it as soon as the server starts.

    .PARAMETER Title
        Name shown in the console and used for the firewall rule and the UPnP mapping. No double quote.

    .PARAMETER ClientLaunch
        What "Start the game on this PC now?" runs: a URI (e.g. steam://rungameid/{AppId:game}) or
        a path relative to -Destination (e.g. ..\Client\MyGameClient.exe). A token
        {AppId:<name>} is replaced from -AppIds; an AppId of 0 (placeholder) turns the launch step
        into a message. '' only prints the hint.

    .PARAMETER AppIds
        Hashtable of app name to Steam AppId, used for {AppId:<name>} tokens in -ClientLaunch.

    .PARAMETER LocalHint
        Extra line printed after the game is offered, e.g. how to add local players in-game.

    .OUTPUTS
        [pscustomobject] with Destination, LocalLauncher, OnlineLauncher, Script, Settings,
        ClientLaunch (tokens resolved) and ClientLaunchSkipReason.

    .EXAMPLE
        New-OgDedicatedServerLauncher -Destination .\Build\WindowsServer -ServerExecutable MyGameServer.exe `
            -ServerArguments '/Game/Maps/Arena' -Port 7777 -Title 'MyGame server' `
            -JoinLinePattern 'Session: (?:(?<joined>joined)|(?<left>left)) players=(?<players>\d+) tested=(?<tested>\d+)' `
            -ClientLaunch 'steam://rungameid/{AppId:game}' -AppIds @{ game = 480 }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ServerExecutable,

        [AllowEmptyString()]
        [string] $ServerArguments = '',

        [ValidateRange(1, 65535)]
        [int] $Port = 7777,

        [Parameter(Mandatory)]
        [string] $JoinLinePattern,

        [AllowEmptyString()]
        [string] $ReadyLinePattern = '',

        [Parameter(Mandatory)]
        [string] $Title,

        [AllowEmptyString()]
        [string] $ClientLaunch = '',

        [hashtable] $AppIds = @{},

        [AllowEmptyString()]
        [string] $LocalHint = ''
    )

    $destinationPath = [System.IO.Path]::GetFullPath($Destination, (Get-Location -PSProvider FileSystem).ProviderPath)
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
        throw "New-OgDedicatedServerLauncher: destination '$destinationPath' does not exist."
    }
    if ([System.IO.Path]::IsPathRooted($ServerExecutable) -or ($ServerExecutable -split '[\\/]') -contains '..') {
        throw "New-OgDedicatedServerLauncher: 'ServerExecutable' must be a path inside the destination, got '$ServerExecutable'."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $destinationPath $ServerExecutable) -PathType Leaf)) {
        throw "New-OgDedicatedServerLauncher: server executable '$ServerExecutable' does not exist in '$destinationPath'."
    }

    try {
        Assert-OgServerLauncherSettings -Title $Title -Port $Port -ServerArguments $ServerArguments `
            -JoinLinePattern $JoinLinePattern -ReadyLinePattern $ReadyLinePattern -ClientLaunch $ClientLaunch `
            -LocalHint $LocalHint -AppNames ([string[]]@($AppIds.Keys))
    }
    catch {
        throw "New-OgDedicatedServerLauncher: $($_.Exception.Message)"
    }

    $skipReason = ''
    $resolvedLaunch = $ClientLaunch
    foreach ($token in [regex]::Matches($ClientLaunch, '\{AppId:(?<name>[^}]*)\}')) {
        $appName = $token.Groups['name'].Value
        $appId = [long]$AppIds[$appName]
        if ($appId -eq 0) {
            $skipReason = "the Steam app '$appName' has no AppId yet (placeholder 0)"
            $resolvedLaunch = ''
            break
        }
        $resolvedLaunch = $resolvedLaunch.Replace($token.Value, [string]$appId)
    }

    $quote = { param([string] $Text) "'" + $Text.Replace("'", "''") + "'" }
    $settingsText = @(
        '@{'
        '    SchemaVersion          = 1'
        "    Title                  = $(& $quote $Title)"
        "    ServerExecutable       = $(& $quote $ServerExecutable)"
        "    ServerArguments        = $(& $quote $ServerArguments)"
        "    Port                   = $Port"
        "    JoinLinePattern        = $(& $quote $JoinLinePattern)"
        "    ReadyLinePattern       = $(& $quote $ReadyLinePattern)"
        "    ClientLaunch           = $(& $quote $resolvedLaunch)"
        "    ClientLaunchSkipReason = $(& $quote $skipReason)"
        "    LocalHint              = $(& $quote $LocalHint)"
        "    PublicIpServices       = @('https://api.ipify.org', 'https://checkip.amazonaws.com', 'https://icanhazip.com')"
        '}'
    ) -join "`r`n"

    $shim = {
        param([string] $Mode)
        (@(
                '@echo off'
                "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0host_server.ps1`" -Mode $Mode"
                'if errorlevel 1 pause'
            ) -join "`r`n") + "`r`n"
    }

    $templatePath = Join-Path $PSScriptRoot '..\Private\templates\host_server.ps1'
    $scriptText = ([System.IO.File]::ReadAllText($templatePath) -replace "`r?`n", "`r`n")

    $files = [ordered]@{
        'Host Local Playtest.bat'   = @{ Text = (& $shim 'Local'); Encoding = [System.Text.ASCIIEncoding]::new() }
        'Host Online Playtest.bat'  = @{ Text = (& $shim 'Online'); Encoding = [System.Text.ASCIIEncoding]::new() }
        'host_server.ps1'           = @{ Text = $scriptText; Encoding = [System.Text.UTF8Encoding]::new($true) }
        'host_server.settings.psd1' = @{ Text = $settingsText + "`r`n"; Encoding = [System.Text.UTF8Encoding]::new($true) }
    }

    if ($PSCmdlet.ShouldProcess($destinationPath, 'Write the dedicated-server host launcher')) {
        foreach ($name in $files.Keys) {
            [System.IO.File]::WriteAllText((Join-Path $destinationPath $name), $files[$name].Text, $files[$name].Encoding)
        }
    }

    [pscustomobject]@{
        Destination            = $destinationPath
        LocalLauncher          = Join-Path $destinationPath 'Host Local Playtest.bat'
        OnlineLauncher         = Join-Path $destinationPath 'Host Online Playtest.bat'
        Script                 = Join-Path $destinationPath 'host_server.ps1'
        Settings               = Join-Path $destinationPath 'host_server.settings.psd1'
        ClientLaunch           = $resolvedLaunch
        ClientLaunchSkipReason = $skipReason
    }
}
