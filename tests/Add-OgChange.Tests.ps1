# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force
    . "$PSScriptRoot\OgGitTestHelpers.ps1"
    Enter-OgGitSandbox -Root (Join-Path $TestDrive 'sandbox')

    # An undeclared nested repo (its own .git, no .gitmodules entry) at <Dir>/<Rel>.
    function New-StrayRepo {
        param([string] $Dir, [string] $Rel)
        $stray = Join-Path $Dir $Rel
        New-Item -ItemType Directory -Path $stray -Force | Out-Null
        Invoke-TestGit $stray init -q | Out-Null
        Add-TestCommit -Dir $stray -File 'stray.txt' -Message 'stray'
        $stray
    }
}

AfterAll {
    Exit-OgGitSandbox
}

Describe 'Add-OgChange (oggitadd) embedded-repo guard' {

    It 'skips an undeclared nested repo with a warning naming it, and still stages the rest' {
        $p = New-TestProject
        New-StrayRepo -Dir $p.Project -Rel 'plugins/stray' | Out-Null
        Set-Content -LiteralPath (Join-Path $p.Project 'plugins/notes.txt') -Value 'real work'

        $warnings = $null
        $results  = @(Add-OgChange -ProjectRoot $p.Project -WarningVariable warnings -WarningAction SilentlyContinue)

        @($warnings | Where-Object { "$_" -match "'plugins/stray'" }).Count | Should -Be 1
        $staged = Get-TestStaged -Dir $p.Project
        $staged | Should -Contain "A`tplugins/notes.txt"
        ($staged | Where-Object { $_ -match 'stray' }) | Should -BeNullOrEmpty
        (Invoke-TestGit $p.Project ls-files -s) | Should -Not -Match '160000 .* plugins/stray'
        ($results | Where-Object Path -eq '').Action | Should -Be 'staged'
    }

    It 'reports nothing-to-stage when the only change is an undeclared nested repo' {
        $p = New-TestProject
        New-StrayRepo -Dir $p.Project -Rel 'stray' | Out-Null

        $results = @(Add-OgChange -ProjectRoot $p.Project -WarningAction SilentlyContinue)

        ($results | Where-Object Path -eq '').Action | Should -Be 'nothing-to-stage'
        Get-TestStaged -Dir $p.Project              | Should -BeNullOrEmpty
    }

    It 'guards the path-scoped mode too' {
        $p = New-TestProject
        New-StrayRepo -Dir $p.Project -Rel 'area/stray' | Out-Null
        Set-Content -LiteralPath (Join-Path $p.Project 'area/real.txt') -Value 'x'

        $warnings = $null
        Add-OgChange -Path 'area' -ProjectRoot $p.Project -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

        @($warnings | Where-Object { "$_" -match "'area/stray'" }).Count | Should -Be 1
        $staged = Get-TestStaged -Dir $p.Project
        $staged | Should -Contain "A`tarea/real.txt"
        ($staged | Where-Object { $_ -match 'stray' }) | Should -BeNullOrEmpty
    }

    It 'does not skip a declared submodule: oggitadd + oggitcommit cascade its change and pin' {
        $p     = New-TestProject
        $child = Join-Path $p.Project 'libs/child'
        New-StrayRepo -Dir $p.Project -Rel 'stray' | Out-Null
        Set-Content -LiteralPath (Join-Path $child 'work.txt') -Value 'child work'

        $warnings = $null
        Add-OgChange -ProjectRoot $p.Project -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        @($warnings | Where-Object { "$_" -match 'libs/child' }).Count | Should -Be 0

        $commits = @(New-OgCommit -Message 'child work' -ProjectRoot $p.Project)

        ($commits | Where-Object Path -eq 'libs/child').Action | Should -Be 'committed'
        ($commits | Where-Object Path -eq '').Action           | Should -Be 'committed'
        (Invoke-TestGit $p.Project ls-tree HEAD -- libs/child) | Should -Match (Invoke-TestGit $child rev-parse HEAD)
        (Invoke-TestGit $p.Project ls-tree -r --name-only HEAD) | Should -Not -Match 'stray'
    }

    It 'does not skip a submodule newly added with oggitsubadd (declared, staged)' {
        $p      = New-TestProject
        $newUrl = New-TestRemote -Root $p.Remotes -Name 'jolt'
        Add-OgSubmodule -Url $newUrl -Path 'libs/child/ext/jolt' -ProjectRoot $p.Project | Out-Null

        $warnings = $null
        Add-OgChange -ProjectRoot $p.Project -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        $warnings | Should -BeNullOrEmpty

        $commits = @(New-OgCommit -Message 'add jolt' -ProjectRoot $p.Project)
        ($commits | Where-Object Path -eq 'libs/child').Action | Should -Be 'committed'
        (Invoke-TestGit (Join-Path $p.Project 'libs/child') ls-tree HEAD -- ext/jolt) | Should -Match '^160000 commit'
    }
}
