# SPDX-License-Identifier: MPL-2.0
function Publish-OgSteamBuild {
    <#
    .SYNOPSIS
        Packages the builds a Steam publish config's selected depots need, writes the SteamPipe VDFs and uploads each app with steamcmd.

    .DESCRIPTION
        One publish, in this order:
          1. Loads and validates the config (Import-OgSteamConfig). The effective branch is -Branch
             when passed, otherwise the config's Branch. 'default' is always rejected.
          2. Selects the depots this run uploads: -Depots, else the depots of -Profile, else the
             config's default profile (Profiles.Default), else every depot. Only the builds those
             depots use are packaged, each exactly once, however many depots use it. Every
             selected depot of every app shares the one build label of the run.
          3. Partial-app guard: an app with a selected depot must have all of its configured
             depots selected, unless -AllowPartialApp. What Steam does with a depot that an app
             build leaves out is not documented: the depot's previous build could stay installed
             next to the new one, e.g. an old server with a mismatching build label. The guard
             runs before git and packaging, also with -NoUpload and -Preview, so dry runs show it.
          4. Unless -NoUpload: checks the config is upload-ready for the selected depots and their
             apps (real AppIds/DepotIds, a BuilderAccount, no 'default' branch; an app with no
             selected depot may keep the placeholder 0) and resolves steamcmd.exe. Both happen
             before any packaging, so a long cook never precedes a guaranteed upload failure.
          5. Reads the project's git state (git status --porcelain, git rev-parse --short=7 HEAD).
             A dirty tree is refused unless -AllowDirty. The build label is
             yyyyMMdd-HHmmss-<sha7>, with the suffix -dirty when the tree is dirty.
             With -SkipPackage the sha and the dirty flag are read from -BuildLabel instead, and a
             -dirty label is refused unless -AllowDirty.
          6. Packages each selected build with Invoke-OgUnrealPackage into
             <OutputRoot>\<label>\<BuildName> (a schema version 1 depot is a build named after the
             depot) and copies the build's ExtraFiles into its ContentRoot. -SkipPackage reuses
             those folders from an earlier run instead and throws if they are missing.
             Then, also with -SkipPackage, writes <ContentRoot>\build_info.txt into every packaged
             build: UTF-8 without BOM, LF, the lines label=<label>, sha=<sha7>, dirty=true|false
             and created=<UTC time of this run, yyyy-MM-ddTHH:mm:ssZ>. A FileExclusions pattern
             that matches build_info.txt, or an ExtraFiles Destination named build_info.txt, is
             rejected before git and packaging.
             A build with a ServerLauncher key then gets the host launcher from
             New-OgDedicatedServerLauncher (Host Local Playtest.bat, Host Online Playtest.bat,
             host_server.ps1, host_server.settings.psd1) in its ContentRoot, also with -SkipPackage.
             {AppId:<name>} in ClientLaunch is filled from the config's apps. FileExclusions or
             ExtraFiles that would drop or overwrite those files are rejected up front as well.
          7. Writes one app VDF per app with a selected depot, plus one depot VDF per selected
             depot, into <OutputRoot>\<label>\_steam\<AppName>. A depot VDF maps its build's
             ContentRoot to the depot's DepotPath ('.' unless the config sets one) with its build's
             FileExclusions. Desc = -Description (or the label), SetLive = the effective branch and
             BuildOutput <OutputRoot>\<label>\_steam\output.
          8. Unless -NoUpload: runs steamcmd once per written app VDF, attached to the console so
             steamcmd can prompt for the password and the Steam Guard code itself, with exactly
             +login <BuilderAccount> +run_app_build <app vdf> +quit. No password is ever passed.
          9. Deletes the oldest build-label folders in OutputRoot beyond the newest KeepLast. The
             current label is never deleted, and folders whose name is not a build label are
             never touched.

    .PARAMETER ConfigPath
        Path to the Steam publish config (.psd1). See the README section "Steam publishing" for the schema.

    .PARAMETER Profile
        Uploads the depots of this profile from the config's Profiles. Cannot be combined with
        -Depots. Without -Profile and -Depots the config's Profiles.Default is used, or every
        depot when the config has no Profiles.

    .PARAMETER Depots
        Uploads exactly these depots (names from the config). Cannot be combined with -Profile.

    .PARAMETER AllowPartialApp
        Lets an app be uploaded with only some of its depots selected (see the partial-app guard
        in the description).

    .PARAMETER Branch
        Beta branch to set the build live on, overriding the config's Branch. '' uploads without
        setting it live. 'default' is rejected: the default branch is set live only in the Steamworks web UI.

    .PARAMETER Description
        Build description shown in Steamworks. Default: the build label.

    .PARAMETER NoUpload
        Package and write the VDFs only. steamcmd is neither resolved nor run, and placeholder
        IDs (0) and an empty BuilderAccount are accepted.

    .PARAMETER Preview
        Writes Preview "1" into the app VDFs: steamcmd then only builds the manifest and logs
        into the BuildOutput folder and uploads nothing.

    .PARAMETER AllowDirty
        Allows a build from a git tree with uncommitted changes. The label gets the suffix -dirty.

    .PARAMETER SkipPackage
        Reuses the packaged builds of -BuildLabel instead of packaging again; regenerates the VDFs.

    .PARAMETER BuildLabel
        Existing build label under OutputRoot to reuse with -SkipPackage, e.g. 20260926-101500-abc1234.

    .PARAMETER SteamCmdPath
        Explicit steamcmd.exe (or its folder). Default: resolved like Resolve-OgSteamCmd
        ($env:OG_STEAMCMD, the Install-OgSteamCmd location, then PATH).

    .OUTPUTS
        [pscustomobject] with BuildLabel, BuildDirectory, GitSha, Dirty, Profile, Depots,
        Destinations, AppVdfs, Uploaded, Branch, Preview.
        Profile is the profile whose depots were selected, or '' (-Depots, or a config without
        Profiles).
        Depots has one entry per selected depot: Name, AppName, Build, DepotPath, ContentRoot,
        BuildInfoPath, ServerLauncher, SizeBytes, UploadBytes. Depots that use the same build
        share its ContentRoot, build_info.txt, launcher and sizes. ServerLauncher is the
        New-OgDedicatedServerLauncher result, or $null.
        Destinations has one entry per selected depot: App, Depot, Build, DepotPath, UploadBytes.
        SizeBytes is every file in the whole ContentRoot. UploadBytes leaves out the files the
        build's FileExclusions match (Test-OgSteamFileExcluded: paths relative to the ContentRoot,
        '*' spans folders), which is what the depot VDF hands to steamcmd.

    .EXAMPLE
        Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -NoUpload

        Packages the builds of the default profile and writes the VDFs without contacting Steam.

    .EXAMPLE
        Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -Profile release -Preview

        Full Steam-side dry run of the 'release' profile: steamcmd logs in and builds the manifests but uploads nothing.

    .EXAMPLE
        ogsteampublish -ConfigPath .\tools\steam\steam-publish.psd1 -Branch playtest -Description 'Playtest 3'

    .EXAMPLE
        Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -Depots game-client -AllowPartialApp -NoUpload

        Packages only the build of depot game-client, although its app has more depots.

    .EXAMPLE
        Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -SkipPackage -BuildLabel 20260926-101500-abc1234 -NoUpload

        Regenerates the VDFs of an existing build without cooking again.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Package')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $ConfigPath,

        [ValidateNotNullOrEmpty()]
        [string] $Profile,

        [ValidateNotNullOrEmpty()]
        [string[]] $Depots,

        [switch] $AllowPartialApp,

        [AllowEmptyString()]
        [string] $Branch,

        [string] $Description,

        [switch] $NoUpload,

        [switch] $Preview,

        [switch] $AllowDirty,

        [Parameter(Mandatory, ParameterSetName = 'Reuse')]
        [switch] $SkipPackage,

        [Parameter(Mandatory, ParameterSetName = 'Reuse')]
        [ValidatePattern('^\d{8}-\d{6}-[0-9a-f]{7}(-dirty)?$')]
        [string] $BuildLabel,

        [string] $SteamCmdPath
    )

    $labelPattern = '^\d{8}-\d{6}-(?<sha>[0-9a-f]{7})(?<dirty>-dirty)?$'

    if ($PSBoundParameters.ContainsKey('Profile') -and $PSBoundParameters.ContainsKey('Depots')) {
        throw 'Publish-OgSteamBuild: -Profile and -Depots cannot be combined. Pass one of them.'
    }

    $config = Import-OgSteamConfig -Path $ConfigPath

    $effectiveBranch = if ($PSBoundParameters.ContainsKey('Branch')) { $Branch.Trim() } else { [string]$config.Branch }
    if ($effectiveBranch -eq 'default') {
        throw "Publish-OgSteamBuild: branch '$effectiveBranch' is rejected. Set the default branch live in the Steamworks web UI, never from a script."
    }

    $allDepots = @($config.Apps | ForEach-Object { $_.Depots })
    $selectedProfile = ''
    if ($PSBoundParameters.ContainsKey('Depots')) {
        $selectedNames = foreach ($name in $Depots) {
            $match = @($allDepots | Where-Object { $_.Name -eq $name }) | Select-Object -First 1
            if ($null -eq $match) {
                throw "Publish-OgSteamBuild: -Depots names unknown depot '$name'. Depots of '$($config.ConfigPath)': $(@($allDepots | ForEach-Object Name) -join ', ')."
            }
            $match.Name
        }
    }
    else {
        $profileName = if ($PSBoundParameters.ContainsKey('Profile')) { $Profile } else { [string]$config.DefaultProfile }
        if ($PSBoundParameters.ContainsKey('Profile') -and @($config.Profiles).Count -eq 0) {
            throw "Publish-OgSteamBuild: -Profile '$Profile' was passed, but '$($config.ConfigPath)' defines no Profiles. Use -Depots, or add Profiles (SchemaVersion 2)."
        }
        if ($profileName) {
            $chosen = @($config.Profiles | Where-Object { $_.Name -eq $profileName }) | Select-Object -First 1
            if ($null -eq $chosen) {
                throw "Publish-OgSteamBuild: unknown profile '$profileName'. Profiles of '$($config.ConfigPath)': $(@($config.Profiles | ForEach-Object Name) -join ', ')."
            }
            $selectedProfile = $chosen.Name
            $selectedNames = @($chosen.Depots)
        }
        else {
            $selectedNames = @($allDepots | ForEach-Object Name)
        }
    }
    $selected = [System.Collections.Generic.HashSet[string]]::new([string[]]@($selectedNames), [System.StringComparer]::OrdinalIgnoreCase)

    $selectedApps = @($config.Apps | Where-Object { @($_.Depots | Where-Object { $selected.Contains($_.Name) }).Count -gt 0 })
    if (-not $AllowPartialApp) {
        $partial = foreach ($app in $selectedApps) {
            $left = @($app.Depots | Where-Object { -not $selected.Contains($_.Name) } | ForEach-Object Name)
            if ($left.Count -gt 0) { "app '$($app.Name)' leaves out $(($left | ForEach-Object { "'$_'" }) -join ', ')" }
        }
        if (@($partial).Count -gt 0) {
            throw ("Publish-OgSteamBuild: this run uploads only some depots of an app: $(@($partial) -join '; '). " +
                "What Steam does with a depot that an app build leaves out is not documented: its previous build could stay " +
                "installed next to the new one (e.g. an old server with a mismatching build label). Select every depot of " +
                "the app (a profile or -Depots), or pass -AllowPartialApp to upload anyway.")
        }
    }

    $selectedBuildNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($depot in $allDepots) {
        if ($selected.Contains($depot.Name)) { $null = $selectedBuildNames.Add($depot.Build) }
    }
    $selectedBuilds = @($config.Builds | Where-Object { $selectedBuildNames.Contains($_.Name) })
    $unit = if ($config.SchemaVersion -eq 1) { 'depot' } else { 'build' }

    $buildInfoName = 'build_info.txt'
    $launcherNames = @('Host Local Playtest.bat', 'Host Online Playtest.bat', 'host_server.ps1', 'host_server.settings.psd1')
    $appIds = @{}
    foreach ($app in @($config.Apps)) { $appIds[$app.Name] = [long]$app.AppId }
    foreach ($build in @($config.Builds)) {
        $generated = @($buildInfoName)
        if ($build.ServerLauncher) { $generated += $launcherNames }
        foreach ($name in $generated) {
            foreach ($pattern in @($build.FileExclusions)) {
                if (Test-OgSteamFileExcluded -RelativePath $name -Pattern $pattern) {
                    throw "Publish-OgSteamBuild: FileExclusions pattern '$pattern' of $unit '$($build.Name)' matches '$name', which the depot must ship. Narrow the pattern."
                }
            }
            foreach ($extra in @($build.ExtraFiles)) {
                if ($extra -and [string]$extra.Destination -eq $name) {
                    throw "Publish-OgSteamBuild: ExtraFiles Destination '$($extra.Destination)' of $unit '$($build.Name)' is reserved for the generated '$name'."
                }
            }
        }
    }

    $steamCmd = $null
    if (-not $NoUpload) {
        $assertArgs = @{ Config = $config; DepotNames = [string[]]@($selected) }
        if ($PSBoundParameters.ContainsKey('Branch')) { $assertArgs.Branch = $effectiveBranch }
        Assert-OgSteamUploadReady @assertArgs
        $steamCmd = Resolve-OgSteamCmd -Path $SteamCmdPath
    }

    if ($SkipPackage) {
        $label = $BuildLabel
        $match = [regex]::Match($label, $labelPattern)
        $gitSha = $match.Groups['sha'].Value
        $dirty = $match.Groups['dirty'].Success
        if ($dirty -and -not $AllowDirty) {
            throw "Publish-OgSteamBuild: build '$label' was packaged from a dirty git tree. Pass -AllowDirty to publish it anyway."
        }
    }
    else {
        $projectDir = Split-Path -Parent $config.ProjectFile
        $status = Invoke-Git -WorkingDirectory $projectDir -Arguments 'status', '--porcelain'
        if ($status.ExitCode -ne 0) {
            throw "Publish-OgSteamBuild: 'git status' failed in '$projectDir' (exit $($status.ExitCode)): $($status.StdErr)"
        }
        $dirty = -not [string]::IsNullOrWhiteSpace($status.StdOut)
        if ($dirty -and -not $AllowDirty) {
            throw "Publish-OgSteamBuild: the git tree at '$projectDir' has uncommitted changes. Commit them, or pass -AllowDirty to build anyway.`n$($status.StdOut)"
        }

        $head = Invoke-Git -WorkingDirectory $projectDir -Arguments 'rev-parse', '--short=7', 'HEAD'
        if ($head.ExitCode -ne 0 -or $head.StdOut.Trim() -notmatch '^[0-9a-f]{7}$') {
            throw "Publish-OgSteamBuild: 'git rev-parse --short=7 HEAD' failed in '$projectDir' (exit $($head.ExitCode)): $($head.StdErr)"
        }
        $gitSha = $head.StdOut.Trim()
        $label = '{0}-{1}{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $gitSha, $(if ($dirty) { '-dirty' } else { '' })
    }

    $buildDir = Join-Path $config.OutputRoot $label
    if ($SkipPackage) {
        if (-not (Test-Path -LiteralPath $buildDir -PathType Container)) {
            throw "Publish-OgSteamBuild: build '$label' does not exist at '$buildDir'."
        }
    }
    elseif (Test-Path -LiteralPath $buildDir) {
        throw "Publish-OgSteamBuild: build folder '$buildDir' already exists."
    }
    else {
        New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
    }

    $created = [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture)
    $buildInfoText = (@(
            "label=$label"
            "sha=$gitSha"
            "dirty=$(([string]$dirty).ToLowerInvariant())"
            "created=$created"
        ) -join "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    $packaged = @{}
    foreach ($build in $selectedBuilds) {
        $archiveDir = Join-Path $buildDir $build.Name

        if ($SkipPackage) {
            if (-not (Test-Path -LiteralPath $archiveDir -PathType Container)) {
                throw "Publish-OgSteamBuild: $unit '$($build.Name)' of build label '$label' does not exist at '$archiveDir'."
            }
            $cookPlatform = switch ($build.TargetType) {
                'Client' { 'WindowsClient' }
                'Server' { 'WindowsServer' }
                'Game'   { 'Windows' }
            }
            $platformDir = Join-Path $archiveDir $cookPlatform
            $contentRoot = if (Test-Path -LiteralPath $platformDir -PathType Container) { $platformDir } else { $archiveDir }
            if ($build.ExpectedExecutable -and
                -not (Test-Path -LiteralPath (Join-Path $contentRoot $build.ExpectedExecutable) -PathType Leaf)) {
                throw "Publish-OgSteamBuild: $unit '$($build.Name)' of build label '$label' has no '$($build.ExpectedExecutable)' in '$contentRoot'."
            }
        }
        else {
            $packageArgs = @{
                ProjectFile      = $config.ProjectFile
                TargetType       = $build.TargetType
                Configuration    = $build.Configuration
                ArchiveDirectory = $archiveDir
            }
            if ($config.EngineRoot) { $packageArgs.EngineRoot = $config.EngineRoot }
            if ($build.ExpectedExecutable) { $packageArgs.ExpectedExecutable = $build.ExpectedExecutable }
            $package = Invoke-OgUnrealPackage @packageArgs
            $contentRoot = $package.ContentRoot

            foreach ($extra in @($build.ExtraFiles)) {
                $destination = Join-Path $contentRoot $extra.Destination
                $destinationDir = Split-Path -Parent $destination
                if (-not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
                    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
                }
                Copy-Item -LiteralPath $extra.Source -Destination $destination -Force
            }
        }

        $buildInfoPath = Join-Path $contentRoot $buildInfoName
        [System.IO.File]::WriteAllText($buildInfoPath, $buildInfoText, $utf8NoBom)

        $launcher = $null
        if ($build.ServerLauncher) {
            $launcherSettings = $build.ServerLauncher
            $launcher = New-OgDedicatedServerLauncher -Destination $contentRoot -ServerExecutable $build.ExpectedExecutable `
                -ServerArguments $launcherSettings.ServerArguments -Port $launcherSettings.Port `
                -JoinLinePattern $launcherSettings.JoinLinePattern -ReadyLinePattern $launcherSettings.ReadyLinePattern `
                -Title $launcherSettings.Title -ClientLaunch $launcherSettings.ClientLaunch -AppIds $appIds `
                -LocalHint $launcherSettings.LocalHint -Confirm:$false
            if ($launcher.ClientLaunchSkipReason) {
                Write-Warning "Publish-OgSteamBuild: the host launcher of $unit '$($build.Name)' will not start the game: $($launcher.ClientLaunchSkipReason)."
            }
        }

        $contentRootPrefix = $contentRoot.TrimEnd('\') + '\'
        $sizeBytes = [long]0
        $uploadBytes = [long]0
        foreach ($file in @(Get-ChildItem -LiteralPath $contentRoot -File -Recurse -Force)) {
            $sizeBytes += $file.Length
            $relativePath = $file.FullName.Substring($contentRootPrefix.Length)
            if (-not (Test-OgSteamFileExcluded -RelativePath $relativePath -Pattern @($build.FileExclusions))) {
                $uploadBytes += $file.Length
            }
        }
        $packaged[$build.Name] = [pscustomobject]@{
            ContentRoot    = $contentRoot
            BuildInfoPath  = $buildInfoPath
            ServerLauncher = $launcher
            SizeBytes      = $sizeBytes
            UploadBytes    = $uploadBytes
            FileExclusions = @($build.FileExclusions)
        }
    }

    $depotResults = [System.Collections.Generic.List[object]]::new()
    $destinations = [System.Collections.Generic.List[object]]::new()
    foreach ($app in $selectedApps) {
        foreach ($depot in @($app.Depots | Where-Object { $selected.Contains($_.Name) })) {
            $built = $packaged[$depot.Build]
            $depotResults.Add([pscustomobject]@{
                    Name           = $depot.Name
                    AppName        = $app.Name
                    Build          = $depot.Build
                    DepotPath      = $depot.DepotPath
                    ContentRoot    = $built.ContentRoot
                    BuildInfoPath  = $built.BuildInfoPath
                    ServerLauncher = $built.ServerLauncher
                    SizeBytes      = $built.SizeBytes
                    UploadBytes    = $built.UploadBytes
                })
            $destinations.Add([pscustomobject]@{
                    App         = $app.Name
                    Depot       = $depot.Name
                    Build       = $depot.Build
                    DepotPath   = $depot.DepotPath
                    UploadBytes = $built.UploadBytes
                })
        }
    }

    $steamDir = Join-Path $buildDir '_steam'
    $buildOutput = Join-Path $steamDir 'output'
    $vdfDescription = if ($Description) { $Description } else { $label }
    $appVdfs = [System.Collections.Generic.List[object]]::new()
    foreach ($app in $selectedApps) {
        $vdfDepots = @(foreach ($depot in @($app.Depots | Where-Object { $selected.Contains($_.Name) })) {
                $built = $packaged[$depot.Build]
                @{
                    DepotId        = $depot.DepotId
                    Name           = $depot.Name
                    ContentRoot    = $built.ContentRoot
                    DepotPath      = $depot.DepotPath
                    FileExclusions = @($built.FileExclusions)
                }
            })
        $vdf = New-OgSteamBuildVdf -AppId $app.AppId -Description $vdfDescription -BuildOutput $buildOutput `
            -SetLive $effectiveBranch -Preview:$Preview -Depots $vdfDepots `
            -OutputDirectory (Join-Path $steamDir $app.Name)
        $appVdfs.Add([pscustomobject]@{ AppName = $app.Name; AppId = $app.AppId; Path = $vdf })
    }

    if (-not $NoUpload) {
        $steamCmdDir = Split-Path -Parent $steamCmd
        foreach ($appVdf in $appVdfs) {
            $upload = Invoke-OgProcess -FilePath $steamCmd -WorkingDirectory $steamCmdDir -ArgumentList @(
                '+login', $config.BuilderAccount, '+run_app_build', $appVdf.Path, '+quit'
            )
            if ($upload.ExitCode -ne 0) {
                throw "Publish-OgSteamBuild: steamcmd failed for app '$($appVdf.AppName)' ($($appVdf.AppId)) with exit code $($upload.ExitCode). Build logs: $buildOutput"
            }
        }
    }

    $labels = @(Get-ChildItem -LiteralPath $config.OutputRoot -Directory |
            Where-Object { $_.Name -match $labelPattern } |
            Sort-Object -Property Name -Descending)
    $keep = @($labels | Select-Object -First $config.KeepLast | ForEach-Object Name) + $label
    foreach ($old in $labels) {
        if ($keep -notcontains $old.Name) {
            Write-Verbose "Pruning old build '$($old.FullName)'."
            Remove-Item -LiteralPath $old.FullName -Recurse -Force
        }
    }

    [pscustomobject]@{
        BuildLabel     = $label
        BuildDirectory = $buildDir
        GitSha         = $gitSha
        Dirty          = $dirty
        Profile        = $selectedProfile
        Depots         = $depotResults.ToArray()
        Destinations   = $destinations.ToArray()
        AppVdfs        = $appVdfs.ToArray()
        Uploaded       = -not $NoUpload
        Branch         = $effectiveBranch
        Preview        = [bool]$Preview
    }
}
