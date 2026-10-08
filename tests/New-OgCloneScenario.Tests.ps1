# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force
    . "$PSScriptRoot\OgGitTestHelpers.ps1"
    Enter-OgGitSandbox -Root (Join-Path $TestDrive 'sandbox')

    # Local stand-ins for the unreal scenario's remotes, in one folder used as -RemoteBaseUrl:
    #   og-brawler-unreal.git
    #     Plugins/OGSimulation -> og-simulation-ue.git
    #       (feat/x only) Source/OGSimulationJolt/og-simulation-jolt -> og-simulation-jolt.git
    # og-simulation-jolt has main and feat/x; og-brawler-unreal and og-simulation-ue have
    # feat/x, where og-simulation-ue declares the jolt submodule and the root pins that.
    function New-UnrealScenarioRemotes {
        $root    = New-TestDir 'scn'
        $remotes = Join-Path $root 'remotes'
        New-Item -ItemType Directory -Path $remotes | Out-Null
        $joltUrl   = New-TestRemote -Root $remotes -Name 'og-simulation-jolt'
        $simUeUrl  = New-TestRemote -Root $remotes -Name 'og-simulation-ue'
        $unrealUrl = New-TestRemote -Root $remotes -Name 'og-brawler-unreal'

        $w = Join-Path $root 'work'
        Invoke-TestGit $root clone -q $unrealUrl $w | Out-Null
        Invoke-TestGit $w submodule add -q -- $simUeUrl Plugins/OGSimulation | Out-Null
        Invoke-TestGit $w commit -q -m 'add og-simulation-ue' | Out-Null
        Invoke-TestGit $w push -q origin main | Out-Null

        # feat/x: og-simulation-ue gains the jolt submodule (on jolt's feat/x).
        $simUe = Join-Path $w 'Plugins/OGSimulation'
        Invoke-TestGit $w     checkout -q -b feat/x | Out-Null
        Invoke-TestGit $simUe checkout -q -b feat/x | Out-Null
        Invoke-TestGit $simUe submodule add -q -- $joltUrl Source/OGSimulationJolt/og-simulation-jolt | Out-Null
        $jolt = Join-Path $simUe 'Source/OGSimulationJolt/og-simulation-jolt'
        Invoke-TestGit $jolt checkout -q -b feat/x | Out-Null
        Add-TestCommit -Dir $jolt -File 'Jolt.txt' -Message 'jolt work'
        Invoke-TestGit $jolt push -q -u origin feat/x | Out-Null
        Invoke-TestGit $simUe add -- Source/OGSimulationJolt/og-simulation-jolt | Out-Null
        Invoke-TestGit $simUe commit -q -m 'add og-simulation-jolt' | Out-Null
        Invoke-TestGit $simUe push -q -u origin feat/x | Out-Null
        Invoke-TestGit $w add -- Plugins/OGSimulation | Out-Null
        Invoke-TestGit $w commit -q -m 'bump og-simulation-ue' | Out-Null
        Invoke-TestGit $w push -q -u origin feat/x | Out-Null

        @{ Root = $root; Remotes = $remotes }
    }
}

AfterAll {
    Exit-OgGitSandbox
}

Describe 'New-OgCloneScenario' {

    It 'without -Branch clones main, where og-simulation-jolt is not declared' {
        $s = New-UnrealScenarioRemotes
        $target = Join-Path $s.Root 'clone-main'

        $r = New-OgCloneScenario -Scenario unreal -Target $target -RemoteBaseUrl $s.Remotes

        $r.Error     | Should -BeNullOrEmpty
        $r.RepoCount | Should -Be 2
        Test-Path (Join-Path $r.Path 'Plugins/OGSimulation/.git') | Should -BeTrue
        Test-Path (Join-Path $r.Path 'Plugins/OGSimulation/Source/OGSimulationJolt/og-simulation-jolt') | Should -BeFalse
    }

    It 'with -Branch puts every repo on the branch and includes og-simulation-jolt next to og-simulation' {
        $s = New-UnrealScenarioRemotes
        $target = Join-Path $s.Root 'clone-feat'

        $r = New-OgCloneScenario -Scenario unreal -Target $target -RemoteBaseUrl $s.Remotes -Branch feat/x

        $r.Error     | Should -BeNullOrEmpty
        $r.Branch    | Should -Be 'feat/x'
        $r.RepoCount | Should -Be 3
        $jolt = Join-Path $r.Path 'Plugins/OGSimulation/Source/OGSimulationJolt/og-simulation-jolt'
        Test-Path (Join-Path $jolt '.git')       | Should -BeTrue
        Test-Path (Join-Path $jolt 'Jolt.txt')   | Should -BeTrue
        foreach ($dir in @($r.Path, (Join-Path $r.Path 'Plugins/OGSimulation'), $jolt)) {
            Invoke-TestGit $dir rev-parse --abbrev-ref HEAD | Should -Be 'feat/x'
        }
    }

    It 'creates a missing -Target without a stray error' {
        $s = New-UnrealScenarioRemotes
        $target = Join-Path $s.Root 'does/not/exist/yet'
        $errs = $null

        $r = New-OgCloneScenario -Scenario unreal -Target $target -RemoteBaseUrl $s.Remotes -ErrorVariable errs

        $errs | Should -BeNullOrEmpty
        $r.Error | Should -BeNullOrEmpty
        Test-Path (Join-Path $target 'og-brawler-unreal/.git') | Should -BeTrue
    }

    It '-WhatIf clones nothing' {
        $s = New-UnrealScenarioRemotes
        $target = Join-Path $s.Root 'clone-whatif'

        $r = New-OgCloneScenario -Scenario unreal -Target $target -RemoteBaseUrl $s.Remotes -Branch feat/x -WhatIf

        $r.RepoCount | Should -Be -1
        Test-Path $target | Should -BeFalse
    }
}
