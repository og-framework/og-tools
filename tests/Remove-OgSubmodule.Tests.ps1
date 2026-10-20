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

Describe 'Remove-OgSubmodule (oggitsubrm)' {

    Context 'Removal of a clean, pushed submodule' {
        It 'stages the removal, cleans .git/modules/<name>, and does not commit' {
            $p          = New-TestProject
            $parentHead = Invoke-TestGit $p.Project rev-parse HEAD
            # The fixture names the submodule 'child-module' (path libs/child): the stored
            # repo lives under the NAME.
            $moduleDir  = Join-Path $p.Project '.git/modules/child-module'
            Test-Path $moduleDir | Should -BeTrue

            $r = Remove-OgSubmodule -Path 'libs/child' -ProjectRoot $p.Project

            $r.Action | Should -Be 'removed'
            $r.Owner  | Should -Be (Split-Path $p.Project -Leaf)
            $staged = Get-TestStaged -Dir $p.Project
            $staged | Should -Contain "D`tlibs/child"
            $staged | Should -Contain "M`t.gitmodules"
            (Get-Content -Raw (Join-Path $p.Project '.gitmodules')) | Should -Not -Match 'child-module'
            Test-Path $moduleDir                               | Should -BeFalse
            Test-Path (Join-Path $p.Project 'libs/child')      | Should -BeFalse
            (& git -C $p.Project config --get submodule.child-module.url) | Should -BeNullOrEmpty
            Invoke-TestGit $p.Project rev-parse HEAD           | Should -Be $parentHead
        }

        It 'removes a nested submodule from its owner (itself a submodule) and cleans the owner''s git dir' {
            $p      = New-TestProject
            $child  = Join-Path $p.Project 'libs/child'
            $newUrl = New-TestRemote -Root $p.Remotes -Name 'jolt'
            Add-OgSubmodule -Url $newUrl -Path 'libs/child/ext/jolt' -ProjectRoot $p.Project | Out-Null
            New-OgCommit -Message 'add jolt' -ProjectRoot $p.Project | Out-Null
            $childGitDir = Invoke-TestGit $child rev-parse --absolute-git-dir
            $nestedStore = Join-Path $childGitDir 'modules/ext/jolt'
            Test-Path $nestedStore | Should -BeTrue

            $r = Remove-OgSubmodule -Path 'libs/child/ext/jolt' -ProjectRoot $p.Project

            $r.Action | Should -Be 'removed'
            $r.Owner  | Should -Be 'libs/child'
            Get-TestStaged -Dir $child | Should -Contain "D`text/jolt"
            Test-Path $nestedStore                   | Should -BeFalse
            Test-Path (Join-Path $childGitDir 'modules/ext') | Should -BeFalse   # emptied parent folder removed
            Test-Path (Join-Path $child 'ext/jolt')  | Should -BeFalse
        }
    }

    Context 'Safety guard' {
        It 'refuses when the submodule has uncommitted changes, and changes nothing' {
            $p     = New-TestProject
            $child = Join-Path $p.Project 'libs/child'
            Set-Content -LiteralPath (Join-Path $child 'README.md') -Value 'edited'

            { Remove-OgSubmodule -Path 'libs/child' -ProjectRoot $p.Project -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*uncommitted changes*'

            Test-Path (Join-Path $child '.git')                 | Should -BeTrue
            Test-Path (Join-Path $p.Project '.git/modules/child-module') | Should -BeTrue
            Get-TestStaged -Dir $p.Project                      | Should -BeNullOrEmpty
        }

        It 'refuses when the submodule has only an untracked file' {
            $p     = New-TestProject
            $child = Join-Path $p.Project 'libs/child'
            Set-Content -LiteralPath (Join-Path $child 'notes.txt') -Value 'mine'

            { Remove-OgSubmodule -Path 'libs/child' -ProjectRoot $p.Project -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*uncommitted changes*'
            Test-Path (Join-Path $child 'notes.txt') | Should -BeTrue
        }

        It 'refuses when the submodule has unpushed commits, and changes nothing' {
            $p     = New-TestProject
            $child = Join-Path $p.Project 'libs/child'
            Add-TestCommit -Dir $child -File 'local.txt' -Message 'local only'

            { Remove-OgSubmodule -Path 'libs/child' -ProjectRoot $p.Project -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*1 unpushed commit*'

            Test-Path (Join-Path $child 'local.txt') | Should -BeTrue
            Get-TestStaged -Dir $p.Project           | Should -BeNullOrEmpty
        }

        It 'refuses when a submodule NESTED inside the target has unpushed work' {
            $p      = New-TestProject
            $child  = Join-Path $p.Project 'libs/child'
            $newUrl = New-TestRemote -Root $p.Remotes -Name 'jolt'
            Add-OgSubmodule -Url $newUrl -Path 'libs/child/ext/jolt' -ProjectRoot $p.Project | Out-Null
            Add-TestCommit -Dir (Join-Path $child 'ext/jolt') -File 'deep.txt' -Message 'deep local'

            { Remove-OgSubmodule -Path 'libs/child' -ProjectRoot $p.Project -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*libs/child/ext/jolt*unpushed*'
        }

        It '-Force removes despite unpushed commits' {
            $p     = New-TestProject
            $child = Join-Path $p.Project 'libs/child'
            Add-TestCommit -Dir $child -File 'local.txt' -Message 'local only'

            $r = Remove-OgSubmodule -Path 'libs/child' -Force -ProjectRoot $p.Project

            $r.Action | Should -Be 'removed'
            Get-TestStaged -Dir $p.Project | Should -Contain "D`tlibs/child"
        }

        It 'refuses a path that is not a declared submodule' {
            $p = New-TestProject
            { Remove-OgSubmodule -Path 'libs/nothing' -ProjectRoot $p.Project -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*not a submodule*'
        }
    }

    Context '-WhatIf' {
        It 'runs the guard, reports the plan, and changes nothing' {
            $p = New-TestProject

            $r = Remove-OgSubmodule -Path 'libs/child' -ProjectRoot $p.Project -WhatIf

            $r.Action | Should -Be 'would-remove'
            $r.Branch | Should -Be 'main'
            Test-Path (Join-Path $p.Project 'libs/child/.git')           | Should -BeTrue
            Test-Path (Join-Path $p.Project '.git/modules/child-module') | Should -BeTrue
            Get-TestStaged -Dir $p.Project                               | Should -BeNullOrEmpty
        }
    }
}
