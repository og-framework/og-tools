# SPDX-License-Identifier: MPL-2.0

# The commit-range resolver behind `oggitdiff -Commit` and the picker (Backlog od task 4a, D5).
#
# One `oggitcommit` run ends in ONE root commit. Resolve-OgCommitRange turns that root commit into one
# Og.CommitRangeEntry per repo the run touched: the root's own files (first parent -> commit), and every
# submodule whose gitlink changed, as the submodule's own old..new, followed recursively into nested
# submodules. Get-OgCommitTouchSummary turns those entries into the picker's short "root +3" string.
#
# Ranges between two root commits (od task 8, R1/R2): Get-OgTreePins lists every repo one root commit
# reaches through its gitlinks, with the pin it has there; Resolve-OgTreeRange pairs the pins of two root
# commits by og-tree path into the same Og.CommitRangeEntry values, so `-From X^1 -To X` gives exactly
# Resolve-OgCommitRange X (a test pins that equivalence on every fixture).
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
#   - A NESTED PIN COMES FROM THE PARENT'S PINNED COMMIT. Get-OgTreePins reads a submodule's gitlinks from
#     `ls-tree <its pin>`, the commit its parent pins at that root commit. Never from its work tree, HEAD
#     or branch tip: those show where the submodule is NOW, which is a different tree whenever a later
#     cascade moved it. A pin that is missing locally makes its subtree unreadable: the repo is reported
#     missing-commit and nothing below it is listed.
#   - TWO-DOT. Two root commits are compared as the two trees they are (their pin sets paired by path),
#     never through a merge base, so two unrelated commits (no common history) compare like any others.

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

    $treeChange = Get-OgCommitRangeTreeChange -Repo $Repo -BaseRev $BaseRev -HeadRev $HeadRev
    $fileCount  = $treeChange.FileCount
    $gitlinks   = $treeChange.Gitlinks

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

function Get-OgTreePins {
    <#
    .SYNOPSIS
        Lists every repo one root commit reaches through its gitlinks, with the commit it pins there
        (od task 8, R1).

    .DESCRIPTION
        Read-only on every repo. The root commit's own tree gives the root's submodule pins; each
        submodule's pinned commit gives ITS submodule pins, and so on (`ls-tree <pin>`). A nested pin is
        therefore always the one its parent's pinned commit records, never the parent's work tree, HEAD
        or branch tip.

        A pin whose commit is not present locally (never fetched, the submodule never initialised, its git
        dir deleted by oggitsubrm) is a 'missing-commit' row, and nothing below it is listed: its tree,
        and so its own submodule pins, cannot be read.

        The rows come in tree order: the root first, then depth-first, siblings in git's path order.
        Repos of -RepoTree (the og tree as it is checked out now) that this commit does not contain are
        added as 'absent' rows in their tree position, so a caller can pair the commit with the current
        tree; a repo below a missing-commit row is neither present nor absent (unknown) and is left out.

    .PARAMETER ProjectRoot
        The og tree's root work tree.

    .PARAMETER Commit
        The root commit (any revision that names a commit in the root repo). Throws if it does not.

    .PARAMETER RepoTree
        Optional: Resolve-OgRepoTree's output for -ProjectRoot (walked once by a caller that lists many
        commits). Used to name repos, place their work trees and list the absent ones.

    .OUTPUTS
        Og.TreePin, one per repo:
          Repo              the repo's name (Resolve-OgRepoTree's Name; the folder leaf).
          Path              the og-tree path ('' for the root), '/'-separated.
          WorkingDirectory  absolute; where the repo's work tree is, or would be.
          Pin               the full commit id this root commit pins ('' when absent).
          GitDir            absolute git dir the pin is read from ('' when none was found, or absent).
          HasWorkTree       $true when WorkingDirectory is that repo's own initialised work tree.
          Status            present | missing-commit | absent.
          Error             why, for missing-commit; '' otherwise.

    .EXAMPLE
        Get-OgTreePins -ProjectRoot C:\dev\og-brawler-unreal -Commit 07414fb | Format-Table Path, Pin, Status
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectRoot,

        [Parameter(Mandatory)]
        [string] $Commit,

        [object[]] $RepoTree
    )

    $context = New-OgTreePinContext -ProjectRoot $ProjectRoot -RepoTree $RepoTree -Caller 'Get-OgTreePins'
    $sha     = Resolve-OgTreeRootCommit -Context $context -Commit $Commit -Caller 'Get-OgTreePins'
    $rows    = Get-OgTreePinRows -Context $context -Commit $sha

    $keyByPath = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($row in $rows) { $keyByPath[$row.Path] = $row.Key }
    $missingPaths = @($rows | Where-Object { $_.Status -eq 'missing-commit' } | ForEach-Object Path)

    # The og tree's repos that this commit does not contain. Shortest path first, so an absent repo's
    # absent parent already has its sort key.
    $treeNodes = @($context.RepoTree | Where-Object { $_.Path } |
        Sort-Object { $_.Path.Length })
    foreach ($node in $treeNodes) {
        $path = $node.Path.Replace('\', '/')
        if ($keyByPath.ContainsKey($path)) { continue }
        if (Test-OgTreePathUnder -Path $path -Ancestor $missingPaths) { continue }

        $nearest = ''
        foreach ($known in $keyByPath.Keys) {
            if ($known -and $known.Length -gt $nearest.Length -and
                $path.StartsWith("$known/", [System.StringComparison]::Ordinal)) { $nearest = $known }
        }
        $key = if ($nearest) { "$($keyByPath[$nearest])`0$($path.Substring($nearest.Length + 1))" } else { $path }
        $keyByPath[$path] = $key
        $rows.Add((New-OgTreePinRow -Repo $node.Name -Path $path -WorkingDirectory $node.AbsolutePath -Pin '' `
            -Status 'absent' -Key $key -Located $null))
    }

    $rows.Sort([System.Comparison[object]] { param($x, $y) [string]::CompareOrdinal($x.Key, $y.Key) })
    foreach ($row in $rows) {
        [PSCustomObject]@{ PSTypeName = 'Og.TreePin'
            Repo             = $row.Repo
            Path             = $row.Path
            WorkingDirectory = $row.WorkingDirectory
            Pin              = $row.Pin
            GitDir           = $row.GitDir
            HasWorkTree      = $row.HasWorkTree
            Status           = $row.Status
            Error            = $row.Error
        }
    }
}

function Resolve-OgTreeRange {
    <#
    .SYNOPSIS
        Resolves the range between two root commits into one Og.CommitRangeEntry per repo whose pin
        differs between them (od task 8, R2).

    .DESCRIPTION
        Read-only on every repo. Pairs Get-OgTreePins of -From with Get-OgTreePins of -To by og-tree path:
          changed         both commits pin the repo, at different commits;
          added           -From does not contain it (BaseRev '');
          removed         -To does not contain it (HeadRev ''; read from its work tree if it still has
                          one, else from the git dir its parent keeps for it);
          missing-commit  either pin is not present locally (Error names the side and the sha). Nothing
                          below it is paired: on the side whose pin is missing its tree cannot be read,
                          so the pins below it are unknown there, not absent.
        A repo pinned at the same commit at both ends is dropped (nothing to diff), and so is everything
        below it.

        The root's entry is always -From..-To and, as in Resolve-OgCommitRange, present only when the two
        commits differ in non-gitlink files. The two commits are compared as they are (two-dot): never
        through a merge base, so two unrelated commits work like any other pair.

        Equivalent to Resolve-OgCommitRange for one cascade: `-From X^1 -To X` returns exactly the entries
        of `Resolve-OgCommitRange -Commit X` (same order, every field). For a parentless X use `-From ''`.

    .PARAMETER ProjectRoot
        The og tree's root work tree.

    .PARAMETER From
        The base root commit (any revision naming a commit in the root repo). '' is the empty tree: every
        repo of -To is then added, as for a parentless commit.

    .PARAMETER To
        The head root commit (any revision naming a commit in the root repo).

    .PARAMETER RepoTree
        Optional: Resolve-OgRepoTree's output for -ProjectRoot, as for Resolve-OgCommitRange.

    .OUTPUTS
        Og.CommitRangeEntry (Resolve-OgCommitRange's contract), in tree order: the root first, then
        depth-first, siblings in git's path order.

    .EXAMPLE
        Resolve-OgTreeRange -ProjectRoot C:\dev\og-brawler-unreal -From 758fb77 -To 07414fb |
            Format-Table Repo, Path, Status, BaseRev, HeadRev
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectRoot,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $From,

        [Parameter(Mandatory)]
        [string] $To,

        [object[]] $RepoTree
    )

    $context = New-OgTreePinContext -ProjectRoot $ProjectRoot -RepoTree $RepoTree -Caller 'Resolve-OgTreeRange'
    $headRev = Resolve-OgTreeRootCommit -Context $context -Commit $To -Caller 'Resolve-OgTreeRange' -Parameter 'To'
    $baseRev = if ($From -eq '') { '' } else {
        Resolve-OgTreeRootCommit -Context $context -Commit $From -Caller 'Resolve-OgTreeRange' -Parameter 'From'
    }

    $baseRows = if ($baseRev) { Get-OgTreePinRows -Context $context -Commit $baseRev } else { @() }
    $headRows = Get-OgTreePinRows -Context $context -Commit $headRev

    # The root: always From..To; present only when the commits differ in non-gitlink files, by the same
    # rule (and the same function) Resolve-OgCommitRange uses.
    $rootChange = Get-OgCommitRangeTreeChange -Repo $context.RootRepo -BaseRev $baseRev -HeadRev $headRev
    if ($rootChange.FileCount -gt 0) {
        $rootStatus = if ($baseRev) { 'changed' } else { 'added' }
        New-OgCommitRangeEntry -Repo $context.RootName -Path '' -WorkingDirectory $context.ProjectRoot `
            -BaseRev $baseRev -HeadRev $headRev -Status $rootStatus -GitDir $context.RootRepo.GitDir -HasWorkTree $true
    }

    # Ordinal: two paths that differ only in case are two repos to git.
    $baseByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $headByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($row in $baseRows) { if ($row.Path) { $baseByPath[$row.Path] = $row } }
    foreach ($row in $headRows) { if ($row.Path) { $headByPath[$row.Path] = $row } }

    # Below a missing pin on EITHER side the pins are unknown on that side: pairing them would report
    # every nested repo as added or removed. Resolve-OgCommitRange does not follow a missing pin either.
    $missingPaths = @(@($baseRows) + @($headRows) |
        Where-Object { $_.Path -and $_.Status -eq 'missing-commit' } | ForEach-Object Path)

    $pairs = [System.Collections.Generic.List[object]]::new()
    $seen  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in @(@($headByPath.Keys) + @($baseByPath.Keys))) {
        if (-not $seen.Add($path)) { continue }
        if (Test-OgTreePathUnder -Path $path -Ancestor $missingPaths) { continue }

        $base = if ($baseByPath.ContainsKey($path)) { $baseByPath[$path] } else { $null }
        $head = if ($headByPath.ContainsKey($path)) { $headByPath[$path] } else { $null }
        $basePin = if ($base) { $base.Pin } else { '' }
        $headPin = if ($head) { $head.Pin } else { '' }
        if ($basePin -ceq $headPin) { continue }

        # The side that still contains the repo locates it: the head side, or the base side for a
        # removal (as Resolve-OgCommitRange's "declaring" commit).
        $declaring = if ($head) { $head } else { $base }
        $pairs.Add([PSCustomObject]@{
            Key = $declaring.Key; Row = $declaring; Base = $base; Head = $head; BasePin = $basePin; HeadPin = $headPin
        })
    }
    $pairs.Sort([System.Comparison[object]] { param($x, $y) [string]::CompareOrdinal($x.Key, $y.Key) })

    foreach ($pair in $pairs) {
        $row     = $pair.Row
        $located = $row.Located
        # Every pin of the pair must be present in the ONE repo that is read (the declaring side's).
        # Already known when each side's walk found its pin present in that same git dir; otherwise
        # (a side missing, or the two sides located in different git dirs) both pins are checked there
        # now, with the same function, and so the same Error text, as Resolve-OgCommitRange.
        $knownPresent = $located.Repo -and @(@($pair.Base, $pair.Head) | Where-Object { $_ } | Where-Object {
                $_.Status -ne 'present' -or $_.GitDir -ne $located.Repo.GitDir }).Count -eq 0
        $missing = if ($knownPresent) { '' } else {
            Get-OgCommitRangeMissingReason -Located $located -BaseRev $pair.BasePin -HeadRev $pair.HeadPin
        }
        $gitDir      = if ($located.Repo) { $located.Repo.GitDir } else { '' }
        $hasWorkTree = if ($located.Repo) { $located.Repo.HasWorkTree } else { $false }

        $status = if ($missing) { 'missing-commit' }
                  elseif (-not $pair.BasePin) { 'added' }
                  elseif (-not $pair.HeadPin) { 'removed' }
                  else { 'changed' }
        New-OgCommitRangeEntry -Repo $row.Repo -Path $row.Path -WorkingDirectory $row.WorkingDirectory `
            -BaseRev $pair.BasePin -HeadRev $pair.HeadPin -Status $status -ErrorText $missing `
            -GitDir $gitDir -HasWorkTree $hasWorkTree
    }
}

function New-OgTreePinContext {
    <#
    .SYNOPSIS
        Resolves what Get-OgTreePins and Resolve-OgTreeRange share for one og tree: the root's repo, the
        path -> Resolve-OgRepoTree node map and the root's name.

    .PARAMETER ProjectRoot
        The og tree's root work tree; must be the top of a git work tree.

    .PARAMETER RepoTree
        Optional Resolve-OgRepoTree output; walked here when not given.

    .PARAMETER Caller
        The calling function's name, for error messages.

    .OUTPUTS
        Hashtable ProjectRoot, RepoTree, NodeByPath, RootRepo (GitDir, WorkTree, HasWorkTree), RootName.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [object[]] $RepoTree,
        [Parameter(Mandatory)] [string] $Caller
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).ProviderPath
    if (-not $RepoTree) { $RepoTree = @(Resolve-OgRepoTree -ProjectRoot $ProjectRoot) }

    $nodeByPath = @{}
    foreach ($node in $RepoTree) { $nodeByPath[$node.Path.Replace('\', '/')] = $node }

    $rootDir = Get-OgCommitRangeOwnWorkTree -Directory $ProjectRoot
    if (-not $rootDir) { throw "${Caller}: '$ProjectRoot' is not the top of a git work tree." }

    @{
        ProjectRoot = $ProjectRoot
        RepoTree    = $RepoTree
        NodeByPath  = $nodeByPath
        RootRepo    = @{ GitDir = $rootDir.GitDir; WorkTree = $ProjectRoot; HasWorkTree = $true }
        RootName    = if ($nodeByPath.ContainsKey('')) { $nodeByPath[''].Name } else { Split-Path $ProjectRoot -Leaf }
    }
}

function Resolve-OgTreeRootCommit {
    <#
    .SYNOPSIS
        Returns the full id of a revision that names a commit in the og tree's root repo; throws otherwise.

    .PARAMETER Context
        New-OgTreePinContext's result.

    .PARAMETER Commit
        The revision.

    .PARAMETER Caller
        The calling function's name, for error messages.

    .PARAMETER Parameter
        Optional parameter name the revision came from (From, To), for error messages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Context,
        [AllowEmptyString()] [string] $Commit,
        [Parameter(Mandatory)] [string] $Caller,
        [string] $Parameter
    )

    $which = if ($Parameter) { " (-$Parameter)" } else { '' }
    # A leading '-' would be parsed as an option by rev-parse; no ref or object id starts with one.
    if ([string]::IsNullOrWhiteSpace($Commit) -or $Commit.StartsWith('-')) {
        throw "${Caller}: invalid revision '$Commit'$which."
    }
    $r = Invoke-OgCommitRangeGit -Repo $Context.RootRepo -Arguments 'rev-parse', '--verify', '--quiet', "$Commit^{commit}"
    if ($r.ExitCode -ne 0) {
        throw "${Caller}: '$Commit'$which does not name a commit in '$($Context.ProjectRoot)'."
    }
    $r.StdOut.Trim()
}

function Get-OgTreePinRows {
    <#
    .SYNOPSIS
        Walks one root commit's gitlinks into the internal pin rows, returned in tree order.

    .DESCRIPTION
        Level by level: every repo of one level lists its gitlinks from ITS PINNED COMMIT
        (`ls-tree -r <pin>`, never its HEAD or branch tip; the file header says why), then every gitlink
        found is located and its pin checked, then the present ones form the next level. `-r` lists every
        path of a commit but never descends into a gitlink, so a submodule is one 160000 record and its
        own pins come from its own pin.

        A level's git calls run concurrently (Invoke-OgTreePinGitBatch): they read different repos and
        are independent. MEASURED 2026-10-23 on og-brawler-unreal (9 repos): about 32 ms per git call
        one after another, and about 870 ms for this walk run sequentially; see the od task 8 notes.

        Each gitlink is classified BEFORE its pin is used: one `rev-parse --show-prefix --absolute-git-dir
        --verify --quiet <pin>^{commit}` run in its folder says both whether the folder is the top of the
        submodule's own work tree (Get-OgCommitRangeOwnWorkTree's test, on the same output lines) and
        whether the pin commit is present there (peeling to ^{commit} needs the object, as `cat-file -e`
        does). A folder that is not its own work tree's top falls back to Find-OgCommitRangeSubmoduleRepo
        (the parent's modules/<name> git dir). A missing pin is a missing-commit row and is not followed.

        The rows carry, besides Og.TreePin's fields, the sort Key (tree order) and Located (where the
        repo's commits are read from, in Find-OgCommitRangeSubmoduleRepo's shape), which
        Resolve-OgTreeRange needs to classify a pair as Resolve-OgCommitRange does. Only repos the commit
        reaches are listed: no absent rows.

    .PARAMETER Context
        New-OgTreePinContext's result.

    .PARAMETER Commit
        The root commit's full id (already resolved).

    .OUTPUTS
        System.Collections.Generic.List[object] of rows, in tree order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Context,
        [Parameter(Mandatory)] [string] $Commit
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add((New-OgTreePinRow -Repo $Context.RootName -Path '' -WorkingDirectory $Context.ProjectRoot `
        -Pin $Commit -Status 'present' -Key '' -Located @{ Repo = $Context.RootRepo; Reason = '' }))

    $level = @(@{ Repo = $Context.RootRepo; Pin = $Commit; Path = ''; Key = '' })
    while ($level.Count -gt 0) {
        # 1. Each repo's gitlinks, read from the commit its parent PINS (the root: the commit itself).
        $listings = Invoke-OgTreePinGitBatch -Request @(foreach ($parent in $level) {
            New-OgTreePinGitRequest -Repo $parent.Repo -Arguments 'ls-tree', '-r', '-z', '--full-tree', $parent.Pin
        })
        $links = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $level.Count; $i++) {
            $parent = $level[$i]
            $ls = $listings[$i]
            if ($ls.ExitCode -ne 0) { throw "git ls-tree $($parent.Pin) failed in '$($parent.Repo.GitDir)': $($ls.StdErr)" }
            foreach ($record in $ls.StdOut.Split([char] 0)) {
                # '<mode> SP <type> SP <object> TAB <path>'; -z: the path is never quoted.
                if (-not $record.StartsWith('160000 ', [System.StringComparison]::Ordinal)) { continue }
                $tab = $record.IndexOf("`t")
                if ($tab -lt 0) { continue }
                $linkPath = $record.Substring($tab + 1)
                $subPath  = if ($parent.Path) { "$($parent.Path)/$linkPath" } else { $linkPath }
                $node     = $Context.NodeByPath[$subPath]
                $links.Add(@{
                    Parent   = $parent
                    LinkPath = $linkPath
                    Pin      = ($record.Substring(0, $tab) -split ' ')[2]
                    Path     = $subPath
                    # Tree order = the chain of in-repo paths compared ordinally, level by level (git's path
                    # order among siblings; a repo before its nested repos). NUL sorts below every path
                    # character, so an ordinal compare of the joined keys IS that comparison.
                    Key      = if ($parent.Path) { "$($parent.Key)`0$linkPath" } else { $linkPath }
                    Name     = if ($node) { $node.Name } else { Split-Path $subPath -Leaf }
                    Dir      = if ($node) { $node.AbsolutePath } else {
                        Join-Path $Context.ProjectRoot ($subPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
                    }
                })
            }
        }

        # 2. Classify every gitlink found: the top of its own work tree? its pin present there? One call
        #    each, all of them concurrently.
        $probed = @($links | Where-Object { Test-Path -LiteralPath $_.Dir -PathType Container })
        $probes = Invoke-OgTreePinGitBatch -Request @(foreach ($link in $probed) {
            @{ WorkingDirectory = $link.Dir
               Arguments = @('rev-parse', '--show-prefix', '--absolute-git-dir', '--verify', '--quiet', "$($link.Pin)^{commit}") }
        })
        $probeByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        for ($i = 0; $i -lt $probed.Count; $i++) { $probeByPath[$probed[$i].Path] = $probes[$i] }

        $next = [System.Collections.Generic.List[object]]::new()
        foreach ($link in $links) {
            $located = $null
            $missing = $null
            if ($probeByPath.ContainsKey($link.Path)) {
                $probe = $probeByPath[$link.Path]
                $lines = $probe.StdOut -split "`r?`n"
                # As Get-OgCommitRangeOwnWorkTree: --show-prefix prints an EMPTY line only at the top of a
                # work tree. In an uninitialised submodule folder git finds the PARENT repo instead (a
                # prefix line), and its verdict on the pin is about the wrong repo: ignored.
                if ($lines.Count -ge 2 -and $lines[0] -eq '' -and $lines[1].Trim()) {
                    $gitDir  = [System.IO.Path]::GetFullPath($lines[1].Trim())
                    $located = @{ Repo = @{ GitDir = $gitDir; WorkTree = $link.Dir; HasWorkTree = $true }; Reason = '' }
                    $missing = Get-OgTreePinMissingReason -Located $located -Pin $link.Pin -Present ($probe.ExitCode -eq 0)
                }
            }
            if (-not $located) {
                $located = Find-OgCommitRangeSubmoduleRepo -ParentRepo $link.Parent.Repo -ParentRev $link.Parent.Pin `
                    -PathInParent $link.LinkPath -WorkingDirectory $link.Dir
                $missing = Get-OgTreePinMissingReason -Located $located -Pin $link.Pin
            }

            $status = if ($missing) { 'missing-commit' } else { 'present' }
            $rows.Add((New-OgTreePinRow -Repo $link.Name -Path $link.Path -WorkingDirectory $link.Dir -Pin $link.Pin `
                -Status $status -ErrorText $missing -Key $link.Key -Located $located))
            if (-not $missing) { $next.Add(@{ Repo = $located.Repo; Pin = $link.Pin; Path = $link.Path; Key = $link.Key }) }
        }
        $level = @($next)
    }

    $rows.Sort([System.Comparison[object]] { param($x, $y) [string]::CompareOrdinal($x.Key, $y.Key) })
    # The comma returns the list itself, not its unrolled elements.
    , $rows
}

function Get-OgTreePinMissingReason {
    <#
    .SYNOPSIS
        Returns why one pin cannot be read ('' when its commit is present where the repo was located).

    .DESCRIPTION
        Without -Present it runs `cat-file -e <pin>^{commit}` in the located repo; with -Present the
        caller has already checked the pin there (Get-OgTreePinRows' combined probe). Either way the
        check happens BEFORE anything uses the pin, so an absent pin is a missing-commit row and never a
        git error thrown out of the walk.

    .PARAMETER Located
        Find-OgCommitRangeSubmoduleRepo's result (or the same shape).

    .PARAMETER Pin
        The pinned commit id.

    .PARAMETER Present
        Optional: whether the pin commit is present in the located repo, as the caller already checked.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Located,
        [Parameter(Mandatory)] [string] $Pin,
        [Nullable[bool]] $Present
    )

    if (-not $Located.Repo) { return "Pin commit cannot be read: $($Located.Reason)." }
    if ($null -eq $Present) {
        $e = Invoke-OgCommitRangeGit -Repo $Located.Repo -Arguments 'cat-file', '-e', "$Pin^{commit}"
        $Present = $e.ExitCode -eq 0
    }
    if ($Present) { return '' }
    "Not present locally in '$($Located.Repo.GitDir)': pin $Pin (not fetched, or the commit was never pushed)."
}

function New-OgTreePinGitRequest {
    <#
    .SYNOPSIS
        Builds one Invoke-OgTreePinGitBatch request against a repo hashtable, with BOTH --git-dir and
        --work-tree, for Invoke-OgCommitRangeGit's measured reason (a modules/ git dir left by `git rm`
        keeps a core.worktree that no longer exists).

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

    @{
        WorkingDirectory = $Repo.WorkTree
        Arguments        = @("--git-dir=$($Repo.GitDir)", "--work-tree=$($Repo.WorkTree)") + $Arguments
    }
}

function Invoke-OgTreePinGitBatch {
    <#
    .SYNOPSIS
        Runs several independent read-only git commands concurrently and returns their results in
        request order (Invoke-OgGitPlumbing's result shape: ExitCode, StdOut untrimmed, StdErr trimmed,
        WorkingDirectory).

    .DESCRIPTION
        Invoke-OgGitPlumbing runs one git at a time; a pin walk needs two calls per repo, and on Windows
        each costs about 32 ms one after another (MEASURED 2026-10-23: 7 rev-parse calls took about
        210 ms in sequence and about 60 ms started together). The commands of one walk level read
        DIFFERENT repos, so nothing orders them.

        As Invoke-OgGitPlumbing: stdout and stderr are decoded as UTF-8 and both are drained
        asynchronously from the moment each process starts (a full pipe would block git while this side
        waits on another), stdin is closed at once (no command here reads it), and every call runs with
        GIT_OPTIONAL_LOCKS=0. At most 16 run at a time.

    .PARAMETER Request
        Hashtables WorkingDirectory, Arguments (one element per argument).

    .OUTPUTS
        object[] of results, one per request, in request order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Request
    )

    $results = [object[]]::new($Request.Count)
    $utf8    = [System.Text.UTF8Encoding]::new($false)
    $batch   = 16

    for ($start = 0; $start -lt $Request.Count; $start += $batch) {
        $last    = [Math]::Min($start + $batch, $Request.Count) - 1
        $running = [System.Collections.Generic.List[object]]::new()
        try {
            foreach ($i in $start..$last) {
                $req = $Request[$i]
                Write-Verbose "git $($req.Arguments -join ' ')  [in: $($req.WorkingDirectory)]"
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName               = 'git'
                $psi.WorkingDirectory       = $req.WorkingDirectory
                $psi.UseShellExecute        = $false
                $psi.RedirectStandardInput  = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.StandardOutputEncoding = $utf8
                $psi.StandardErrorEncoding  = $utf8
                $psi.CreateNoWindow         = $true
                foreach ($arg in $req.Arguments) { $psi.ArgumentList.Add($arg) }
                $psi.Environment['GIT_OPTIONAL_LOCKS'] = '0'

                $proc = [System.Diagnostics.Process]::new()
                $proc.StartInfo = $psi
                $proc.Start() | Out-Null
                $running.Add(@{
                    Index     = $i
                    Process   = $proc
                    Directory = $req.WorkingDirectory
                    StdOut    = $proc.StandardOutput.ReadToEndAsync()
                    StdErr    = $proc.StandardError.ReadToEndAsync()
                })
                $proc.StandardInput.Close()
            }
            foreach ($run in $running) {
                $run.Process.WaitForExit()
                $results[$run.Index] = [PSCustomObject]@{
                    ExitCode         = $run.Process.ExitCode
                    StdOut           = $run.StdOut.GetAwaiter().GetResult()
                    StdErr           = $run.StdErr.GetAwaiter().GetResult().TrimEnd("`r", "`n")
                    WorkingDirectory = $run.Directory
                }
            }
        } finally {
            foreach ($run in $running) { $run.Process.Dispose() }
        }
    }
    # The comma returns the array itself, so a one-element result is not unrolled into a scalar.
    , $results
}

function New-OgTreePinRow {
    <#
    .SYNOPSIS
        Builds one internal pin row (Og.TreePin's fields plus Key and Located).

    .PARAMETER Repo
        The repo's name.

    .PARAMETER Path
        The og-tree path ('' for the root).

    .PARAMETER WorkingDirectory
        Absolute work-tree path (present or not).

    .PARAMETER Pin
        Full commit id, or '' (absent).

    .PARAMETER Status
        present, missing-commit or absent.

    .PARAMETER ErrorText
        Why, for missing-commit.

    .PARAMETER Key
        The tree-order sort key.

    .PARAMETER Located
        Find-OgCommitRangeSubmoduleRepo's result, or $null (absent). GitDir and HasWorkTree come from it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [AllowEmptyString()] [string] $Path,
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [AllowEmptyString()] [string] $Pin,
        [Parameter(Mandatory)] [ValidateSet('present', 'missing-commit', 'absent')] [string] $Status,
        [AllowEmptyString()] [string] $ErrorText = '',
        [AllowEmptyString()] [string] $Key,
        [AllowNull()] [hashtable] $Located
    )

    $repoInfo = if ($Located) { $Located.Repo } else { $null }
    [PSCustomObject]@{
        Repo             = $Repo
        Path             = $Path
        WorkingDirectory = $WorkingDirectory
        Pin              = $Pin
        GitDir           = if ($repoInfo) { $repoInfo.GitDir } else { '' }
        HasWorkTree      = if ($repoInfo) { [bool] $repoInfo.HasWorkTree } else { $false }
        Status           = $Status
        Error            = $ErrorText
        Key              = $Key
        Located          = $Located
    }
}

function Test-OgTreePathUnder {
    <#
    .SYNOPSIS
        Returns $true when og-tree -Path lies strictly below one of -Ancestor (a path is not below itself).

    .PARAMETER Path
        The og-tree path, '/'-separated.

    .PARAMETER Ancestor
        Candidate ancestor og-tree paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [AllowEmptyCollection()] [AllowNull()] [string[]] $Ancestor
    )

    foreach ($a in @($Ancestor)) {
        if ($a -and $Path.StartsWith("$a/", [System.StringComparison]::Ordinal)) { return $true }
    }
    $false
}

function Get-OgCommitRangeTreeChange {
    <#
    .SYNOPSIS
        Diffs one repo's BaseRev..HeadRev trees: how many non-gitlink paths changed, and every gitlink
        that changed (Path, BaseRev, HeadRev; '' = that side has no gitlink there).

    .DESCRIPTION
        One `diff-tree` (two-dot: the two trees as they are, never a merge base). Both resolvers decide
        whether the root's own entry exists from FileCount, so Resolve-OgCommitRange and
        Resolve-OgTreeRange share this one rule rather than two copies that could drift apart (the
        equivalence of the two is pinned by a test).

    .PARAMETER Repo
        Hashtable GitDir, WorkTree, HasWorkTree: where the commits are read from.

    .PARAMETER BaseRev
        Full commit id of the base side, or '' for an empty base (the empty tree).

    .PARAMETER HeadRev
        Full commit id of the head side, or '' for an empty head (the empty tree).

    .OUTPUTS
        Hashtable FileCount (int) and Gitlinks (list of PSCustomObject Path, BaseRev, HeadRev), in git's
        path order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Repo,
        [AllowEmptyString()] [string] $BaseRev,
        [AllowEmptyString()] [string] $HeadRev
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

    @{ FileCount = $fileCount; Gitlinks = $gitlinks }
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
