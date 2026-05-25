# SPDX-License-Identifier: MPL-2.0
function Test-OgPinConsistency {
    <#
    .SYNOPSIS
        Validates that all submodule pins in the og-framework tree are consistent and healthy.

    .DESCRIPTION
        Walks the submodule tree via Get-OgRepoStatus and runs three checks:

        1. Cross-path SHA consistency (Severity='error'): if the same repo name appears
           at multiple paths with different Pinned SHAs, emit a violation. In the current
           8-repo architecture each lib has exactly one path per consumer project, so this
           is a structural safety net rather than a common trigger.

        2. Parent/HEAD sync (Severity='warning'): each submodule whose local HEAD does not
           match the SHA pinned in its immediate parent (PinStatus != 'in-sync') emits a
           violation. This fires after a pin-bump commit without a corresponding
           'git submodule update'.

        3. Remote URL health (Severity='warning'): any repo whose RemoteOk is false
           (i.e. origin is not the canonical https://github.com/og-framework/*.git URL)
           emits a violation. This catches the temp file:/// remote that is left behind
           when the temp-local-remote pin-bump pattern is used without restoring the URL.

        Empty pipeline = tree is fully consistent.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .NOTES
        Exit-code pattern for CI use: PowerShell functions cannot set the shell-level
        $LASTEXITCODE in a way that survives the calling script context. Recommended idiom:

            $violations = Test-OgPinConsistency
            if ($violations) { exit 1 } else { exit 0 }

        Or more concisely in a CI script:

            exit (([array](Test-OgPinConsistency)).Count -gt 0 ? 1 : 0)

        This cmdlet sets $global:LASTEXITCODE as a convenience for interactive sessions,
        but callers should not rely on it in scripts.

    .EXAMPLE
        Test-OgPinConsistency | Format-Table -AutoSize
        # Prints all violations. Empty output means the tree is consistent.

    .EXAMPLE
        $v = Test-OgPinConsistency; if ($v) { exit 1 }
        # CI usage: exits 1 if any violations exist.

    .OUTPUTS
        PSCustomObject — one per violation:
          Lib, PathA, ShaA, PathB, ShaB, Severity ('error'|'warning'), Reason
        Empty pipeline if no violations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string] $ProjectRoot = (Get-Location).Path
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
    $statuses    = Get-OgRepoStatus -ProjectRoot $ProjectRoot

    $hasViolations = $false

    # Build name -> list of status entries (non-parent repos only)
    $byName = @{}
    foreach ($s in $statuses) {
        if (-not $s.Path) { continue }
        if (-not $byName.ContainsKey($s.Name)) {
            $byName[$s.Name] = [System.Collections.Generic.List[object]]::new()
        }
        $byName[$s.Name].Add($s)
    }

    # Check 1: cross-path consistency
    foreach ($name in $byName.Keys) {
        $entries = $byName[$name]
        if ($entries.Count -lt 2) { continue }
        for ($i = 0; $i -lt $entries.Count - 1; $i++) {
            for ($j = $i + 1; $j -lt $entries.Count; $j++) {
                $a = $entries[$i]
                $b = $entries[$j]
                if ($a.Pinned -and $b.Pinned -and $a.Pinned -ne $b.Pinned) {
                    $hasViolations = $true
                    [PSCustomObject]@{
                        Lib      = $name
                        PathA    = $a.Path
                        ShaA     = $a.Pinned
                        PathB    = $b.Path
                        ShaB     = $b.Pinned
                        Severity = 'error'
                        Reason   = 'Same repo appears at two paths with different pinned SHAs'
                    }
                }
            }
        }
    }

    # Check 2: parent/HEAD sync
    foreach ($s in $statuses) {
        if (-not $s.Path) { continue }
        if ($s.PinStatus -and $s.PinStatus -notin @('in-sync', 'n/a')) {
            $hasViolations = $true
            [PSCustomObject]@{
                Lib      = $s.Name
                PathA    = $s.Path
                ShaA     = $s.Head
                PathB    = $s.Path
                ShaB     = $s.Pinned
                Severity = 'warning'
                Reason   = "PinStatus='$($s.PinStatus)': local HEAD does not match parent-pinned SHA"
            }
        }
    }

    # Check 3: remote URL health
    foreach ($s in $statuses) {
        if (-not $s.RemoteOk) {
            $hasViolations = $true
            [PSCustomObject]@{
                Lib      = $s.Name
                PathA    = if ($s.Path) { $s.Path } else { '(parent)' }
                ShaA     = $s.Head
                PathB    = $null
                ShaB     = $null
                Severity = 'warning'
                Reason   = 'RemoteOk=False: origin URL is not a canonical https://github.com/og-framework/*.git (possible stale temp-local-remote)'
            }
        }
    }

    $global:LASTEXITCODE = if ($hasViolations) { 1 } else { 0 }
}
