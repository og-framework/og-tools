# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

# Covers the commit picker's UI (od task 5a, design D6): the row list builder, the lazy cached touch
# resolution, the pure renderer and viewport rule, and the key loop. Every repo is a throwaway under
# $TestDrive, sandboxed by Enter-OgGitSandbox. NOTHING TOUCHES THE REAL CONSOLE: the loop tests mock every
# console seam (capability, enter/exit screen, window size, draw, key-available, read-key); the keys come
# from a queue, and an exhausted queue throws, so a loop that does not end fails instead of hanging (and the
# key-available mock turns true after 200 polls, so a resolve loop that never ends reaches the keys too).
# Nothing launches a tool: the end-to-end dry run also mocks Start-OgDiffToolProcess and asserts 0 calls.

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force
    . "$PSScriptRoot\OgGitTestHelpers.ps1"
    Enter-OgGitSandbox -Root (Join-Path $TestDrive 'sandbox')

    $script:SourceFile = Join-Path $moduleRoot 'Private\Show-OgDiffPicker.ps1'
    $script:Ell = [string] [char] 0x2026

    # A key press as [Console]::ReadKey returns it.
    function New-TestKey {
        param([System.ConsoleKey] $Key, [char] $Char = [char] 0)
        [System.ConsoleKeyInfo]::new($Char, $Key, $false, $false, $false)
    }

    # n fake rows: Sha 'sha<ii>' padded to 40, ShortSha 'r<ii>____' (7 chars), Subject 'subject <i>'.
    function New-TestRows {
        param([int] $Count)
        @(for ($i = 0; $i -lt $Count; $i++) {
            [PSCustomObject]@{
                PSTypeName = 'Og.PickerRow'
                Sha        = ('sha{0:D2}' -f $i).PadRight(40, '0')
                ShortSha   = ('r{0:D2}' -f $i).PadRight(7, '_')
                Date       = '2026-10-22 21:{0:D2}' -f $i
                Subject    = "subject $i"
                Touched    = $null
                Entries    = $null
                TouchError = $null
            }
        })
    }

    function New-TestEntry {
        param([string] $Repo, [string] $BaseRev = ('b' * 40), [string] $HeadRev = ('c' * 40), [string] $Status = 'changed',
              [string] $ErrorText = $null)
        [PSCustomObject]@{
            PSTypeName = 'Og.CommitRangeEntry'; Repo = $Repo; Path = ''; WorkingDirectory = ''
            BaseRev = $BaseRev; HeadRev = $HeadRev; Status = $Status; Error = $ErrorText
        }
    }

    function New-TestModel {
        param([object[]] $Rows, [scriptblock] $Resolver, [scriptblock] $Summary, [string] $Title = 'proj')
        InModuleScope og-framework -Parameters @{ R = $Rows; V = $Resolver; S = $Summary; T = $Title } {
            New-OgPickerModel -Rows $R -TouchResolver $V -TouchSummary $S -Title $T
        }
    }

    function Invoke-TestLoop {
        param($Model)
        InModuleScope og-framework -Parameters @{ M = $Model } { Select-OgPickerRow -Model $M }
    }

    function Invoke-TestRender {
        param([object[]] $Rows, [int] $Selected, [int] $Top, [int] $Width, [int] $Height, [string] $Title = 'proj')
        # Always a string[] (one line included), so $lines[0] is a line, never a character.
        $lines = [string[]] @(InModuleScope og-framework -Parameters @{ R = $Rows; S = $Selected; O = $Top; W = $Width; H = $Height; T = $Title } {
            Format-OgPickerScreen -Rows $R -Selected $S -Top $O -Width $W -Height $H -Title $T
        })
        Write-Output -NoEnumerate $lines
    }

    # Commits a file with a fixed author/committer time (unix seconds) and message.
    function Add-TestTimedCommit {
        param([string] $Dir, [long] $Unix, [string] $Message, [string] $File = 'f.txt')
        Set-Content -LiteralPath (Join-Path $Dir $File) -Value ([guid]::NewGuid().ToString('N'))
        Invoke-TestGit $Dir add -- $File | Out-Null
        $env:GIT_AUTHOR_DATE    = "$Unix +0000"
        $env:GIT_COMMITTER_DATE = "$Unix +0000"
        try { Invoke-TestGit $Dir commit -q -m $Message | Out-Null }
        finally { Remove-Item env:GIT_AUTHOR_DATE, env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue }
    }

    # The repo's read-only fingerprint: HEAD, every ref, the index file's and HEAD reflog's hashes. No 'git status':
    # it may refresh (rewrite) the index itself, which would make the fingerprint differ for no reason of ours.
    function Get-TestRepoFingerprint {
        param([string] $Dir)
        $index = Join-Path $Dir '.git\index'
        @(
            Invoke-TestGit $Dir rev-parse HEAD
            Invoke-TestGit $Dir for-each-ref
            (Get-FileHash -LiteralPath $index -Algorithm SHA256).Hash
            (Get-FileHash -LiteralPath (Join-Path $Dir '.git\logs\HEAD') -Algorithm SHA256).Hash
        ) -join "`n"
    }
}

AfterAll {
    Exit-OgGitSandbox
}

Describe 'Get-OgPickerRows (the row list builder)' {
    BeforeAll {
        # main: one, two, (side branch: side one), three, merge of side (no-ff), then a non-ASCII subject.
        $script:Repo = New-TestDir 'rows'
        Invoke-TestGit $script:Repo init -q | Out-Null
        $script:T0 = [long] 1793000000
        Add-TestTimedCommit $script:Repo ($script:T0 + 0)   'one'
        Add-TestTimedCommit $script:Repo ($script:T0 + 60)  'two'
        Invoke-TestGit $script:Repo checkout -q -b side | Out-Null
        Add-TestTimedCommit $script:Repo ($script:T0 + 120) 'side one' 'side.txt'
        Invoke-TestGit $script:Repo checkout -q main | Out-Null
        Add-TestTimedCommit $script:Repo ($script:T0 + 180) 'three'
        $env:GIT_AUTHOR_DATE = "$($script:T0 + 240) +0000"; $env:GIT_COMMITTER_DATE = "$($script:T0 + 240) +0000"
        try { Invoke-TestGit $script:Repo merge -q --no-ff -m 'merge side' side | Out-Null }
        finally { Remove-Item env:GIT_AUTHOR_DATE, env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue }
        $script:Unicode = 'four ' + [char] 0x00DC + 'n' + [char] 0x00EF + 'code ' + [char] 0x2713
        Add-TestTimedCommit $script:Repo ($script:T0 + 300) $script:Unicode
    }

    It 'lists the first-parent line of HEAD, newest first, with full and short ids, local dates and subjects' {
        $before = Get-TestRepoFingerprint $script:Repo
        $rows = @(InModuleScope og-framework -Parameters @{ P = $script:Repo } { Get-OgPickerRows -ProjectRoot $P })

        $expectedShas = @((Invoke-TestGit $script:Repo rev-list --first-parent HEAD) -split "`r?`n")
        @($rows.Sha) | Should -Be $expectedShas
        @($rows.Subject) | Should -Be @($script:Unicode, 'merge side', 'three', 'two', 'one')
        @($rows.Subject) | Should -Not -Contain 'side one'
        $rows[0].PSObject.TypeNames[0] | Should -Be 'Og.PickerRow'
        foreach ($row in $rows) {
            $row.Sha | Should -Match '^[0-9a-f]{40}$'
            $row.Sha.StartsWith($row.ShortSha) | Should -BeTrue
            $row.ShortSha.Length | Should -BeGreaterOrEqual 7
            $row.Touched | Should -BeNullOrEmpty
            $row.Entries | Should -BeNullOrEmpty
        }
        # Oracle: git's own local-time rendering of the author date.
        $gitDates = @((Invoke-TestGit $script:Repo log --first-parent '--date=format-local:%Y-%m-%d %H:%M' '--format=%ad') -split "`r?`n")
        @($rows.Date) | Should -Be $gitDates
        $rows[4].Date | Should -Be ([DateTimeOffset]::FromUnixTimeSeconds($script:T0).LocalDateTime.ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture))
        Get-TestRepoFingerprint $script:Repo | Should -Be $before
    }

    It '-Count limits the rows to the newest n' {
        $rows = @(InModuleScope og-framework -Parameters @{ P = $script:Repo } { Get-OgPickerRows -ProjectRoot $P -Count 2 })
        @($rows.Subject) | Should -Be @($script:Unicode, 'merge side')
    }

    It 'throws a clear error on a repo without commits' {
        $empty = New-TestDir 'unborn'
        Invoke-TestGit $empty init -q | Out-Null
        { InModuleScope og-framework -Parameters @{ P = $empty } { Get-OgPickerRows -ProjectRoot $P } } |
            Should -Throw "Cannot list the commits of HEAD in '$empty'*"
    }
}

Describe 'The key loop (Select-OgPickerRow) with mocked console seams' {
    BeforeEach {
        $script:Keys       = [System.Collections.Generic.Queue[System.ConsoleKeyInfo]]::new()
        $script:Sizes      = [System.Collections.Generic.Queue[object]]::new()
        $script:Sizes.Enqueue([PSCustomObject]@{ Width = 81; Height = 8 })   # usable width 80, viewport 5
        $script:Frames     = [System.Collections.Generic.List[object]]::new()
        $script:Events     = [System.Collections.Generic.List[string]]::new()
        $script:Calls      = [System.Collections.Generic.List[string]]::new()
        $script:KeyWaiting = $false
        $script:Polls      = 0
        $script:Capability = [PSCustomObject]@{ InputRedirected = $false; OutputRedirected = $false; VirtualTerminal = $true }

        Mock Get-OgPickerConsoleCapability -ModuleName og-framework { $script:Capability }
        Mock Enter-OgPickerScreen -ModuleName og-framework { $script:Events.Add('enter'); [PSCustomObject]@{ CursorVisible = $true } }
        Mock Exit-OgPickerScreen -ModuleName og-framework { $script:Events.Add('exit') }
        Mock Get-OgPickerWindowSize -ModuleName og-framework {
            if ($script:Sizes.Count -gt 1) { $script:Sizes.Dequeue() } else { $script:Sizes.Peek() }
        }
        Mock Write-OgPickerScreen -ModuleName og-framework {
            $script:Events.Add('draw')
            $script:Frames.Add([PSCustomObject]@{ Lines = @($Lines); Highlight = $Highlight; Width = $Width })
        }
        # Hang guard: after 200 polls a key is 'waiting', so a loop that would resolve forever (a row that never
        # stops being pending) reads the key list instead, and the test FAILS on its call counts instead of hanging.
        Mock Test-OgPickerKeyAvailable -ModuleName og-framework { $script:Polls++; $script:KeyWaiting -or $script:Polls -gt 200 }
        Mock Read-OgPickerKey -ModuleName og-framework {
            if ($script:Keys.Count -eq 0) { throw 'test key list exhausted' }
            $script:Events.Add('key')
            $script:Keys.Dequeue()
        }

        function Push-TestKeys {
            param([object[]] $List)
            foreach ($k in $List) {
                if ($k -is [string]) { $script:Keys.Enqueue((New-TestKey ([System.ConsoleKey]::Q) ([char] $k))) }
                else { $script:Keys.Enqueue((New-TestKey $k)) }
            }
        }

        $script:KDown = [System.ConsoleKey]::DownArrow; $script:KUp = [System.ConsoleKey]::UpArrow
        $script:KPgDn = [System.ConsoleKey]::PageDown;  $script:KPgUp = [System.ConsoleKey]::PageUp
        $script:KHome = [System.ConsoleKey]::Home;      $script:KEnd = [System.ConsoleKey]::End
        $script:KEnter = [System.ConsoleKey]::Enter;    $script:KEsc = [System.ConsoleKey]::Escape
    }

    Context 'Moving and picking' {
        BeforeEach {
            $script:Rows  = New-TestRows 12
            $script:Model = New-TestModel -Rows $script:Rows
        }

        It 'Down, Down, Enter returns the third row' {
            Push-TestKeys @($script:KDown, $script:KDown, $script:KEnter)
            $picked = Invoke-TestLoop $script:Model
            $picked.Sha | Should -Be $script:Rows[2].Sha
            @($picked).Count | Should -Be 1
        }

        It 'Esc returns nothing' {
            Push-TestKeys @($script:KDown, $script:KEsc)
            Invoke-TestLoop $script:Model | Should -BeNullOrEmpty
        }

        It 'q returns nothing; any other key is ignored' {
            Push-TestKeys @($script:KDown, 'x', 'q')
            Invoke-TestLoop $script:Model | Should -BeNullOrEmpty
            $script:Frames[-1].Lines[2] | Should -BeLike '> r01____*'    # 'x' did not move: row 1 still selected
        }

        It 'PgDn moves one viewport and clamps at the last row' {
            Push-TestKeys @($script:KPgDn, $script:KPgDn, $script:KPgDn, $script:KEnter)
            (Invoke-TestLoop $script:Model).Sha | Should -Be $script:Rows[11].Sha
            # Selections 0 -> 5 -> 10 -> 11 (clamped): the highlighted row line per frame.
            @($script:Frames | ForEach-Object { $_.Lines[$_.Highlight].Substring(0, 9) }) |
                Should -Be @('> r00____', '> r05____', '> r10____', '> r11____')
        }

        It 'End selects the last row and Down there stays; Home and Up/PgUp clamp at the first row' {
            Push-TestKeys @($script:KEnd, $script:KDown, $script:KEnter)
            (Invoke-TestLoop $script:Model).Sha | Should -Be $script:Rows[11].Sha

            $script:Frames.Clear()
            Push-TestKeys @($script:KEnd, $script:KHome, $script:KUp, $script:KPgUp, $script:KEnter)
            (Invoke-TestLoop $script:Model).Sha | Should -Be $script:Rows[0].Sha
        }

        It 'redraws once per key and leaves the screen exactly once, after the last draw' {
            Push-TestKeys @($script:KDown, $script:KEnter)
            $null = Invoke-TestLoop $script:Model
            @($script:Events) | Should -Be @('enter', 'draw', 'key', 'draw', 'key', 'exit')
        }

        # R1 (review od-5a): the row must reach the pipeline only AFTER the screen is restored. A `return` inside the
        # loop's try emits it first and runs the finally afterwards, so Out-Default (or 5b's diff) would run on the
        # alternate screen. The downstream stage runs in the module scope so the pipeline really streams.
        It 'emits the row downstream only after the screen is restored (<name>)' -TestCases @(
            @{ name = 'Enter'; expected = @('enter', 'draw', 'key', 'draw', 'key', 'exit', 'out') }
            @{ name = 'Esc';   expected = @('enter', 'draw', 'key', 'draw', 'key', 'exit') }
            @{ name = 'q';     expected = @('enter', 'draw', 'key', 'draw', 'key', 'exit') }
        ) {
            $finalKey = switch ($name) { 'Enter' { $script:KEnter } 'Esc' { $script:KEsc } 'q' { 'q' } }
            Push-TestKeys @($script:KDown, $finalKey)
            $seen = InModuleScope og-framework -Parameters @{ M = $script:Model; E = $script:Events } {
                Select-OgPickerRow -Model $M | ForEach-Object { $E.Add('out'); $_ }
            }
            @($script:Events) | Should -Be $expected
            if ($name -eq 'Enter') { $seen.Sha | Should -Be $script:Rows[1].Sha } else { $seen | Should -BeNullOrEmpty }
        }
    }

    # od task 11a (R5): Space marks one end of a range; Enter, h and w return an Og.PickerChoice.
    Context 'Marking a base and choosing a range' {
        BeforeEach {
            $script:Rows   = New-TestRows 12
            $script:Model  = New-TestModel -Rows $script:Rows
            $script:KSpace = [System.ConsoleKey]::Spacebar
        }

        It 'Enter without a mark returns today''s single commit: Kind Commit, the row''s sha as Commit and Sha, the row itself' {
            Push-TestKeys @($script:KDown, $script:KDown, $script:KEnter)
            $choice = Invoke-TestLoop $script:Model
            @($choice).Count | Should -Be 1
            $choice.PSObject.TypeNames[0] | Should -Be 'Og.PickerChoice'
            ($choice.PSObject.Properties.Name -join ',') | Should -Be 'Kind,Commit,From,To,WorkingTree,Sha,Row'
            $choice.Kind | Should -Be 'Commit'
            $choice.Commit | Should -Be $script:Rows[2].Sha
            $choice.Sha | Should -Be $script:Rows[2].Sha            # what Show-OgDiff -Pick (5b) reads until 11b
            [object]::ReferenceEquals($choice.Row, $script:Rows[2]) | Should -BeTrue
            $choice.From | Should -BeNullOrEmpty
            $choice.To | Should -BeNullOrEmpty
            $choice.WorkingTree | Should -BeFalse
        }

        It 'Space marks the selected row, the header names the base, and Space on the marked row clears the mark' {
            Push-TestKeys @($script:KDown, $script:KSpace, $script:KSpace, $script:KEnter)
            $choice = Invoke-TestLoop $script:Model
            # Frames: start, after Down, after the 1st Space (marked), after the 2nd Space (cleared).
            $script:Frames.Count | Should -Be 4
            $script:Frames[1].Lines[0] | Should -BeExactly 'Pick a commit: proj  (2/12)'
            $script:Frames[2].Lines[0] | Should -BeExactly 'Pick a commit: proj  (2/12)  base: r01____'
            $script:Frames[2].Lines[2] | Should -BeLike '>*r01____  2026-10-22 21:01  *'
            @($script:Frames[2].Lines[1..5] | Where-Object { $_[1] -eq '*' }).Count | Should -Be 1
            $script:Frames[3].Lines[0] | Should -BeExactly 'Pick a commit: proj  (2/12)'
            @($script:Frames[3].Lines[1..5] | Where-Object { $_[1] -eq '*' }).Count | Should -Be 0
            $script:Frames[3].Lines[2] | Should -BeLike '> r01____*'
            # No mark left: Enter is the single commit again.
            $choice.Kind | Should -Be 'Commit'
            $choice.Commit | Should -Be $script:Rows[1].Sha
        }

        It 'keeps one mark at a time: Space on another row moves the mark there' {
            Push-TestKeys @($script:KSpace, $script:KDown, $script:KDown, $script:KSpace, $script:KEsc)
            $null = Invoke-TestLoop $script:Model
            $last = $script:Frames[-1]
            @($last.Lines[1..5] | Where-Object { $_[1] -eq '*' }).Count | Should -Be 1
            $last.Lines[3] | Should -BeLike '>*r02____*'
            $last.Lines[1] | Should -BeLike '  r00____*'
            $last.Lines[0] | Should -BeExactly 'Pick a commit: proj  (3/12)  base: r02____'
        }

        It 'Enter with a mark returns older..newer whichever row was marked first (<name>)' -TestCases @(
            @{ name = 'marked the newer row, then moved down'; keys = @('Down', 'Space', 'Down', 'Down', 'Down', 'Enter') }
            @{ name = 'marked the older row, then moved up';   keys = @('Down', 'Down', 'Down', 'Down', 'Space', 'Up', 'Up', 'Up', 'Enter') }
        ) {
            $map = @{ Down = $script:KDown; Up = $script:KUp; Space = $script:KSpace; Enter = $script:KEnter }
            Push-TestKeys @($keys | ForEach-Object { $map[$_] })
            $choice = Invoke-TestLoop $script:Model
            $choice.Kind | Should -Be 'Range'
            $choice.From | Should -Be $script:Rows[4].Sha      # the LOWER row: the older commit is the base
            $choice.To | Should -Be $script:Rows[1].Sha
            $choice.Commit | Should -BeNullOrEmpty
            $choice.Sha | Should -BeNullOrEmpty                # never routed down the single-commit path
            $choice.WorkingTree | Should -BeFalse
            # The frame before Enter: both ends visible, the mark on one, the header naming the OLDER row as the base.
            $before = $script:Frames[-1]
            $before.Lines[0] | Should -BeLike '*  base: r04____'
            @($before.Lines[1..5] | Where-Object { $_[1] -eq '*' }).Count | Should -Be 1
        }

        It 'Enter on the marked row itself does nothing: the picker stays open and the next keys still work' {
            Push-TestKeys @($script:KDown, $script:KSpace, $script:KEnter, $script:KUp, $script:KEnter)
            $choice = Invoke-TestLoop $script:Model
            @($script:Events) | Should -Be @('enter', 'draw', 'key', 'draw', 'key', 'draw', 'key', 'draw', 'key', 'draw', 'key', 'exit')
            # The no-op Enter redrew the same screen.
            ($script:Frames[3].Lines -join "`n") | Should -BeExactly ($script:Frames[2].Lines -join "`n")
            $script:Frames[3].Highlight | Should -Be $script:Frames[2].Highlight
            $choice.Kind | Should -Be 'Range'
            $choice.From | Should -Be $script:Rows[1].Sha
            $choice.To | Should -Be $script:Rows[0].Sha
        }

        It '<name> returns selected..HEAD (Kind Range, To HEAD), with or without a mark' -TestCases @(
            @{ name = 'h';                   keys = @('Down', 'Down', 'h') }
            @{ name = 'H';                   keys = @('Down', 'Down', 'H') }
            @{ name = 'h with a mark below'; keys = @('Down', 'Down', 'Down', 'Space', 'Up', 'h') }
        ) {
            $map = @{ Down = $script:KDown; Up = $script:KUp; Space = $script:KSpace }
            Push-TestKeys @($keys | ForEach-Object { if ($map.ContainsKey($_)) { $map[$_] } else { $_ } })
            $choice = Invoke-TestLoop $script:Model
            $choice.Kind | Should -Be 'Range'
            $choice.From | Should -Be $script:Rows[2].Sha
            $choice.To | Should -BeExactly 'HEAD'
            $choice.Sha | Should -BeNullOrEmpty
            $choice.WorkingTree | Should -BeFalse
            [object]::ReferenceEquals($choice.Row, $script:Rows[2]) | Should -BeTrue
        }

        It '<name> returns selected..the working tree (Kind WorkingTree), with or without a mark' -TestCases @(
            @{ name = 'w';                   keys = @('Down', 'Down', 'w') }
            @{ name = 'W';                   keys = @('Down', 'Down', 'W') }
            @{ name = 'w with a mark above'; keys = @('Space', 'Down', 'Down', 'w') }
        ) {
            $map = @{ Down = $script:KDown; Space = $script:KSpace }
            Push-TestKeys @($keys | ForEach-Object { if ($map.ContainsKey($_)) { $map[$_] } else { $_ } })
            $choice = Invoke-TestLoop $script:Model
            $choice.Kind | Should -Be 'WorkingTree'
            $choice.From | Should -Be $script:Rows[2].Sha
            $choice.To | Should -BeNullOrEmpty
            $choice.WorkingTree | Should -BeTrue
            $choice.Sha | Should -BeNullOrEmpty
            $choice.Commit | Should -BeNullOrEmpty
        }

        It 'emits the <name> choice downstream only after the screen is restored' -TestCases @(
            @{ name = 'range';        keys = @('Space', 'Down', 'Enter'); kind = 'Range' }
            @{ name = 'HEAD';         keys = @('Down', 'h');              kind = 'Range' }
            @{ name = 'working tree'; keys = @('Down', 'w');              kind = 'WorkingTree' }
        ) {
            $map = @{ Down = $script:KDown; Space = $script:KSpace; Enter = $script:KEnter }
            Push-TestKeys @($keys | ForEach-Object { if ($map.ContainsKey($_)) { $map[$_] } else { $_ } })
            $seen = InModuleScope og-framework -Parameters @{ M = $script:Model; E = $script:Events } {
                Select-OgPickerRow -Model $M | ForEach-Object { $E.Add('out'); $_ }
            }
            $script:Events[-2] | Should -Be 'exit'
            $script:Events[-1] | Should -Be 'out'
            @($script:Events | Where-Object { $_ -eq 'exit' }).Count | Should -Be 1
            $seen.Kind | Should -Be $kind
        }

        It 'keeps the detail line on the SELECTED row''s own cascade while another row is marked, and resolves nothing extra' {
            $resolver = { param($sha) $script:Calls.Add($sha); New-TestEntry -Repo ('repo' + $sha.Substring(3, 2)) }
            $model = New-TestModel -Rows $script:Rows -Resolver $resolver
            Push-TestKeys @($script:KSpace, $script:KDown, $script:KDown, $script:KEsc)
            $null = Invoke-TestLoop $model
            $script:Frames[-1].Lines[6] | Should -BeLike '  repos: repo02 *'
            $script:Frames[-1].Lines[0] | Should -BeLike '*  base: r02____'
            # Rows 0..4 once each (the viewport), as without a mark.
            @($script:Calls) | Should -Be @(0..4 | ForEach-Object { $script:Rows[$_].Sha })
        }
    }

    Context 'Scrolling at the edges (viewport of 5 rows)' {
        It 'scrolls by exactly one row when the selection passes the bottom edge, and back at the top edge' {
            $rows  = New-TestRows 12
            Push-TestKeys (@($script:KDown) * 5 + @($script:KUp) * 5 + @($script:KEnter))
            $null = Invoke-TestLoop (New-TestModel -Rows $rows)

            # Frame k: lines[0] is the header, lines[1..5] the viewport, lines[6] detail, lines[7] footer.
            $tops = @($script:Frames | ForEach-Object { $_.Lines[1].Substring(2, 7) })
            $sel  = @($script:Frames | ForEach-Object { $_.Lines[$_.Highlight].Substring(0, 9) })
            # Down 1..4 keep the top; the 5th Down puts row 5 on the LAST visible line (top row 1).
            $tops | Should -Be @('r00____', 'r00____', 'r00____', 'r00____', 'r00____', 'r01____',
                                 'r01____', 'r01____', 'r01____', 'r01____', 'r00____')
            $sel  | Should -Be @('> r00____', '> r01____', '> r02____', '> r03____', '> r04____', '> r05____',
                                 '> r04____', '> r03____', '> r02____', '> r01____', '> r00____')
            $script:Frames[5].Highlight | Should -Be 5
            $script:Frames[5].Lines[5] | Should -BeLike '> r05____*'
            $script:Frames[9].Highlight | Should -Be 1
            foreach ($f in $script:Frames) { $f.Lines.Count | Should -Be 8 }
        }

        It 'keeps the selection visible across a resize between keys' {
            $rows = New-TestRows 12
            $script:Sizes.Clear()
            foreach ($s in @(@(81, 8), @(81, 8), @(81, 4), @(41, 4), @(61, 20))) {
                $script:Sizes.Enqueue([PSCustomObject]@{ Width = $s[0]; Height = $s[1] })
            }
            Push-TestKeys @($script:KDown, $script:KDown, $script:KDown, $script:KDown, $script:KEnter)
            (Invoke-TestLoop (New-TestModel -Rows $rows)).Sha | Should -Be $rows[4].Sha

            @($script:Frames | ForEach-Object { $_.Lines.Count }) | Should -Be @(8, 8, 4, 4, 20)
            @($script:Frames | ForEach-Object { $_.Width }) | Should -Be @(80, 80, 80, 40, 60)
            for ($k = 0; $k -lt $script:Frames.Count; $k++) {
                $f = $script:Frames[$k]
                $f.Lines[$f.Highlight] | Should -BeLike ('> r{0:D2}____*' -f $k)
                foreach ($line in $f.Lines) { $line.Length | Should -BeLessOrEqual $f.Width }
            }
            # Height 20 (viewport 17) shows all 12 rows from the top again, then blank lines.
            $script:Frames[4].Lines[1] | Should -BeLike '  r00____*'
            $script:Frames[4].Lines[13] | Should -Be ''
        }
    }

    Context 'Lazy, cached touch resolution on a temp repo' {
        BeforeAll {
            $script:LazyRepo = New-TestDir 'lazy'
            Invoke-TestGit $script:LazyRepo init -q | Out-Null
            for ($i = 0; $i -lt 12; $i++) { Add-TestCommit -Dir $script:LazyRepo -Message "commit $i" }
        }

        It 'resolves only the visible rows, the selected one first, each sha once; ellipsis until resolved' {
            $rows = @(InModuleScope og-framework -Parameters @{ P = $script:LazyRepo } { Get-OgPickerRows -ProjectRoot $P })
            $rows.Count | Should -Be 12
            $resolver = { param($sha) $script:Calls.Add($sha); New-TestEntry -Repo 'lazy' }
            $model = New-TestModel -Rows $rows -Resolver $resolver

            Push-TestKeys @($script:KEnd, $script:KHome, $script:KEnter)
            (Invoke-TestLoop $model).Sha | Should -Be $rows[0].Sha

            # Start: rows 0..4 (0 is selected). End: row 11 first, then 7..10. Home: all cached, no call.
            $expected = @(0, 1, 2, 3, 4, 11, 7, 8, 9, 10 | ForEach-Object { $rows[$_].Sha })
            @($script:Calls) | Should -Be $expected
            $rows[5].Touched | Should -BeNullOrEmpty
            $rows[6].Touched | Should -BeNullOrEmpty
            $rows[0].Touched | Should -Be 'lazy'

            # The first frame shows every visible row unresolved; the frame before the first key shows them resolved.
            foreach ($line in $script:Frames[0].Lines[1..5]) { $line.Substring(29, 12) | Should -Be $script:Ell.PadRight(12) }
            $script:Frames[0].Lines[6] | Should -Be "  repos: $script:Ell"
            $firstKey = $script:Events.IndexOf('key')
            $drawsBeforeKey = @($script:Events.GetRange(0, $firstKey) | Where-Object { $_ -eq 'draw' }).Count
            $drawsBeforeKey | Should -Be 6      # the empty frame, then one redraw per resolved row
            foreach ($line in $script:Frames[5].Lines[1..5]) { $line.Substring(29, 12) | Should -Be 'lazy'.PadRight(12) }

            # Cached: a second loop over the same model calls the resolver for nothing it already has.
            $script:Calls.Clear()
            Push-TestKeys @($script:KEsc)
            $null = Invoke-TestLoop $model
            $script:Calls.Count | Should -Be 0
        }

        It 'answers a waiting key before resolving more rows' {
            $rows = New-TestRows 12
            $script:KeyWaiting = $true
            Push-TestKeys @($script:KEnter)
            $model = New-TestModel -Rows $rows -Resolver { param($sha) $script:Calls.Add($sha) }
            (Invoke-TestLoop $model).Sha | Should -Be $rows[0].Sha
            $script:Calls.Count | Should -Be 0
        }

        It 'a throwing resolver shows ! and the message, is called once per sha, and the picker still works' {
            $rows = New-TestRows 3
            $model = New-TestModel -Rows $rows -Resolver {
                param($sha)
                $script:Calls.Add($sha)
                if ($sha.StartsWith('sha01')) { throw 'pin commit not found' }
                New-TestEntry -Repo 'root'
            }
            Push-TestKeys @($script:KDown, $script:KUp, $script:KDown, $script:KEnter)
            (Invoke-TestLoop $model).Sha | Should -Be $rows[1].Sha
            @($script:Calls | Where-Object { $_ -eq $rows[1].Sha }).Count | Should -Be 1
            $rows[1].Touched | Should -Be '!'
            $rows[1].TouchError | Should -Be 'pin commit not found'
            $script:Frames[-1].Lines[6] | Should -Be '  repos: none touched; cannot resolve: pin commit not found'
        }

        It 'discards what a resolver prints, and uses a custom summary scriptblock' {
            $rows = New-TestRows 2
            $model = New-TestModel -Rows $rows -Resolver {
                param($sha)
                Write-Warning 'noisy resolver'
                Write-Information 'noisy info'
                New-TestEntry -Repo 'root'; New-TestEntry -Repo 'sub'
            } -Summary { param($entries) "n=$(@($entries).Count)" }
            Push-TestKeys @($script:KEnter)
            $out = @(InModuleScope og-framework -Parameters @{ M = $model } { Select-OgPickerRow -Model $M 3>&1 6>&1 })
            @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -or
                                    $_ -is [System.Management.Automation.InformationRecord] }).Count | Should -Be 0
            $rows[0].Touched | Should -Be 'n=2'
        }
    }

    Context 'Console contract' {
        It 'throws an error naming oggitdiff -Commit with redirected input, before touching the screen' {
            $script:Capability.InputRedirected = $true
            Push-TestKeys @($script:KEnter)
            { Invoke-TestLoop (New-TestModel -Rows (New-TestRows 3)) } |
                Should -Throw '*input is redirected*oggitdiff -Commit <sha>*'
            Should -Invoke Enter-OgPickerScreen -ModuleName og-framework -Times 0 -Exactly
            Should -Invoke Read-OgPickerKey -ModuleName og-framework -Times 0 -Exactly
        }

        It 'also refuses redirected output and a host without VT support' -TestCases @(
            @{ Field = 'OutputRedirected'; Value = $true;  Why = '*output is redirected*oggitdiff -Commit*' }
            @{ Field = 'VirtualTerminal';  Value = $false; Why = '*virtual terminal*oggitdiff -Commit*' }
        ) {
            $script:Capability.$Field = $Value
            { Invoke-TestLoop (New-TestModel -Rows (New-TestRows 3)) } | Should -Throw $Why
            Should -Invoke Enter-OgPickerScreen -ModuleName og-framework -Times 0 -Exactly
        }

        It 'restores the screen when a key read throws' {
            Mock Read-OgPickerKey -ModuleName og-framework { $script:Events.Add('key'); throw 'console went away' }
            { Invoke-TestLoop (New-TestModel -Rows (New-TestRows 3)) } | Should -Throw '*console went away*'
            @($script:Events) | Should -Be @('enter', 'draw', 'key', 'exit')
            Should -Invoke Exit-OgPickerScreen -ModuleName og-framework -Times 1 -Exactly
        }

        It 'returns nothing and never enters the screen for an empty row list' {
            Invoke-TestLoop (New-TestModel -Rows @()) | Should -BeNullOrEmpty
            Should -Invoke Enter-OgPickerScreen -ModuleName og-framework -Times 0 -Exactly
        }
    }

    Context 'Invoke-OgDiffPicker, the dry-run entry point' {
        It 'lists the temp repo, returns the picked row, launches nothing and changes nothing' {
            Mock Start-OgDiffToolProcess -ModuleName og-framework { throw 'must not launch' }
            $repo = New-TestDir 'dry'
            Invoke-TestGit $repo init -q | Out-Null
            Add-TestCommit -Dir $repo -Message 'older'
            Add-TestCommit -Dir $repo -Message 'newer'
            $before = Get-TestRepoFingerprint $repo

            Push-TestKeys @($script:KDown, $script:KEnter)
            # The resolver is created HERE, not inside InModuleScope: a scriptblock literal written in the module
            # scope is bound to the module and cannot see this file's New-TestEntry.
            $resolver = { param($sha) New-TestEntry -Repo 'dry' -HeadRev $sha }
            $picked = InModuleScope og-framework -Parameters @{ P = $repo; V = $resolver } {
                Invoke-OgDiffPicker -ProjectRoot $P -Count 5 -TouchResolver $V
            }
            # od task 11a: the picker returns an Og.PickerChoice; the row is its Row (Subject and Entries moved there).
            $picked.Kind | Should -Be 'Commit'
            $picked.Row.Subject | Should -Be 'older'
            $picked.Sha | Should -Be (Invoke-TestGit $repo rev-parse HEAD~1)
            $picked.Commit | Should -Be $picked.Sha
            $picked.Row.Entries[0].HeadRev | Should -Be $picked.Sha
            $script:Frames[0].Lines[0] | Should -Be "Pick a commit: $(Split-Path $repo -Leaf)  (1/2)"
            Should -Invoke Start-OgDiffToolProcess -ModuleName og-framework -Times 0 -Exactly
            Get-TestRepoFingerprint $repo | Should -Be $before
        }

        It 'returns a range of the temp repo''s real commits: mark the newer, move to the older, Enter (od task 11a)' {
            Mock Start-OgDiffToolProcess -ModuleName og-framework { throw 'must not launch' }
            $repo = New-TestDir 'dryrange'
            Invoke-TestGit $repo init -q | Out-Null
            Add-TestCommit -Dir $repo -Message 'first'
            Add-TestCommit -Dir $repo -Message 'second'
            Add-TestCommit -Dir $repo -Message 'third'
            $before = Get-TestRepoFingerprint $repo

            Push-TestKeys @([System.ConsoleKey]::Spacebar, $script:KDown, $script:KDown, $script:KEnter)
            $choice = InModuleScope og-framework -Parameters @{ P = $repo } { Invoke-OgDiffPicker -ProjectRoot $P }
            $choice.Kind | Should -Be 'Range'
            $choice.From | Should -Be (Invoke-TestGit $repo rev-parse HEAD~2)
            $choice.To | Should -Be (Invoke-TestGit $repo rev-parse HEAD)
            $choice.Row.Subject | Should -Be 'first'
            $short = (Invoke-TestGit $repo rev-parse --short HEAD~2)
            $script:Frames[-1].Lines[0] | Should -Be "Pick a commit: $(Split-Path $repo -Leaf)  (3/3)  base: $short"
            Should -Invoke Start-OgDiffToolProcess -ModuleName og-framework -Times 0 -Exactly
            Get-TestRepoFingerprint $repo | Should -Be $before
        }

        It 'fails on redirected input before running any git command' {
            Mock Get-OgPickerRows -ModuleName og-framework { throw 'must not list' }
            $script:Capability.InputRedirected = $true
            { InModuleScope og-framework -Parameters @{ P = $TestDrive } { Invoke-OgDiffPicker -ProjectRoot $P } } |
                Should -Throw '*oggitdiff -Commit <sha>*'
            Should -Invoke Get-OgPickerRows -ModuleName og-framework -Times 0 -Exactly
        }
    }
}

Describe 'The pure renderer (Format-OgPickerScreen)' {
    BeforeAll {
        $script:R = New-TestRows 5
        $script:R[0].Touched = 'root +2'
        $script:R[0].Entries = @(
            New-TestEntry -Repo 'proj' -BaseRev ('1' * 40) -HeadRev ('2' * 40)
            New-TestEntry -Repo 'og-sim' -BaseRev '' -HeadRev ('3' * 40) -Status 'added'
            New-TestEntry -Repo 'old' -BaseRev ('4' * 40) -HeadRev '' -Status 'removed'
            New-TestEntry -Repo 'lib' -BaseRev ('5' * 40) -HeadRev ('6' * 40) -Status 'missing-commit' -ErrorText 'not here'
        )
        $script:R[1].Subject = 'a much longer subject line that cannot fit into a narrow window at all'
    }

    It 'renders header, rows with the selection marker, detail and footer, exactly Height lines' {
        $lines = Invoke-TestRender -Rows $script:R -Selected 0 -Top 0 -Width 200 -Height 9
        $lines.Count | Should -Be 9
        $lines[0] | Should -BeExactly 'Pick a commit: proj  (1/5)'
        $lines[1] | Should -BeExactly ('> r00____  2026-10-22 21:00  ' + 'root +2'.PadRight(12) + '  subject 0')
        $lines[2] | Should -BeExactly ('  r01____  2026-10-22 21:01  ' + $script:Ell.PadRight(12) + '  ' + $script:R[1].Subject)
        @($lines[1..5] | Where-Object { $_.StartsWith('> ') }).Count | Should -Be 1
        $lines[6] | Should -BeExactly ''    # viewport line 6 of 6: past the 5th row
        $lines[7] | Should -BeExactly ('  repos: proj 1111111..2222222, og-sim 0000000..3333333 (added), ' +
                                       'old 4444444..0000000 (removed), lib (missing-commit)')
        # od task 11a: the footer lists the range keys (it was 'Up/Down PgUp/PgDn Home/End: move   Enter: open   Esc/q: cancel').
        $lines[8] | Should -BeExactly 'Space: mark  Enter: open  h: vs HEAD  w: vs working tree  Esc/q: cancel'
    }

    It 'moves the marker with the selection and shows the unresolved detail as an ellipsis' {
        $lines = Invoke-TestRender -Rows $script:R -Selected 3 -Top 0 -Width 200 -Height 9
        $lines[0] | Should -BeExactly 'Pick a commit: proj  (4/5)'
        $lines[4] | Should -BeLike '> r03____*'
        @($lines[1..5] | Where-Object { $_.StartsWith('> ') }).Count | Should -Be 1
        $lines[7] | Should -BeExactly "  repos: $script:Ell"
    }

    It 'truncates the subject with an ellipsis to the exact width' {
        $lines = Invoke-TestRender -Rows $script:R -Selected 1 -Top 0 -Width 60 -Height 9
        $prefix = '> r01____  2026-10-22 21:01  ' + $script:Ell.PadRight(12) + '  '
        $lines[2] | Should -BeExactly ($prefix + $script:R[1].Subject.Substring(0, 60 - $prefix.Length - 1) + $script:Ell)
        $lines[2].Length | Should -Be 60
        $lines[1] | Should -BeExactly ('  r00____  2026-10-22 21:00  ' + 'root +2'.PadRight(12) + '  subject 0')
    }

    It 'never returns a line longer than the width, for every width from 1 to 90' {
        for ($w = 1; $w -le 90; $w++) {
            $lines = Invoke-TestRender -Rows $script:R -Selected 0 -Top 0 -Width $w -Height 9
            foreach ($l in $lines) { $l.Length | Should -BeLessOrEqual $w }
        }
    }

    It 'shows the rows from Top and blank lines past the last row' {
        $lines = Invoke-TestRender -Rows $script:R -Selected 4 -Top 3 -Width 200 -Height 8
        $lines[1] | Should -BeLike '  r03____*'
        $lines[2] | Should -BeLike '> r04____*'
        $lines[3] | Should -Be ''
        $lines[5] | Should -Be ''
    }

    It 'drops the footer, then the header, then the detail line in short windows' -TestCases @(
        @{ H = 4; First = 'Pick*';     Last = 'Space: mark*' }      # od task 11a: was 'Up/Down*' (the footer's text)
        @{ H = 3; First = 'Pick*';     Last = '  repos:*' }
        @{ H = 2; First = '> r00*';    Last = '  repos:*' }
        @{ H = 1; First = '> r00*';    Last = '> r00*' }
    ) {
        $lines = Invoke-TestRender -Rows $script:R -Selected 0 -Top 0 -Width 100 -Height $H
        $lines.Count | Should -Be $H
        $lines[0] | Should -BeLike $First
        $lines[-1] | Should -BeLike $Last
    }

    It 'replaces control characters in a subject (no tab, no escape sequence reaches the terminal)' {
        $rows = New-TestRows 1
        $rows[0].Subject = "tab`there esc$([char] 27)[31mred"
        $lines = Invoke-TestRender -Rows $rows -Selected 0 -Top 0 -Width 200 -Height 4
        $lines[1].EndsWith('tab here esc [31mred') | Should -BeTrue
        $lines[1] | Should -Not -Match '\p{Cc}'
    }

    It 'shows a resolved commit that touched nothing as none touched' {
        $rows = New-TestRows 1
        $rows[0].Touched = '-'; $rows[0].Entries = @()
        (Invoke-TestRender -Rows $rows -Selected 0 -Top 0 -Width 200 -Height 4)[2] | Should -BeExactly '  repos: none touched'
    }

    # od task 11a: the mark column and the header's base.
    It 'marks the marked row with * in the second marker column, keeping every other column where it was' {
        $lines = [string[]] @(InModuleScope og-framework -Parameters @{ R = $script:R } {
            Format-OgPickerScreen -Rows $R -Selected 0 -Top 0 -Width 200 -Height 9 -Title 'proj' -Marked 2
        })
        $lines[1] | Should -BeExactly ('> r00____  2026-10-22 21:00  ' + 'root +2'.PadRight(12) + '  subject 0')
        $lines[3] | Should -BeExactly (' *r02____  2026-10-22 21:02  ' + $script:Ell.PadRight(12) + '  subject 2')
        $lines[3].Substring(29, 12) | Should -Be $script:Ell.PadRight(12)     # the touched column's offset is unchanged
        $lines[2] | Should -BeLike '  r01____*'
        $lines[0] | Should -BeExactly 'Pick a commit: proj  (1/5)  base: r02____'
        # The detail line is the SELECTED row's, not the marked one's.
        $lines[7] | Should -BeLike '  repos: proj 1111111..2222222, *'
    }

    It 'shows both markers on a selected marked row' {
        $lines = [string[]] @(InModuleScope og-framework -Parameters @{ R = $script:R } {
            Format-OgPickerScreen -Rows $R -Selected 3 -Top 0 -Width 200 -Height 9 -Title 'proj' -Marked 3
        })
        $lines[4] | Should -BeLike '>*r03____  2026-10-22 21:03  *'
        @($lines[1..5] | Where-Object { $_[1] -eq '*' }).Count | Should -Be 1
        @($lines[1..5] | Where-Object { $_[0] -eq '>' }).Count | Should -Be 1
        $lines[0] | Should -BeExactly 'Pick a commit: proj  (4/5)  base: r03____'
    }

    It 'names the base Enter would use: the older (lower) of the marked and the selected row (selected <s>, marked <m>)' -TestCases @(
        @{ s = 0; m = 3; base = 'r03____' }     # marked below the selection: the mark is the base
        @{ s = 4; m = 1; base = 'r04____' }     # selection below the mark: the SELECTED row is the base
        @{ s = 2; m = 2; base = 'r02____' }     # on the mark
    ) {
        $lines = [string[]] @(InModuleScope og-framework -Parameters @{ R = $script:R; S = $s; M = $m } {
            Format-OgPickerScreen -Rows $R -Selected $S -Top 0 -Width 200 -Height 9 -Title 'proj' -Marked $M
        })
        $lines[0] | Should -BeExactly "Pick a commit: proj  ($($s + 1)/5)  base: $base"
    }

    It 'shows no base and no * without a mark (-Marked -1, the default, or out of range)' -TestCases @(
        @{ m = -1 }, @{ m = 5 }
    ) {
        $lines = [string[]] @(InModuleScope og-framework -Parameters @{ R = $script:R; M = $m } {
            Format-OgPickerScreen -Rows $R -Selected 0 -Top 0 -Width 200 -Height 9 -Title 'proj' -Marked $M
        })
        $lines[0] | Should -BeExactly 'Pick a commit: proj  (1/5)'
        @($lines[1..5] | Where-Object { $_.Length -gt 1 -and $_[1] -eq '*' }).Count | Should -Be 0
    }

    It 'never returns a line longer than the width with a mark, for every width from 1 to 90' {
        for ($w = 1; $w -le 90; $w++) {
            $lines = [string[]] @(InModuleScope og-framework -Parameters @{ R = $script:R; W = $w } {
                Format-OgPickerScreen -Rows $R -Selected 1 -Top 0 -Width $W -Height 9 -Title 'proj' -Marked 3
            })
            foreach ($l in $lines) { $l.Length | Should -BeLessOrEqual $w }
        }
    }

    It 'the footer at width <w> is "<e>"' -TestCases @(
        @{ w = 200; e = 'Space: mark  Enter: open  h: vs HEAD  w: vs working tree  Esc/q: cancel' }
        @{ w = 71;  e = 'Space: mark  Enter: open  h: vs HEAD  w: vs working tree  Esc/q: cancel' }
        @{ w = 70;  e = 'Space:mark Enter:open h:HEAD w:worktree Esc/q:cancel' }
        @{ w = 52;  e = 'Space:mark Enter:open h:HEAD w:worktree Esc/q:cancel' }
        @{ w = 30;  e = "Space:mark Enter:open h:HEAD $([char] 0x2026)" }
    ) {
        (Invoke-TestRender -Rows $script:R -Selected 0 -Top 0 -Width $w -Height 9)[8] | Should -BeExactly $e
    }
}

Describe 'The pure helpers' {
    It 'Get-OgPickerScrollTop(selected <s>, top <t>, viewport <v>, count <c>) is <e>' -TestCases @(
        @{ s = 0;  t = 0; v = 5;  c = 12; e = 0 }
        @{ s = 4;  t = 0; v = 5;  c = 12; e = 0 }    # last visible line: no scroll
        @{ s = 5;  t = 0; v = 5;  c = 12; e = 1 }    # one past the bottom edge: scroll by exactly one
        @{ s = 11; t = 0; v = 5;  c = 12; e = 7 }    # End
        @{ s = 3;  t = 4; v = 5;  c = 12; e = 3 }    # one past the top edge
        @{ s = 6;  t = 4; v = 5;  c = 12; e = 4 }    # inside: unchanged
        @{ s = 11; t = 7; v = 10; c = 12; e = 2 }    # window grew: no blank lines while rows are hidden above
        @{ s = 2;  t = 7; v = 10; c = 12; e = 2 }
        @{ s = 2;  t = 1; v = 20; c = 12; e = 0 }    # everything fits
    ) {
        InModuleScope og-framework -Parameters @{ S = $s; T = $t; V = $v; C = $c } {
            Get-OgPickerScrollTop -Selected $S -Top $T -ViewportHeight $V -Count $C
        } | Should -Be $e
    }

    It 'Get-OgPickerKeyAction maps <name> to <action>' -TestCases @(
        @{ name = 'Up';     key = [System.ConsoleKey]::UpArrow;   char = [char] 0;   action = 'Up' }
        @{ name = 'Down';   key = [System.ConsoleKey]::DownArrow; char = [char] 0;   action = 'Down' }
        @{ name = 'PgUp';   key = [System.ConsoleKey]::PageUp;    char = [char] 0;   action = 'PageUp' }
        @{ name = 'PgDn';   key = [System.ConsoleKey]::PageDown;  char = [char] 0;   action = 'PageDown' }
        @{ name = 'Home';   key = [System.ConsoleKey]::Home;      char = [char] 0;   action = 'Home' }
        @{ name = 'End';    key = [System.ConsoleKey]::End;       char = [char] 0;   action = 'End' }
        @{ name = 'Enter';  key = [System.ConsoleKey]::Enter;     char = [char] 13;  action = 'Pick' }
        @{ name = 'Esc';    key = [System.ConsoleKey]::Escape;    char = [char] 27;  action = 'Cancel' }
        @{ name = 'q';      key = [System.ConsoleKey]::Q;         char = [char] 'q'; action = 'Cancel' }
        @{ name = 'x';      key = [System.ConsoleKey]::X;         char = [char] 'x'; action = 'None' }
        @{ name = 'Space';  key = [System.ConsoleKey]::Spacebar;  char = [char] ' '; action = 'Mark' }
        @{ name = 'h';      key = [System.ConsoleKey]::H;         char = [char] 'h'; action = 'VsHead' }
        @{ name = 'H';      key = [System.ConsoleKey]::H;         char = [char] 'H'; action = 'VsHead' }
        @{ name = 'w';      key = [System.ConsoleKey]::W;         char = [char] 'w'; action = 'VsWorkingTree' }
        @{ name = 'W';      key = [System.ConsoleKey]::W;         char = [char] 'W'; action = 'VsWorkingTree' }
    ) {
        $k = New-TestKey $key $char
        InModuleScope og-framework -Parameters @{ K = $k } { Get-OgPickerKeyAction -Key $K } | Should -Be $action
    }

    # od task 11a: the pure choice rule. Rows are newest first: a higher index is an older commit.
    It 'Get-OgPickerChoice(<a>, selected <s>, marked <m>) is <kind> <from>..<to>' -TestCases @(
        @{ a = 'Pick';          s = 2; m = -1; kind = 'Commit';      commit = 2;  from = $null; to = $null }
        @{ a = 'Pick';          s = 1; m = 4;  kind = 'Range';       commit = $null; from = 4; to = 1 }
        @{ a = 'Pick';          s = 4; m = 1;  kind = 'Range';       commit = $null; from = 4; to = 1 }
        @{ a = 'Pick';          s = 0; m = 11; kind = 'Range';       commit = $null; from = 11; to = 0 }
        @{ a = 'Pick';          s = 3; m = 3;  kind = $null;         commit = $null; from = $null; to = $null }
        @{ a = 'VsHead';        s = 3; m = -1; kind = 'Range';       commit = $null; from = 3; to = 'HEAD' }
        @{ a = 'VsHead';        s = 3; m = 7;  kind = 'Range';       commit = $null; from = 3; to = 'HEAD' }
        @{ a = 'VsWorkingTree'; s = 5; m = -1; kind = 'WorkingTree'; commit = $null; from = 5; to = $null }
        @{ a = 'VsWorkingTree'; s = 5; m = 0;  kind = 'WorkingTree'; commit = $null; from = 5; to = $null }
        @{ a = 'Down';          s = 5; m = 0;  kind = $null;         commit = $null; from = $null; to = $null }
        @{ a = 'Mark';          s = 5; m = -1; kind = $null;         commit = $null; from = $null; to = $null }
    ) {
        $rows = New-TestRows 12
        $choice = InModuleScope og-framework -Parameters @{ R = $rows; A = $a; S = $s; M = $m } {
            Get-OgPickerChoice -Rows $R -Action $A -Selected $S -Marked $M
        }
        if ($null -eq $kind) { $choice | Should -BeNullOrEmpty; return }
        $sha = { param($v) if ($null -eq $v) { $null } elseif ($v -is [string]) { $v } else { $rows[$v].Sha } }
        $choice.PSObject.TypeNames[0] | Should -Be 'Og.PickerChoice'
        $choice.Kind | Should -Be $kind
        $choice.Commit | Should -Be (& $sha $commit)
        $choice.Sha | Should -Be (& $sha $commit)
        $choice.From | Should -Be (& $sha $from)
        $choice.To | Should -Be (& $sha $to)
        $choice.WorkingTree | Should -Be ($kind -eq 'WorkingTree')
        [object]::ReferenceEquals($choice.Row, $rows[$s]) | Should -BeTrue
    }

    It 'ConvertTo-OgPickerFitted("<text>", <w>) is "<e>"' -TestCases @(
        @{ text = 'abcdef'; w = 6; e = 'abcdef' }
        @{ text = 'abcdef'; w = 5; e = "abcd$([char] 0x2026)" }
        @{ text = 'abcdef'; w = 1; e = "$([char] 0x2026)" }
        @{ text = 'abcdef'; w = 0; e = '' }
        @{ text = '';       w = 3; e = '' }
    ) {
        InModuleScope og-framework -Parameters @{ T = $text; W = $w } { ConvertTo-OgPickerFitted $T $W } | Should -BeExactly $e
    }

    It 'Format-OgPickerTouchSummary: none, one, several, missing-commit' {
        InModuleScope og-framework -Parameters @{ E = @() } { Format-OgPickerTouchSummary -Entries $E } | Should -Be '-'
        $one = @(New-TestEntry -Repo 'root')
        InModuleScope og-framework -Parameters @{ E = $one } { Format-OgPickerTouchSummary -Entries $E } | Should -Be 'root'
        $four = @((New-TestEntry -Repo 'root'), (New-TestEntry -Repo 'a'), (New-TestEntry -Repo 'b'), (New-TestEntry -Repo 'c'))
        InModuleScope og-framework -Parameters @{ E = $four } { Format-OgPickerTouchSummary -Entries $E } | Should -Be 'root +3'
        $missing = @((New-TestEntry -Repo 'root'), (New-TestEntry -Repo 'a' -Status 'missing-commit'))
        InModuleScope og-framework -Parameters @{ E = $missing } { Format-OgPickerTouchSummary -Entries $E } | Should -Be '!root +1'
    }

    It 'Format-OgPickerFrame positions every line absolutely and highlights the selected one' {
        $e = [char] 27
        $frame = InModuleScope og-framework { Format-OgPickerFrame -Lines @('ab', 'cd', '') -Highlight 1 -Width 6 }
        $frame | Should -BeExactly "$e[1;1Hab$e[K$e[2;1H$e[7mcd    $e[27m$e[K$e[3;1H$e[K$e[0m$e[J"
        $frame | Should -Not -Match "`n"
    }

    It 'Get-OgPickerNextSelection clamps every move' -TestCases @(
        @{ a = 'Up';       s = 0;  e = 0 }
        @{ a = 'Down';     s = 11; e = 11 }
        @{ a = 'PageDown'; s = 9;  e = 11 }
        @{ a = 'PageUp';   s = 3;  e = 0 }
        @{ a = 'PageUp';   s = 8;  e = 3 }
        @{ a = 'End';      s = 2;  e = 11 }
        @{ a = 'Home';     s = 9;  e = 0 }
        @{ a = 'None';     s = 6;  e = 6 }
    ) {
        InModuleScope og-framework -Parameters @{ A = $a; S = $s } {
            Get-OgPickerNextSelection -Action $A -Selected $S -ViewportHeight 5 -Count 12
        } | Should -Be $e
    }
}

Describe 'The console seams'' own bodies (dot-sourced, outside the module mocks)' {
    BeforeAll {
        . $script:SourceFile
    }

    It 'Get-OgPickerConsoleCapability reports three booleans' {
        $cap = Get-OgPickerConsoleCapability
        $cap.InputRedirected | Should -BeOfType [bool]
        $cap.OutputRedirected | Should -BeOfType [bool]
        $cap.VirtualTerminal | Should -BeOfType [bool]
    }

    It 'Get-OgPickerWindowSize reports a positive size' {
        $size = Get-OgPickerWindowSize
        $size.Width | Should -BeGreaterThan 0
        $size.Height | Should -BeGreaterThan 0
    }
}
