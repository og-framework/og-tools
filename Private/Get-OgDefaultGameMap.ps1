# SPDX-License-Identifier: MPL-2.0
function Get-OgDefaultGameMap {
    <#
    .SYNOPSIS
        Reads GameDefaultMap from a project's Config\DefaultEngine.ini and returns its package path.

    .DESCRIPTION
        GameDefaultMap is written as an object path ('/Game/Maps/Arena.Arena'); this returns the package path ('/Game/Maps/Arena'),
        which is what a server URL takes. Throws when the setting is missing.

    .PARAMETER ProjectDirectory
        The folder that holds the .uproject.

    .OUTPUTS
        [string] the map's package path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectDirectory
    )

    $ini = Join-Path $ProjectDirectory 'Config\DefaultEngine.ini'
    $line = if (Test-Path -LiteralPath $ini -PathType Leaf) {
        Get-Content -LiteralPath $ini | Where-Object { $_ -match '^\s*GameDefaultMap\s*=' } | Select-Object -First 1
    }
    if (-not $line) {
        throw "Get-OgDefaultGameMap: no GameDefaultMap in '$ini'; pass -Map."
    }
    $value = ($line -split '=', 2)[1].Trim()
    ($value -split '\.', 2)[0]
}
