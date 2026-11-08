# SPDX-License-Identifier: MPL-2.0

function Import-OgSteamConfig {
    <#
    .SYNOPSIS
        Loads and validates a Steam publish config (.psd1) and returns it with absolute paths.

    .DESCRIPTION
        Reads the file with Import-PowerShellDataFile and validates it against schema version 1
        or 2.

        Schema version 2 separates what is packaged (Builds) from where it goes (the depots of
        each app), so one packaged build can feed several depots:

            SchemaVersion  = 2                  (required)
            ProjectFile, EngineRoot, Platform, BuilderAccount, Branch, OutputRoot, KeepLast
                                                (as in version 1, below)
            Builds         = @( @{ Name; TargetType; Configuration;
                                 ExpectedExecutable; FileExclusions;
                                 ExtraFiles = @( @{ Source; Destination } );
                                 ServerLauncher = @{ ... } } )
            Apps           = @( @{ Name; AppId; Depots = @( @{ Name; DepotId; Build; DepotPath } ) } )
            Profiles       = @{ Default = '<profile>'; <profile> = @('<depot>', ...); ... }   (optional)

        Build keys Name, TargetType and Configuration are required; ExpectedExecutable,
        FileExclusions, ExtraFiles and ServerLauncher are optional. Build names match
        ^[a-z0-9-]+$ and are unique. Depot keys Name, DepotId and Build are required; Build names
        a build of this file. DepotPath (optional, default '.') is the folder inside the app
        install that the build lands in: a relative path with no '..' segment, no wildcard and
        no character a file name cannot hold; '\' and '/' are both accepted and returned as '\'.
        A build that no depot uses only produces a warning.

        Profiles (optional) names sets of depots for Publish-OgSteamBuild -Profile. Default is
        required when Profiles is present and names one of the profiles; every other key is a
        profile name (^[a-z0-9-]+$) whose value lists one or more depot names of this file.

        Schema version 1 keeps every build key on the depot itself:

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

        Each version 1 depot becomes an implicit build named after the depot, with DepotPath '.'.
        Builds, Profiles and DepotPath are version 2 keys and are unknown in version 1.

        App keys Name, AppId, Depots are required. Depot names match ^[a-z0-9-]+$ and are unique
        across all apps. References to builds and depots match case-insensitively and are
        returned in the casing of their definition.

        ServerLauncher (optional) makes Publish-OgSteamBuild generate a dedicated-server host
        launcher into the build (New-OgDedicatedServerLauncher). It needs TargetType Server or
        Game and an ExpectedExecutable. Title, Port and JoinLinePattern are required;
        ServerArguments, ReadyLinePattern, ClientLaunch and LocalHint are optional. ClientLaunch
        is one string or a list of them (the launcher starts the first usable one); a list entry
        must not be empty. The values are checked by Assert-OgServerLauncherSettings;
        {AppId:<name>} tokens in ClientLaunch must name an app of this file.
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
        PSCustomObject with ConfigPath plus every schema key:
          - Builds: PSCustomObjects (Name, TargetType, Configuration, ExpectedExecutable,
            FileExclusions, ExtraFiles, ServerLauncher); one per version 1 depot.
          - Apps: PSCustomObjects (Name, AppId, Depots). Each depot carries Name, DepotId, Build,
            DepotPath, its build's TargetType, Configuration, ExpectedExecutable, FileExclusions,
            ExtraFiles and ServerLauncher, and AppName and AppId back-references.
          - Profiles: PSCustomObjects (Name, Depots), sorted by name; empty without Profiles.
          - DefaultProfile: the Default profile name, or ''.
        ExtraFiles entries carry an absolute Source. ServerLauncher is $null or a PSCustomObject
        with all seven keys; its ClientLaunch is a string array (empty when unset).
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

    $asName = {
        param($Value, [string] $Key)
        $text = & $asString $Value $Key
        if ($text -cnotmatch '^[a-z0-9-]+$') {
            throw "Steam config '$configPath': '$Key' must match ^[a-z0-9-]+$, got '$text'."
        }
        $text
    }

    $resolve = {
        param([string] $Relative)
        [System.IO.Path]::GetFullPath($Relative, $configDir)
    }

    $asDepotPath = {
        param($Value, [string] $Key)
        $text = & $asString $Value $Key
        if ([System.IO.Path]::IsPathRooted($text)) {
            throw "Steam config '$configPath': '$Key' must be a relative path inside the app install, got '$text'."
        }
        $segments = @($text -split '[\\/]' | Where-Object { $_ -ne '' -and $_ -ne '.' })
        if ($segments -contains '..') {
            throw "Steam config '$configPath': '$Key' must not contain a '..' segment, got '$text'."
        }
        if ($text.IndexOfAny([char[]]'*?') -ge 0) {
            throw "Steam config '$configPath': '$Key' must not contain a wildcard (* or ?), got '$text'."
        }
        $invalid = [System.IO.Path]::GetInvalidFileNameChars()
        foreach ($segment in $segments) {
            if ($segment.IndexOfAny($invalid) -ge 0) {
                throw "Steam config '$configPath': '$Key' holds a character a folder name cannot hold, got '$text'."
            }
        }
        if ($segments.Count -eq 0) { return '.' }
        $segments -join '\'
    }

    $readBuild = {
        param([System.Collections.IDictionary] $Table, [string] $Where, [string] $Name, [string[]] $AppNames)
        $targetType = & $asChoice $Table.TargetType "${Where}TargetType" @('Client', 'Server', 'Game')
        $configuration = & $asChoice $Table.Configuration "${Where}Configuration" @('Development', 'Shipping')

        $expectedExecutable = & $asString $Table.ExpectedExecutable "${Where}ExpectedExecutable" -AllowEmpty
        if ($expectedExecutable -ne '' -and [System.IO.Path]::IsPathRooted($expectedExecutable)) {
            throw "Steam config '$configPath': '${Where}ExpectedExecutable' must be relative to the depot content root, got '$expectedExecutable'."
        }

        $exclusions = & $asList $Table.FileExclusions "${Where}FileExclusions"
        $fileExclusions = [string[]]@(for ($x = 0; $x -lt $exclusions.Count; $x++) {
                & $asString $exclusions[$x] "${Where}FileExclusions[$x]"
            })

        $rawExtras = & $asList $Table.ExtraFiles "${Where}ExtraFiles"
        $extraFiles = @(for ($e = 0; $e -lt $rawExtras.Count; $e++) {
                $extraWhere = "${Where}ExtraFiles[$e]."
                $rawExtra = $rawExtras[$e]
                if ($rawExtra -isnot [System.Collections.IDictionary]) {
                    throw "Steam config '$configPath': '${Where}ExtraFiles[$e]' must be a hashtable."
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
        if ($Table.Contains('ServerLauncher')) {
            $launcherWhere = "${Where}ServerLauncher."
            $rawLauncher = $Table.ServerLauncher
            if ($rawLauncher -isnot [System.Collections.IDictionary]) {
                throw "Steam config '$configPath': '${Where}ServerLauncher' must be a hashtable."
            }
            & $assertKeys $rawLauncher $launcherWhere `
                @('Title', 'Port', 'JoinLinePattern') `
                @('ServerArguments', 'ReadyLinePattern', 'ClientLaunch', 'LocalHint')
            if ($targetType -eq 'Client') {
                throw "Steam config '$configPath': '${Where}ServerLauncher' needs TargetType Server or Game, got '$targetType'."
            }
            if ($expectedExecutable -eq '') {
                throw "Steam config '$configPath': '${Where}ServerLauncher' needs '${Where}ExpectedExecutable' (the server exe the launcher starts)."
            }

            $rawLaunch = $rawLauncher.ClientLaunch
            if ($null -eq $rawLaunch -or $rawLaunch -is [string]) {
                $single = & $asString $rawLaunch "${launcherWhere}ClientLaunch" -AllowEmpty
                [string[]]$clientLaunch = @($single | Where-Object { $_ -ne '' })
            }
            else {
                $entries = @($rawLaunch)
                [string[]]$clientLaunch = @(for ($c = 0; $c -lt $entries.Count; $c++) {
                        & $asString $entries[$c] "${launcherWhere}ClientLaunch[$c]"
                    })
            }

            $serverLauncher = [pscustomobject]@{
                Title            = & $asString $rawLauncher.Title "${launcherWhere}Title"
                Port             = [int](& $asInteger $rawLauncher.Port "${launcherWhere}Port" 1 65535)
                JoinLinePattern  = & $asString $rawLauncher.JoinLinePattern "${launcherWhere}JoinLinePattern"
                ServerArguments  = & $asString $rawLauncher.ServerArguments "${launcherWhere}ServerArguments" -AllowEmpty
                ReadyLinePattern = & $asString $rawLauncher.ReadyLinePattern "${launcherWhere}ReadyLinePattern" -AllowEmpty
                ClientLaunch     = $clientLaunch
                LocalHint        = & $asString $rawLauncher.LocalHint "${launcherWhere}LocalHint" -AllowEmpty
            }
            try {
                Assert-OgServerLauncherSettings -Title $serverLauncher.Title -Port $serverLauncher.Port `
                    -ServerArguments $serverLauncher.ServerArguments -JoinLinePattern $serverLauncher.JoinLinePattern `
                    -ReadyLinePattern $serverLauncher.ReadyLinePattern -ClientLaunch $serverLauncher.ClientLaunch `
                    -LocalHint $serverLauncher.LocalHint -AppNames $AppNames -Prefix $launcherWhere
            }
            catch {
                throw "Steam config '$configPath': $($_.Exception.Message)"
            }
        }

        [pscustomobject]@{
            Name               = $Name
            TargetType         = $targetType
            Configuration      = $configuration
            ExpectedExecutable = $expectedExecutable
            FileExclusions     = $fileExclusions
            ExtraFiles         = $extraFiles
            ServerLauncher     = $serverLauncher
        }
    }

    $uint32Max = [long][uint32]::MaxValue
    $buildKeys = @('ExpectedExecutable', 'FileExclusions', 'ExtraFiles', 'ServerLauncher')

    $isVersion2 = ($raw.SchemaVersion -is [int] -or $raw.SchemaVersion -is [long]) -and $raw.SchemaVersion -eq 2
    if ($isVersion2) {
        & $assertKeys $raw '' `
            @('SchemaVersion', 'ProjectFile', 'Platform', 'OutputRoot', 'KeepLast', 'Builds', 'Apps') `
            @('EngineRoot', 'BuilderAccount', 'Branch', 'Profiles')
    }
    else {
        & $assertKeys $raw '' `
            @('SchemaVersion', 'ProjectFile', 'Platform', 'OutputRoot', 'KeepLast', 'Apps') `
            @('EngineRoot', 'BuilderAccount', 'Branch')
    }

    $schemaVersion = & $asInteger $raw.SchemaVersion 'SchemaVersion' 0 ([int]::MaxValue)
    if ($schemaVersion -ne 1 -and $schemaVersion -ne 2) {
        throw "Steam config '$configPath': 'SchemaVersion' must be 1 or 2, got $schemaVersion."
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

    $builds = [System.Collections.Generic.List[object]]::new()
    $buildsByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $buildWhere = @{}
    if ($isVersion2) {
        $rawBuilds = & $asList $raw.Builds 'Builds'
        if ($rawBuilds.Count -eq 0) {
            throw "Steam config '$configPath': 'Builds' must contain at least one build."
        }
        for ($b = 0; $b -lt $rawBuilds.Count; $b++) {
            $where = "Builds[$b]."
            $rawBuild = $rawBuilds[$b]
            if ($rawBuild -isnot [System.Collections.IDictionary]) {
                throw "Steam config '$configPath': 'Builds[$b]' must be a hashtable."
            }
            & $assertKeys $rawBuild $where @('Name', 'TargetType', 'Configuration') $buildKeys
            $buildName = & $asName $rawBuild.Name "${where}Name"
            if ($buildsByName.ContainsKey($buildName)) {
                throw "Steam config '$configPath': duplicate build name '$buildName' at '${where}Name'."
            }
            $build = & $readBuild $rawBuild $where $buildName $allAppNames
            $builds.Add($build)
            $buildsByName[$buildName] = $build
            $buildWhere[$buildName] = "Builds[$b]"
        }
    }

    $apps = [System.Collections.Generic.List[object]]::new()
    $appNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $depotsByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $usedBuilds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

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
            if ($isVersion2) {
                & $assertKeys $rawDepot $depotWhere @('Name', 'DepotId', 'Build') @('DepotPath')
            }
            else {
                & $assertKeys $rawDepot $depotWhere @('Name', 'DepotId', 'TargetType', 'Configuration') $buildKeys
            }

            $depotName = & $asName $rawDepot.Name "${depotWhere}Name"
            if ($depotsByName.ContainsKey($depotName)) {
                throw "Steam config '$configPath': duplicate depot name '$depotName' at '${depotWhere}Name'."
            }
            $depotId = [uint32](& $asInteger $rawDepot.DepotId "${depotWhere}DepotId" 0 $uint32Max)

            if ($isVersion2) {
                $buildRef = & $asString $rawDepot.Build "${depotWhere}Build"
                if (-not $buildsByName.ContainsKey($buildRef)) {
                    throw "Steam config '$configPath': '${depotWhere}Build' names unknown build '$buildRef'. Builds: $(@($builds | ForEach-Object Name) -join ', ')."
                }
                $build = $buildsByName[$buildRef]
                $depotPath = if ($rawDepot.Contains('DepotPath')) { & $asDepotPath $rawDepot.DepotPath "${depotWhere}DepotPath" } else { '.' }
            }
            else {
                $build = & $readBuild $rawDepot $depotWhere $depotName $allAppNames
                $builds.Add($build)
                $buildsByName[$depotName] = $build
                $depotPath = '.'
            }
            $null = $usedBuilds.Add($build.Name)

            $depot = [pscustomobject]@{
                Name               = $depotName
                DepotId            = $depotId
                Build              = $build.Name
                DepotPath          = $depotPath
                TargetType         = $build.TargetType
                Configuration      = $build.Configuration
                ExpectedExecutable = $build.ExpectedExecutable
                FileExclusions     = $build.FileExclusions
                ExtraFiles         = $build.ExtraFiles
                ServerLauncher     = $build.ServerLauncher
                AppName            = $appName
                AppId              = $appId
            }
            $depots.Add($depot)
            $depotsByName[$depotName] = $depot
        }

        $apps.Add([pscustomobject]@{
                Name   = $appName
                AppId  = $appId
                Depots = $depots.ToArray()
            })
    }

    foreach ($build in $builds) {
        if (-not $usedBuilds.Contains($build.Name)) {
            Write-Warning "Steam config '$configPath': build '$($build.Name)' ($($buildWhere[$build.Name])) is not used by any depot, so it is never packaged."
        }
    }

    $profiles = [System.Collections.Generic.List[object]]::new()
    $defaultProfile = ''
    if ($raw.Contains('Profiles')) {
        $rawProfiles = $raw.Profiles
        if ($rawProfiles -isnot [System.Collections.IDictionary]) {
            throw "Steam config '$configPath': 'Profiles' must be a hashtable."
        }
        if (-not $rawProfiles.Contains('Default')) {
            throw "Steam config '$configPath': missing required key 'Profiles.Default'."
        }
        foreach ($key in @($rawProfiles.Keys | Where-Object { $_ -ne 'Default' } | Sort-Object)) {
            $profileName = & $asName $key "Profiles.$key (profile name)"
            $entries = & $asList $rawProfiles[$key] "Profiles.$profileName"
            if ($entries.Count -eq 0) {
                throw "Steam config '$configPath': 'Profiles.$profileName' must name at least one depot."
            }
            $members = [System.Collections.Generic.List[string]]::new()
            for ($p = 0; $p -lt $entries.Count; $p++) {
                $entryKey = "Profiles.$profileName[$p]"
                $depotRef = & $asString $entries[$p] $entryKey
                if (-not $depotsByName.ContainsKey($depotRef)) {
                    throw "Steam config '$configPath': '$entryKey' names unknown depot '$depotRef'. Depots: $(@($depotsByName.Values | ForEach-Object Name) -join ', ')."
                }
                $canonical = $depotsByName[$depotRef].Name
                if (-not $members.Contains($canonical)) { $members.Add($canonical) }
            }
            $profiles.Add([pscustomobject]@{
                    Name   = $profileName
                    Depots = $members.ToArray()
                })
        }
        $defaultRef = & $asString $rawProfiles.Default 'Profiles.Default'
        $defaultMatch = @($profiles | Where-Object { $_.Name -eq $defaultRef }) | Select-Object -First 1
        if ($null -eq $defaultMatch) {
            throw "Steam config '$configPath': 'Profiles.Default' names unknown profile '$defaultRef'. Profiles: $(@($profiles | ForEach-Object Name) -join ', ')."
        }
        $defaultProfile = $defaultMatch.Name
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
        Builds         = $builds.ToArray()
        Apps           = $apps.ToArray()
        Profiles       = $profiles.ToArray()
        DefaultProfile = $defaultProfile
    }
}
