# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force

    # Runs git in a working dir, returns raw stdout (throws on failure) — test harness only.
    function git-in {
        param([string] $Dir, [Parameter(ValueFromRemainingArguments)] [string[]] $Args)
        $out = & git -C $Dir @Args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($Args -join ' ') failed in ${Dir}: $out" }
        ($out | Out-String).Trim()
    }

    # Creates a throwaway single git repo on 'main' (or -Branch) with one commit. Returns its path.
    function New-TestGitRepo {
        param([string] $Branch = 'main')
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ogdiff-" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        git-in $dir init -b $Branch | Out-Null
        git-in $dir config user.email 'test@example.com' | Out-Null
        git-in $dir config user.name  'Test' | Out-Null
        git-in $dir config commit.gpgsign false | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'file.txt') -Value "base`n" -NoNewline
        git-in $dir add . | Out-Null
        git-in $dir commit -m 'initial' | Out-Null
        $dir
    }

    # od task 3: the default mode now resolves a diff tool and launches it. Sandbox git's global config
    # (no user diff.tool can be picked up) and configure a fake tool there; the Describe's BeforeEach
    # mocks every launch, so no test ever starts a process.
    . "$PSScriptRoot\OgGitTestHelpers.ps1"
    Enter-OgGitSandbox -Root (Join-Path $TestDrive 'sandbox')
    Invoke-TestGit $TestDrive config --global diff.tool captest | Out-Null
    Invoke-TestGit $TestDrive config --global difftool.captest.cmd '"C:\Tools\FakeTool.exe" "$LOCAL" "$REMOTE"' | Out-Null
}

AfterAll {
    Exit-OgGitSandbox
}

Describe 'Show-OgDiff' {

    # NOTHING LAUNCHES A TOOL: every test runs with the launch, the process probe and the sleep mocked,
    # and every run folder goes under $TestDrive (never the user's real temp\og-diff). A test may mock
    # Start-OgDiffToolProcess again to capture more; its own mock wins.
    BeforeEach {
        $script:Launches = [System.Collections.Generic.List[string]]::new()
        $script:RunRoot  = Join-Path (New-TestDir 'tmp') 'og-diff'
        Mock -ModuleName og-framework Start-OgDiffToolProcess {
            $script:Launches.Add($CommandLine)
            [PSCustomObject]@{ Launched = $true; ExitCode = $null; Detail = $null }
        }
        Mock -ModuleName og-framework Test-OgDiffToolProcessRunning { $true }
        Mock -ModuleName og-framework Start-OgDiffSleep { }
        Mock -ModuleName og-framework Get-OgDiffRunRoot { $script:RunRoot }
    }

    Context 'Regression: -Against absent behaves exactly as before' {
        It 'reports clean on an untouched repo (no mocking needed — difftool never invoked)' {
            $repo = New-TestGitRepo
            try {
                $r = Show-OgDiff -ProjectRoot $repo
                $r.Action | Should -Be 'clean'
                $r.Ref    | Should -BeNullOrEmpty
                $r.Range  | Should -BeNullOrEmpty
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It 'an unstaged edit is invisible to -Staged (staged mode sees only the index)' {
            $repo = New-TestGitRepo
            try {
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "dirty`n" -NoNewline
                $r = Show-OgDiff -ProjectRoot $repo -Staged
                $r.Action | Should -Be 'clean'   # nothing staged, even though the tree is dirty
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It '-DirDiff is now a no-op: the default directory diff opens, and git difftool (--dir-diff) is never run' {
            # od task 3 adaptation: -DirDiff used to delegate to `git difftool --dir-diff`; directory
            # diffs are now the default and git's --dir-diff is never used (its temp dirs vanish).
            $repo = New-TestGitRepo
            try {
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "dirty`n" -NoNewline

                Mock -ModuleName og-framework -CommandName Invoke-Git `
                    -ParameterFilter { $Arguments -contains 'difftool' } `
                    -MockWith { throw 'git difftool must never be invoked for -DirDiff' }

                $r = Show-OgDiff -ProjectRoot $repo -DirDiff
                $r.Action   | Should -Be 'opened'
                $r.BasePath | Should -Not -BeNullOrEmpty
                $r.HeadPath | Should -Not -BeNullOrEmpty
                $script:Launches.Count | Should -Be 1
                Should -Invoke -ModuleName og-framework -CommandName Invoke-Git -Times 0 `
                    -ParameterFilter { $Arguments -contains 'difftool' }
            } finally { Remove-Item -Recurse -Force $repo }
        }
    }

    Context 'Parameter sets' {
        It 'rejects -Against combined with -Staged at parameter-binding time' {
            $repo = New-TestGitRepo
            try {
                { Show-OgDiff -ProjectRoot $repo -Against main -Staged } | Should -Throw
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It 'rejects -Fetch combined with -Staged (Fetch belongs to the Against parameter set)' {
            $repo = New-TestGitRepo
            try {
                { Show-OgDiff -ProjectRoot $repo -Fetch -Staged } | Should -Throw
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It '-Fetch works alongside -Against without throwing (fetch failure in a remote-less temp repo is a soft warning)' {
            $repo = New-TestGitRepo
            try {
                $r = Show-OgDiff -ProjectRoot $repo -Against main -Fetch -WarningAction SilentlyContinue
                $r.Action | Should -Be 'clean'   # HEAD == main, self-compare
            } finally { Remove-Item -Recurse -Force $repo }
        }
    }

    Context 'THE THREE-DOT TEST — proves <ref>...HEAD, not <ref>..HEAD' {
        It 'succeeds: reports clean when the branch itself added nothing, even though main advanced after the branch point' {
            # main advances with main-only.txt AFTER feat branches off; feat makes no new commits
            # (feat == merge-base). Three-dot (main...HEAD) => clean. A two-dot (main..HEAD)
            # implementation would report this DIRTY (main's tip now differs from feat's tip),
            # which is exactly the false positive this feature must not produce.
            $repo = New-TestGitRepo
            try {
                git-in $repo checkout -b feat | Out-Null
                git-in $repo checkout main | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'main-only.txt') -Value "main`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'main-only change' | Out-Null
                git-in $repo checkout feat | Out-Null

                # Oracle: confirm via git itself that the three-dot range is genuinely empty.
                & git -C $repo diff --quiet main...HEAD
                $LASTEXITCODE | Should -Be 0

                $r = Show-OgDiff -ProjectRoot $repo -Against main
                $r.Action | Should -Be 'clean'
                $r.Range  | Should -Be 'main...HEAD'
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It 'succeeds: reports the branch''s own change and uses main...HEAD (three dots) even though main also advanced independently' {
            # feat adds feat-only.txt; main independently advances with main-only.txt. The three-dot
            # range must surface ONLY feat's change (verified against git directly as an oracle) and
            # Show-OgDiff must pass that exact range string through.
            $repo = New-TestGitRepo
            try {
                git-in $repo checkout -b feat | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'feat-only.txt') -Value "feat`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'feat-only change' | Out-Null

                git-in $repo checkout main | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'main-only.txt') -Value "main`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'main-only change' | Out-Null

                git-in $repo checkout feat | Out-Null

                # Oracle: the three-dot content is exactly feat's own change, never main's.
                $changed = git-in $repo diff --name-only main...HEAD
                $changed | Should -Be 'feat-only.txt'
                $changed | Should -Not -Match 'main-only.txt'

                Mock -ModuleName og-framework -CommandName Invoke-Git `
                    -ParameterFilter { $Arguments -contains 'difftool' } `
                    -MockWith {
                        $script:capturedArgs = $Arguments
                        [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
                    }

                # od task 3: this asserts the git difftool arguments, so it runs under -PerFile.
                $r = Show-OgDiff -ProjectRoot $repo -Against main -PerFile
                $r.Action | Should -Be 'opened'
                $r.Range  | Should -Be 'main...HEAD'
                $script:capturedArgs | Should -Be @('difftool', '--no-prompt', 'main...HEAD')
                # Guard against a two-dot regression slipping in disguised as the right string:
                $script:capturedArgs | Should -Not -Contain 'main..HEAD'
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It 'succeeds with -DirDiff too: same three-dot range, but item 2''s export path (not git difftool) opens it' {
            # Same branch shape as above, this time with -DirDiff -- item 2 retargets this exact
            # combination away from `git difftool --dir-diff`, so this case is re-expressed against
            # the export mechanism rather than a mocked difftool call (see the dedicated "Item 2"
            # context below for the full persistence / merge-base proofs).
            $repo = New-TestGitRepo
            try {
                git-in $repo checkout -b feat | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'feat-only.txt') -Value "feat`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'feat-only change' | Out-Null

                git-in $repo checkout main | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'main-only.txt') -Value "main`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'main-only change' | Out-Null

                git-in $repo checkout feat | Out-Null

                git-in $repo config diff.tool captest | Out-Null
                git-in $repo config difftool.captest.cmd '"C:\Tools\FakeTool.exe" "$LOCAL" "$REMOTE"' | Out-Null

                Mock -ModuleName og-framework -CommandName Invoke-Git `
                    -ParameterFilter { $Arguments -contains 'difftool' } `
                    -MockWith { throw 'git difftool must never be invoked for -Against -DirDiff (item 2)' }
                Mock -ModuleName og-framework -CommandName Start-OgDiffToolProcess -MockWith {
                    $script:capturedCommandLine = $CommandLine
                }

                $r = Show-OgDiff -ProjectRoot $repo -Against main -DirDiff
                $r.Action | Should -Be 'opened'
                $r.Range  | Should -Be 'main...HEAD'
                $script:capturedCommandLine | Should -Match ([regex]::Escape($r.BasePath))
                $script:capturedCommandLine | Should -Match ([regex]::Escape($r.HeadPath))
            } finally {
                Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue
                Remove-Item -Recurse -Force (Join-Path $env:TEMP (Join-Path 'og-diff' (Split-Path $repo -Leaf))) -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'no-ref: a repo lacking the ref reports no-ref and the sweep continues' {
        It 'reports no-ref (not an error) when the ref cannot be resolved in a single repo' {
            $repo = New-TestGitRepo
            try {
                $r = Show-OgDiff -ProjectRoot $repo -Against origin/main   # no remote configured
                $r.Action | Should -Be 'no-ref'
                $r.Ref    | Should -Be 'origin/main'
                $r.Range  | Should -BeNullOrEmpty
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It 'a repo without the ref does not abort the sweep — the remaining repo in the tree is still evaluated' {
            # Parent repo tree discovery is purely textual (.gitmodules + filesystem), so a
            # throwaway nested repo wired up via .gitmodules is enough to build a real 2-repo tree
            # without touching any project repo or running `git submodule add`.
            $parent = New-TestGitRepo -Branch main
            try {
                $childPath = Join-Path $parent 'child'
                git-in $parent config -f (Join-Path $parent '.gitmodules') submodule.child.path child | Out-Null
                git-in $parent config -f (Join-Path $parent '.gitmodules') submodule.child.url './child' | Out-Null
                git-in $parent add .gitmodules | Out-Null
                git-in $parent commit -m 'add .gitmodules' | Out-Null

                New-Item -ItemType Directory -Path $childPath | Out-Null
                git-in $childPath init -b trunk | Out-Null   # deliberately NOT 'main'
                git-in $childPath config user.email 'test@example.com' | Out-Null
                git-in $childPath config user.name  'Test' | Out-Null
                git-in $childPath config commit.gpgsign false | Out-Null
                Set-Content -LiteralPath (Join-Path $childPath 'file.txt') -Value "child`n" -NoNewline
                git-in $childPath add . | Out-Null
                git-in $childPath commit -m 'initial' | Out-Null

                $results = Show-OgDiff -ProjectRoot $parent -Against main -WarningAction SilentlyContinue

                $results.Count | Should -Be 2
                ($results | Where-Object Repo -eq (Split-Path $parent -Leaf)).Action | Should -Be 'clean'
                ($results | Where-Object Repo -eq 'child').Action | Should -Be 'no-ref'
            } finally { Remove-Item -Recurse -Force $parent }
        }
    }

    Context 'Item 2: -Against -DirDiff exports to persistent directories (git deletes its own temp dirs)' {

        # Every test here that reaches the export step must clean up its per-repo root under
        # $env:TEMP\og-diff\<repo> -- it is deliberately NOT removed by Show-OgDiff itself (the
        # whole point is that it persists), so leftovers would otherwise accumulate across runs.
        # Defined in a BeforeAll (not loose in the Context body) so it exists at Pester's RUN phase,
        # not just discovery -- a function declared directly in a Context/Describe body only lives
        # during discovery and is invisible inside It blocks.
        BeforeAll {
            function Remove-OgDiffExportRoot {
                param([string] $RepoPath)
                $root = Join-Path $env:TEMP (Join-Path 'og-diff' (Split-Path $RepoPath -Leaf))
                Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
            }
        }

        It 'THE ACTUAL BUG, baseline: a plain git difftool --dir-diff temp directory does NOT survive after the tool returns' {
            # This does not call Show-OgDiff at all -- it exercises git itself, to concretely prove
            # the defect item 2 exists to avoid regressing to. The capture tool below runs WHILE
            # git's own temp dir still exists (during git's synchronous eval of the configured cmd)
            # and records its path; by the time git difftool returns, that directory is gone --
            # exactly what happened with Diffinity, a single-instance app that hands off to an
            # already-running window and exits immediately, fooling git into cleaning up early.
            $repo = New-TestGitRepo
            $captureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ogdiff-capture-' + [guid]::NewGuid().ToString('N'))
            try {
                New-Item -ItemType Directory -Path $captureRoot | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "dirty`n" -NoNewline

                $helperScript = Join-Path $captureRoot 'capture-helper.ps1'
                $captureFile  = Join-Path $captureRoot 'capture.txt'
                Set-Content -LiteralPath $helperScript -Value @'
param([string] $CaptureFile)
$found = Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Directory -Filter 'git-difftool.*' -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName
Set-Content -LiteralPath $CaptureFile -Value ($found -join "`n")
'@
                $cmdConfig = "pwsh -NoProfile -File `"$helperScript`" `"$captureFile`""
                git-in $repo config difftool.captest.cmd $cmdConfig | Out-Null

                & git -C $repo difftool --no-prompt --dir-diff --tool=captest 2>&1 | Out-Null

                $capturedPaths = if (Test-Path -LiteralPath $captureFile) {
                    @(Get-Content -LiteralPath $captureFile | Where-Object { $_ })
                } else { @() }

                $capturedPaths.Count | Should -BeGreaterThan 0
                foreach ($p in $capturedPaths) {
                    Test-Path -LiteralPath $p | Should -Be $false
                }
            } finally {
                Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue
                Remove-Item -Recurse -Force $captureRoot -ErrorAction SilentlyContinue
            }
        }

        It 'THE FIX: after Show-OgDiff -Against -DirDiff returns, both exported directories still exist and contain the expected files' {
            $repo = New-TestGitRepo
            try {
                $baseSha = git-in $repo rev-parse HEAD
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "changed`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'second commit' | Out-Null

                git-in $repo config diff.tool captest | Out-Null
                git-in $repo config difftool.captest.cmd '"C:\Tools\FakeTool.exe" "$LOCAL" "$REMOTE"' | Out-Null
                Mock -ModuleName og-framework -CommandName Start-OgDiffToolProcess -MockWith { }

                $r = Show-OgDiff -ProjectRoot $repo -Against $baseSha -DirDiff
                $r.Action | Should -Be 'opened'

                Test-Path -LiteralPath $r.BasePath | Should -Be $true
                Test-Path -LiteralPath $r.HeadPath | Should -Be $true
                Get-Content -LiteralPath (Join-Path $r.BasePath 'file.txt') | Should -Be 'base'
                Get-Content -LiteralPath (Join-Path $r.HeadPath 'file.txt') | Should -Be 'changed'
            } finally {
                Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue
                Remove-OgDiffExportRoot -RepoPath $repo
            }
        }

        It 'MERGE-BASE, NOT REF: exported base tree matches git merge-base <ref> HEAD, never <ref>''s own tip' {
            # <ref> (main) advances AFTER the branch point, so merge-base and <ref>'s tip are
            # provably different trees here -- only the merge-base is correct.
            $repo = New-TestGitRepo
            try {
                git-in $repo checkout -b feat | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'feat-only.txt') -Value "feat`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'feat-only change' | Out-Null

                git-in $repo checkout main | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'main-only.txt') -Value "main`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'main-only change' | Out-Null

                git-in $repo checkout feat | Out-Null

                # Oracle: merge-base(main, HEAD) and main's own tip are different trees here, and
                # only the merge-base tree lacks main-only.txt. git-in collapses multi-line stdout
                # into one trimmed string, so split back into lines before using -Contain on it.
                $mergeBase = git-in $repo merge-base main HEAD
                $refTip    = git-in $repo rev-parse main
                $mergeBase | Should -Not -Be $refTip
                $mergeBaseFiles = (git-in $repo ls-tree -r --name-only $mergeBase) -split '\r?\n'
                $refTipFiles    = (git-in $repo ls-tree -r --name-only $refTip)    -split '\r?\n'
                $mergeBaseFiles | Should -Not -Contain 'main-only.txt'
                $refTipFiles    | Should -Contain 'main-only.txt'

                git-in $repo config diff.tool captest | Out-Null
                git-in $repo config difftool.captest.cmd '"C:\Tools\FakeTool.exe" "$LOCAL" "$REMOTE"' | Out-Null
                Mock -ModuleName og-framework -CommandName Start-OgDiffToolProcess -MockWith { }

                $r = Show-OgDiff -ProjectRoot $repo -Against main -DirDiff
                $r.Action | Should -Be 'opened'

                # od task 3 adaptation: the export is SPARSE now (changed files only), so the unchanged
                # file.txt is on neither side; the old full-tree export had it on both.
                # Base = merge-base: neither branch's own commit is present. Had <ref>'s tip been the
                # base, main-only.txt would sit on the base side as a file this branch "deleted".
                Test-Path -LiteralPath (Join-Path $r.BasePath 'main-only.txt') | Should -Be $false
                Test-Path -LiteralPath (Join-Path $r.BasePath 'feat-only.txt') | Should -Be $false
                Test-Path -LiteralPath (Join-Path $r.BasePath 'file.txt')      | Should -Be $false
                $r.BaseRev | Should -Be $mergeBase
                Split-Path $r.BasePath -Leaf | Should -Be ("$($r.Repo) base " + $mergeBase.Substring(0, 7))

                # Head = HEAD (feat): feat's own commit is present, main's is not.
                Test-Path -LiteralPath (Join-Path $r.HeadPath 'feat-only.txt') | Should -Be $true
                Test-Path -LiteralPath (Join-Path $r.HeadPath 'main-only.txt') | Should -Be $false
                Test-Path -LiteralPath (Join-Path $r.HeadPath 'file.txt')      | Should -Be $false
            } finally {
                Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue
                Remove-OgDiffExportRoot -RepoPath $repo
            }
        }

        It 'a clean repo (-Against -DirDiff, HEAD == ref) exports nothing and launches nothing' {
            $repo = New-TestGitRepo
            try {
                Remove-OgDiffExportRoot -RepoPath $repo   # in case a stale run left one behind
                $exportRoot = Join-Path $env:TEMP (Join-Path 'og-diff' (Split-Path $repo -Leaf))

                Mock -ModuleName og-framework -CommandName Start-OgDiffToolProcess -MockWith { }

                $r = Show-OgDiff -ProjectRoot $repo -Against main -DirDiff -WarningAction SilentlyContinue
                $r.Action   | Should -Be 'clean'
                $r.BasePath | Should -BeNullOrEmpty
                $r.HeadPath | Should -BeNullOrEmpty
                Test-Path -LiteralPath $exportRoot | Should -Be $false
                Should -Invoke -ModuleName og-framework -CommandName Start-OgDiffToolProcess -Times 0
            } finally { Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue }
        }

        It 'no difftool configured: reports failed with a clear error, exports nothing, and never falls back to git difftool' {
            $repo = New-TestGitRepo
            try {
                $baseSha = git-in $repo rev-parse HEAD
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "changed`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'second commit' | Out-Null

                Remove-OgDiffExportRoot -RepoPath $repo
                $exportRoot = Join-Path $env:TEMP (Join-Path 'og-diff' (Split-Path $repo -Leaf))

                Mock -ModuleName og-framework -CommandName Invoke-Git `
                    -ParameterFilter { $Arguments -contains 'difftool' } `
                    -MockWith { throw 'git difftool must never be invoked when no tool is configured' }

                $r = Show-OgDiff -ProjectRoot $repo -Against $baseSha -DirDiff `
                    -Tool 'definitely-not-configured-anywhere' -WarningAction SilentlyContinue
                $r.Action   | Should -Be 'failed'
                $r.Error    | Should -Match 'difftool'
                $r.BasePath | Should -BeNullOrEmpty
                $r.HeadPath | Should -BeNullOrEmpty
                Test-Path -LiteralPath $exportRoot | Should -Be $false
            } finally { Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue }
        }
    }

    Context '-PerFile: the per-file git difftool path, as before directory diffs became the default' {
        # The two tests below are the pre-task-3 default-mode tests, moved here with -PerFile added: they
        # assert git difftool's arguments, which only the per-file path still uses.

        It '-PerFile reports opened for an unstaged edit, invoking difftool with plain --no-prompt (no range)' {
            $repo = New-TestGitRepo
            try {
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "dirty`n" -NoNewline

                Mock -ModuleName og-framework -CommandName Invoke-Git `
                    -ParameterFilter { $Arguments -contains 'difftool' } `
                    -MockWith {
                        $script:capturedArgs = $Arguments
                        [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
                    }

                $r = Show-OgDiff -ProjectRoot $repo -PerFile
                $r.Action | Should -Be 'opened'
                $script:capturedArgs | Should -Be @('difftool', '--no-prompt')
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It '-PerFile: a staged edit is reported opened by -Staged, with --cached passed to difftool' {
            $repo = New-TestGitRepo
            try {
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "staged`n" -NoNewline
                git-in $repo add . | Out-Null

                Mock -ModuleName og-framework -CommandName Invoke-Git `
                    -ParameterFilter { $Arguments -contains 'difftool' } `
                    -MockWith {
                        $script:capturedArgs = $Arguments
                        [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
                    }

                $r = Show-OgDiff -ProjectRoot $repo -Staged -PerFile
                $r.Action | Should -Be 'opened'
                $script:capturedArgs | Should -Contain '--cached'
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It '-PerFile -DirDiff runs plain per-file git difftool, never --dir-diff' {
            $repo = New-TestGitRepo
            try {
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "dirty`n" -NoNewline

                Mock -ModuleName og-framework -CommandName Invoke-Git `
                    -ParameterFilter { $Arguments -contains 'difftool' } `
                    -MockWith {
                        $script:capturedArgs = $Arguments
                        [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
                    }

                $r = Show-OgDiff -ProjectRoot $repo -PerFile -DirDiff -Tool captest
                $r.Action | Should -Be 'opened'
                $script:capturedArgs | Should -Be @('difftool', '--no-prompt', '--tool=captest')
                $script:Launches.Count | Should -Be 0
            } finally { Remove-Item -Recurse -Force $repo }
        }
    }

    Context 'od task 3: directory diffs by default, in one run, -PerFile kept' {

        BeforeAll {
            $script:Utf8 = [System.Text.UTF8Encoding]::new($false)

            function Write-TestText {
                param([string] $Dir, [string] $Rel, [string] $Text)
                $path = Join-Path $Dir $Rel
                [void] [System.IO.Directory]::CreateDirectory((Split-Path $path -Parent))
                [System.IO.File]::WriteAllText($path, $Text, $script:Utf8)
            }

            function Read-TestText {
                param([string] $Path)
                [System.IO.File]::ReadAllText($Path)
            }

            # A one-commit repo under $TestDrive: <fresh dir>\<Name>, a.txt = "one".
            function New-TestDiffRepo {
                param([string] $Name = 'repo')
                $dir = Join-Path (New-TestDir 'od3') $Name
                [void] [System.IO.Directory]::CreateDirectory($dir)
                Invoke-TestGit $dir init -q | Out-Null
                Write-TestText $dir 'a.txt' "one`n"
                Invoke-TestGit $dir add -- 'a.txt' | Out-Null
                Invoke-TestGit $dir commit -q -m 'one' | Out-Null
                $dir
            }

            # A three-repo og tree: <base>\root with real submodules libs/a and libs/b (local clones).
            function New-TestTree3 {
                $base = New-TestDir 'tree3'
                foreach ($n in 'a', 'b') {
                    $src = Join-Path $base "src-$n"
                    [void] [System.IO.Directory]::CreateDirectory($src)
                    Invoke-TestGit $src init -q | Out-Null
                    Write-TestText $src "$n.txt" "one-$n`n"
                    Invoke-TestGit $src add -- "$n.txt" | Out-Null
                    Invoke-TestGit $src commit -q -m "one-$n" | Out-Null
                }
                $root = Join-Path $base 'root'
                [void] [System.IO.Directory]::CreateDirectory($root)
                Invoke-TestGit $root init -q | Out-Null
                Write-TestText $root 'r.txt' "root`n"
                Invoke-TestGit $root add -- 'r.txt' | Out-Null
                Invoke-TestGit $root commit -q -m 'root' | Out-Null
                foreach ($n in 'a', 'b') {
                    Invoke-TestGit $root submodule add -q -- (Join-Path $base "src-$n") "libs/$n" | Out-Null
                }
                Invoke-TestGit $root commit -q -m 'add submodules' | Out-Null
                [PSCustomObject]@{ Root = $root; A = (Join-Path $root 'libs\a'); B = (Join-Path $root 'libs\b') }
            }

            # feat branched off main; main then gained main-only.txt, feat gained feat-only.txt; feat checked out.
            function New-TestDivergedRepo {
                $dir = New-TestDiffRepo 'diverged'
                Invoke-TestGit $dir checkout -q -b feat | Out-Null
                Write-TestText $dir 'feat-only.txt' "feat`n"
                Invoke-TestGit $dir add -- 'feat-only.txt' | Out-Null
                Invoke-TestGit $dir commit -q -m 'feat-only' | Out-Null
                Invoke-TestGit $dir checkout -q main | Out-Null
                Write-TestText $dir 'main-only.txt' "main`n"
                Invoke-TestGit $dir add -- 'main-only.txt' | Out-Null
                Invoke-TestGit $dir commit -q -m 'main-only' | Out-Null
                Invoke-TestGit $dir checkout -q feat | Out-Null
                $dir
            }

            function Get-TestIndexHash {
                param([string] $Dir)
                $rel = Invoke-TestGit $Dir rev-parse --git-path index
                $path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Dir, $rel))
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            }

            # Every file under a folder as sorted '/'-separated relative paths, hidden ones included. Nothing is
            # filtered out (od task 7): the engine's marker sits BESIDE a side folder, so a side folder's
            # listing must be exactly its exported files.
            function Get-TestFiles {
                param([string] $Dir)
                $root = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\') + '\'
                @(Get-ChildItem -LiteralPath $Dir -Recurse -Force -File |
                    ForEach-Object { $_.FullName.Substring($root.Length).Replace('\', '/') } |
                    Sort-Object -CaseSensitive)
            }

            $script:ResultFields = 'Repo,Path,Action,Error,Ref,Range,BasePath,HeadPath,Commit,BaseRev,HeadRev,FileCount,RunPath'
        }

        BeforeEach {
            # git difftool belongs to -PerFile only: anything else that reaches it is a bug.
            Mock -ModuleName og-framework Invoke-Git -ParameterFilter { $Arguments -contains 'difftool' } {
                throw 'git difftool must not be invoked here'
            }
        }

        It 'a three-repo tree with changes in two repos opens two tabs from ONE run folder; the clean repo opens nothing' {
            $t = New-TestTree3
            Write-TestText $t.Root 'r.txt' "root changed`n"
            Write-TestText $t.A 'a.txt' "a changed`n"

            $results = @(Show-OgDiff -ProjectRoot $t.Root)

            ($results | ForEach-Object Repo) | Should -Be @('root', 'a', 'b')
            ($results | ForEach-Object Path) | Should -Be @('', 'libs/a', 'libs/b')
            ($results | ForEach-Object Action) | Should -Be @('opened', 'opened', 'clean')
            ($results | ForEach-Object FileCount) | Should -Be @(1, 1, 0)

            # ONE run: one folder under og-diff, both opened repos in it, the clean one not.
            $runs = @(Get-ChildItem -LiteralPath $script:RunRoot -Directory)
            $runs.Count | Should -Be 1
            $runs[0].Name | Should -Match '^\d{8}-\d{6}-worktree$'
            $results[0].RunPath | Should -Be $runs[0].FullName
            $results[1].RunPath | Should -Be $runs[0].FullName
            $results[2].RunPath | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $runs[0].FullName -Directory | ForEach-Object Name | Sort-Object) |
                Should -Be @('a', 'root')

            # Two launches, root first, each on its own repo folder's sides.
            $script:Launches.Count | Should -Be 2
            $script:Launches[0] | Should -BeLike "*$($results[0].BasePath)*$($results[0].HeadPath)*"
            $script:Launches[1] | Should -BeLike "*$($results[1].BasePath)*$($results[1].HeadPath)*"
            Split-Path $results[0].HeadPath -Leaf | Should -Be 'root working'
            Split-Path $results[1].HeadPath -Leaf | Should -Be 'a working'
            # Each side's marker sits beside it in the repo folder, never inside it (od task 7).
            @(Get-ChildItem -LiteralPath (Join-Path $runs[0].FullName 'a') -Force | ForEach-Object Name | Sort-Object) |
                Should -Be @((Split-Path $results[1].BasePath -Leaf), "$(Split-Path $results[1].BasePath -Leaf).og-diff-side",
                    'a working', 'a working.og-diff-side')
            Read-TestText (Join-Path $results[0].BasePath 'r.txt') | Should -Be "root`n"
            Read-TestText (Join-Path $results[0].HeadPath 'r.txt') | Should -Be "root changed`n"
            Get-TestFiles $results[1].HeadPath | Should -Be @('a.txt')

            # The legacy per-repo export root is never written again.
            Test-Path -LiteralPath (Join-Path ([System.IO.Path]::GetTempPath()) 'og-diff\root') | Should -Be $false
        }

        It '-Staged exports HEAD vs the index: the staged content, not the unstaged edit, and no untracked file' {
            $repo = New-TestDiffRepo
            $head = Invoke-TestGit $repo rev-parse HEAD
            Write-TestText $repo 'a.txt' "staged`n"
            Invoke-TestGit $repo add -- 'a.txt' | Out-Null
            Write-TestText $repo 'a.txt' "unstaged`n"
            Write-TestText $repo 'u.txt' "untracked`n"

            $r = Show-OgDiff -ProjectRoot $repo -Staged

            $r.Action    | Should -Be 'opened'
            $r.FileCount | Should -Be 1
            $r.BaseRev   | Should -Be $head
            $r.HeadRev   | Should -BeNullOrEmpty
            Split-Path $r.BasePath -Leaf | Should -Be ("$($r.Repo) base " + $head.Substring(0, 7))
            Split-Path $r.HeadPath -Leaf | Should -Be "$($r.Repo) index"
            Split-Path $r.RunPath -Leaf  | Should -Match '^\d{8}-\d{6}-staged$'
            Read-TestText (Join-Path $r.BasePath 'a.txt') | Should -Be "one`n"
            Read-TestText (Join-Path $r.HeadPath 'a.txt') | Should -Be "staged`n"
            Get-TestFiles $r.BasePath | Should -Be @('a.txt')
            Get-TestFiles $r.HeadPath | Should -Be @('a.txt')
        }

        It '-Against exports the merge base and HEAD (only the branch''s own changes), with Ref, Range and both revs' {
            $repo = New-TestDivergedRepo
            $mergeBase = Invoke-TestGit $repo merge-base main HEAD
            $head      = Invoke-TestGit $repo rev-parse HEAD
            $mainTip   = Invoke-TestGit $repo rev-parse main
            $mergeBase | Should -Not -Be $mainTip

            $r = Show-OgDiff -ProjectRoot $repo -Against main

            $r.Action    | Should -Be 'opened'
            $r.Ref       | Should -Be 'main'
            $r.Range     | Should -Be 'main...HEAD'
            $r.BaseRev   | Should -Be $mergeBase
            $r.HeadRev   | Should -Be $head
            $r.FileCount | Should -Be 1
            Split-Path $r.BasePath -Leaf | Should -Be ("$($r.Repo) base " + $mergeBase.Substring(0, 7))
            Split-Path $r.HeadPath -Leaf | Should -Be ("$($r.Repo) head " + $head.Substring(0, 7))
            Split-Path $r.RunPath -Leaf  | Should -Match '^\d{8}-\d{6}-against-main$'
            # The merge base, never main's tip: main-only.txt is on NEITHER side.
            Get-TestFiles $r.BasePath | Should -Be @()
            Get-TestFiles $r.HeadPath | Should -Be @('feat-only.txt')
        }

        It '-Against keeps tree order across no-ref repos: root opened, submodules without the ref report no-ref' {
            $t = New-TestTree3
            Invoke-TestGit $t.Root branch base-point | Out-Null
            Write-TestText $t.Root 'r.txt' "root changed`n"
            Invoke-TestGit $t.Root add -- 'r.txt' | Out-Null
            Invoke-TestGit $t.Root commit -q -m 'root change' | Out-Null

            $results = @(Show-OgDiff -ProjectRoot $t.Root -Against base-point)

            ($results | ForEach-Object Repo) | Should -Be @('root', 'a', 'b')
            ($results | ForEach-Object Action) | Should -Be @('opened', 'no-ref', 'no-ref')
            $results[1].Ref   | Should -Be 'base-point'
            $results[1].Range | Should -BeNullOrEmpty
            $script:Launches.Count | Should -Be 1
        }

        It '-Against keeps tree order when a finished slot comes first: root no-ref, a opened, b no-ref' {
            # od task 3 rework 1: the root has no such ref (a finished no-ref result) and comes BEFORE the one
            # request. Emitting the set's results first and the finished slots after would give a, root, b.
            $t = New-TestTree3
            Invoke-TestGit $t.A branch only-in-a | Out-Null
            Write-TestText $t.A 'a.txt' "a changed`n"
            Invoke-TestGit $t.A add -- 'a.txt' | Out-Null
            Invoke-TestGit $t.A commit -q -m 'a change' | Out-Null

            $results = @(Show-OgDiff -ProjectRoot $t.Root -Against only-in-a)

            ($results | ForEach-Object Repo) | Should -Be @('root', 'a', 'b')
            ($results | ForEach-Object Action) | Should -Be @('no-ref', 'opened', 'no-ref')
            $results[1].Range | Should -Be 'only-in-a...HEAD'
            $results[1].FileCount | Should -Be 1
            $script:Launches.Count | Should -Be 1
        }

        It '-Against with no merge base reports failed for that repo, with the reason' {
            $repo = New-TestDiffRepo
            Invoke-TestGit $repo checkout -q --orphan other | Out-Null
            Write-TestText $repo 'o.txt' "other`n"
            Invoke-TestGit $repo add -- 'o.txt' | Out-Null
            Invoke-TestGit $repo commit -q -m 'orphan' | Out-Null
            Invoke-TestGit $repo checkout -q main | Out-Null

            $r = Show-OgDiff -ProjectRoot $repo -Against other -WarningAction SilentlyContinue

            $r.Action | Should -Be 'failed'
            $r.Error  | Should -Match 'merge base'
            $r.Range  | Should -Be 'other...HEAD'
            $script:Launches.Count | Should -Be 0
        }

        It 'a repo with only an untracked file opens in the default mode, the file on the head side only' {
            $repo = New-TestDiffRepo
            Write-TestText $repo 'new.txt' "new`n"

            $r = Show-OgDiff -ProjectRoot $repo

            $r.Action    | Should -Be 'opened'
            $r.FileCount | Should -Be 1
            Get-TestFiles $r.BasePath | Should -Be @()
            Get-TestFiles $r.HeadPath | Should -Be @('new.txt')
            $script:Launches.Count | Should -Be 1
        }

        It '-PerFile: a repo with only an untracked file is clean and git difftool is not run (it would show nothing)' {
            $repo = New-TestDiffRepo
            Write-TestText $repo 'new.txt' "new`n"

            $r = Show-OgDiff -ProjectRoot $repo -PerFile

            $r.Action    | Should -Be 'clean'
            $r.FileCount | Should -Be 0
            Should -Invoke -ModuleName og-framework Invoke-Git -Times 0 -ParameterFilter { $Arguments -contains 'difftool' }
        }

        It '-PerFile compares like git difftool: a staged-only change is clean without -Staged and opened with it' {
            # git difftool (no argument) compares the working tree with the INDEX, so a change that is
            # only staged shows nothing; the check must agree, or the result would claim a window.
            $repo = New-TestDiffRepo
            Write-TestText $repo 'a.txt' "staged`n"
            Invoke-TestGit $repo add -- 'a.txt' | Out-Null

            $r = Show-OgDiff -ProjectRoot $repo -PerFile
            $r.Action | Should -Be 'clean'
            Should -Invoke -ModuleName og-framework Invoke-Git -Times 0 -ParameterFilter { $Arguments -contains 'difftool' }

            Mock -ModuleName og-framework Invoke-Git -ParameterFilter { $Arguments -contains 'difftool' } {
                [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
            }
            $s = Show-OgDiff -ProjectRoot $repo -PerFile -Staged
            $s.Action    | Should -Be 'opened'
            $s.FileCount | Should -Be 1
            $s.BaseRev   | Should -Be (Invoke-TestGit $repo rev-parse HEAD)
        }

        It '-PerFile never calls the export, in every mode' -ForEach @(
            @{ Mode = 'WorkingTree' }, @{ Mode = 'Staged' }, @{ Mode = 'Against' }
        ) {
            Mock -ModuleName og-framework Open-OgDirDiffSet { throw 'Open-OgDirDiffSet must not run under -PerFile' }
            Mock -ModuleName og-framework Export-OgDiffSides { throw 'Export-OgDiffSides must not run under -PerFile' }
            Mock -ModuleName og-framework Get-OgDiffChange { throw 'Get-OgDiffChange must not run under -PerFile' }
            Mock -ModuleName og-framework Invoke-Git -ParameterFilter { $Arguments -contains 'difftool' } {
                $script:capturedArgs = $Arguments
                [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
            }

            $p = @{ PerFile = $true }
            switch ($Mode) {
                'WorkingTree' { $repo = New-TestDiffRepo; Write-TestText $repo 'a.txt' "two`n" }
                'Staged'      { $repo = New-TestDiffRepo; Write-TestText $repo 'a.txt' "two`n"
                                Invoke-TestGit $repo add -- 'a.txt' | Out-Null; $p.Staged = $true }
                'Against'     { $repo = New-TestDivergedRepo; $p.Against = 'main' }
            }

            $r = Show-OgDiff -ProjectRoot $repo @p

            $r.Action | Should -Be 'opened'
            $r.BasePath | Should -BeNullOrEmpty
            $r.RunPath  | Should -BeNullOrEmpty
            Should -Invoke -ModuleName og-framework Open-OgDirDiffSet -Times 0
            Should -Invoke -ModuleName og-framework Export-OgDiffSides -Times 0
            Should -Invoke -ModuleName og-framework Get-OgDiffChange -Times 0
            $script:Launches.Count | Should -Be 0
            Test-Path -LiteralPath $script:RunRoot | Should -Be $false
        }

        It '-PerFile change check leaves the real index untouched (a stat-dirty file would make git diff rewrite it)' {
            $repo = New-TestDiffRepo
            # Same content, new mtime: the index's stat cache is stale, so a plain `git diff` refreshes
            # and REWRITES .git/index.
            (Get-Item -LiteralPath (Join-Path $repo 'a.txt')).LastWriteTime = [datetime]::new(2020, 1, 1)
            $before = Get-TestIndexHash $repo

            $r = Show-OgDiff -ProjectRoot $repo -PerFile

            $r.Action | Should -Be 'clean'
            Get-TestIndexHash $repo | Should -Be $before
            Should -Invoke -ModuleName og-framework Invoke-Git -Times 0 -ParameterFilter { $Arguments -contains 'difftool' }

            # Also with a real change beside it (git difftool itself is mocked here).
            Write-TestText $repo 'b.txt' "b`n"
            Invoke-TestGit $repo add -- 'b.txt' | Out-Null
            Invoke-TestGit $repo commit -q -m 'b' | Out-Null
            Write-TestText $repo 'b.txt' "b changed`n"
            (Get-Item -LiteralPath (Join-Path $repo 'a.txt')).LastWriteTime = [datetime]::new(2019, 1, 1)
            $before = Get-TestIndexHash $repo
            Mock -ModuleName og-framework Invoke-Git -ParameterFilter { $Arguments -contains 'difftool' } {
                [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
            }
            $r = Show-OgDiff -ProjectRoot $repo -PerFile
            $r.Action    | Should -Be 'opened'
            $r.FileCount | Should -Be 1
            Get-TestIndexHash $repo | Should -Be $before
        }

        It 'the default mode leaves the real index and status untouched too' {
            $repo = New-TestDiffRepo
            Write-TestText $repo 'b.txt' "b`n"
            Invoke-TestGit $repo add -- 'b.txt' | Out-Null
            Invoke-TestGit $repo commit -q -m 'b' | Out-Null
            Write-TestText $repo 'b.txt' "b changed`n"
            (Get-Item -LiteralPath (Join-Path $repo 'a.txt')).LastWriteTime = [datetime]::new(2020, 1, 1)
            $before = Get-TestIndexHash $repo
            $status = Invoke-TestGit $repo --no-optional-locks status --porcelain
            $before | Should -Be (Get-TestIndexHash $repo)   # the status above wrote nothing either

            $r = Show-OgDiff -ProjectRoot $repo

            $r.Action | Should -Be 'opened'
            Get-TestIndexHash $repo | Should -Be $before
            Invoke-TestGit $repo --no-optional-locks status --porcelain | Should -Be $status
        }

        It 'a listing error (-Staged during a merge conflict) is that repo''s failed result, with the engine''s message' {
            $repo = New-TestDiffRepo
            Invoke-TestGit $repo checkout -q -b side | Out-Null
            Write-TestText $repo 'a.txt' "side`n"
            Invoke-TestGit $repo commit -q -am 'side' | Out-Null
            Invoke-TestGit $repo checkout -q main | Out-Null
            Write-TestText $repo 'a.txt' "main`n"
            Invoke-TestGit $repo commit -q -am 'main' | Out-Null
            & git -C $repo merge -q side 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0   # the conflict is real

            $all = @(Show-OgDiff -ProjectRoot $repo -Staged 3>&1)
            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $r = @($all | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })

            $r.Count     | Should -Be 1
            $r[0].Action | Should -Be 'failed'
            $r[0].Error  | Should -Match 'Unmerged path'
            $warnings.Count | Should -Be 1
            $script:Launches.Count | Should -Be 0
        }

        It 'resolves the diff tool once, from the first changed repo (a later repo''s local difftool config is not used)' {
            $t = New-TestTree3
            Invoke-TestGit $t.A config difftool.captest.cmd '"C:\Tools\LocalA.exe" "$LOCAL" "$REMOTE"' | Out-Null
            Invoke-TestGit $t.B config difftool.captest.cmd '"C:\Tools\LocalB.exe" "$LOCAL" "$REMOTE"' | Out-Null
            Write-TestText $t.A 'a.txt' "a changed`n"
            Write-TestText $t.B 'b.txt' "b changed`n"

            $results = @(Show-OgDiff -ProjectRoot $t.Root)

            ($results | ForEach-Object Action) | Should -Be @('clean', 'opened', 'opened')
            $script:Launches.Count | Should -Be 2
            $script:Launches | ForEach-Object { $_ | Should -BeLike '"C:\Tools\LocalA.exe" *' }
        }

        It 'skips a repo whose folder is missing (no result), as before' {
            $repo = New-TestDiffRepo 'withgone'
            Invoke-TestGit $repo config -f .gitmodules submodule.gone.path libs/gone | Out-Null
            Invoke-TestGit $repo config -f .gitmodules submodule.gone.url ./gone | Out-Null
            Invoke-TestGit $repo add -- .gitmodules | Out-Null
            Invoke-TestGit $repo commit -q -m 'gitmodules' | Out-Null

            $results = @(Show-OgDiff -ProjectRoot $repo)

            $results.Count     | Should -Be 1
            $results[0].Repo   | Should -Be 'withgone'
            $results[0].Action | Should -Be 'clean'
        }

        It 'every branch emits one result type: Og.DiffResult with the same fields in the same order' {
            $results = [System.Collections.Generic.List[object]]::new()

            $dirty = New-TestDiffRepo; Write-TestText $dirty 'a.txt' "two`n"
            $clean = New-TestDiffRepo
            $diverged = New-TestDivergedRepo
            $orphan = New-TestDiffRepo
            Invoke-TestGit $orphan checkout -q --orphan other | Out-Null
            Invoke-TestGit $orphan commit -q --allow-empty -m 'orphan' | Out-Null
            Invoke-TestGit $orphan checkout -q main | Out-Null

            $results.Add((Show-OgDiff -ProjectRoot $dirty))                                          # opened (dir diff)
            $results.Add((Show-OgDiff -ProjectRoot $clean))                                          # clean (dir diff)
            $results.Add((Show-OgDiff -ProjectRoot $dirty -Tool nope -WarningAction SilentlyContinue)) # failed (no tool)
            $results.Add((Show-OgDiff -ProjectRoot $clean -Against nowhere))                         # no-ref
            $results.Add((Show-OgDiff -ProjectRoot $orphan -Against other -WarningAction SilentlyContinue)) # failed (merge base)
            $results.Add((Show-OgDiff -ProjectRoot $clean -PerFile))                                 # clean (-PerFile)
            $results.Add((Show-OgDiff -ProjectRoot $diverged -Against nowhere -PerFile))             # no-ref (-PerFile)
            Mock -ModuleName og-framework Invoke-Git -ParameterFilter { $Arguments -contains 'difftool' } {
                [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
            }
            $results.Add((Show-OgDiff -ProjectRoot $dirty -PerFile))                                 # opened (-PerFile)
            Mock -ModuleName og-framework Invoke-Git -ParameterFilter { $Arguments -contains 'difftool' } {
                [PSCustomObject]@{ ExitCode = 1; StdOut = ''; StdErr = 'tool broke'; WorkingDirectory = $WorkingDirectory }
            }
            $results.Add((Show-OgDiff -ProjectRoot $dirty -PerFile -WarningAction SilentlyContinue)) # failed (-PerFile)

            ($results | ForEach-Object Action) |
                Should -Be @('opened', 'clean', 'failed', 'no-ref', 'failed', 'clean', 'no-ref', 'opened', 'failed')
            foreach ($r in $results) {
                $r.PSObject.TypeNames[0] | Should -Be 'Og.DiffResult'
                ($r.PSObject.Properties.Name -join ',') | Should -Be $script:ResultFields
                $r.Commit | Should -BeNullOrEmpty
            }
            $results[8].Error | Should -Be 'tool broke'
        }
    }

    Context 'od task 4b: -Commit diffs one root commit (one oggitcommit cascade)' {

        BeforeAll {
            # Three levels on local remotes: project (root) -> libs/child -> libs/child/ext/nested, the nested
            # one added with oggitsubadd + oggitadd + oggitcommit (od task 4a's fixture: the newest root
            # commit IS the "added submodule" cascade).
            function New-OdCommitTree {
                $p = New-TestProject
                $nestedUrl = New-TestRemote -Root $p.Remotes -Name 'nested'
                Add-OgSubmodule -Url $nestedUrl -Path 'libs/child/ext/nested' -ProjectRoot $p.Project | Out-Null
                Add-OgChange -ProjectRoot $p.Project | Out-Null
                New-OgCommit -Message 'add nested' -ProjectRoot $p.Project | Out-Null
                $p.Child  = Join-Path $p.Project 'libs\child'
                $p.Nested = Join-Path $p.Project 'libs\child\ext\nested'
                $p.GitDir = Join-Path $p.Project '.git'
                $p
            }

            # A full id, or a gitlink's pin with '<commit>:<path>'.
            function Get-OdRev {
                param([string] $Dir, [string] $Rev = 'HEAD')
                Invoke-TestGit $Dir rev-parse $Rev
            }

            function Get-OdText {
                param([string] $Path)
                ([System.IO.File]::ReadAllText($Path)).Trim()
            }

            # Every file under a folder as sorted '/'-separated relative paths, hidden ones included. Nothing is
            # filtered out (od task 7): the engine's marker sits BESIDE a side folder, so a side folder's
            # listing must be exactly its exported files.
            function Get-OdFiles {
                param([string] $Dir)
                $root = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\') + '\'
                @(Get-ChildItem -LiteralPath $Dir -Recurse -Force -File |
                    ForEach-Object { $_.FullName.Substring($root.Length).Replace('\', '/') } |
                    Sort-Object -CaseSensitive)
            }

            # Every file under a folder (a project's work trees AND its .git, absorbed submodule git dirs under
            # .git/modules included), with mtime and SHA-256. Any write anywhere below it changes the string.
            function Get-OdTreeSnapshot {
                param([string] $Dir)
                $root = (Resolve-Path -LiteralPath $Dir).ProviderPath
                (Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
                    "$($_.FullName.Substring($root.Length))|$($_.LastWriteTimeUtc.Ticks)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
                }) -join "`n"
            }

            # The three-level cascade: root, child and nested all change files, and nested gets TWO commits
            # (a manual one picked up by oggitcommit's pre-pass, then the cascade's own), so the old pin is
            # not the new pin's parent. Afterwards child and nested move ON past their new pins, so a diff
            # that used a submodule's tip instead of its pins would show other sides.
            function New-OdCascade {
                $t = New-OdCommitTree
                $t.OldRoot   = Get-OdRev $t.Project
                $t.OldChild  = Get-OdRev $t.Project 'HEAD:libs/child'
                $t.OldNested = Get-OdRev $t.Child 'HEAD:ext/nested'

                Add-TestCommit -Dir $t.Nested -File 'manual.txt' -Content 'manual' -Message 'manual'
                Set-Content -LiteralPath (Join-Path $t.Nested 'README.md') -Value 'nested changed'
                Set-Content -LiteralPath (Join-Path $t.Child 'README.md')  -Value 'child changed'
                Set-Content -LiteralPath (Join-Path $t.Child 'child.txt')  -Value 'child work'
                Set-Content -LiteralPath (Join-Path $t.Project 'README.md') -Value 'root changed'
                Set-Content -LiteralPath (Join-Path $t.Project 'root.txt')  -Value 'root work'
                Add-OgChange -ProjectRoot $t.Project | Out-Null
                New-OgCommit -Message 'cascade' -ProjectRoot $t.Project | Out-Null

                $t.Sha       = Get-OdRev $t.Project
                $t.NewChild  = Get-OdRev $t.Project 'HEAD:libs/child'
                $t.NewNested = Get-OdRev $t.Child 'HEAD:ext/nested'
                Get-OdRev $t.Nested "$($t.NewNested)^1" | Should -Not -Be $t.OldNested   # precondition: two commits

                Add-TestCommit -Dir $t.Nested -File 'later.txt' -Message 'later nested'
                Add-TestCommit -Dir $t.Child  -File 'later.txt' -Message 'later child'
                Get-OdRev $t.Child  | Should -Not -Be $t.NewChild    # precondition: the tips moved on
                Get-OdRev $t.Nested | Should -Not -Be $t.NewNested
                $t
            }

            $script:OdResultFields = 'Repo,Path,Action,Error,Ref,Range,BasePath,HeadPath,Commit,BaseRev,HeadRev,FileCount,RunPath'
        }

        BeforeEach {
            # git difftool belongs to -PerFile only; a -PerFile test mocks it again to capture its calls.
            Mock -ModuleName og-framework Invoke-Git -ParameterFilter { $Arguments -contains 'difftool' } {
                throw 'git difftool must not be invoked here'
            }
        }

        It 'opens every repo of a three-level cascade from ONE run folder, one launch each, with the exact pinned sides' {
            $t = New-OdCascade
            $short = $t.Sha.Substring(0, 7)

            $r = @(Show-OgDiff -ProjectRoot $t.Project -Commit $short)

            ($r | ForEach-Object Path)   | Should -Be @('', 'libs/child', 'libs/child/ext/nested')
            ($r | ForEach-Object Repo)   | Should -Be @('project', 'child', 'nested')
            ($r | ForEach-Object Action) | Should -Be @('opened', 'opened', 'opened')
            ($r | ForEach-Object FileCount) | Should -Be @(2, 2, 2)
            foreach ($x in $r) {
                $x.PSObject.TypeNames[0] | Should -Be 'Og.DiffResult'
                ($x.PSObject.Properties.Name -join ',') | Should -Be $script:OdResultFields
                $x.Commit | Should -Be $t.Sha
                $x.Ref    | Should -BeNullOrEmpty
                $x.Range  | Should -BeNullOrEmpty
            }

            # The ranges are the pins (and the root's first parent), never a tip.
            @($r[0].BaseRev, $r[0].HeadRev) | Should -Be @($t.OldRoot, $t.Sha)
            @($r[1].BaseRev, $r[1].HeadRev) | Should -Be @($t.OldChild, $t.NewChild)
            @($r[2].BaseRev, $r[2].HeadRev) | Should -Be @($t.OldNested, $t.NewNested)

            # ONE run folder, labelled commit-<short>, one repo folder per touched repo.
            $runs = @(Get-ChildItem -LiteralPath $script:RunRoot -Directory)
            $runs.Count   | Should -Be 1
            $runs[0].Name | Should -Match "^\d{8}-\d{6}-commit-$short$"
            $r | ForEach-Object { $_.RunPath | Should -Be $runs[0].FullName }
            @(Get-ChildItem -LiteralPath $runs[0].FullName -Directory | ForEach-Object Name | Sort-Object) |
                Should -Be @('child', 'nested', 'project')

            # One launch per repo, in tree order, each on its own sides, named after the pins.
            $script:Launches.Count | Should -Be 3
            for ($i = 0; $i -lt 3; $i++) {
                $script:Launches[$i] | Should -Be "`"C:\Tools\FakeTool.exe`" `"$($r[$i].BasePath)`" `"$($r[$i].HeadPath)`""
                $repoFolder = @('project', 'child', 'nested')[$i]
                Split-Path $r[$i].BasePath -Leaf | Should -Be ("$repoFolder base " + $r[$i].BaseRev.Substring(0, 7))
                Split-Path $r[$i].HeadPath -Leaf | Should -Be ("$repoFolder head " + $r[$i].HeadRev.Substring(0, 7))
            }

            # The exact sides: only the changed files, with the content at each pin.
            Get-OdFiles $r[0].BasePath | Should -Be @('README.md')
            Get-OdFiles $r[0].HeadPath | Should -Be @('README.md', 'root.txt')
            Get-OdText (Join-Path $r[0].BasePath 'README.md') | Should -Be '# parent'
            Get-OdText (Join-Path $r[0].HeadPath 'README.md') | Should -Be 'root changed'

            Get-OdFiles $r[1].BasePath | Should -Be @('README.md')
            Get-OdFiles $r[1].HeadPath | Should -Be @('child.txt', 'README.md')   # Sort-Object's culture order
            Get-OdText (Join-Path $r[1].BasePath 'README.md') | Should -Be '# child'
            Get-OdText (Join-Path $r[1].HeadPath 'README.md') | Should -Be 'child changed'

            Get-OdFiles $r[2].BasePath | Should -Be @('README.md')
            Get-OdFiles $r[2].HeadPath | Should -Be @('manual.txt', 'README.md')   # never later.txt (the tip)
            Get-OdText (Join-Path $r[2].BasePath 'README.md') | Should -Be '# nested'
            Get-OdText (Join-Path $r[2].HeadPath 'README.md') | Should -Be 'nested changed'
        }

        It 'diffs an EARLIER cascade by its own pins, not the repos'' current state' {
            $t = New-OdCascade
            # A second cascade after the first: the first must still diff to exactly its own ranges.
            Set-Content -LiteralPath (Join-Path $t.Nested 'README.md') -Value 'second cascade'
            Add-OgChange -ProjectRoot $t.Project | Out-Null
            New-OgCommit -Message 'second' -ProjectRoot $t.Project | Out-Null
            Get-OdRev $t.Project | Should -Not -Be $t.Sha

            $r = @(Show-OgDiff -ProjectRoot $t.Project -Commit $t.Sha)

            ($r | ForEach-Object Action) | Should -Be @('opened', 'opened', 'opened')
            @($r[1].BaseRev, $r[1].HeadRev) | Should -Be @($t.OldChild, $t.NewChild)
            @($r[2].BaseRev, $r[2].HeadRev) | Should -Be @($t.OldNested, $t.NewNested)
            Get-OdText (Join-Path $r[2].HeadPath 'README.md') | Should -Be 'nested changed'
        }

        It 'a root-only commit opens the root alone' {
            $t = New-OdCommitTree
            $before = Get-OdRev $t.Project
            Add-TestCommit -Dir $t.Project -File 'only-root.txt' -Content 'root only' -Message 'root only'
            $sha = Get-OdRev $t.Project

            $r = @(Show-OgDiff -ProjectRoot $t.Project -Commit HEAD)

            $r.Count        | Should -Be 1
            $r[0].Path      | Should -Be ''
            $r[0].Action    | Should -Be 'opened'
            $r[0].BaseRev   | Should -Be $before
            $r[0].HeadRev   | Should -Be $sha
            $r[0].Commit    | Should -Be $sha
            $r[0].FileCount | Should -Be 1
            Get-OdFiles $r[0].BasePath | Should -Be @()
            Get-OdFiles $r[0].HeadPath | Should -Be @('only-root.txt')
            $script:Launches.Count | Should -Be 1
        }

        It 'a submodule whose pin moved but whose own files did not is clean (FileCount 0, no tab); its nested repo opens' {
            $t = New-OdCommitTree
            Set-Content -LiteralPath (Join-Path $t.Nested 'README.md') -Value 'nested only'
            Add-OgChange -ProjectRoot $t.Project | Out-Null
            New-OgCommit -Message 'nested only' -ProjectRoot $t.Project | Out-Null

            $r = @(Show-OgDiff -ProjectRoot $t.Project -Commit HEAD)

            ($r | ForEach-Object Path)   | Should -Be @('libs/child', 'libs/child/ext/nested')
            ($r | ForEach-Object Action) | Should -Be @('clean', 'opened')
            $r[0].FileCount | Should -Be 0
            $r[0].RunPath   | Should -BeNullOrEmpty
            $r[0].BasePath  | Should -BeNullOrEmpty
            $r[0].BaseRev   | Should -Be (Get-OdRev $t.Project 'HEAD~1:libs/child')
            $r[0].HeadRev   | Should -Be (Get-OdRev $t.Project 'HEAD:libs/child')
            $script:Launches.Count | Should -Be 1
            @(Get-ChildItem -LiteralPath $r[1].RunPath -Directory | ForEach-Object Name) | Should -Be @('nested')
        }

        It 'an added submodule opens with an empty base and all its files on the head side' {
            $t = New-OdCommitTree   # its newest root commit is the oggitsubadd cascade

            $r = @(Show-OgDiff -ProjectRoot $t.Project -Commit HEAD)

            ($r | ForEach-Object Path)   | Should -Be @('libs/child', 'libs/child/ext/nested')
            ($r | ForEach-Object Action) | Should -Be @('opened', 'opened')
            Get-OdFiles $r[0].HeadPath | Should -Be @('.gitmodules')   # the child's own file change
            $r[1].BaseRev | Should -BeNullOrEmpty
            $r[1].HeadRev | Should -Be (Get-OdRev $t.Child 'HEAD:ext/nested')
            Split-Path $r[1].BasePath -Leaf | Should -Be 'nested base empty'
            Get-OdFiles $r[1].BasePath | Should -Be @()
            Get-OdFiles $r[1].HeadPath | Should -Be @('README.md')
        }

        It 'a removed submodule is diffed through the git dir its parent kept: old files on the base side, empty head, read-only' {
            $t = New-OdCommitTree
            $oldChild  = Get-OdRev $t.Project 'HEAD:libs/child'
            $oldNested = Get-OdRev $t.Child 'HEAD:ext/nested'
            Invoke-TestGit $t.Project rm -q -- libs/child | Out-Null
            Invoke-TestGit $t.Project commit -q -m 'drop child' | Out-Null
            Test-Path -LiteralPath $t.Child | Should -BeFalse                                       # no work tree
            Test-Path -LiteralPath (Join-Path $t.GitDir 'modules\child-module') | Should -BeTrue   # its git dir kept

            # Everything under the project (work trees, .git, .git/modules/...) and the remotes, before.
            $before = Get-OdTreeSnapshot $t.Root

            $r = @(Show-OgDiff -ProjectRoot $t.Project -Commit HEAD)

            ($r | ForEach-Object Path)   | Should -Be @('', 'libs/child', 'libs/child/ext/nested')
            ($r | ForEach-Object Action) | Should -Be @('opened', 'opened', 'opened')
            @($r[1].BaseRev, $r[1].HeadRev) | Should -Be @($oldChild, $null)
            @($r[2].BaseRev, $r[2].HeadRev) | Should -Be @($oldNested, $null)

            # The old files on the base side, from the old pin; the head side is empty, like a deleted file.
            Get-OdFiles $r[1].BasePath | Should -Be @('.gitmodules', 'README.md')
            Get-OdText (Join-Path $r[1].BasePath 'README.md') | Should -Be '# child'
            Split-Path $r[1].HeadPath -Leaf | Should -Be 'child head empty'
            Get-OdFiles $r[1].HeadPath | Should -Be @()
            Get-OdFiles $r[2].BasePath | Should -Be @('README.md')
            Get-OdText (Join-Path $r[2].BasePath 'README.md') | Should -Be '# nested'
            Get-OdFiles $r[2].HeadPath | Should -Be @()
            $script:Launches.Count | Should -Be 3

            # READ-ONLY: nothing under the project changed (the modules/ git dirs included), and
            # checkout-index wrote only into the run folder: it holds exactly the exported files, plus each
            # side's marker BESIDE its side folder (od task 7).
            Get-OdTreeSnapshot $t.Root | Should -Be $before
            Test-Path -LiteralPath $t.Child | Should -BeFalse
            $run = $r[0].RunPath
            $run.StartsWith($script:RunRoot) | Should -BeTrue
            $childBase  = "child base $($oldChild.Substring(0, 7))"
            $nestedBase = "nested base $($oldNested.Substring(0, 7))"
            $projBase   = Split-Path $r[0].BasePath -Leaf
            $projHead   = Split-Path $r[0].HeadPath -Leaf
            Get-OdFiles $run | Should -Be (@(
                "child/$childBase/.gitmodules"
                "child/$childBase/README.md"
                "child/$childBase.og-diff-side"
                "child/child head empty.og-diff-side"
                "nested/$nestedBase/README.md"
                "nested/$nestedBase.og-diff-side"
                "nested/nested head empty.og-diff-side"
                "project/$projBase/.gitmodules"
                "project/$projBase.og-diff-side"
                "project/$projHead/.gitmodules"
                "project/$projHead.og-diff-side"
            ) | Sort-Object -CaseSensitive)
        }

        It 'reports a pin commit not present locally as its own missing-commit result, in tree order between two opened repos' {
            $t = New-OdCommitTree
            $zedUrl = New-TestRemote -Root $t.Remotes -Name 'zed'
            Add-OgSubmodule -Url $zedUrl -Path 'libs/zed' -ProjectRoot $t.Project | Out-Null
            Add-OgChange -ProjectRoot $t.Project | Out-Null
            New-OgCommit -Message 'add zed' -ProjectRoot $t.Project | Out-Null
            $zed = Join-Path $t.Project 'libs\zed'

            # A real child commit that exists only on the remote (pushed from another clone, never fetched here).
            $other = Join-Path $t.Root 'other-child'
            Invoke-TestGit $t.Root clone -q $t.ChildUrl $other | Out-Null
            Add-TestCommit -Dir $other -File 'remote-only.txt' -Message 'remote only'
            Invoke-TestGit $other push -q origin HEAD:refs/heads/remote-only | Out-Null
            $remoteOnly = Get-OdRev $other

            # One root commit: a root file, the child pinned to the missing commit, and zed moved.
            Add-TestCommit -Dir $zed -File 'z.txt' -Content 'zed work' -Message 'zed work'
            Set-Content -LiteralPath (Join-Path $t.Project 'root.txt') -Value 'root work'
            Invoke-TestGit $t.Project add -- root.txt libs/zed | Out-Null
            Invoke-TestGit $t.Project update-index --cacheinfo "160000,$remoteOnly,libs/child" | Out-Null
            Invoke-TestGit $t.Project commit -q -m 'pin to a commit not fetched' | Out-Null
            $sha = Get-OdRev $t.Project

            $r = @(Show-OgDiff -ProjectRoot $t.Project -Commit HEAD -WarningVariable warnings -WarningAction SilentlyContinue)

            ($r | ForEach-Object Path)   | Should -Be @('', 'libs/child', 'libs/zed')
            ($r | ForEach-Object Action) | Should -Be @('opened', 'missing-commit', 'opened')
            $r[1].Error     | Should -Match "head pin $remoteOnly"
            $r[1].HeadRev   | Should -Be $remoteOnly
            $r[1].Commit    | Should -Be $sha
            $r[1].FileCount | Should -BeNullOrEmpty
            $r[1].RunPath   | Should -BeNullOrEmpty
            ($r[1].PSObject.Properties.Name -join ',') | Should -Be $script:OdResultFields
            @($warnings | Where-Object { "$_" -match 'libs/child' }).Count | Should -Be 1
            $script:Launches.Count | Should -Be 2
            $script:Launches[0] | Should -BeLike "*$($r[0].HeadPath)*"
            $script:Launches[1] | Should -BeLike "*$($r[2].HeadPath)*"
            Get-OdFiles $r[2].HeadPath | Should -Be @('z.txt')

            # The same slot under -PerFile.
            $script:Difftool = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName og-framework Invoke-Git -ParameterFilter { $Arguments -contains 'difftool' } {
                $script:Difftool.Add($WorkingDirectory)
                [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
            }
            $p = @(Show-OgDiff -ProjectRoot $t.Project -Commit HEAD -PerFile -WarningAction SilentlyContinue)
            ($p | ForEach-Object Action) | Should -Be @('opened', 'missing-commit', 'opened')
            @($script:Difftool) | Should -Be @($t.Project, $zed)
        }

        It '-PerFile runs git difftool <old> <new> in each touched repo with the pinned revs, and never exports' {
            $t = New-OdCascade
            $script:Difftool = [System.Collections.Generic.List[object]]::new()
            Mock -ModuleName og-framework Invoke-Git -ParameterFilter { $Arguments -contains 'difftool' } {
                $script:Difftool.Add([PSCustomObject]@{ Dir = $WorkingDirectory; Args = @($Arguments) })
                [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
            }
            Mock -ModuleName og-framework Open-OgDirDiffSet { throw 'no directory diff under -PerFile' }

            $r = @(Show-OgDiff -ProjectRoot $t.Project -Commit $t.Sha -PerFile)

            ($r | ForEach-Object Action) | Should -Be @('opened', 'opened', 'opened')
            $script:Difftool.Count | Should -Be 3
            $expected = @(
                @($t.Project, $t.OldRoot, $t.Sha),
                @($t.Child, $t.OldChild, $t.NewChild),
                @($t.Nested, $t.OldNested, $t.NewNested))
            for ($i = 0; $i -lt 3; $i++) {
                $script:Difftool[$i].Dir  | Should -Be $expected[$i][0]
                $script:Difftool[$i].Args | Should -Be @('difftool', '--no-prompt', $expected[$i][1], $expected[$i][2])
                $r[$i].BaseRev | Should -Be $expected[$i][1]
                $r[$i].HeadRev | Should -Be $expected[$i][2]
                $r[$i].Commit  | Should -Be $t.Sha
                $r[$i].RunPath | Should -BeNullOrEmpty
                # FileCount = what git difftool walks: git's own `git diff --name-only <old> <new>` there.
                $oracle = @((Invoke-TestGit $expected[$i][0] diff --name-only $expected[$i][1] $expected[$i][2]) -split "`r?`n" | Where-Object { $_ })
                $r[$i].FileCount | Should -Be $oracle.Count
            }
            Should -Invoke -ModuleName og-framework Open-OgDirDiffSet -Times 0
            Test-Path -LiteralPath $script:RunRoot | Should -BeFalse
        }

        It '-PerFile reports an added or a removed submodule as failed with a hint to the directory mode, and runs no difftool for it' {
            $t = New-OdCommitTree   # newest root commit: nested added
            $script:Difftool = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName og-framework Invoke-Git -ParameterFilter { $Arguments -contains 'difftool' } {
                $script:Difftool.Add($WorkingDirectory)
                [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
            }

            $added = @(Show-OgDiff -ProjectRoot $t.Project -Commit HEAD -PerFile -WarningAction SilentlyContinue)
            ($added | ForEach-Object Action) | Should -Be @('opened', 'failed')
            $added[1].Error | Should -Match 'added'
            $added[1].Error | Should -Match 'oggitdiff -Commit'
            @($script:Difftool) | Should -Be @($t.Child)

            Invoke-TestGit $t.Project rm -q -- libs/child | Out-Null
            Invoke-TestGit $t.Project commit -q -m 'drop child' | Out-Null
            $script:Difftool.Clear()

            $removed = @(Show-OgDiff -ProjectRoot $t.Project -Commit HEAD -PerFile -WarningAction SilentlyContinue)
            ($removed | ForEach-Object Path)   | Should -Be @('', 'libs/child', 'libs/child/ext/nested')
            ($removed | ForEach-Object Action) | Should -Be @('opened', 'failed', 'failed')
            $removed[1].Error | Should -Match 'no work tree'
            $removed[1].Error | Should -Match 'directory mode'
            @($script:Difftool) | Should -Be @($t.Project)
        }

        It 'refuses a -Commit that names no commit before listing anything, and binds only alone' {
            $t = New-OdCommitTree
            { Show-OgDiff -ProjectRoot $t.Project -Commit 'no-such-rev' } | Should -Throw '*does not name a commit*'
            { Show-OgDiff -ProjectRoot $t.Project -Commit '--all' } | Should -Throw '*invalid revision*'
            { Show-OgDiff -ProjectRoot $t.Project -Commit '' } | Should -Throw
            { Show-OgDiff -ProjectRoot $t.Project -Commit HEAD -Staged } | Should -Throw
            { Show-OgDiff -ProjectRoot $t.Project -Commit HEAD -Against main } | Should -Throw
            { Show-OgDiff -ProjectRoot $t.Project -Commit HEAD -Fetch } | Should -Throw
            $script:Launches.Count | Should -Be 0
            Test-Path -LiteralPath $script:RunRoot | Should -BeFalse
        }

        It 'git-dir mode is Range only and takes only a fully qualified, existing git dir' {
            $t = New-OdCommitTree
            $gd = Join-Path $t.GitDir 'modules\child-module'
            InModuleScope og-framework -Parameters @{ Gd = $gd; Wd = $t.Child } {
                { Get-OgDiffChange -WorkingDirectory $Wd -Kind WorkingTree -GitDir $Gd } | Should -Throw '*belongs to -Kind Range*'
                { Get-OgDiffChange -WorkingDirectory $Wd -Kind Range -BaseRev '' -HeadRev HEAD -GitDir 'modules\child-module' } |
                    Should -Throw '*fully qualified*'
                { Get-OgDiffChange -WorkingDirectory $Wd -Kind Range -BaseRev '' -HeadRev HEAD -GitDir "$Gd-nope" } |
                    Should -Throw '*does not exist*'
                { New-OgDirDiffRequest -Repo child -WorkingDirectory $Wd -Kind Staged -GitDir $Gd } | Should -Throw '*belongs to -Kind Range*'
                $hand = [PSCustomObject]@{ Repo = 'child'; WorkingDirectory = $Wd; Kind = 'WorkingTree'; GitDir = $Gd }
                { Open-OgDirDiffSet -Request $hand -Label x } | Should -Throw '*git-dir mode is Range only*'

                # The same Range read through the git dir and through the work tree lists the same files.
                $viaGitDir = Get-OgDiffChange -WorkingDirectory 'C:\unused' -Kind Range -BaseRev '' -HeadRev HEAD -GitDir $Gd
                $viaTree   = Get-OgDiffChange -WorkingDirectory $Wd -Kind Range -BaseRev '' -HeadRev HEAD
                $viaGitDir.GitDir   | Should -Be $Gd
                $viaGitDir.RepoRoot | Should -Be $Gd
                $viaTree.GitDir     | Should -BeNullOrEmpty
                @($viaGitDir.Files.Path) | Should -Be @($viaTree.Files.Path)
                $viaGitDir.HeadCommit | Should -Be $viaTree.HeadCommit
            }
        }

        It 'resolves the diff tool in the first request with a work tree, else above a git-dir request''s missing folder' {
            $t = New-OdCommitTree
            $gone = Join-Path $t.Project 'libs\gone\deeper'
            InModuleScope og-framework -Parameters @{ Gone = $gone; Child = $t.Child; Project = $t.Project } {
                $gitDirOnly = [PSCustomObject]@{ Repo = 'gone'; WorkingDirectory = $Gone; Kind = 'Range'; GitDir = 'C:\x\.git\modules\gone' }
                $workTree   = [PSCustomObject]@{ Repo = 'child'; WorkingDirectory = $Child; Kind = 'Range' }
                Get-OgDirDiffToolDirectory -Request @($gitDirOnly, $workTree) | Should -Be $Child
                Get-OgDirDiffToolDirectory -Request @($gitDirOnly) | Should -Be (Join-Path $Project 'libs')
            }
        }

        It 'an empty commit gives no result and a warning' {
            $t = New-OdCommitTree
            Invoke-TestGit $t.Project commit -q --allow-empty -m 'empty' | Out-Null

            $r = @(Show-OgDiff -ProjectRoot $t.Project -Commit HEAD -WarningVariable warnings -WarningAction SilentlyContinue)

            $r.Count | Should -Be 0
            "$warnings" | Should -Match 'changed no file'
            $script:Launches.Count | Should -Be 0
        }

        Context 'od task 5b: -Pick picks a root commit in the picker and opens it through the -Commit path' {

            BeforeAll {
                # Two cascades in a row (the picker's row 1 is the FIRST, whose pins New-OdCascade recorded), then
                # -Extra root-only commits on top, which push the cascades further down the list.
                function New-OdPickTree {
                    param([int] $Extra = 0)
                    $t = New-OdCascade
                    Set-Content -LiteralPath (Join-Path $t.Nested 'README.md') -Value 'second cascade'
                    Add-OgChange -ProjectRoot $t.Project | Out-Null
                    New-OgCommit -Message 'second' -ProjectRoot $t.Project | Out-Null
                    for ($i = 0; $i -lt $Extra; $i++) {
                        Add-TestCommit -Dir $t.Project -File "extra$i.txt" -Message "extra $i"
                    }
                    # The picker's rows, newest first, by git's own first-parent log (the oracle).
                    $t.Rows = @((Invoke-TestGit $t.Project log --first-parent --format=%H HEAD) -split "`r?`n" | Where-Object { $_ })
                    Reset-OdPickCounters
                    $t
                }

                # The counting mocks below also see the FIXTURE's own calls (oggitadd/oggitcommit walk the tree), so
                # every fixture ends by zeroing them: the tests count only what Show-OgDiff -Pick does.
                function Reset-OdPickCounters {
                    $script:TreeCalls = 0
                    $script:RangeCalls.Clear()
                }

                function New-OdKey {
                    param([System.ConsoleKey] $Key, [char] $Char = [char] 0)
                    [System.ConsoleKeyInfo]::new($Char, $Key, $false, $false, $false)
                }

                # The module's own functions, captured BEFORE any mock: a counting mock below calls them through
                # these scriptblocks (bound to the module), so the real resolver and tree walk still run.
                $script:RealCommitRange = InModuleScope og-framework { ${function:Resolve-OgCommitRange} }
                $script:RealRepoTree    = InModuleScope og-framework { ${function:Resolve-OgRepoTree} }
            }

            BeforeEach {
                # 5a's pattern: every console seam is mocked; keys come from a queue (an exhausted queue throws).
                # Window 121 x 8: usable width 120, viewport 5 rows. A key is "waiting" only after 200 polls, so the
                # picker resolves every visible row it wants to before it reads the first key, and a loop that
                # would resolve forever fails on its counts instead of hanging.
                $script:PickKeys       = [System.Collections.Generic.Queue[System.ConsoleKeyInfo]]::new()
                $script:PickEvents     = [System.Collections.Generic.List[string]]::new()
                $script:PickFrames     = [System.Collections.Generic.List[object]]::new()
                $script:RangeCalls     = [System.Collections.Generic.List[object]]::new()
                $script:TreeCalls      = 0
                $script:PickPolls      = 0
                $script:PickCapability = [PSCustomObject]@{ InputRedirected = $false; OutputRedirected = $false; VirtualTerminal = $true }

                Mock -ModuleName og-framework Get-OgPickerConsoleCapability { $script:PickCapability }
                Mock -ModuleName og-framework Enter-OgPickerScreen { $script:PickEvents.Add('enter'); [PSCustomObject]@{ CursorVisible = $true } }
                Mock -ModuleName og-framework Exit-OgPickerScreen { $script:PickEvents.Add('exit') }
                Mock -ModuleName og-framework Get-OgPickerWindowSize { [PSCustomObject]@{ Width = 121; Height = 8 } }
                Mock -ModuleName og-framework Write-OgPickerScreen { $script:PickEvents.Add('draw'); $script:PickFrames.Add(@($Lines)) }
                Mock -ModuleName og-framework Test-OgPickerKeyAvailable { $script:PickPolls++; $script:PickPolls -gt 200 }
                Mock -ModuleName og-framework Read-OgPickerKey {
                    if ($script:PickKeys.Count -eq 0) { throw 'test key list exhausted' }
                    $script:PickEvents.Add('key')
                    $script:PickKeys.Dequeue()
                }

                # Counted, but real: every resolver call is recorded with its arguments, then the module's own
                # Resolve-OgCommitRange runs. The same for the tree walk.
                # The arguments are passed by name: a Pester 5 mock body sees the bound parameters as variables,
                # but its $PSBoundParameters is empty (measured: 'missing mandatory parameters: ProjectRoot').
                Mock -ModuleName og-framework Resolve-OgCommitRange {
                    $script:RangeCalls.Add([PSCustomObject]@{ Commit = $Commit; ProjectRoot = $ProjectRoot; RepoTree = $RepoTree })
                    & $script:RealCommitRange -ProjectRoot $ProjectRoot -Commit $Commit -RepoTree $RepoTree
                }
                Mock -ModuleName og-framework Resolve-OgRepoTree {
                    $script:TreeCalls++
                    & $script:RealRepoTree -ProjectRoot $ProjectRoot
                }

                # The Describe's launch mock, plus an event, so the tests see WHEN a launch happens.
                Mock -ModuleName og-framework Start-OgDiffToolProcess {
                    $script:Launches.Add($CommandLine)
                    $script:PickEvents.Add('launch')
                    [PSCustomObject]@{ Launched = $true; ExitCode = $null; Detail = $null }
                }

                function Push-OdKeys {
                    param([object[]] $List)
                    foreach ($k in $List) {
                        if ($k -is [string]) { $script:PickKeys.Enqueue((New-OdKey ([System.ConsoleKey]::Q) ([char] $k))) }
                        else { $script:PickKeys.Enqueue((New-OdKey $k)) }
                    }
                }
                $script:KDown  = [System.ConsoleKey]::DownArrow
                $script:KEnter = [System.ConsoleKey]::Enter
                $script:KEsc   = [System.ConsoleKey]::Escape
            }

            It 'Enter opens the PICKED commit exactly like -Commit: one run folder commit-(short sha), one launch per repo, the pinned sides' {
                $t = New-OdPickTree
                $t.Rows[1] | Should -Be $t.Sha        # precondition: row 1 is the first cascade
                $short = $t.Sha.Substring(0, 7)
                Push-OdKeys @($script:KDown, $script:KEnter)

                $r = @(Show-OgDiff -ProjectRoot $t.Project -Pick)

                # The -Commit results for the picked sha (od task 4b's cascade test, unchanged expectations).
                ($r | ForEach-Object Path)      | Should -Be @('', 'libs/child', 'libs/child/ext/nested')
                ($r | ForEach-Object Action)    | Should -Be @('opened', 'opened', 'opened')
                ($r | ForEach-Object FileCount) | Should -Be @(2, 2, 2)
                foreach ($x in $r) {
                    ($x.PSObject.Properties.Name -join ',') | Should -Be $script:OdResultFields
                    $x.Commit | Should -Be $t.Sha
                }
                @($r[0].BaseRev, $r[0].HeadRev) | Should -Be @($t.OldRoot, $t.Sha)
                @($r[1].BaseRev, $r[1].HeadRev) | Should -Be @($t.OldChild, $t.NewChild)
                @($r[2].BaseRev, $r[2].HeadRev) | Should -Be @($t.OldNested, $t.NewNested)

                $runs = @(Get-ChildItem -LiteralPath $script:RunRoot -Directory)
                $runs.Count   | Should -Be 1
                $runs[0].Name | Should -Match "^\d{8}-\d{6}-commit-$short$"
                $script:Launches.Count | Should -Be 3
                for ($i = 0; $i -lt 3; $i++) {
                    $r[$i].RunPath | Should -Be $runs[0].FullName
                    $script:Launches[$i] | Should -Be "`"C:\Tools\FakeTool.exe`" `"$($r[$i].BasePath)`" `"$($r[$i].HeadPath)`""
                    $repoFolder = @('project', 'child', 'nested')[$i]
                    Split-Path $r[$i].BasePath -Leaf | Should -Be ("$repoFolder base " + $r[$i].BaseRev.Substring(0, 7))
                    Split-Path $r[$i].HeadPath -Leaf | Should -Be ("$repoFolder head " + $r[$i].HeadRev.Substring(0, 7))
                }
                Get-OdFiles $r[2].HeadPath | Should -Be @('manual.txt', 'README.md')
                Get-OdText (Join-Path $r[2].HeadPath 'README.md') | Should -Be 'nested changed'   # not 'second cascade'

                # The diff runs only AFTER the picker left its screen: every launch comes after the 'exit'.
                $exitAt = $script:PickEvents.IndexOf('exit')
                $exitAt | Should -BeGreaterThan 0
                $script:PickEvents.IndexOf('launch') | Should -BeGreaterThan $exitAt
                @($script:PickEvents | Where-Object { $_ -eq 'exit' }).Count | Should -Be 1

                # The frame before Enter: the picked row is marked and shows 4a's summary; the detail line names
                # every repo the commit touched with its pinned base..head.
                $last = $script:PickFrames[$script:PickFrames.Count - 1]
                $last[2] | Should -BeLike "> $short  *"
                $last[2].Substring(29, 12) | Should -Be 'root +2'.PadRight(12)
                $last[1].Substring(29, 12) | Should -Be 'child +1'.PadRight(12)   # the second cascade: pins only in the root
                $detail = '  repos: project {0}..{1}, child {2}..{3}, nested {4}..{5}' -f `
                    $t.OldRoot.Substring(0, 7), $short, $t.OldChild.Substring(0, 7), $t.NewChild.Substring(0, 7),
                    $t.OldNested.Substring(0, 7), $t.NewNested.Substring(0, 7)
                $last[6] | Should -Be $detail
            }

            It 'resolves the tree ONCE and passes it, with the caller''s root, to every resolver call' {
                $t = New-OdPickTree
                Push-OdKeys @($script:KDown, $script:KEnter)

                $null = @(Show-OgDiff -ProjectRoot $t.Project -Pick)

                $script:TreeCalls | Should -Be 1
                # Rows 0..4 for the picker (all five on screen), then the picked commit for the -Commit path.
                @($script:RangeCalls | ForEach-Object Commit) | Should -Be @($t.Rows[0..4] + $t.Sha)
                foreach ($call in $script:RangeCalls) {
                    $call.ProjectRoot | Should -Be $t.Project
                    @($call.RepoTree | ForEach-Object Path) | Should -Be @('', 'libs/child', 'libs/child/ext/nested')
                }
            }

            It 'resolves lazily: only the rows on screen, not all -Count rows up front' {
                $t = New-OdPickTree -Extra 10
                $t.Rows.Count | Should -Be 15         # precondition: more rows than the 5-row viewport
                Push-OdKeys @($script:KEsc)

                $r = @(Show-OgDiff -ProjectRoot $t.Project -Pick -Count 30)

                $r.Count | Should -Be 0
                @($script:RangeCalls | ForEach-Object Commit) | Should -Be @($t.Rows[0..4])
                # Every visible row was resolved before the key was read: root-only commits show 'root'.
                $firstKey = $script:PickEvents.IndexOf('key')
                $frame = $script:PickFrames[@($script:PickEvents.GetRange(0, $firstKey) | Where-Object { $_ -eq 'draw' }).Count - 1]
                foreach ($line in $frame[1..5]) { $line.Substring(29, 12) | Should -Be 'root'.PadRight(12) }
            }

            It '-Count limits the list' {
                $t = New-OdPickTree -Extra 10
                Push-OdKeys @($script:KEsc)

                $null = @(Show-OgDiff -ProjectRoot $t.Project -Pick -Count 3)

                $script:PickFrames[0][0] | Should -BeLike '*(1/3)'
                @($script:RangeCalls | ForEach-Object Commit) | Should -Be @($t.Rows[0..2])
            }

            It '<Name> cancels: nothing is returned, exported or launched, and the screen is restored' -ForEach @(
                @{ Name = 'Esc'; Key = [System.ConsoleKey]::Escape }
                @{ Name = 'q'; Key = 'q' }
            ) {
                $t = New-OdPickTree
                Mock -ModuleName og-framework Open-OgDirDiffSet { throw 'nothing may open on cancel' }
                Push-OdKeys @($script:KDown, $Key)

                $r = @(Show-OgDiff -ProjectRoot $t.Project -Pick)

                $r.Count | Should -Be 0
                $script:Launches.Count | Should -Be 0
                Should -Invoke -ModuleName og-framework Open-OgDirDiffSet -Times 0
                Test-Path -LiteralPath $script:RunRoot | Should -BeFalse
                $script:PickEvents[$script:PickEvents.Count - 1] | Should -Be 'exit'
                # Only the picker's own resolutions ran; the cancelled pick resolved nothing more.
                @($script:RangeCalls | ForEach-Object Commit) | Should -Be @($t.Rows[0..4])
            }

            It 'surfaces the picker''s console error unchanged (<Why>), before any git command, the tree walk included' -ForEach @(
                @{ Why = 'its input is redirected';  Cap = @{ InputRedirected = $true;  OutputRedirected = $false; VirtualTerminal = $true } }
                @{ Why = 'its output is redirected'; Cap = @{ InputRedirected = $false; OutputRedirected = $true;  VirtualTerminal = $true } }
            ) {
                $t = New-OdCommitTree
                Reset-OdPickCounters
                $script:PickCapability = [PSCustomObject] $Cap
                Mock -ModuleName og-framework Invoke-Git { throw 'no git command may run' }
                Mock -ModuleName og-framework Invoke-OgGitPlumbing { throw 'no git command may run' }
                Mock -ModuleName og-framework Get-OgPickerRows { throw 'the picker must not list' }

                { Show-OgDiff -ProjectRoot $t.Project -Pick } |
                    Should -Throw -ExpectedMessage "The commit picker needs an interactive console, but $Why. Name the commit instead: oggitdiff -Commit <sha>"

                $script:TreeCalls | Should -Be 0
                Should -Invoke -ModuleName og-framework Invoke-Git -Times 0
                Should -Invoke -ModuleName og-framework Invoke-OgGitPlumbing -Times 0
                Should -Invoke -ModuleName og-framework Get-OgPickerRows -Times 0
                Should -Invoke -ModuleName og-framework Enter-OgPickerScreen -Times 0
                Should -Invoke -ModuleName og-framework Read-OgPickerKey -Times 0
                $script:Launches.Count | Should -Be 0
            }

            It '-Pick -PerFile runs git difftool with the pinned old and new for the PICKED commit in each touched repo, and never exports' {
                $t = New-OdPickTree
                $script:Difftool = [System.Collections.Generic.List[object]]::new()
                Mock -ModuleName og-framework Invoke-Git -ParameterFilter { $Arguments -contains 'difftool' } {
                    $script:Difftool.Add([PSCustomObject]@{ Dir = $WorkingDirectory; Args = @($Arguments) })
                    $script:PickEvents.Add('difftool')
                    [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
                }
                Mock -ModuleName og-framework Open-OgDirDiffSet { throw 'no directory diff under -PerFile' }
                Push-OdKeys @($script:KDown, $script:KEnter)

                $r = @(Show-OgDiff -ProjectRoot $t.Project -Pick -PerFile)

                ($r | ForEach-Object Action) | Should -Be @('opened', 'opened', 'opened')
                $expected = @(
                    @($t.Project, $t.OldRoot, $t.Sha),
                    @($t.Child, $t.OldChild, $t.NewChild),
                    @($t.Nested, $t.OldNested, $t.NewNested))
                $script:Difftool.Count | Should -Be 3
                for ($i = 0; $i -lt 3; $i++) {
                    $script:Difftool[$i].Dir  | Should -Be $expected[$i][0]
                    $script:Difftool[$i].Args | Should -Be @('difftool', '--no-prompt', $expected[$i][1], $expected[$i][2])
                    $r[$i].Commit  | Should -Be $t.Sha
                    $r[$i].RunPath | Should -BeNullOrEmpty
                }
                Should -Invoke -ModuleName og-framework Open-OgDirDiffSet -Times 0
                Test-Path -LiteralPath $script:RunRoot | Should -BeFalse
                $script:PickEvents.IndexOf('difftool') | Should -BeGreaterThan $script:PickEvents.IndexOf('exit')
            }

            It 'a commit the resolver cannot resolve shows ! and the picker still opens another commit' {
                $t = New-OdPickTree
                $script:Broken = $t.Rows[0]
                Mock -ModuleName og-framework Resolve-OgCommitRange {
                    $script:RangeCalls.Add([PSCustomObject]@{ Commit = $Commit; ProjectRoot = $ProjectRoot; RepoTree = $RepoTree })
                    if ($Commit -eq $script:Broken) { throw 'corrupt object (test)' }
                    & $script:RealCommitRange -ProjectRoot $ProjectRoot -Commit $Commit -RepoTree $RepoTree
                }
                Push-OdKeys @($script:KDown, $script:KEnter)

                $r = @(Show-OgDiff -ProjectRoot $t.Project -Pick)

                ($r | ForEach-Object Action) | Should -Be @('opened', 'opened', 'opened')
                ($r | ForEach-Object Commit | Select-Object -Unique) | Should -Be $t.Sha
                $last = $script:PickFrames[$script:PickFrames.Count - 1]
                $last[1].Substring(29, 12) | Should -Be '!'.PadRight(12)
                $last[2].Substring(29, 12) | Should -Be 'root +2'.PadRight(12)
                # The broken commit was tried once, not on every redraw.
                @($script:RangeCalls | Where-Object Commit -eq $script:Broken).Count | Should -Be 1
            }

            It 'binds -Pick only alone: with -Commit, -Staged or -Against it is a binding error, and -Count needs -Pick' {
                $t = New-OdCommitTree
                { Show-OgDiff -ProjectRoot $t.Project -Pick -Commit HEAD } | Should -Throw
                { Show-OgDiff -ProjectRoot $t.Project -Pick -Staged } | Should -Throw
                { Show-OgDiff -ProjectRoot $t.Project -Pick -Against main } | Should -Throw
                { Show-OgDiff -ProjectRoot $t.Project -Commit HEAD -Count 5 } | Should -Throw
                { Show-OgDiff -ProjectRoot $t.Project -Pick -Count 0 } | Should -Throw
                Should -Invoke -ModuleName og-framework Enter-OgPickerScreen -Times 0
                $script:Launches.Count | Should -Be 0
                Test-Path -LiteralPath $script:RunRoot | Should -BeFalse
            }
        }
    }
}

