# SPDX-License-Identifier: MPL-2.0
function Resolve-OgRepoTree {
    <#
    .SYNOPSIS
        Walks .gitmodules depth-first from the project root and returns one PSCustomObject
        per repo (parent first, then depth-first submodules).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectRoot
    )

    # Emit the parent first
    $parentRemote = ''
    $remoteResult = Invoke-Git -WorkingDirectory $ProjectRoot -Arguments 'remote', 'get-url', 'origin'
    if ($remoteResult.ExitCode -eq 0) { $parentRemote = $remoteResult.StdOut }

    [PSCustomObject]@{
        Name         = Split-Path $ProjectRoot -Leaf
        Path         = ''
        AbsolutePath = $ProjectRoot
        RemoteUrl    = $parentRemote
        IsParent     = $true
        Depth        = 0
        TreePrefix   = ''
    }

    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    ParseGitmodulesRecursive `
        -RepoRoot       $ProjectRoot `
        -RelativeBase   '' `
        -ProjectRoot    $ProjectRoot `
        -Visited        $visited `
        -Depth          1 `
        -AncestorsLast  @()
}

function ParseGitmodulesRecursive {
    param(
        [string]   $RepoRoot,
        [string]   $RelativeBase,
        [string]   $ProjectRoot,
        [System.Collections.Generic.HashSet[string]] $Visited,
        [int]      $Depth,
        [bool[]]   $AncestorsLast
    )

    $gmPath = Join-Path $RepoRoot '.gitmodules'
    if (-not (Test-Path -LiteralPath $gmPath)) { return }

    # Pre-filter for visited dedup so $i / $count reflect entries we'll actually emit
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($entry in (ReadGitmodulesFile -Path $gmPath)) {
        $subRelToParent  = $entry.Path.Replace('\', '/')
        $subRelToProject = if ($RelativeBase) { "$RelativeBase/$subRelToParent" } else { $subRelToParent }
        $subRelToProject = $subRelToProject.Replace('\', '/')
        if ($Visited.Add($subRelToProject)) {
            $entries.Add(@{
                Entry           = $entry
                SubRelToProject = $subRelToProject
            })
        }
    }

    $count = $entries.Count
    for ($i = 0; $i -lt $count; $i++) {
        $entry           = $entries[$i].Entry
        $subRelToProject = $entries[$i].SubRelToProject
        $isLastSibling   = ($i -eq $count - 1)

        $absPath = Join-Path $ProjectRoot ($subRelToProject.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        $subName = Split-Path $subRelToProject -Leaf

        $remoteUrl = $entry.Url
        if (Test-Path -LiteralPath $absPath) {
            $rr = Invoke-Git -WorkingDirectory $absPath -Arguments 'remote', 'get-url', 'origin'
            if ($rr.ExitCode -eq 0) { $remoteUrl = $rr.StdOut }
        }

        $prefix = ''
        foreach ($wasLast in $AncestorsLast) {
            $prefix += if ($wasLast) { '   ' } else { '|  ' }
        }
        $prefix += if ($isLastSibling) { '\- ' } else { '+- ' }

        [PSCustomObject]@{
            Name         = $subName
            Path         = $subRelToProject
            AbsolutePath = $absPath
            RemoteUrl    = $remoteUrl
            IsParent     = $false
            Depth        = $Depth
            TreePrefix   = $prefix
        }

        if (Test-Path -LiteralPath $absPath) {
            ParseGitmodulesRecursive `
                -RepoRoot       $absPath `
                -RelativeBase   $subRelToProject `
                -ProjectRoot    $ProjectRoot `
                -Visited        $Visited `
                -Depth          ($Depth + 1) `
                -AncestorsLast  ($AncestorsLast + $isLastSibling)
        }
    }
}

function ReadGitmodulesFile {
    param([string] $Path)

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $current = $null

    foreach ($rawLine in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $line = $rawLine.Trim()
        if ($line -match '^\[submodule\s') {
            if ($null -ne $current) { $entries.Add($current) }
            $current = @{ Path = ''; Url = '' }
        } elseif ($null -ne $current) {
            if    ($line -match '^path\s*=\s*(.+)$') { $current.Path = $Matches[1].Trim() }
            elseif ($line -match '^url\s*=\s*(.+)$') { $current.Url  = $Matches[1].Trim() }
        }
    }
    if ($null -ne $current) { $entries.Add($current) }
    $entries
}
