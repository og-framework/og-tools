# SPDX-License-Identifier: MPL-2.0
function Get-OgRepoStatus {
    <#
    .SYNOPSIS
        Returns the status of every repo in the og-framework submodule tree.

    .DESCRIPTION
        Enumerates all repos recursively via .gitmodules and returns one PSCustomObject
        per repo with: head SHA, pinned SHA, branch, commits ahead/behind origin/main,
        dirty state, pin-sync status, and remote URL health.

        Depth is 0 for the project root, 1 for direct submodules, 2 for nested submodules, etc.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .PARAMETER Fetch
        When set, runs 'git fetch --recurse-submodules' from the project root before
        computing status. Without this, Ahead/Behind reflect the local origin/main ref,
        which may be stale if nobody has fetched recently. Use this when you want fresh
        out-of-date detection without performing an ff-merge (which is what oggitsync does).

    .EXAMPLE
        oggitstatus | Format-Table -AutoSize

    .EXAMPLE
        oggitstatus -Fetch | Where-Object Behind -gt 0
        # Refresh remote refs, then show repos that are behind their remote main.

    .EXAMPLE
        Get-OgRepoStatus | Where-Object Dirty

    .OUTPUTS
        PSCustomObject — one per repo:
          Name, Path, Depth, TreePrefix, Head, Pinned, Branch, Ahead, Behind, Dirty, PinStatus, RemoteOk
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string] $ProjectRoot = (Get-Location).Path,

        [switch] $Fetch
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath

    if ($Fetch) {
        Write-Verbose 'Fetching all remotes (git fetch --recurse-submodules)...'
        $fetchResult = Invoke-Git -WorkingDirectory $ProjectRoot `
            -Arguments 'fetch', '--recurse-submodules', '--quiet'
        if ($fetchResult.ExitCode -ne 0) {
            Write-Warning "git fetch --recurse-submodules returned non-zero: $($fetchResult.StdErr)"
        }
    }

    $tree = Resolve-OgRepoTree -ProjectRoot $ProjectRoot

    foreach ($repo in $tree) {
        $absPath = $repo.AbsolutePath

        if (-not (Test-Path -LiteralPath $absPath)) {
            Write-Warning "Repo path not found on disk, skipping: $absPath"
            continue
        }

        # HEAD SHA (short, 7 chars)
        $headResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', 'HEAD'
        $head       = if ($headResult.ExitCode -eq 0) { $headResult.StdOut } else { '(error)' }

        # Branch
        $branchResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--abbrev-ref', 'HEAD'
        $branch       = if ($branchResult.ExitCode -eq 0) { $branchResult.StdOut } else { '(error)' }
        if ($branch -eq 'HEAD') { $branch = '(detached)' }

        # Ahead / Behind vs origin/main
        $ahead  = $null
        $behind = $null
        $abResult = Invoke-Git -WorkingDirectory $absPath -Arguments `
            'rev-list', '--left-right', '--count', 'origin/main...HEAD'
        if ($abResult.ExitCode -eq 0 -and $abResult.StdOut -match '^(\d+)\s+(\d+)') {
            $behind = [int]$Matches[1]
            $ahead  = [int]$Matches[2]
        }

        # Dirty: any output from --porcelain=v2
        $porcelainResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'status', '--porcelain=v2'
        $dirty = $porcelainResult.ExitCode -eq 0 -and ($porcelainResult.StdOut -ne '')

        # Pinned SHA and PinStatus (for non-parent repos)
        $pinned    = $null
        $pinStatus = 'n/a'

        if (-not $repo.IsParent) {
            # Find the immediate parent git repo for this submodule.
            # Submodule entries are stored in the immediate parent's index — not necessarily
            # the project root — so we walk up until we find a directory with a .git entry.
            $subRelPath = $repo.Path.Replace('\', '/')
            $pathParts  = $subRelPath -split '/'

            $parentAbsPath   = $ProjectRoot
            $pathRelToParent = $subRelPath

            for ($i = $pathParts.Count - 2; $i -ge 0; $i--) {
                $candidateRelPath = ($pathParts[0..$i] -join '/')
                $candidateAbs     = Join-Path $ProjectRoot ($candidateRelPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
                if (Test-Path -LiteralPath (Join-Path $candidateAbs '.git')) {
                    $parentAbsPath   = $candidateAbs
                    $pathRelToParent = ($pathParts[($i + 1)..($pathParts.Count - 1)] -join '/')
                    break
                }
            }

            $lsResult2 = Invoke-Git -WorkingDirectory $parentAbsPath `
                -Arguments 'ls-tree', 'HEAD', '--', $pathRelToParent

            if ($lsResult2.ExitCode -eq 0 -and $lsResult2.StdOut -match '\b([0-9a-f]{40})\b') {
                $pinnedFull = $Matches[1]
                $pinned     = $pinnedFull.Substring(0, 7)

                $headFull = (Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', 'HEAD').StdOut
                if ($headFull -eq $pinnedFull) {
                    $pinStatus = 'in-sync'
                } else {
                    $ancestorCheck = Invoke-Git -WorkingDirectory $absPath `
                        -Arguments 'merge-base', '--is-ancestor', $pinnedFull, $headFull
                    if ($ancestorCheck.ExitCode -eq 0) {
                        $pinStatus = 'parent-behind'
                    } else {
                        $ancestorCheck2 = Invoke-Git -WorkingDirectory $absPath `
                            -Arguments 'merge-base', '--is-ancestor', $headFull, $pinnedFull
                        if ($ancestorCheck2.ExitCode -eq 0) {
                            $pinStatus = 'parent-ahead'
                        } else {
                            Write-Warning "Divergent histories between HEAD ($($head)) and pinned ($pinned) in $($repo.Path)"
                            $pinStatus = 'parent-behind'
                        }
                    }
                }
            }
        }

        # Remote URL — must match https://github.com/og-framework/*.git
        $remoteOk     = $false
        $remoteResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'remote', 'get-url', 'origin'
        if ($remoteResult.ExitCode -eq 0) {
            $remoteOk = $remoteResult.StdOut -match '^https://github\.com/og-framework/[^/]+\.git$'
        }

        [PSCustomObject]@{
            PSTypeName = 'Og.RepoStatus'
            Name       = $repo.Name
            Path       = $repo.Path
            Depth      = $repo.Depth
            TreePrefix = $repo.TreePrefix
            Head       = $head
            Pinned     = $pinned
            Branch     = $branch
            Ahead      = $ahead
            Behind     = $behind
            Dirty      = $dirty
            PinStatus  = $pinStatus
            RemoteOk   = $remoteOk
        }
    }
}
