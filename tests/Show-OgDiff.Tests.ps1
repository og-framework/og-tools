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
}

Describe 'Show-OgDiff' {

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

        It 'reports opened for an unstaged edit, invoking difftool with plain --no-prompt (no range)' {
            $repo = New-TestGitRepo
            try {
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "dirty`n" -NoNewline

                Mock -ModuleName og-framework -CommandName Invoke-Git `
                    -ParameterFilter { $Arguments -contains 'difftool' } `
                    -MockWith {
                        $script:capturedArgs = $Arguments
                        [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
                    }

                $r = Show-OgDiff -ProjectRoot $repo
                $r.Action | Should -Be 'opened'
                $script:capturedArgs | Should -Be @('difftool', '--no-prompt')
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

        It 'a staged edit is reported opened by -Staged, with --cached passed to difftool' {
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

                $r = Show-OgDiff -ProjectRoot $repo -Staged
                $r.Action | Should -Be 'opened'
                $script:capturedArgs | Should -Contain '--cached'
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It '-DirDiff without -Against still delegates to plain git difftool --dir-diff (item 2 only changes the -Against combo)' {
            $repo = New-TestGitRepo
            try {
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "dirty`n" -NoNewline

                Mock -ModuleName og-framework -CommandName Invoke-Git `
                    -ParameterFilter { $Arguments -contains 'difftool' } `
                    -MockWith {
                        $script:capturedArgs = $Arguments
                        [PSCustomObject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; WorkingDirectory = $WorkingDirectory }
                    }

                $r = Show-OgDiff -ProjectRoot $repo -DirDiff
                $r.Action   | Should -Be 'opened'
                $r.BasePath | Should -BeNullOrEmpty
                $r.HeadPath | Should -BeNullOrEmpty
                $script:capturedArgs | Should -Be @('difftool', '--no-prompt', '--dir-diff')
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

                $r = Show-OgDiff -ProjectRoot $repo -Against main
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

                # Exported base = merge-base: neither branch's own commit is present.
                Test-Path -LiteralPath (Join-Path $r.BasePath 'main-only.txt') | Should -Be $false
                Test-Path -LiteralPath (Join-Path $r.BasePath 'feat-only.txt') | Should -Be $false
                Test-Path -LiteralPath (Join-Path $r.BasePath 'file.txt')      | Should -Be $true

                # Exported head = HEAD (feat): feat's own commit is present, main's is not.
                Test-Path -LiteralPath (Join-Path $r.HeadPath 'feat-only.txt') | Should -Be $true
                Test-Path -LiteralPath (Join-Path $r.HeadPath 'main-only.txt') | Should -Be $false
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
}

