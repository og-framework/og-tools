# SPDX-License-Identifier: MPL-2.0

# The sparse changed-paths export engine behind every og directory diff (Backlog od task 1, D1).
#
# Get-OgDiffChange lists what one comparison changed; Export-OgDiffSides writes exactly those paths
# into a base folder and a head folder. Both are read-only on the repo. The rules they keep, and why:
#
#   - NEVER `git difftool --dir-diff`: git deletes its temp dirs the moment a single-instance tool
#     hands off and exits, so the tool's panes go empty (see Show-OgDiff).
#   - NEVER THE REAL INDEX. Every git call here runs with GIT_INDEX_FILE pointing at a private temp
#     file. MEASURED 2026-10-22 (git 2.50.1): plain `git diff HEAD` REWRITES .git/index when a tracked
#     file is only stat-dirty (touched, same content) -- even with GIT_OPTIONAL_LOCKS=0. So the
#     listing refreshes a COPY of the index (update-index --refresh) and diffs with plumbing
#     (diff-index / diff-tree), which reads but never writes.
#   - BINARY-SAFE. File content never passes through a PowerShell string: object sides are written by
#     `git checkout-index --prefix` straight to disk, working-tree files are copied byte for byte.
#   - NO COMMAND-LINE LENGTH LIMIT. Paths travel on stdin (`update-index -z --index-info`), never as
#     arguments.
#   - ONE CHECKOUT CONVERSION. Every object side goes through checkout-index, i.e. the same
#     core.autocrlf / .gitattributes / smudge conversion as a real checkout, so the base side of an
#     edited CRLF file has CRLF like the working-tree copy beside it. An unchanged file is never
#     listed at all (git compares the clean, normalized content).
#   - NO GITLINKS. Mode 160000 entries are dropped from the listing: a submodule is its own repo and
#     gets its own diff, never a folder or a placeholder file here.
#   - GIT-DIR MODE (-GitDir, -Kind Range only; od task 4b). A submodule removed by a commit has no work
#     tree any more; its objects live only in the git dir its parent kept (`<parent git dir>/modules/<name>`).
#     A Range export reads nothing but objects (diff-tree, a temp index, checkout-index --prefix), so it
#     can run on that git dir alone: every git call then carries `--git-dir=<gd> --work-tree=<gd>`.
#     BOTH options, never --git-dir alone: MEASURED in od task 4a (git 2.50.1), such a git dir keeps
#     core.worktree pointing at the deleted folder and git dies with "cannot chdir to '../../../libs/x'";
#     an explicit --work-tree overrides it. --work-tree=<gd> is safe because the only command that writes
#     files, checkout-index, always gets an ABSOLUTE --prefix (a guarded, fully qualified destination);
#     with a relative one git would write relative to the work tree, i.e. into the git dir.
#   - LONG PATHS. The git calls that write the exported files run with `-c core.longpaths=true`
#     (Get-OgDiffLongPathArgument). A run folder under %TEMP% plus a deep repo path easily passes 260
#     characters, and MEASURED 2026-10-23 (git 2.50.1, LongPathsEnabled 0, no core.longpaths in any
#     config): checkout-index into a 309-character path dies with "cannot create directory ... Filename
#     too long" (od review 3 hit it on a real repo). It is a command-line `-c`, never a config change: the
#     repo stays read-only. The .NET and pwsh file calls here (copy, create, delete) need nothing: pwsh 7
#     handles long paths by itself (same measurement).
#   - NOTHING BUT EXPORTED FILES INSIDE A SIDE FOLDER (od task 7). The engine's marker, which makes a
#     folder clearable, is a file BESIDE the side folder ('<side>.og-diff-side' in its parent), never in
#     it: the diff tool shows a side folder's whole content, and the in-folder marker of tasks 1-6 was
#     listed in every Diffinity tab as one "Identical" file (the user's live check, 2026-10-23). The old
#     in-folder form is still ACCEPTED (Assert-OgDiffDestination, and the prune in Open-OgDirDiffSet.ps1),
#     so the run folders made before task 7 are still cleared and still age out; it is never written.

function Get-OgDiffChange {
    <#
    .SYNOPSIS
        Lists the paths one comparison changed (status, side presence, modes and object ids) without
        exporting anything and without writing to the repo.

    .DESCRIPTION
        The cheap "is there any change?" answer for callers that must decide before exporting
        (FileCount -eq 0 means clean), and the listing Export-OgDiffSides exports from (pass the
        result to Export-OgDiffSides -ChangeSet to export without listing twice).

        Comparisons (-Kind):
          WorkingTree  base = HEAD, head = the working tree on disk, INCLUDING untracked files that
                       are not ignored (each listed as Added with Untracked = $true).
          Staged       base = HEAD, head = the index.
          Range        base = -BaseRev, head = -HeadRev, a two-dot tree comparison. An EMPTY rev
                       means an empty side (the empty tree), for a submodule added or removed by a
                       commit. A merge base, when wanted, is the caller's to resolve and pass.

        A repo with no commit yet (unborn HEAD) compares against the empty tree for WorkingTree and
        Staged.

        With -GitDir (Range only) the comparison is read from that git dir alone, for a repo that has no
        work tree (a submodule removed by the commit being diffed): see the file header. RepoRoot is then
        the git dir.

        Renames are a delete plus an add (--no-renames), so both names appear. Mode 160000 (gitlink)
        entries are never listed; a change between a file and a gitlink keeps only the file's side.

        Read-only: the real index is copied to a temp file and every git call runs against that copy
        (see the file header for the measurement that makes this necessary).

    .PARAMETER WorkingDirectory
        Any directory inside the repo's work tree; the repo's top level is resolved from it. Not used with
        -GitDir (that repo's work tree may not exist).

    .PARAMETER Kind
        WorkingTree, Staged or Range.

    .PARAMETER BaseRev
        Range only, and required for Range: the base revision, or '' for an empty base.

    .PARAMETER HeadRev
        Range only, and required for Range: the head revision, or '' for an empty head.

    .PARAMETER GitDir
        Range only, optional: a fully qualified git dir to read the comparison from instead of a work tree
        (git-dir mode, see the file header). Omitted or '': the normal mode.

    .OUTPUTS
        PSCustomObject (Og.DiffChangeSet): Kind, RepoRoot, BaseCommit, HeadCommit, Files, FileCount, GitDir.
        GitDir is the git dir of git-dir mode (then also RepoRoot), else $null.
        BaseCommit/HeadCommit are full commit ids, or $null for an empty side, the working tree or
        the index. Files are Og.DiffSideFile objects sorted by Path (ordinal): Path ('/'-separated,
        relative to the top level), Status (Added | Deleted | Modified | TypeChanged), OnBase, OnHead,
        Untracked, BaseMode, BaseObject, HeadMode, HeadObject (mode/object are $null where a side has
        no git object, e.g. a working-tree file).

    .EXAMPLE
        (Get-OgDiffChange -WorkingDirectory C:\dev\proj -Kind WorkingTree).FileCount -gt 0
        # $true when the working tree differs from HEAD, untracked files included.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory)]
        [ValidateSet('WorkingTree', 'Staged', 'Range')]
        [string] $Kind,

        [AllowEmptyString()]
        [string] $BaseRev,

        [AllowEmptyString()]
        [string] $HeadRev,

        [AllowEmptyString()]
        [string] $GitDir
    )

    $hasRevs = $PSBoundParameters.ContainsKey('BaseRev') -or $PSBoundParameters.ContainsKey('HeadRev')
    if ($Kind -eq 'Range') {
        if (-not ($PSBoundParameters.ContainsKey('BaseRev') -and $PSBoundParameters.ContainsKey('HeadRev'))) {
            throw "Get-OgDiffChange -Kind Range needs both -BaseRev and -HeadRev ('' for an empty side)."
        }
    } elseif ($hasRevs) {
        throw "Get-OgDiffChange -Kind $Kind compares against HEAD; -BaseRev/-HeadRev belong to -Kind Range."
    }
    # Git-dir mode reads objects only. WorkingTree and Staged need a work tree and an index, which a git
    # dir without its work tree does not have (its index would describe a deleted folder).
    if (-not [string]::IsNullOrEmpty($GitDir) -and $Kind -ne 'Range') {
        throw "Get-OgDiffChange -GitDir belongs to -Kind Range; -Kind $Kind needs the repo's work tree."
    }

    if ([string]::IsNullOrEmpty($GitDir)) {
        $GitDir   = $null
        $repoRoot = Get-OgDiffRepoRoot -WorkingDirectory $WorkingDirectory
    } else {
        $GitDir   = Resolve-OgDiffGitDir -GitDir $GitDir
        $repoRoot = $GitDir
    }
    $emptyTree = Get-OgDiffEmptyTree -RepoRoot $repoRoot -GitDir $GitDir

    if ($Kind -eq 'Range') {
        $base = Resolve-OgDiffSideRev -RepoRoot $repoRoot -Rev $BaseRev -EmptyTree $emptyTree -GitDir $GitDir
        $head = Resolve-OgDiffSideRev -RepoRoot $repoRoot -Rev $HeadRev -EmptyTree $emptyTree -GitDir $GitDir
    } else {
        $headProbe = Invoke-OgGitPlumbing -WorkingDirectory $repoRoot `
            -Arguments 'rev-parse', '--verify', '--quiet', 'HEAD^{commit}'
        $base = if ($headProbe.ExitCode -eq 0) {
            @{ Commit = $headProbe.StdOut.Trim(); Tree = $headProbe.StdOut.Trim() }
        } else {
            @{ Commit = $null; Tree = $emptyTree }
        }
        $head = @{ Commit = $null; Tree = $null }
    }

    $tempIndex = New-OgDiffTempIndexPath
    try {
        # WorkingTree and Staged read the index (its stat cache and its staged blobs), so they get a
        # COPY of it. Range never needs an index; its temp path simply does not exist, which git
        # reads as an empty index -- so even there no git process ever opens the real one.
        if ($Kind -ne 'Range') {
            $indexPathResult = Invoke-OgGitPlumbing -WorkingDirectory $repoRoot `
                -Arguments 'rev-parse', '--git-path', 'index'
            if ($indexPathResult.ExitCode -ne 0) {
                throw "git rev-parse --git-path index failed in '$repoRoot': $($indexPathResult.StdErr)"
            }
            $realIndex = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($repoRoot, $indexPathResult.StdOut.Trim()))
            if (Test-Path -LiteralPath $realIndex -PathType Leaf) {
                Copy-Item -LiteralPath $realIndex -Destination $tempIndex -Force
            }
        }
        $gitEnv = @{ GIT_INDEX_FILE = $tempIndex; GIT_OPTIONAL_LOCKS = '0' }

        $diffOptions = @('--raw', '-z', '--no-renames', '--no-ext-diff', '--no-textconv', '--no-abbrev')

        switch ($Kind) {
            'WorkingTree' {
                # Refresh the COPY's stat cache first. Without it, diff-index reports every
                # stat-dirty file (touched, checked out again, autocrlf-rewritten) as modified.
                # --unmerged: a conflicted path must not abort the refresh. --ignore-missing: a
                # deleted file is the diff's business, not an error here.
                $refresh = Invoke-OgGitPlumbing -WorkingDirectory $repoRoot -Environment $gitEnv `
                    -Arguments 'update-index', '-q', '--unmerged', '--ignore-missing', '--ignore-submodules', '--refresh'
                if ($refresh.ExitCode -ne 0) {
                    throw "git update-index --refresh (temp index) failed in '$repoRoot': $($refresh.StdErr)"
                }
                $diffArgs = @('diff-index') + $diffOptions + @('--ignore-submodules=dirty', $base.Tree)
            }
            'Staged' {
                $diffArgs = @('diff-index', '--cached') + $diffOptions + @('--ignore-submodules=dirty', $base.Tree)
            }
            'Range' {
                $diffArgs = @('diff-tree', '-r') + $diffOptions + @($base.Tree, $head.Tree)
            }
        }

        $diff = Invoke-OgGitPlumbing -WorkingDirectory $repoRoot -Environment $gitEnv `
            -Arguments (@(Get-OgDiffGitDirArgument -GitDir $GitDir) + $diffArgs)
        if ($diff.ExitCode -ne 0) {
            throw "git $($diffArgs[0]) failed in '$repoRoot': $($diff.StdErr)"
        }

        # Ordinal: git paths are case-sensitive; [ordered]@{} would merge 'A.txt' and 'a.txt'.
        $files = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($entry in (ConvertFrom-OgDiffRawZ -Text $diff.StdOut)) {
            if ($entry.Status -eq 'U') {
                throw "Unmerged path '$($entry.Path)' in '$repoRoot': the index side of a -Kind Staged " +
                    'comparison is undefined during a conflict. Resolve it, or compare -Kind WorkingTree.'
            }
            if ($entry.Status -notin 'A', 'D', 'M', 'T') {
                throw "Unexpected diff status '$($entry.Status)' for '$($entry.Path)' in '$repoRoot'."
            }
            $file = New-OgDiffSideFile -Path $entry.Path -RawStatus $entry.Status `
                -BaseMode $entry.BaseMode -BaseObject $entry.BaseObject `
                -HeadMode $entry.HeadMode -HeadObject $entry.HeadObject `
                -HeadFromWorkingTree:($Kind -eq 'WorkingTree')
            if ($null -ne $file) { $files[$file.Path] = $file }
        }

        if ($Kind -eq 'WorkingTree') {
            Add-OgDiffUntrackedFile -RepoRoot $repoRoot -Environment $gitEnv -Files $files
        }
    } finally {
        Remove-Item -LiteralPath $tempIndex, "$tempIndex.lock" -Force -ErrorAction SilentlyContinue
    }

    $sorted = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files.Values) { $sorted.Add($f) }
    $sorted.Sort([System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Path, $b.Path) })

    [PSCustomObject]@{ PSTypeName = 'Og.DiffChangeSet';
        Kind       = $Kind
        RepoRoot   = $repoRoot
        BaseCommit = $base.Commit
        HeadCommit = $head.Commit
        Files      = [object[]] $sorted.ToArray()
        FileCount  = $sorted.Count
        GitDir     = $GitDir
    }
}

function Export-OgDiffSides {
    <#
    .SYNOPSIS
        Exports ONLY the changed paths of one comparison into a base folder and a head folder, read-only
        on the repo.

    .DESCRIPTION
        Lists the comparison with Get-OgDiffChange (or takes an existing listing via -ChangeSet), clears
        both destinations, then writes:
          - a Modified or TypeChanged path on both sides;
          - an Added path (untracked ones included, in WorkingTree mode) on the head side only;
          - a Deleted path on the base side only.
        Nothing else: an unchanged file never appears on either side.

        Object sides (HEAD, a revision, the index) are written by building a temp index that holds
        only the changed entries (`update-index -z --index-info`, paths on stdin) and checking it out
        with `checkout-index -a -f --prefix=<destination>/`. That keeps the real index untouched, the
        content binary-exact, the path count unbounded and the eol conversion that of a real checkout.
        The WorkingTree head side is copied from disk byte for byte.

        Git-dir mode (-GitDir, or a -ChangeSet listed with -GitDir) exports a Range from the git dir alone,
        for a repo without a work tree; see the file header.

        Each destination is deleted recursively before writing, so it is guarded first (see
        Assert-OgDiffDestination): it must be a fully qualified path that is not a drive or share root,
        must not overlap the repo or the other destination, and, if it already exists, must be empty or
        carry the engine's own marker: the file '<folder name>.og-diff-side' beside it (or, from an
        export made before od task 7, '.og-diff-side' inside it). Every destination the engine creates
        gets the marker beside it, so re-exporting into the same folder works, nothing else can ever be
        cleared, and the side folder itself holds nothing but the exported files.

        A working-tree file that vanishes between listing and copy is skipped with a warning (the
        listing still names it), so one racing editor save cannot abort the whole export.

    .PARAMETER WorkingDirectory
        Any directory inside the repo's work tree (the Compare parameter set).

    .PARAMETER Kind
        WorkingTree, Staged or Range; see Get-OgDiffChange.

    .PARAMETER BaseRev
        Range only: the base revision, or '' for an empty base.

    .PARAMETER HeadRev
        Range only: the head revision, or '' for an empty head.

    .PARAMETER GitDir
        Range only, optional: export from this fully qualified git dir (git-dir mode); see Get-OgDiffChange.

    .PARAMETER ChangeSet
        An Og.DiffChangeSet from Get-OgDiffChange, exported as listed (the ChangeSet parameter set).

    .PARAMETER BaseDestination
        Fully qualified folder for the base side: new, empty, or an earlier export (marker). Cleared first.
        Its marker is written beside it, into its parent folder.

    .PARAMETER HeadDestination
        Fully qualified folder for the head side: new, empty, or an earlier export (marker). Cleared first.
        Its marker is written beside it, into its parent folder.

    .OUTPUTS
        PSCustomObject (Og.DiffSides): Kind, RepoRoot, BaseCommit, HeadCommit, BaseDestination,
        HeadDestination (full paths), Files and FileCount (as Get-OgDiffChange). In git-dir mode RepoRoot
        is the git dir.

    .EXAMPLE
        Export-OgDiffSides -WorkingDirectory C:\dev\proj -Kind Range -BaseRev $mergeBase -HeadRev HEAD `
            -BaseDestination "$env:TEMP\og-diff\x\base" -HeadDestination "$env:TEMP\og-diff\x\head"
    #>
    [CmdletBinding(DefaultParameterSetName = 'Compare')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Compare')]
        [string] $WorkingDirectory,

        [Parameter(Mandatory, ParameterSetName = 'Compare')]
        [ValidateSet('WorkingTree', 'Staged', 'Range')]
        [string] $Kind,

        [Parameter(ParameterSetName = 'Compare')]
        [AllowEmptyString()]
        [string] $BaseRev,

        [Parameter(ParameterSetName = 'Compare')]
        [AllowEmptyString()]
        [string] $HeadRev,

        [Parameter(ParameterSetName = 'Compare')]
        [AllowEmptyString()]
        [string] $GitDir,

        [Parameter(Mandatory, ParameterSetName = 'ChangeSet')]
        [PSCustomObject] $ChangeSet,

        [Parameter(Mandatory)]
        [string] $BaseDestination,

        [Parameter(Mandatory)]
        [string] $HeadDestination
    )

    if ($PSCmdlet.ParameterSetName -eq 'Compare') {
        $listArgs = @{ WorkingDirectory = $WorkingDirectory; Kind = $Kind }
        if ($PSBoundParameters.ContainsKey('BaseRev')) { $listArgs.BaseRev = $BaseRev }
        if ($PSBoundParameters.ContainsKey('HeadRev')) { $listArgs.HeadRev = $HeadRev }
        if ($PSBoundParameters.ContainsKey('GitDir'))  { $listArgs.GitDir  = $GitDir }
        $ChangeSet = Get-OgDiffChange @listArgs
    }
    $repoRoot = $ChangeSet.RepoRoot
    # Read by name: a change set built by hand (or before git-dir mode existed) has no GitDir property.
    $gitDirProperty  = $ChangeSet.PSObject.Properties['GitDir']
    $changeSetGitDir = if ($gitDirProperty) { [string] $gitDirProperty.Value } else { '' }

    $baseDest = Assert-OgDiffDestination -Destination $BaseDestination -RepoRoot $repoRoot
    $headDest = Assert-OgDiffDestination -Destination $HeadDestination -RepoRoot $repoRoot
    if (Test-OgDiffPathOverlap -A $baseDest -B $headDest) {
        throw "Base and head destinations overlap ('$baseDest', '$headDest'); each is cleared before writing."
    }

    # Both destinations are guarded above BEFORE either is cleared: a refusal must never leave one
    # side already deleted. Cleared, so a stale earlier export never passes for a fresh one.
    foreach ($dest in $baseDest, $headDest) {
        Initialize-OgDiffSideFolder -Path $dest
    }

    $files = @($ChangeSet.Files)

    Export-OgDiffObjectSide -RepoRoot $repoRoot -GitDir $changeSetGitDir -Destination $baseDest -Entries @(
        $files | Where-Object OnBase | ForEach-Object {
            [PSCustomObject]@{ Path = $_.Path; Mode = $_.BaseMode; Object = $_.BaseObject }
        })

    $onHead = @($files | Where-Object OnHead)
    if ($ChangeSet.Kind -eq 'WorkingTree') {
        Copy-OgDiffWorkingTreeFile -RepoRoot $repoRoot -Destination $headDest -Paths @($onHead | ForEach-Object Path)
    } else {
        Export-OgDiffObjectSide -RepoRoot $repoRoot -GitDir $changeSetGitDir -Destination $headDest -Entries @(
            $onHead | ForEach-Object {
                [PSCustomObject]@{ Path = $_.Path; Mode = $_.HeadMode; Object = $_.HeadObject }
            })
    }

    [PSCustomObject]@{ PSTypeName = 'Og.DiffSides';
        Kind            = $ChangeSet.Kind
        RepoRoot        = $repoRoot
        BaseCommit      = $ChangeSet.BaseCommit
        HeadCommit      = $ChangeSet.HeadCommit
        BaseDestination = $baseDest
        HeadDestination = $headDest
        Files           = [object[]] $files
        FileCount       = $files.Count
    }
}

function Get-OgDiffRepoRoot {
    <#
    .SYNOPSIS
        Resolves the work tree's top level (native path) for a directory inside it; throws outside a
        work tree.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $WorkingDirectory)

    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw "Not a directory: '$WorkingDirectory'."
    }
    $top = Invoke-OgGitPlumbing -WorkingDirectory $WorkingDirectory -Arguments 'rev-parse', '--show-toplevel'
    if ($top.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($top.StdOut)) {
        throw "Not inside a git work tree: '$WorkingDirectory'. $($top.StdErr)"
    }
    [System.IO.Path]::GetFullPath($top.StdOut.Trim())
}

function Resolve-OgDiffGitDir {
    <#
    .SYNOPSIS
        Git-dir mode: returns a git dir's normalized full path, or throws unless it is a fully qualified,
        existing directory that git opens with --git-dir + --work-tree.

    .DESCRIPTION
        Fully qualified only, for the same reason as Assert-OgDiffDestination: a relative path would be
        resolved against [Environment]::CurrentDirectory, which in pwsh is not $PWD.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $GitDir)

    if (-not [System.IO.Path]::IsPathFullyQualified($GitDir)) {
        throw "Git dir '$GitDir' must be a fully qualified path."
    }
    $full = [System.IO.Path]::GetFullPath($GitDir).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "Git dir '$full' does not exist."
    }
    $probe = Invoke-OgGitPlumbing -WorkingDirectory $full -Environment @{ GIT_OPTIONAL_LOCKS = '0' } `
        -Arguments (@(Get-OgDiffGitDirArgument -GitDir $full) + @('rev-parse', '--git-dir'))
    if ($probe.ExitCode -ne 0) {
        throw "Not a git dir: '$full'. $($probe.StdErr)"
    }
    $full
}

function Get-OgDiffGitDirArgument {
    <#
    .SYNOPSIS
        The git options that select git-dir mode, `--git-dir=<gd>` and `--work-tree=<gd>`; nothing for an
        empty -GitDir (the normal mode, where git finds the repo from its working directory).

    .DESCRIPTION
        Always BOTH options: --git-dir alone dies on a removed submodule's git dir, whose core.worktree
        still names the deleted folder (measured in od task 4a; see the file header).
    #>
    [CmdletBinding()]
    param([AllowEmptyString()] [AllowNull()] [string] $GitDir)

    if ([string]::IsNullOrEmpty($GitDir)) { return }
    "--git-dir=$GitDir"
    "--work-tree=$GitDir"
}

function Get-OgDiffLongPathArgument {
    <#
    .SYNOPSIS
        The git options that let git write paths beyond 260 characters on Windows: `-c core.longpaths=true`.

    .DESCRIPTION
        Passed to the git calls that write exported files (Export-OgDiffObjectSide), so a deep repo path
        under a run folder never fails with "Filename too long" (see the file header for the measurement).
        A per-command `-c`, ON PURPOSE: never `git config core.longpaths`, which would write the repo's
        config and break the engine's read-only rule. Git options, so they go before the command name and
        before or after Get-OgDiffGitDirArgument's (both are global options).
    #>
    [CmdletBinding()]
    param()

    '-c'
    'core.longpaths=true'
}

function Get-OgDiffEmptyTree {
    <#
    .SYNOPSIS
        Returns the empty tree's object id for the repo's hash algorithm (SHA-1 or SHA-256).

    .DESCRIPTION
        Hashed rather than hard-coded (4b825dc...) so a SHA-256 repo works too. Nothing is written:
        no -w, and git knows the empty tree without it being stored. -GitDir: git-dir mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [AllowEmptyString()] [AllowNull()] [string] $GitDir
    )

    $r = Invoke-OgGitPlumbing -WorkingDirectory $RepoRoot -InputText '' `
        -Arguments (@(Get-OgDiffGitDirArgument -GitDir $GitDir) + @('hash-object', '-t', 'tree', '--stdin'))
    if ($r.ExitCode -ne 0) { throw "git hash-object (empty tree) failed in '$RepoRoot': $($r.StdErr)" }
    $r.StdOut.Trim()
}

function Resolve-OgDiffSideRev {
    <#
    .SYNOPSIS
        Resolves one side of a Range comparison: an empty rev is the empty tree (no commit), anything
        else must name a commit present in the repo.
        -GitDir: git-dir mode (see the file header).
    .OUTPUTS
        Hashtable with Commit (full id or $null) and Tree (what diff-tree compares).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [AllowEmptyString()] [string] $Rev,
        [Parameter(Mandatory)] [string] $EmptyTree,
        [AllowEmptyString()] [AllowNull()] [string] $GitDir
    )

    if ([string]::IsNullOrEmpty($Rev)) { return @{ Commit = $null; Tree = $EmptyTree } }
    # A leading '-' would be parsed as an option by rev-parse; no ref or object id starts with one.
    if ($Rev.StartsWith('-')) { throw "Invalid revision '$Rev'." }

    $r = Invoke-OgGitPlumbing -WorkingDirectory $RepoRoot `
        -Arguments (@(Get-OgDiffGitDirArgument -GitDir $GitDir) + @('rev-parse', '--verify', '--quiet', "$Rev^{commit}"))
    if ($r.ExitCode -ne 0) {
        throw "Revision '$Rev' does not resolve to a commit in '$RepoRoot' (missing locally, or not a commit)."
    }
    $commit = $r.StdOut.Trim()
    @{ Commit = $commit; Tree = $commit }
}

function New-OgDiffTempIndexPath {
    <#
    .SYNOPSIS
        Returns a unique, not-yet-existing temp file path for a private GIT_INDEX_FILE.
    #>
    [CmdletBinding()]
    param()

    Join-Path ([System.IO.Path]::GetTempPath()) ('og-diff-index-' + [guid]::NewGuid().ToString('N'))
}

function ConvertFrom-OgDiffRawZ {
    <#
    .SYNOPSIS
        Parses `git diff-* --raw -z --no-abbrev` output into entries (Path, Status, modes, object ids).

    .DESCRIPTION
        -z format: ':<srcmode> <dstmode> <srcsha> <dstsha> <status>' NUL '<path>' NUL, repeated. A copy
        or rename status (C/R) carries two paths; --no-renames means they never appear, but the parser
        still consumes both so a future caller cannot desynchronize it.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Text)

    if ([string]::IsNullOrEmpty($Text)) { return }
    $tokens = $Text.Split([char] 0)
    $i = 0
    while ($i -lt $tokens.Length) {
        $meta = $tokens[$i]
        if ([string]::IsNullOrEmpty($meta)) { $i++; continue }
        if (-not $meta.StartsWith(':')) { throw "Unexpected raw diff record '$meta'." }
        $fields = $meta.Substring(1).Split(' ')
        $status = $fields[4].Substring(0, 1)
        $path = $tokens[$i + 1]
        $i += 2
        if ($status -in 'R', 'C') { $path = $tokens[$i]; $i++ }
        [PSCustomObject]@{
            Path       = $path
            Status     = $status
            BaseMode   = $fields[0]
            HeadMode   = $fields[1]
            BaseObject = $fields[2]
            HeadObject = $fields[3]
        }
    }
}

function New-OgDiffSideFile {
    <#
    .SYNOPSIS
        Turns one raw diff entry into an Og.DiffSideFile, dropping gitlink sides; returns $null when no
        side is left (a pure submodule pin change).

    .DESCRIPTION
        A side exists when its mode is neither 000000 (absent) nor 160000 (gitlink). The status follows
        the surviving sides, so a file replaced by a submodule reads as Deleted, not TypeChanged.
        For a working-tree head, git reports no object id (all zeros) because the file is not hashed;
        HeadObject is then $null and the export copies the file from disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $RawStatus,
        [string] $BaseMode,
        [string] $BaseObject,
        [string] $HeadMode,
        [string] $HeadObject,
        [switch] $HeadFromWorkingTree
    )

    $onBase = $BaseMode -notin '000000', '160000'
    $onHead = $HeadMode -notin '000000', '160000'
    if (-not $onBase -and -not $onHead) { return $null }

    $status = if ($onBase -and $onHead) {
        if ($RawStatus -eq 'T') { 'TypeChanged' } else { 'Modified' }
    } elseif ($onBase) { 'Deleted' } else { 'Added' }

    [PSCustomObject]@{ PSTypeName = 'Og.DiffSideFile';
        Path       = $Path
        Status     = $status
        OnBase     = $onBase
        OnHead     = $onHead
        Untracked  = $false
        BaseMode   = if ($onBase) { $BaseMode } else { $null }
        BaseObject = if ($onBase) { $BaseObject } else { $null }
        HeadMode   = if ($onHead) { $HeadMode } else { $null }
        HeadObject = if ($onHead -and -not $HeadFromWorkingTree) { $HeadObject } else { $null }
    }
}

function Add-OgDiffUntrackedFile {
    <#
    .SYNOPSIS
        Adds the untracked, non-ignored files to a WorkingTree listing (in place).

    .DESCRIPTION
        `ls-files --others --exclude-standard` honours .gitignore, .git/info/exclude and
        core.excludesFile, so an ignored file never appears. A nested repo that is not a submodule is
        listed as 'dir/' and skipped: it is not a file of this repo.

        A path can be untracked AND listed as Deleted: `git rm --cached` keeps the file on disk. That
        is not a delete from the working tree's point of view, so the file is hashed with the repo's
        clean conversion (`hash-object --stdin-paths`, paths on stdin) and compared with HEAD's blob:
        identical -> dropped (nothing changed on disk), different -> Modified.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [hashtable] $Environment,
        [Parameter(Mandatory)] [System.Collections.Generic.Dictionary[string, object]] $Files
    )

    $others = Invoke-OgGitPlumbing -WorkingDirectory $RepoRoot -Environment $Environment `
        -Arguments 'ls-files', '-z', '--others', '--exclude-standard', '--full-name'
    if ($others.ExitCode -ne 0) { throw "git ls-files --others failed in '$RepoRoot': $($others.StdErr)" }

    $recheck = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $others.StdOut.Split([char] 0)) {
        if ([string]::IsNullOrEmpty($path) -or $path.EndsWith('/')) { continue }
        $existing = $null
        if ($Files.TryGetValue($path, [ref] $existing)) {
            # Only the `git rm --cached` shape reaches here: listed Deleted, yet on disk.
            if ($existing.Status -eq 'Deleted' -and $existing.BaseMode -in '100644', '100755' -and
                -not $path.Contains("`n")) {
                $recheck.Add($path)
            } else {
                $existing.Status = 'Modified'; $existing.OnHead = $true; $existing.Untracked = $true
            }
            continue
        }
        $Files[$path] = [PSCustomObject]@{ PSTypeName = 'Og.DiffSideFile';
            Path       = $path
            Status     = 'Added'
            OnBase     = $false
            OnHead     = $true
            Untracked  = $true
            BaseMode   = $null
            BaseObject = $null
            HeadMode   = $null
            HeadObject = $null
        }
    }

    if ($recheck.Count -eq 0) { return }
    $hashes = Invoke-OgGitPlumbing -WorkingDirectory $RepoRoot -Environment $Environment `
        -Arguments 'hash-object', '--stdin-paths' -InputText (($recheck -join "`n") + "`n")
    if ($hashes.ExitCode -ne 0) { throw "git hash-object --stdin-paths failed in '$RepoRoot': $($hashes.StdErr)" }
    $ids = @($hashes.StdOut.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    for ($k = 0; $k -lt $recheck.Count; $k++) {
        $entry = $Files[$recheck[$k]]
        if ($ids[$k] -eq $entry.BaseObject) {
            $Files.Remove($recheck[$k])
        } else {
            $entry.Status = 'Modified'; $entry.OnHead = $true; $entry.Untracked = $true
        }
    }
}

# The engine's marker, in its two forms. Only a destination that is empty or carries it may be cleared
# (Assert-OgDiffDestination), and only run folders whose every side carries it are pruned (Test-OgDiffRunFolder).
#   - WRITTEN (od task 7): the file '<side folder name>.og-diff-side' BESIDE the side folder, in its parent,
#     e.g. <run>\og-brawler\'og-brawler base e289ac3.og-diff-side'. Never inside: the diff tool would list it.
#   - ACCEPTED ONLY (exports made before task 7): the file '.og-diff-side' INSIDE the side folder.
# Both are this one string (a suffix, and a whole file name). Never rename it: a renamed marker would make
# every existing run folder unclearable and unprunable (it would stay in %TEMP% forever).
$script:OgDiffSideMarker = '.og-diff-side'

function Get-OgDiffSideMarkerPath {
    <#
    .SYNOPSIS
        Pure: the path of a side folder's marker, '<parent>\<folder name>.og-diff-side' (beside the folder).

    .DESCRIPTION
        -Destination must already be a normalized, fully qualified, non-root path without a trailing
        separator (Assert-OgDiffDestination's result): the marker is derived from its last component.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Destination)

    $parent = [System.IO.Path]::GetDirectoryName($Destination)
    $leaf   = [System.IO.Path]::GetFileName($Destination)
    if ([string]::IsNullOrEmpty($parent) -or [string]::IsNullOrEmpty($leaf)) {
        throw "Get-OgDiffSideMarkerPath: '$Destination' has no parent folder or no folder name."
    }
    Join-Path $parent ($leaf + $script:OgDiffSideMarker)
}

function Test-OgDiffSideMarked {
    <#
    .SYNOPSIS
        $true when an existing side folder carries the engine's marker in either form: the file beside it
        (Get-OgDiffSideMarkerPath, written since od task 7) or the older '.og-diff-side' file inside it.

    .DESCRIPTION
        BOTH forms on purpose: the in-folder form is how every export before od task 7 was marked, and
        those folders must stay clearable. Only FILES count: a folder of that name is no marker.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    (Test-Path -LiteralPath (Get-OgDiffSideMarkerPath -Destination $Path) -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $Path $script:OgDiffSideMarker) -PathType Leaf)
}

function Assert-OgDiffDestination {
    <#
    .SYNOPSIS
        Returns a destination's normalized full path, or throws unless deleting it recursively is
        provably safe.

    .DESCRIPTION
        The destination is deleted recursively before every export, so a wrong argument (a typo, an
        empty path component in a caller's Join-Path, '.', a drive root) must never reach the delete.
        The rules, all unconditional:

          1. FULLY QUALIFIED ONLY ([System.IO.Path]::IsPathFullyQualified). Refuses 'base', '.', '..',
             'C:' and 'C:foo'. A relative path would resolve against [Environment]::CurrentDirectory,
             which in pwsh is NOT $PWD, and a drive-relative one ('C:') is resolved by Remove-Item
             against the PowerShell location: measured by the od-1 review, 'C:\' trimmed to 'C:' aimed
             the delete at the repo being diffed.
          2. NEVER A ROOT. A path equal to its GetPathRoot ('C:\', '\\server\share') is refused. The
             trailing separator is trimmed only after this check, so a root can never become a
             drive-relative string.
          3. NOT THE REPO. Equal to, inside, or containing the repo's work tree is refused.
          4. MARKER RULE (no blacklist). An existing destination is accepted only if it is an empty
             folder or carries the engine's own marker (Test-OgDiffSideMarked): the file
             '<folder name>.og-diff-side' beside it, which Initialize-OgDiffSideFolder writes for every
             destination it creates, or the older '.og-diff-side' inside it (exports before od task 7).
             So the profile, TEMP, Documents, Windows or any user folder is refused whatever a caller
             passes, without a list of "dangerous" folders that could never be complete. An existing
             FILE is refused.

        Rule 3 is implied by rule 4 for any real repo (non-empty, no marker) but is kept: it gives the
        clearer error, and it also refuses a path inside the work tree that does not exist yet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Destination,
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($Destination) -or -not [System.IO.Path]::IsPathFullyQualified($Destination)) {
        throw "Refusing export destination '$Destination': it must be a fully qualified path (e.g. " +
            "'C:\Temp\og-diff\run\repo\base'); relative and drive-relative paths are never cleared."
    }

    # GetFullPath of a fully qualified path consults no current directory; it only normalizes '.',
    # '..' and separators.
    $full = [System.IO.Path]::GetFullPath($Destination)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\', '/') -eq $root.TrimEnd('\', '/')) {
        throw "Refusing export destination '$Destination': it is the root '$root' and would be cleared."
    }
    $full = $full.TrimEnd('\', '/')   # safe now: $full is longer than its root

    if (Test-OgDiffPathOverlap -A $full -B $RepoRoot) {
        throw "Refusing export destination '$full': it overlaps the repo '$RepoRoot' and would be cleared."
    }

    if (Test-Path -LiteralPath $full -PathType Leaf) {
        throw "Refusing export destination '$full': it is an existing file."
    }
    if (Test-Path -LiteralPath $full -PathType Container) {
        $hasEntries = $null -ne (Get-ChildItem -LiteralPath $full -Force | Select-Object -First 1)
        if ($hasEntries -and -not (Test-OgDiffSideMarked -Path $full)) {
            throw "Refusing export destination '$full': it is not empty and has no " +
                "'$($script:OgDiffSideMarker)' marker (neither '$(Split-Path $full -Leaf)$($script:OgDiffSideMarker)' " +
                "beside it nor '$($script:OgDiffSideMarker)' inside it), so it is not an earlier og diff export and will not be cleared."
        }
    }
    $full
}

function Initialize-OgDiffSideFolder {
    <#
    .SYNOPSIS
        Clears an already-guarded destination and recreates it EMPTY, with the engine's marker beside it.

    .DESCRIPTION
        The ONLY place the engine deletes a folder. Callers must pass a path returned by
        Assert-OgDiffDestination; this function does not re-check.

        The marker is a small hidden file '<folder name>.og-diff-side' in the PARENT folder
        (Get-OgDiffSideMarkerPath), never inside: the folder is what the diff tool shows, so it must hold
        nothing but the exported files (od task 7; the in-folder marker of tasks 1-6 showed up in every
        tab). Clearing the folder also removes an older in-folder marker. Being outside, the marker can no
        longer be overwritten by a repo file of the same name.

        The folder is created BEFORE its marker is written: an interruption in between leaves an empty
        folder, which the guard accepts anyway; the reverse order could leave a marker vouching for a
        folder the engine never made.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $marker = Get-OgDiffSideMarkerPath -Destination $Path
    # The marker of an earlier export into this folder is still there (it lives beside the folder, so the
    # clear above does not take it). Delete it first: WriteAllText refuses to overwrite a HIDDEN file
    # (MEASURED 2026-10-23, pwsh 7.6.8: "Access to the path ... is denied"), so re-exporting into the
    # same folder would otherwise fail.
    if (Test-Path -LiteralPath $marker -PathType Leaf) { Remove-Item -LiteralPath $marker -Force }
    [System.IO.File]::WriteAllText($marker, "og diff export side: the folder '$(Split-Path $Path -Leaf)' beside this file " +
        "is cleared by the next export into it, and deleted with its run folder by the og diff retention prune.`r`n")
    (Get-Item -LiteralPath $marker -Force).Attributes = 'Hidden'
}

function Test-OgDiffPathOverlap {
    <#
    .SYNOPSIS
        $true when two fully qualified paths are equal or one lies inside the other (case-insensitive,
        as on Windows).

    .DESCRIPTION
        String comparison only: a junction, subst drive or 8.3 alias of the same folder is not
        detected. That is acceptable because Assert-OgDiffDestination's marker rule refuses any
        non-empty folder the engine did not create, whatever it aliases. Throws on a path that is not
        fully qualified, which would otherwise be resolved against a current directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $A,
        [Parameter(Mandatory)] [string] $B
    )

    foreach ($p in $A, $B) {
        if (-not [System.IO.Path]::IsPathFullyQualified($p)) { throw "Test-OgDiffPathOverlap: '$p' is not fully qualified." }
    }
    # Append the separator rather than trim it: trimming 'C:\' would produce the drive-relative 'C:'.
    $a = [System.IO.Path]::GetFullPath($A); if (-not $a.EndsWith('\')) { $a += '\' }
    $b = [System.IO.Path]::GetFullPath($B); if (-not $b.EndsWith('\')) { $b += '\' }
    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    $a.StartsWith($b, $cmp) -or $b.StartsWith($a, $cmp)
}

function Export-OgDiffObjectSide {
    <#
    .SYNOPSIS
        Writes git objects (mode + object id per path) into a folder through a temp index and
        `checkout-index --prefix`; never touches the real index.

    .DESCRIPTION
        The temp index holds ONLY the given entries, so `checkout-index -a` writes exactly them: this
        is what makes the export sparse. Paths go on stdin (-z), so there is no length limit.
        checkout-index applies the checkout conversion (core.autocrlf, .gitattributes from the work
        tree, smudge filters) exactly as a real checkout would, and writes content git -> file
        directly, so binary files stay exact.

        -GitDir: git-dir mode (see the file header). The work tree is then the git dir itself, so the
        ABSOLUTE --prefix below is what keeps every write inside -Destination; never make it relative.

        Both git calls carry `-c core.longpaths=true` (see the file header: without it a destination
        path beyond 260 characters fails with "Filename too long").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Destination,
        [AllowEmptyCollection()] [object[]] $Entries = @(),
        [AllowEmptyString()] [AllowNull()] [string] $GitDir
    )

    if ($Entries.Count -eq 0) { return }

    $tempIndex = New-OgDiffTempIndexPath
    $gitEnv = @{ GIT_INDEX_FILE = $tempIndex; GIT_OPTIONAL_LOCKS = '0' }
    try {
        $sb = [System.Text.StringBuilder]::new()
        foreach ($e in $Entries) {
            [void] $sb.Append($e.Mode).Append(' ').Append($e.Object).Append("`t").Append($e.Path).Append([char] 0)
        }
        $repoArgs = @(Get-OgDiffLongPathArgument) + @(Get-OgDiffGitDirArgument -GitDir $GitDir)
        $info = Invoke-OgGitPlumbing -WorkingDirectory $RepoRoot -Environment $gitEnv `
            -Arguments ($repoArgs + @('update-index', '-z', '--index-info')) -InputText $sb.ToString()
        if ($info.ExitCode -ne 0) {
            throw "git update-index --index-info (temp index) failed in '$RepoRoot': $($info.StdErr)"
        }

        # checkout-index wants a prefix ending in '/'; forward slashes are what git expects on Windows.
        $prefix = $Destination.Replace('\', '/').TrimEnd('/') + '/'
        $checkout = Invoke-OgGitPlumbing -WorkingDirectory $RepoRoot -Environment $gitEnv `
            -Arguments ($repoArgs + @('checkout-index', '-a', '-f', "--prefix=$prefix"))
        if ($checkout.ExitCode -ne 0) {
            throw "git checkout-index into '$Destination' failed in '$RepoRoot': $($checkout.StdErr)"
        }
    } finally {
        Remove-Item -LiteralPath $tempIndex, "$tempIndex.lock" -Force -ErrorAction SilentlyContinue
    }
}

function Copy-OgDiffWorkingTreeFile {
    <#
    .SYNOPSIS
        Copies working-tree files (repo-relative, '/'-separated) into a folder, byte for byte.

    .DESCRIPTION
        The working-tree side IS the files on disk, so it is copied, not converted: what the user
        sees in the editor is what the diff shows. A file that cannot be read (vanished since the
        listing, or locked) is skipped with a warning rather than aborting the export.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Destination,
        [AllowEmptyCollection()] [string[]] $Paths = @()
    )

    foreach ($path in $Paths) {
        $native = $path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $source = Join-Path $RepoRoot $native
        $target = Join-Path $Destination $native
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            Write-Warning "Skipped '$path' in '$RepoRoot': no longer a file on disk."
            continue
        }
        try {
            [void] [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
            [System.IO.File]::Copy($source, $target, $true)
        } catch {
            Write-Warning "Skipped '$path' in '$RepoRoot': $($_.Exception.Message)"
        }
    }
}
