# SPDX-License-Identifier: MPL-2.0

# The per-run layout and the single-instance launcher behind every og directory diff (Backlog od task 2,
# D2 and D3).
#
# One Open-OgDirDiffSet call is one RUN. Every repo with a change is exported by the task 1 engine
# (Get-OgDiffChange / Export-OgDiffSides) into
#
#     <GetTempPath()>\og-diff\<yyyyMMdd-HHmmss>-<label>\<repo>\{<baseLabel>,<headLabel>}
#
# e.g. ...\20261023-094100-commit-6245add\og-brawler\{og-brawler base e289ac3, og-brawler head db4ec6a},
# and opened as one directory diff; all of them are meant to land as tabs of ONE instance of the tool.
# Why each piece is the way it is:
#
#   - SIDE FOLDERS NAME THEIR REPO (od task 7). Diffinity titles a folder-diff tab '<left name> - <right
#     name>' from the two folder names alone, so the repo is part of each side's name
#     (Get-OgDiffSideLabel). The engine's marker sits beside each side folder, never inside it
#     (Export-OgDiffSides.ps1), so a tab lists nothing but the exported files.
#   - A NEW FOLDER PER RUN. Runs never overwrite each other, so the tabs of an earlier run that are
#     still open keep their files. Old runs beyond -Keep are pruned by Remove-OgDiffOldRun, which has
#     its own strict rule (Test-OgDiffRunFolder) because it is a recursive delete outside the engine.
#   - SEQUENTIAL LAUNCHES WITH A WAIT. A single-instance tool (Diffinity with tabs) turns a new
#     invocation into a tab of the running instance only if that instance is already up. Launches fired
#     back to back race: each finds no instance yet and opens its own window. So after the first launch
#     the launcher waits, bounded, until the tool's process exists, then launches the rest one by one
#     with a short pause between them.
#   - THE CONFIGURED COMMAND ONLY. Every launch is `difftool.<tool>.cmd` with $LOCAL/$REMOTE substituted,
#     through Start-OgDiffToolProcess. Never add a tool-specific flag here (no -forceNewInstance, no
#     -folderDiff, no -bringToFront): the user's config stays the one source of the command line, so
#     any other configured tool keeps working.
#   - NEVER `git difftool --dir-diff` (see Export-OgDiffSides.ps1 and Show-OgDiff): with no tool
#     configured, the repos with changes fail with a clear error instead.

# Every run folder name starts with this timestamp. Test-OgDiffRunFolder matches it, so keep the two in
# step: the prune deletes nothing whose name does not parse back with this exact format.
$script:OgDiffRunStampFormat = 'yyyyMMdd-HHmmss'

# The run label's cap in the run folder name (od task 6). Short ON PURPOSE: every exported file's path is
# <TEMP>\og-diff\<stamp>-<label>\<repo>\<side>\<repo path>, and a long label (a long -Against ref name)
# plus a deep repo path passed 260 characters (od review 3). 24 keeps every built-in label whole
# ('worktree', 'staged', 'commit-<7>', 'against-origin/main') and cuts only a long ref name. Long paths
# beyond that are the export's job (core.longpaths, Export-OgDiffSides.ps1); this cap keeps ordinary runs
# well under the limit, which matters to tools that cannot open a longer path. Since od task 7 <side>
# starts with <repo> too ('<repo> base <sha7>'), which adds the repo folder name once more to every path.
$script:OgDiffRunLabelMaxLength = 24

function New-OgDirDiffRequest {
    <#
    .SYNOPSIS
        Builds one per-repo request for Open-OgDirDiffSet: which repo, and which comparison to open.

    .DESCRIPTION
        The request type every directory-diff mode shares (working tree, -Staged, -Against, a commit).
        It is validated here, and again by Open-OgDirDiffSet, so a hand-built object with the same
        properties works too.

    .PARAMETER Repo
        The repo's name (Resolve-OgRepoTree's Name, the folder leaf). Names the repo folder in the run
        unless two requests share it (see Get-OgDiffRepoFolderName).

    .PARAMETER Path
        The repo's path relative to the og tree root ('' for the root itself). Carried onto the result and
        used to tell apart two repos with the same name.

    .PARAMETER WorkingDirectory
        The repo's work tree (any folder inside it).

    .PARAMETER Kind
        WorkingTree, Staged or Range, as Get-OgDiffChange.

    .PARAMETER BaseRev
        Range only, and required for Range: the base revision, or '' for an empty base (an added repo).

    .PARAMETER HeadRev
        Range only, and required for Range: the head revision, or '' for an empty head (a removed repo).

    .PARAMETER Ref
        Optional, carried onto the result unchanged (Show-OgDiff -Against's ref).

    .PARAMETER Range
        Optional, carried onto the result unchanged (e.g. 'origin/main...HEAD').

    .PARAMETER Commit
        Optional, carried onto the result unchanged (the root commit a -Commit diff was made for).

    .PARAMETER GitDir
        Range only, optional: read the comparison from this fully qualified git dir instead of the work
        tree (the engine's git-dir mode), for a repo that has no work tree, e.g. a submodule removed by
        the commit being diffed. WorkingDirectory is then only where the repo was (it may not exist).

    .OUTPUTS
        PSCustomObject (Og.DirDiffRequest): Repo, Path, WorkingDirectory, Kind, BaseRev, HeadRev, Ref,
        Range, Commit, GitDir. BaseRev/HeadRev are $null unless Kind is Range; GitDir is $null unless given.

    .EXAMPLE
        New-OgDirDiffRequest -Repo og-tools -Path tools/og-tools -WorkingDirectory C:\dev\proj\tools\og-tools `
            -Kind Range -BaseRev $old -HeadRev $new
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Repo,

        [AllowEmptyString()]
        [string] $Path = '',

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory)]
        [ValidateSet('WorkingTree', 'Staged', 'Range')]
        [string] $Kind,

        [AllowEmptyString()]
        [string] $BaseRev,

        [AllowEmptyString()]
        [string] $HeadRev,

        [string] $Ref,

        [string] $Range,

        [string] $Commit,

        [AllowEmptyString()]
        [string] $GitDir
    )

    # A [string] parameter turns $null into '', and '' MEANS something for a Range (the empty side), so
    # "given" is read from $PSBoundParameters, never from the value.
    $hasBase = $PSBoundParameters.ContainsKey('BaseRev')
    $hasHead = $PSBoundParameters.ContainsKey('HeadRev')
    if ($Kind -eq 'Range' -and -not ($hasBase -and $hasHead)) {
        throw "New-OgDirDiffRequest -Kind Range needs both -BaseRev and -HeadRev ('' for an empty side)."
    }
    if ($Kind -ne 'Range' -and ($hasBase -or $hasHead)) {
        throw "New-OgDirDiffRequest -Kind $Kind compares against HEAD; -BaseRev/-HeadRev belong to -Kind Range."
    }
    if ($Kind -ne 'Range' -and -not [string]::IsNullOrEmpty($GitDir)) {
        throw "New-OgDirDiffRequest -GitDir belongs to -Kind Range; -Kind $Kind needs the repo's work tree."
    }

    [PSCustomObject]@{ PSTypeName = 'Og.DirDiffRequest';
        Repo             = $Repo
        Path             = $Path
        WorkingDirectory = $WorkingDirectory
        Kind             = $Kind
        BaseRev          = $(if ($hasBase) { $BaseRev } else { $null })
        HeadRev          = $(if ($hasHead) { $HeadRev } else { $null })
        Ref              = $(if ($PSBoundParameters.ContainsKey('Ref'))    { $Ref }    else { $null })
        Range            = $(if ($PSBoundParameters.ContainsKey('Range'))  { $Range }  else { $null })
        Commit           = $(if ($PSBoundParameters.ContainsKey('Commit')) { $Commit } else { $null })
        GitDir           = $(if ([string]::IsNullOrEmpty($GitDir)) { $null } else { $GitDir })
    }
}

function Open-OgDirDiffSet {
    <#
    .SYNOPSIS
        Exports every requested repo's changes into one new run folder and opens one directory diff per
        changed repo, all meant as tabs of one instance of the configured diff tool.

    .DESCRIPTION
        For each request, in order:
          1. lists the comparison once (Get-OgDiffChange); a repo with no changed file is 'clean' and is
             neither exported nor launched; a listing error makes that repo 'failed';
        then, if any repo changed:
          2. resolves the tool command ONCE (Resolve-OgDiffToolCommand, in the first changed repo that has
             a work tree; see Get-OgDirDiffToolDirectory for a set of git-dir requests only). With
             none, every changed repo is 'failed' with a clear error, nothing is exported and nothing is
             launched; there is never a fallback to `git difftool --dir-diff`;
          3. creates the run folder <GetTempPath()>\og-diff\<yyyyMMdd-HHmmss>-<label> (the label made
             safe and cut to 24 characters; a '-2', '-3' ... suffix if that name already exists, so a run
             never overwrites another);
          4. exports each changed repo into <run>\<repo>\{<baseLabel>,<headLabel>} with
             Export-OgDiffSides -ChangeSet (no second listing). Side labels repeat the repo folder name
             (Get-OgDiffSideLabel): '<repo> base <short sha>', '<repo> head <short sha>', '<repo> working',
             '<repo> index', '<repo> base empty' / '<repo> head empty'. The engine writes each side's
             marker beside it, '<repo>\<side label>.og-diff-side';
          5. launches one directory diff per exported repo, in request order, through
             Start-OgDiffToolProcess:
               - before the first launch it probes whether the tool is already running
                 (Test-OgDiffToolProcessRunning; the exe is the command line's first token);
               - if it was not, then after the first successful launch and before the second it waits,
                 bounded by -ProbeTimeoutMilliseconds, until the tool's process is up. A timeout is a
                 warning; the rest are launched anyway;
               - every further launch is preceded by a -LaunchPauseMilliseconds pause;
               - a launch that fails is reported for that repo and the rest still launch;
          6. prunes old runs beyond -Keep (Remove-OgDiffOldRun; the current run always survives).

    .PARAMETER Request
        Og.DirDiffRequest objects (New-OgDirDiffRequest), or objects with the same properties (GitDir may
        be absent: the normal mode).

    .PARAMETER Label
        Names the run folder after its timestamp, e.g. 'worktree', 'staged', 'against-origin/main',
        'commit-6245add'. Made filesystem-safe: every character outside [A-Za-z0-9._-] becomes '-', and
        cut to 24 characters (so a long ref name cannot push the exported paths past 260 characters).

    .PARAMETER Tool
        A git-configured diff tool name overriding diff.tool, as Show-OgDiff -Tool.

    .PARAMETER Keep
        How many runs to keep under og-diff, the current one included (default 10).

    .PARAMETER ProbeTimeoutMilliseconds
        The bound on the wait for the tool's process after the first launch (default 10000).

    .PARAMETER ProbeIntervalMilliseconds
        How often the process is probed during that wait (default 100).

    .PARAMETER LaunchPauseMilliseconds
        The pause before each launch after the first (default 300).

    .OUTPUTS
        PSCustomObject (Og.DiffResult), one per request in request order: Repo, Path, Action ('opened' |
        'clean' | 'failed'), Error, Ref, Range, BasePath, HeadPath, Commit, BaseRev, HeadRev, FileCount,
        RunPath.
          - Ref, Range and Commit are the request's, carried unchanged.
          - BaseRev/HeadRev are the full commit ids the sides were taken from ($null for the working tree,
            the index or an empty side); after a listing error, the request's revs as given.
          - FileCount is the listing's count ($null after a listing error). It can exceed the files on
            disk: a working-tree file that vanished before the copy is skipped with a warning.
          - BasePath, HeadPath and RunPath are set whenever the export succeeded, also when the launch
            then failed, so the folders can be opened by hand.

    .EXAMPLE
        $req = New-OgDirDiffRequest -Repo proj -WorkingDirectory C:\dev\proj -Kind WorkingTree
        Open-OgDirDiffSet -Request $req -Label worktree
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Request,

        [Parameter(Mandatory)]
        [string] $Label,

        [string] $Tool,

        [ValidateRange(1, 10000)]
        [int] $Keep = 10,

        [ValidateRange(0, 600000)]
        [int] $ProbeTimeoutMilliseconds = 10000,

        [ValidateRange(1, 60000)]
        [int] $ProbeIntervalMilliseconds = 100,

        [ValidateRange(0, 60000)]
        [int] $LaunchPauseMilliseconds = 300
    )

    $requests = @($Request)
    for ($i = 0; $i -lt $requests.Count; $i++) { Assert-OgDirDiffRequest -Request $requests[$i] -Index $i }

    # Resolved and checked before anything else: the prune below enumerates and deletes inside it.
    $runRoot = Assert-OgDiffRunRoot -Path (Get-OgDiffRunRoot)

    $results = [object[]]::new($requests.Count)
    $pending = [System.Collections.Generic.List[object]]::new()

    # 1. List every repo once.
    for ($i = 0; $i -lt $requests.Count; $i++) {
        $req = $requests[$i]
        $listArgs = @{ WorkingDirectory = $req.WorkingDirectory; Kind = $req.Kind }
        if ($req.Kind -eq 'Range') { $listArgs.BaseRev = [string] $req.BaseRev; $listArgs.HeadRev = [string] $req.HeadRev }
        $reqGitDir = Get-OgDirDiffRequestGitDir -Request $req
        if ($reqGitDir) { $listArgs.GitDir = $reqGitDir }
        try {
            $changeSet = Get-OgDiffChange @listArgs
        } catch {
            Write-Warning "Listing the changes failed in '$(Get-OgDirDiffDisplayName $req)': $($_.Exception.Message)"
            $results[$i] = New-OgDirDiffResult -Request $req -Action 'failed' -ErrorMessage $_.Exception.Message
            continue
        }
        if ($changeSet.FileCount -eq 0) {
            $results[$i] = New-OgDirDiffResult -Request $req -Action 'clean' -ChangeSet $changeSet
            continue
        }
        $pending.Add([PSCustomObject]@{ Index = $i; Request = $req; ChangeSet = $changeSet })
    }

    if ($pending.Count -gt 0) {
        # 2. The tool, once, before anything is written: no tool means nothing to show the exports in.
        $template = Resolve-OgDiffToolCommand -Tool $Tool `
            -WorkingDirectory (Get-OgDirDiffToolDirectory -Request @($pending | ForEach-Object Request))
        if ([string]::IsNullOrEmpty($template)) {
            $toolText = if ($Tool) { "No command configured for diff tool '$Tool' (difftool.$Tool.cmd)" }
                        else { 'No difftool configured (set diff.tool / difftool.<tool>.cmd, or pass -Tool)' }
            $noToolMessage = "$toolText. Refusing to fall back to 'git difftool --dir-diff', which deletes its " +
                'temp dirs while a single-instance tool still shows them.'
            Write-Warning $noToolMessage
            foreach ($p in $pending) {
                $results[$p.Index] = New-OgDirDiffResult -Request $p.Request -Action 'failed' `
                    -ErrorMessage $noToolMessage -ChangeSet $p.ChangeSet
            }
        } else {
            # 3. + 4. One new run folder, one repo folder per changed repo.
            $runPath     = New-OgDiffRunFolder -RunRoot $runRoot -Name (
                (Get-OgDiffNow).ToString($script:OgDiffRunStampFormat, [System.Globalization.CultureInfo]::InvariantCulture) +
                '-' + (ConvertTo-OgDiffPathLabel -Text $Label -Fallback 'diff' -MaxLength $script:OgDiffRunLabelMaxLength))
            # @() on purpose: with one changed repo the function returns a bare string, and indexing a
            # string gives its first CHARACTER (the repo 'alpha' would export into folder 'a').
            $folderNames = @(Get-OgDiffRepoFolderName -Request @($pending | ForEach-Object Request))
            $exported    = [System.Collections.Generic.List[object]]::new()

            for ($k = 0; $k -lt $pending.Count; $k++) {
                $p       = $pending[$k]
                $labels  = Get-OgDiffSideLabel -ChangeSet $p.ChangeSet -RepoFolderName $folderNames[$k]
                $repoDir = Join-Path $runPath $folderNames[$k]
                $basePath = Join-Path $repoDir $labels.Base
                $headPath = Join-Path $repoDir $labels.Head
                try {
                    # The engine refuses anything but a fully qualified destination; this check names the
                    # cause (a run root that is not one) before the engine's generic refusal would.
                    foreach ($dest in $basePath, $headPath) {
                        if (-not [System.IO.Path]::IsPathFullyQualified($dest)) {
                            throw "The export destination '$dest' is not fully qualified."
                        }
                    }
                    $sides = Export-OgDiffSides -ChangeSet $p.ChangeSet -BaseDestination $basePath -HeadDestination $headPath
                } catch {
                    Write-Warning "Export failed in '$(Get-OgDirDiffDisplayName $p.Request)': $($_.Exception.Message)"
                    $results[$p.Index] = New-OgDirDiffResult -Request $p.Request -Action 'failed' `
                        -ErrorMessage $_.Exception.Message -ChangeSet $p.ChangeSet
                    continue
                }
                $exported.Add([PSCustomObject]@{
                    Index = $p.Index; Request = $p.Request; ChangeSet = $p.ChangeSet
                    BasePath = $sides.BaseDestination; HeadPath = $sides.HeadDestination
                })
            }

            # 5. Launch.
            $launches = Invoke-OgDirDiffLaunch -Exported $exported -CommandTemplate $template `
                -ProbeTimeoutMilliseconds $ProbeTimeoutMilliseconds -ProbeIntervalMilliseconds $ProbeIntervalMilliseconds `
                -LaunchPauseMilliseconds $LaunchPauseMilliseconds
            foreach ($e in $exported) {
                $launch = $launches[$e.Index]
                $action = if ($launch.Launched) { 'opened' } else { 'failed' }
                $results[$e.Index] = New-OgDirDiffResult -Request $e.Request -Action $action -ErrorMessage $launch.Error `
                    -ChangeSet $e.ChangeSet -BasePath $e.BasePath -HeadPath $e.HeadPath -RunPath $runPath
            }

            if ($exported.Count -eq 0) {
                # Every export failed before writing anything: drop the empty run folder we just made.
                # Non-recursive on purpose: if a failed export left side folders behind, this throws and
                # the run stays, shaped like any other run, for the prune to take later.
                try { [System.IO.Directory]::Delete($runPath, $false) } catch { Write-Verbose "Run folder kept: $runPath" }
            }

            # 6. Prune. NEVER FATAL: the diffs are already open, so a prune problem (an unreadable og-diff
            # folder, a concurrent run's prune) is a warning and must never cost the caller these results.
            # Remove-OgDiffOldRun is built not to throw; this catch is the second line, not the first.
            if (Test-Path -LiteralPath $runPath) {
                try {
                    $null = Remove-OgDiffOldRun -RunRoot $runRoot -CurrentRun $runPath -Keep $Keep
                } catch {
                    Write-Warning "Pruning old og diff runs under '$runRoot' failed: $($_.Exception.Message)"
                }
            }
        }
    }

    $results
}

function Invoke-OgDirDiffLaunch {
    <#
    .SYNOPSIS
        Launches one directory diff per exported repo, in order, so they land in ONE tool instance: probe,
        first launch, bounded wait for the process, then the rest with a pause before each.

    .DESCRIPTION
        The probe runs once, before the first launch. If the tool is already running, the wait is skipped
        (the running instance takes every launch as a tab), but the pauses stay. Otherwise the wait runs
        once, after the first launch that succeeded and before the next one: if the first repo's launch
        fails, the next repo's launch is the one that starts the instance, so the wait follows that one.

        A launch is a failure only when Start-OgDiffToolProcess says Launched = $false: only an immediate
        failure is observable for a fire-and-forget GUI launch (see Start-OgDiffToolProcess).

        With no exe derivable from the command line, nothing can be probed: the launches are only paused.

    .OUTPUTS
        Hashtable: request index -> @{ Launched; Error }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Exported,
        [Parameter(Mandatory)] [string] $CommandTemplate,
        [Parameter(Mandatory)] [int] $ProbeTimeoutMilliseconds,
        [Parameter(Mandatory)] [int] $ProbeIntervalMilliseconds,
        [Parameter(Mandatory)] [int] $LaunchPauseMilliseconds
    )

    $outcome = @{}
    if ($Exported.Count -eq 0) { return $outcome }

    $first   = $Exported[0]
    $exePath = Get-OgDiffToolExePath -CommandLine (Expand-OgDiffToolCommand -CommandTemplate $CommandTemplate `
        -LocalPath $first.BasePath -RemotePath $first.HeadPath)
    $mustWait = $false
    if ($exePath) {
        $mustWait = -not (Test-OgDiffToolProcessRunning -ExePath $exePath)
    } else {
        Write-Verbose "No executable in the diff tool command; launching without the process wait: $CommandTemplate"
    }

    $launchedAny = $false
    for ($i = 0; $i -lt $Exported.Count; $i++) {
        $e = $Exported[$i]
        if ($launchedAny) {
            if ($mustWait) {
                $mustWait = $false
                if (-not (Wait-OgDiffToolProcess -ExePath $exePath -TimeoutMilliseconds $ProbeTimeoutMilliseconds `
                        -IntervalMilliseconds $ProbeIntervalMilliseconds)) {
                    Write-Warning ("The diff tool process '$exePath' did not appear within $ProbeTimeoutMilliseconds ms " +
                        "after the first launch. Launching the remaining $($Exported.Count - $i) repo(s) anyway; " +
                        'they may open in a separate window.')
                }
            }
            Start-OgDiffSleep -Milliseconds $LaunchPauseMilliseconds
        }

        $commandLine = Expand-OgDiffToolCommand -CommandTemplate $CommandTemplate -LocalPath $e.BasePath -RemotePath $e.HeadPath
        Write-Verbose "Launching directory diff for '$(Get-OgDirDiffDisplayName $e.Request)': $commandLine"
        $launch = Start-OgDiffToolProcess -CommandLine $commandLine

        # A launch that did not start is NOT 'opened': the result must never claim a window the user never
        # saw. $null (no report) counts as started: only Launched = $false is a reported failure.
        if ($null -ne $launch -and -not $launch.Launched) {
            $launchError = if ($launch.Detail) { $launch.Detail } else { 'The diff tool failed to launch.' }
            Write-Warning "Diff tool failed to launch for '$(Get-OgDirDiffDisplayName $e.Request)': $launchError"
            $outcome[$e.Index] = @{ Launched = $false; Error = $launchError }
            continue
        }
        $launchedAny = $true
        $outcome[$e.Index] = @{ Launched = $true; Error = $null }
    }
    $outcome
}

function Wait-OgDiffToolProcess {
    <#
    .SYNOPSIS
        Waits, bounded, until the diff tool's process is running. Returns $true when it is, $false on
        timeout.

    .DESCRIPTION
        Probes, then sleeps -IntervalMilliseconds, until the probe succeeds or the summed sleeps reach
        -TimeoutMilliseconds (one last probe is made at the bound). The elapsed time is the sum of the
        sleeps, not a stopwatch, ON PURPOSE: with the sleep seam mocked, a stopwatch would make a test of
        the timeout spin for the real 10 s; summed sleeps keep the bound exact and the test instant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ExePath,
        [Parameter(Mandatory)] [int] $TimeoutMilliseconds,
        [Parameter(Mandatory)] [ValidateRange(1, [int]::MaxValue)] [int] $IntervalMilliseconds
    )

    $waited = 0
    while ($true) {
        if (Test-OgDiffToolProcessRunning -ExePath $ExePath) { return $true }
        if ($waited -ge $TimeoutMilliseconds) { return $false }
        $step = [Math]::Min($IntervalMilliseconds, $TimeoutMilliseconds - $waited)
        Start-OgDiffSleep -Milliseconds $step
        $waited += $step
    }
}

function Test-OgDiffToolProcessRunning {
    <#
    .SYNOPSIS
        Process probe seam: is a process of the given diff tool executable running?

    .DESCRIPTION
        A single small function so Pester can mock it; the launcher never inspects processes any other
        way. Matches by process name (the exe's file name without extension). For a rooted -ExePath, a
        process whose path is readable must also match it (case-insensitive); a process whose path cannot
        be read (another user's, elevated) counts as a match, because the name already matched and the
        cost of a false "running" is only a skipped wait.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ExePath
    )

    $name = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    if ([string]::IsNullOrEmpty($name)) { return $false }

    $processes = @(Get-Process -Name ([WildcardPattern]::Escape($name)) -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { return $false }
    if (-not [System.IO.Path]::IsPathRooted($ExePath)) { return $true }

    $full = [System.IO.Path]::GetFullPath($ExePath)
    foreach ($process in $processes) {
        $processPath = try { $process.Path } catch { $null }
        if ([string]::IsNullOrEmpty($processPath) -or
            [string]::Equals($processPath, $full, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

function Get-OgDiffToolExePath {
    <#
    .SYNOPSIS
        Returns the executable of an expanded diff tool command line: its first quoted token, or its first
        whitespace-delimited token when it does not start with a quote. $null for an empty line.

    .DESCRIPTION
        Pure. `difftool.<tool>.cmd` quotes the tool path as its first token, e.g.
            "C:\Program Files\Diffinity\Diffinity.exe" "$LOCAL" "$REMOTE"
        and that path is what the process probe looks for.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $CommandLine
    )

    $line = $CommandLine.TrimStart()
    if ($line.Length -eq 0) { return $null }
    if ($line[0] -eq '"') {
        $end = $line.IndexOf('"', 1)
        $token = if ($end -lt 0) { $line.Substring(1) } else { $line.Substring(1, $end - 1) }
    } else {
        $token = ($line -split '\s+', 2)[0]
    }
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }
    $token
}

function Start-OgDiffSleep {
    <#
    .SYNOPSIS
        Sleep seam: waits the given milliseconds. A single small function so Pester can mock it and the
        launcher's pauses and probe waits cost no real time in tests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Milliseconds
    )

    if ($Milliseconds -gt 0) { Start-Sleep -Milliseconds $Milliseconds }
}

function Get-OgDiffNow {
    <#
    .SYNOPSIS
        Clock seam: the current local time, which names the run folder. A single small function so
        Pester can pin the run folder's name.

    .DESCRIPTION
        Local time on purpose: the user reads the folder names (and Diffinity's tab paths). Across a
        daylight-saving fall-back, two runs an hour apart can sort out of order for the prune; that hour's
        runs are the only ones affected.
    #>
    [CmdletBinding()]
    param()

    [datetime]::Now
}

function Get-OgDiffRunRoot {
    <#
    .SYNOPSIS
        Run-root seam: <GetTempPath()>\og-diff, the folder that holds every run folder.

    .DESCRIPTION
        A single small function so Pester can point the runs (and the prune) at $TestDrive instead of the
        user's real temp folder. Built from [System.IO.Path]::GetTempPath(), which is fully qualified;
        Open-OgDirDiffSet still checks the result with Assert-OgDiffRunRoot.
    #>
    [CmdletBinding()]
    param()

    Join-Path ([System.IO.Path]::GetTempPath()) 'og-diff'
}

function Assert-OgDiffRunRoot {
    <#
    .SYNOPSIS
        Returns the run root's normalized full path, or throws unless it is a fully qualified, non-root
        folder named 'og-diff'.

    .DESCRIPTION
        The prune enumerates this folder and deletes inside it, so a wrong root (a relative path, a drive
        root, TEMP itself after an empty Join-Path component) must never reach it. The leaf name check
        pins the prune to an og-diff folder whatever the seam returns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathFullyQualified($Path)) {
        throw "Refusing og-diff run root '$Path': it must be a fully qualified path."
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\', '/') -eq $root.TrimEnd('\', '/')) {
        throw "Refusing og-diff run root '$Path': it is the root '$root'."
    }
    $full = $full.TrimEnd('\', '/')
    if (-not [string]::Equals((Split-Path -Path $full -Leaf), 'og-diff', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing og-diff run root '$full': its folder must be named 'og-diff'."
    }
    $full
}

function ConvertTo-OgDiffPathLabel {
    <#
    .SYNOPSIS
        Makes text safe as ONE folder name: every run of characters outside [A-Za-z0-9._-] becomes a
        single '-', leading/trailing '-' and '.' are trimmed, the length is capped, and a Windows device
        name (CON, NUL, COM1 ...) gets a '_' prefix. Returns -Fallback for an empty result.

    .DESCRIPTION
        Pure. Ref names carry '/' (origin/main) and ':' is reserved on Windows, so a label or a repo path
        could otherwise create nested folders or fail. The prune's name pattern (Test-OgDiffRunFolder)
        relies on the run label staying inside this character set.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [AllowNull()] [string] $Text,
        [Parameter(Mandatory)] [string] $Fallback,
        [int] $MaxLength = 60
    )

    $s = [regex]::Replace([string] $Text, '[^A-Za-z0-9._-]+', '-')
    $s = [regex]::Replace($s, '-{2,}', '-').Trim('-', '.')
    if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength).Trim('-', '.') }
    if ($s.Length -eq 0) { return $Fallback }
    if ($s -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$') { $s = "_$s" }
    $s
}

function Get-OgDiffSideLabel {
    <#
    .SYNOPSIS
        The two side folder names for a listed comparison, so each tab names its repo and what it compares.

    .DESCRIPTION
        Pure. Each name starts with the repo's folder name in the run (-RepoFolderName, from
        Get-OgDiffRepoFolderName: sanitized and distinct, so same-leaf repos stay apart):
          Base: '<repo> base <7-char sha>', or '<repo> base empty' for an empty side (an added repo, an
                unborn HEAD).
          Head: '<repo> working' (WorkingTree), '<repo> index' (Staged), '<repo> head <7-char sha>', or
                '<repo> head empty' (a removed repo).
        WHY THE REPO IS REPEATED IN THE SIDE NAME (od task 7, the user's choice after the live check):
        Diffinity titles a folder-diff tab from the two folder NAMES only, '<left> - <right>', so with
        bare 'base-<sha>' / 'head-<sha>' every tab of a run read the same and the repo was visible only in
        the path bar. Now a tab reads e.g. 'og-brawler base e289ac3 - og-brawler head db4ec6a'. Do not
        drop the repo from these names to shorten paths. The spaces are safe: the difftool command quotes
        $LOCAL and $REMOTE (Expand-OgDiffToolCommand; the user's Diffinity command does).
        The short id is a label only (no git call to make it unique): 'base'/'head' already keep the two
        sides apart, and no name can end in a space or a dot (Windows would strip it).

    .PARAMETER ChangeSet
        The listed comparison (Og.DiffChangeSet): Kind, BaseCommit, HeadCommit.

    .PARAMETER RepoFolderName
        The repo's folder name in the run, from Get-OgDiffRepoFolderName (already filesystem-safe).

    .OUTPUTS
        Hashtable: Base, Head.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $ChangeSet,
        [Parameter(Mandatory)] [string] $RepoFolderName
    )

    $short = { param([string] $Sha) $Sha.Substring(0, [Math]::Min(7, $Sha.Length)) }

    $base = if ($ChangeSet.BaseCommit) { 'base ' + (& $short $ChangeSet.BaseCommit) } else { 'base empty' }
    $head = switch ($ChangeSet.Kind) {
        'WorkingTree' { 'working' }
        'Staged'      { 'index' }
        default       { if ($ChangeSet.HeadCommit) { 'head ' + (& $short $ChangeSet.HeadCommit) } else { 'head empty' } }
    }
    @{ Base = "$RepoFolderName $base"; Head = "$RepoFolderName $head" }
}

function Get-OgDiffRepoFolderName {
    <#
    .SYNOPSIS
        One distinct folder name per request, in request order: the repo's name, or its og-tree path when
        another request has the same name.

    .DESCRIPTION
        Pure. Two repos in one tree can share a leaf name (libs/a/core and libs/b/core), and NTFS folds
        case (Core and core). So:
          - a name used by one request only (case-insensitive) is kept: 'core';
          - a shared name becomes the repo's path made safe: 'libs-a-core', 'libs-b-core' (the root repo,
            path '', keeps its name);
          - anything still equal after that (e.g. two requests for the same repo) gets '-2', '-3' ...
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Request
    )

    $leafNames = @(foreach ($req in $Request) { ConvertTo-OgDiffPathLabel -Text $req.Repo -Fallback 'repo' })
    $leafCount = @{}   # PowerShell hashtables are case-insensitive, as NTFS is
    foreach ($n in $leafNames) { $leafCount[$n] = 1 + [int] $leafCount[$n] }

    $taken = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    for ($i = 0; $i -lt $Request.Count; $i++) {
        $name = $leafNames[$i]
        if ($leafCount[$name] -gt 1 -and -not [string]::IsNullOrEmpty($Request[$i].Path)) {
            $name = ConvertTo-OgDiffPathLabel -Text $Request[$i].Path -Fallback $name
        }
        $candidate = $name
        for ($n = 2; -not $taken.Add($candidate); $n++) { $candidate = "$name-$n" }
        $candidate
    }
}

function New-OgDiffRunFolder {
    <#
    .SYNOPSIS
        Creates and returns a NEW run folder <RunRoot>\<Name>, or <Name>-2, -3 ... when that name exists.

    .DESCRIPTION
        Never reuses an existing folder: two runs in the same second with the same label must not share
        (and so clear) each other's side folders while the first run's tabs are open.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RunRoot,
        [Parameter(Mandatory)] [string] $Name
    )

    $null = [System.IO.Directory]::CreateDirectory($RunRoot)
    for ($n = 1; $n -le 1000; $n++) {
        $candidate = Join-Path $RunRoot $(if ($n -eq 1) { $Name } else { "$Name-$n" })
        if (Test-Path -LiteralPath $candidate) { continue }
        $null = New-Item -ItemType Directory -Path $candidate -ErrorAction Stop
        return $candidate
    }
    throw "Could not create a new run folder for '$Name' under '$RunRoot' (1000 names taken)."
}

function Test-OgDiffRunFolder {
    <#
    .SYNOPSIS
        True only for a folder that is provably an og diff run, and so may be deleted by the prune.

    .DESCRIPTION
        The prune is a recursive delete in the user's temp folder, so it has its own rule, all of it
        required:
          - a real directory (not a junction or symlink: never follow a link out of og-diff);
          - its name is '<yyyyMMdd-HHmmss>-<label>' with a timestamp that parses and a label in
            [A-Za-z0-9._-] (what Open-OgDirDiffSet writes);
          - it holds at least one entry, and only directories (repo folders), none of them links;
          - each repo folder holds at least one side folder, and nothing but side folders and their
            marker files, none of them links;
          - every side folder is marked, in either of the engine's two forms (see $script:OgDiffSideMarker
            in Export-OgDiffSides.ps1): the file '<side>.og-diff-side' beside it in the repo folder
            (written since od task 7), or '.og-diff-side' inside it (the runs made before task 7, which
            must still age out);
          - every marker file in a repo folder belongs to a side folder there ('<side>.og-diff-side' for
            an existing <side>): any other file -- a stray file, or a marker whose folder is gone -- is
            something the engine did not leave, so the whole run is kept.
        So the legacy og-diff\<repo>\{base,head} folders (no timestamp, no marker), an empty folder, a run
        with one unmarked side, or a folder a user dropped a file into are never deleted.

        NEVER THROWS. A folder that cannot be inspected -- access denied, or deleted in between by a
        concurrent oggitdiff's own prune -- is not provably a run, so it is $false. An exception here would
        escape the prune after the diffs were launched and lose the caller's results (od-2 review R1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.IO.DirectoryInfo] $Directory
    )

    try {
        Test-OgDiffRunFolderContent -Directory $Directory
    } catch {
        Write-Verbose "Not a provable og diff run (cannot inspect '$($Directory.FullName)'): $($_.Exception.Message)"
        $false
    }
}

function Test-OgDiffRunFolderContent {
    <#
    .SYNOPSIS
        The rule of Test-OgDiffRunFolder (see there). Throws when a folder cannot be listed; call it only
        through Test-OgDiffRunFolder, which turns that into $false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.IO.DirectoryInfo] $Directory
    )

    $link = [System.IO.FileAttributes]::ReparsePoint
    if (($Directory.Attributes -band $link) -ne 0) { return $false }

    if ($Directory.Name -notmatch '^(?<stamp>\d{8}-\d{6})-[A-Za-z0-9._-]+$') { return $false }
    $stamp = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Matches.stamp, $script:OgDiffRunStampFormat,
            [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref] $stamp)) {
        return $false
    }

    $repoFolders = @($Directory.GetFileSystemInfos())
    if ($repoFolders.Count -eq 0) { return $false }
    $ignoreCase = [System.StringComparer]::OrdinalIgnoreCase   # NTFS folds case
    foreach ($repoFolder in $repoFolders) {
        if ($repoFolder -isnot [System.IO.DirectoryInfo] -or ($repoFolder.Attributes -band $link) -ne 0) { return $false }

        # Split the repo folder into side folders and files; a link keeps the run.
        $sideFolders = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
        $fileNames = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
        foreach ($entry in $repoFolder.GetFileSystemInfos()) {
            if (($entry.Attributes -band $link) -ne 0) { return $false }
            if ($entry -is [System.IO.DirectoryInfo]) { $sideFolders.Add($entry) } else { [void] $fileNames.Add($entry.Name) }
        }
        if ($sideFolders.Count -eq 0) { return $false }

        $ownMarkers = [System.Collections.Generic.HashSet[string]]::new($ignoreCase)
        foreach ($side in $sideFolders) {
            $siblingName = $side.Name + $script:OgDiffSideMarker
            [void] $ownMarkers.Add($siblingName)
            # Either form marks the side (see the description): the sibling file listed above, or the old
            # in-folder file. Dropping either check strands one generation of runs in %TEMP% for good.
            $marked = $fileNames.Contains($siblingName) -or
                [System.IO.File]::Exists((Join-Path $side.FullName $script:OgDiffSideMarker))
            if (-not $marked) { return $false }
        }
        # ONE rule for every file here: it must be the marker of a side folder in this repo folder. That keeps
        # the run for a stray file (a user's note) and for a marker whose side folder is gone alike.
        foreach ($name in $fileNames) {
            if (-not $ownMarkers.Contains($name)) { return $false }
        }
    }
    $true
}

function Remove-OgDiffOldRun {
    <#
    .SYNOPSIS
        Deletes the oldest run folders under the og-diff root so that at most -Keep runs remain, the
        current run included and never deleted. Returns the deleted paths.

    .DESCRIPTION
        Only DIRECT children of -RunRoot that pass Test-OgDiffRunFolder are runs; everything else under
        og-diff is foreign and is neither counted nor touched, and og-diff itself is never deleted. Age is
        the timestamp in the folder NAME (newest = greatest name, ordinal), not the folder's mtime, which
        changes whenever something inside it is written. A delete that fails (a file held open) is a
        warning: the run is retried by the next prune.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RunRoot,
        [Parameter(Mandatory)] [string] $CurrentRun,
        [Parameter(Mandatory)] [ValidateRange(1, [int]::MaxValue)] [int] $Keep
    )

    $root    = Assert-OgDiffRunRoot -Path $RunRoot
    $current = [System.IO.Path]::GetFullPath($CurrentRun).TrimEnd('\', '/')

    $others = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
    foreach ($dir in ([System.IO.DirectoryInfo]::new($root)).GetDirectories()) {
        if ([string]::Equals($dir.FullName.TrimEnd('\', '/'), $current, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (Test-OgDiffRunFolder -Directory $dir) { $others.Add($dir) }
    }
    # Ordinal, newest first. Within ONE second, the '-N' suffixes of New-OgDiffRunFolder compare as text ('-10' counts
    # as older than '-2'), which misorders only same-second runs from the tenth on (od-2 review N1); accepted.
    $others.Sort([System.Comparison[System.IO.DirectoryInfo]] { param($a, $b) [string]::CompareOrdinal($b.Name, $a.Name) })

    # The current run takes one of the -Keep places.
    for ($i = $Keep - 1; $i -lt $others.Count; $i++) {
        $victim = $others[$i]
        # Belt and braces: a victim is a direct, non-empty-named child of the asserted root.
        if ([string]::IsNullOrEmpty($victim.Name) -or
            -not [string]::Equals($victim.Parent.FullName.TrimEnd('\', '/'), $root, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        try {
            Remove-Item -LiteralPath $victim.FullName -Recurse -Force -ErrorAction Stop
            $victim.FullName
        } catch {
            Write-Warning "Could not delete the old og diff run '$($victim.FullName)': $($_.Exception.Message)"
        }
    }
}

function New-OgDirDiffResult {
    <#
    .SYNOPSIS
        Builds one Og.DiffResult for Open-OgDirDiffSet (see its .OUTPUTS for the fields).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Request,
        [Parameter(Mandatory)] [ValidateSet('opened', 'clean', 'failed')] [string] $Action,
        [string] $ErrorMessage,
        [PSCustomObject] $ChangeSet,
        [string] $BasePath,
        [string] $HeadPath,
        [string] $RunPath
    )

    $orNull = { param([string] $Value) if ([string]::IsNullOrEmpty($Value)) { $null } else { $Value } }

    [PSCustomObject]@{ PSTypeName = 'Og.DiffResult';
        Repo      = $Request.Repo
        Path      = $Request.Path
        Action    = $Action
        Error     = & $orNull $ErrorMessage
        Ref       = $Request.Ref
        Range     = $Request.Range
        BasePath  = & $orNull $BasePath
        HeadPath  = & $orNull $HeadPath
        Commit    = $Request.Commit
        BaseRev   = $(if ($ChangeSet) { $ChangeSet.BaseCommit } else { $Request.BaseRev })
        HeadRev   = $(if ($ChangeSet) { $ChangeSet.HeadCommit } else { $Request.HeadRev })
        FileCount = $(if ($ChangeSet) { $ChangeSet.FileCount } else { $null })
        RunPath   = & $orNull $RunPath
    }
}

function Assert-OgDirDiffRequest {
    <#
    .SYNOPSIS
        Throws unless a request has what Open-OgDirDiffSet needs: Repo, WorkingDirectory, a valid Kind, and
        for a Range both BaseRev and HeadRev (non-null; '' is an empty side). A GitDir belongs to a Range.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Request,
        [Parameter(Mandatory)] [int] $Index
    )

    if ($null -eq $Request) { throw "Open-OgDirDiffSet: request $Index is null." }
    foreach ($name in 'Repo', 'WorkingDirectory', 'Kind') {
        $prop = $Request.PSObject.Properties[$name]
        if ($null -eq $prop -or [string]::IsNullOrEmpty([string] $prop.Value)) {
            throw "Open-OgDirDiffSet: request $Index has no '$name'."
        }
    }
    if ($Request.Kind -notin 'WorkingTree', 'Staged', 'Range') {
        throw "Open-OgDirDiffSet: request $Index has Kind '$($Request.Kind)'; expected WorkingTree, Staged or Range."
    }
    if ($Request.Kind -eq 'Range') {
        foreach ($name in 'BaseRev', 'HeadRev') {
            $prop = $Request.PSObject.Properties[$name]
            if ($null -eq $prop -or $null -eq $prop.Value) {
                throw "Open-OgDirDiffSet: request $Index is a Range without '$name' ('' for an empty side)."
            }
        }
    } elseif (Get-OgDirDiffRequestGitDir -Request $Request) {
        throw "Open-OgDirDiffSet: request $Index has a GitDir but Kind '$($Request.Kind)'; git-dir mode is Range only."
    }
}

function Get-OgDirDiffRequestGitDir {
    <#
    .SYNOPSIS
        A request's GitDir, or '' when it has none (no such property: a hand-built or older request).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Request
    )

    $prop = $Request.PSObject.Properties['GitDir']
    if ($null -eq $prop -or $null -eq $prop.Value) { return '' }
    [string] $prop.Value
}

function Get-OgDirDiffToolDirectory {
    <#
    .SYNOPSIS
        The directory the diff tool command is resolved in: the first request's WorkingDirectory that is a
        real work tree, i.e. the first request without a GitDir.

    .DESCRIPTION
        A git-dir request (a removed submodule) has no work tree: its WorkingDirectory may be missing, or
        an empty folder inside its PARENT's work tree, and git run inside its git dir would apply the stale
        core.worktree and die (od task 4a). So git-dir requests are passed over. When every request is a
        git-dir one, the nearest existing folder above the first one's WorkingDirectory is used: git there
        reads the enclosing repo's config (the parent's) and the global config, which is where diff.tool
        lives.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Request
    )

    foreach ($req in $Request) {
        if (-not (Get-OgDirDiffRequestGitDir -Request $req)) { return $req.WorkingDirectory }
    }
    $dir = [string] $Request[0].WorkingDirectory
    while (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        $dir = Split-Path -Path $dir -Parent
    }
    if ([string]::IsNullOrEmpty($dir)) { [System.IO.Path]::GetTempPath() } else { $dir }
}

function Get-OgDirDiffDisplayName {
    <#
    .SYNOPSIS
        A request's name for messages: its og-tree path, or its repo name for the root (path '').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Request
    )

    if ([string]::IsNullOrEmpty($Request.Path)) { $Request.Repo } else { $Request.Path }
}
