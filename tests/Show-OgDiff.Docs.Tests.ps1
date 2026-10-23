# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

# Smoke checks that the README and the manifest keep up with Show-OgDiff (od task 6). They read files and
# the loaded module only: no git, no repo, no tool. They catch drift, not prose quality: a parameter, an
# Action value or the inventory row that the code has and the README lost (or never got).

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force
    $script:Readme   = [System.IO.File]::ReadAllText((Join-Path $moduleRoot 'README.md'))
    $script:Manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $moduleRoot 'og-framework.psd1')
}

Describe 'Show-OgDiff docs and manifest (od task 6)' {
    It 'the manifest is at 1.6.0 or later and still exports Show-OgDiff and oggitdiff' {
        [version] $script:Manifest.ModuleVersion | Should -BeGreaterOrEqual ([version] '1.6.0')
        $script:Manifest.FunctionsToExport | Should -Contain 'Show-OgDiff'
        $script:Manifest.AliasesToExport   | Should -Contain 'oggitdiff'
        (Get-Alias -Name oggitdiff).Definition | Should -Be 'Show-OgDiff'
    }

    It 'the README cmdlet inventory has the Show-OgDiff / oggitdiff row' {
        $script:Readme | Should -Match '(?m)^\| `Show-OgDiff` \| `oggitdiff` \| '
    }

    It 'the README names every Show-OgDiff parameter' {
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters +
            [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        $names = @((Get-Command Show-OgDiff).Parameters.Keys | Where-Object { $_ -notin $common })
        $names.Count | Should -BeGreaterThan 5
        # Case-sensitive, and not preceded by '-' or a word character: `--tool=<Tool>` (git difftool's
        # option) must not count as documenting -Tool (od review 6, N1).
        foreach ($name in $names) {
            $script:Readme | Should -MatchExactly ('(?<![-\w])' + [regex]::Escape("-$name") + '\b') -Because "the README should document -$name"
        }
    }

    It 'the README Actions table lists every Action a result can carry' {
        $actions = InModuleScope og-framework {
            (Get-Command New-OgDiffResult).Parameters['Action'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                ForEach-Object ValidValues
        }
        @($actions).Count | Should -Be 5
        foreach ($action in $actions) {
            $script:Readme | Should -Match ('(?m)^\| `' + [regex]::Escape($action) + '` \| ') -Because "Action '$action' needs a row"
        }
    }
}
