# SPDX-License-Identifier: MPL-2.0

# What `oggitdiff -From <A> -IncludeWorkingTree` compares, repo by repo (Backlog od task 10, R3).

function Get-OgDiffWorkingRangeItem {
    <#
    .SYNOPSIS
        Pairs the pins of root commit <A> (Get-OgTreePins) with the og tree as it is checked out now
        (Resolve-OgRepoTree) and says, per repo and in tree order, how Show-OgDiff -From <A>
        -IncludeWorkingTree compares it.

    .DESCRIPTION
        Every repo of the CURRENT tree gets one item, plus every repo <A> pins that the current tree no
        longer has. Kind says what to do with it:

          working          in the current tree, checked out (its folder is its own work tree's top): compare
                           its working tree with its pin at <A>, Pin.Pin. Pin.Pin is '' when <A> does not
                           contain the repo (Pin.Status 'absent'): an EMPTY base, every file Added.
          gone             <A> pins it (Pin.Status 'present'), the current tree does not list it: <A>'s
                           files against an empty head, read from Pin.GitDir when Pin.HasWorkTree is $false.
          missing-commit   its pin at <A> is not present locally (Pin.Error says why).
          unknown          in the current tree, below a repo whose pin at <A> is missing (Above): <A>'s
                           pins below that repo cannot be read, so this repo's pin at <A> is unknown. Never
                           reported as absent: that would claim <A> lacks it.
          not-checked-out  in the current tree, but its folder is missing or is not its own work tree (an
                           uninitialised or deinit-ed submodule: git run there would reach the PARENT repo).
                           There is no working tree to compare; the caller skips it, as the default mode
                           skips a missing folder. So is every repo <A> pins BELOW such a repo: the current
                           tree cannot list what lies inside a repo that is not checked out, so such a repo
                           is not 'gone' (that would show it as removed).

        Tree order is Get-OgTreePins' order (the root, then depth-first, siblings in git's path order;
        absent repos already in place). The unknown repos follow the missing-commit repo above them, in
        Resolve-OgRepoTree's order: nothing else of <A> lies below that repo, so its subtree is exactly
        the slot right after it.

        The only git call is the own-work-tree test (Get-OgCommitRangeOwnWorkTree) for a repo absent at
        <A>; for a repo present at <A>, Get-OgTreePins already ran it on the same folder (HasWorkTree).

    .PARAMETER Pin
        Get-OgTreePins -Commit <A> -RepoTree <the same tree>: one Og.TreePin per repo, tree order.

    .PARAMETER RepoTree
        Resolve-OgRepoTree's output for the project root: the og tree as it is checked out now.

    .OUTPUTS
        PSCustomObject per repo: Kind, Repo (Name, Path, AbsolutePath, as Resolve-OgRepoTree's entries),
        Pin (the Og.TreePin, or $null for 'unknown'), Above (the missing-commit Og.TreePin above an
        'unknown' repo, else $null).

    .EXAMPLE
        $tree = @(Resolve-OgRepoTree -ProjectRoot $root)
        Get-OgDiffWorkingRangeItem -Pin @(Get-OgTreePins -ProjectRoot $root -Commit 758fb77 -RepoTree $tree) -RepoTree $tree
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Pin,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $RepoTree
    )

    # Ordinal: two paths that differ only in case are two repos to git.
    $nodeByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($node in $RepoTree) { $nodeByPath[$node.Path.Replace('\', '/')] = $node }
    $pinPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($p in $Pin) { [void] $pinPaths.Add($p.Path) }
    # Filled in tree order (a repo before the repos below it), so a nested pin sees its parent's verdict.
    $notCheckedOut = [System.Collections.Generic.List[string]]::new()

    foreach ($p in $Pin) {
        $node = if ($nodeByPath.ContainsKey($p.Path)) { $nodeByPath[$p.Path] } else { $null }
        $repo = [PSCustomObject]@{
            Name         = $p.Repo
            Path         = $p.Path
            AbsolutePath = if ($node) { $node.AbsolutePath } else { $p.WorkingDirectory }
        }

        $kind = switch ($p.Status) {
            'missing-commit' { 'missing-commit' }
            'absent' {
                # Get-OgTreePins knows nothing about an absent repo's folder: test it here.
                if (Get-OgCommitRangeOwnWorkTree -Directory $repo.AbsolutePath) { 'working' } else { 'not-checked-out' }
            }
            default {
                # Present at <A>. HasWorkTree is Get-OgTreePins' own-work-tree test of this very folder.
                if ($node) { if ($p.HasWorkTree) { 'working' } else { 'not-checked-out' } }
                elseif (Test-OgTreePathUnder -Path $p.Path -Ancestor $notCheckedOut) { 'not-checked-out' }
                else { 'gone' }
            }
        }
        if ($kind -eq 'not-checked-out') { $notCheckedOut.Add($p.Path) }
        [PSCustomObject]@{ Kind = $kind; Repo = $repo; Pin = $p; Above = $null }

        if ($p.Status -eq 'missing-commit') {
            foreach ($treeNode in $RepoTree) {
                $path = $treeNode.Path.Replace('\', '/')
                if (-not $path -or $pinPaths.Contains($path)) { continue }
                if (-not (Test-OgTreePathUnder -Path $path -Ancestor @($p.Path))) { continue }
                [PSCustomObject]@{
                    Kind  = 'unknown'
                    Repo  = [PSCustomObject]@{ Name = $treeNode.Name; Path = $path; AbsolutePath = $treeNode.AbsolutePath }
                    Pin   = $null
                    Above = $p
                }
            }
        }
    }
}
