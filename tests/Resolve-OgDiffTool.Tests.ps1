# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

# Covers the diff-tool LAUNCH COMPOSITION only. The spawn itself stays untested on purpose -- there
# is no display in the test environment, and Start-OgDiffToolProcess exists as a mockable seam for
# exactly that reason. That seam is also why the defect below shipped: everything around the launch
# was testable, and the one line that was wrong was not.
#
# The defect: `cmd /c <line>` makes cmd.exe STRIP THE FIRST AND LAST QUOTE when the line begins with
# a quote -- which it always does, because difftool.<tool>.cmd quotes the tool path. cmd then
# mangles the line and exits 1, invisibly, behind -WindowStyle Hidden.
#
# MEASURED 2026-09-09 on an identical fixture (a .cmd tool at a path containing a space, given two
# directory arguments that also contain spaces):
#     cmd /c  <line>     -> exit 1, the tool never ran
#     cmd /s /c "<line>" -> exit 0, the tool ran with both paths intact

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force
}

Describe 'Get-OgDiffToolArgumentList' {

    Context 'A quoted tool path with spaces -- the shape difftool.<tool>.cmd always produces' {

        It 'emits exactly three arguments' {
            # REGRESSION GUARD, not a formality. PowerShell's comma operator binds TIGHTER than '+',
            # so @('/s', '/c', '"' + $CommandLine + '"') parses as
            # @('/s','/c','"') + $CommandLine + '"' -- a FIVE element array that hands cmd a bare
            # quote as its command and splits the line off as trailing arguments. It looks correct
            # in the source and fails only when launched.
            $result = InModuleScope og-framework {
                Get-OgDiffToolArgumentList -CommandLine '"C:\Tool Dir\diff.exe" "C:\base dir" "C:\head dir"'
            }

            $result.Count | Should -Be 3
        }

        It 'passes /s before /c so cmd takes the wrapped line verbatim' {
            $result = InModuleScope og-framework {
                Get-OgDiffToolArgumentList -CommandLine '"C:\Tool Dir\diff.exe" "C:\base dir" "C:\head dir"'
            }

            $result[0] | Should -Be '/s'
            $result[1] | Should -Be '/c'
        }

        It 'wraps the entire command line in one extra quote pair' {
            $result = InModuleScope og-framework {
                Get-OgDiffToolArgumentList -CommandLine '"C:\Tool Dir\diff.exe" "C:\base dir" "C:\head dir"'
            }

            $result[2] | Should -Be '""C:\Tool Dir\diff.exe" "C:\base dir" "C:\head dir""'
        }
    }

    Context 'An unquoted command line' {

        It 'still wraps, because /s consumes exactly one outer pair' {
            $result = InModuleScope og-framework {
                Get-OgDiffToolArgumentList -CommandLine 'diff.exe base head'
            }

            $result.Count | Should -Be 3
            $result[2]    | Should -Be '"diff.exe base head"'
        }
    }
}
