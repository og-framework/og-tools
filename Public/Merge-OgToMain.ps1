# SPDX-License-Identifier: MPL-2.0
function Merge-OgToMain {
    <#
    .SYNOPSIS
        Merges a feature branch back into main across the og-framework repo tree,
        deepest-first, with a clean-tree guard and stop-on-conflict.

    .DESCRIPTION
        The inverse of New-OgFeatureBranch. For each repo in the tree (children before
        parents) the cmdlet checks out MainBranch, fast-forwards it to origin, and merges
        the named feature branch in with --no-ff (a real merge commit, so the feature
        history — and every submodule pin commit the superproject recorded — stays
        reachable from main).

        DEEPEST-FIRST is load-bearing: a submodule must be merged before its parent so the
        parent's recorded pin (a feature-branch SHA) is reachable from the child's main
        before the parent is merged. The order matches Push-OgFramework.

        CLEAN-TREE GUARD (pre-flight, read-only): before touching any repo, the cmdlet
        refuses to run if any branch-having repo has uncommitted TRACKED changes — a merge
        could overwrite them. Nothing is merged in that case (fail-fast, no partial state).
        Pass -Force to skip the guard. Untracked files are allowed (a rare untracked/merge
        collision is caught at merge time by the stop-on-conflict path).

        STOP-ON-CONFLICT: if a merge conflicts, the cmdlet runs 'git merge --abort' to
        restore that repo's clean main, records the conflicting files, and HALTS the
        cascade — parents are NOT merged (they would reference an unfinished child). Resolve
        the conflict by hand, then re-run: already-merged children report 'already-merged'
        (idempotent), so the cascade resumes where it stopped.

        DOES NOT ADVANCE PINS. Each child is merged to its own MainBranch, creating a new
        merge commit — but the parent's recorded pin still points at the FEATURE-branch SHA it
        carried before (that reachability is exactly what deepest-first guarantees, and the
        dirty guard below deliberately ignores the resulting gitlink modification so a
        resume-after-conflict re-run is not refused). Run 'oggitadd; oggitcommit'
        (New-OgCommit) after the cascade to advance every pin, then push. Skipping it leaves
        main self-inconsistent: the content is identical, but a fresh clone's
        'git submodule update' checks out feature-branch commits instead of each child's main
        tip.

        NEW SUBMODULES: after a cascade that completes (no conflict or failure), every
        submodule that is now declared on MainBranch but not initialised on disk (typically
        one the feature branch added) is initialised with 'git submodule update --init' in
        its owner and reported with Action='initialised'.

        DOES NOT PUSH. Like Push-OgFramework, this cmdlet is human-run and leaves each repo
        on MainBranch with the merge commit unpushed. Run 'oggitpush' (Push-OgFramework)
        afterward to push every main, children before the superproject.

        FULL SEQUENCE: Merge-OgToMain -> oggitadd; oggitcommit -> oggitpush -> oggitstatus -Fetch

    .PARAMETER Branch
        The feature branch to merge into MainBranch (e.g. the name given to
        New-OgFeatureBranch). Only alphanumerics, dots, underscores, hyphens, and forward
        slashes are allowed.

    .PARAMETER Message
        Merge commit message. Defaults to "Merge <Branch> into <MainBranch>".

    .PARAMETER MainBranch
        The integration branch to merge into. Defaults to 'main'.

    .PARAMETER AllowFastForward
        Permit a fast-forward merge when possible (omit --no-ff). Default is OFF: a --no-ff
        merge commit is always created, which keeps the feature SHAs reachable as a second
        parent (safest for submodule pin resolution and easy revert).

    .PARAMETER DeleteMergedBranch
        After a successful merge in a repo, delete the local feature branch with
        'git branch -d' (safe delete; refuses if not fully merged). Default OFF. Does not
        delete remote branches.

    .PARAMETER Force
        Skip the clean-tree pre-flight guard. Note this only lets the cascade PROCEED — `git merge`
        itself still refuses to start if the working tree has changes it would have to overwrite
        (staged changes, or unstaged edits to a path the merge must update); such a repo reports
        Action='failed' and halts the cascade. -Force is therefore only useful when the dirtiness is
        in files the merge does not touch. Use with care.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .EXAMPLE
        Merge-OgToMain -Branch feature/netcode-v2 | Format-Table -AutoSize
        # Merges feature/netcode-v2 into main in every repo, children first. Then:
        oggitpush   # push every main, deepest-first

    .EXAMPLE
        Merge-OgToMain -Branch feature/netcode-v2 -WhatIf
        # Shows the per-repo plan (would-merge / no-branch) without merging anything.

    .EXAMPLE
        Merge-OgToMain -Branch feature/x -DeleteMergedBranch | Where-Object Action -eq merged
        # Merge and clean up the local feature branch in each repo that merged.

    .OUTPUTS
        PSCustomObject (Og.MergeResult) — one per repo evaluated:
          Repo, Path, Branch, Action, FromSha, ToSha, Conflicts, Error
        Action values:
          'merged'                 — feature branch merged; main advanced
          'already-merged'         — main already contained the branch (no-op)
          'no-branch'              — feature branch does not exist in this repo (skipped)
          'conflict'               — merge conflicted; aborted + tree restored; cascade halted
          'failed'                 — a git step failed (e.g. checkout main); cascade halted
          'skipped-after-conflict' — a deeper repo halted the cascade before this repo
          'would-merge'            — WhatIf preview
          'initialised'            — a submodule new on MainBranch, initialised after the cascade
          'would-init'             — WhatIf preview of the same
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidatePattern('^[A-Za-z0-9._/-]+$')]
        [string] $Branch,

        [Parameter()]
        [string] $Message,

        [Parameter()]
        [string] $MainBranch = 'main',

        [switch] $AllowFastForward,

        [switch] $DeleteMergedBranch,

        [switch] $Force,

        [Parameter()]
        [string] $ProjectRoot = (Get-Location).Path
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
    if (-not $Message) { $Message = "Merge $Branch into $MainBranch" }

    $tree = Resolve-OgRepoTree -ProjectRoot $ProjectRoot

    # Deepest-first; parent last (children merged before parents so parent pins resolve).
    $parent   = $tree | Where-Object { $_.IsParent }
    $subRepos = $tree | Where-Object { -not $_.IsParent }
    $ordered  = @($subRepos | Sort-Object { ($_.Path -split '/').Count } -Descending) + @($parent)

    # ---- PRE-FLIGHT (read-only): branch presence + clean-tree guard ----
    $plan  = [System.Collections.Generic.List[object]]::new()
    $dirty = [System.Collections.Generic.List[string]]::new()
    foreach ($repo in $ordered) {
        $absPath = $repo.AbsolutePath
        # A missing or uninitialised (empty-directory) submodule: git there would act on its owner.
        if (-not (Test-Path -LiteralPath $absPath) -or
            (-not $repo.IsParent -and -not (Test-OgRepoInitialised -AbsolutePath $absPath))) {
            Write-Warning "Repo path not on disk, skipping: $absPath"
            continue
        }

        $hasBranch = (Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--verify', "refs/heads/$Branch").ExitCode -eq 0

        $isDirty = $false
        if ($hasBranch) {
            # Tracked-only dirtiness; untracked files are allowed. `--ignore-submodules=all` is
            # load-bearing: after a child merges, its still-on-feature-branch PARENT shows the
            # submodule gitlink as modified (pin=feature SHA, child now at its merge commit). That
            # is NOT clobberable by `git merge` (it never touches submodule working trees), so it
            # must not count as dirty — otherwise the advertised resume-after-conflict re-run, and
            # any second run, would be refused by this guard.
            $st = Invoke-Git -WorkingDirectory $absPath -Arguments 'status', '--porcelain', '--untracked-files=no', '--ignore-submodules=all'
            $isDirty = ($st.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($st.StdOut))
            if ($isDirty) { $dirty.Add($repo.Name) }
        }

        $plan.Add([PSCustomObject]@{ Repo = $repo; HasBranch = $hasBranch; IsDirty = $isDirty })
    }

    if ($dirty.Count -gt 0 -and -not $Force) {
        Write-Error ("Refusing to merge: uncommitted tracked changes in {0}. Commit or stash them (or pass -Force). No repo was touched." -f ($dirty -join ', '))
        return
    }

    # ---- MERGE PASS (deepest-first, stop on conflict) ----
    $halted = $false
    foreach ($entry in $plan) {
        $repo    = $entry.Repo
        $absPath = $repo.AbsolutePath
        $relPath = $repo.Path.Replace('\', '/')

        if ($halted) {
            [PSCustomObject]@{ PSTypeName = 'Og.MergeResult'
                Repo = $repo.Name; Path = $relPath; Branch = $Branch
                Action = 'skipped-after-conflict'; FromSha = $null; ToSha = $null; Conflicts = @(); Error = $null }
            continue
        }

        if (-not $entry.HasBranch) {
            [PSCustomObject]@{ PSTypeName = 'Og.MergeResult'
                Repo = $repo.Name; Path = $relPath; Branch = $Branch
                Action = 'no-branch'; FromSha = $null; ToSha = $null; Conflicts = @(); Error = $null }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("$($repo.Name) ($MainBranch <- $Branch)", "git checkout $MainBranch + pull --ff-only + merge $Branch")) {
            $mainShaResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', $MainBranch
            $fromSha = if ($mainShaResult.ExitCode -eq 0) { $mainShaResult.StdOut } else { '(unknown)' }
            [PSCustomObject]@{ PSTypeName = 'Og.MergeResult'
                Repo = $repo.Name; Path = $relPath; Branch = $Branch
                Action = 'would-merge'; FromSha = $fromSha; ToSha = $null; Conflicts = @(); Error = $null }
            continue
        }

        # 1) checkout MainBranch
        $co = Invoke-Git -WorkingDirectory $absPath -Arguments 'checkout', $MainBranch
        if ($co.ExitCode -ne 0) {
            Write-Error "$($repo.Name): failed to checkout '$MainBranch': $($co.StdErr)"
            [PSCustomObject]@{ PSTypeName = 'Og.MergeResult'
                Repo = $repo.Name; Path = $relPath; Branch = $Branch
                Action = 'failed'; FromSha = $null; ToSha = $null; Conflicts = @(); Error = $co.StdErr }
            $halted = $true
            continue
        }

        $fromShaResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', 'HEAD'
        $fromSha = if ($fromShaResult.ExitCode -eq 0) { $fromShaResult.StdOut } else { '(unknown)' }

        # 2) pull --ff-only origin MainBranch (soft: get latest main; warn on failure)
        $pull = Invoke-Git -WorkingDirectory $absPath -Arguments 'pull', '--ff-only', 'origin', $MainBranch
        if ($pull.ExitCode -ne 0) {
            Write-Warning "$($repo.Name): 'pull --ff-only origin $MainBranch' did not succeed (merging into local $MainBranch): $($pull.StdErr)"
        }

        # 3) merge the feature branch
        $mergeArgs = @('merge')
        if (-not $AllowFastForward) { $mergeArgs += '--no-ff' }
        $mergeArgs += @('-m', $Message, $Branch)
        $merge = Invoke-Git -WorkingDirectory $absPath -Arguments $mergeArgs

        if ($merge.ExitCode -ne 0) {
            # Distinguish a real CONFLICT (merge started: MERGE_HEAD present and/or unmerged paths)
            # from a REFUSAL where the merge never began (e.g. staged changes, or an untracked file
            # the merge would overwrite). Only a started merge needs --abort; a refusal left the tree
            # untouched, so reporting 'conflict' + aborting there would be wrong (F4).
            $conflicts = @()
            $cf = Invoke-Git -WorkingDirectory $absPath -Arguments 'diff', '--name-only', '--diff-filter=U'
            if ($cf.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($cf.StdOut)) {
                $conflicts = @($cf.StdOut -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
            $mergeStarted = (Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--verify', '--quiet', 'MERGE_HEAD').ExitCode -eq 0

            if ($conflicts.Count -or $mergeStarted) {
                Invoke-Git -WorkingDirectory $absPath -Arguments 'merge', '--abort' | Out-Null
                $conflictDesc = if ($conflicts.Count) { $conflicts -join ', ' } else { $merge.StdErr }
                Write-Error "$($repo.Name): merge conflict merging '$Branch' into '$MainBranch' — aborted, working tree restored. Conflicts: $conflictDesc. Resolve manually, then re-run. Halting cascade (parents NOT merged)."
                $action = 'conflict'
            }
            else {
                Write-Error "$($repo.Name): merge of '$Branch' into '$MainBranch' could not start (no conflict; e.g. local changes would be overwritten): $($merge.StdErr). Halting cascade (parents NOT merged)."
                $action = 'failed'
            }

            [PSCustomObject]@{ PSTypeName = 'Og.MergeResult'
                Repo = $repo.Name; Path = $relPath; Branch = $Branch
                Action = $action; FromSha = $fromSha; ToSha = $null; Conflicts = $conflicts; Error = $merge.StdErr }
            $halted = $true
            continue
        }

        $toShaResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', 'HEAD'
        $toSha = if ($toShaResult.ExitCode -eq 0) { $toShaResult.StdOut } else { '(unknown)' }

        $action = if ($toSha -eq $fromSha -or $merge.StdOut -match 'Already up to date') { 'already-merged' } else { 'merged' }

        if ($DeleteMergedBranch -and $action -eq 'merged') {
            $del = Invoke-Git -WorkingDirectory $absPath -Arguments 'branch', '-d', $Branch
            if ($del.ExitCode -ne 0) {
                Write-Warning "$($repo.Name): merged, but could not delete local branch '$Branch': $($del.StdErr)"
            }
        }

        [PSCustomObject]@{ PSTypeName = 'Og.MergeResult'
            Repo = $repo.Name; Path = $relPath; Branch = $Branch
            Action = $action; FromSha = $fromSha; ToSha = $toSha; Conflicts = @(); Error = $null }
    }

    if (-not $halted) {
        # Submodules that are new on MainBranch (declared, not initialised): bring them onto disk.
        foreach ($init in (Initialize-OgMissingSubmodule -ProjectRoot $ProjectRoot)) {
            [PSCustomObject]@{ PSTypeName = 'Og.MergeResult'
                Repo = $init.Repo; Path = $init.Path; Branch = $MainBranch
                Action = $init.Action; FromSha = $null; ToSha = $init.Sha; Conflicts = @(); Error = $init.Error }
        }

        Write-Verbose ("Merge cascade complete. Each parent's submodule pin on '$MainBranch' references the merged " +
            "feature commit (reachable from the child's '$MainBranch' via the --no-ff merge, so pins RESOLVE and push/clone " +
            "work). The pin is NOT at the child's '$MainBranch' tip yet, so Test-OgPinConsistency will warn. To advance pins " +
            "to the '$MainBranch' tips, run:  oggitadd; oggitcommit -PinMessage 'chore: bump submodule pins to $MainBranch'  " +
            "(New-OgCommit's pre-pass detects the pin-behind and stages it). Then 'oggitpush' to push every '$MainBranch' — " +
            "children before the superproject.")
    }
}
