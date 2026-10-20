# SPDX-License-Identifier: MPL-2.0
function ConvertTo-OgRepoRelativePath {
    <#
    .SYNOPSIS
        Normalises a project-relative path: forward slashes, no leading './', no leading or
        trailing slash. Throws on an absolute path or a '..' segment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $p = $Path.Trim().Replace('\', '/')
    if ([System.IO.Path]::IsPathRooted($p) -or $p -match '^[A-Za-z]:') {
        throw "Path must be relative to the project root, not absolute: '$Path'"
    }
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    $p = $p.Trim('/')
    if (-not $p) { throw "Path must name a directory below the project root: '$Path'" }
    if (($p -split '/') -contains '..') { throw "Path must not contain '..': '$Path'" }
    $p
}

function Test-OgRepoInitialised {
    <#
    .SYNOPSIS
        True when the directory exists and holds its own '.git' (a directory, or a gitfile
        for an absorbed submodule). An uninitialised submodule is an EMPTY directory, so
        Test-Path on the directory alone is not enough: running git there would act on the
        enclosing repo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $AbsolutePath
    )
    Test-Path -LiteralPath (Join-Path $AbsolutePath '.git')
}

function Find-OgOwnerRepo {
    <#
    .SYNOPSIS
        Returns the deepest repo in a Resolve-OgRepoTree result whose directory strictly
        contains the given project-relative path, plus the path relative to that repo.

    .DESCRIPTION
        "Strictly contains": a node whose Path equals RelPath is the repo itself, not its
        owner, so it is skipped. Only repos initialised on disk qualify (an uninitialised
        submodule cannot own anything yet). The project root owns everything that no
        submodule claims.

        Returns $null when no initialised repo owns the path.

    .OUTPUTS
        PSCustomObject: Node (the tree node), RelToOwner (string, forward slashes)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Tree,

        [Parameter(Mandatory)]
        [string] $RelPath
    )

    $target = $RelPath.Replace('\', '/').Trim('/')
    $best      = $null
    $bestDepth = -1
    foreach ($node in $Tree) {
        $nodePath = $node.Path.Replace('\', '/')
        if ($nodePath -eq $target) { continue }
        $depth = if ($nodePath -eq '') { 0 } else { ($nodePath -split '/').Count }
        $contains = ($nodePath -eq '') -or $target.StartsWith($nodePath + '/', [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $contains -or $depth -le $bestDepth) { continue }
        if (-not (Test-OgRepoInitialised -AbsolutePath $node.AbsolutePath)) { continue }
        $best      = $node
        $bestDepth = $depth
    }

    if (-not $best) { return $null }

    $ownerPath  = $best.Path.Replace('\', '/')
    $relToOwner = if ($ownerPath -eq '') { $target } else { $target.Substring($ownerPath.Length).TrimStart('/') }
    [PSCustomObject]@{
        Node       = $best
        RelToOwner = $relToOwner
    }
}

function Get-OgSubmoduleDeclaration {
    <#
    .SYNOPSIS
        Reads a repo's .gitmodules and returns one object per declared submodule:
        Name (the [submodule "<name>"] key, which names .git/modules/<name>), Path, Url.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoPath
    )

    $gm = Join-Path $RepoPath '.gitmodules'
    if (-not (Test-Path -LiteralPath $gm)) { return }

    $current = $null
    foreach ($raw in (Get-Content -LiteralPath $gm -ErrorAction SilentlyContinue)) {
        $line = $raw.Trim()
        if ($line -match '^\[submodule\s+"(.+)"\]$') {
            if ($current) { [PSCustomObject]$current }
            $current = [ordered]@{ Name = $Matches[1]; Path = ''; Url = '' }
        } elseif ($current) {
            if    ($line -match '^path\s*=\s*(.+)$') { $current.Path = $Matches[1].Trim().Replace('\', '/') }
            elseif ($line -match '^url\s*=\s*(.+)$')  { $current.Url  = $Matches[1].Trim() }
        }
    }
    if ($current) { [PSCustomObject]$current }
}
