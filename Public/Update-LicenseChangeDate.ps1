# SPDX-License-Identifier: MPL-2.0
function Update-LicenseChangeDate {
    <#
    .SYNOPSIS
        Stamps the Change Date in a BSL LICENSE file based on the release date.

    .DESCRIPTION
        Reads the LICENSE file at <Path>/LICENSE, locates either the template
        placeholder {{CHANGE_DATE}} or an existing "Change Date:" line, and
        replaces it with a computed or explicit date.

        Run this at release time to stamp the BSL Change Date based on the release
        date. Default is +4 years per og-framework policy.

        The computed date is either:
          - ReleaseDate + YearsFromRelease (default 4), or
          - an explicit -ChangeDate when absolute override is needed.

        If the LICENSE file does not appear to be a BSL file (missing "Business
        Source License" and "Change Date:" markers), the cmdlet emits a warning
        and returns without modifying the file.

    .PARAMETER Path
        Path to the repo root directory containing the BSL LICENSE file.

    .PARAMETER ReleaseDate
        The date this release ships. Used as the base for the Change Date
        calculation when -ChangeDate is not specified.

    .PARAMETER YearsFromRelease
        Number of years to add to ReleaseDate when computing the Change Date.
        Default is 4, matching og-framework policy. Must be >= 0.

    .PARAMETER ChangeDate
        Absolute override for the Change Date. When provided, takes precedence
        over -YearsFromRelease. Use for explicit-date scenarios such as
        contractual commitments or aligning multiple repos to a single date.

    .EXAMPLE
        Update-LicenseChangeDate -Path C:\dev\my-repo -ReleaseDate 2026-06-01
        # Stamps Change Date as 2030-06-01 (default +4 years).

    .EXAMPLE
        Update-LicenseChangeDate -Path C:\dev\my-repo -ReleaseDate 2026-06-01 -YearsFromRelease 1
        # Stamps Change Date as 2027-06-01 (custom +1 year window).

    .EXAMPLE
        Update-LicenseChangeDate -Path C:\dev\my-repo -ReleaseDate 2026-06-01 -ChangeDate 2029-01-01
        # Stamps Change Date as 2029-01-01 (absolute override).

    .OUTPUTS
        PSCustomObject with properties: Path, OldChangeDate, NewChangeDate, Action
          Action values: 'placeholder-substituted' | 'date-overwritten' | 'skipped-not-bsl'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [Parameter(Mandatory)]
        [DateTime] $ReleaseDate,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $YearsFromRelease = 4,

        [DateTime] $ChangeDate
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Path '$Path' is not a directory or does not exist."
    }

    $licensePath = Join-Path $Path 'LICENSE'
    if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
        throw "LICENSE file not found at '$licensePath'."
    }

    $content = Get-Content -LiteralPath $licensePath -Raw

    $isBsl = ($content -match 'Business Source License') -and ($content -match 'Change Date:')
    if (-not $isBsl) {
        Write-Warning "LICENSE at '$licensePath' does not appear to be a BSL file (missing 'Business Source License' or 'Change Date:' marker). Skipping."
        return [PSCustomObject]@{
            PSTypeName    = 'Og.LicenseStampResult'
            Path          = $Path
            OldChangeDate = $null
            NewChangeDate = $null
            Action        = 'skipped-not-bsl'
        }
    }

    $effectiveChangeDate = if ($PSBoundParameters.ContainsKey('ChangeDate')) {
        $limitDate = $ReleaseDate.AddYears(4)
        if ($ChangeDate -gt $limitDate) {
            Write-Warning "ChangeDate '$($ChangeDate.ToString('yyyy-MM-dd'))' is more than 4 years after ReleaseDate '$($ReleaseDate.ToString('yyyy-MM-dd'))'. BSL §43-47 caps the effective date at the 4-year anniversary regardless."
        }
        $ChangeDate
    } else {
        $ReleaseDate.AddYears($YearsFromRelease)
    }

    $newDateStr  = $effectiveChangeDate.ToString('yyyy-MM-dd')
    $newLine     = "Change Date:          $newDateStr"

    $oldChangeDate = $null
    $action        = $null

    if ($content -match '\{\{CHANGE_DATE\}\}') {
        $oldChangeDate = '{{CHANGE_DATE}}'
        $newContent    = $content -replace '\{\{CHANGE_DATE\}\}', $newDateStr
        $action        = 'placeholder-substituted'
    } else {
        if ($content -match 'Change Date:\s+(\S+)') {
            $oldChangeDate = $Matches[1]
        }
        $newContent = $content -replace '(?m)^Change Date:\s+\S+', $newLine
        $action     = 'date-overwritten'
    }

    Set-Content -LiteralPath $licensePath -Value $newContent -NoNewline

    [PSCustomObject]@{
        PSTypeName    = 'Og.LicenseStampResult'
        Path          = $Path
        OldChangeDate = $oldChangeDate
        NewChangeDate = $newDateStr
        Action        = $action
    }
}
