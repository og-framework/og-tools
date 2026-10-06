# SPDX-License-Identifier: MPL-2.0
function Resolve-OgUnrealEngineRoot {
    <#
    .SYNOPSIS
        Resolves the Unreal Engine root folder for a .uproject.

    .DESCRIPTION
        Resolution order:
          1. -EngineRoot, when given (no fallback if it is invalid).
          2. EngineAssociation = '{GUID}': value <GUID> of HKCU:\Software\Epic Games\Unreal Engine\Builds (source builds).
          3. EngineAssociation = version (e.g. '5.6'): InstalledDirectory of HKLM:\SOFTWARE\EpicGames\Unreal Engine\<version> (launcher installs).
        The result must contain Engine\Build\BatchFiles\RunUAT.bat; otherwise this throws, naming what was tried.

    .PARAMETER ProjectFile
        Path to the .uproject.

    .PARAMETER EngineRoot
        Explicit engine root; wins over the .uproject association.

    .OUTPUTS
        [string] absolute engine root path.

    .EXAMPLE
        Resolve-OgUnrealEngineRoot -ProjectFile C:\dev\game\Game.uproject
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectFile,

        [string] $EngineRoot
    )

    $runUatRelative = 'Engine\Build\BatchFiles\RunUAT.bat'

    if ($EngineRoot) {
        $full = [System.IO.Path]::GetFullPath($EngineRoot)
        if (-not (Test-Path -LiteralPath (Join-Path $full $runUatRelative) -PathType Leaf)) {
            throw "Resolve-OgUnrealEngineRoot: explicit -EngineRoot '$full' does not contain $runUatRelative."
        }
        return $full
    }

    if (-not (Test-Path -LiteralPath $ProjectFile -PathType Leaf)) {
        throw "Resolve-OgUnrealEngineRoot: project file '$ProjectFile' does not exist."
    }

    $association = [string](Get-Content -LiteralPath $ProjectFile -Raw | ConvertFrom-Json).EngineAssociation
    if ([string]::IsNullOrWhiteSpace($association)) {
        throw "Resolve-OgUnrealEngineRoot: '$ProjectFile' has no EngineAssociation; pass -EngineRoot."
    }

    if ($association -match '^\{[0-9A-Fa-f-]+\}$') {
        $key       = 'HKCU:\Software\Epic Games\Unreal Engine\Builds'
        $valueName = $association
    }
    elseif ($association -match '^\d+\.\d+$') {
        $key       = "HKLM:\SOFTWARE\EpicGames\Unreal Engine\$association"
        $valueName = 'InstalledDirectory'
    }
    else {
        throw "Resolve-OgUnrealEngineRoot: EngineAssociation '$association' in '$ProjectFile' is neither a {GUID} nor a version like 5.6; pass -EngineRoot."
    }

    $tried = "EngineAssociation '$association' -> registry '$key' value '$valueName'"
    $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    $value = if ($props) { [string]$props.$valueName } else { '' }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Resolve-OgUnrealEngineRoot: $tried not found; pass -EngineRoot."
    }

    $full = [System.IO.Path]::GetFullPath($value)
    if (-not (Test-Path -LiteralPath (Join-Path $full $runUatRelative) -PathType Leaf)) {
        throw "Resolve-OgUnrealEngineRoot: $tried = '$full', which does not contain $runUatRelative."
    }
    $full
}
