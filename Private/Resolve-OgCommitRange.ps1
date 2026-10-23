# SPDX-License-Identifier: MPL-2.0

# The commit-range resolver behind `oggitdiff -Commit` and the picker (Backlog od task 4a, D5).
#
# One `oggitcommit` run ends in ONE root commit. Resolve-OgCommitRange turns that root commit into one
# Og.CommitRangeEntry per repo the run touched: the root's own files (first parent -> commit), and every
# submodule whose gitlink changed, as the submodule's own old..new, followed recursively into nested
# submodules. Get-OgCommitTouchSummary turns those entries into the picker's short "root +3" string.
#
# Rules this file keeps, and why:
#
#   - THE PINS, NEVER A TIP. A submodule's range is exactly the two gitlink ids its parent's diff shows
#     (old pin -> new pin). Never its working-tree HEAD, its branch tip or `<new>^1`: the submodule may
#     have moved since (a later cascade), or the range may span several commits (a manual commit picked
#     up by oggitcommit's pre-pass). Nested gitlinks are read from the SUBMODULE's own old..new diff, so
#     a later commit in the submodule never leaks into an earlier cascade.
#   - FIRST PARENT. The root's range is `<sha>^1..<sha>`, so a merge commit shows what the merge brought
#     into the line it was made on.
#   - READ-ONLY PLUMBING ONLY. diff-tree, cat-file -e, rev-parse, config --blob and hash-object without
#     -w. NEVER plain `git diff` or `git status`: MEASURED in od task 1, they rewrite .git/index when a
#     tracked file is only stat-dirty. Every call also runs with GIT_OPTIONAL_LOCKS=0.
#   - MISSING COMMITS ARE DATA. A pin commit that is not present locally (never fetched, a submodule not
#     initialised, a git dir deleted by oggitsubrm) is classified with `cat-file -e <rev>^{commit}`
#     BEFORE anything else uses the rev, reported as Status 'missing-commit' with an Error, and its
#     nested repos are not followed. It never throws for the rest of the tree.
#   - WHERE A SUBMODULE'S OBJECTS LIVE. Its own work tree when it is initialised there; otherwise the
#     git dir its parent keeps for it (`<parent git dir>/modules/<name>`), which is still there after a
#     plain `git rm` of the submodule or a `git submodule deinit`. The name comes from the parent's
#     .gitmodules AT THE COMMIT (git config --blob), not from the working tree, so a submodule since
#     removed from .gitmodules still resolves.

function Resolve-OgCommitRange {
    <#
    .SYNOPSIS
        Resolves a root commit into one Og.CommitRangeEntry per repo it touched (the root's own files, and
        every changed submodule pin as that submodule's old..new, recursively).

    .DESCRIPTION
        Read-only on every repo. The entries come in tree order: the root first, then depth-first (a
        submodule, then its nested submodules, then the next submodule), siblings in git's path order.

        The root's own entry is `<sha>^1..<sha>` (the first parent, so a merge commit works; an empty base
        for a parentless commit) and is present only if the commit changed files (non-gitlink paths) in
        the root. Every changed gitlink is one entry for that submodule: its old pin..new pin, an empty
        base when the submodule was added, an empty head when it was removed. Nested submodules are
        followed through the gitlink changes inside the parent submodule's old..new.

        A pin commit that is not present locally gives that submodule Status 'missing-commit' (and its
        nested repos are not followed); the rest of the tree still resolves.

    .PARAMETER ProjectRoot
        The og tree's root work tree.

    .PARAMETER Commit
        The root commit (any revision that names a commit in the root repo). Throws if it does not.

    .PARAMETER RepoTree
        Optional: Resolve-OgRepoTree's output for -ProjectRoot, so a caller resolving many commits (the
        picker) walks .gitmodules once. Used only to name repos and place their work trees.

    .OUTPUTS
        Og.CommitRangeEntry, one per touched repo:
          Repo              the repo's name (Resolve-OgRepoTree's Name; the folder leaf).
          Path              the og-tree path ('' for the root), '/'-separated.
          WorkingDirectory  absolute; where the repo's work tree is, or would be when it is not
                            initialised or was removed.
          BaseRev, HeadRev  full commit ids; '' is an empty side (added: empty base; removed: empty head).
          Status            changed | added | removed | missing-commit.
          Error             why, for missing-commit; '' otherwise.
          GitDir            absolute git dir the commits were read from ('' when none was found).
          HasWorkTree       $true when WorkingDirectory is that repo's own initialised work tree. $false
                            for a removed or uninitialised submodule: its objects are only in GitDir, and
                            git run in WorkingDirectory would reach the PARENT repo instead.

    .EXAMPLE
        Resolve-OgCommitRange -ProjectRoot C:\dev\og-brawler-unreal -Commit 6245add |
            Format-Table Repo, Path, Status, BaseRev, HeadRev
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectRoot,

        [Parameter(Mandatory)]
        [string] $Commit,

        [object[]] $RepoTree
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).ProviderPath
    if (-not $RepoTree) { $RepoTree = @(Resolve-OgRepoTree -ProjectRoot $ProjectRoot) }

    # og-tree path -> tree node, for names and work-tree locations.
    $nodeByPath = @{}
    foreach ($node in $RepoTree) { $nodeByPath[$node.Path.Replace('\', '/')] = $node }

    $rootDir = Get-OgCommitRangeOwnWorkTree -Directory $ProjectRoot
    if (-not $rootDir) {
        throw "Resolve-OgCommitRange: '$ProjectRoot' is not the top of a git work tree."
    }
    $rootRepo = @{ GitDir = $rootDir.GitDir; WorkTree = $ProjectRoot; HasWorkTree = $true }

    # A leading '-' would be parsed as an option by rev-parse; no ref or object id starts with one.
    if ([string]::IsNullOrWhiteSpace($Commit) -or $Commit.StartsWith('-')) {
        throw "Resolve-OgCommitRange: invalid revision '$Commit'."
    }
    $head = Invoke-OgCommitRangeGit -Repo $rootRepo -Arguments 'rev-parse', '--verify', '--quiet', "$Commit^{commit}"
    if ($head.ExitCode -ne 0) {
        throw "Resolve-OgCommitRange: '$Commit' does not name a commit in '$ProjectRoot'."
    }
    $headRev = $head.StdOut.Trim()

    # First parent only: a merge commit's range is what it brought into the line it was made on.
    # No parent (the repo's first commit) is an empty base.
    $parent  = Invoke-OgCommitRangeGit -Repo $rootRepo -Arguments 'rev-parse', '--verify', '--quiet', "$headRev^1^{commit}"
    $baseRev = if ($parent.ExitCode -eq 0) { $parent.StdOut.Trim() } else { '' }

    $rootName = if ($nodeByPath.ContainsKey('')) { $nodeByPath[''].Name } else { Split-Path $ProjectRoot -Leaf }
    $rootStatus = if ($baseRev) { 'changed' } else { 'added' }

    Add-OgCommitRangeRepoEntry -Repo $rootRepo -Name $rootName -Path '' -WorkingDirectory $ProjectRoot `
        -BaseRev $baseRev -HeadRev $headRev -Status $rootStatus -IsRoot `
        -ProjectRoot $ProjectRoot -NodeByPath $nodeByPath
}

function Add-OgCommitRangeRepoEntry {
    <#
    .SYNOPSIS
        Emits one repo's Og.CommitRangeEntry (the root's only if it changed files) and recurses into the
        submodules whose gitlinks change inside that repo's BaseRev..HeadRev.

    .DESCRIPTION
        The caller has already checked that every non-empty side of the range is present in -Repo; this
        function diffs the two trees and never re-checks. Each changed gitlink is classified
        (added/removed/changed), located (Find-OgCommitRangeSubmoduleRepo) and checked for its pin
        commits before it is followed; a missing one becomes a missing-commit entry and is not followed.

    .PARAMETER Repo
        Hashtable GitDir, WorkTree, HasWorkTree: where this repo's commits are read from.

    .PARAMETER Name
        The repo's name for the entry.

    .PARAMETER Path
        The repo's og-tree path ('' for the root).

    .PARAMETER WorkingDirectory
        Absolute path of the repo's (possibly absent) work tree, for the entry.

    .PARAMETER BaseRev
        Full commit id of the base side, or '' for an empty base.

    .PARAMETER HeadRev
        Full commit id of the head side, or '' for an empty head.

    .PARAMETER Status
        The entry's status (changed, added or removed).

    .PARAMETER IsRoot
        The root repo: its entry is emitted only if the range changed non-gitlink paths.

    .PARAMETER ProjectRoot
        The og tree's root, to place a submodule not in -NodeByPath.

    .PARAMETER NodeByPath
        og-tree path -> Resolve-OgRepoTree node.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Repo,
        [Parameter(Mandatory)] [string] $Name,
        [AllowEmptyString()] [string] $Path,
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [AllowEmptyString()] [string] $BaseRev,
        [AllowEmptyString()] [string] $HeadRev,
        [Parameter(Mandatory)] [string] $Status,
        [switch] $IsRoot,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [hashtable] $NodeByPath
    )

    # An empty side is the empty tree, hashed rather than hard-coded (4b825dc...) so a SHA-256 repo works.
    $emptyTree = $null
    if (-not $BaseRev -or -not $HeadRev) {
        $et = Invoke-OgCommitRangeGit -Repo $Repo -Arguments 'hash-object', '-t', 'tree', '--stdin'
        if ($et.ExitCode -ne 0) { throw "git hash-object (empty tree) failed in '$($Repo.GitDir)': $($et.StdErr)" }
        $emptyTree = $et.StdOut.Trim()
    }
    $baseTree = if ($BaseRev) { $BaseRev } else { $emptyTree }
    $headTree = if ($HeadRev) { $HeadRev } else { $emptyTree }

    # -r lists every path but never descends into a gitlink: a submodule is one 160000 entry here.
    $diff = Invoke-OgCommitRangeGit -Repo $Repo -Arguments (
        @('diff-tree', '-r', '--raw', '-z', '--no-renames', '--no-abbrev', $baseTree, $headTree))
    if ($diff.ExitCode -ne 0) {
        throw "git diff-tree $baseTree $headTree failed in '$($Repo.GitDir)': $($diff.StdErr)"
    }

    $fileCount = 0
    $gitlinks  = [System.Collections.Generic.List[object]]::new()
    foreach ($change in (ConvertFrom-OgDiffRawZ -Text $diff.StdOut)) {
        $baseIsLink = $change.BaseMode -eq '160000'
        $headIsLink = $change.HeadMode -eq '160000'
        # A file <-> submodule type change counts on both lists: its file side is a file change of this
        # repo, its gitlink side a submodule added or removed.
        if ((-not $baseIsLink -and $change.BaseMode -ne '000000') -or
            (-not $headIsLink -and $change.HeadMode -ne '000000')) {
            $fileCount++
        }
        if ($baseIsLink -or $headIsLink) {
            $gitlinks.Add([PSCustomObject]@{
                Path    = $change.Path
                BaseRev = if ($baseIsLink) { $change.BaseObject } else { '' }
                HeadRev = if ($headIsLink) { $change.HeadObject } else { '' }
            })
        }
    }

    if (-not $IsRoot -or $fileCount -gt 0) {
        New-OgCommitRangeEntry -Repo $Name -Path $Path -WorkingDirectory $WorkingDirectory `
            -BaseRev $BaseRev -HeadRev $HeadRev -Status $Status -GitDir $Repo.GitDir -HasWorkTree $Repo.HasWorkTree
    }

    foreach ($link in $gitlinks) {
        $subPath = if ($Path) { "$Path/$($link.Path)" } else { $link.Path }
        $node    = $NodeByPath[$subPath]
        $subName = if ($node) { $node.Name } else { Split-Path $subPath -Leaf }
        $subDir  = if ($node) { $node.AbsolutePath } else {
            Join-Path $ProjectRoot ($subPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        }
        $subStatus = if (-not $link.BaseRev) { 'added' } elseif (-not $link.HeadRev) { 'removed' } else { 'changed' }

        # The parent commit that still declares the submodule names it in its .gitmodules.
        $declaringRev = if ($link.HeadRev) { $HeadRev } else { $BaseRev }
        $located = Find-OgCommitRangeSubmoduleRepo -ParentRepo $Repo -ParentRev $declaringRev `
            -PathInParent $link.Path -WorkingDirectory $subDir

        $missing = Get-OgCommitRangeMissingReason -Located $located -BaseRev $link.BaseRev -HeadRev $link.HeadRev
        if ($missing) {
            $gitDir = if ($located.Repo) { $located.Repo.GitDir } else { '' }
            $hasWorkTree = if ($located.Repo) { $located.Repo.HasWorkTree } else { $false }
            New-OgCommitRangeEntry -Repo $subName -Path $subPath -WorkingDirectory $subDir `
                -BaseRev $link.BaseRev -HeadRev $link.HeadRev -Status 'missing-commit' -ErrorText $missing `
                -GitDir $gitDir -HasWorkTree $hasWorkTree
            continue
        }

        Add-OgCommitRangeRepoEntry -Repo $located.Repo -Name $subName -Path $subPath -WorkingDirectory $subDir `
            -BaseRev $link.BaseRev -HeadRev $link.HeadRev -Status $subStatus `
            -ProjectRoot $ProjectRoot -NodeByPath $NodeByPath
    }
}

function Find-OgCommitRangeSubmoduleRepo {
    <#
    .SYNOPSIS
        Finds where a submodule's commits can be read: its own initialised work tree, else the git dir its
        parent keeps for it under `<parent git dir>/modules/<name>`.

    .DESCRIPTION
        Returns a hashtable: Repo (GitDir, WorkTree, HasWorkTree; $null when neither exists) and Reason
        (why none was found, for the missing-commit Error).

    .PARAMETER ParentRepo
        The parent's repo hashtable (GitDir, WorkTree, HasWorkTree).

    .PARAMETER ParentRev
        A parent commit whose tree still contains the submodule (its .gitmodules names it).

    .PARAMETER PathInParent
        The gitlink's path inside the parent repo.

    .PARAMETER WorkingDirectory
        Where the submodule's work tree is, or would be.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $ParentRepo,
        [Parameter(Mandatory)] [string] $ParentRev,
        [Parameter(Mandatory)] [string] $PathInParent,
        [Parameter(Mandatory)] [string] $WorkingDirectory
    )

    $own = Get-OgCommitRangeOwnWorkTree -Directory $WorkingDirectory
    if ($own) {
        return @{ Repo = @{ GitDir = $own.GitDir; WorkTree = $WorkingDirectory; HasWorkTree = $true }; Reason = '' }
    }

    $name = Get-OgCommitRangeSubmoduleName -ParentRepo $ParentRepo -ParentRev $ParentRev -PathInParent $PathInParent
    $moduleDir = Join-Path $ParentRepo.GitDir (Join-Path 'modules' ($name.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
    if (Test-Path -LiteralPath $moduleDir -PathType Container) {
        $repo = @{ GitDir = $moduleDir; WorkTree = $moduleDir; HasWorkTree = $false }
        $probe = Invoke-OgCommitRangeGit -Repo $repo -Arguments 'rev-parse', '--git-dir'
        if ($probe.ExitCode -eq 0) { return @{ Repo = $repo; Reason = '' } }
    }

    @{
        Repo   = $null
        Reason = "the submodule is not initialised at '$WorkingDirectory' and its parent keeps no git dir for it " +
                 "at '$moduleDir' (never cloned here, or removed together with its git dir, as oggitsubrm does)"
    }
}

function Get-OgCommitRangeOwnWorkTree {
    <#
    .SYNOPSIS
        Returns @{ GitDir } when -Directory is the TOP of its own git work tree, $null otherwise.

    .DESCRIPTION
        An uninitialised submodule is an empty folder inside its parent's work tree: git run there finds
        the PARENT repo. So "git works here" is not enough; the directory must be its work tree's top
        (`rev-parse --show-prefix` is empty). The prefix is compared rather than the paths, so 8.3 short
        names, slashes and case never matter.

    .PARAMETER Directory
        The directory to test; a missing directory is $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $null }
    $r = Invoke-OgGitPlumbing -WorkingDirectory $Directory -Environment @{ GIT_OPTIONAL_LOCKS = '0' } `
        -Arguments 'rev-parse', '--show-prefix', '--absolute-git-dir'
    if ($r.ExitCode -ne 0) { return $null }
    $lines = $r.StdOut -split "`r?`n"
    # --show-prefix prints an EMPTY line at the top of a work tree; anything else is a subfolder.
    if ($lines.Count -lt 2 -or $lines[0] -ne '') { return $null }
    @{ GitDir = [System.IO.Path]::GetFullPath($lines[1].Trim()) }
}

function Get-OgCommitRangeSubmoduleName {
    <#
    .SYNOPSIS
        Returns the submodule name that the parent's .gitmodules at -ParentRev gives the path, or the path
        itself (git's default name) when none does.

    .DESCRIPTION
        Read from the COMMIT's .gitmodules blob, never the working tree's file: the submodule may have
        been removed from the working tree's .gitmodules since (that is the removed-submodule case).

    .PARAMETER ParentRepo
        The parent's repo hashtable.

    .PARAMETER ParentRev
        The parent commit to read .gitmodules from.

    .PARAMETER PathInParent
        The gitlink's path inside the parent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $ParentRepo,
        [Parameter(Mandatory)] [string] $ParentRev,
        [Parameter(Mandatory)] [string] $PathInParent
    )

    # -z: 'key' LF 'value' NUL per entry, so a name or path with spaces cannot be split wrongly.
    $r = Invoke-OgCommitRangeGit -Repo $ParentRepo -Arguments (
        @('config', '-z', '--blob', "${ParentRev}:.gitmodules", '--get-regexp', '^submodule\..*\.path$'))
    if ($r.ExitCode -eq 0) {
        foreach ($record in $r.StdOut.Split([char] 0)) {
            $nl = $record.IndexOf("`n")
            if ($nl -lt 0) { continue }
            $key   = $record.Substring(0, $nl)
            $value = $record.Substring($nl + 1)
            if ($value.Replace('\', '/').TrimEnd('/') -ceq $PathInParent) {
                return $key.Substring('submodule.'.Length, $key.Length - 'submodule.'.Length - '.path'.Length)
            }
        }
    }
    $PathInParent
}

function Get-OgCommitRangeMissingReason {
    <#
    .SYNOPSIS
        Returns why a submodule range cannot be read ('' when both non-empty sides are present).

    .DESCRIPTION
        `cat-file -e <rev>^{commit}` per non-empty side: the classification happens here, BEFORE any
        other git command uses the rev, so an absent pin is a missing-commit entry and never a git error
        thrown out of the resolver.

    .PARAMETER Located
        Find-OgCommitRangeSubmoduleRepo's result.

    .PARAMETER BaseRev
        The old pin, or ''.

    .PARAMETER HeadRev
        The new pin, or ''.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Located,
        [AllowEmptyString()] [string] $BaseRev,
        [AllowEmptyString()] [string] $HeadRev
    )

    if (-not $Located.Repo) { return "Pin commits cannot be read: $($Located.Reason)." }

    $absent = @(foreach ($side in @(@('base', $BaseRev), @('head', $HeadRev))) {
        if (-not $side[1]) { continue }
        $e = Invoke-OgCommitRangeGit -Repo $Located.Repo -Arguments 'cat-file', '-e', "$($side[1])^{commit}"
        if ($e.ExitCode -ne 0) { "$($side[0]) pin $($side[1])" }
    })
    if ($absent.Count -eq 0) { return '' }
    "Not present locally in '$($Located.Repo.GitDir)': $($absent -join ', ') (not fetched, or the commit was never pushed)."
}

function Invoke-OgCommitRangeGit {
    <#
    .SYNOPSIS
        Runs one read-only git command against a repo hashtable (GitDir, WorkTree).

    .DESCRIPTION
        Always passes BOTH --git-dir and --work-tree. MEASURED 2026-10-22 (git 2.50.1): a submodule's
        git dir left under modules/ after `git rm` keeps core.worktree pointing at the deleted folder, and
        any command run with only --git-dir dies with "cannot chdir to '../../../libs/child'". An explicit
        --work-tree (the git dir itself when there is no work tree) overrides it; the commands used here
        never read or write the work tree.

    .PARAMETER Repo
        Hashtable GitDir, WorkTree.

    .PARAMETER Arguments
        Git arguments after the repo options.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Repo,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    Invoke-OgGitPlumbing -WorkingDirectory $Repo.WorkTree -Environment @{ GIT_OPTIONAL_LOCKS = '0' } `
        -Arguments (@("--git-dir=$($Repo.GitDir)", "--work-tree=$($Repo.WorkTree)") + $Arguments)
}

function New-OgCommitRangeEntry {
    <#
    .SYNOPSIS
        Builds one Og.CommitRangeEntry (the shared contract with the picker and `oggitdiff -Commit`).

    .PARAMETER Repo
        The repo's name.

    .PARAMETER Path
        The og-tree path ('' for the root).

    .PARAMETER WorkingDirectory
        Absolute work-tree path (present or not).

    .PARAMETER BaseRev
        Full id or '' (empty side).

    .PARAMETER HeadRev
        Full id or '' (empty side).

    .PARAMETER Status
        changed, added, removed or missing-commit.

    .PARAMETER ErrorText
        Why, for missing-commit (the entry's Error). Not named -Error: that would shadow the automatic
        $Error variable inside this function.

    .PARAMETER GitDir
        The git dir the commits are read from, or ''.

    .PARAMETER HasWorkTree
        Whether WorkingDirectory is the repo's own initialised work tree.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [AllowEmptyString()] [string] $Path,
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [AllowEmptyString()] [string] $BaseRev,
        [AllowEmptyString()] [string] $HeadRev,
        [Parameter(Mandatory)] [ValidateSet('changed', 'added', 'removed', 'missing-commit')] [string] $Status,
        [AllowEmptyString()] [string] $ErrorText = '',
        [AllowEmptyString()] [string] $GitDir = '',
        [bool] $HasWorkTree
    )

    [PSCustomObject]@{ PSTypeName = 'Og.CommitRangeEntry'
        Repo             = $Repo
        Path             = $Path
        WorkingDirectory = $WorkingDirectory
        BaseRev          = $BaseRev
        HeadRev          = $HeadRev
        Status           = $Status
        Error            = $ErrorText
        GitDir           = $GitDir
        HasWorkTree      = $HasWorkTree
    }
}

function Get-OgCommitTouchSummary {
    <#
    .SYNOPSIS
        Turns one commit's Og.CommitRangeEntry list into the picker's short summary ("root +3") or, with
        -Detail, its one-line list of repos and ranges.

    .DESCRIPTION
        Pure: reads only the entries. The short form is the first touched repo ('root' for the root's own
        entry, else the repo's name) plus the count of the others, then the count of missing-commit
        entries if any:

            root +3            the root's files and three submodules
            og-brawler +1      pins only: og-brawler and one nested repo
            root +2 (1 missing)
            (no changes)       no entries (an empty commit)

        -Detail lists every entry as '<name> <base7>..<head7>', an empty side shown as 'empty', with
        '[added]', '[removed]' or '[missing-commit]' after it, joined with ', '.

    .PARAMETER Entry
        The entries of ONE commit, in Resolve-OgCommitRange's order. Accepts pipeline input.

    .PARAMETER Detail
        Return the per-repo list instead of the short summary.

    .EXAMPLE
        Resolve-OgCommitRange -ProjectRoot $root -Commit HEAD | Get-OgCommitTouchSummary
        # root +2
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowNull()] [AllowEmptyCollection()]
        [object[]] $Entry,

        [switch] $Detail
    )

    begin { $all = [System.Collections.Generic.List[object]]::new() }
    process { foreach ($e in $Entry) { if ($null -ne $e) { $all.Add($e) } } }
    end {
        if ($all.Count -eq 0) { return '(no changes)' }

        $nameOf = { param($e) if ([string]::IsNullOrEmpty($e.Path)) { 'root' } else { $e.Repo } }

        if ($Detail) {
            $shortRev = { param($rev) if ([string]::IsNullOrEmpty($rev)) { 'empty' } else { $rev.Substring(0, [Math]::Min(7, $rev.Length)) } }
            $parts = foreach ($e in $all) {
                $text = "$(& $nameOf $e) $(& $shortRev $e.BaseRev)..$(& $shortRev $e.HeadRev)"
                if ($e.Status -ne 'changed') { $text += " [$($e.Status)]" }
                $text
            }
            return ($parts -join ', ')
        }

        $summary = & $nameOf $all[0]
        if ($all.Count -gt 1) { $summary += " +$($all.Count - 1)" }
        $missing = @($all | Where-Object { $_.Status -eq 'missing-commit' }).Count
        if ($missing -gt 0) { $summary += " ($missing missing)" }
        $summary
    }
}
