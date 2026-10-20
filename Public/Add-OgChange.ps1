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

        EMBEDDED-REPO GUARD: before staging in a repo, the cmdlet looks for untracked
        directories that hold their own '.git' but are NOT declared in that repo's
        .gitmodules (for example a submodule that exists only on a feature branch, left on
        disk after checking out main). Each one is excluded from the add with a
        ':(exclude)<path>' pathspec and named in a warning. Without the guard git would
        stage it as an embedded gitlink with no .gitmodules entry, a pin no other clone can
        resolve. Use Add-OgSubmodule (oggitsubadd) to add such a repo properly.

    .PARAMETER Path
        Optional. Relative path(s) from the project root. When specified, only stages
        changes within the repo(s) that own the given paths. Paths may refer to files
        or directories.

    .PARAMETER All
        Explicit switch that mirrors the default behavior (stage all dirty repos).
        Provided for clarity in scripts; has no additional effect when -Path is absent.

    .PARAMETER IntentToAdd
        Pass `-N` to git add instead of staging content. Registers files as
        "intended to be added" without staging any content — the working-tree
        contents stay unstaged, but git diff (and therefore git difftool /
        oggitdiff -DirDiff) starts treating them as new files with empty
        baselines. Useful before running `oggitdiff -DirDiff` so the directory
        diff includes untracked files in its right pane.

        Reversible: `git reset HEAD -- <file>` in the owning repo removes the
        intent-to-add entry without touching working-tree content. A subsequent
        plain `oggitadd` finalises the staging when you're ready to commit.

        Alias: -N (matches `git add -N`).

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
        # Make untracked files visible to a directory diff:
        oggitadd -IntentToAdd
        oggitdiff -DirDiff
        # The diff's right pane now includes new files alongside modified ones.
        # When ready to commit: `oggitadd` (no flag) finalises content staging.
        # To undo without committing: `git reset HEAD -- <file>` in each repo.

    .EXAMPLE
        # Canonical workflow:
        oggitadd
        oggitcommit -Message "feat: add position prediction to simulation"
        # (user runs) oggitpush

    .OUTPUTS
        PSCustomObject — one per repo touched:
          Repo, Path, FilesStaged (int), Action ('staged'|'intent-added'|'nothing-to-stage'|'would-stage'|'failed')
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string[]] $Path,

        [switch] $All,

        [Alias('N')]
        [switch] $IntentToAdd,

        [string] $ProjectRoot = (Get-Location).Path
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
    $tree = @(Resolve-OgRepoTree -ProjectRoot $ProjectRoot)

    # Embedded-repo guard: returns ':(exclude)<path>' pathspecs for every undeclared nested
    # repo in the repo at $absPath (limited to those inside $scope, a repo-relative path,
    # when given) and warns once per path.
    $embeddedRepoExcludes = {
        param([string] $absPath, [string] $label, [string] $scope)
        foreach ($nested in @(Get-OgUndeclaredNestedRepo -RepoPath $absPath)) {
            if ($scope -and $scope -ne '.' -and
                -not ($nested -eq $scope -or $nested.StartsWith($scope.TrimEnd('/') + '/'))) { continue }
            Write-Warning ("Skipping '$nested' in '$label': it contains its own .git but is not declared in .gitmodules, " +
                "so git would stage it as an embedded gitlink. Add it with oggitsubadd, or move it out of the tree.")
            ":(exclude)$nested"
        }
    }

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

            $addArgs = if ($IntentToAdd) {
                @('add', '-N', '--', $fileRelToOwner)
            } else {
                @('add', '--', $fileRelToOwner)
            }
            if (Test-Path -LiteralPath $ownerNode.AbsolutePath) {
                $addArgs += @(& $embeddedRepoExcludes $ownerNode.AbsolutePath $ownerNode.Name $fileRelToOwner)
            }
            $reposToStage.Add(@{ Node = $ownerNode; AddArgs = $addArgs })
        }

        # Action label for successful adds — switches between 'staged' (content
        # written to index) and 'intent-added' (-N: index entry registered, no
        # content staged) so callers can distinguish the two.
        $stagedActionLabel = if ($IntentToAdd) { 'intent-added' } else { 'staged' }

        foreach ($entry in $reposToStage) {
            $node    = $entry.Node
            $absPath = $node.AbsolutePath
            $name    = $node.Name

            # An uninitialised submodule is an empty directory: git run there would act on
            # its owner, which this loop stages on its own.
            if (-not (Test-Path -LiteralPath $absPath) -or
                (-not $node.IsParent -and -not (Test-OgRepoInitialised -AbsolutePath $absPath))) {
                Write-Warning "Repo path not on disk, skipping: $absPath"
                continue
            }

            $target = if ($node.Path) { "$name ($($node.Path))" } else { $name }
            # Reconstruct the full git command for the ShouldProcess prompt (e.g.
            # "git add -N path/to/file" when -IntentToAdd, "git add path/to/file"
            # otherwise).
            $opDesc = 'git ' + ($entry.AddArgs -join ' ')
            if (-not $PSCmdlet.ShouldProcess($target, $opDesc)) {
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

            # Count files newly visible in the cached diff. With -N these are
            # intent-to-add entries (empty content); with plain add they are real
            # staged content. Either way, the count reflects what's now in the
            # index.
            $diffResult  = Invoke-Git -WorkingDirectory $absPath -Arguments 'diff', '--cached', '--name-only'
            $filesStaged = if ($diffResult.ExitCode -eq 0 -and $diffResult.StdOut) {
                ($diffResult.StdOut -split "`n" | Where-Object { $_ -ne '' }).Count
            } else { 0 }

            [PSCustomObject]@{ PSTypeName = 'Og.AddResult';
                Repo        = $name
                Path        = $node.Path
                FilesStaged = $filesStaged
                Action      = if ($filesStaged -gt 0) { $stagedActionLabel } else { 'nothing-to-stage' }
            }
        }
    } else {
        # Default mode: stage all dirty repos
        # With -IntentToAdd we run `git add -N -A` (every untracked file gets an
        # intent-to-add index entry; already-tracked-but-modified files are a
        # no-op for -N since intent is implicit). Without -IntentToAdd it's the
        # canonical `git add -A` (full content staging).
        $baseAddArgs       = if ($IntentToAdd) { @('add', '-N', '-A') } else { @('add', '-A') }
        $stagedActionLabel = if ($IntentToAdd) { 'intent-added' } else { 'staged' }

        foreach ($node in $tree) {
            $absPath = $node.AbsolutePath
            $name    = $node.Name

            # An uninitialised submodule is an empty directory: git run there would act on
            # its owner, which this loop stages on its own.
            if (-not (Test-Path -LiteralPath $absPath) -or
                (-not $node.IsParent -and -not (Test-OgRepoInitialised -AbsolutePath $absPath))) {
                Write-Warning "Repo path not on disk, skipping: $absPath"
                continue
            }

            # Check dirty state (working tree, not index). `git status
            # --porcelain=v2` reports both tracked changes AND untracked files,
            # so a repo with only untracked content still counts as dirty —
            # important for the -IntentToAdd flow where the typical reason to
            # run is precisely those untracked files.
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

            $excludes = @(& $embeddedRepoExcludes $absPath $name $null)
            $addArgs  = if ($excludes.Count -gt 0) { $baseAddArgs + @('--', '.') + $excludes } else { $baseAddArgs }
            $opDesc   = 'git ' + ($addArgs -join ' ')

            $target = if ($node.Path) { "$name ($($node.Path))" } else { $name }
            if (-not $PSCmdlet.ShouldProcess($target, $opDesc)) {
                [PSCustomObject]@{ PSTypeName = 'Og.AddResult';
                    Repo        = $name
                    Path        = $node.Path
                    FilesStaged = 0
                    Action      = 'would-stage'
                }
                continue
            }

            $addResult = Invoke-Git -WorkingDirectory $absPath -Arguments $addArgs
            if ($addResult.ExitCode -ne 0) {
                Write-Error "$opDesc failed in '$name': $($addResult.StdErr)"
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
                Action      = if ($filesStaged -gt 0) { $stagedActionLabel } else { 'nothing-to-stage' }
            }
        }
    }
}
