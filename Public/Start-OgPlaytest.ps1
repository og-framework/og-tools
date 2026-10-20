# SPDX-License-Identifier: MPL-2.0
function Start-OgPlaytest {
    <#
    .SYNOPSIS
        Starts a local playtest: a dedicated server and N rendered clients, as standalone processes of the Editor binary with
        -game. With -Join it starts only clients, which connect to a server that is already running.

    .DESCRIPTION
        The same shape as multi-process PIE, without the editor UI:
          - the server: UnrealEditor.exe <project> <map> -game -server -port=<Port>, with PIE's packet emulation profile
            (outgoing lag 15-50 ms and 1 % loss, incoming lag 15-50 ms and 2 % loss) unless -NoEmulation;
          - each client: UnrealEditor.exe <project> <Address>:<Port> -game -windowed -ResX/-ResY, with its windows placed side by
            side.

        Build the Editor target first (Invoke-OgUnrealBuild / ogbuild): the processes run
        <EngineRoot>\Engine\Binaries\Win64\UnrealEditor.exe against the project's Editor DLLs.

        Logs go to <project dir>\Saved\Playtest\<Tag>\: server.log and client<N>.log (-abslog), one file per process. A new
        session uses a new Tag (default: yyyyMMdd-HHmmss). -Join uses the newest session folder unless -Tag is given, and numbers
        its clients after the client logs already there, so a client that joins never overwrites an earlier client's log.

        Without -Join it refuses to start while an UnrealEditor process is running (an open editor, or an old playtest), unless
        -Force is given: the processes would compete for CPU and memory, and a running editor holds the DLLs a build needs.

        The processes are started and left running. Close the client windows first, then the server window. Each process gets a
        -log console unless -NoConsole is given.

    .PARAMETER Clients
        How many clients to start. Default: 2 for a new session (0 starts the server alone), 1 with -Join.

    .PARAMETER Join
        Start only clients, connecting to an existing server at -Address:-Port. No server is started.

    .PARAMETER Address
        The server address the clients connect to. Default: 127.0.0.1.

    .PARAMETER Port
        The server port. Default: 17900.

    .PARAMETER Map
        The map the server loads, for example /Game/ThirdPerson/Maps/ThirdPersonMap. Default: GameDefaultMap from the project's
        Config\DefaultEngine.ini.

    .PARAMETER Tag
        The session folder name under Saved\Playtest.

    .PARAMETER NoEmulation
        No packet lag or loss emulation on the server (plain loopback).

    .PARAMETER Trace
        Record an Unreal Insights trace on the server (cpu, frame, bookmark, counters, task) to <session>\server.utrace.

    .PARAMETER LogLevels
        Log category verbosities for every process, for example @{ LogOGNet = 'Verbose'; LogOGSim = 'Log' }. Each becomes
        -ini:Engine:[Core.Log]:<Category>=<Level>.

    .PARAMETER ExtraArgs
        Extra arguments for every process.

    .PARAMETER ServerArgs
        Extra arguments for the server only.

    .PARAMETER ClientArgs
        Extra arguments for the clients only.

    .PARAMETER ServerLeadSeconds
        How long to wait between starting the server and starting the clients. Default: 25.

    .PARAMETER ResX
        Client window width. Default: 1280.

    .PARAMETER ResY
        Client window height. Default: 720.

    .PARAMETER NoConsole
        Start the processes without the -log console window.

    .PARAMETER ProjectFile
        Path to the .uproject. Default: the single .uproject in the current directory.

    .PARAMETER EngineRoot
        Engine root. Default: resolved from the .uproject's EngineAssociation through the registry.

    .PARAMETER Force
        Start a new session even while an UnrealEditor process is running.

    .OUTPUTS
        One [pscustomobject] per started process: Role ('Server' or 'Client'), Index (0 for the server), ProcessId, LogPath and
        ArgumentList.

    .EXAMPLE
        ogplaytest
        # A server and two clients, with packet emulation, logs in Saved\Playtest\<timestamp>.

    .EXAMPLE
        ogplaytest -Clients 3 -Tag gate14 -LogLevels @{ LogOGSimHost = 'Log' }

    .EXAMPLE
        ogplaytest -Join
        # One more client joins the running server; its log goes into the newest session folder as the next client<N>.log.

    .EXAMPLE
        ogplaytest -Join -Clients 2 -Address 192.168.1.20 -Port 7777 -Tag lan
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateRange(0, 16)]
        [int] $Clients = 2,

        [switch] $Join,

        [string] $Address = '127.0.0.1',

        [ValidateRange(1, 65535)]
        [int] $Port = 17900,

        [string] $Map,

        [ValidatePattern('^[A-Za-z0-9._-]+$')]
        [string] $Tag,

        [switch] $NoEmulation,

        [switch] $Trace,

        [hashtable] $LogLevels = @{},

        [string[]] $ExtraArgs = @(),

        [string[]] $ServerArgs = @(),

        [string[]] $ClientArgs = @(),

        [ValidateRange(0, 600)]
        [int] $ServerLeadSeconds = 25,

        [int] $ResX = 1280,

        [int] $ResY = 720,

        [switch] $NoConsole,

        [ValidatePattern('\.uproject$')]
        [string] $ProjectFile,

        [string] $EngineRoot,

        [switch] $Force
    )

    if ($Join -and -not $PSBoundParameters.ContainsKey('Clients')) { $Clients = 1 }
    if ($Join -and $Clients -lt 1) {
        throw 'Start-OgPlaytest: -Join needs at least one client (-Clients 1 or more).'
    }

    $projectPath = Resolve-OgProjectFile -ProjectFile $ProjectFile -CallerName 'Start-OgPlaytest'
    $projectDir = Split-Path -Parent $projectPath
    $engine = Resolve-OgUnrealEngineRoot -ProjectFile $projectPath -EngineRoot $EngineRoot
    $editorExe = Join-Path $engine 'Engine\Binaries\Win64\UnrealEditor.exe'
    if (-not (Test-Path -LiteralPath $editorExe -PathType Leaf)) {
        throw "Start-OgPlaytest: '$editorExe' does not exist. Build the engine and the project's Editor target first (ogbuild)."
    }

    if (-not $Join -and -not $Force) {
        $running = Get-Process -Name 'UnrealEditor' -ErrorAction SilentlyContinue
        if ($running) {
            throw "Start-OgPlaytest: UnrealEditor is running (PID $(@($running.Id) -join ', ')). Close the editor or the old playtest first, use -Join to add clients to a running server, or pass -Force."
        }
    }

    $sessionRoot = Join-Path $projectDir 'Saved\Playtest'
    if (-not $Tag) {
        if ($Join) {
            $newest = Get-ChildItem -LiteralPath $sessionRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $Tag = if ($newest) { $newest.Name } else { 'join-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
        }
        else {
            $Tag = Get-Date -Format 'yyyyMMdd-HHmmss'
        }
    }
    $sessionDir = Join-Path $sessionRoot $Tag

    $levelArgs = foreach ($key in ($LogLevels.Keys | Sort-Object)) { "-ini:Engine:[Core.Log]:$key=$($LogLevels[$key])" }
    $consoleArgs = if ($NoConsole) { @() } else { @('-log') }
    $projectArg = ConvertTo-OgQuotedArgument $projectPath

    $firstClient = 1
    if ($Join) {
        $existing = Get-ChildItem -LiteralPath $sessionDir -Filter 'client*.log' -File -ErrorAction SilentlyContinue |
            ForEach-Object { if ($_.BaseName -match '^client(\d+)$') { [int]$Matches[1] } }
        if ($existing) { $firstClient = ([int]($existing | Measure-Object -Maximum).Maximum) + 1 }
    }

    $what = if ($Join) { "$Clients client(s) joining $Address`:$Port" } else { "a server on port $Port and $Clients client(s)" }
    if (-not $PSCmdlet.ShouldProcess($what, "Start a playtest (logs: $sessionDir)")) { return }

    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

    if (-not $Join) {
        if (-not $Map) { $Map = Get-OgDefaultGameMap -ProjectDirectory $projectDir }
        $emulation = if ($NoEmulation) { @() } else {
            @('-PktLagMin=15', '-PktLagMax=50', '-PktLoss=1', '-PktIncomingLagMin=15', '-PktIncomingLagMax=50', '-PktIncomingLoss=2')
        }
        $traceArgs = if ($Trace) {
            @('-trace=cpu,frame,bookmark,counters,task', ('-tracefile=' + (ConvertTo-OgQuotedArgument (Join-Path $sessionDir 'server.utrace'))), '-statnamedevents')
        } else { @() }
        $serverLog = Join-Path $sessionDir 'server.log'
        $serverArgList = @($projectArg, $Map, '-game', '-server', "-port=$Port") + $consoleArgs + @('-abslog=' + (ConvertTo-OgQuotedArgument $serverLog)) +
            $traceArgs + $emulation + @($levelArgs) + $ExtraArgs + $ServerArgs
        $server = Start-Process -FilePath $editorExe -ArgumentList $serverArgList -PassThru
        Write-Host "Server started (PID $($server.Id)); logs: $sessionDir"
        [pscustomobject]@{ Role = 'Server'; Index = 0; ProcessId = $server.Id; LogPath = $serverLog; ArgumentList = $serverArgList }

        if ($Clients -gt 0 -and $ServerLeadSeconds -gt 0) {
            Write-Host "Waiting $ServerLeadSeconds s for the server before starting the clients..."
            Start-Sleep -Seconds $ServerLeadSeconds
        }
    }

    for ($i = 0; $i -lt $Clients; $i++) {
        $index = $firstClient + $i
        $clientLog = Join-Path $sessionDir "client$index.log"
        $winX = ($index - 1) * ($ResX + 10)
        $clientArgList = @($projectArg, "$Address`:$Port", '-game', '-windowed', "-ResX=$ResX", "-ResY=$ResY", "-WinX=$winX", '-WinY=40') +
            $consoleArgs + @('-abslog=' + (ConvertTo-OgQuotedArgument $clientLog)) + @($levelArgs) + $ExtraArgs + $ClientArgs
        $client = Start-Process -FilePath $editorExe -ArgumentList $clientArgList -PassThru
        Write-Host "Client $index started (PID $($client.Id))."
        [pscustomobject]@{ Role = 'Client'; Index = $index; ProcessId = $client.Id; LogPath = $clientLog; ArgumentList = $clientArgList }
    }

    if (-not $Join) {
        Write-Host 'Close the client windows first, then the server window. Add a client with: ogplaytest -Join'
    }
}
