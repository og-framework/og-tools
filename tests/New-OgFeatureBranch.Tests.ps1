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

Describe 'New-OgFeatureBranch' {

    Context 'Quiet re-branching' {
        It 'reports already-exists without any error when re-run' {
            $p = New-TestProject
            $first = @(New-OgFeatureBranch -Name feat/x -ProjectRoot $p.Project)
            $first.Action | ForEach-Object { $_ | Should -Be 'created' }

            $errs   = $null
            $second = @(New-OgFeatureBranch -Name feat/x -ProjectRoot $p.Project -ErrorVariable errs -ErrorAction Stop)

            $errs | Should -BeNullOrEmpty
            $second.Count | Should -Be 2
            $second.Action | ForEach-Object { $_ | Should -Be 'already-exists' }
        }

        It 'reports the skip through Write-Verbose' {
            $p = New-TestProject
            New-OgFeatureBranch -Name feat/x -ProjectRoot $p.Project | Out-Null

            $verbose = New-OgFeatureBranch -Name feat/x -ProjectRoot $p.Project -Verbose 4>&1 |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and "$_" -match 'already has branch' }
            @($verbose).Count | Should -Be 2
        }

        It 'creates the branch only in a newly added submodule on a re-run' {
            $p = New-TestProject
            New-OgFeatureBranch -Name feat/x -ProjectRoot $p.Project | Out-Null
            $newUrl = New-TestRemote -Root $p.Remotes -Name 'newlib'
            # Added on main-from-origin (as a plain git submodule add would), then re-branch.
            Invoke-TestGit $p.Project submodule add -q -- $newUrl libs/newlib | Out-Null

            $r = @(New-OgFeatureBranch -Name feat/x -ProjectRoot $p.Project -ErrorAction Stop)

            ($r | Where-Object Path -eq 'libs/newlib').Action | Should -Be 'created'
            ($r | Where-Object Path -eq 'libs/child').Action  | Should -Be 'already-exists'
            ($r | Where-Object Path -eq '').Action            | Should -Be 'already-exists'
            Invoke-TestGit (Join-Path $p.Project 'libs/newlib') rev-parse --abbrev-ref HEAD | Should -Be 'feat/x'
        }
    }

    Context '-Repo filter' {
        It 'limits creation to a repo named by its leaf name' {
            $p = New-TestProject

            $r = @(New-OgFeatureBranch -Name feat/only -Repo child -ProjectRoot $p.Project)

            $r.Count  | Should -Be 1
            $r.Path   | Should -Be 'libs/child'
            $r.Action | Should -Be 'created'
            Invoke-TestGit (Join-Path $p.Project 'libs/child') rev-parse --abbrev-ref HEAD | Should -Be 'feat/only'
            Invoke-TestGit $p.Project rev-parse --abbrev-ref HEAD | Should -Be 'main'
            (& git -C $p.Project rev-parse --verify --quiet refs/heads/feat/only) | Should -BeNullOrEmpty
        }

        It 'matches a project-relative path (either slash) and the parent by its folder name' {
            $p = New-TestProject
            $parentName = Split-Path $p.Project -Leaf

            $r = @(New-OgFeatureBranch -Name feat/two -Repo 'libs\child', $parentName -ProjectRoot $p.Project)

            $r.Count | Should -Be 2
            ($r.Action | Sort-Object -Unique) | Should -Be 'created'
        }

        It 'warns about a -Repo value that matches nothing' {
            $p = New-TestProject
            $warnings = $null

            $r = @(New-OgFeatureBranch -Name feat/z -Repo nope -ProjectRoot $p.Project -WarningVariable warnings -WarningAction SilentlyContinue)

            $r.Count | Should -Be 0
            @($warnings | Where-Object { "$_" -match "'nope'" }).Count | Should -Be 1
        }
    }
}
