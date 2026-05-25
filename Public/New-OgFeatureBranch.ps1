# SPDX-License-Identifier: MPL-2.0
function New-OgFeatureBranch {
    <#
    .SYNOPSIS
        Creates a named feature branch across all repos in the og-framework tree.

    .DESCRIPTION
        For each repo in the tree the cmdlet checks out main, pulls --ff-only from
        origin/main, and creates the named branch. If the branch already exists the
        repo is skipped with Action='already-exists'.

        Dirty working trees are not a barrier — `git checkout -b` carries uncommitted
        changes to the new branch unchanged. The canonical workflow is edit -> branch ->
        cascade-commit, so the tree is dirty by design when this cmdlet is called.

        After processing all repos, a single Write-Error is emitted for each
        already-exists repo (collected, not per-repo, so the pipeline of PSObjects is
        not interrupted).

        Branch creation always targets the full tree (parent + all submodules). To work on
        a subset, create the branch everywhere and delete unwanted branches afterward.

    .PARAMETER Name
        The branch name to create. Only alphanumerics, dots, underscores, hyphens, and
        forward slashes are allowed.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .EXAMPLE
        New-OgFeatureBranch -Name feat/wall-hang | Format-Table -AutoSize
        # Creates feat/wall-hang in the parent + all submodule repos.

    .EXAMPLE
        New-OgFeatureBranch -Name fix/sim-physics -WhatIf
        # Shows which repos would get the branch without creating anything.

    .OUTPUTS
        PSCustomObject — one per repo targeted:
          Repo, Path, Action ('created'|'already-exists'|'failed'|'would-create'), BaseSha, Branch
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidatePattern('^[A-Za-z0-9._/-]+$')]
        [string] $Name,

        [Parameter()]
        [string] $ProjectRoot = (Get-Location).Path
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
    $tree        = Resolve-OgRepoTree -ProjectRoot $ProjectRoot

    $existsRepos = [System.Collections.Generic.List[string]]::new()

    foreach ($repo in $tree) {
        $absPath   = $repo.AbsolutePath
        $relPath   = $repo.Path.Replace('\', '/')
        $repoLabel = if ($repo.IsParent) { $repo.Name } else { $relPath }

        if (-not (Test-Path -LiteralPath $absPath)) {
            Write-Warning "Repo path not found, skipping: $absPath"
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($repoLabel, "git checkout main + pull + checkout -b $Name")) {
            $headResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', 'HEAD'
            $baseSha = if ($headResult.ExitCode -eq 0) { $headResult.StdOut } else { '(unknown)' }
            [PSCustomObject]@{ Repo = $repo.Name; Path = $relPath; Action = 'would-create'; BaseSha = $baseSha; Branch = $Name }
            continue
        }

        # Check if branch already exists
        $branchCheck = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--verify', "refs/heads/$Name"
        if ($branchCheck.ExitCode -eq 0) {
            $existsRepos.Add($repoLabel)
            [PSCustomObject]@{ Repo = $repo.Name; Path = $relPath; Action = 'already-exists'; BaseSha = $null; Branch = $Name }
            continue
        }

        # Checkout main
        $coMain = Invoke-Git -WorkingDirectory $absPath -Arguments 'checkout', 'main'
        if ($coMain.ExitCode -ne 0) {
            Write-Error "Failed to checkout main in '$repoLabel': $($coMain.StdErr)"
            [PSCustomObject]@{ Repo = $repo.Name; Path = $relPath; Action = 'failed'; BaseSha = $null; Branch = $Name }
            continue
        }

        # Pull ff-only (soft failure — detached submodules may have no remote tracking branch)
        $pull = Invoke-Git -WorkingDirectory $absPath -Arguments 'pull', '--ff-only', 'origin', 'main'
        if ($pull.ExitCode -ne 0) {
            Write-Warning "pull --ff-only in '$repoLabel' did not succeed: $($pull.StdErr)"
        }

        $headResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', 'HEAD'
        $baseSha = if ($headResult.ExitCode -eq 0) { $headResult.StdOut } else { '(unknown)' }

        # Create branch
        $branchResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'checkout', '-b', $Name
        if ($branchResult.ExitCode -ne 0) {
            Write-Error "Failed to create branch '$Name' in '$repoLabel': $($branchResult.StdErr)"
            [PSCustomObject]@{ Repo = $repo.Name; Path = $relPath; Action = 'failed'; BaseSha = $baseSha; Branch = $Name }
            continue
        }

        [PSCustomObject]@{ Repo = $repo.Name; Path = $relPath; Action = 'created'; BaseSha = $baseSha; Branch = $Name }
    }

    foreach ($r in $existsRepos) {
        Write-Error "Skipped '$r': branch '$Name' already exists."
    }
}
