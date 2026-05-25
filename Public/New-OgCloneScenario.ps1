# SPDX-License-Identifier: MPL-2.0
function New-OgCloneScenario {
    <#
    .SYNOPSIS
        Clones a named og-framework working-tree scenario with all submodules populated.

    .DESCRIPTION
        Clones the root repo for the given scenario and recursively initialises all
        submodules. The clone is placed at <Target>/<repo-name>. The four recognised
        scenarios map to fixed og-framework remote URLs:

          simulation   — og-simulation-tests (og-simulation pure source included)
          brawler      — og-brawler-tests    (og-brawler + og-simulation pure sources)
          unreal       — og-brawler-unreal   (full UE project with plugin shells + test targets)
          cmake-runner — og-tests-cmake-runner (CMake assembly for both test executables)

        If the destination subdirectory already exists the cmdlet throws rather than
        overwriting it. Pass -Verbose to stream git clone progress lines.

    .PARAMETER Scenario
        The scenario to clone. One of: simulation, brawler, unreal, cmake-runner.

    .PARAMETER Target
        Directory under which the scenario root repo will be cloned.
        The clone path is <Target>/<repo-name>. Created if it does not exist.

    .EXAMPLE
        New-OgCloneScenario -Scenario cmake-runner -Target C:\dev\og-scratch
        # Clones og-tests-cmake-runner + all submodules under C:\dev\og-scratch\.

    .EXAMPLE
        New-OgCloneScenario -Scenario unreal -Target C:\tmp\ci-clone -WhatIf
        # Shows what would be cloned without touching the filesystem.

    .OUTPUTS
        PSCustomObject — one object:
          Scenario, Path, RepoCount, Duration, Error ($null on success)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('simulation', 'brawler', 'unreal', 'cmake-runner')]
        [string] $Scenario,

        [Parameter(Mandatory, Position = 1)]
        [string] $Target
    )

    $repoMap = @{
        'simulation'   = 'og-simulation-tests'
        'brawler'      = 'og-brawler-tests'
        'unreal'       = 'og-brawler-unreal'
        'cmake-runner' = 'og-tests-cmake-runner'
    }

    $repoName  = $repoMap[$Scenario]
    $remoteUrl = "https://github.com/og-framework/$repoName.git"
    $clonePath = Join-Path (Resolve-Path $Target -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProviderPath) $repoName
    if (-not $clonePath) { $clonePath = Join-Path $Target $repoName }

    if (-not $PSCmdlet.ShouldProcess($clonePath, "git clone --recurse-submodules $remoteUrl")) {
        [PSCustomObject]@{
            Scenario  = $Scenario
            Path      = $clonePath
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

    $start.Stop()

    if ($VerbosePreference -ne 'SilentlyContinue') {
        foreach ($line in ($result.StdErr -split "`n" | Where-Object { $_.Trim() })) {
            Write-Verbose $line
        }
    }

    if ($result.ExitCode -ne 0) {
        $errMsg = $result.StdErr
        Write-Error "Clone failed: $errMsg"
        [PSCustomObject]@{
            Scenario  = $Scenario
            Path      = $clonePath
            RepoCount = 0
            Duration  = $start.Elapsed
            Error     = $errMsg
        }
        return
    }

    # Count repos: parent + all submodules
    $subStatus = Invoke-Git -WorkingDirectory $clonePath `
        -Arguments 'submodule', 'status', '--recursive'
    $subCount = if ($subStatus.ExitCode -eq 0 -and $subStatus.StdOut) {
        ($subStatus.StdOut -split "`n" | Where-Object { $_.Trim() }).Count
    } else { 0 }

    [PSCustomObject]@{
        Scenario  = $Scenario
        Path      = $clonePath
        RepoCount = 1 + $subCount
        Duration  = $start.Elapsed
        Error     = $null
    }
}
