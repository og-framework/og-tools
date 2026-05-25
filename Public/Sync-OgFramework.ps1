# SPDX-License-Identifier: MPL-2.0
function Sync-OgFramework {
    <#
    .SYNOPSIS
        Fetches all og-framework repos then fast-forward merges each to origin/main.

    .DESCRIPTION
        Runs git fetch --recurse-submodules from the project root, then walks the
        submodule tree deepest-first, checking out main and merging --ff-only on each
        submodule before finally merging the top-level parent. Emits one PSCustomObject
        per repo touched.

        On ff-merge failure the cmdlet writes an error, emits a failed PSObject, and
        stops processing further repos. No partial-merge state is left behind.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .EXAMPLE
        Sync-OgFramework | Format-Table -AutoSize
        # Fetches and fast-forwards all repos in the tree.

    .EXAMPLE
        Sync-OgFramework -WhatIf
        # Shows what each repo would do (checkout + merge) without touching anything.

    .OUTPUTS
        PSCustomObject — one per repo:
          Repo, Path, Action ('fast-forwarded'|'already-current'|'failed'), FromSha, ToSha
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string] $ProjectRoot = (Get-Location).Path
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath

    # Fetch all repos at once
    if ($PSCmdlet.ShouldProcess($ProjectRoot, 'git fetch --recurse-submodules')) {
        $fetchResult = Invoke-Git -WorkingDirectory $ProjectRoot `
            -Arguments 'fetch', '--recurse-submodules'
        if ($fetchResult.ExitCode -ne 0) {
            Write-Warning "fetch --recurse-submodules failed: $($fetchResult.StdErr)"
        }
    }

    $tree = Resolve-OgRepoTree -ProjectRoot $ProjectRoot

    # Separate parent from submodules; process deepest-first (reverse order), parent last
    $parent   = $tree | Where-Object { $_.IsParent }
    $subRepos = $tree | Where-Object { -not $_.IsParent }
    $ordered  = @($subRepos | Sort-Object { ($_.Path -split '/').Count } -Descending) + @($parent)

    foreach ($repo in $ordered) {
        $absPath = $repo.AbsolutePath

        if (-not (Test-Path -LiteralPath $absPath)) {
            Write-Warning "Repo path not found, skipping: $absPath"
            continue
        }

        $fromShaResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', 'HEAD'
        $fromSha = if ($fromShaResult.ExitCode -eq 0) { $fromShaResult.StdOut } else { '(unknown)' }

        $repoLabel = if ($repo.IsParent) { $repo.Name } else { $repo.Path }

        if ($PSCmdlet.ShouldProcess($repoLabel, 'git checkout main + git merge --ff-only origin/main')) {
            $checkoutResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'checkout', 'main'
            if ($checkoutResult.ExitCode -ne 0) {
                # Fallback: create local main tracking origin/main. Handles submodule clones
                # initialised in detached-HEAD with no local main branch.
                $checkoutResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'checkout', '-B', 'main', 'origin/main'
            }
            if ($checkoutResult.ExitCode -ne 0) {
                Write-Error "Failed to checkout main in '$repoLabel': $($checkoutResult.StdErr)"
                [PSCustomObject]@{ PSTypeName = 'Og.SyncResult';
                    Repo    = $repo.Name
                    Path    = $repo.Path
                    Action  = 'failed'
                    FromSha = $fromSha
                    ToSha   = $null
                }
                return
            }

            $mergeResult = Invoke-Git -WorkingDirectory $absPath `
                -Arguments 'merge', '--ff-only', 'origin/main'

            if ($mergeResult.ExitCode -ne 0) {
                Write-Error "ff-merge failed in '$repoLabel': $($mergeResult.StdErr)"
                [PSCustomObject]@{ PSTypeName = 'Og.SyncResult';
                    Repo    = $repo.Name
                    Path    = $repo.Path
                    Action  = 'failed'
                    FromSha = $fromSha
                    ToSha   = $null
                }
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
        } else {
            # -WhatIf: emit intent without executing
            [PSCustomObject]@{ PSTypeName = 'Og.SyncResult';
                Repo    = $repo.Name
                Path    = $repo.Path
                Action  = 'would-sync'
                FromSha = $fromSha
                ToSha   = '(pending)'
            }
        }
    }
}
