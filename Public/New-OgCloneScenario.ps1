# SPDX-License-Identifier: MPL-2.0
function New-OgCloneScenario {
    <#
    .SYNOPSIS
        Clones a named og-framework working-tree scenario with all submodules populated.

    .DESCRIPTION
        Clones the root repo for the given scenario and recursively initialises all
        submodules. The clone is placed at <Target>/<repo-name>. The four recognised
        scenarios map to fixed og-framework repos (what --recurse-submodules brings in):

          simulation   — og-simulation-tests only (the test sources; it has no submodules)
          brawler      — og-brawler-tests only (the test sources; it has no submodules)
          unreal       — og-brawler-unreal: og-simulation-ue (with og-simulation and, once
                         declared there, og-simulation-jolt), og-brawler-ue (with og-brawler),
                         og-simulation-tests, og-brawler-tests, og-tools
          cmake-runner — og-tests-cmake-runner: og-simulation, og-brawler,
                         og-simulation-tests, og-brawler-tests, og-tools

        og-simulation-jolt sits next to og-simulation inside og-simulation-ue
        (Plugins/OGSimulation/Source/OGSimulationJolt/og-simulation-jolt), so the unreal
        scenario clones it wherever it clones og-simulation. While it is declared only on a
        feature branch, pass -Branch <feature-branch>: after the clone, every repo whose
        origin has that branch is put on it (Sync-OgFramework -Branch), and the submodules
        the branch declares (og-simulation-jolt) are initialised and put on it too.

        If the destination subdirectory already exists the cmdlet throws rather than
        overwriting it. Pass -Verbose to stream git clone progress lines.

    .PARAMETER Scenario
        The scenario to clone. One of: simulation, brawler, unreal, cmake-runner.

    .PARAMETER Target
        Directory under which the scenario root repo will be cloned.
        The clone path is <Target>/<repo-name>. Created if it does not exist.

    .PARAMETER Branch
        After the clone, check out this branch in every repo whose origin has it and
        initialise the submodules it declares. Only alphanumerics, dots, underscores,
        hyphens, and forward slashes are allowed.

    .PARAMETER RemoteBaseUrl
        Base the root repo's clone URL is built from: <RemoteBaseUrl>/<repo-name>.git.
        Defaults to https://github.com/og-framework (tests point it at local bare repos).

    .EXAMPLE
        New-OgCloneScenario -Scenario cmake-runner -Target C:\dev\og-scratch
        # Clones og-tests-cmake-runner + all submodules under C:\dev\og-scratch\.

    .EXAMPLE
        New-OgCloneScenario -Scenario unreal -Target C:\dev\og-scratch -Branch feat/jolt-scheduler
        # Clones og-brawler-unreal, puts every repo that has feat/jolt-scheduler on it, and
        # initialises og-simulation-jolt, which only that branch declares.

    .EXAMPLE
        New-OgCloneScenario -Scenario unreal -Target C:\tmp\ci-clone -WhatIf
        # Shows what would be cloned without touching the filesystem.

    .OUTPUTS
        PSCustomObject — one object:
          Scenario, Path, Branch, RepoCount, Duration, Error ($null on success)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('simulation', 'brawler', 'unreal', 'cmake-runner')]
        [string] $Scenario,

        [Parameter(Mandatory, Position = 1)]
        [string] $Target,

        [Parameter()]
        [ValidatePattern('^[A-Za-z0-9._/-]+$')]
        [string] $Branch,

        [Parameter()]
        [string] $RemoteBaseUrl = 'https://github.com/og-framework'
    )

    $repoMap = @{
        'simulation'   = 'og-simulation-tests'
        'brawler'      = 'og-brawler-tests'
        'unreal'       = 'og-brawler-unreal'
        'cmake-runner' = 'og-tests-cmake-runner'
    }

    $repoName  = $repoMap[$Scenario]
    $remoteUrl = "$($RemoteBaseUrl.TrimEnd('/', '\'))/$repoName.git"
    $resolvedTarget = Resolve-Path -LiteralPath $Target -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProviderPath
    $clonePath = if ($resolvedTarget) { Join-Path $resolvedTarget $repoName } else { Join-Path $Target $repoName }

    $opDesc = "git clone --recurse-submodules $remoteUrl" + $(if ($Branch) { " + sync branch $Branch" } else { '' })
    if (-not $PSCmdlet.ShouldProcess($clonePath, $opDesc)) {
        [PSCustomObject]@{
            Scenario  = $Scenario
            Path      = $clonePath
            Branch    = $Branch
            RepoCount = -1
            Duration  = $null
            Error     = $null
        }
        return
    }

    # Create target dir if needed
    if (-not (Test-Path -LiteralPath $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }

    # Recompute clonePath now that Target is guaranteed to exist
    $clonePath = Join-Path (Resolve-Path -LiteralPath $Target).ProviderPath $repoName

    # Guard: do not overwrite an existing clone
    if (Test-Path -LiteralPath $clonePath) {
        throw "Destination already exists: '$clonePath'. Delete it first or choose a different -Target."
    }

    Write-Verbose "Cloning $remoteUrl -> $clonePath"

    $start  = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-Git -WorkingDirectory $Target `
        -Arguments 'clone', '--recurse-submodules', $remoteUrl, $clonePath

    if ($VerbosePreference -ne 'SilentlyContinue') {
        foreach ($line in ($result.StdErr -split "`n" | Where-Object { $_.Trim() })) {
            Write-Verbose $line
        }
    }

    if ($result.ExitCode -ne 0) {
        $start.Stop()
        $errMsg = $result.StdErr
        Write-Error "Clone failed: $errMsg"
        [PSCustomObject]@{
            Scenario  = $Scenario
            Path      = $clonePath
            Branch    = $Branch
            RepoCount = 0
            Duration  = $start.Elapsed
            Error     = $errMsg
        }
        return
    }

    # Feature branch: put every repo that has it on it, and initialise the submodules
    # only that branch declares.
    $syncError = $null
    if ($Branch) {
        $syncErrors = @()
        $sync = @(Sync-OgFramework -ProjectRoot $clonePath -Branch $Branch -ErrorVariable syncErrors -ErrorAction SilentlyContinue)
        foreach ($s in $sync) { Write-Verbose "$($s.Path): $($s.Action)" }
        if ($syncErrors.Count -gt 0 -or ($sync | Where-Object Action -eq 'failed')) {
            $syncError = "Cloned, but syncing branch '$Branch' failed: " + (($syncErrors | ForEach-Object { "$_" }) -join '; ')
            Write-Error $syncError
        }
    }

    $start.Stop()

    # Count repos: parent + all submodules
    $subStatus = Invoke-Git -WorkingDirectory $clonePath `
        -Arguments 'submodule', 'status', '--recursive'
    $subCount = if ($subStatus.ExitCode -eq 0 -and $subStatus.StdOut) {
        ($subStatus.StdOut -split "`n" | Where-Object { $_.Trim() }).Count
    } else { 0 }

    [PSCustomObject]@{
        Scenario  = $Scenario
        Path      = $clonePath
        Branch    = $Branch
        RepoCount = 1 + $subCount
        Duration  = $start.Elapsed
        Error     = $syncError
    }
}
