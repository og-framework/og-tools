# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

# Covers the per-run layout and the single-instance launcher (Open-OgDirDiffSet, od task 2).
# Every repo is a throwaway under $TestDrive, sandboxed by Enter-OgGitSandbox. NOTHING LAUNCHES A TOOL:
# the top-level BeforeEach mocks Start-OgDiffToolProcess (the launch), Test-OgDiffToolProcessRunning (the
# probe), Start-OgDiffSleep (the sleep), Get-OgDiffNow (the clock) and Get-OgDiffRunRoot (so every run
# folder and every prune stays inside $TestDrive, never the user's real temp\og-diff). The seams' own
# bodies are tested from a dot-sourced copy of the file, outside the module's mocks.
#
# The mocks append to one ordered event list ('probe', 'launch:<repo folder>', 'sleep <ms>'), so the
# order tests compare the whole sequence: first launch, wait, then the rest.

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force
    . "$PSScriptRoot\OgGitTestHelpers.ps1"
    Enter-OgGitSandbox -Root (Join-Path $TestDrive 'sandbox')

    $script:SourceFile = Join-Path $moduleRoot 'Private\Open-OgDirDiffSet.ps1'
    $script:ToolExe    = 'C:\Tools\FakeTool.exe'
    $script:Template   = '"C:\Tools\FakeTool.exe" "$LOCAL" "$REMOTE"'
    # The sandbox's global config is the only git config the tests see (no system config).
    Invoke-TestGit $TestDrive config --global diff.tool captest | Out-Null
    Invoke-TestGit $TestDrive config --global difftool.captest.cmd $script:Template | Out-Null

    $script:Utf8 = [System.Text.UTF8Encoding]::new($false)

    function Write-TestText {
        param([string] $Dir, [string] $Rel, [string] $Text)
        $path = Join-Path $Dir $Rel
        [void] [System.IO.Directory]::CreateDirectory((Split-Path $path -Parent))
        [System.IO.File]::WriteAllText($path, $Text, $script:Utf8)
    }

    # A one-commit repo at <fresh dir>\<Rel> (a.txt = "one"). -Dirty edits a.txt in the working tree.
    function New-TestDiffRepo {
        param([string] $Rel = 'repo', [switch] $Dirty, [string] $DirtyText = "two`n")
        $dir = Join-Path (New-TestDir 'tree') $Rel
        [void] [System.IO.Directory]::CreateDirectory($dir)
        Invoke-TestGit $dir init -q | Out-Null
        Write-TestText $dir 'a.txt' "one`n"
        Invoke-TestGit $dir add -- 'a.txt' | Out-Null
        Invoke-TestGit $dir commit -q -m 'one' | Out-Null
        if ($Dirty) { Write-TestText $dir 'a.txt' $DirtyText }
        $dir
    }

    function New-TestRequest {
        param([hashtable] $P)
        InModuleScope og-framework -Parameters @{ P = $P } { New-OgDirDiffRequest @P }
    }

    function New-TestWorkingRequest {
        param([string] $Repo, [string] $Dir, [string] $Path = $Repo)
        New-TestRequest @{ Repo = $Repo; Path = $Path; WorkingDirectory = $Dir; Kind = 'WorkingTree' }
    }

    # Runs Open-OgDirDiffSet in the module; returns the results and keeps the warnings in $script:Warnings.
    function Invoke-TestOpen {
        param([hashtable] $P)
        $all = @(InModuleScope og-framework -Parameters @{ P = $P } { Open-OgDirDiffSet @P 3>&1 })
        $script:Warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } |
            ForEach-Object Message)
        , @($all | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
    }

    # Every file under a folder as sorted, '/'-separated relative paths, the engine's marker included.
    function Get-TestTree {
        param([string] $Dir)
        if (-not (Test-Path -LiteralPath $Dir)) { return @() }
        if (Test-Path -LiteralPath $Dir -PathType Leaf) { return @('FILE:' + [System.IO.File]::ReadAllText($Dir)) }
        $root = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\') + '\'
        @(Get-ChildItem -LiteralPath $Dir -Recurse -Force |
            ForEach-Object { $_.FullName.Substring($root.Length).Replace('\', '/') + $(if ($_.PSIsContainer) { '/' }) } |
            Sort-Object -CaseSensitive)
    }

    # A run-shaped folder as Open-OgDirDiffSet leaves it: <root>\<name>\repo\{<sides>} with markers.
    # -Marker: Sibling (the od task 7 layout and the default: a hidden '<side>.og-diff-side' beside each
    # side folder), InFolder (runs made before task 7: '.og-diff-side' inside each side; pair it with the
    # old side names, e.g. -Sides 'base-1234567', 'working'), or None (-NoMarker is the same).
    function New-TestRunFolder {
        param([string] $Root, [string] $Name, [string[]] $Sides = @('repo base 1234567', 'repo working'),
            [ValidateSet('Sibling', 'InFolder', 'None')] [string] $Marker = 'Sibling', [switch] $NoMarker)
        if ($NoMarker) { $Marker = 'None' }
        foreach ($side in $Sides) {
            $dir = Join-Path $Root "$Name\repo\$side"
            [void] [System.IO.Directory]::CreateDirectory($dir)
            Write-TestText $dir 'a.txt' 'x'
            switch ($Marker) {
                'Sibling' {
                    Write-TestText (Join-Path $Root "$Name\repo") "$side.og-diff-side" 'marker'
                    (Get-Item -LiteralPath (Join-Path $Root "$Name\repo\$side.og-diff-side") -Force).Attributes = 'Hidden'
                }
                'InFolder' { Write-TestText $dir '.og-diff-side' 'marker' }
            }
        }
        Join-Path $Root $Name
    }

    function Get-TestRunNames {
        param([string] $Root)
        @(Get-ChildItem -LiteralPath $Root -Directory -Force | ForEach-Object Name | Sort-Object)
    }
}

AfterAll {
    Exit-OgGitSandbox
}

Describe 'Open-OgDirDiffSet (od task 2)' {
    BeforeEach {
        $script:Events      = [System.Collections.Generic.List[string]]::new()
        $script:Commands    = [System.Collections.Generic.List[string]]::new()
        $script:ProbeQueue  = [System.Collections.Generic.Queue[bool]]::new()
        $script:ProbeDefault = $true
        $script:FailLaunch  = @()      # repo folder names whose launch reports Launched = $false
        $script:Now         = [datetime]::new(2026, 10, 22, 15, 30, 45)
        $script:RunRoot     = Join-Path (New-TestDir 'tmp') 'og-diff'
        $script:Warnings    = @()

        Mock -ModuleName og-framework Start-OgDiffToolProcess {
            $script:Commands.Add($CommandLine)
            $base = [regex]::Match($CommandLine, '"([^"]+)"\s+"([^"]+)"\s*$').Groups[1].Value
            $folder = Split-Path (Split-Path $base -Parent) -Leaf
            $script:Events.Add("launch:$folder")
            if ($folder -in $script:FailLaunch) {
                return [PSCustomObject]@{ Launched = $false; ExitCode = 1; Detail = "boom $folder" }
            }
            [PSCustomObject]@{ Launched = $true; ExitCode = $null; Detail = $null }
        }
        Mock -ModuleName og-framework Test-OgDiffToolProcessRunning {
            $script:Events.Add('probe')
            if ($script:ProbeQueue.Count -gt 0) { $script:ProbeQueue.Dequeue() } else { $script:ProbeDefault }
        }
        Mock -ModuleName og-framework Start-OgDiffSleep { $script:Events.Add("sleep $Milliseconds") }
        Mock -ModuleName og-framework Get-OgDiffNow { $script:Now }
        Mock -ModuleName og-framework Get-OgDiffRunRoot { $script:RunRoot }
        Mock -ModuleName og-framework Invoke-Git -ParameterFilter { $Arguments -contains 'difftool' } {
            throw 'git difftool must never be invoked by Open-OgDirDiffSet'
        }
    }

    Describe 'Open-OgDirDiffSet: launch order (one tool instance)' {
        BeforeEach {
            $script:alpha = New-TestDiffRepo 'alpha' -Dirty
            $script:beta  = New-TestDiffRepo 'beta'  -Dirty
            $script:gamma = New-TestDiffRepo 'gamma' -Dirty
            $script:reqs = @(
                New-TestWorkingRequest 'alpha' $script:alpha
                New-TestWorkingRequest 'beta'  $script:beta
                New-TestWorkingRequest 'gamma' $script:gamma)
        }

        It 'launches the first repo, waits until the tool process is up, then the rest in order with a pause before each' {
            foreach ($b in $false, $false, $true) { $script:ProbeQueue.Enqueue($b) }   # not running; then up on the 2nd poll

            $r = Invoke-TestOpen @{ Request = $script:reqs; Label = 'worktree' }

            @($script:Events) | Should -Be @(
                'probe'                         # before the first launch: not running
                'launch:alpha'
                'probe', 'sleep 100', 'probe'   # the bounded wait: up on the second probe
                'sleep 300', 'launch:beta'
                'sleep 300', 'launch:gamma')
            @($r.Action) | Should -Be @('opened', 'opened', 'opened')
            $script:Warnings | Should -BeNullOrEmpty
        }

        It 'skips the wait when the tool was already running before the first launch (the pauses stay)' {
            $script:ProbeQueue.Enqueue($true)
            $null = Invoke-TestOpen @{ Request = $script:reqs; Label = 'worktree' }
            @($script:Events) | Should -Be @('probe', 'launch:alpha', 'sleep 300', 'launch:beta', 'sleep 300', 'launch:gamma')
        }

        It 'one changed repo: one probe, one launch, no wait and no pause' {
            $script:ProbeQueue.Enqueue($false)
            $r = Invoke-TestOpen @{ Request = @($script:reqs[0]); Label = 'worktree' }
            @($script:Events) | Should -Be @('probe', 'launch:alpha')
            $r[0].Action | Should -Be 'opened'
        }

        It 'launches the configured command verbatim (only $LOCAL/$REMOTE substituted, no tool flag) and probes its exe' {
            $script:ProbeQueue.Enqueue($true)
            $r = Invoke-TestOpen @{ Request = $script:reqs; Label = 'worktree' }
            $script:Commands.Count | Should -Be 3
            for ($i = 0; $i -lt 3; $i++) {
                $script:Commands[$i] | Should -BeExactly ('"C:\Tools\FakeTool.exe" "{0}" "{1}"' -f $r[$i].BasePath, $r[$i].HeadPath)
                $script:Commands[$i] | Should -Not -Match 'forceNewInstance|folderDiff|bringToFront'
            }
            Should -Invoke -ModuleName og-framework Test-OgDiffToolProcessRunning -Times 1 -Exactly `
                -ParameterFilter { $ExePath -eq 'C:\Tools\FakeTool.exe' }
        }

        It 'honours the -ProbeIntervalMilliseconds and -LaunchPauseMilliseconds knobs' {
            foreach ($b in $false, $false, $true) { $script:ProbeQueue.Enqueue($b) }
            $null = Invoke-TestOpen @{ Request = $script:reqs; Label = 'worktree'; ProbeIntervalMilliseconds = 40; LaunchPauseMilliseconds = 7 }
            @($script:Events) | Should -Be @('probe', 'launch:alpha', 'probe', 'sleep 40', 'probe', 'sleep 7', 'launch:beta', 'sleep 7', 'launch:gamma')
        }
    }

    Describe 'Open-OgDirDiffSet: clean repos are neither exported nor launched' {
        It 'launches only the changed repos and reports the clean one as clean' {
            $alpha = New-TestDiffRepo 'alpha' -Dirty
            $beta  = New-TestDiffRepo 'beta'
            $gamma = New-TestDiffRepo 'gamma' -Dirty
            $script:ProbeQueue.Enqueue($true)

            $r = Invoke-TestOpen @{ Request = @(
                    New-TestWorkingRequest 'alpha' $alpha
                    New-TestWorkingRequest 'beta'  $beta
                    New-TestWorkingRequest 'gamma' $gamma); Label = 'worktree' }

            @($r.Repo)   | Should -Be @('alpha', 'beta', 'gamma')
            @($r.Action) | Should -Be @('opened', 'clean', 'opened')
            @($script:Events) | Should -Be @('probe', 'launch:alpha', 'sleep 300', 'launch:gamma')
            $r[1].FileCount | Should -Be 0
            $r[1].BasePath  | Should -BeNullOrEmpty
            $r[1].HeadPath  | Should -BeNullOrEmpty
            $r[1].RunPath   | Should -BeNullOrEmpty
            Get-TestRunNames $r[0].RunPath | Should -Be @('alpha', 'gamma')
        }

        It 'with every repo clean: no probe, no launch, no tool needed and no run folder' {
            $alpha = New-TestDiffRepo 'alpha'
            $r = Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $alpha); Label = 'worktree'; Tool = 'not-configured' }
            $r[0].Action | Should -Be 'clean'
            $script:Events.Count | Should -Be 0
            Test-Path -LiteralPath $script:RunRoot | Should -BeFalse
        }

        It 'with no requests at all: returns nothing and writes nothing' {
            $r = Invoke-TestOpen @{ Request = @(); Label = 'worktree' }
            $r.Count | Should -Be 0
            Test-Path -LiteralPath $script:RunRoot | Should -BeFalse
        }
    }

    Describe 'Open-OgDirDiffSet: run folder, labels and paths per repo' {
        It 'WorkingTree: run\repo\{REPO base SHA7, REPO working}, with the result fields' {
            $alpha = New-TestDiffRepo 'alpha' -Dirty
            $sha = Invoke-TestGit $alpha rev-parse HEAD
            $req = New-TestRequest @{ Repo = 'alpha'; Path = 'libs/alpha'; WorkingDirectory = $alpha; Kind = 'WorkingTree'
                Ref = 'origin/main'; Range = 'origin/main...HEAD' }

            $r = (Invoke-TestOpen @{ Request = @($req); Label = 'worktree' })[0]

            $run = Join-Path $script:RunRoot '20261022-153045-worktree'
            $r.RunPath   | Should -Be $run
            $r.BasePath  | Should -Be (Join-Path $run "alpha\alpha base $($sha.Substring(0, 7))")
            $r.HeadPath  | Should -Be (Join-Path $run 'alpha\alpha working')
            $r.Repo      | Should -Be 'alpha'
            $r.Path      | Should -Be 'libs/alpha'
            $r.Action    | Should -Be 'opened'
            $r.Error     | Should -BeNullOrEmpty
            $r.Ref       | Should -Be 'origin/main'
            $r.Range     | Should -Be 'origin/main...HEAD'
            $r.Commit    | Should -BeNullOrEmpty
            $r.BaseRev   | Should -Be $sha
            $r.HeadRev   | Should -BeNullOrEmpty
            $r.FileCount | Should -Be 1
            $r.PSObject.TypeNames | Should -Contain 'Og.DiffResult'
            Get-Content -Raw -LiteralPath (Join-Path $r.BasePath 'a.txt') | Should -Be "one`n"
            Get-Content -Raw -LiteralPath (Join-Path $r.HeadPath 'a.txt') | Should -Be "two`n"
            [System.IO.Path]::IsPathFullyQualified($r.BasePath) | Should -BeTrue
        }

        It 'Staged: the head side is named REPO index' {
            $alpha = New-TestDiffRepo 'alpha' -Dirty
            Invoke-TestGit $alpha add -- 'a.txt' | Out-Null
            $sha = Invoke-TestGit $alpha rev-parse HEAD
            $r = (Invoke-TestOpen @{ Request = @(New-TestRequest @{ Repo = 'alpha'; WorkingDirectory = $alpha; Kind = 'Staged' })
                Label = 'staged' })[0]
            $r.RunPath  | Should -Be (Join-Path $script:RunRoot '20261022-153045-staged')
            Split-Path $r.BasePath -Leaf | Should -Be "alpha base $($sha.Substring(0, 7))"
            Split-Path $r.HeadPath -Leaf | Should -Be 'alpha index'
            Get-Content -Raw -LiteralPath (Join-Path $r.HeadPath 'a.txt') | Should -Be "two`n"
        }

        It 'Range: REPO base SHA7 and REPO head SHA7, with the full ids on the result' {
            $alpha = New-TestDiffRepo 'alpha' -Dirty
            $old = Invoke-TestGit $alpha rev-parse HEAD
            Invoke-TestGit $alpha commit -q -am 'two' | Out-Null
            $new = Invoke-TestGit $alpha rev-parse HEAD
            $r = (Invoke-TestOpen @{ Request = @(New-TestRequest @{ Repo = 'alpha'; WorkingDirectory = $alpha; Kind = 'Range'
                        BaseRev = $old; HeadRev = $new; Commit = 'abc1234' }); Label = 'commit-abc1234' })[0]
            Split-Path $r.BasePath -Leaf | Should -Be "alpha base $($old.Substring(0, 7))"
            Split-Path $r.HeadPath -Leaf | Should -Be "alpha head $($new.Substring(0, 7))"
            $r.BaseRev | Should -Be $old
            $r.HeadRev | Should -Be $new
            $r.Commit  | Should -Be 'abc1234'
            $r.RunPath | Should -Be (Join-Path $script:RunRoot '20261022-153045-commit-abc1234')
        }

        It 'Range with an empty base: the base side is named REPO base empty and holds no file' {
            $alpha = New-TestDiffRepo 'alpha'
            $r = (Invoke-TestOpen @{ Request = @(New-TestRequest @{ Repo = 'alpha'; WorkingDirectory = $alpha; Kind = 'Range'
                        BaseRev = ''; HeadRev = 'HEAD' }); Label = 'commit-x' })[0]
            Split-Path $r.BasePath -Leaf | Should -Be 'alpha base empty'
            Split-Path $r.HeadPath -Leaf | Should -Be "alpha head $((Invoke-TestGit $alpha rev-parse HEAD).Substring(0, 7))"
            $r.BaseRev | Should -BeNullOrEmpty
            # od task 7: no marker inside a side any more (it was '.og-diff-side' in both lists).
            @(Get-TestTree $r.BasePath).Count | Should -Be 0
            Test-Path -LiteralPath $r.BasePath -PathType Container | Should -BeTrue
            Get-TestTree $r.HeadPath | Should -Be @('a.txt')
        }

        It 'Range with an empty head: the head side is named REPO head empty and holds no file' {
            $alpha = New-TestDiffRepo 'alpha'
            $sha = Invoke-TestGit $alpha rev-parse HEAD
            $r = (Invoke-TestOpen @{ Request = @(New-TestRequest @{ Repo = 'alpha'; WorkingDirectory = $alpha; Kind = 'Range'
                        BaseRev = 'HEAD'; HeadRev = '' }); Label = 'commit-x' })[0]
            Split-Path $r.BasePath -Leaf | Should -Be "alpha base $($sha.Substring(0, 7))"
            Split-Path $r.HeadPath -Leaf | Should -Be 'alpha head empty'
            Get-TestTree $r.BasePath | Should -Be @('a.txt')
            @(Get-TestTree $r.HeadPath).Count | Should -Be 0
        }

        # od task 7 (the user's live check): every side folder holds ONLY the exported files; its marker sits
        # beside it in the repo folder. The whole run folder is listed, so a marker anywhere else fails.
        It 'the run holds exactly the side folders, their exported files and one hidden marker beside each side (<Kind>)' -ForEach @(
            @{ Kind = 'WorkingTree' }, @{ Kind = 'Staged' }, @{ Kind = 'Range' }
        ) {
            $alpha = New-TestDiffRepo 'alpha' -Dirty
            $old = Invoke-TestGit $alpha rev-parse HEAD
            $p = @{ Repo = 'alpha'; WorkingDirectory = $alpha; Kind = $Kind }
            if ($Kind -eq 'Staged') { Invoke-TestGit $alpha add -- 'a.txt' | Out-Null }
            if ($Kind -eq 'Range') {
                Invoke-TestGit $alpha commit -q -am 'two' | Out-Null
                $p.BaseRev = $old; $p.HeadRev = Invoke-TestGit $alpha rev-parse HEAD
            }
            $r = (Invoke-TestOpen @{ Request = @(New-TestRequest $p); Label = 'x' })[0]
            $r.Action | Should -Be 'opened'
            $b = Split-Path $r.BasePath -Leaf
            $h = Split-Path $r.HeadPath -Leaf
            $b | Should -BeLike 'alpha base *'
            $h | Should -BeLike 'alpha *'
            Get-TestTree $r.RunPath | Should -Be (@(
                'alpha/', "alpha/$b/", "alpha/$b/a.txt", "alpha/$b.og-diff-side",
                "alpha/$h/", "alpha/$h/a.txt", "alpha/$h.og-diff-side") | Sort-Object -CaseSensitive)
            foreach ($side in $r.BasePath, $r.HeadPath) {
                (Get-Item -LiteralPath "$side.og-diff-side" -Force).Attributes.HasFlag([System.IO.FileAttributes]::Hidden) | Should -BeTrue
            }
            # The tab title the tool builds from the two folder names (Diffinity: '<left> - <right>').
            $script:Commands[0] | Should -BeLike "*`"$($r.BasePath)`" `"$($r.HeadPath)`""
        }

        It 'makes the label filesystem-safe: <Label> -> <Expected>' -ForEach @(
            @{ Label = 'against-origin/main'; Expected = 'against-origin-main' }
            @{ Label = 'a:b\c  d*?';          Expected = 'a-b-c-d' }
            @{ Label = '///';                 Expected = 'diff' }
            @{ Label = '..\..\evil';          Expected = 'evil' }
        ) {
            $alpha = New-TestDiffRepo 'alpha' -Dirty
            $r = (Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $alpha); Label = $Label })[0]
            $r.RunPath | Should -Be (Join-Path $script:RunRoot "20261022-153045-$Expected")
            Split-Path $r.RunPath -Parent | Should -Be $script:RunRoot
        }

        # od task 6 (MAX_PATH, review 3): the label is cut to 24 characters in the run folder name, so a long
        # -Against ref cannot push ordinary exports past 260 characters. Every built-in label stays whole.
        It 'cuts the run label to 24 characters: <Label> -> <Expected>' -ForEach @(
            @{ Label = 'against-origin/feature/a-very-long-branch-name'; Expected = 'against-origin-feature-a' }
            @{ Label = 'against-origin/main';                           Expected = 'against-origin-main' }
            @{ Label = 'commit-6245add';                                Expected = 'commit-6245add' }
            @{ Label = ('x' * 23) + '/y';                               Expected = ('x' * 23) }
        ) {
            $alpha = New-TestDiffRepo 'alpha' -Dirty
            $r = (Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $alpha); Label = $Label })[0]
            $r.Action  | Should -Be 'opened'
            $r.RunPath | Should -Be (Join-Path $script:RunRoot "20261022-153045-$Expected")
        }

        # od task 6 (MAX_PATH, review 3): a run root deep enough that every exported file's path passes 260
        # characters. Without `-c core.longpaths=true` on the export's git calls, checkout-index fails with
        # "Filename too long" (measured; the sandbox has no system config, so nothing else sets it).
        It 'exports a file whose path passes 260 characters (<Kind>)' -ForEach @(
            @{ Kind = 'WorkingTree' }, @{ Kind = 'Range' }
        ) {
            $deepRel = ('d' * 40) + '/' + ('e' * 40) + '/' + ('f' * 40) + '/deep.txt'
            $alpha = New-TestDiffRepo 'alpha'
            Write-TestText $alpha $deepRel "base`n"
            Invoke-TestGit $alpha add -A | Out-Null
            Invoke-TestGit $alpha commit -q -m 'deep' | Out-Null
            $old = Invoke-TestGit $alpha rev-parse HEAD
            Write-TestText $alpha $deepRel "head`n"
            if ($Kind -eq 'Range') {
                Invoke-TestGit $alpha commit -q -am 'deep head' | Out-Null
                $req = New-TestRequest @{ Repo = 'alpha'; WorkingDirectory = $alpha; Kind = 'Range'
                    BaseRev = $old; HeadRev = (Invoke-TestGit $alpha rev-parse HEAD) }
            } else {
                $req = New-TestWorkingRequest 'alpha' $alpha
            }
            $script:RunRoot = Join-Path (New-TestDir ('r' * 80)) 'og-diff'

            $r = (Invoke-TestOpen @{ Request = @($req); Label = 'longpath' })[0]

            $r.Error  | Should -BeNullOrEmpty
            $r.Action | Should -Be 'opened'
            $baseFile = Join-Path $r.BasePath $deepRel.Replace('/', '\')
            $headFile = Join-Path $r.HeadPath $deepRel.Replace('/', '\')
            $baseFile.Length | Should -BeGreaterThan 260
            $headFile.Length | Should -BeGreaterThan 260
            [System.IO.File]::ReadAllText($baseFile) | Should -Be "base`n"
            [System.IO.File]::ReadAllText($headFile) | Should -Be "head`n"
        }

        It 'never reuses a run folder: a second run in the same second gets a -2 suffix and the first keeps its files' {
            $alpha = New-TestDiffRepo 'alpha' -Dirty
            $req = New-TestWorkingRequest 'alpha' $alpha
            $first = (Invoke-TestOpen @{ Request = @($req); Label = 'worktree' })[0]
            Write-TestText $alpha 'a.txt' "three`n"
            $second = (Invoke-TestOpen @{ Request = @($req); Label = 'worktree' })[0]

            $second.RunPath | Should -Be (Join-Path $script:RunRoot '20261022-153045-worktree-2')
            Get-Content -Raw -LiteralPath (Join-Path $first.HeadPath 'a.txt')  | Should -Be "two`n"
            Get-Content -Raw -LiteralPath (Join-Path $second.HeadPath 'a.txt') | Should -Be "three`n"
        }

        It 'refuses the run root <Root> (not a fully qualified og-diff folder) before listing anything' -ForEach @(
            @{ Root = 'og-diff' }, @{ Root = 'C:\' }, @{ Root = 'C:og-diff' }, @{ Root = 'C:\Temp\not-og' }
        ) {
            $script:RunRoot = $Root
            Mock -ModuleName og-framework Get-OgDiffChange { throw 'must not list' }
            $alpha = New-TestDiffRepo 'alpha' -Dirty
            { Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $alpha); Label = 'worktree' } } |
                Should -Throw 'Refusing og-diff run root*'
            Should -Invoke -ModuleName og-framework Get-OgDiffChange -Times 0
        }
    }

    Describe 'Open-OgDirDiffSet: repos with the same name' {
        It 'gives same-leaf repos distinct folders from their paths (case-insensitive), each with its own content' {
            $a = New-TestDiffRepo 'libs/a/core'   -Dirty -DirtyText "from a`n"
            $b = New-TestDiffRepo 'libs/b/core'   -Dirty -DirtyText "from b`n"
            $c = New-TestDiffRepo 'extern/Core'   -Dirty -DirtyText "from c`n"
            $d = New-TestDiffRepo 'tools/unique'  -Dirty -DirtyText "from d`n"
            $script:ProbeQueue.Enqueue($true)

            $r = Invoke-TestOpen @{ Request = @(
                    New-TestWorkingRequest 'core'   $a 'libs/a/core'
                    New-TestWorkingRequest 'core'   $b 'libs/b/core'
                    New-TestWorkingRequest 'Core'   $c 'extern/Core'
                    New-TestWorkingRequest 'unique' $d 'tools/unique'); Label = 'worktree' }

            @($r.Action) | Should -Be @('opened', 'opened', 'opened', 'opened')
            @($r | ForEach-Object { Split-Path (Split-Path $_.HeadPath -Parent) -Leaf }) |
                Should -Be @('libs-a-core', 'libs-b-core', 'extern-Core', 'unique')
            # od task 7: each side folder starts with that same disambiguated repo folder name.
            @($r | ForEach-Object { Split-Path $_.HeadPath -Leaf }) |
                Should -Be @('libs-a-core working', 'libs-b-core working', 'extern-Core working', 'unique working')
            for ($i = 0; $i -lt 4; $i++) {
                Split-Path $r[$i].BasePath -Leaf |
                    Should -Be ("$(@('libs-a-core', 'libs-b-core', 'extern-Core', 'unique')[$i]) base " + $r[$i].BaseRev.Substring(0, 7))
            }
            @($script:Events | Where-Object { $_ -like 'launch:*' }) |
                Should -Be @('launch:libs-a-core', 'launch:libs-b-core', 'launch:extern-Core', 'launch:unique')
            $expected = "from a`n", "from b`n", "from c`n", "from d`n"
            for ($i = 0; $i -lt 4; $i++) {
                Get-Content -Raw -LiteralPath (Join-Path $r[$i].HeadPath 'a.txt') | Should -Be $expected[$i]
            }
        }

        It 'Get-OgDiffRepoFolderName: the root keeps its name, duplicates of one path get -2' {
            $names = InModuleScope og-framework {
                Get-OgDiffRepoFolderName -Request @(
                    [PSCustomObject]@{ Repo = 'core'; Path = '' }
                    [PSCustomObject]@{ Repo = 'core'; Path = 'libs/core' }
                    [PSCustomObject]@{ Repo = 'x';    Path = 'x' }
                    [PSCustomObject]@{ Repo = 'x';    Path = 'x' }
                    [PSCustomObject]@{ Repo = 'a b:c'; Path = 'a b:c' })
            }
            @($names) | Should -Be @('core', 'libs-core', 'x', 'x-2', 'a-b-c')
        }
    }

    Describe 'Open-OgDirDiffSet: a launch failure is reported for that repo and the rest still launch' {
        BeforeEach {
            $script:reqs = @(
                New-TestWorkingRequest 'alpha' (New-TestDiffRepo 'alpha' -Dirty)
                New-TestWorkingRequest 'beta'  (New-TestDiffRepo 'beta'  -Dirty)
                New-TestWorkingRequest 'gamma' (New-TestDiffRepo 'gamma' -Dirty))
        }

        It 'a middle repo fails: failed with the launch detail and its folders, the others opened' {
            $script:ProbeQueue.Enqueue($true)
            $script:FailLaunch = @('beta')
            $r = Invoke-TestOpen @{ Request = $script:reqs; Label = 'worktree' }

            @($r.Action) | Should -Be @('opened', 'failed', 'opened')
            $r[1].Error | Should -Be 'boom beta'
            Test-Path -LiteralPath $r[1].BasePath | Should -BeTrue    # the export stays, to open by hand
            $r[1].RunPath | Should -Not -BeNullOrEmpty
            @($script:Events) | Should -Be @('probe', 'launch:alpha', 'sleep 300', 'launch:beta', 'sleep 300', 'launch:gamma')
            $script:Warnings | Should -HaveCount 1
            $script:Warnings[0] | Should -BeLike "*failed to launch*'beta'*boom beta*"
        }

        It 'the first repo fails: the next launch starts the instance, so the wait follows it' {
            foreach ($b in $false, $true) { $script:ProbeQueue.Enqueue($b) }
            $script:FailLaunch = @('alpha')
            $r = Invoke-TestOpen @{ Request = $script:reqs; Label = 'worktree' }

            @($r.Action) | Should -Be @('failed', 'opened', 'opened')
            @($script:Events) | Should -Be @('probe', 'launch:alpha', 'launch:beta', 'probe', 'sleep 300', 'launch:gamma')
        }
    }

    Describe 'Open-OgDirDiffSet: the probe timeout warns and still launches the rest' {
        It 'polls until -ProbeTimeoutMilliseconds, warns once, then launches every remaining repo' {
            $script:ProbeDefault = $false   # the tool's process never appears
            $reqs = @(
                New-TestWorkingRequest 'alpha' (New-TestDiffRepo 'alpha' -Dirty)
                New-TestWorkingRequest 'beta'  (New-TestDiffRepo 'beta'  -Dirty)
                New-TestWorkingRequest 'gamma' (New-TestDiffRepo 'gamma' -Dirty))

            $r = Invoke-TestOpen @{ Request = $reqs; Label = 'worktree'; ProbeTimeoutMilliseconds = 1000 }

            $expected = @('probe', 'launch:alpha') + (@('probe', 'sleep 100') * 10) + @('probe') +
                @('sleep 300', 'launch:beta', 'sleep 300', 'launch:gamma')
            @($script:Events) | Should -Be $expected
            @($r.Action) | Should -Be @('opened', 'opened', 'opened')
            $script:Warnings | Should -HaveCount 1
            $script:Warnings[0] | Should -BeLike "*'C:\Tools\FakeTool.exe' did not appear within 1000 ms*remaining 2 repo(s) anyway*"
        }

        It 'Wait-OgDiffToolProcess bounds the wait by the summed sleeps (last step shortened) and returns $false' {
            $script:ProbeDefault = $false
            $up = InModuleScope og-framework { Wait-OgDiffToolProcess -ExePath 'C:\x.exe' -TimeoutMilliseconds 250 -IntervalMilliseconds 100 }
            $up | Should -BeFalse
            @($script:Events) | Should -Be @('probe', 'sleep 100', 'probe', 'sleep 100', 'probe', 'sleep 50', 'probe')
        }
    }

    Describe 'Open-OgDirDiffSet: no tool configured' {
        It 'fails every changed repo with a clear error, keeps clean ones clean, and exports and launches nothing' {
            $alpha = New-TestDiffRepo 'alpha' -Dirty
            $beta  = New-TestDiffRepo 'beta'
            $gamma = New-TestDiffRepo 'gamma' -Dirty
            Invoke-TestGit $TestDrive config --global --unset diff.tool | Out-Null
            try {
                $r = Invoke-TestOpen @{ Request = @(
                        New-TestWorkingRequest 'alpha' $alpha
                        New-TestWorkingRequest 'beta'  $beta
                        New-TestWorkingRequest 'gamma' $gamma); Label = 'worktree' }
            } finally {
                Invoke-TestGit $TestDrive config --global diff.tool captest | Out-Null
            }

            @($r.Action) | Should -Be @('failed', 'clean', 'failed')
            foreach ($i in 0, 2) {
                $r[$i].Error     | Should -BeLike "No difftool configured*Refusing to fall back to 'git difftool --dir-diff'*"
                $r[$i].BasePath  | Should -BeNullOrEmpty
                $r[$i].FileCount | Should -Be 1
            }
            $script:Events.Count | Should -Be 0
            Test-Path -LiteralPath $script:RunRoot | Should -BeFalse
            $script:Warnings | Should -HaveCount 1
            Should -Invoke -ModuleName og-framework Invoke-Git -ParameterFilter { $Arguments -contains 'difftool' } -Times 0
        }

        It 'names an unconfigured -Tool in the error' {
            $alpha = New-TestDiffRepo 'alpha' -Dirty
            $r = Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $alpha); Label = 'worktree'; Tool = 'not-configured' }
            $r[0].Action | Should -Be 'failed'
            $r[0].Error  | Should -BeLike "No command configured for diff tool 'not-configured' (difftool.not-configured.cmd)*"
            $script:Events.Count | Should -Be 0
        }
    }

    Describe 'Open-OgDirDiffSet: a listing or export failure stays with its repo' {
        It 'a request outside a repo and a missing rev fail; the others still open' {
            $alpha = New-TestDiffRepo 'alpha' -Dirty
            $gamma = New-TestDiffRepo 'gamma' -Dirty
            $script:ProbeQueue.Enqueue($true)
            $r = Invoke-TestOpen @{ Request = @(
                    New-TestWorkingRequest 'alpha' $alpha
                    New-TestWorkingRequest 'nowhere' (New-TestDir 'notarepo')
                    New-TestRequest @{ Repo = 'missing'; WorkingDirectory = $gamma; Kind = 'Range'; BaseRev = '0123456789abcdef0123456789abcdef01234567'; HeadRev = 'HEAD' }
                    New-TestWorkingRequest 'gamma' $gamma); Label = 'worktree' }

            @($r.Action) | Should -Be @('opened', 'failed', 'failed', 'opened')
            $r[1].Error | Should -BeLike '*Not inside a git work tree*'
            $r[1].FileCount | Should -BeNullOrEmpty
            $r[2].Error | Should -BeLike '*does not resolve*'
            $r[2].BaseRev | Should -Be '0123456789abcdef0123456789abcdef01234567'
            @($script:Events) | Should -Be @('probe', 'launch:alpha', 'sleep 300', 'launch:gamma')
        }

        It 'an export failure fails that repo and is never launched; the rest launch' {
            $script:ProbeQueue.Enqueue($true)
            $reqs = @(
                New-TestWorkingRequest 'alpha' (New-TestDiffRepo 'alpha' -Dirty)
                New-TestWorkingRequest 'beta'  (New-TestDiffRepo 'beta'  -Dirty))
            Mock -ModuleName og-framework Export-OgDiffSides -ParameterFilter { $BaseDestination -like '*\alpha\*' } {
                throw 'disk full'
            }
            $r = Invoke-TestOpen @{ Request = $reqs; Label = 'worktree' }
            @($r.Action) | Should -Be @('failed', 'opened')
            $r[0].Error | Should -Be 'disk full'
            $r[0].RunPath | Should -BeNullOrEmpty
            @($script:Events) | Should -Be @('probe', 'launch:beta')
        }

        It 'every export failing leaves no empty run folder behind' {
            Mock -ModuleName og-framework Export-OgDiffSides { throw 'disk full' }
            $r = Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' (New-TestDiffRepo 'alpha' -Dirty)); Label = 'worktree' }
            $r[0].Action | Should -Be 'failed'
            Get-TestRunNames $script:RunRoot | Should -Be @()
            $script:Events.Count | Should -Be 0
        }
    }

    Describe 'Open-OgDirDiffSet: retention' {
        BeforeEach {
            $script:alpha = New-TestDiffRepo 'alpha' -Dirty
            [void] [System.IO.Directory]::CreateDirectory($script:RunRoot)
            $script:Old = @(1..10 | ForEach-Object { '20260101-0000{0:D2}-worktree' -f $_ })
            foreach ($name in $script:Old) { $null = New-TestRunFolder $script:RunRoot $name }

            # Foreign entries: none of them is a run, so none is counted or touched.
            $script:Foreign = @(
                (New-TestRunFolder $script:RunRoot 'legacy-repo' -Sides 'base', 'head' -NoMarker)     # og-diff\<repo>\{base,head}
                (New-TestRunFolder $script:RunRoot '20250101-000000-nomarker' -NoMarker)
                (New-TestRunFolder $script:RunRoot 'notarun-withmarker')
                (New-TestRunFolder $script:RunRoot '20251399-000000-badstamp')
                (New-TestRunFolder $script:RunRoot '20250101-000000-has space')
                (New-TestRunFolder $script:RunRoot '20250101-000000-loosefile'))
            Write-TestText (Join-Path $script:RunRoot '20250101-000000-loosefile') 'note.txt' 'mine'
            $loneSide = New-TestRunFolder $script:RunRoot '20250101-000000-onesidenomarker'
            Remove-Item -LiteralPath (Join-Path $loneSide 'repo\repo working.og-diff-side') -Force
            $script:Foreign += $loneSide
            [void] [System.IO.Directory]::CreateDirectory((Join-Path $script:RunRoot '20250101-000000-empty'))
            $script:Foreign += (Join-Path $script:RunRoot '20250101-000000-empty')
            Write-TestText $script:RunRoot '20250101-000000-afile' 'a file, not a folder'
            $script:Foreign += (Join-Path $script:RunRoot '20250101-000000-afile')

            $script:ForeignTrees = @{}
            foreach ($f in $script:Foreign) { $script:ForeignTrees[$f] = (Get-TestTree $f) -join '|' }
        }

        It 'keeps 10 runs: the current one and the 9 newest old ones; the oldest goes, foreign folders stay' {
            $r = (Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $script:alpha); Label = 'worktree' })[0]

            $runs = @(InModuleScope og-framework -Parameters @{ R = $script:RunRoot } {
                Get-ChildItem -LiteralPath $R -Directory | Where-Object { Test-OgDiffRunFolder -Directory $_ } | ForEach-Object Name })
            $runs.Count | Should -Be 10
            $runs | Should -Contain (Split-Path $r.RunPath -Leaf)
            $runs | Should -Not -Contain $script:Old[0]
            foreach ($name in $script:Old[1..9]) { $runs | Should -Contain $name }
            Test-Path -LiteralPath (Join-Path $script:RunRoot $script:Old[0]) | Should -BeFalse
            foreach ($f in $script:Foreign) {
                Test-Path -LiteralPath $f | Should -BeTrue -Because $f
                (Get-TestTree $f) -join '|' | Should -Be $script:ForeignTrees[$f] -Because $f
            }
            Test-Path -LiteralPath $script:RunRoot | Should -BeTrue
        }

        It '-Keep 3 keeps the current run and the 2 newest old ones' {
            $r = (Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $script:alpha); Label = 'worktree'; Keep = 3 })[0]
            $left = @(Get-TestRunNames $script:RunRoot | Where-Object { $_ -like '20260101-0000*-worktree' -or $_ -eq (Split-Path $r.RunPath -Leaf) })
            $left | Should -Be @('20260101-000009-worktree', '20260101-000010-worktree', (Split-Path $r.RunPath -Leaf))
            foreach ($f in $script:Foreign) { Test-Path -LiteralPath $f | Should -BeTrue -Because $f }
        }

        It 'never deletes the current run, even when every other run is newer' {
            $null = New-TestRunFolder $script:RunRoot '20990101-000000-future'
            $null = New-TestRunFolder $script:RunRoot '20990101-000001-future'
            $r = (Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $script:alpha); Label = 'worktree'; Keep = 2 })[0]
            Test-Path -LiteralPath $r.HeadPath | Should -BeTrue
            $left = @(Get-TestRunNames $script:RunRoot | Where-Object { $_ -like '20*-worktree' -or $_ -like '2099*' })
            $left | Should -Be @('20261022-153045-worktree', '20990101-000001-future')
        }

        It 'never follows a junction: a run-shaped junction, and runs whose repo or side folder is a junction, all stay' {
            $outside = New-TestDir 'outside'
            $target = New-TestRunFolder $outside '20200101-000000-target'
            $junction = Join-Path $script:RunRoot '20200101-000000-junction'
            $null = New-Item -ItemType Junction -Path $junction -Value $target
            $hostRun = Join-Path $script:RunRoot '20200101-000001-hostsjunction'
            [void] [System.IO.Directory]::CreateDirectory($hostRun)
            $null = New-Item -ItemType Junction -Path (Join-Path $hostRun 'repo') -Value (Join-Path $target 'repo')
            $before = (Get-TestTree $target) -join '|'

            # Review R2: a run that is genuine except that one SIDE folder is a junction to a marker-carrying canary.
            # od task 7: the junction carries BOTH marker forms (in-folder via the canary, and a sibling file),
            # so only the link check can keep this run.
            $canary = Join-Path $outside 'canary'
            Write-TestText $canary '.og-diff-side' 'marker'
            Write-TestText $canary 'keep.txt' 'precious'
            $sideRun = New-TestRunFolder $script:RunRoot '20200101-000002-sidejunction' -Sides 'repo working'
            $null = New-Item -ItemType Junction -Path (Join-Path $sideRun 'repo\repo base 1234567') -Value $canary
            Write-TestText (Join-Path $sideRun 'repo') 'repo base 1234567.og-diff-side' 'marker'
            $canaryBefore = (Get-TestTree $canary) -join '|'

            $null = Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $script:alpha); Label = 'worktree'; Keep = 1 }

            Test-Path -LiteralPath $junction | Should -BeTrue
            Test-Path -LiteralPath $hostRun  | Should -BeTrue
            (Get-TestTree $target) -join '|' | Should -Be $before
            Test-Path -LiteralPath (Join-Path $sideRun 'repo\repo base 1234567') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $sideRun 'repo\repo working\a.txt') | Should -BeTrue
            (Get-TestTree $canary) -join '|' | Should -Be $canaryBefore
            # Keep 1: every real old run is gone, only the current one is left of them.
            @(Get-TestRunNames $script:RunRoot | Where-Object { $_ -like '20260101-*' }) | Should -Be @()
        }

        It 'a child of og-diff that cannot be listed is no run: results come back (caller in try), other old runs still pruned' {
            # Review R1. Genuine run shape, but the folder denies listing (as for another user's folder): it is not
            # provably a run, so it is neither counted nor deleted, and it must not abort the call or the prune.
            $denied = New-TestRunFolder $script:RunRoot '20260101-000005-denied'
            $null = & icacls $denied /deny "$($env:USERNAME):(RD)" 2>&1
            try {
                { [System.IO.DirectoryInfo]::new($denied).GetFileSystemInfos() } | Should -Throw -Because 'the deny must bite'
                $caught = $null
                $r = $null
                try {
                    $r = Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $script:alpha); Label = 'worktree' }
                } catch { $caught = $_.Exception.Message }
            } finally {
                $null = & icacls $denied /remove:d "$($env:USERNAME)" 2>&1
            }

            $caught | Should -BeNullOrEmpty
            $r[0].Action | Should -Be 'opened'
            $script:Warnings | Should -BeNullOrEmpty
            # 10 old + the current run, the denied folder not counted: the oldest goes, the rest stay.
            Test-Path -LiteralPath (Join-Path $script:RunRoot $script:Old[0]) | Should -BeFalse
            foreach ($name in $script:Old[1..9]) { Test-Path -LiteralPath (Join-Path $script:RunRoot $name) | Should -BeTrue }
            Test-Path -LiteralPath (Join-Path $denied 'repo\repo working\a.txt') | Should -BeTrue
        }

        It 'a prune that throws anyway is one warning; the results still come back (caller in try)' {
            Mock -ModuleName og-framework Remove-OgDiffOldRun { throw 'prune exploded' }
            $caught = $null
            $r = $null
            try {
                $r = Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $script:alpha); Label = 'worktree' }
            } catch { $caught = $_.Exception.Message }
            $caught | Should -BeNullOrEmpty
            $r[0].Action | Should -Be 'opened'
            $script:Warnings | Should -HaveCount 1
            $script:Warnings[0] | Should -BeLike '*Pruning old og diff runs*prune exploded*'
        }

        It 'Test-OgDiffRunFolder answers $false, without throwing, for a folder that vanished after it was listed' {
            $gone = [System.IO.DirectoryInfo]::new((New-TestRunFolder $script:RunRoot '20260101-000011-vanished'))
            Remove-Item -LiteralPath $gone.FullName -Recurse -Force
            InModuleScope og-framework -Parameters @{ D = $gone } { Test-OgDiffRunFolder -Directory $D } | Should -BeFalse
        }

        It 'Remove-OgDiffOldRun refuses a root that is not an og-diff folder and deletes nothing' {
            $parent = Split-Path $script:RunRoot -Parent
            $before = (Get-TestTree $parent) -join '|'
            { InModuleScope og-framework -Parameters @{ R = $parent; C = (Join-Path $parent 'x') } {
                    Remove-OgDiffOldRun -RunRoot $R -CurrentRun $C -Keep 1 } } | Should -Throw "*must be named 'og-diff'*"
            (Get-TestTree $parent) -join '|' | Should -Be $before
        }
    }

    # od task 7: the marker moved beside the side folder. The prune must take runs in either marker form
    # (the runs made before task 7 must still age out) and keep anything else.
    Describe 'Open-OgDirDiffSet: retention, marker forms (od task 7)' {
        BeforeEach {
            $script:alpha = New-TestDiffRepo 'alpha' -Dirty
            [void] [System.IO.Directory]::CreateDirectory($script:RunRoot)
            # Two genuine new-layout runs older than everything below: proof that the prune did run.
            $script:Genuine = @(
                (New-TestRunFolder $script:RunRoot '20200101-000000-genuine')
                (New-TestRunFolder $script:RunRoot '20200101-000001-genuine'))
        }

        It 'prunes runs made before od task 7 (old side names, marker INSIDE each side): they still age out' {
            $old = @(1..3 | ForEach-Object { '20260101-0000{0:D2}-worktree' -f $_ })
            foreach ($name in $old) {
                $null = New-TestRunFolder $script:RunRoot $name -Sides 'base-1234567', 'working' -Marker InFolder
            }
            $isRun = @(InModuleScope og-framework -Parameters @{ R = $script:RunRoot; N = $old } {
                    $N | ForEach-Object { Test-OgDiffRunFolder -Directory ([System.IO.DirectoryInfo]::new((Join-Path $R $_))) } })
            $isRun | Should -Be @($true, $true, $true)

            $r = (Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $script:alpha); Label = 'worktree'; Keep = 2 })[0]

            Get-TestRunNames $script:RunRoot | Should -Be @($old[2], (Split-Path $r.RunPath -Leaf))
        }

        It 'prunes a run whose two sides carry the marker in different forms' {
            $mixed = New-TestRunFolder $script:RunRoot '20210101-000000-mixed' -Sides 'repo base 1234567'
            $null = New-TestRunFolder $script:RunRoot '20210101-000000-mixed' -Sides 'working' -Marker InFolder
            InModuleScope og-framework -Parameters @{ D = $mixed } {
                Test-OgDiffRunFolder -Directory ([System.IO.DirectoryInfo]::new($D)) } | Should -BeTrue
            $null = Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $script:alpha); Label = 'worktree'; Keep = 1 }
            Test-Path -LiteralPath $mixed | Should -BeFalse
        }

        # SEEN FAILING (Backlog task 7 AC): with the sibling-marker check dropped, this run is pruned.
        It 'keeps a run whose side folder has no marker in either form (unmarked side is not pruned)' {
            $unmarked = New-TestRunFolder $script:RunRoot '20190101-000000-unmarkedside'
            Remove-Item -LiteralPath (Join-Path $unmarked 'repo\repo working.og-diff-side') -Force
            Test-Path -LiteralPath (Join-Path $unmarked 'repo\repo working\.og-diff-side') | Should -BeFalse
            $before = (Get-TestTree $unmarked) -join '|'

            $null = Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $script:alpha); Label = 'worktree'; Keep = 1 }

            foreach ($g in $script:Genuine) { Test-Path -LiteralPath $g | Should -BeFalse -Because "$g is a genuine old run" }
            Test-Path -LiteralPath $unmarked | Should -BeTrue
            (Get-TestTree $unmarked) -join '|' | Should -Be $before
        }

        It 'keeps a run with a stray file in a repo folder, or a marker whose side folder is gone, or markers only' {
            $stray = New-TestRunFolder $script:RunRoot '20190101-000001-strayfile'
            Write-TestText (Join-Path $stray 'repo') 'notes.txt' 'mine'
            $orphan = New-TestRunFolder $script:RunRoot '20190101-000002-orphanmarker'
            Write-TestText (Join-Path $orphan 'repo') 'repo head 7654321.og-diff-side' 'marker'
            $markersOnly = New-TestRunFolder $script:RunRoot '20190101-000003-markersonly'
            Get-ChildItem -LiteralPath (Join-Path $markersOnly 'repo') -Directory | Remove-Item -Recurse -Force
            (Get-ChildItem -LiteralPath (Join-Path $markersOnly 'repo') -Force).Count | Should -Be 2
            $kept = @($stray, $orphan, $markersOnly)
            $before = @{}; foreach ($k in $kept) { $before[$k] = (Get-TestTree $k) -join '|' }

            $null = Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $script:alpha); Label = 'worktree'; Keep = 1 }

            foreach ($g in $script:Genuine) { Test-Path -LiteralPath $g | Should -BeFalse -Because "$g is a genuine old run" }
            foreach ($k in $kept) {
                Test-Path -LiteralPath $k | Should -BeTrue -Because $k
                (Get-TestTree $k) -join '|' | Should -Be $before[$k] -Because $k
            }
        }

        It 'keeps a run where only a FOLDER of the marker''s name sits beside a side (a marker is a file)' {
            $dirMarker = New-TestRunFolder $script:RunRoot '20190101-000004-dirmarker' -Sides 'repo working' -NoMarker
            $null = New-Item -ItemType Directory (Join-Path $dirMarker 'repo\repo working.og-diff-side')
            $null = Invoke-TestOpen @{ Request = @(New-TestWorkingRequest 'alpha' $script:alpha); Label = 'worktree'; Keep = 1 }
            Test-Path -LiteralPath (Join-Path $dirMarker 'repo\repo working\a.txt') | Should -BeTrue
        }
    }

    Describe 'New-OgDirDiffRequest and request validation' {
        It 'stores Range revs as given, empty string included, and leaves them $null otherwise' {
            $range = New-TestRequest @{ Repo = 'r'; WorkingDirectory = 'C:\x'; Kind = 'Range'; BaseRev = ''; HeadRev = 'HEAD' }
            $range.BaseRev | Should -BeExactly ''
            $range.HeadRev | Should -Be 'HEAD'
            $range.Path    | Should -BeExactly ''
            $range.PSObject.TypeNames | Should -Contain 'Og.DirDiffRequest'
            $wt = New-TestRequest @{ Repo = 'r'; WorkingDirectory = 'C:\x'; Kind = 'WorkingTree' }
            $wt.BaseRev | Should -BeNullOrEmpty
            $null -eq $wt.BaseRev | Should -BeTrue
            $null -eq $wt.Commit  | Should -BeTrue
        }

        It 'rejects a Range without both revs and revs on another kind' {
            { New-TestRequest @{ Repo = 'r'; WorkingDirectory = 'C:\x'; Kind = 'Range'; BaseRev = 'a' } } | Should -Throw '*both -BaseRev and -HeadRev*'
            { New-TestRequest @{ Repo = 'r'; WorkingDirectory = 'C:\x'; Kind = 'Staged'; HeadRev = 'a' } } | Should -Throw '*belong to -Kind Range*'
        }

        It 'Open-OgDirDiffSet rejects a hand-built request missing <Missing> before listing anything' -ForEach @(
            @{ Missing = 'WorkingDirectory'; Req = @{ Repo = 'r'; Kind = 'WorkingTree' } }
            @{ Missing = 'Repo';             Req = @{ WorkingDirectory = 'C:\x'; Kind = 'WorkingTree' } }
            @{ Missing = 'HeadRev';          Req = @{ Repo = 'r'; WorkingDirectory = 'C:\x'; Kind = 'Range'; BaseRev = 'a'; HeadRev = $null } }
            @{ Missing = 'Kind';             Req = @{ Repo = 'r'; WorkingDirectory = 'C:\x'; Kind = 'Sideways' } }
        ) {
            Mock -ModuleName og-framework Get-OgDiffChange { throw 'must not list' }
            { Invoke-TestOpen @{ Request = @([PSCustomObject] $Req); Label = 'x' } } | Should -Throw "Open-OgDirDiffSet: request 0*"
            Should -Invoke -ModuleName og-framework Get-OgDiffChange -Times 0
        }
    }

    Describe 'Pure helpers' {
        It 'Get-OgDiffToolExePath: <Line> -> <Expected>' -ForEach @(
            @{ Line = '"C:\Program Files\Diffinity\Diffinity.exe" "C:\a b" "C:\c"'; Expected = 'C:\Program Files\Diffinity\Diffinity.exe' }
            @{ Line = '  meld "C:\a" "C:\b"';                                       Expected = 'meld' }
            @{ Line = 'C:\Tools\x.exe --diff C:\a C:\b';                            Expected = 'C:\Tools\x.exe' }
            @{ Line = '';                                                           Expected = $null }
            @{ Line = '""';                                                         Expected = $null }
        ) {
            $got = InModuleScope og-framework -Parameters @{ L = $Line } { Get-OgDiffToolExePath -CommandLine $L }
            if ($null -eq $Expected) { $got | Should -BeNullOrEmpty } else { $got | Should -BeExactly $Expected }
        }

        It 'ConvertTo-OgDiffPathLabel: <Text> -> <Expected>' -ForEach @(
            @{ Text = 'origin/main';   Expected = 'origin-main' }
            @{ Text = 'feature/a:b';   Expected = 'feature-a-b' }
            @{ Text = 'CON';           Expected = '_CON' }
            @{ Text = 'nul.txt';       Expected = '_nul.txt' }
            @{ Text = '';              Expected = 'fb' }
            @{ Text = '-..-';          Expected = 'fb' }
            @{ Text = ('x' * 70);      Expected = ('x' * 60) }
        ) {
            InModuleScope og-framework -Parameters @{ T = $Text } { ConvertTo-OgDiffPathLabel -Text $T -Fallback 'fb' } |
                Should -BeExactly $Expected
        }

        # od task 7: was 'both sides empty become base-empty and head-empty'; every name now carries the repo.
        It 'Get-OgDiffSideLabel: <Kind> <Base>..<Head> -> "<ExpectedBase>" / "<ExpectedHead>"' -ForEach @(
            @{ Kind = 'WorkingTree'; Base = '1234567890ab'; Head = $null;          ExpectedBase = 'core base 1234567'; ExpectedHead = 'core working' }
            @{ Kind = 'WorkingTree'; Base = $null;          Head = $null;          ExpectedBase = 'core base empty';   ExpectedHead = 'core working' }
            @{ Kind = 'Staged';      Base = '1234567890ab'; Head = $null;          ExpectedBase = 'core base 1234567'; ExpectedHead = 'core index' }
            @{ Kind = 'Range';       Base = '1234567890ab'; Head = 'abcdef012345'; ExpectedBase = 'core base 1234567'; ExpectedHead = 'core head abcdef0' }
            @{ Kind = 'Range';       Base = $null;          Head = 'abcdef012345'; ExpectedBase = 'core base empty';   ExpectedHead = 'core head abcdef0' }
            @{ Kind = 'Range';       Base = '1234567890ab'; Head = $null;          ExpectedBase = 'core base 1234567'; ExpectedHead = 'core head empty' }
            @{ Kind = 'Range';       Base = $null;          Head = $null;          ExpectedBase = 'core base empty';   ExpectedHead = 'core head empty' }
        ) {
            $l = InModuleScope og-framework -Parameters @{ K = $Kind; B = $Base; H = $Head } {
                Get-OgDiffSideLabel -RepoFolderName 'core' -ChangeSet ([PSCustomObject]@{ Kind = $K; BaseCommit = $B; HeadCommit = $H })
            }
            $l.Base | Should -BeExactly $ExpectedBase
            $l.Head | Should -BeExactly $ExpectedHead
        }
    }

    Describe 'The seams'' own bodies (dot-sourced, outside the module mocks)' {
        BeforeAll {
            # A private copy of the functions in this scope: the module's mocks do not reach it.
            . $script:SourceFile
        }

        It 'Get-OgDiffRunRoot is GetTempPath()\og-diff and passes Assert-OgDiffRunRoot' {
            $root = Get-OgDiffRunRoot
            $root | Should -Be (Join-Path ([System.IO.Path]::GetTempPath()) 'og-diff')
            Assert-OgDiffRunRoot -Path $root | Should -Be ([System.IO.Path]::GetFullPath($root).TrimEnd('\'))
        }

        It 'Test-OgDiffToolProcessRunning finds this very process by path and by name, and nothing else' {
            $self = (Get-Process -Id $PID).Path
            Test-OgDiffToolProcessRunning -ExePath $self | Should -BeTrue
            Test-OgDiffToolProcessRunning -ExePath ([System.IO.Path]::GetFileName($self)) | Should -BeTrue
            # The user's real difftool.diffinity.cmd reads back with DOUBLED backslashes
            # ("C:\\Program Files\\Diffinity\\Diffinity.exe", measured in the od-2 dry check): still a match.
            Test-OgDiffToolProcessRunning -ExePath $self.Replace('\', '\\') | Should -BeTrue
            Test-OgDiffToolProcessRunning -ExePath (Join-Path 'C:\no\such\dir' ([System.IO.Path]::GetFileName($self))) | Should -BeFalse
            Test-OgDiffToolProcessRunning -ExePath 'C:\no\such\og-diff-no-such-tool-7f3a.exe' | Should -BeFalse
        }

        It 'Get-OgDiffNow is the local clock' {
            $before = [datetime]::Now
            $now = Get-OgDiffNow
            $now.Kind | Should -Be ([System.DateTimeKind]::Local)
            ($now -ge $before) | Should -BeTrue
        }
    }
}
