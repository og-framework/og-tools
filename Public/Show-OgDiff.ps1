# SPDX-License-Identifier: MPL-2.0
function Show-OgDiff {
    <#
    .SYNOPSIS
        Opens git difftool on every modified file across the og-framework tree — against the
        working tree by default, or against a ref (e.g. origin/main) with -Against.

    .DESCRIPTION
        For each repo with a diff to show, runs `git difftool --no-prompt`. The actual tool used
        is whatever git's diff.tool config points at (or pass -Tool to override).

        Without -Against, the comparison target is the working tree (today's behaviour): each repo
        with uncommitted tracked modifications is opened. This answers "what have I not committed?"

        With -Against <ref>, the comparison target becomes `<ref>...HEAD` — a THREE-DOT range,
        diffed against the merge base of <ref> and HEAD, not <ref>'s current tip. This answers
        "how does my branch differ from <ref>?" and is what you want when preparing a merge: on a
        clean working tree (the state you're in right before merging) the working-tree comparison
        reports every repo clean and opens nothing, which is not useful. `<ref>...HEAD` shows only
        what HEAD added since the branch point. A two-dot `<ref>..HEAD` would instead show, inverted,
        everything that has landed on <ref> since the branch point too — noise that is not your
        change. Get-OgRepoStatus's Ahead/Behind counts use the same three-dot convention
        (`rev-list --left-right --count origin/main...HEAD`) for the same reason.

        To set up Diffinity once, globally:
            git config --global diff.tool diffinity
            git config --global difftool.diffinity.cmd '"C:/Path/To/Diffinity.exe" "$LOCAL" "$REMOTE"'

        Then `oggitdiff` uses Diffinity automatically.

        ⚠ -Against -DirDiff DOES NOT use `git difftool --dir-diff`. `git difftool --dir-diff` copies
        both sides into a temp directory, launches the tool, and deletes that directory the instant
        the tool PROCESS exits. Single-instance tools (Diffinity included) hand a new invocation's
        arguments to the already-running window and exit immediately, so git sees the tool "finish"
        and deletes the files while the window is still showing them -- with `<ref>...HEAD` BOTH
        sides are temporary, so the window ends up with two empty panes. Instead, -Against -DirDiff
        exports both sides itself with `git archive` into PERSISTENT directories under
        `$env:TEMP\og-diff\<repo>\{base,head}` (cleared and overwritten on every run for that repo)
        and launches the configured tool against those directories directly. The two paths are
        returned on the result object (BasePath/HeadPath) so you can reopen the comparison later
        without re-running anything. This requires a configured diff tool (`diff.tool` /
        `difftool.<tool>.cmd`, or -Tool) -- with none configured this mode reports a clear error
        rather than silently falling back to `git difftool`.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to current working directory.

    .PARAMETER Tool
        Name of a git-configured diff tool (e.g., 'diffinity', 'vscode', 'meld').
        Overrides diff.tool for this invocation.

    .PARAMETER DirDiff
        Open one tool window per repo (directory diff) instead of one window per file. Combined
        with -Against, this exports both sides to persistent directories instead of delegating to
        `git difftool --dir-diff` -- see the temp-dir-cleanup note above.

    .PARAMETER Staged
        Compare staged changes vs HEAD instead of working-tree vs HEAD. Mutually exclusive with
        -Against (different questions: staged-vs-HEAD vs branch-vs-ref).

    .PARAMETER Against
        Compare each repo's HEAD against <ref> using the three-dot range `<ref>...HEAD` (diffed
        against the merge base) instead of the working tree. A repo where <ref> cannot be resolved
        (`git rev-parse --verify --quiet <ref>` fails — different default branch, never fetched, or
        the ref simply does not exist there) reports Action 'no-ref' and is skipped; it does not
        abort the sweep across the rest of the tree. Mutually exclusive with -Staged.

    .PARAMETER Fetch
        Only valid together with -Against. Runs 'git fetch --recurse-submodules' from the project
        root before resolving <ref> in each repo. ⚠ Without this, if <ref> is a local
        remote-tracking ref (e.g. origin/main), it reflects whatever was last fetched — which can be
        arbitrarily stale if nobody has fetched recently — and the reported diff would silently
        understate how much the branch actually differs. Mirrors Get-OgRepoStatus's -Fetch switch.

    .EXAMPLE
        oggitdiff
        # Opens difftool on each modified file in every dirty repo. Uses git's
        # default diff.tool.

    .EXAMPLE
        oggitdiff -Tool diffinity -DirDiff
        # Opens Diffinity once per dirty repo with a directory comparison.

    .EXAMPLE
        oggitdiff -Staged
        # Diffs the staged index vs HEAD (review what's about to be committed).

    .EXAMPLE
        oggitdiff -Against origin/main -DirDiff -Fetch
        # One directory-diff window per repo: what feature/... changes vs origin/main. Each side is
        # exported to a persistent directory (see BasePath/HeadPath on the result) instead of a
        # git-managed temp dir that would be deleted while the window is still open.

    .OUTPUTS
        PSCustomObject (Og.DiffResult) — one per repo touched:
          Repo, Path, Action ('opened' | 'clean' | 'failed' | 'no-ref'), Error, Ref, Range,
          BasePath, HeadPath
        Ref and Range are $null unless -Against was used; when it was, Range carries the resolved
        `<ref>...HEAD` string that was actually compared (or $null for a 'no-ref' repo). BasePath
        and HeadPath are $null except for an 'opened' result from -Against -DirDiff, where they are
        the persistent exported-tree directories (merge-base and HEAD respectively) the tool was
        launched against -- reopen them any time without re-running the cmdlet, until the next run
        for that repo overwrites them.
    #>
    [CmdletBinding(DefaultParameterSetName = 'WorkingTree')]
    param(
        [Parameter(Position = 0)]
        [string] $ProjectRoot = (Get-Location).Path,

        [string] $Tool,

        [switch] $DirDiff,

        [Parameter(ParameterSetName = 'WorkingTree')]
        [switch] $Staged,

        [Parameter(ParameterSetName = 'Against')]
        [string] $Against,

        [Parameter(ParameterSetName = 'Against')]
        [switch] $Fetch
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath

    if ($Fetch) {
        Write-Verbose 'Fetching all remotes (git fetch --recurse-submodules)...'
        $fetchResult = Invoke-Git -WorkingDirectory $ProjectRoot `
            -Arguments 'fetch', '--recurse-submodules', '--quiet'
        if ($fetchResult.ExitCode -ne 0) {
            Write-Warning "git fetch --recurse-submodules returned non-zero: $($fetchResult.StdErr)"
        }
    }

    $tree         = Resolve-OgRepoTree -ProjectRoot $ProjectRoot
    $usingAgainst = -not [string]::IsNullOrEmpty($Against)

    foreach ($repo in $tree) {
        $absPath = $repo.AbsolutePath
        if (-not (Test-Path -LiteralPath $absPath)) { continue }

        # Resolve <ref> per repo — it may not exist here (different default branch, never
        # fetched, or simply absent). A miss must not abort the sweep of the remaining repos.
        $range = $null
        if ($usingAgainst) {
            $resolveResult = Invoke-Git -WorkingDirectory $absPath `
                -Arguments 'rev-parse', '--verify', '--quiet', $Against
            if ($resolveResult.ExitCode -ne 0) {
                [PSCustomObject]@{ PSTypeName = 'Og.DiffResult';
                    Repo     = $repo.Name
                    Path     = $repo.Path
                    Action   = 'no-ref'
                    Error    = $null
                    Ref      = $Against
                    Range    = $null
                    BasePath = $null
                    HeadPath = $null
                }
                continue
            }
            $range = "$Against...HEAD"
        }

        # Both the emptiness check AND the difftool invocation must target the same range —
        # checking the working tree while diffing a range (or vice versa) would silently report
        # 'clean' for a branch that differs, or open a window for a clean one.
        $checkArgs = @('diff', '--quiet')
        if ($usingAgainst) { $checkArgs += $range }
        elseif ($Staged)   { $checkArgs += '--cached' }

        # git diff --quiet exits 0 if no diff, 1 if there is a diff
        $check = Invoke-Git -WorkingDirectory $absPath -Arguments $checkArgs
        if ($check.ExitCode -eq 0) {
            [PSCustomObject]@{ PSTypeName = 'Og.DiffResult';
                Repo     = $repo.Name
                Path     = $repo.Path
                Action   = 'clean'
                Error    = $null
                Ref      = $Against
                Range    = $range
                BasePath = $null
                HeadPath = $null
            }
            continue
        }

        if ($DirDiff -and $usingAgainst) {
            # -Against -DirDiff never uses `git difftool --dir-diff` (see .DESCRIPTION): both sides
            # of a <ref>...HEAD comparison are temporary copies, and git deletes its temp dir the
            # instant the tool process exits — fatal for single-instance tools that hand off to an
            # already-running window and exit immediately. Export both sides ourselves instead.
            Export-OgDiffAgainstDirDiff -Repo $repo -AbsPath $absPath `
                -Against $Against -Range $range -Tool $Tool
            continue
        }

        $diffArgs = @('difftool', '--no-prompt')
        if ($DirDiff)       { $diffArgs += '--dir-diff' }
        if ($usingAgainst)  { $diffArgs += $range }
        elseif ($Staged)    { $diffArgs += '--cached' }
        if ($Tool)          { $diffArgs += "--tool=$Tool" }

        Write-Verbose "Opening difftool in $($repo.Path)..."
        $diff = Invoke-Git -WorkingDirectory $absPath -Arguments $diffArgs
        if ($diff.ExitCode -eq 0) {
            [PSCustomObject]@{ PSTypeName = 'Og.DiffResult';
                Repo     = $repo.Name
                Path     = $repo.Path
                Action   = 'opened'
                Error    = $null
                Ref      = $Against
                Range    = $range
                BasePath = $null
                HeadPath = $null
            }
        } else {
            Write-Warning "git difftool failed in '$($repo.Path)': $($diff.StdErr)"
            [PSCustomObject]@{ PSTypeName = 'Og.DiffResult';
                Repo     = $repo.Name
                Path     = $repo.Path
                Action   = 'failed'
                Error    = $diff.StdErr
                Ref      = $Against
                Range    = $range
                BasePath = $null
                HeadPath = $null
            }
        }
    }
}
