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

Describe 'Push-OgFramework (oggitpush)' {

    It 'pushes a branch that origin does not have yet with -u (upstream set)' {
        $p     = New-TestProject
        $child = Join-Path $p.Project 'libs/child'
        Invoke-TestGit $child checkout -q -b feat/x | Out-Null
        Add-TestCommit -Dir $child -File 'f.txt' -Message 'feature'

        $results = @(Push-OgFramework -ProjectRoot $p.Project)

        $r = $results | Where-Object Path -eq 'libs/child'
        $r.Action | Should -Be 'pushed'
        $r.Branch | Should -Be 'feat/x'
        Invoke-TestGit $child rev-parse --abbrev-ref 'feat/x@{upstream}' | Should -Be 'origin/feat/x'
        Invoke-TestGit $p.ChildUrl rev-parse refs/heads/feat/x | Should -Be (Invoke-TestGit $child rev-parse HEAD)
    }

    It 'pushes an existing upstream branch without needing -u' {
        $p     = New-TestProject
        $child = Join-Path $p.Project 'libs/child'
        Add-TestCommit -Dir $child -File 'g.txt' -Message 'on main'

        $r = @(Push-OgFramework -ProjectRoot $p.Project) | Where-Object Path -eq 'libs/child'

        $r.Action        | Should -Be 'pushed'
        $r.CommitsPushed | Should -Be 1
        Invoke-TestGit $p.ChildUrl rev-parse refs/heads/main | Should -Be (Invoke-TestGit $child rev-parse HEAD)
    }

    It '-WhatIf names the -u push for a new branch and pushes nothing' {
        $p     = New-TestProject
        $child = Join-Path $p.Project 'libs/child'
        Invoke-TestGit $child checkout -q -b feat/y | Out-Null

        $r = @(Push-OgFramework -ProjectRoot $p.Project -WhatIf) | Where-Object Path -eq 'libs/child'

        $r.Action | Should -Be 'would-push'
        (& git -C $p.ChildUrl rev-parse --verify --quiet refs/heads/feat/y) | Should -BeNullOrEmpty
    }
}
