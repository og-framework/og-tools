# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force
    . "$PSScriptRoot\OgGitTestHelpers.ps1"
    Enter-OgGitSandbox -Root (Join-Path $TestDrive 'sandbox')
}

AfterAll {
    Exit-OgGitSandbox
}

Describe 'Add-OgSubmodule (oggitsubadd)' {

    Context 'Success' {
        It 'adds a submodule inside the owning repo, on the owner''s feature branch, staged but not committed' {
            $p     = New-TestProject
            $child = Join-Path $p.Project 'libs/child'
            Invoke-TestGit $p.Project checkout -q -b feat/x | Out-Null
            Invoke-TestGit $child     checkout -q -b feat/x | Out-Null
            $newUrl     = New-TestRemote -Root $p.Remotes -Name 'jolt'
            $childHead  = Invoke-TestGit $child rev-parse HEAD
            $parentHead = Invoke-TestGit $p.Project rev-parse HEAD

            $r = Add-OgSubmodule -Url $newUrl -Path 'libs/child/ext/jolt' -ProjectRoot $p.Project

            $r.Action | Should -Be 'added'
            $r.Owner  | Should -Be 'libs/child'
            $r.Branch | Should -Be 'feat/x'

            # The submodule exists and is on the branch, created from its main.
            $jolt = Join-Path $child 'ext/jolt'
            Test-Path (Join-Path $jolt '.git')                 | Should -BeTrue
            Invoke-TestGit $jolt rev-parse --abbrev-ref HEAD   | Should -Be 'feat/x'
            Invoke-TestGit $jolt rev-parse HEAD                | Should -Be (Invoke-TestGit $jolt rev-parse origin/main)

            # .gitmodules and the gitlink are staged in the OWNER (the child), not the parent.
            $staged = Get-TestStaged -Dir $child
            $staged | Should -Contain "A`t.gitmodules"
            $staged | Should -Contain "A`text/jolt"
            (Invoke-TestGit $child ls-files -s -- ext/jolt) | Should -Match ('^160000 ' + (Invoke-TestGit $jolt rev-parse HEAD))
            Invoke-TestGit $child config -f .gitmodules --get submodule.ext/jolt.url | Should -Be $newUrl

            # Nothing committed anywhere.
            Invoke-TestGit $child rev-parse HEAD     | Should -Be $childHead
            Invoke-TestGit $p.Project rev-parse HEAD | Should -Be $parentHead
        }

        It 'is completed by oggitcommit (pin cascade) and oggitpush (new branch pushed with -u)' {
            $p     = New-TestProject
            $child = Join-Path $p.Project 'libs/child'
            Invoke-TestGit $p.Project checkout -q -b feat/x | Out-Null
            Invoke-TestGit $child     checkout -q -b feat/x | Out-Null
            $newUrl = New-TestRemote -Root $p.Remotes -Name 'jolt'

            Add-OgSubmodule -Url $newUrl -Path 'libs/child/ext/jolt' -ProjectRoot $p.Project | Out-Null
            $commits = @(New-OgCommit -Message 'Add jolt submodule' -ProjectRoot $p.Project)
            ($commits | Where-Object Path -eq 'libs/child').Action | Should -Be 'committed'
            ($commits | Where-Object Path -eq '').Action           | Should -Be 'committed'
            # The parent's pin now records the child's new commit.
            (Invoke-TestGit $p.Project ls-tree HEAD -- libs/child) | Should -Match (Invoke-TestGit $child rev-parse HEAD)

            $pushes = @(Push-OgFramework -ProjectRoot $p.Project)
            ($pushes | Where-Object Path -eq 'libs/child/ext/jolt').Action | Should -Be 'pushed'
            $jolt = Join-Path $child 'ext/jolt'
            Invoke-TestGit $jolt rev-parse --abbrev-ref 'feat/x@{upstream}' | Should -Be 'origin/feat/x'
            (& git -C $newUrl rev-parse --verify --quiet refs/heads/feat/x) | Should -Not -BeNullOrEmpty
        }

        It 'puts the submodule on -Branch when given, even if the owner is on main' {
            $p      = New-TestProject
            $newUrl = New-TestRemote -Root $p.Remotes -Name 'lib2'

            $r = Add-OgSubmodule -Url $newUrl -Path 'ext/lib2' -Branch 'feat/y' -ProjectRoot $p.Project

            $r.Action | Should -Be 'added'
            $r.Owner  | Should -Be (Split-Path $p.Project -Leaf)
            Invoke-TestGit (Join-Path $p.Project 'ext/lib2') rev-parse --abbrev-ref HEAD | Should -Be 'feat/y'
            Get-TestStaged -Dir $p.Project | Should -Contain "A`text/lib2"
        }

        It 'leaves the submodule on main when the owner is on main and no -Branch is given' {
            $p      = New-TestProject
            $newUrl = New-TestRemote -Root $p.Remotes -Name 'lib3'

            $r = Add-OgSubmodule -Url $newUrl -Path 'ext\lib3' -ProjectRoot $p.Project

            $r.Branch | Should -Be 'main'
            $r.Path   | Should -Be 'ext/lib3'
            Invoke-TestGit (Join-Path $p.Project 'ext/lib3') rev-parse --abbrev-ref HEAD | Should -Be 'main'
        }
    }

    Context 'Refusals' {
        It 'refuses when the remote has no main branch (an empty repo) and changes nothing' {
            $p        = New-TestProject
            $emptyUrl = New-TestRemote -Root $p.Remotes -Name 'empty' -Empty

            { Add-OgSubmodule -Url $emptyUrl -Path 'ext/empty' -ProjectRoot $p.Project -ErrorAction Stop } |
                Should -Throw -ExpectedMessage "*has no 'main' branch*initial commit*"

            Test-Path (Join-Path $p.Project 'ext/empty')   | Should -BeFalse
            Test-Path (Join-Path $p.Project '.gitmodules') | Should -BeTrue
            Invoke-TestGit $p.Project status --porcelain    | Should -BeNullOrEmpty
        }

        It 'refuses when only a branch ending in /main exists (exact ref match)' {
            $p   = New-TestProject
            $url = New-TestRemote -Root $p.Remotes -Name 'oddmain' -Empty
            $seed = Join-Path $p.Root 'seed-oddmain'
            Invoke-TestGit $p.Root init -q -b release/main $seed | Out-Null
            Add-TestCommit -Dir $seed -Message 'initial'
            Invoke-TestGit $seed push -q $url release/main | Out-Null

            { Add-OgSubmodule -Url $url -Path 'ext/odd' -ProjectRoot $p.Project -ErrorAction Stop } |
                Should -Throw -ExpectedMessage "*has no 'main' branch*"
            Test-Path (Join-Path $p.Project 'ext/odd') | Should -BeFalse
        }

        It 'refuses a path that is already a submodule' {
            $p = New-TestProject
            { Add-OgSubmodule -Url $p.ChildUrl -Path 'libs/child' -ProjectRoot $p.Project -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*already declared as a submodule*'
        }
    }

    Context '-WhatIf' {
        It 'reports the plan and changes nothing' {
            $p     = New-TestProject
            $child = Join-Path $p.Project 'libs/child'
            Invoke-TestGit $child checkout -q -b feat/x | Out-Null
            $newUrl = New-TestRemote -Root $p.Remotes -Name 'jolt'

            $r = Add-OgSubmodule -Url $newUrl -Path 'libs/child/ext/jolt' -ProjectRoot $p.Project -WhatIf

            $r.Action | Should -Be 'would-add'
            $r.Owner  | Should -Be 'libs/child'
            $r.Branch | Should -Be 'feat/x'
            Test-Path (Join-Path $child 'ext/jolt')    | Should -BeFalse
            Test-Path (Join-Path $child '.gitmodules') | Should -BeFalse
            Invoke-TestGit $child status --porcelain    | Should -BeNullOrEmpty
        }

        It 'still runs the remote main check' {
            $p        = New-TestProject
            $emptyUrl = New-TestRemote -Root $p.Remotes -Name 'empty' -Empty
            { Add-OgSubmodule -Url $emptyUrl -Path 'ext/empty' -ProjectRoot $p.Project -WhatIf -ErrorAction Stop } |
                Should -Throw -ExpectedMessage "*has no 'main' branch*"
        }
    }
}
