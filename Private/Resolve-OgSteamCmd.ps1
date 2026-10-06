# SPDX-License-Identifier: MPL-2.0
function Resolve-OgSteamCmd {
    <#
    .SYNOPSIS
        Returns the path of steamcmd.exe.

    .DESCRIPTION
        Resolution order:
          1. -Path, when given.
          2. $env:OG_STEAMCMD, when set.
          3. The Install-OgSteamCmd default location: $env:LOCALAPPDATA\og-tools\steamcmd\steamcmd.exe.
          4. steamcmd.exe on PATH.
        -Path and $env:OG_STEAMCMD may name steamcmd.exe or the folder containing it. When either is
        given but does not exist, this throws instead of falling back to a later source.
        When nothing is found, this throws with the Install-OgSteamCmd command to run.

    .PARAMETER Path
        Explicit steamcmd.exe (or its folder); wins over every other source.

    .OUTPUTS
        [string] absolute path of steamcmd.exe.

    .EXAMPLE
        Resolve-OgSteamCmd

    .EXAMPLE
        Resolve-OgSteamCmd -Path D:\tools\steamcmd
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Path
    )

    $exeName = 'steamcmd.exe'

    $explicit = @(
        @{ Source = '-Path';            Value = $Path }
        @{ Source = '$env:OG_STEAMCMD'; Value = $env:OG_STEAMCMD }
    )
    foreach ($candidate in $explicit) {
        if ([string]::IsNullOrWhiteSpace($candidate.Value)) { continue }
        $full = [System.IO.Path]::GetFullPath($candidate.Value)
        if (Test-Path -LiteralPath $full -PathType Container) {
            $full = Join-Path $full $exeName
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Resolve-OgSteamCmd: $($candidate.Source) = '$($candidate.Value)', but '$full' does not exist."
        }
        return $full
    }

    $tried = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $default = Join-Path $env:LOCALAPPDATA "og-tools\steamcmd\$exeName"
        $tried.Add($default)
        if (Test-Path -LiteralPath $default -PathType Leaf) {
            return $default
        }
    }

    $tried.Add("$exeName on PATH")
    $onPath = Get-Command -Name $exeName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) {
        return $onPath.Source
    }

    throw "Resolve-OgSteamCmd: steamcmd not found (tried: $($tried -join '; ')). Run Install-OgSteamCmd, or set `$env:OG_STEAMCMD to an existing steamcmd.exe."
}
