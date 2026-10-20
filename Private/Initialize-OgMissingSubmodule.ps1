# SPDX-License-Identifier: MPL-2.0
function Initialize-OgMissingSubmodule {
    <#
    .SYNOPSIS
        Initialises every submodule that is declared in an initialised repo's .gitmodules but
        not yet initialised on disk, by running 'git submodule update --init -- <paths>' in
        each owning repo. Repeats until no new repo appears, so submodules declared inside a
        freshly initialised submodule are picked up too.

    .DESCRIPTION
        A submodule is "missing" when its directory has no '.git' (git leaves an EMPTY
        directory for an uninitialised gitlink, so the directory alone proves nothing).
        Used by Sync-OgFramework (a submodule that another clone added) and Merge-OgToMain
        (a submodule that is new on main after the cascade).

        Honours -WhatIf / $WhatIfPreference: each owner is one ShouldProcess call, and a
        declined call yields Action='would-init'.

        Each initialised submodule is left where 'git submodule update' leaves it: detached
        at the commit its owner pins. Callers that want a branch checked out do that next.

    .OUTPUTS
        PSCustomObject, one per missing submodule:
          Repo, Path (project-relative), Owner, Action ('initialised'|'would-init'|'failed'),
          Sha (short, $null unless initialised), Error
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectRoot,

        # Project-relative paths to leave alone (already reported by an earlier pass).
        [string[]] $SkipPath = @()
    )

    $attempted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $SkipPath) { if ($p) { [void]$attempted.Add($p) } }

    while ($true) {
        $tree = @(Resolve-OgRepoTree -ProjectRoot $ProjectRoot)

        # Group the missing submodules by their (initialised) owner. A missing repo whose
        # owner is itself missing waits for the next round.
        $byOwner = [ordered]@{}
        foreach ($node in $tree) {
            if ($node.IsParent) { continue }
            if (Test-OgRepoInitialised -AbsolutePath $node.AbsolutePath) { continue }
            if ($attempted.Contains($node.Path)) { continue }

            $owner = Find-OgOwnerRepo -Tree $tree -RelPath $node.Path
            if (-not $owner) { continue }

            $key = $owner.Node.AbsolutePath
            if (-not $byOwner.Contains($key)) {
                $byOwner[$key] = [PSCustomObject]@{
                    Owner   = $owner.Node
                    Entries = [System.Collections.Generic.List[object]]::new()
                }
            }
            $byOwner[$key].Entries.Add([PSCustomObject]@{ Node = $node; RelToOwner = $owner.RelToOwner })
        }

        if ($byOwner.Count -eq 0) { return }

        $progress = $false
        foreach ($group in $byOwner.Values) {
            $owner      = $group.Owner
            $ownerLabel = if ($owner.IsParent) { $owner.Name } else { $owner.Path }
            $relPaths   = @($group.Entries | ForEach-Object { $_.RelToOwner })
            foreach ($e in $group.Entries) { [void]$attempted.Add($e.Node.Path) }

            if (-not $PSCmdlet.ShouldProcess($ownerLabel, "git submodule update --init -- $($relPaths -join ' ')")) {
                foreach ($e in $group.Entries) {
                    [PSCustomObject]@{
                        Repo   = $e.Node.Name
                        Path   = $e.Node.Path
                        Owner  = $ownerLabel
                        Action = 'would-init'
                        Sha    = $null
                        Error  = $null
                    }
                }
                continue
            }

            $result = Invoke-Git -WorkingDirectory $owner.AbsolutePath `
                -Arguments (@('submodule', 'update', '--init', '--') + $relPaths)

            foreach ($e in $group.Entries) {
                $ok = Test-OgRepoInitialised -AbsolutePath $e.Node.AbsolutePath
                $sha = $null
                if ($ok) {
                    $progress = $true
                    $shaResult = Invoke-Git -WorkingDirectory $e.Node.AbsolutePath -Arguments 'rev-parse', '--short', 'HEAD'
                    if ($shaResult.ExitCode -eq 0) { $sha = $shaResult.StdOut }
                } else {
                    Write-Warning "Could not initialise submodule '$($e.Node.Path)' in '$ownerLabel': $($result.StdErr)"
                }
                [PSCustomObject]@{
                    Repo   = $e.Node.Name
                    Path   = $e.Node.Path
                    Owner  = $ownerLabel
                    Action = if ($ok) { 'initialised' } else { 'failed' }
                    Sha    = $sha
                    Error  = if ($ok) { $null } else { $result.StdErr }
                }
            }
        }

        # Nothing new on disk (all declined or failed): another round cannot find more.
        if (-not $progress) { return }
    }
}
