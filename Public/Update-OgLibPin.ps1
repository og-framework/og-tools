# SPDX-License-Identifier: MPL-2.0
function Update-OgLibPin {
    <#
    .SYNOPSIS
        Stages a submodule's pin advance in its immediate parent without committing.

    .DESCRIPTION
        Locates the named submodule in the repo tree by matching -Submodule against the
        Name (path basename) or full Path field of each node returned by Resolve-OgRepoTree.
        Stages the pin advance (git add) in the immediate parent repo.

        Resolution rules:
        - If -Submodule matches exactly one node by Name (basename): use that node.
        - If -Submodule matches exactly one node by full Path: use that node.
        - If multiple nodes match the same Name: throw with a list of candidates — the
          caller must use the full relative path to disambiguate.
        - If no node matches: throw with a list of all available Names.

        Does NOT commit. The caller reviews the staged state then runs New-OgCommit
        (or oggitcommit) to commit.

    .PARAMETER Submodule
        Name or relative path of the submodule to pin. Basename (e.g., 'og-simulation')
        is sufficient when unambiguous. Full relative path (e.g.,
        'Plugins/OGSimulation/Source/OGSimulation/og-simulation') resolves ambiguity.

    .PARAMETER Sha
        The SHA to pin to. Defaults to the current HEAD of the submodule's local clone.

    .PARAMETER IncludeAncestors
        When set, also stages the immediate parent's own pointer update in the grandparent,
        continuing up to the project root. Useful for advancing a deep submodule pin all
        the way through a multi-level chain without running New-OgCommit first.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to the current working directory.

    .EXAMPLE
        Update-OgLibPin -Submodule og-simulation -WhatIf
        # Shows which parent repo would have its pin staged.

    .EXAMPLE
        Update-OgLibPin -Submodule og-simulation -IncludeAncestors
        # Stages og-simulation's pin in OGSimulation, then OGSimulation's pin in
        # the project root.

    .EXAMPLE
        Update-OgLibPin -Submodule "Plugins/OGSimulation/Source/OGSimulation/og-simulation"
        # Uses full path for disambiguation when two submodules share the same basename.

    .OUTPUTS
        PSCustomObject — one per repo touched:
          Repo, Path, Action ('staged'|'no-change'|'would-stage'|'failed'), OldPin, NewPin
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Submodule,

        [Parameter(Position = 1)]
        [string] $Sha,

        [switch] $IncludeAncestors,

        [string] $ProjectRoot = (Get-Location).Path
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
    $tree        = @(Resolve-OgRepoTree -ProjectRoot $ProjectRoot)

    # Resolve the submodule node
    $normInput = $Submodule.Replace('\', '/')

    # First try exact Path match (forward-slash, case-insensitive)
    $pathMatches = @($tree | Where-Object { -not $_.IsParent -and $_.Path.Replace('\', '/') -eq $normInput })
    if ($pathMatches.Count -eq 1) {
        $targetNode = $pathMatches[0]
    } elseif ($pathMatches.Count -gt 1) {
        $candidates = ($pathMatches | ForEach-Object { $_.Path }) -join ', '
        Write-Error "Ambiguous path '$Submodule' matched multiple submodules: $candidates"
        return
    } else {
        # Try basename match
        $nameMatches = @($tree | Where-Object { -not $_.IsParent -and $_.Name -eq $normInput })
        if ($nameMatches.Count -eq 0) {
            $available = ($tree | Where-Object { -not $_.IsParent } | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', '
            Write-Error "Submodule '$Submodule' not found in tree. Available basenames: $available"
            return
        } elseif ($nameMatches.Count -gt 1) {
            $candidates = ($nameMatches | ForEach-Object { "  $($_.Path)" }) -join "`n"
            Write-Error "Basename '$Submodule' is ambiguous — multiple submodules match:`n$candidates`nUse the full relative path to disambiguate."
            return
        }
        $targetNode = $nameMatches[0]
    }

    # Build parent lookup: for each node find the immediate parent in the tree
    # (deepest ancestor whose path is a prefix)
    function Find-ImmediateParent {
        param($node, $allNodes)
        $nodePath = $node.Path.Replace('\', '/')
        $bestParent     = $null
        $bestParentDepth = -1
        foreach ($candidate in $allNodes) {
            $candidatePath = $candidate.Path.Replace('\', '/')
            if ($candidatePath -eq $nodePath) { continue }
            if ($candidatePath -eq '') {
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
        $bestParent
    }

    # Build the chain: start from targetNode, walk up via IncludeAncestors
    $chain = [System.Collections.Generic.List[hashtable]]::new()
    $currentNode = $targetNode
    $currentSha  = $Sha

    do {
        $parentNode = Find-ImmediateParent -node $currentNode -allNodes $tree
        if (-not $parentNode) { break }

        $childRelInParent = $currentNode.AbsolutePath.Replace('\', '/').Substring(
            $parentNode.AbsolutePath.Replace('\', '/').Length).TrimStart('/')

        $chain.Add(@{
            SourceNode        = $currentNode
            ParentNode        = $parentNode
            ChildRelInParent  = $childRelInParent
            Sha               = $currentSha
        })

        # For ancestor steps, Sha comes from the parent's current HEAD after staging
        $currentSha  = $null
        $currentNode = $parentNode

    } while ($IncludeAncestors -and -not $currentNode.IsParent)

    foreach ($step in $chain) {
        $sourceNode       = $step.SourceNode
        $parentNode       = $step.ParentNode
        $childRelInParent = $step.ChildRelInParent
        $sourceAbs        = $sourceNode.AbsolutePath
        $parentAbs        = $parentNode.AbsolutePath

        if (-not (Test-Path -LiteralPath $sourceAbs)) {
            Write-Error "Source path not found on disk: $sourceAbs"
            [PSCustomObject]@{ PSTypeName = 'Og.PinUpdateResult'; Repo = $parentNode.Name; Path = $sourceNode.Path; Action = 'failed'; OldPin = $null; NewPin = $null }
            continue
        }

        # Get current pinned SHA from parent's index
        $lsResult = Invoke-Git -WorkingDirectory $parentAbs -Arguments 'ls-tree', 'HEAD', '--', $childRelInParent
        $oldPin = $null
        if ($lsResult.ExitCode -eq 0 -and $lsResult.StdOut -match '\b([0-9a-f]{40})\b') {
            $oldPin = $Matches[1].Substring(0, 7)
        }

        # Determine target SHA
        $targetSha = $step.Sha
        if (-not $targetSha) {
            $headResult = Invoke-Git -WorkingDirectory $sourceAbs -Arguments 'rev-parse', 'HEAD'
            if ($headResult.ExitCode -ne 0) {
                Write-Error "Could not determine HEAD of '$($sourceNode.Path)': $($headResult.StdErr)"
                [PSCustomObject]@{ PSTypeName = 'Og.PinUpdateResult'; Repo = $parentNode.Name; Path = $sourceNode.Path; Action = 'failed'; OldPin = $oldPin; NewPin = $null }
                continue
            }
            $targetSha = $headResult.StdOut
        }
        $newPin = $targetSha.Substring(0, [Math]::Min(7, $targetSha.Length))

        if ($oldPin -and $targetSha.StartsWith($oldPin)) {
            [PSCustomObject]@{ PSTypeName = 'Og.PinUpdateResult';
                Repo   = $parentNode.Name
                Path   = $sourceNode.Path
                Action = 'no-change'
                OldPin = $oldPin
                NewPin = $newPin
            }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("$($parentNode.Name) -> $childRelInParent", "git add (pin $oldPin -> $newPin)")) {
            [PSCustomObject]@{ PSTypeName = 'Og.PinUpdateResult';
                Repo   = $parentNode.Name
                Path   = $sourceNode.Path
                Action = 'would-stage'
                OldPin = $oldPin
                NewPin = $newPin
            }
            continue
        }

        # For the first step: if a specific SHA was requested, checkout that SHA first
        if ($step -eq $chain[0] -and $Sha) {
            $coResult = Invoke-Git -WorkingDirectory $sourceAbs -Arguments 'checkout', $targetSha
            if ($coResult.ExitCode -ne 0) {
                Write-Error "Failed to checkout '$targetSha' in '$($sourceNode.Path)': $($coResult.StdErr)"
                [PSCustomObject]@{ PSTypeName = 'Og.PinUpdateResult'; Repo = $parentNode.Name; Path = $sourceNode.Path; Action = 'failed'; OldPin = $oldPin; NewPin = $newPin }
                continue
            }
        }

        $addResult = Invoke-Git -WorkingDirectory $parentAbs -Arguments 'add', $childRelInParent
        if ($addResult.ExitCode -ne 0) {
            Write-Error "git add failed in '$($parentNode.Name)': $($addResult.StdErr)"
            [PSCustomObject]@{ PSTypeName = 'Og.PinUpdateResult'; Repo = $parentNode.Name; Path = $sourceNode.Path; Action = 'failed'; OldPin = $oldPin; NewPin = $newPin }
            continue
        }

        [PSCustomObject]@{ PSTypeName = 'Og.PinUpdateResult';
            Repo   = $parentNode.Name
            Path   = $sourceNode.Path
            Action = 'staged'
            OldPin = $oldPin
            NewPin = $newPin
        }
    }
}
