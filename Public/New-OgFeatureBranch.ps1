# SPDX-License-Identifier: MPL-2.0
function New-OgFeatureBranch {
    <#
    .SYNOPSIS
        Creates a named feature branch across all repos in the og-framework tree.

    .DESCRIPTION
        For each repo in the tree the cmdlet checks out main, pulls --ff-only from
        origin/main, and creates the named branch. If the branch already exists the
        repo is skipped with Action='already-exists' and an informational Write-Verbose
        message. That is not an error, so re-running the cmdlet after a new submodule
        joins the tree only creates the branch where it is missing.

        Dirty working trees are not a barrier — `git checkout -b` carries uncommitted
        changes to the new branch unchanged. The canonical workflow is edit -> branch ->
        cascade-commit, so the tree is dirty by design when this cmdlet is called.

        By default the whole tree is targeted (parent + all submodules). -Repo limits it to
        the named repos. An uninitialised submodule (an empty directory) is skipped with a
        warning.

    .PARAMETER Name
        The branch name to create. Only alphanumerics, dots, underscores, hyphens, and
        forward slashes are allowed.

    .PARAMETER Repo
        Limit the cmdlet to these repos. Each value matches a repo's name (its leaf folder
        name, or the project folder name for the parent) or its project-relative path,
        case-insensitively. A value that matches no repo is reported with a warning.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .EXAMPLE
        New-OgFeatureBranch -Name feat/wall-hang | Format-Table -AutoSize
        # Creates feat/wall-hang in the parent + all submodule repos.

    .EXAMPLE
        New-OgFeatureBranch -Name fix/sim-physics -WhatIf
        # Shows which repos would get the branch without creating anything.

    .EXAMPLE
        New-OgFeatureBranch -Name feat/jolt-scheduler -Repo og-simulation-jolt
        # Creates the branch only in og-simulation-jolt (for example a submodule added later).

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
        [string[]] $Repo,

        [Parameter()]
        [string] $ProjectRoot = (Get-Location).Path
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
    $tree        = @(Resolve-OgRepoTree -ProjectRoot $ProjectRoot)

    if ($Repo) {
        $matchesFilter = {
            param($node, [string] $value)
            $value = $value.Replace('\', '/').Trim('/')
            $path  = $node.Path.Replace('\', '/')
            ($value -eq $node.Name) -or ($path -and $value -eq $path)
        }
        foreach ($value in $Repo) {
            if (-not ($tree | Where-Object { & $matchesFilter $_ $value })) {
                Write-Warning "-Repo '$value' matches no repo in the tree."
            }
        }
        $tree = @($tree | Where-Object { $node = $_; $Repo | Where-Object { & $matchesFilter $node $_ } })
    }

    foreach ($repoNode in $tree) {
        $absPath   = $repoNode.AbsolutePath
        $relPath   = $repoNode.Path.Replace('\', '/')
        $repoLabel = if ($repoNode.IsParent) { $repoNode.Name } else { $relPath }

        if (-not (Test-Path -LiteralPath $absPath)) {
            Write-Warning "Repo path not found, skipping: $absPath"
            continue
        }
        if (-not $repoNode.IsParent -and -not (Test-OgRepoInitialised -AbsolutePath $absPath)) {
            # An empty submodule directory: git run there would act on the owner.
            Write-Warning "Repo not initialised on disk, skipping: $absPath"
            continue
        }

        # An existing branch is not an error: re-running picks up the repos that lack it.
        $branchCheck = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--verify', '--quiet', "refs/heads/$Name"
        if ($branchCheck.ExitCode -eq 0) {
            Write-Verbose "'$repoLabel' already has branch '$Name'; skipped."
            [PSCustomObject]@{ Repo = $repoNode.Name; Path = $relPath; Action = 'already-exists'; BaseSha = $null; Branch = $Name }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($repoLabel, "git checkout main + pull + checkout -b $Name")) {
            $headResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', 'HEAD'
            $baseSha = if ($headResult.ExitCode -eq 0) { $headResult.StdOut } else { '(unknown)' }
            [PSCustomObject]@{ Repo = $repoNode.Name; Path = $relPath; Action = 'would-create'; BaseSha = $baseSha; Branch = $Name }
            continue
        }

        # Checkout main
        $coMain = Invoke-Git -WorkingDirectory $absPath -Arguments 'checkout', 'main'
        if ($coMain.ExitCode -ne 0) {
            Write-Error "Failed to checkout main in '$repoLabel': $($coMain.StdErr)"
            [PSCustomObject]@{ Repo = $repoNode.Name; Path = $relPath; Action = 'failed'; BaseSha = $null; Branch = $Name }
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
            [PSCustomObject]@{ Repo = $repoNode.Name; Path = $relPath; Action = 'failed'; BaseSha = $baseSha; Branch = $Name }
            continue
        }

        [PSCustomObject]@{ Repo = $repoNode.Name; Path = $relPath; Action = 'created'; BaseSha = $baseSha; Branch = $Name }
    }
}
