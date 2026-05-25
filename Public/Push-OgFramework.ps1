# SPDX-License-Identifier: MPL-2.0
function Push-OgFramework {
    <#
    .SYNOPSIS
        Pushes all og-framework repos deepest-first.

    .DESCRIPTION
        Per OGRepoRefactor norm, human contributors push manually; agents never invoke
        this cmdlet. It exists for documentation/composability and for future CI use on
        bot identities.

        Walks Resolve-OgRepoTree deepest-first and pushes each repo with unpushed
        commits individually. Does NOT rely on `git push --recurse-submodules=on-demand`,
        which by design only descends one level — further recursion requires the nested
        submodule's own local config to set `push.recurseSubmodules=on-demand` (see
        https://git-scm.com/docs/git-push). For a 2+ level tree we'd silently leave deep
        commits unpushed, breaking submodule pin chains on the remote.

        On the first push failure the cmdlet stops the cascade so parents that reference
        unpushed children are never pushed.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .EXAMPLE
        Push-OgFramework -WhatIf
        # Shows which repos would be pushed and how many commits each, without pushing.

    .EXAMPLE
        Push-OgFramework | Where-Object Action -eq pushed | Format-Table -AutoSize
        # Pushes and shows only repos where commits were sent.

    .OUTPUTS
        PSCustomObject — one per repo touched:
          Repo, Path, Branch, Action, CommitsPushed, FromSha, ToSha, Error
        Action values:
          'pushed'              — push succeeded
          'already-up-to-date'  — no commits ahead of origin
          'skipped-detached'    — HEAD detached; can't push
          'skipped-no-remote'   — no origin configured
          'failed'              — push attempted but failed (cascade stops)
          'would-push'          — WhatIf preview
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string] $ProjectRoot = (Get-Location).Path
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
    $tree        = Resolve-OgRepoTree -ProjectRoot $ProjectRoot

    # Deepest-first; parent last
    $parent   = $tree | Where-Object { $_.IsParent }
    $subRepos = $tree | Where-Object { -not $_.IsParent }
    $ordered  = @($subRepos | Sort-Object { ($_.Path -split '/').Count } -Descending) + @($parent)

    foreach ($repo in $ordered) {
        $absPath = $repo.AbsolutePath
        if (-not (Test-Path -LiteralPath $absPath)) { continue }

        # Branch detection (detached HEAD => 'HEAD')
        $branchResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--abbrev-ref', 'HEAD'
        $branch       = if ($branchResult.ExitCode -eq 0) { $branchResult.StdOut } else { $null }

        if ([string]::IsNullOrEmpty($branch) -or $branch -eq 'HEAD') {
            Write-Warning "$($repo.Name): detached HEAD; skipping push."
            [PSCustomObject]@{ PSTypeName = 'Og.PushResult';
                Repo          = $repo.Name
                Path          = $repo.Path
                Branch        = '(detached)'
                Action        = 'skipped-detached'
                CommitsPushed = 0
                FromSha       = $null
                ToSha         = $null
                Error         = $null
            }
            continue
        }

        # Origin remote check
        $remoteResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'remote', 'get-url', 'origin'
        if ($remoteResult.ExitCode -ne 0) {
            Write-Warning "$($repo.Name): no 'origin' remote configured; skipping push."
            [PSCustomObject]@{ PSTypeName = 'Og.PushResult';
                Repo          = $repo.Name
                Path          = $repo.Path
                Branch        = $branch
                Action        = 'skipped-no-remote'
                CommitsPushed = 0
                FromSha       = $null
                ToSha         = $null
                Error         = $null
            }
            continue
        }

        # Compute HEAD and ahead count vs origin/<branch>
        $headShaResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', 'HEAD'
        $headSha       = if ($headShaResult.ExitCode -eq 0) { $headShaResult.StdOut } else { '(unknown)' }

        $remoteRef       = "origin/$branch"
        $remoteShaResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', $remoteRef
        $fromSha         = $null
        $ahead           = 0
        if ($remoteShaResult.ExitCode -eq 0) {
            $fromSha = $remoteShaResult.StdOut
            $countResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-list', '--count', "$remoteRef..HEAD"
            if ($countResult.ExitCode -eq 0 -and $countResult.StdOut -match '^\d+$') {
                $ahead = [int]$countResult.StdOut
            }
        } else {
            # origin/<branch> doesn't exist — first push of this branch. Treat as ahead.
            $ahead = 1
        }

        if ($ahead -eq 0) {
            [PSCustomObject]@{ PSTypeName = 'Og.PushResult';
                Repo          = $repo.Name
                Path          = $repo.Path
                Branch        = $branch
                Action        = 'already-up-to-date'
                CommitsPushed = 0
                FromSha       = $headSha
                ToSha         = $headSha
                Error         = $null
            }
            continue
        }

        $whatIfTarget = "$($repo.Name) ($branch, $ahead commit$(if ($ahead -ne 1) { 's' }))"
        if (-not $PSCmdlet.ShouldProcess($whatIfTarget, "git push origin $branch")) {
            [PSCustomObject]@{ PSTypeName = 'Og.PushResult';
                Repo          = $repo.Name
                Path          = $repo.Path
                Branch        = $branch
                Action        = 'would-push'
                CommitsPushed = $ahead
                FromSha       = $fromSha
                ToSha         = $headSha
                Error         = $null
            }
            continue
        }

        $pushResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'push', 'origin', $branch
        if ($pushResult.ExitCode -eq 0) {
            [PSCustomObject]@{ PSTypeName = 'Og.PushResult';
                Repo          = $repo.Name
                Path          = $repo.Path
                Branch        = $branch
                Action        = 'pushed'
                CommitsPushed = $ahead
                FromSha       = $fromSha
                ToSha         = $headSha
                Error         = $null
            }
        } else {
            Write-Error "Push failed for $($repo.Name): $($pushResult.StdErr)"
            [PSCustomObject]@{ PSTypeName = 'Og.PushResult';
                Repo          = $repo.Name
                Path          = $repo.Path
                Branch        = $branch
                Action        = 'failed'
                CommitsPushed = 0
                FromSha       = $fromSha
                ToSha         = $headSha
                Error         = $pushResult.StdErr
            }
            return  # STOP cascade — don't push parents that reference unpushed children
        }
    }
}
