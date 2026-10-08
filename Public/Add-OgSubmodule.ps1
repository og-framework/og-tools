# SPDX-License-Identifier: MPL-2.0
function Add-OgSubmodule {
    <#
    .SYNOPSIS
        Adds a repo as a submodule at a project-relative path, inside whichever repo of the
        tree owns that path, and puts the new submodule on the owner's feature branch.

    .DESCRIPTION
        Resolves the OWNER: the deepest initialised repo in the tree whose directory contains
        -Path (for example og-simulation-ue for a path under Plugins/OGSimulation/). Then:

          1. Refuses if the remote has no 'main' branch ('git ls-remote --heads <url> main'
             finds nothing). Create the repo with an initial commit (a README or LICENSE)
             first. This check runs under -WhatIf too, so a preview reports it.
          2. Runs 'git submodule add -- <url> <path-relative-to-owner>' in the owner.
          3. Picks the branch for the new submodule: -Branch when given, otherwise the
             owner's current branch when that is not 'main'. If origin already has that
             branch it is checked out (tracking origin); otherwise it is created from
             origin/main (no upstream yet: the first oggitpush pushes it with -u). Without
             a branch the submodule is left on main.
          4. Re-stages the gitlink so it records the submodule's HEAD.

        It does NOT commit. '.gitmodules' and the gitlink are left staged in the owner, so
        the next 'oggitcommit' (New-OgCommit) commits the owner and cascades the pin advance
        up to the project root. Then 'oggitpush'.

        Typical feature-branch sequence (every repo already on feat/x):
          oggitsubadd -Url https://github.com/og-framework/new-repo.git -Path Plugins/Foo/Source/New/new-repo
          oggitcommit -Message "Add new-repo submodule"
          oggitpush

    .PARAMETER Url
        Clone URL of the repo to add. Its 'main' branch must exist.

    .PARAMETER Path
        Where the submodule goes, relative to the project root (forward or back slashes).

    .PARAMETER Branch
        Branch to put the new submodule on. Defaults to the owner's current branch when that
        is not 'main'. Only alphanumerics, dots, underscores, hyphens, and forward slashes are
        allowed.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .EXAMPLE
        oggitsubadd -Url https://github.com/og-framework/og-simulation-jolt.git -Path Plugins/OGSimulation/Source/OGSimulationJolt/og-simulation-jolt
        # Adds og-simulation-jolt inside og-simulation-ue, on og-simulation-ue's branch.

    .EXAMPLE
        Add-OgSubmodule -Url https://github.com/og-framework/new-repo.git -Path libs/new-repo -WhatIf
        # Checks the remote's main, shows the owner, path and branch, and changes nothing.

    .OUTPUTS
        PSCustomObject (Og.SubmoduleResult) — one object:
          Repo, Path, Owner, Url, Branch, Action ('added'|'would-add'|'failed'), Sha, Error
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Url,

        [Parameter(Mandatory, Position = 1)]
        [string] $Path,

        [Parameter()]
        [ValidatePattern('^[A-Za-z0-9._/-]+$')]
        [string] $Branch,

        [Parameter()]
        [string] $ProjectRoot = (Get-Location).Path
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
    $relPath     = ConvertTo-OgRepoRelativePath -Path $Path
    $tree        = @(Resolve-OgRepoTree -ProjectRoot $ProjectRoot)

    if ($tree | Where-Object { -not $_.IsParent -and $_.Path -eq $relPath }) {
        Write-Error "'$relPath' is already declared as a submodule. Nothing was changed."
        return
    }

    $owner = Find-OgOwnerRepo -Tree $tree -RelPath $relPath
    if (-not $owner) {
        Write-Error "No initialised repo in the tree owns '$relPath'. Nothing was changed."
        return
    }
    $ownerNode  = $owner.Node
    $ownerLabel = if ($ownerNode.IsParent) { $ownerNode.Name } else { $ownerNode.Path }
    $absPath    = Join-Path $ProjectRoot ($relPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    $repoName   = Split-Path $relPath -Leaf

    # Branch for the new submodule: explicit, else the owner's feature branch.
    $targetBranch = $Branch
    if (-not $targetBranch) {
        $ownerBranch = Invoke-Git -WorkingDirectory $ownerNode.AbsolutePath -Arguments 'rev-parse', '--abbrev-ref', 'HEAD'
        if ($ownerBranch.ExitCode -eq 0 -and $ownerBranch.StdOut -notin @('main', 'HEAD', '')) {
            $targetBranch = $ownerBranch.StdOut
        }
    }
    $branchLabel = if ($targetBranch) { $targetBranch } else { 'main' }

    # Read-only remote check: 'main' must exist (an empty repo cannot be a submodule).
    $lsRemote = Invoke-Git -WorkingDirectory $ownerNode.AbsolutePath -Arguments 'ls-remote', '--heads', $Url, 'main'
    if ($lsRemote.ExitCode -ne 0) {
        Write-Error "Cannot read remote '$Url': $($lsRemote.StdErr). Nothing was changed."
        return
    }
    # '--heads <url> main' tail-matches (refs/heads/x/main too), so require the exact ref.
    if (-not ($lsRemote.StdOut -match '(?m)^\S+\s+refs/heads/main\s*$')) {
        Write-Error ("Remote '$Url' has no 'main' branch. Create the repository with an initial commit " +
            "(for example a README or LICENSE) so 'main' exists, then re-run. Nothing was changed.")
        return
    }

    $opDesc = "git submodule add $Url $($owner.RelToOwner) (branch $branchLabel; staged, not committed)"
    if (-not $PSCmdlet.ShouldProcess($ownerLabel, $opDesc)) {
        [PSCustomObject]@{ PSTypeName = 'Og.SubmoduleResult'
            Repo = $repoName; Path = $relPath; Owner = $ownerLabel; Url = $Url
            Branch = $branchLabel; Action = 'would-add'; Sha = $null; Error = $null }
        return
    }

    $fail = {
        param([string] $Message, [string] $GitError)
        Write-Error "$Message $GitError"
        [PSCustomObject]@{ PSTypeName = 'Og.SubmoduleResult'
            Repo = $repoName; Path = $relPath; Owner = $ownerLabel; Url = $Url
            Branch = $branchLabel; Action = 'failed'; Sha = $null; Error = $GitError }
    }

    $add = Invoke-Git -WorkingDirectory $ownerNode.AbsolutePath -Arguments 'submodule', 'add', '--', $Url, $owner.RelToOwner
    if ($add.ExitCode -ne 0) {
        & $fail "git submodule add failed in '$ownerLabel':" $add.StdErr
        return
    }

    # Put the new submodule on its branch, created from origin/main (the clone's default
    # HEAD may not be main).
    if ($targetBranch) {
        $remoteHas = (Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--verify', '--quiet', "refs/remotes/origin/$targetBranch").ExitCode -eq 0
        $co = if ($remoteHas) {
            Write-Verbose "'$relPath': origin already has '$targetBranch'; checking it out."
            Invoke-Git -WorkingDirectory $absPath -Arguments 'checkout', $targetBranch
        } else {
            Invoke-Git -WorkingDirectory $absPath -Arguments 'checkout', '--no-track', '-b', $targetBranch, 'origin/main'
        }
    } else {
        $co = Invoke-Git -WorkingDirectory $absPath -Arguments 'checkout', 'main'
    }
    if ($co.ExitCode -ne 0) {
        & $fail "Submodule '$relPath' was added (and staged) in '$ownerLabel', but checking out '$branchLabel' failed:" $co.StdErr
        return
    }

    # The gitlink must record the commit the submodule now sits on.
    $stage = Invoke-Git -WorkingDirectory $ownerNode.AbsolutePath -Arguments 'add', '--', $owner.RelToOwner
    if ($stage.ExitCode -ne 0) {
        & $fail "Submodule '$relPath' was added, but re-staging its gitlink in '$ownerLabel' failed:" $stage.StdErr
        return
    }

    $sha = (Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', 'HEAD').StdOut

    [PSCustomObject]@{ PSTypeName = 'Og.SubmoduleResult'
        Repo = $repoName; Path = $relPath; Owner = $ownerLabel; Url = $Url
        Branch = $branchLabel; Action = 'added'; Sha = $sha; Error = $null }
}
