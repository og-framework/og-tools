# SPDX-License-Identifier: MPL-2.0
function New-OgCommit {
    <#
    .SYNOPSIS
        Commits staged changes across the og-framework repo tree, deepest-first,
        with automatic pin-advance cascade.

    .DESCRIPTION
        Walks the repo tree resolved from .gitmodules, processes repos in deepest-first
        order (children before parents), and commits every repo that has staged changes.

        After committing each child repo, New-OgCommit stages that child's new HEAD SHA
        as a submodule pin advance in the immediate parent. This means running
        'oggitadd; oggitcommit' is all you need for a full 3-level cascade — no manual
        pin staging required.

        PRE-PASS: before the main commit loop, New-OgCommit detects repos where
        PinStatus='parent-behind' (the user manually ran 'git commit' in a submodule
        outside og-tools). For each such repo, the missing pin advance is staged in the
        immediate parent so the cascade can proceed normally.

        PIN-ADVANCE MESSAGE: when all staged files in a repo are submodule pointer
        updates (detected via cross-reference against .gitmodules paths), the commit
        uses -PinMessage instead of -Message. This lets pin-only commits carry a
        consistent short message (e.g., "chore: bump pins") while real-work commits
        carry the meaningful description.

    .PARAMETER Message
        Commit message used for repos with real content changes.

    .PARAMETER PinMessage
        Commit message used when a repo's staged changes are only submodule pin advances.
        Defaults to the same value as -Message.

    .PARAMETER AllowEmpty
        When set, passes --allow-empty to git commit. Useful for testing.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .EXAMPLE
        oggitadd
        oggitcommit -Message "feat: add position prediction to simulation"
        # Stages all dirty repos, then commits the full cascade:
        # og-simulation committed, then og-simulation-ue pin bumped + committed,
        # then og-brawler-unreal pin bumped + committed — all with the same message.

    .EXAMPLE
        oggitadd
        oggitcommit -Message "feat: new brawler move" -PinMessage "chore: bump og-brawler pin"
        # Real-work commits use the first message; pin-advance-only commits use the second.

    .EXAMPLE
        # Pre-pass scenario — user manually committed in og-simulation:
        #   (in og-simulation)  git commit -m "manual"
        # Then from og-brawler-unreal:
        oggitcommit -Message "bump"
        # Pre-pass detects og-simulation-ue pin is stale, stages it, cascade continues.

    .EXAMPLE
        New-OgCommit -Message "test" -WhatIf
        # Shows which repos would be committed without making any changes.

    .OUTPUTS
        PSCustomObject — one per repo evaluated:
          Repo, Path, Action ('committed'|'nothing-to-commit'|'would-commit'|'failed'),
          Sha, Message, ContainsPinAdvance
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Message,

        [Parameter(Position = 1)]
        [string] $PinMessage,

        [switch] $AllowEmpty,

        [string] $ProjectRoot = (Get-Location).Path
    )

    if (-not $PinMessage) { $PinMessage = $Message }

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath

    # Resolve tree: parent first, then depth-first submodules
    $tree = @(Resolve-OgRepoTree -ProjectRoot $ProjectRoot)

    # Build parent lookup: AbsolutePath -> immediate parent node
    # A repo's immediate parent is the deepest ancestor in the tree that contains it.
    $parentOf = @{}
    foreach ($node in $tree) {
        if ($node.IsParent) { continue }
        $nodePath = $node.Path.Replace('\', '/')
        $parts    = $nodePath -split '/'

        $bestParent     = $null
        $bestParentDepth = -1

        foreach ($candidate in $tree) {
            $candidatePath = $candidate.Path.Replace('\', '/')
            if ($candidatePath -eq $nodePath) { continue }

            if ($candidatePath -eq '') {
                # project root is always a candidate
                if ($bestParentDepth -lt 0) {
                    $bestParent      = $candidate
                    $bestParentDepth = 0
                }
            } elseif ($nodePath.StartsWith($candidatePath + '/')) {
                $depth = ($candidatePath -split '/').Count
                if ($depth -gt $bestParentDepth) {
                    $bestParent      = $candidate
                    $bestParentDepth = $depth
                }
            }
        }

        if ($bestParent) {
            $parentOf[$node.AbsolutePath] = $bestParent
        }
    }

    # Reverse for deepest-first order
    [array]::Reverse($tree)

    # Helper: given a repo's AbsPath, return relative path of the repo dir within its parent
    function Get-PathInParent {
        param($childAbsPath, $parentAbsPath)
        $rel = $childAbsPath.Replace('\', '/').Substring($parentAbsPath.Replace('\', '/').Length).TrimStart('/')
        $rel
    }

    # Helper: collect all submodule relative paths declared in a repo's .gitmodules
    # Returns a plain string[] so callers can use -in / -contains without HashSet pipeline issues.
    function Get-SubmodulePaths {
        param([string] $repoAbsPath)
        $gmPath = Join-Path $repoAbsPath '.gitmodules'
        $result = [System.Collections.Generic.List[string]]::new()
        if (Test-Path -LiteralPath $gmPath) {
            foreach ($line in (Get-Content -LiteralPath $gmPath -ErrorAction SilentlyContinue)) {
                if ($line.Trim() -match '^path\s*=\s*(.+)$') {
                    $result.Add($Matches[1].Trim().Replace('\', '/'))
                }
            }
        }
        , [string[]]$result.ToArray()
    }

    # PRE-PASS: detect repos where parent's pin is behind child's HEAD
    # (user manually committed outside og-tools). Stage the missing pin advance.
    foreach ($node in $tree) {
        if ($node.IsParent) { continue }
        $absPath = $node.AbsolutePath
        if (-not (Test-Path -LiteralPath $absPath)) { continue }

        $parentNode = $parentOf[$absPath]
        if (-not $parentNode) { continue }
        $parentAbsPath = $parentNode.AbsolutePath
        if (-not (Test-Path -LiteralPath $parentAbsPath)) { continue }

        # Get current HEAD in child
        $headResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', 'HEAD'
        if ($headResult.ExitCode -ne 0) { continue }
        $headFull = $headResult.StdOut

        # Get pinned SHA from parent's ls-tree
        $childRelInParent = Get-PathInParent $absPath $parentAbsPath
        $lsResult = Invoke-Git -WorkingDirectory $parentAbsPath `
            -Arguments 'ls-tree', 'HEAD', '--', $childRelInParent
        if ($lsResult.ExitCode -ne 0 -or $lsResult.StdOut -notmatch '\b([0-9a-f]{40})\b') { continue }
        $pinnedFull = $Matches[1]

        if ($headFull -eq $pinnedFull) { continue }

        # Check if child HEAD is ahead of pin (parent-behind case)
        $ancestorCheck = Invoke-Git -WorkingDirectory $absPath `
            -Arguments 'merge-base', '--is-ancestor', $pinnedFull, $headFull
        if ($ancestorCheck.ExitCode -ne 0) { continue }

        # Stage the pin advance in the parent
        Write-Verbose "Pre-pass: staging pin advance for $($node.Name) in $($parentNode.Name)"
        if ($PSCmdlet.ShouldProcess("$($parentNode.Name): stage pin advance for $($node.Name)", 'git add (pre-pass)')) {
            $addResult = Invoke-Git -WorkingDirectory $parentAbsPath `
                -Arguments 'add', $childRelInParent
            if ($addResult.ExitCode -ne 0) {
                Write-Warning "Pre-pass: failed to stage pin advance for $($node.Name) in $($parentNode.Name): $($addResult.StdErr)"
            }
        }
    }

    # MAIN PASS: commit repos deepest-first
    foreach ($repo in $tree) {
        $absPath  = $repo.AbsolutePath
        $repoName = $repo.Name

        if (-not (Test-Path -LiteralPath $absPath)) {
            Write-Warning "Repo path not on disk, skipping: $absPath"
            continue
        }

        # Check for staged changes
        $diffResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'diff', '--cached', '--quiet'
        $hasStaged  = ($diffResult.ExitCode -ne 0)

        if (-not $hasStaged -and -not $AllowEmpty) {
            [PSCustomObject]@{ PSTypeName = 'Og.CommitResult';
                Repo               = $repoName
                Path               = $repo.Path
                Action             = 'nothing-to-commit'
                Sha                = $null
                Message            = $null
                ContainsPinAdvance = $false
            }
            continue
        }

        # Determine if all staged changes are pin advances
        $stagedFiles     = @()
        $nameOnlyResult  = Invoke-Git -WorkingDirectory $absPath -Arguments 'diff', '--cached', '--name-only'
        if ($nameOnlyResult.ExitCode -eq 0 -and $nameOnlyResult.StdOut) {
            $stagedFiles = $nameOnlyResult.StdOut -split "`n" | Where-Object { $_ -ne '' }
        }

        $submodulePaths      = Get-SubmodulePaths -repoAbsPath $absPath
        $containsPinAdvance  = $false
        $allStagesArePins    = $false
        if ($stagedFiles.Count -gt 0) {
            $pinFiles    = $stagedFiles | Where-Object { $_.Replace('\', '/') -in $submodulePaths }
            $nonPinFiles = $stagedFiles | Where-Object { $_.Replace('\', '/') -notin $submodulePaths }
            $containsPinAdvance = $pinFiles.Count -gt 0
            $allStagesArePins   = ($pinFiles.Count -gt 0) -and ($nonPinFiles.Count -eq 0)
        }

        $commitMsg = if ($allStagesArePins) { $PinMessage } else { $Message }

        $target = if ($repo.Path) { "$repoName ($($repo.Path))" } else { $repoName }
        if (-not $PSCmdlet.ShouldProcess($target, "git commit -m `"$commitMsg`"")) {
            [PSCustomObject]@{ PSTypeName = 'Og.CommitResult';
                Repo               = $repoName
                Path               = $repo.Path
                Action             = 'would-commit'
                Sha                = $null
                Message            = $commitMsg
                ContainsPinAdvance = $containsPinAdvance
            }
            continue
        }

        $commitArgs = @('commit', '-m', $commitMsg)
        if ($AllowEmpty) { $commitArgs += '--allow-empty' }

        $commitResult = Invoke-Git -WorkingDirectory $absPath -Arguments $commitArgs
        if ($commitResult.ExitCode -ne 0) {
            Write-Error "git commit failed in '$repoName': $($commitResult.StdErr)"
            [PSCustomObject]@{ PSTypeName = 'Og.CommitResult';
                Repo               = $repoName
                Path               = $repo.Path
                Action             = 'failed'
                Sha                = $null
                Message            = $commitMsg
                ContainsPinAdvance = $containsPinAdvance
            }
            continue
        }

        # Capture new HEAD SHA
        $shaResult = Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', 'HEAD'
        $newShaFull = if ($shaResult.ExitCode -eq 0) { $shaResult.StdOut } else { $null }
        $newShaShort = if ($newShaFull) {
            (Invoke-Git -WorkingDirectory $absPath -Arguments 'rev-parse', '--short', 'HEAD').StdOut
        } else { $null }

        # Cascade: stage pin advance in immediate parent
        $parentNode = $parentOf[$absPath]
        if ($parentNode -and $newShaFull) {
            $parentAbsPath    = $parentNode.AbsolutePath
            $childRelInParent = Get-PathInParent $absPath $parentAbsPath
            if (Test-Path -LiteralPath $parentAbsPath) {
                $addResult = Invoke-Git -WorkingDirectory $parentAbsPath `
                    -Arguments 'add', $childRelInParent
                if ($addResult.ExitCode -ne 0) {
                    Write-Warning "Failed to stage pin advance for '$repoName' in '$($parentNode.Name)': $($addResult.StdErr)"
                }
            }
        }

        [PSCustomObject]@{ PSTypeName = 'Og.CommitResult';
            Repo               = $repoName
            Path               = $repo.Path
            Action             = 'committed'
            Sha                = $newShaShort
            Message            = $commitMsg
            ContainsPinAdvance = $containsPinAdvance
        }
    }
}
