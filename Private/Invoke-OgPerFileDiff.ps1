# SPDX-License-Identifier: MPL-2.0

# Show-OgDiff's -PerFile path (git difftool, one window per changed file) and the one result type every
# Show-OgDiff branch emits (Backlog od task 3).

function Invoke-OgPerFileDiff {
    <#
    .SYNOPSIS
        Show-OgDiff -PerFile for one repo: checks read-only whether git difftool would show anything, and
        if so runs `git difftool --no-prompt` on the same comparison.

    .DESCRIPTION
        The comparison is git's own, passed identically to the check and to git difftool, so the two can
        never disagree (checking one thing while diffing another would report 'clean' for a repo that
        differs, or open nothing for one reported 'opened'):

          WorkingTree  (no argument)   the working tree vs the INDEX, tracked files only;
          Staged       --cached        the index vs HEAD;
          Range        <ref>...HEAD    HEAD vs the merge base (git resolves the three dots), or
                       <base> <head>   two explicit commits (-BaseRev/-HeadRev; Show-OgDiff -Commit).

        The check is Get-OgPerFileDiffCount, which runs that `git diff` on a temporary copy of the index:
        a plain `git diff --quiet` rewrites .git/index (see there). It deliberately does NOT use the
        directory-diff listing (Get-OgDiffChange): that compares the working tree with HEAD and counts
        untracked files, so a repo whose change is only staged, or only untracked, would be reported
        'opened' while git difftool opens nothing.

        git difftool itself runs through Invoke-Git exactly as before -PerFile existed; it is git's own
        interactive command and may refresh the index's stat information.

    .PARAMETER Repo
        The Resolve-OgRepoTree entry (Name, Path, AbsolutePath).

    .PARAMETER Kind
        WorkingTree, Staged or Range.

    .PARAMETER MergeBase
        Range only: the merge base Show-OgDiff resolved, reported as the result's BaseRev.

    .PARAMETER Ref
        Range only: <ref>, carried onto the result.

    .PARAMETER Range
        Range only: the '<ref>...HEAD' string git diff and git difftool compare. Give either -Range or
        -BaseRev and -HeadRev.

    .PARAMETER BaseRev
        Range only: an explicit base commit; git diff and git difftool then get `<BaseRev> <HeadRev>` as
        two arguments (Show-OgDiff -Commit's pinned old..new). Both must be non-empty: an empty side has
        no per-file form in git difftool, so the caller reports such a repo itself.

    .PARAMETER HeadRev
        Range only, with -BaseRev: the explicit head commit.

    .PARAMETER Commit
        Optional, carried onto the result (the root commit Show-OgDiff -Commit diffs).

    .PARAMETER Tool
        Passed to git difftool as --tool=<Tool> when given.

    .OUTPUTS
        One Og.DiffResult (New-OgDiffResult): 'opened', 'clean' or 'failed'. FileCount is the number of
        paths git difftool walks; BaseRev is HEAD (-Staged), the merge base (-Range) or -BaseRev, HeadRev is
        HEAD (-Range) or -HeadRev; both are $null where that side is the index or the working tree.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Repo,

        [Parameter(Mandatory)]
        [ValidateSet('WorkingTree', 'Staged', 'Range')]
        [string] $Kind,

        [string] $MergeBase,

        [string] $Ref,

        [string] $Range,

        [string] $BaseRev,

        [string] $HeadRev,

        [string] $Commit,

        [string] $Tool
    )

    $absPath  = $Repo.AbsolutePath
    $explicit = -not [string]::IsNullOrEmpty($BaseRev) -or -not [string]::IsNullOrEmpty($HeadRev)
    if ($explicit) {
        if ($Kind -ne 'Range' -or -not [string]::IsNullOrEmpty($Range)) {
            throw 'Invoke-OgPerFileDiff: -BaseRev/-HeadRev belong to -Kind Range, instead of -Range.'
        }
        if ([string]::IsNullOrEmpty($BaseRev) -or [string]::IsNullOrEmpty($HeadRev)) {
            throw 'Invoke-OgPerFileDiff: -BaseRev and -HeadRev go together, both non-empty (git difftool has no empty side).'
        }
        # A leading '-' would reach git diff and git difftool as an OPTION; no commit id starts with one.
        foreach ($rev in $BaseRev, $HeadRev) {
            if ($rev.StartsWith('-')) { throw "Invoke-OgPerFileDiff: invalid revision '$rev'." }
        }
    } elseif ($Kind -eq 'Range' -and [string]::IsNullOrEmpty($Range)) {
        throw 'Invoke-OgPerFileDiff -Kind Range needs -Range, or -BaseRev and -HeadRev.'
    }

    # One argument list for both the check and git difftool: see .DESCRIPTION. @() around the switch on
    # purpose: a branch that yields @() emits NOTHING, which would leave $null (one empty argument).
    $compare = @(switch ($Kind) {
        'Range'  { if ($explicit) { $BaseRev; $HeadRev } else { $Range } }
        'Staged' { '--cached' }
        default  { }
    })
    $display = if ([string]::IsNullOrEmpty($Repo.Path)) { $Repo.Name } else { $Repo.Path }

    $common = @{ Repo = $Repo; Ref = $Ref; Range = $Range; Commit = $Commit }
    if ($explicit) {
        $common.BaseRev = $BaseRev
        $common.HeadRev = $HeadRev
    } elseif ($Kind -ne 'WorkingTree') {
        $headProbe = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--verify', '--quiet', 'HEAD^{commit}'
        $headId    = if ($headProbe.ExitCode -eq 0) { $headProbe.StdOut.Trim() } else { $null }
        if ($Kind -eq 'Staged') { $common.BaseRev = $headId }
        else { $common.BaseRev = $MergeBase; $common.HeadRev = $headId }
    }

    try {
        $count = Get-OgPerFileDiffCount -WorkingDirectory $absPath -DiffArguments $compare
    } catch {
        Write-Warning "Checking for changes failed in '$display': $($_.Exception.Message)"
        return New-OgDiffResult @common -Action 'failed' -ErrorMessage $_.Exception.Message
    }
    if ($count -eq 0) {
        return New-OgDiffResult @common -Action 'clean' -FileCount 0
    }

    $diffArgs = @('difftool', '--no-prompt') + $compare
    if ($Tool) { $diffArgs += "--tool=$Tool" }

    Write-Verbose "Opening difftool in $display..."
    $diff = Invoke-Git -WorkingDirectory $absPath -Arguments $diffArgs
    if ($diff.ExitCode -eq 0) {
        New-OgDiffResult @common -Action 'opened' -FileCount $count
    } else {
        Write-Warning "git difftool failed in '$display': $($diff.StdErr)"
        New-OgDiffResult @common -Action 'failed' -ErrorMessage $diff.StdErr -FileCount $count
    }
}

function Get-OgPerFileDiffCount {
    <#
    .SYNOPSIS
        Counts the paths `git diff <DiffArguments>` lists, run on a temporary copy of the repo's index so
        the real .git/index is never written.

    .DESCRIPTION
        This is the -PerFile "is there a change?" check, and it is git's own comparison on purpose (the
        same `git diff` arguments git difftool gets), so it counts exactly the paths git difftool walks:
        the working tree vs the index with no argument, the index vs HEAD with --cached, a range with
        '<ref>...HEAD'. Untracked files are never counted; a submodule entry is (git difftool shows it).

        WHY A COPY OF THE INDEX. MEASURED 2026-10-22 (git 2.50.1, od task 3 measurement M1): a plain
        `git diff --quiet` on a working tree with a stat-dirty file (touched, same content) REWRITES
        .git/index (it refreshes the stat cache), also with GIT_OPTIONAL_LOCKS=0. Pointed at a copy via
        GIT_INDEX_FILE (M2), git refreshes and rewrites the copy and the real index stays byte-identical.
        Do not "simplify" this back to `git diff --quiet` in the repo.

    .PARAMETER WorkingDirectory
        The repo's top level (Resolve-OgRepoTree's AbsolutePath).

    .PARAMETER DiffArguments
        The comparison arguments, as git difftool gets them: none, '--cached', or '<ref>...HEAD'.

    .OUTPUTS
        [int] the number of paths. Throws when git fails (e.g. a range that does not resolve).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [string[]] $DiffArguments = @()
    )

    $indexPathResult = Invoke-OgGitPlumbing -WorkingDirectory $WorkingDirectory -Arguments 'rev-parse', '--git-path', 'index'
    if ($indexPathResult.ExitCode -ne 0) {
        throw "git rev-parse --git-path index failed in '$WorkingDirectory': $($indexPathResult.StdErr)"
    }
    # --git-path answers relative to the directory git ran in, or absolute (a submodule's .git file).
    $realIndex = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($WorkingDirectory, $indexPathResult.StdOut.Trim()))

    $tempIndex = New-OgDiffTempIndexPath
    try {
        # No index yet (a fresh repo): no copy, and git reads the missing file as an empty index, as it
        # would read the missing real one.
        if (Test-Path -LiteralPath $realIndex -PathType Leaf) {
            Copy-Item -LiteralPath $realIndex -Destination $tempIndex -Force
        }
        $diff = Invoke-OgGitPlumbing -WorkingDirectory $WorkingDirectory `
            -Environment @{ GIT_INDEX_FILE = $tempIndex; GIT_OPTIONAL_LOCKS = '0' } `
            -Arguments (@('diff', '--name-only', '-z', '--no-color') + @($DiffArguments))
        if ($diff.ExitCode -ne 0) {
            throw "git diff --name-only $($DiffArguments -join ' ') failed in '$WorkingDirectory': $($diff.StdErr)"
        }
        @($diff.StdOut.Split([char] 0) | Where-Object { $_ }).Count
    } finally {
        Remove-Item -LiteralPath $tempIndex, "$tempIndex.lock" -Force -ErrorAction SilentlyContinue
    }
}

function New-OgDiffResult {
    <#
    .SYNOPSIS
        Builds the Og.DiffResult that Show-OgDiff's own branches emit (no-ref, a failed merge base,
        missing-commit, -PerFile), with exactly the fields and field order of Open-OgDirDiffSet's results.

    .DESCRIPTION
        One result type across every mode: Repo, Path, Action, Error, Ref, Range, BasePath, HeadPath,
        Commit, BaseRev, HeadRev, FileCount, RunPath. Keep the order in step with New-OgDirDiffResult
        (Open-OgDirDiffSet.ps1); a test compares the property names of every branch.
        BasePath, HeadPath and RunPath are always $null here: these branches export nothing. Commit is
        set only for Show-OgDiff -Commit. Empty strings become $null.

    .PARAMETER Repo
        The Resolve-OgRepoTree entry (Name and Path are used).

    .PARAMETER Action
        'opened', 'clean', 'failed', 'no-ref' or 'missing-commit' (Show-OgDiff -Commit: a pin commit that is
        not present locally, or a repo whose objects cannot be found; its Error says which).

    .PARAMETER ErrorMessage
        The error for a 'failed' result.

    .PARAMETER Ref
        Show-OgDiff -Against's ref, or nothing.

    .PARAMETER Range
        The '<ref>...HEAD' string, or nothing.

    .PARAMETER BaseRev
        The base side's full commit id, or nothing.

    .PARAMETER HeadRev
        The head side's full commit id, or nothing.

    .PARAMETER FileCount
        The number of changed paths, or $null when nothing was listed.

    .PARAMETER Commit
        The root commit Show-OgDiff -Commit diffs (full id), or nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Repo,
        [Parameter(Mandatory)] [ValidateSet('opened', 'clean', 'failed', 'no-ref', 'missing-commit')] [string] $Action,
        [string] $ErrorMessage,
        [string] $Ref,
        [string] $Range,
        [string] $BaseRev,
        [string] $HeadRev,
        [AllowNull()] [object] $FileCount = $null,
        [string] $Commit
    )

    # [string] parameters turn $null into ''; the result carries $null for "not applicable".
    $orNull = { param([string] $Value) if ([string]::IsNullOrEmpty($Value)) { $null } else { $Value } }

    [PSCustomObject]@{ PSTypeName = 'Og.DiffResult';
        Repo      = $Repo.Name
        Path      = $Repo.Path
        Action    = $Action
        Error     = & $orNull $ErrorMessage
        Ref       = & $orNull $Ref
        Range     = & $orNull $Range
        BasePath  = $null
        HeadPath  = $null
        Commit    = & $orNull $Commit
        BaseRev   = & $orNull $BaseRev
        HeadRev   = & $orNull $HeadRev
        FileCount = $FileCount
        RunPath   = $null
    }
}
