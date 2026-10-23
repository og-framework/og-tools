# SPDX-License-Identifier: MPL-2.0
function Show-OgDiff {
    <#
    .SYNOPSIS
        Opens what changed across the og-framework tree in the configured diff tool: by default one
        directory diff per changed repo, all as tabs of ONE tool instance; with -PerFile, git difftool's
        per-file windows. Compares the working tree by default, the index with -Staged, the branch
        against a ref (e.g. origin/main) with -Against, or what one root commit (one `oggitcommit` run)
        changed in every repo with -Commit, or with -Pick, a commit picked from a list of the recent ones.

    .DESCRIPTION
        Every repo of the og tree takes part: the project root and its submodules, recursively, in
        Resolve-OgRepoTree's order. A repo whose folder is missing (a submodule not checked out) is
        skipped. Four comparisons:

          (default)  the working tree vs HEAD: "what have I not committed?". Untracked files that are
                     not ignored count as changes, so a repo with only a new file opens too.
          -Staged    the index vs HEAD: "what am I about to commit?".
          -Against   HEAD vs the merge base of <ref> and HEAD, i.e. the THREE-DOT range `<ref>...HEAD`:
                     "how does my branch differ from <ref>?".
          -Commit    one root commit, i.e. one `oggitcommit` run: "what did that run change?". See
                     -Commit below.
          -Pick      the same, for a root commit you pick from a list of the recent ones. See -Pick
                     below.

        Why -Against is three dots: it is what you want when preparing a merge. On a clean working tree
        (the state you are in right before merging) the working-tree comparison reports every repo clean
        and opens nothing, which is not useful. `<ref>...HEAD` shows only what HEAD added since the
        branch point. A two-dot `<ref>..HEAD` would instead show, inverted, everything that has landed on
        <ref> since the branch point too: noise that is not your change. Get-OgRepoStatus's Ahead/Behind
        counts use the same three-dot convention (`rev-list --left-right --count origin/main...HEAD`) for
        the same reason. So the base side of an -Against diff is ALWAYS the merge base, never <ref>'s tip.

        DEFAULT: DIRECTORY DIFFS, ONE TOOL INSTANCE, ONE TAB PER CHANGED REPO. One Open-OgDirDiffSet call
        covers the whole tree:
          - each repo's comparison is listed once, read-only; a repo with no changed file is 'clean' and
            opens nothing;
          - each changed repo's CHANGED FILES ONLY are exported into a new run folder
                $env:TEMP\og-diff\<yyyyMMdd-HHmmss>-<label>\<repo>\{<base side>,<head side>}
            with the label worktree, staged or against-<ref> (made filesystem-safe and cut to 24
            characters, so a long ref name cannot push the paths past 260 characters), and each side
            named after its repo: '<repo> base <short sha>', '<repo> head <short sha>', '<repo> working'
            or '<repo> index' ('<repo> base empty' / '<repo> head empty' for an empty side). Diffinity
            titles a tab from the two folder names, so a tab reads e.g.
            'og-brawler base e289ac3 - og-brawler head db4ec6a'. A modified file is on both sides, an
            added file on the head side only, a deleted file on the base side only. A submodule is never a
            folder in its parent's diff: it is a repo of its own in the sweep, with its own tab. A side
            folder holds nothing but the exported files: its marker, a small hidden file
            '<side>.og-diff-side', sits BESIDE it in the repo folder, so the diff never lists it. Only a
            folder with its marker is ever cleared or pruned. Run folders made before this layout carry
            the marker as .og-diff-side INSIDE each side folder; that form is still accepted, so they
            still age out. The export writes paths beyond 260 characters too (git runs with
            core.longpaths=true for it, on its command line, never in a config);
          - one directory diff per changed repo is launched through the configured command, one after
            the other, with a bounded wait after the first until the tool's process is up (up to 10 s,
            only when the tool was not running yet) and a short pause before each further launch, so
            the rest land as tabs of that one instance. The wait looks for the process of the command's
            first token: a command wrapped in `cmd /c ...` names cmd, which is always running, so the
            wait is skipped and the tabs may race into separate windows;
          - RETENTION: the 10 newest run folders are kept and older ones are deleted. Only folders with
            the run layout and its markers are ever deleted; the run you just opened always survives.
            Each run has its own folder, so an earlier run's tabs that are still open keep their files.
            The og-diff\<repo>\{base,head} folders that -Against -DirDiff wrote before this layout have
            no marker and are never pruned: delete them once by hand.
        The diff tool is resolved ONCE per call, in the first repo that has a change (-Tool, else
        diff.tool, then difftool.<tool>.cmd). A repo-local difftool config in a later repo is not
        honoured in this mode; the usual global config is the same everywhere. With no tool configured,
        every changed repo reports 'failed' with a clear error and nothing is exported or launched.
        Nothing in this mode writes to any repo: no index, ref or config change (the listing and the
        export work on a temporary copy of the index). The only exception is -Fetch's own fetch, which
        updates the remote-tracking refs before anything is listed.

        WHY NEVER `git difftool --dir-diff`. It copies the sides into a temp directory, launches the
        tool, and deletes that directory the instant the tool PROCESS exits. A single-instance tool
        (Diffinity included) hands a new invocation's arguments to the already-running window and exits
        at once, so git sees the tool "finish" and deletes the files while the window still shows them:
        the panes go empty. So this cmdlet exports the sides itself into the persistent run folders
        above and launches the configured tool on them directly, in every mode. -DirDiff, which used to
        ask for that git option, is accepted and ignored.

        -PerFile: git difftool's per-file windows, as before this cmdlet opened directory diffs. For each
        repo with a change it runs `git difftool --no-prompt` (with `--cached` for -Staged, or
        `<ref>...HEAD` for -Against, and `--tool=<Tool>`), so the tool opens once per changed file and
        git manages the temp files. The "is there a change?" check before it is git's own `git diff`
        comparison, run on a TEMPORARY COPY of the repo's index: a plain `git diff --quiet` refreshes
        and rewrites .git/index (measured, even with GIT_OPTIONAL_LOCKS=0). Like git difftool, this
        check compares the working tree with the INDEX (not HEAD) and ignores untracked files: git
        difftool shows neither a staged-only change nor an untracked file, so a repo with only those is
        'clean' and opens nothing. git difftool itself is git's interactive command and may refresh the
        index's stat information, as any `git diff` does.

        To set up Diffinity once, globally:
            git config --global diff.tool diffinity
            git config --global difftool.diffinity.cmd '"C:/Path/To/Diffinity.exe" "$LOCAL" "$REMOTE"'

        Then `oggitdiff` uses Diffinity automatically. With Diffinity's tabs enabled, each changed repo
        opens as a tab of one window. The configured command is the only command line: this cmdlet never
        adds a tool flag (no -forceNewInstance, which would open a window per repo).

        -Commit <rev>: ONE COMMIT CASCADE. <rev> must name a commit in the project root. The repos it
        touched come from its own change and its submodule pin changes, followed recursively:
          - the root: `<rev>^1..<rev>` (the FIRST parent, so a merge commit shows what it brought into
            its line), only if it changed files of the root itself;
          - each submodule whose pin the commit moved: that submodule's old pin..new pin, exactly the two
            gitlink ids, never the submodule's current HEAD or branch tip; nested submodules through the
            pin changes inside that range.
        Only repos the commit touched get a result; the rest of the tree is not listed. Directory mode
        opens them in ONE run folder labelled commit-<short sha>, sides '<repo> base <sha>' /
        '<repo> head <sha>'. Each
        repo's result tells what happened:
          opened          its changed files were exported and the directory diff launched.
          clean           its pin moved but no FILE of its own changed (only nested submodule pins,
                          which are not files): FileCount 0, no tab. Its nested repos have their own
                          results. With -PerFile such a repo is 'opened': git difftool counts and
                          shows the moved pin itself.
          added           (not an Action) a submodule the commit added: the base side is empty, the
                          head side holds every file, like an added file.
          removed         (not an Action) a submodule the commit removed: the head side is empty and the
                          base side holds the old files, read from the git dir its parent kept
                          (`.git/modules/<name>`), since it has no work tree any more.
          missing-commit  a pin commit that is not present locally (never fetched), or a submodule
                          whose objects are nowhere here (not initialised, or removed together with its
                          git dir, as oggitsubrm does). Reported with the reason in Error, never fatal:
                          the other repos still open.
          failed          the listing, the export or the launch failed for that repo (see Error).
        With -PerFile, each touched repo runs `git difftool --no-prompt <old> <new>` (explicit commits)
        after the same "is there a change?" check as the other modes. A submodule the commit added or
        removed has no per-file form (git difftool cannot compare against an empty side, and a removed
        repo has no work tree to run in): it reports 'failed' with a hint to use the directory mode. The
        same goes for a root commit without a parent and for a repo present only in its parent's
        modules/ folder (no work tree).

        -Pick [-Count <n>]: THE COMMIT PICKER. Lists the project root's last <n> commits (default 30) on
        the first-parent line of HEAD, newest first, one line each:
            > 6245add  2026-10-21 23:29  root +5       Split the game-agnostic half of ...
        The columns are the short sha, the author date (local time), the repos the commit touched and
        the subject. Keys:
          Up/Down, PgUp/PgDn, Home/End   move the selection
          Enter                          open the selected commit, exactly as -Commit <its sha> would
          Esc or q                       cancel: nothing is opened and nothing is returned
        The touched column is 'root' (the root's own files) or the first touched submodule, plus how many
        more repos the commit touched, e.g. 'root +5', with '(1 missing)' when pin commits are missing
        locally and '(no changes)' for an empty commit. It shows an ellipsis (…) until that commit is
        resolved: only the commits on screen are resolved, the selected one first and each at most once,
        so the list appears at once and fills in while you look (and move). It shows '!' when a commit
        cannot be resolved; the picker keeps working and the reason is on the detail line. Such a commit
        can still be picked: Enter then fails with the same error as -Commit <its sha>. The detail line
        below the list names every repo the selected commit touched (the root by its folder name) with
        its base..head range (0000000 for an empty side) and its status when it is not a plain change:
        (added) or (removed); a (missing-commit) repo shows its name only. The ellipsis (U+2026) needs a
        console whose output encoding is UTF-8 (code page 65001); on an OEM code page such as 437 it
        shows as '?'.
        The picker draws on the console's alternate screen, so your screen and scrollback come back as they
        were when it closes (also on an error or Ctrl+C); the picked commit's results are written after
        that. It needs an interactive console: with redirected input or output (a script, a pipe, a CI
        job), or a host without virtual-terminal support, it fails before running any git command, with
        an error that says to name the commit instead: oggitdiff -Commit <sha>.
        -PerFile and -Tool apply to the picked commit as they do to -Commit.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .PARAMETER Tool
        Name of a git-configured diff tool (e.g. 'diffinity', 'vscode', 'meld'). Overrides diff.tool for
        this invocation; its command comes from difftool.<Tool>.cmd. In the default mode it is resolved
        once, in the first changed repo; with -PerFile it is passed to git difftool as --tool=<Tool>.

    .PARAMETER PerFile
        Open git difftool's per-file windows (`git difftool --no-prompt`) instead of one directory diff
        per repo. See -PerFile in the description for the change check that precedes it.

    .PARAMETER DirDiff
        Accepted for compatibility and ignored: directory diffs are now the default. It never makes this
        cmdlet run `git difftool --dir-diff` (see the description), also not together with -PerFile.

    .PARAMETER Staged
        Compare the index (staged changes) vs HEAD instead of the working tree. Mutually exclusive with
        -Against, -Commit and -Pick (different questions: staged-vs-HEAD vs branch-vs-ref vs one commit).

    .PARAMETER Against
        Compare each repo's HEAD against <ref> using the three-dot range `<ref>...HEAD`: the base side is
        `git merge-base <ref> HEAD`, never <ref>'s own tip. A repo where <ref> cannot be resolved
        (`git rev-parse --verify --quiet <ref>` fails: a different default branch, never fetched, or the
        ref simply does not exist there) reports Action 'no-ref' and is skipped; it does not abort the
        sweep across the rest of the tree. A repo where <ref> and HEAD have no merge base reports
        'failed'. Mutually exclusive with -Staged, -Commit and -Pick.

    .PARAMETER Fetch
        Only valid together with -Against. Runs 'git fetch --recurse-submodules' from the project root
        before resolving <ref> in each repo. Without this, if <ref> is a local remote-tracking ref (e.g.
        origin/main), it reflects whatever was last fetched, which can be arbitrarily stale if nobody has
        fetched recently, and the diff would silently understate how much the branch actually differs.
        Mirrors Get-OgRepoStatus's -Fetch switch. The fetch changes the repos' remote-tracking refs; the
        directory diffs themselves never write to a repo (with -PerFile, git difftool may refresh the
        index's stat information; see -PerFile in the description).

    .PARAMETER Commit
        Diff what one root commit changed across the og tree (see -Commit in the description): a sha,
        short sha or any revision that names a commit in the project root; anything else is an error
        before anything is listed. Mutually exclusive with -Staged, -Against and -Pick.

    .PARAMETER Pick
        Pick the root commit from a list in the console instead of naming it (see -Pick in the
        description), then diff it exactly like -Commit. Needs an interactive console. Mutually exclusive
        with -Staged, -Against and -Commit.

    .PARAMETER Count
        Only with -Pick: how many of the root's recent first-parent commits to list (default 30, 1 to
        10000). Only the ones on screen are resolved, so a long list costs nothing until you scroll to it.
        Given without -Pick, PowerShell prompts for the mandatory -Pick switch of that parameter set.

    .EXAMPLE
        oggitdiff
        # One Diffinity window, one directory-diff tab per repo with uncommitted changes (untracked
        # files included). The result rows name each repo's run folder (RunPath, BasePath, HeadPath).

    .EXAMPLE
        oggitdiff -PerFile
        # The per-file way: git difftool opens the tool once per modified tracked file, repo by repo.

    .EXAMPLE
        oggitdiff -Staged
        # One tab per repo with staged changes: HEAD vs the index (review what is about to be committed).

    .EXAMPLE
        oggitdiff -Against origin/main -Fetch
        # Fetches first, then one tab per repo whose branch differs from origin/main: the merge base on
        # the left, HEAD on the right, only the files the branch changed.

    .EXAMPLE
        oggitdiff -Commit 6245add
        # One tab per repo that the oggitcommit run ending in root commit 6245add touched: the root's own
        # files (6245add^1..6245add) and every submodule's pinned old..new, nested ones included, all
        # from one run folder ...\og-diff\<stamp>-commit-6245add.

    .EXAMPLE
        oggitdiff -Commit HEAD -PerFile
        # The same repos, with git difftool's per-file windows: `git difftool --no-prompt <old> <new>` in
        # each touched repo.

    .EXAMPLE
        oggitdiff -Pick
        # Lists the last 30 root commits with the repos each touched; Enter opens the selected one like
        # oggitdiff -Commit <its sha> (one tab per touched repo), Esc or q opens nothing.

    .EXAMPLE
        oggitdiff -Pick -Count 50
        # The same picker over the last 50 root commits.

    .OUTPUTS
        PSCustomObject (Og.DiffResult), one per repo whose folder exists, in tree order, with the same
        fields in every mode:
          Repo, Path, Action ('opened' | 'clean' | 'failed' | 'no-ref' | 'missing-commit'), Error, Ref,
          Range, BasePath, HeadPath, Commit, BaseRev, HeadRev, FileCount, RunPath
          With -Commit: one per repo the commit touched (not one per repo of the tree), in tree order.
          With -Pick: the same as -Commit for the picked commit, or nothing at all when cancelled.
          - Ref and Range are $null unless -Against was used; then Ref is <ref> and Range is the
            `<ref>...HEAD` string that was compared ($null for a 'no-ref' repo).
          - BaseRev/HeadRev are the full commit ids of the sides ($null for the working tree, the index,
            or a repo that failed before listing). For -Against, BaseRev is the merge base. For -Commit
            they are the repo's old and new pin ($null for an added repo's base or a removed repo's head),
            also for a missing-commit repo.
          - FileCount is the number of changed files: in the default mode the exported paths (untracked
            files included), with -PerFile the paths git difftool walks (tracked only). $null for a
            'no-ref' or 'missing-commit' repo and for one that failed before it was listed.
          - BasePath/HeadPath/RunPath are the run folder's side folders and the run folder itself, set
            whenever a directory diff was exported (also when its launch then failed, so you can open
            them by hand); $null otherwise and always with -PerFile.
          - Commit is the root commit's full id with -Commit, on every result; $null otherwise.
    #>
    [CmdletBinding(DefaultParameterSetName = 'WorkingTree')]
    param(
        [Parameter(Position = 0)]
        [string] $ProjectRoot = (Get-Location).Path,

        [string] $Tool,

        [switch] $PerFile,

        [switch] $DirDiff,

        [Parameter(ParameterSetName = 'WorkingTree')]
        [switch] $Staged,

        [Parameter(ParameterSetName = 'Against')]
        [string] $Against,

        [Parameter(ParameterSetName = 'Against')]
        [switch] $Fetch,

        [Parameter(Mandatory, ParameterSetName = 'Commit')]
        [string] $Commit,

        [Parameter(Mandatory, ParameterSetName = 'Pick')]
        [switch] $Pick,

        [Parameter(ParameterSetName = 'Pick')]
        [ValidateRange(1, 10000)]
        [int] $Count = 30
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath

    $usingPick = $PSCmdlet.ParameterSetName -eq 'Pick'
    if ($usingPick) {
        # Fail before ANY git work, the tree walk below included, when the console cannot run the picker.
        # This is the picker's own check (Invoke-OgDiffPicker runs it again), so its error, which names
        # `oggitdiff -Commit <sha>`, surfaces unchanged; it is only moved ahead of Resolve-OgRepoTree.
        Assert-OgPickerInteractive
    }

    if ($DirDiff) {
        Write-Verbose '-DirDiff is ignored: directory diffs are the default, and git difftool --dir-diff is never used.'
    }

    if ($Fetch) {
        Write-Verbose 'Fetching all remotes (git fetch --recurse-submodules)...'
        $fetchResult = Invoke-Git -WorkingDirectory $ProjectRoot `
            -Arguments 'fetch', '--recurse-submodules', '--quiet'
        if ($fetchResult.ExitCode -ne 0) {
            Write-Warning "git fetch --recurse-submodules returned non-zero: $($fetchResult.StdErr)"
        }
    }

    $tree = Resolve-OgRepoTree -ProjectRoot $ProjectRoot

    if ($usingPick) {
        # The resolver scriptblock runs INSIDE the picker's call chain and finds its variables by dynamic
        # lookup, so a name the picker also uses ($ProjectRoot, $Count, $rows, $row, ...) would resolve to
        # the PICKER's variable (od task 5a, N5). Hence the distinct names $pickRoot and $pickTree. Do not
        # "fix" this with .GetNewClosure(): the closure's new module hides this module's private functions,
        # Resolve-OgCommitRange included (measured in review 5a).
        # The tree is walked ONCE (above) and serves every row the picker resolves and the picked commit.
        $pickRoot = $ProjectRoot
        $pickTree = $tree
        $pickerArgs = @{
            ProjectRoot   = $ProjectRoot
            Count         = $Count
            TouchResolver = { param($sha) Resolve-OgCommitRange -ProjectRoot $pickRoot -Commit $sha -RepoTree $pickTree }
            # 4a's summary, not the picker's default: it names the root 'root' (the default would print the
            # project folder's name, which does not fit the 12-character column) and counts missing pins.
            TouchSummary  = { param($entries) Get-OgCommitTouchSummary -Entry $entries }
        }
        # Assigned, never piped into the diff: the diff below must start only after Invoke-OgDiffPicker has
        # RETURNED, i.e. left the alternate screen, so its warnings, results and the tool launch land on the
        # user's own screen and not on the picker's. The picker itself also emits its row only after leaving
        # the screen (od task 5a, R1); the assignment keeps that order even if the picker ever changes.
        $picked = Invoke-OgDiffPicker @pickerArgs
        if ($null -eq $picked) {
            Write-Verbose 'Pick cancelled: nothing opened.'
            return
        }
        # From here on -Pick IS -Commit <the picked sha>: same resolver, slots, label and -PerFile path.
        $Commit = $picked.Sha
    }

    $usingCommit  = $PSCmdlet.ParameterSetName -in 'Commit', 'Pick'
    $usingAgainst = -not [string]::IsNullOrEmpty($Against)
    $kind         = if ($usingAgainst -or $usingCommit) { 'Range' } elseif ($Staged) { 'Staged' } else { 'WorkingTree' }

    # Default mode: results are collected in tree order and emitted after ONE Open-OgDirDiffSet call, so
    # that every changed repo opens in one tool instance. Each slot is either a finished result (no-ref,
    # failed merge base, missing-commit) or the index of its request in $requests.
    $slots    = [System.Collections.Generic.List[object]]::new()
    $requests = [System.Collections.Generic.List[object]]::new()

    if ($usingCommit) {
        # Throws a clear error when -Commit does not name a commit in the root (nothing is listed then).
        $entries = @(Resolve-OgCommitRange -ProjectRoot $ProjectRoot -Commit $Commit -RepoTree $tree)
        $rootSha = (Invoke-Git -WorkingDirectory $ProjectRoot `
            -Arguments 'rev-parse', '--verify', '--quiet', "$Commit^{commit}").StdOut.Trim()
        $shortSha = $rootSha.Substring(0, [Math]::Min(7, $rootSha.Length))
        $label    = "commit-$shortSha"
        if ($entries.Count -eq 0) {
            Write-Warning "Commit $shortSha changed no file and no submodule pin in '$ProjectRoot'."
        }
    }

    foreach ($entry in $(if ($usingCommit) { $entries } else { @() })) {
        # The entries come in tree order (root, then depth-first) and name only the repos the commit
        # touched. The ranges ARE the pins (Resolve-OgCommitRange): never replace them with a submodule's
        # HEAD or tip, which may have moved on since this commit.
        $repo    = [PSCustomObject]@{ Name = $entry.Repo; Path = $entry.Path; AbsolutePath = $entry.WorkingDirectory }
        $display = if ([string]::IsNullOrEmpty($entry.Path)) { $entry.Repo } else { $entry.Path }
        $revs    = @{ BaseRev = $entry.BaseRev; HeadRev = $entry.HeadRev; Commit = $rootSha }

        # Not diffable: a pin commit missing locally, or no repo found to read the commits from (GitDir ''
        # without a work tree: never initialised, or removed with its git dir by oggitsubrm). Reported,
        # never fatal. A removed submodule whose git dir is still kept IS diffable (git-dir mode below).
        if ($entry.Status -eq 'missing-commit' -or (-not $entry.HasWorkTree -and [string]::IsNullOrEmpty($entry.GitDir))) {
            $reason = if ($entry.Error) { $entry.Error } else { "No git dir found for '$display'." }
            Write-Warning "Skipped '$display' (missing-commit): $reason"
            $result = New-OgDiffResult -Repo $repo -Action 'missing-commit' -ErrorMessage $reason @revs
            if ($PerFile) { $result } else { $slots.Add($result) }
            continue
        }

        if ($PerFile) {
            # git difftool needs two commits AND a work tree to run in. An added or removed submodule has an
            # empty side, and a removed one (or one present only under modules/) has no work tree: there is
            # no per-file equivalent, so say so instead of opening nothing or the wrong repo.
            $why = if (-not $entry.HasWorkTree) { 'it has no work tree here (removed, or present only in its parent''s modules/)' }
                   elseif ([string]::IsNullOrEmpty($entry.BaseRev)) { 'the commit added it (empty base side)' }
                   elseif ([string]::IsNullOrEmpty($entry.HeadRev)) { 'the commit removed it (empty head side)' }
                   else { $null }
            if ($why) {
                $message = "No per-file diff for '$display': $why, which git difftool cannot show. " +
                    "Use the directory mode: oggitdiff -Commit $shortSha"
                Write-Warning $message
                New-OgDiffResult -Repo $repo -Action 'failed' -ErrorMessage $message @revs
                continue
            }
            Invoke-OgPerFileDiff -Repo $repo -Kind 'Range' -Tool $Tool @revs
            continue
        }

        $requestArgs = @{
            Repo = $entry.Repo; Path = $entry.Path; WorkingDirectory = $entry.WorkingDirectory; Kind = 'Range'
            BaseRev = $entry.BaseRev; HeadRev = $entry.HeadRev; Commit = $rootSha
        }
        # No work tree (a submodule the commit removed): its commits are only in the git dir its parent
        # kept, so the engine reads them from there (git-dir mode). Never export such an entry from
        # WorkingDirectory: git run there finds the PARENT repo (od task 4a).
        if (-not $entry.HasWorkTree) { $requestArgs.GitDir = $entry.GitDir }
        $slots.Add([int] $requests.Count)
        $requests.Add((New-OgDirDiffRequest @requestArgs))
    }

    foreach ($repo in $(if ($usingCommit) { @() } else { $tree })) {
        $absPath = $repo.AbsolutePath
        if (-not (Test-Path -LiteralPath $absPath)) { continue }

        # Resolve <ref> per repo: it may not exist here (different default branch, never fetched, or
        # simply absent). A miss must not abort the sweep of the remaining repos.
        $range     = $null
        $mergeBase = $null
        if ($usingAgainst) {
            $resolveResult = Invoke-Git -WorkingDirectory $absPath `
                -Arguments 'rev-parse', '--verify', '--quiet', $Against
            if ($resolveResult.ExitCode -ne 0) {
                $result = New-OgDiffResult -Repo $repo -Action 'no-ref' -Ref $Against
                if ($PerFile) { $result } else { $slots.Add($result) }
                continue
            }
            $range = "$Against...HEAD"

            # ⭐ The base side is `merge-base <ref> HEAD`, never <ref> itself: that IS the three-dot
            # semantics (see .DESCRIPTION). Diffing or exporting <ref>'s own tip would silently bring
            # back the two-dot bug: everything <ref> gained since the branch point would show as
            # deleted by this branch.
            $mergeBaseResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'merge-base', $Against, 'HEAD'
            if ($mergeBaseResult.ExitCode -ne 0) {
                $mergeBaseError = if ($mergeBaseResult.StdErr) { $mergeBaseResult.StdErr }
                                  else { "'$Against' and HEAD have no merge base." }
                $display = if ([string]::IsNullOrEmpty($repo.Path)) { $repo.Name } else { $repo.Path }
                Write-Warning "git merge-base failed in '$display': $mergeBaseError"
                $result = New-OgDiffResult -Repo $repo -Action 'failed' -ErrorMessage $mergeBaseError `
                    -Ref $Against -Range $range
                if ($PerFile) { $result } else { $slots.Add($result) }
                continue
            }
            $mergeBase = $mergeBaseResult.StdOut.Trim()
        }

        if ($PerFile) {
            Invoke-OgPerFileDiff -Repo $repo -Kind $kind -MergeBase $mergeBase -Ref $Against -Range $range -Tool $Tool
            continue
        }

        $requestArgs = @{ Repo = $repo.Name; Path = $repo.Path; WorkingDirectory = $absPath; Kind = $kind }
        if ($usingAgainst) {
            $requestArgs.BaseRev = $mergeBase
            $requestArgs.HeadRev = 'HEAD'
            $requestArgs.Ref     = $Against
            $requestArgs.Range   = $range
        }
        $slots.Add([int] $requests.Count)
        $requests.Add((New-OgDirDiffRequest @requestArgs))
    }

    if ($PerFile) { return }

    $setResults = @()
    if ($requests.Count -gt 0) {
        if (-not $usingCommit) {
            $label = switch ($kind) { 'Range' { "against-$Against" } 'Staged' { 'staged' } default { 'worktree' } }
        }
        # @() on purpose: one request gives one bare result, which must still index as element 0.
        $setResults = @(Open-OgDirDiffSet -Request $requests.ToArray() -Label $label -Tool $Tool)
    }

    foreach ($slot in $slots) {
        if ($slot -is [int]) { $setResults[$slot] } else { $slot }
    }
}
