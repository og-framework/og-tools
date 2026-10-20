# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force
    . "$PSScriptRoot\OgGitTestHelpers.ps1"
    Enter-OgGitSandbox -Root (Join-Path $TestDrive 'sandbox')

    # A second working clone of the fixture's parent remote ("another machine").
    function New-SecondClone {
        param([hashtable] $P)
        $other = Join-Path $P.Root ('other-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 6))
        Invoke-TestGit $P.Root clone -q --recurse-submodules $P.ParentUrl $other | Out-Null
        Invoke-TestGit (Join-Path $other 'libs/child') checkout -q main | Out-Null
        $other
    }
}

AfterAll {
    Exit-OgGitSandbox
}

Describe 'Sync-OgFramework (oggitsync)' {

    Context 'Initialising missing submodules' {
        It 'initialises a submodule that is declared but missing on disk, then syncs it to main' {
            $p     = New-TestProject -NoRecurse
            $child = Join-Path $p.Project 'libs/child'
            Test-Path (Join-Path $child '.git') | Should -BeFalse

            $results = @(Sync-OgFramework -ProjectRoot $p.Project -WarningAction SilentlyContinue)

            ($results | Where-Object { $_.Path -eq 'libs/child' -and $_.Action -eq 'initialised' }) | Should -Not -BeNullOrEmpty
            Test-Path (Join-Path $child '.git')                 | Should -BeTrue
            Invoke-TestGit $child rev-parse --abbrev-ref HEAD   | Should -Be 'main'
        }

        It 'initialises a submodule that another clone added and pushed (it arrives with the parent''s merge)' {
            $p     = New-TestProject
            $other = New-SecondClone -P $p
            $newUrl = New-TestRemote -Root $p.Remotes -Name 'newlib'
            Invoke-TestGit $other submodule add -q -- $newUrl libs/newlib | Out-Null
            Invoke-TestGit $other commit -q -m 'add newlib' | Out-Null
            Invoke-TestGit $other push -q origin main | Out-Null

            $results = @(Sync-OgFramework -ProjectRoot $p.Project)

            ($results | Where-Object Path -eq '').Action | Should -Be 'fast-forwarded'
            ($results | Where-Object { $_.Path -eq 'libs/newlib' -and $_.Action -eq 'initialised' }) | Should -Not -BeNullOrEmpty
            $newlib = Join-Path $p.Project 'libs/newlib'
            Test-Path (Join-Path $newlib '.git')                | Should -BeTrue
            Invoke-TestGit $newlib rev-parse --abbrev-ref HEAD  | Should -Be 'main'
            Test-Path (Join-Path $newlib 'README.md')           | Should -BeTrue
        }

        It '-WhatIf reports would-init and initialises nothing' {
            $p     = New-TestProject -NoRecurse
            $child = Join-Path $p.Project 'libs/child'

            $results = @(Sync-OgFramework -ProjectRoot $p.Project -WhatIf -WarningAction SilentlyContinue)

            ($results | Where-Object Path -eq 'libs/child').Action | Should -Contain 'would-init'
            Test-Path (Join-Path $child '.git') | Should -BeFalse
        }
    }

    Context '-Branch mode' {
        It 'checks out and fast-forwards the branch in every repo whose origin has it; others are left alone' {
            $p     = New-TestProject
            $other = New-SecondClone -P $p
            $otherChild = Join-Path $other 'libs/child'
            # Only the CHILD gets feat/x on origin.
            Invoke-TestGit $otherChild checkout -q -b feat/x | Out-Null
            Add-TestCommit -Dir $otherChild -File 'feature.txt' -Message 'feature'
            Invoke-TestGit $otherChild push -q -u origin feat/x | Out-Null
            $featTip    = Invoke-TestGit $otherChild rev-parse --short HEAD
            $parentHead = Invoke-TestGit $p.Project rev-parse --short HEAD

            $results = @(Sync-OgFramework -ProjectRoot $p.Project -Branch feat/x)

            $childResult = $results | Where-Object Path -eq 'libs/child'
            $childResult.Action | Should -Be 'fast-forwarded'
            $childResult.ToSha  | Should -Be $featTip
            $child = Join-Path $p.Project 'libs/child'
            Invoke-TestGit $child rev-parse --abbrev-ref HEAD | Should -Be 'feat/x'
            Test-Path (Join-Path $child 'feature.txt')        | Should -BeTrue

            ($results | Where-Object Path -eq '').Action        | Should -Be 'no-branch'
            Invoke-TestGit $p.Project rev-parse --abbrev-ref HEAD | Should -Be 'main'
            Invoke-TestGit $p.Project rev-parse --short HEAD      | Should -Be $parentHead
        }

        It 'fast-forwards an existing local branch to origin/<Branch>' {
            $p     = New-TestProject
            $child = Join-Path $p.Project 'libs/child'
            Invoke-TestGit $child checkout -q -b feat/x | Out-Null
            Invoke-TestGit $child push -q -u origin feat/x | Out-Null
            Invoke-TestGit $child checkout -q main | Out-Null

            $other      = New-SecondClone -P $p
            $otherChild = Join-Path $other 'libs/child'
            Invoke-TestGit $otherChild fetch -q origin | Out-Null
            Invoke-TestGit $otherChild checkout -q feat/x | Out-Null
            Add-TestCommit -Dir $otherChild -File 'more.txt' -Message 'more'
            Invoke-TestGit $otherChild push -q origin feat/x | Out-Null

            $r = @(Sync-OgFramework -ProjectRoot $p.Project -Branch feat/x) | Where-Object Path -eq 'libs/child'

            $r.Action | Should -Be 'fast-forwarded'
            Invoke-TestGit $child rev-parse --abbrev-ref HEAD | Should -Be 'feat/x'
            Test-Path (Join-Path $child 'more.txt')           | Should -BeTrue
        }

        It 'without -Branch every repo still goes to main (unchanged behaviour)' {
            $p     = New-TestProject
            $child = Join-Path $p.Project 'libs/child'
            Invoke-TestGit $child checkout -q -b feat/x | Out-Null
            Invoke-TestGit $child push -q -u origin feat/x | Out-Null

            $results = @(Sync-OgFramework -ProjectRoot $p.Project)

            ($results | Where-Object Path -eq 'libs/child').Action | Should -Be 'already-current'
            Invoke-TestGit $child rev-parse --abbrev-ref HEAD      | Should -Be 'main'
        }
    }
}
