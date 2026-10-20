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

    # Creates a throwaway single git repo on 'main' with one commit. Returns its path.
    function New-TestGitRepo {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ogmerge-" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        git-in $dir init -b main | Out-Null
        git-in $dir config user.email 'test@example.com' | Out-Null
        git-in $dir config user.name  'Test' | Out-Null
        git-in $dir config commit.gpgsign false | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'file.txt') -Value "base`n" -NoNewline
        git-in $dir add . | Out-Null
        git-in $dir commit -m 'initial' | Out-Null
        $dir
    }
}

Describe 'Merge-OgToMain (single-repo behaviours)' {

    Context 'Happy path' {
        It 'merges a feature branch into main and advances main' {
            $repo = New-TestGitRepo
            try {
                git-in $repo checkout -b feat/x | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'feature.txt') -Value "hi`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'feature work' | Out-Null
                git-in $repo checkout main | Out-Null
                $mainBefore = git-in $repo rev-parse HEAD

                $r = Merge-OgToMain -Branch feat/x -ProjectRoot $repo

                $r.Action | Should -Be 'merged'
                (git-in $repo rev-parse HEAD)               | Should -Not -Be $mainBefore
                Test-Path (Join-Path $repo 'feature.txt')   | Should -BeTrue
                git-in $repo rev-parse --abbrev-ref HEAD    | Should -Be 'main'
                # --no-ff => a merge commit (2 parents)
                (git-in $repo rev-list --parents -n 1 HEAD).Split(' ').Count | Should -Be 3
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It 'reports already-merged on a second run (idempotent)' {
            $repo = New-TestGitRepo
            try {
                git-in $repo checkout -b feat/x | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'feature.txt') -Value "hi`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'feature work' | Out-Null
                git-in $repo checkout main | Out-Null

                Merge-OgToMain -Branch feat/x -ProjectRoot $repo | Out-Null
                $again = Merge-OgToMain -Branch feat/x -ProjectRoot $repo
                $again.Action | Should -Be 'already-merged'
            } finally { Remove-Item -Recurse -Force $repo }
        }
    }

    Context 'Guards and skips' {
        It 'reports no-branch when the feature branch is absent' {
            $repo = New-TestGitRepo
            try {
                $r = Merge-OgToMain -Branch does/not-exist -ProjectRoot $repo
                $r.Action | Should -Be 'no-branch'
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It 'refuses to merge with a dirty tracked working tree (and merges nothing)' {
            $repo = New-TestGitRepo
            try {
                git-in $repo checkout -b feat/x | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'feature.txt') -Value "hi`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'feature work' | Out-Null
                git-in $repo checkout main | Out-Null
                $mainBefore = git-in $repo rev-parse HEAD
                # dirty the tracked file
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "dirty`n" -NoNewline

                { Merge-OgToMain -Branch feat/x -ProjectRoot $repo -ErrorAction Stop } | Should -Throw
                (git-in $repo rev-parse HEAD) | Should -Be $mainBefore   # untouched
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It '-Force overrides the dirty guard (unstaged edit to a file the merge does not touch)' {
            $repo = New-TestGitRepo
            try {
                git-in $repo checkout -b feat/x | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'feature.txt') -Value "hi`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'feature work' | Out-Null
                git-in $repo checkout main | Out-Null
                # Dirty a TRACKED file the feature branch does NOT modify. The guard would refuse,
                # but git merge can still complete (it only writes feature.txt). -Force skips the guard;
                # git merge itself does not refuse because file.txt is not a merged path.
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "unstaged-dirty`n" -NoNewline

                $r = Merge-OgToMain -Branch feat/x -ProjectRoot $repo -Force
                $r.Action                                     | Should -Be 'merged'
                Test-Path (Join-Path $repo 'feature.txt')     | Should -BeTrue
                (Get-Content -Raw (Join-Path $repo 'file.txt')) | Should -Match 'unstaged-dirty'  # preserved
            } finally { Remove-Item -Recurse -Force $repo }
        }

        It '-WhatIf previews without merging' {
            $repo = New-TestGitRepo
            try {
                git-in $repo checkout -b feat/x | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'feature.txt') -Value "hi`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'feature work' | Out-Null
                git-in $repo checkout main | Out-Null
                $mainBefore = git-in $repo rev-parse HEAD

                $r = Merge-OgToMain -Branch feat/x -ProjectRoot $repo -WhatIf
                $r.Action | Should -Be 'would-merge'
                (git-in $repo rev-parse HEAD) | Should -Be $mainBefore   # untouched
            } finally { Remove-Item -Recurse -Force $repo }
        }
    }

    Context 'Conflict handling' {
        It 'aborts on conflict, restores the tree, and reports conflict' {
            $repo = New-TestGitRepo
            try {
                # feature edits file.txt one way...
                git-in $repo checkout -b feat/x | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "feature-change`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'feat edit' | Out-Null
                # ...main edits the same line differently
                git-in $repo checkout main | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Value "main-change`n" -NoNewline
                git-in $repo add . | Out-Null
                git-in $repo commit -m 'main edit' | Out-Null
                $mainBefore = git-in $repo rev-parse HEAD

                $r = Merge-OgToMain -Branch feat/x -ProjectRoot $repo -ErrorAction SilentlyContinue
                $r.Action                       | Should -Be 'conflict'
                $r.Conflicts                     | Should -Contain 'file.txt'
                (git-in $repo rev-parse HEAD)    | Should -Be $mainBefore      # merge --abort restored it
                # no in-progress merge left behind
                Test-Path (Join-Path $repo '.git\MERGE_HEAD') | Should -BeFalse
            } finally { Remove-Item -Recurse -Force $repo }
        }
    }
}

Describe 'Merge-OgToMain (post-merge submodule init)' {
    BeforeAll {
        . "$PSScriptRoot\OgGitTestHelpers.ps1"
        Enter-OgGitSandbox -Root (Join-Path $TestDrive 'sandbox')
    }
    AfterAll {
        Exit-OgGitSandbox
    }

    It 'initialises a submodule that is new on main after the cascade and reports it' {
        $p      = New-TestProject
        $newUrl = New-TestRemote -Root $p.Remotes -Name 'newlib'

        # The feature branch adds a submodule; this clone then forgets it locally (as a
        # clone that never initialised it would be), so after the merge it is declared on
        # main but not on disk.
        Invoke-TestGit $p.Project checkout -q -b feat/x | Out-Null
        Invoke-TestGit $p.Project submodule add -q -- $newUrl libs/newlib | Out-Null
        Invoke-TestGit $p.Project commit -q -m 'add newlib' | Out-Null
        Invoke-TestGit $p.Project submodule deinit -q -f -- libs/newlib | Out-Null
        Remove-Item -LiteralPath (Join-Path $p.Project '.git/modules/libs/newlib') -Recurse -Force
        Invoke-TestGit $p.Project checkout -q main | Out-Null

        $results = @(Merge-OgToMain -Branch feat/x -ProjectRoot $p.Project -WarningAction SilentlyContinue)

        ($results | Where-Object Path -eq '').Action | Should -Be 'merged'
        $init = $results | Where-Object Path -eq 'libs/newlib'
        $init.Action | Should -Be 'initialised'
        $init.Branch | Should -Be 'main'
        $init.ToSha  | Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $p.Project 'libs/newlib/.git')     | Should -BeTrue
        Test-Path (Join-Path $p.Project 'libs/newlib/README.md') | Should -BeTrue
    }

    It 'does not initialise anything when the cascade halts' {
        $p      = New-TestProject
        $newUrl = New-TestRemote -Root $p.Remotes -Name 'newlib'
        Invoke-TestGit $p.Project checkout -q -b feat/x | Out-Null
        Invoke-TestGit $p.Project submodule add -q -- $newUrl libs/newlib | Out-Null
        Set-Content -LiteralPath (Join-Path $p.Project 'clash.txt') -Value 'feature'
        Invoke-TestGit $p.Project add clash.txt | Out-Null
        Invoke-TestGit $p.Project commit -q -m 'add newlib + clash' | Out-Null
        Invoke-TestGit $p.Project submodule deinit -q -f -- libs/newlib | Out-Null
        Remove-Item -LiteralPath (Join-Path $p.Project '.git/modules/libs/newlib') -Recurse -Force
        Invoke-TestGit $p.Project checkout -q main | Out-Null
        Add-TestCommit -Dir $p.Project -File 'clash.txt' -Content 'main' -Message 'main clash'

        $results = @(Merge-OgToMain -Branch feat/x -ProjectRoot $p.Project -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)

        ($results | Where-Object Path -eq '').Action        | Should -Be 'conflict'
        ($results | Where-Object Path -eq 'libs/newlib')    | Should -BeNullOrEmpty
    }
}
