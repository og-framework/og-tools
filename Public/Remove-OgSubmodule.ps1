# SPDX-License-Identifier: MPL-2.0
function Remove-OgSubmodule {
    <#
    .SYNOPSIS
        Retires a submodule: the mirror of Add-OgSubmodule. Deinitialises it, removes it from
        its owning repo, and deletes its stored git dir, leaving the removal staged.

    .DESCRIPTION
        Finds the submodule declared at -Path and its OWNER (the deepest repo that declares
        it in .gitmodules). Then, in the owner:

          1. git submodule deinit -f -- <path-relative-to-owner>
          2. git rm -f -- <path-relative-to-owner>   (also removes the .gitmodules entry)
          3. Deletes <owner git dir>/modules/<submodule name>, so a later re-add starts from
             a fresh clone instead of the stale stored repo.

        It does NOT commit. The '.gitmodules' change and the gitlink deletion are left staged,
        so the next 'oggitcommit' commits the owner and cascades the pin advance. Then
        'oggitpush'.

        SAFETY GUARD: refuses when the submodule, or any submodule nested inside it, has
        uncommitted work (tracked changes or untracked files) or commits that no remote has
        (unpushed). Deinit and the git-dir deletion would destroy that work. -Force skips the
        guard.

        Retirement sequence (for example a no-go repo that reached main):
          oggitsubrm -Path Plugins/OGSimulation/Source/OGSimulationJolt/og-simulation-jolt
          oggitcommit -Message "Retire og-simulation-jolt"
          oggitpush
        Then archive the GitHub repo (do not delete it: old pins must keep resolving).

    .PARAMETER Path
        The submodule's path relative to the project root.

    .PARAMETER Force
        Remove even when the submodule has uncommitted or unpushed work. That work is lost.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .EXAMPLE
        oggitsubrm -Path libs/old-repo -WhatIf
        # Runs the safety guard and shows what would be removed, changing nothing.

    .EXAMPLE
        oggitsubrm -Path libs/old-repo; oggitcommit -Message "Retire old-repo"
        # Removes the submodule and commits the removal with the pin cascade.

    .OUTPUTS
        PSCustomObject (Og.SubmoduleResult) — one object:
          Repo, Path, Owner, Url, Branch, Action ('removed'|'would-remove'|'failed'), Sha, Error
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [switch] $Force,

        [Parameter()]
        [string] $ProjectRoot = (Get-Location).Path
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
    $relPath     = ConvertTo-OgRepoRelativePath -Path $Path
    $tree        = @(Resolve-OgRepoTree -ProjectRoot $ProjectRoot)

    $node = $tree | Where-Object { -not $_.IsParent -and $_.Path -eq $relPath } | Select-Object -First 1
    if (-not $node) {
        Write-Error "'$relPath' is not a submodule declared in any .gitmodules of the tree. Nothing was changed."
        return
    }

    $owner = Find-OgOwnerRepo -Tree $tree -RelPath $relPath
    if (-not $owner) {
        Write-Error "Could not find the initialised repo that declares '$relPath'. Nothing was changed."
        return
    }
    $ownerNode  = $owner.Node
    $ownerLabel = if ($ownerNode.IsParent) { $ownerNode.Name } else { $ownerNode.Path }

    $decl = Get-OgSubmoduleDeclaration -RepoPath $ownerNode.AbsolutePath |
        Where-Object { $_.Path.Trim('/') -eq $owner.RelToOwner } | Select-Object -First 1
    $moduleName = if ($decl) { $decl.Name } else { $owner.RelToOwner }
    $url        = if ($decl) { $decl.Url } else { $node.RemoteUrl }

    $initialised = Test-OgRepoInitialised -AbsolutePath $node.AbsolutePath
    $branch = $null
    $sha    = $null
    if ($initialised) {
        $b = Invoke-Git -WorkingDirectory $node.AbsolutePath -Arguments 'rev-parse', '--abbrev-ref', 'HEAD'
        if ($b.ExitCode -eq 0) { $branch = $b.StdOut }
        $s = Invoke-Git -WorkingDirectory $node.AbsolutePath -Arguments 'rev-parse', '--short', 'HEAD'
        if ($s.ExitCode -eq 0) { $sha = $s.StdOut }
    }

    # ---- SAFETY GUARD (read-only): the submodule and everything nested inside it ----
    if (-not $Force) {
        $problems = [System.Collections.Generic.List[string]]::new()
        $scope = @($tree | Where-Object {
            -not $_.IsParent -and ($_.Path -eq $relPath -or $_.Path.StartsWith($relPath + '/'))
        })
        foreach ($r in $scope) {
            if (-not (Test-OgRepoInitialised -AbsolutePath $r.AbsolutePath)) { continue }

            $st = Invoke-Git -WorkingDirectory $r.AbsolutePath -Arguments 'status', '--porcelain'
            if ($st.ExitCode -ne 0) {
                $problems.Add("$($r.Path): git status failed ($($st.StdErr))")
            } elseif (-not [string]::IsNullOrWhiteSpace($st.StdOut)) {
                $problems.Add("$($r.Path): uncommitted changes")
            }

            # Commits on HEAD or any local branch that no remote-tracking ref contains.
            $unpushed = Invoke-Git -WorkingDirectory $r.AbsolutePath -Arguments 'rev-list', '--count', 'HEAD', '--branches', '--not', '--remotes'
            if ($unpushed.ExitCode -ne 0) {
                $problems.Add("$($r.Path): could not count unpushed commits ($($unpushed.StdErr))")
            } elseif ($unpushed.StdOut -match '^\d+$' -and [int]$unpushed.StdOut -gt 0) {
                $problems.Add("$($r.Path): $($unpushed.StdOut) unpushed commit(s)")
            }
        }
        if ($problems.Count -gt 0) {
            Write-Error ("Refusing to remove '$relPath': {0}. Commit and push that work (or pass -Force to discard it). Nothing was changed." -f ($problems -join '; '))
            return
        }
    }

    $opDesc = "git submodule deinit -f + git rm -f $($owner.RelToOwner) + delete modules/$moduleName (staged, not committed)"
    if (-not $PSCmdlet.ShouldProcess($ownerLabel, $opDesc)) {
        [PSCustomObject]@{ PSTypeName = 'Og.SubmoduleResult'
            Repo = $node.Name; Path = $relPath; Owner = $ownerLabel; Url = $url
            Branch = $branch; Action = 'would-remove'; Sha = $sha; Error = $null }
        return
    }

    $fail = {
        param([string] $Message, [string] $GitError)
        Write-Error "$Message $GitError"
        [PSCustomObject]@{ PSTypeName = 'Og.SubmoduleResult'
            Repo = $node.Name; Path = $relPath; Owner = $ownerLabel; Url = $url
            Branch = $branch; Action = 'failed'; Sha = $sha; Error = $GitError }
    }

    # Resolve the owner's git dir BEFORE removing anything (an owner that is itself a
    # submodule keeps its git dir under its parent's .git/modules).
    $gitDir = Invoke-Git -WorkingDirectory $ownerNode.AbsolutePath -Arguments 'rev-parse', '--absolute-git-dir'
    if ($gitDir.ExitCode -ne 0) {
        & $fail "Could not resolve the git dir of '$ownerLabel':" $gitDir.StdErr
        return
    }

    if ($initialised) {
        $deinit = Invoke-Git -WorkingDirectory $ownerNode.AbsolutePath -Arguments 'submodule', 'deinit', '-f', '--', $owner.RelToOwner
        if ($deinit.ExitCode -ne 0) {
            & $fail "git submodule deinit failed in '$ownerLabel':" $deinit.StdErr
            return
        }
    }

    $rm = Invoke-Git -WorkingDirectory $ownerNode.AbsolutePath -Arguments 'rm', '-f', '--', $owner.RelToOwner
    if ($rm.ExitCode -ne 0) {
        & $fail "git rm failed in '$ownerLabel':" $rm.StdErr
        return
    }

    # Delete the stored repo, then any parent folders the name's slashes left empty.
    $modulesRoot = Join-Path $gitDir.StdOut 'modules'
    $moduleDir   = Join-Path $modulesRoot ($moduleName.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    if (Test-Path -LiteralPath $moduleDir) {
        try {
            Remove-Item -LiteralPath $moduleDir -Recurse -Force -ErrorAction Stop
        } catch {
            & $fail "Removal is staged in '$ownerLabel', but deleting '$moduleDir' failed:" $_.Exception.Message
            return
        }
        $dir = Split-Path $moduleDir -Parent
        while ($dir -and $dir.Length -gt $modulesRoot.Length -and
               (Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force)) {
            Remove-Item -LiteralPath $dir -Force
            $dir = Split-Path $dir -Parent
        }
    }

    [PSCustomObject]@{ PSTypeName = 'Og.SubmoduleResult'
        Repo = $node.Name; Path = $relPath; Owner = $ownerLabel; Url = $url
        Branch = $branch; Action = 'removed'; Sha = $sha; Error = $null }
}
