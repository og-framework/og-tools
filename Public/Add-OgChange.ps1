# SPDX-License-Identifier: MPL-2.0
function Add-OgChange {
    <#
    .SYNOPSIS
        Stages working-tree changes across all dirty repos in the og-framework tree.

    .DESCRIPTION
        Walks the repo tree resolved from the project root's .gitmodules chain and
        runs `git add -A` in every repo that has working-tree changes (Dirty=$true).

        This is the first step in the canonical og-tools commit workflow:
          oggitadd; oggitcommit -Message "feat: ..."; oggitpush

        Does NOT pre-stage pin advances — that is New-OgCommit's job, which stages
        each parent's submodule pointer update after committing the child.

    .PARAMETER Path
        Optional. Relative path(s) from the project root. When specified, only stages
        changes within the repo(s) that own the given paths. Paths may refer to files
        or directories.

    .PARAMETER All
        Explicit switch that mirrors the default behavior (stage all dirty repos).
        Provided for clarity in scripts; has no additional effect when -Path is absent.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .EXAMPLE
        oggitadd
        # Stages all working-tree changes in every dirty repo across the tree.

    .EXAMPLE
        Add-OgChange
        # Equivalent to 'oggitadd' — stages all dirty repos.

    .EXAMPLE
        Add-OgChange -Path "Plugins/OGSimulation/Source/OGSimulation/og-simulation/OGSimulation.cpp"
        # Stages only the owning repo (og-simulation) for that specific file.

    .EXAMPLE
        # Canonical workflow:
        oggitadd
        oggitcommit -Message "feat: add position prediction to simulation"
        # (user runs) oggitpush

    .OUTPUTS
        PSCustomObject — one per repo touched:
          Repo, Path, FilesStaged (int), Action ('staged'|'nothing-to-stage'|'failed')
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string[]] $Path,

        [switch] $All,

        [string] $ProjectRoot = (Get-Location).Path
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
    $tree = @(Resolve-OgRepoTree -ProjectRoot $ProjectRoot)

    if ($Path -and $Path.Count -gt 0) {
        # Path-scoped mode: for each path find the owning repo (deepest match)
        $reposToStage = [System.Collections.Generic.List[hashtable]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($p in $Path) {
            $normalised = $p.Replace('\', '/')

            # Find the deepest repo whose path is a prefix of the given path
            $ownerNode  = $null
            $ownerDepth = -1
            foreach ($node in $tree) {
                $nodePath = $node.Path.Replace('\', '/')
                if ($nodePath -eq '') {
                    # project root matches everything
                    if ($ownerDepth -lt 0) {
                        $ownerNode  = $node
                        $ownerDepth = 0
                    }
                } elseif ($normalised -eq $nodePath -or $normalised.StartsWith($nodePath + '/')) {
                    $depth = ($nodePath -split '/').Count
                    if ($depth -gt $ownerDepth) {
                        $ownerNode  = $node
                        $ownerDepth = $depth
                    }
                }
            }

            if (-not $ownerNode) {
                Write-Warning "Could not locate owning repo for path: $p"
                continue
            }

            if (-not $seen.Add($ownerNode.AbsolutePath)) { continue }

            # Compute path relative to owning repo
            $ownerRelPath = $ownerNode.Path.Replace('\', '/')
            $fileRelToOwner = if ($ownerRelPath -eq '') {
                $normalised
            } else {
                $normalised.Substring($ownerRelPath.Length).TrimStart('/')
            }

            $reposToStage.Add(@{ Node = $ownerNode; AddArgs = @('add', $fileRelToOwner) })
        }

        foreach ($entry in $reposToStage) {
            $node    = $entry.Node
            $absPath = $node.AbsolutePath
            $name    = $node.Name

            if (-not (Test-Path -LiteralPath $absPath)) {
                Write-Warning "Repo path not on disk, skipping: $absPath"
                continue
            }

            $target = if ($node.Path) { "$name ($($node.Path))" } else { $name }
            if (-not $PSCmdlet.ShouldProcess($target, "git add $($entry.AddArgs[1])")) {
                [PSCustomObject]@{ PSTypeName = 'Og.AddResult';
                    Repo        = $name
                    Path        = $node.Path
                    FilesStaged = 0
                    Action      = 'would-stage'
                }
                continue
            }

            $addResult = Invoke-Git -WorkingDirectory $absPath -Arguments $entry.AddArgs
            if ($addResult.ExitCode -ne 0) {
                Write-Error "git add failed in '$name': $($addResult.StdErr)"
                [PSCustomObject]@{ PSTypeName = 'Og.AddResult';
                    Repo        = $name
                    Path        = $node.Path
                    FilesStaged = 0
                    Action      = 'failed'
                }
                continue
            }

            # Count newly staged files
            $diffResult  = Invoke-Git -WorkingDirectory $absPath -Arguments 'diff', '--cached', '--name-only'
            $filesStaged = if ($diffResult.ExitCode -eq 0 -and $diffResult.StdOut) {
                ($diffResult.StdOut -split "`n" | Where-Object { $_ -ne '' }).Count
            } else { 0 }

            [PSCustomObject]@{ PSTypeName = 'Og.AddResult';
                Repo        = $name
                Path        = $node.Path
                FilesStaged = $filesStaged
                Action      = if ($filesStaged -gt 0) { 'staged' } else { 'nothing-to-stage' }
            }
        }
    } else {
        # Default mode: stage all dirty repos
        foreach ($node in $tree) {
            $absPath = $node.AbsolutePath
            $name    = $node.Name

            if (-not (Test-Path -LiteralPath $absPath)) {
                Write-Warning "Repo path not on disk, skipping: $absPath"
                continue
            }

            # Check dirty state (working tree, not index)
            $statusResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'status', '--porcelain=v2'
            $isDirty = $statusResult.ExitCode -eq 0 -and ($statusResult.StdOut -ne '')
            if (-not $isDirty) {
                [PSCustomObject]@{ PSTypeName = 'Og.AddResult';
                    Repo        = $name
                    Path        = $node.Path
                    FilesStaged = 0
                    Action      = 'nothing-to-stage'
                }
                continue
            }

            $target = if ($node.Path) { "$name ($($node.Path))" } else { $name }
            if (-not $PSCmdlet.ShouldProcess($target, 'git add -A')) {
                [PSCustomObject]@{ PSTypeName = 'Og.AddResult';
                    Repo        = $name
                    Path        = $node.Path
                    FilesStaged = 0
                    Action      = 'would-stage'
                }
                continue
            }

            $addResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'add', '-A'
            if ($addResult.ExitCode -ne 0) {
                Write-Error "git add -A failed in '$name': $($addResult.StdErr)"
                [PSCustomObject]@{ PSTypeName = 'Og.AddResult';
                    Repo        = $name
                    Path        = $node.Path
                    FilesStaged = 0
                    Action      = 'failed'
                }
                continue
            }

            $diffResult  = Invoke-Git -WorkingDirectory $absPath -Arguments 'diff', '--cached', '--name-only'
            $filesStaged = if ($diffResult.ExitCode -eq 0 -and $diffResult.StdOut) {
                ($diffResult.StdOut -split "`n" | Where-Object { $_ -ne '' }).Count
            } else { 0 }

            [PSCustomObject]@{ PSTypeName = 'Og.AddResult';
                Repo        = $name
                Path        = $node.Path
                FilesStaged = $filesStaged
                Action      = if ($filesStaged -gt 0) { 'staged' } else { 'nothing-to-stage' }
            }
        }
    }
}
