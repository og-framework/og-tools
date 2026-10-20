# SPDX-License-Identifier: MPL-2.0
function Sync-OgFramework {
    <#
    .SYNOPSIS
        Fetches all og-framework repos, initialises submodules that are new on disk, then
        fast-forward merges each repo to origin/main (or to origin/<Branch> with -Branch).

    .DESCRIPTION
        Runs git fetch --recurse-submodules from the project root, then walks the
        submodule tree deepest-first, checking out main and merging --ff-only on each
        submodule before finally merging the top-level parent. Emits one PSCustomObject
        per repo touched.

        MISSING SUBMODULES: a submodule declared in an owner's .gitmodules but not
        initialised on disk (for example one that another clone added) is initialised with
        'git submodule update --init' in its owner, and reported with Action='initialised'.
        This runs twice: right after the fetch (submodules already declared locally), and
        again after the merges (submodules the merges just brought in). Each repo
        initialised by the second pass is then synced like the others.

        -Branch MODE: checks out <Branch> and fast-forwards it to origin/<Branch> in every
        repo whose origin has that branch, instead of main. A repo without origin/<Branch>
        is left untouched and reported with Action='no-branch'. Without -Branch the
        behaviour is unchanged (every repo goes to main).

        On ff-merge failure the cmdlet writes an error, emits a failed PSObject, and
        stops processing further repos. No partial-merge state is left behind.

    .PARAMETER Branch
        Sync this branch instead of main, in every repo whose origin has it. Only
        alphanumerics, dots, underscores, hyphens, and forward slashes are allowed.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .EXAMPLE
        Sync-OgFramework | Format-Table -AutoSize
        # Fetches, initialises any new submodule, and fast-forwards all repos to main.

    .EXAMPLE
        oggitsync -Branch feat/jolt-scheduler
        # Puts every repo that has feat/jolt-scheduler on origin onto that branch, fast-forwarded.

    .EXAMPLE
        Sync-OgFramework -WhatIf
        # Shows what each repo would do (init, checkout + merge) without touching anything.

    .OUTPUTS
        PSCustomObject — one per repo:
          Repo, Path, Action ('fast-forwarded'|'already-current'|'initialised'|'no-branch'|
          'failed'|'would-sync'|'would-init'), FromSha, ToSha
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string] $ProjectRoot = (Get-Location).Path,

        [Parameter()]
        [ValidatePattern('^[A-Za-z0-9._/-]+$')]
        [string] $Branch
    )

    $ProjectRoot  = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
    $targetBranch = if ($Branch) { $Branch } else { 'main' }

    # Fetch all repos at once
    if ($PSCmdlet.ShouldProcess($ProjectRoot, 'git fetch --recurse-submodules')) {
        $fetchResult = Invoke-Git -WorkingDirectory $ProjectRoot `
            -Arguments 'fetch', '--recurse-submodules'
        if ($fetchResult.ExitCode -ne 0) {
            Write-Warning "fetch --recurse-submodules failed: $($fetchResult.StdErr)"
        }
    }

    # Converts an Initialize-OgMissingSubmodule result into a sync result.
    $toSyncResult = {
        param($init)
        [PSCustomObject]@{ PSTypeName = 'Og.SyncResult';
            Repo    = $init.Repo
            Path    = $init.Path
            Action  = $init.Action
            FromSha = $null
            ToSha   = $init.Sha
        }
    }

    # Syncs one repo and emits its result. On failure it sets $failed (passed as [ref]) so
    # the caller stops the cascade.
    $syncRepo = {
        param($repo, [ref] $failed)

        $absPath   = $repo.AbsolutePath
        $repoLabel = if ($repo.IsParent) { $repo.Name } else { $repo.Path }

        if (-not $repo.IsParent -and -not (Test-OgRepoInitialised -AbsolutePath $absPath)) {
            # Never run git in an empty submodule directory: it would act on the owner.
            Write-Warning "Repo not initialised on disk, skipping: $absPath"
            return
        }

        $fromShaResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', 'HEAD'
        $fromSha = if ($fromShaResult.ExitCode -eq 0) { $fromShaResult.StdOut } else { '(unknown)' }

        if ($Branch) {
            $remoteHas = (Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--verify', '--quiet', "refs/remotes/origin/$Branch").ExitCode -eq 0
            if (-not $remoteHas) {
                Write-Verbose "'$repoLabel' has no origin/$Branch; left as is."
                [PSCustomObject]@{ PSTypeName = 'Og.SyncResult';
                    Repo    = $repo.Name
                    Path    = $repo.Path
                    Action  = 'no-branch'
                    FromSha = $fromSha
                    ToSha   = $fromSha
                }
                return
            }
        }

        if (-not $PSCmdlet.ShouldProcess($repoLabel, "git checkout $targetBranch + git merge --ff-only origin/$targetBranch")) {
            # -WhatIf: emit intent without executing
            [PSCustomObject]@{ PSTypeName = 'Og.SyncResult';
                Repo    = $repo.Name
                Path    = $repo.Path
                Action  = 'would-sync'
                FromSha = $fromSha
                ToSha   = '(pending)'
            }
            return
        }

        $checkoutResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'checkout', $targetBranch
        if ($checkoutResult.ExitCode -ne 0) {
            # Fallback: create the local branch tracking origin. Handles submodule clones
            # initialised in detached-HEAD with no local branch.
            $checkoutResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'checkout', '-B', $targetBranch, "origin/$targetBranch"
        }
        if ($checkoutResult.ExitCode -ne 0) {
            Write-Error "Failed to checkout $targetBranch in '$repoLabel': $($checkoutResult.StdErr)"
            [PSCustomObject]@{ PSTypeName = 'Og.SyncResult';
                Repo    = $repo.Name
                Path    = $repo.Path
                Action  = 'failed'
                FromSha = $fromSha
                ToSha   = $null
            }
            $failed.Value = $true
            return
        }

        $mergeResult = Invoke-Git -WorkingDirectory $absPath `
            -Arguments 'merge', '--ff-only', "origin/$targetBranch"

        if ($mergeResult.ExitCode -ne 0) {
            Write-Error "ff-merge failed in '$repoLabel': $($mergeResult.StdErr)"
            [PSCustomObject]@{ PSTypeName = 'Og.SyncResult';
                Repo    = $repo.Name
                Path    = $repo.Path
                Action  = 'failed'
                FromSha = $fromSha
                ToSha   = $null
            }
            $failed.Value = $true
            return
        }

        $toShaResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', 'HEAD'
        $toSha = if ($toShaResult.ExitCode -eq 0) { $toShaResult.StdOut } else { $fromSha }

        $action = if ($toSha -eq $fromSha) { 'already-current' } else { 'fast-forwarded' }

        [PSCustomObject]@{ PSTypeName = 'Og.SyncResult';
            Repo    = $repo.Name
            Path    = $repo.Path
            Action  = $action
            FromSha = $fromSha
            ToSha   = $toSha
        }
    }

    $deepestFirst = {
        param($nodes)
        $parent   = @($nodes | Where-Object { $_.IsParent })
        $subRepos = @($nodes | Where-Object { -not $_.IsParent })
        @($subRepos | Sort-Object { ($_.Path -split '/').Count } -Descending) + $parent
    }

    # Pass 1: submodules already declared on disk but never initialised.
    $pass1Paths = [System.Collections.Generic.List[string]]::new()
    foreach ($init in (Initialize-OgMissingSubmodule -ProjectRoot $ProjectRoot)) {
        $pass1Paths.Add($init.Path)
        & $toSyncResult $init
    }

    $tree    = Resolve-OgRepoTree -ProjectRoot $ProjectRoot
    $ordered = & $deepestFirst $tree
    $failed  = $false

    foreach ($repo in $ordered) {
        & $syncRepo $repo ([ref] $failed)
        if ($failed) { return }
    }

    # Pass 2: submodules that the merges above just declared (pass 1 already reported the
    # rest, so it is not retried). Sync each new repo too.
    $newPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($init in (Initialize-OgMissingSubmodule -ProjectRoot $ProjectRoot -SkipPath $pass1Paths)) {
        & $toSyncResult $init
        if ($init.Action -eq 'initialised') { $newPaths.Add($init.Path) }
    }
    if ($newPaths.Count -eq 0) { return }

    $newRepos = @(Resolve-OgRepoTree -ProjectRoot $ProjectRoot | Where-Object { $newPaths -contains $_.Path })
    foreach ($repo in (& $deepestFirst $newRepos)) {
        & $syncRepo $repo ([ref] $failed)
        if ($failed) { return }
    }
}
