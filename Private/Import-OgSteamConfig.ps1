# SPDX-License-Identifier: MPL-2.0

function Import-OgSteamConfig {
    <#
    .SYNOPSIS
        Loads and validates a Steam publish config (.psd1) and returns it with absolute paths.

    .DESCRIPTION
        Reads the file with Import-PowerShellDataFile and validates it against schema version 1:

            SchemaVersion  = 1                  (required)
            ProjectFile    = '<rel or abs>.uproject'   (required, must exist)
            EngineRoot     = ''                 (optional; '' resolves from the .uproject later)
            Platform       = 'Win64'            (required; only Win64)
            BuilderAccount = ''                 (optional; required only for uploads)
            Branch         = ''                 (optional; 'default' is always rejected)
            OutputRoot     = '<rel or abs dir>' (required)
            KeepLast       = 3                  (required; integer >= 1)
            Apps           = @( @{ Name; AppId; Depots = @( @{
                                 Name; DepotId; TargetType; Configuration;
                                 ExpectedExecutable; FileExclusions;
                                 ExtraFiles = @( @{ Source; Destination } );
                                 ServerLauncher = @{ Title; Port; JoinLinePattern;
                                     ServerArguments; ReadyLinePattern; ClientLaunch; LocalHint } } ) } )

        App keys Name, AppId, Depots are required. Depot keys Name, DepotId, TargetType and
        Configuration are required; ExpectedExecutable, FileExclusions, ExtraFiles and
        ServerLauncher are optional.

        ServerLauncher (optional) makes Publish-OgSteamBuild generate a dedicated-server host
        launcher into the depot (New-OgDedicatedServerLauncher). It needs TargetType Server or Game
        and an ExpectedExecutable. Title, Port and JoinLinePattern are required; ServerArguments,
        ReadyLinePattern, ClientLaunch and LocalHint are optional and default to ''. The values are
        checked by Assert-OgServerLauncherSettings; {AppId:<name>} tokens in ClientLaunch must name
        an app of this file.
        Unknown keys at any level are rejected so a misspelt key never passes silently.

        AppId and DepotId must be non-negative integers that fit a uint32; 0 is accepted here as a
        placeholder and rejected by Assert-OgSteamUploadReady before any upload.

        Relative ProjectFile, EngineRoot, OutputRoot and ExtraFiles.Source are resolved against the
        folder that contains the config file. Every error message names the offending key.

    .PARAMETER Path
        Path to the .psd1 config file. Relative paths resolve against the current location.

    .EXAMPLE
        $config = Import-OgSteamConfig -Path .\tools\steam\steam-publish.psd1
        $config.Apps[0].Depots[0].DepotId

    .OUTPUTS
        PSCustomObject with ConfigPath plus every schema key. Apps is an array of PSCustomObjects
        (Name, AppId, Depots); each depot carries AppName and AppId back-references and its
        ExtraFiles entries carry an absolute Source. ServerLauncher is $null or a PSCustomObject
        with all seven keys.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $configPath = [System.IO.Path]::GetFullPath($Path, (Get-Location -PSProvider FileSystem).ProviderPath)
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Steam config '$configPath' does not exist."
    }
    $configDir = Split-Path -Parent $configPath

    try {
        $raw = Import-PowerShellDataFile -LiteralPath $configPath -ErrorAction Stop
    }
    catch {
        throw "Steam config '$configPath' could not be parsed: $($_.Exception.Message)"
    }

    $assertKeys = {
        param([System.Collections.IDictionary] $Table, [string] $Where, [string[]] $Required, [string[]] $Optional)
        $allowed = @($Required) + @($Optional)
        foreach ($key in $Table.Keys) {
            if ($allowed -notcontains $key) {
                throw "Steam config '$configPath': unknown key '$Where$key'. Allowed keys: $($allowed -join ', ')."
            }
        }
        foreach ($key in $Required) {
            if (-not $Table.Contains($key)) {
                throw "Steam config '$configPath': missing required key '$Where$key'."
            }
        }
    }

    $asString = {
        param($Value, [string] $Key, [switch] $AllowEmpty)
        if ($null -eq $Value -and $AllowEmpty) { return '' }
        if ($Value -isnot [string]) {
            throw "Steam config '$configPath': '$Key' must be a string."
        }
        if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value)) {
            throw "Steam config '$configPath': '$Key' must not be empty."
        }
        $Value
    }

    $asInteger = {
        param($Value, [string] $Key, [long] $Min, [long] $Max)
        if (-not ($Value -is [int] -or $Value -is [long])) {
            throw "Steam config '$configPath': '$Key' must be an integer, got '$Value'."
        }
        if ($Value -lt $Min -or $Value -gt $Max) {
            throw "Steam config '$configPath': '$Key' must be between $Min and $Max, got $Value."
        }
        $Value
    }

    $asChoice = {
        param($Value, [string] $Key, [string[]] $Choices)
        $text = & $asString $Value $Key
        $match = $Choices | Where-Object { $_ -eq $text } | Select-Object -First 1
        if ($null -eq $match) {
            throw "Steam config '$configPath': '$Key' must be one of $($Choices -join ', '), got '$text'."
        }
        $match
    }

    $asList = {
        param($Value, [string] $Key)
        if ($null -eq $Value) { return , @() }
        , @($Value)
    }

    $resolve = {
        param([string] $Relative)
        [System.IO.Path]::GetFullPath($Relative, $configDir)
    }

    $uint32Max = [long][uint32]::MaxValue

    & $assertKeys $raw '' `
        @('SchemaVersion', 'ProjectFile', 'Platform', 'OutputRoot', 'KeepLast', 'Apps') `
        @('EngineRoot', 'BuilderAccount', 'Branch')

    $schemaVersion = & $asInteger $raw.SchemaVersion 'SchemaVersion' 0 ([int]::MaxValue)
    if ($schemaVersion -ne 1) {
        throw "Steam config '$configPath': 'SchemaVersion' must be 1, got $schemaVersion."
    }

    $projectFile = & $resolve (& $asString $raw.ProjectFile 'ProjectFile')
    if ([System.IO.Path]::GetExtension($projectFile) -ne '.uproject') {
        throw "Steam config '$configPath': 'ProjectFile' must point to a .uproject file, got '$projectFile'."
    }
    if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
        throw "Steam config '$configPath': 'ProjectFile' '$projectFile' does not exist."
    }

    $engineRoot = & $asString $raw.EngineRoot 'EngineRoot' -AllowEmpty
    if ($engineRoot -ne '') { $engineRoot = & $resolve $engineRoot }

    $platform = & $asChoice $raw.Platform 'Platform' @('Win64')

    $builderAccount = (& $asString $raw.BuilderAccount 'BuilderAccount' -AllowEmpty).Trim()

    $branch = (& $asString $raw.Branch 'Branch' -AllowEmpty).Trim()
    if ($branch -eq 'default') {
        throw "Steam config '$configPath': 'Branch' must not be 'default'. Set the default branch live in the Steamworks web UI."
    }

    $outputRoot = & $resolve (& $asString $raw.OutputRoot 'OutputRoot')

    $keepLast = & $asInteger $raw.KeepLast 'KeepLast' 1 ([int]::MaxValue)

    $rawApps = & $asList $raw.Apps 'Apps'
    if ($rawApps.Count -eq 0) {
        throw "Steam config '$configPath': 'Apps' must contain at least one app."
    }

    $allAppNames = [string[]]@($rawApps | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Name -is [string] } |
            ForEach-Object { $_.Name })

    $apps = [System.Collections.Generic.List[object]]::new()
    $appNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $depotNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    for ($a = 0; $a -lt $rawApps.Count; $a++) {
        $appWhere = "Apps[$a]."
        $rawApp = $rawApps[$a]
        if ($rawApp -isnot [System.Collections.IDictionary]) {
            throw "Steam config '$configPath': 'Apps[$a]' must be a hashtable."
        }
        & $assertKeys $rawApp $appWhere @('Name', 'AppId', 'Depots') @()

        $appName = & $asString $rawApp.Name "${appWhere}Name"
        if (-not $appNames.Add($appName)) {
            throw "Steam config '$configPath': duplicate app name '$appName' at '${appWhere}Name'."
        }
        $appId = [uint32](& $asInteger $rawApp.AppId "${appWhere}AppId" 0 $uint32Max)

        $rawDepots = & $asList $rawApp.Depots "${appWhere}Depots"
        if ($rawDepots.Count -eq 0) {
            throw "Steam config '$configPath': '${appWhere}Depots' must contain at least one depot."
        }

        $depots = [System.Collections.Generic.List[object]]::new()
        for ($d = 0; $d -lt $rawDepots.Count; $d++) {
            $depotWhere = "${appWhere}Depots[$d]."
            $rawDepot = $rawDepots[$d]
            if ($rawDepot -isnot [System.Collections.IDictionary]) {
                throw "Steam config '$configPath': '${appWhere}Depots[$d]' must be a hashtable."
            }
            & $assertKeys $rawDepot $depotWhere `
                @('Name', 'DepotId', 'TargetType', 'Configuration') `
                @('ExpectedExecutable', 'FileExclusions', 'ExtraFiles', 'ServerLauncher')

            $depotName = & $asString $rawDepot.Name "${depotWhere}Name"
            if ($depotName -cnotmatch '^[a-z0-9-]+$') {
                throw "Steam config '$configPath': '${depotWhere}Name' must match ^[a-z0-9-]+$, got '$depotName'."
            }
            if (-not $depotNames.Add($depotName)) {
                throw "Steam config '$configPath': duplicate depot name '$depotName' at '${depotWhere}Name'."
            }

            $depotId = [uint32](& $asInteger $rawDepot.DepotId "${depotWhere}DepotId" 0 $uint32Max)
            $targetType = & $asChoice $rawDepot.TargetType "${depotWhere}TargetType" @('Client', 'Server', 'Game')
            $configuration = & $asChoice $rawDepot.Configuration "${depotWhere}Configuration" @('Development', 'Shipping')

            $expectedExecutable = & $asString $rawDepot.ExpectedExecutable "${depotWhere}ExpectedExecutable" -AllowEmpty
            if ($expectedExecutable -ne '' -and [System.IO.Path]::IsPathRooted($expectedExecutable)) {
                throw "Steam config '$configPath': '${depotWhere}ExpectedExecutable' must be relative to the depot content root, got '$expectedExecutable'."
            }

            $exclusions = & $asList $rawDepot.FileExclusions "${depotWhere}FileExclusions"
            $fileExclusions = [string[]]@(for ($x = 0; $x -lt $exclusions.Count; $x++) {
                    & $asString $exclusions[$x] "${depotWhere}FileExclusions[$x]"
                })

            $rawExtras = & $asList $rawDepot.ExtraFiles "${depotWhere}ExtraFiles"
            $extraFiles = @(for ($e = 0; $e -lt $rawExtras.Count; $e++) {
                    $extraWhere = "${depotWhere}ExtraFiles[$e]."
                    $rawExtra = $rawExtras[$e]
                    if ($rawExtra -isnot [System.Collections.IDictionary]) {
                        throw "Steam config '$configPath': '${depotWhere}ExtraFiles[$e]' must be a hashtable."
                    }
                    & $assertKeys $rawExtra $extraWhere @('Source', 'Destination') @()

                    $source = & $resolve (& $asString $rawExtra.Source "${extraWhere}Source")
                    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                        throw "Steam config '$configPath': '${extraWhere}Source' '$source' does not exist."
                    }
                    $destination = & $asString $rawExtra.Destination "${extraWhere}Destination"
                    if ([System.IO.Path]::IsPathRooted($destination) -or
                        ($destination -split '[\\/]') -contains '..') {
                        throw "Steam config '$configPath': '${extraWhere}Destination' must be a path inside the depot content root, got '$destination'."
                    }

                    [pscustomobject]@{
                        Source      = $source
                        Destination = $destination
                    }
                })

            $serverLauncher = $null
            if ($rawDepot.Contains('ServerLauncher')) {
                $launcherWhere = "${depotWhere}ServerLauncher."
                $rawLauncher = $rawDepot.ServerLauncher
                if ($rawLauncher -isnot [System.Collections.IDictionary]) {
                    throw "Steam config '$configPath': '${depotWhere}ServerLauncher' must be a hashtable."
                }
                & $assertKeys $rawLauncher $launcherWhere `
                    @('Title', 'Port', 'JoinLinePattern') `
                    @('ServerArguments', 'ReadyLinePattern', 'ClientLaunch', 'LocalHint')
                if ($targetType -eq 'Client') {
                    throw "Steam config '$configPath': '${depotWhere}ServerLauncher' needs TargetType Server or Game, got '$targetType'."
                }
                if ($expectedExecutable -eq '') {
                    throw "Steam config '$configPath': '${depotWhere}ServerLauncher' needs '${depotWhere}ExpectedExecutable' (the server exe the launcher starts)."
                }
                $serverLauncher = [pscustomobject]@{
                    Title            = & $asString $rawLauncher.Title "${launcherWhere}Title"
                    Port             = [int](& $asInteger $rawLauncher.Port "${launcherWhere}Port" 1 65535)
                    JoinLinePattern  = & $asString $rawLauncher.JoinLinePattern "${launcherWhere}JoinLinePattern"
                    ServerArguments  = & $asString $rawLauncher.ServerArguments "${launcherWhere}ServerArguments" -AllowEmpty
                    ReadyLinePattern = & $asString $rawLauncher.ReadyLinePattern "${launcherWhere}ReadyLinePattern" -AllowEmpty
                    ClientLaunch     = & $asString $rawLauncher.ClientLaunch "${launcherWhere}ClientLaunch" -AllowEmpty
                    LocalHint        = & $asString $rawLauncher.LocalHint "${launcherWhere}LocalHint" -AllowEmpty
                }
                try {
                    Assert-OgServerLauncherSettings -Title $serverLauncher.Title -Port $serverLauncher.Port `
                        -ServerArguments $serverLauncher.ServerArguments -JoinLinePattern $serverLauncher.JoinLinePattern `
                        -ReadyLinePattern $serverLauncher.ReadyLinePattern -ClientLaunch $serverLauncher.ClientLaunch `
                        -LocalHint $serverLauncher.LocalHint -AppNames $allAppNames -Prefix $launcherWhere
                }
                catch {
                    throw "Steam config '$configPath': $($_.Exception.Message)"
                }
            }

            $depots.Add([pscustomobject]@{
                    Name               = $depotName
                    DepotId            = $depotId
                    TargetType         = $targetType
                    Configuration      = $configuration
                    ExpectedExecutable = $expectedExecutable
                    FileExclusions     = $fileExclusions
                    ExtraFiles         = $extraFiles
                    ServerLauncher     = $serverLauncher
                    AppName            = $appName
                    AppId              = $appId
                })
        }

        $apps.Add([pscustomobject]@{
                Name   = $appName
                AppId  = $appId
                Depots = $depots.ToArray()
            })
    }

    [pscustomobject]@{
        ConfigPath     = $configPath
        SchemaVersion  = $schemaVersion
        ProjectFile    = $projectFile
        EngineRoot     = $engineRoot
        Platform       = $platform
        BuilderAccount = $builderAccount
        Branch         = $branch
        OutputRoot     = $outputRoot
        KeepLast       = [int]$keepLast
        Apps           = $apps.ToArray()
    }
}
