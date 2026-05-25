# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force

    $bslContent = @'
Business Source License 1.1

Parameters

Licensor:             Test Licensor
Licensed Work:        test-repo
Change Date:          {{CHANGE_DATE}}
Change License:       Mozilla Public License Version 2.0

For information about alternative licensing arrangements please contact test@example.com.
'@

    $nonBslContent = @'
MIT License

Copyright (c) 2024 Test

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software.
'@
}

Describe 'Update-LicenseChangeDate' {

    Context 'Placeholder substitution (default +4 years)' {
        It 'replaces {{CHANGE_DATE}} with ReleaseDate + 4 years' {
            $dir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
            try {
                Set-Content -LiteralPath (Join-Path $dir 'LICENSE') -Value $bslContent -NoNewline
                $releaseDate = [DateTime]'2026-06-01'
                $result = Update-LicenseChangeDate -Path $dir -ReleaseDate $releaseDate
                $result.Action        | Should -Be 'placeholder-substituted'
                $result.OldChangeDate | Should -Be '{{CHANGE_DATE}}'
                $result.NewChangeDate | Should -Be '2030-06-01'
                $result.Path          | Should -Be $dir.FullName
                (Get-Content (Join-Path $dir 'LICENSE') -Raw) | Should -Match 'Change Date:\s+2030-06-01'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    }

    Context 'Existing Change Date overwrite' {
        It 'overwrites an already-stamped Change Date line' {
            $dir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
            try {
                $stamped = $bslContent -replace '\{\{CHANGE_DATE\}\}', '2029-01-01'
                Set-Content -LiteralPath (Join-Path $dir 'LICENSE') -Value $stamped -NoNewline
                $result = Update-LicenseChangeDate -Path $dir -ReleaseDate ([DateTime]'2026-06-01')
                $result.Action        | Should -Be 'date-overwritten'
                $result.OldChangeDate | Should -Be '2029-01-01'
                $result.NewChangeDate | Should -Be '2030-06-01'
                (Get-Content (Join-Path $dir 'LICENSE') -Raw) | Should -Match 'Change Date:\s+2030-06-01'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    }

    Context 'Custom -YearsFromRelease' {
        It 'computes the correct date with -YearsFromRelease 1' {
            $dir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
            try {
                Set-Content -LiteralPath (Join-Path $dir 'LICENSE') -Value $bslContent -NoNewline
                $result = Update-LicenseChangeDate -Path $dir -ReleaseDate ([DateTime]'2026-06-01') -YearsFromRelease 1
                $result.NewChangeDate | Should -Be '2027-06-01'
                $result.Action        | Should -Be 'placeholder-substituted'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }

        It 'accepts -YearsFromRelease 0 (same day as release)' {
            $dir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
            try {
                Set-Content -LiteralPath (Join-Path $dir 'LICENSE') -Value $bslContent -NoNewline
                $result = Update-LicenseChangeDate -Path $dir -ReleaseDate ([DateTime]'2026-06-01') -YearsFromRelease 0
                $result.NewChangeDate | Should -Be '2026-06-01'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    }

    Context 'Absolute -ChangeDate override' {
        It '-ChangeDate takes precedence over -YearsFromRelease' {
            $dir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
            try {
                Set-Content -LiteralPath (Join-Path $dir 'LICENSE') -Value $bslContent -NoNewline
                $result = Update-LicenseChangeDate -Path $dir -ReleaseDate ([DateTime]'2026-06-01') `
                    -YearsFromRelease 1 -ChangeDate ([DateTime]'2031-03-15')
                $result.NewChangeDate | Should -Be '2031-03-15'
                $result.Action        | Should -Be 'placeholder-substituted'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    }

    Context '-ChangeDate more than 4 years warning' {
        It 'emits a warning when -ChangeDate exceeds 4 years after -ReleaseDate' {
            $dir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
            try {
                Set-Content -LiteralPath (Join-Path $dir 'LICENSE') -Value $bslContent -NoNewline
                { Update-LicenseChangeDate -Path $dir -ReleaseDate ([DateTime]'2026-06-01') `
                    -ChangeDate ([DateTime]'2032-01-01') -WarningAction Stop } |
                    Should -Throw
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }

        It 'still writes the file even when warning is emitted' {
            $dir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
            try {
                Set-Content -LiteralPath (Join-Path $dir 'LICENSE') -Value $bslContent -NoNewline
                $result = Update-LicenseChangeDate -Path $dir -ReleaseDate ([DateTime]'2026-06-01') `
                    -ChangeDate ([DateTime]'2032-01-01') -WarningAction SilentlyContinue
                $result.NewChangeDate | Should -Be '2032-01-01'
                $result.Action        | Should -Be 'placeholder-substituted'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    }

    Context 'Non-BSL LICENSE file' {
        It 'returns Action skipped-not-bsl and does not modify the file' {
            $dir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
            try {
                Set-Content -LiteralPath (Join-Path $dir 'LICENSE') -Value $nonBslContent -NoNewline
                $result = Update-LicenseChangeDate -Path $dir -ReleaseDate ([DateTime]'2026-06-01') -WarningAction SilentlyContinue
                $result.Action        | Should -Be 'skipped-not-bsl'
                $result.OldChangeDate | Should -BeNullOrEmpty
                $result.NewChangeDate | Should -BeNullOrEmpty
                (Get-Content (Join-Path $dir 'LICENSE') -Raw) | Should -Be $nonBslContent
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    }

    Context 'Error cases' {
        It 'throws when -Path does not exist' {
            { Update-LicenseChangeDate -Path 'C:\does-not-exist-xyz' -ReleaseDate ([DateTime]'2026-06-01') } |
                Should -Throw
        }

        It 'throws when LICENSE file is missing' {
            $dir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
            try {
                { Update-LicenseChangeDate -Path $dir -ReleaseDate ([DateTime]'2026-06-01') } |
                    Should -Throw
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }

        It 'throws when -YearsFromRelease is negative' {
            $dir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
            try {
                Set-Content -LiteralPath (Join-Path $dir 'LICENSE') -Value $bslContent -NoNewline
                { Update-LicenseChangeDate -Path $dir -ReleaseDate ([DateTime]'2026-06-01') -YearsFromRelease -1 } |
                    Should -Throw
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    }

    Context 'Returned PSCustomObject shape' {
        It 'has expected properties' {
            $dir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }
            try {
                Set-Content -LiteralPath (Join-Path $dir 'LICENSE') -Value $bslContent -NoNewline
                $result = Update-LicenseChangeDate -Path $dir -ReleaseDate ([DateTime]'2026-06-01')
                $result.PSObject.Properties.Name | Should -Contain 'Path'
                $result.PSObject.Properties.Name | Should -Contain 'OldChangeDate'
                $result.PSObject.Properties.Name | Should -Contain 'NewChangeDate'
                $result.PSObject.Properties.Name | Should -Contain 'Action'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    }
}
