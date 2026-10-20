# SPDX-License-Identifier: MPL-2.0
function Resolve-OgProjectFile {
    <#
    .SYNOPSIS
        Resolves the .uproject a cmdlet works on: the given path, or the single .uproject in the current directory.

    .PARAMETER ProjectFile
        Explicit path. When empty, the current directory must hold exactly one .uproject.

    .PARAMETER CallerName
        Name used in error messages.

    .OUTPUTS
        [string] absolute path to an existing .uproject.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $ProjectFile,

        [string] $CallerName = 'Resolve-OgProjectFile'
    )

    if ($ProjectFile) {
        $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectFile)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "${CallerName}: project file '$path' does not exist."
        }
        return $path
    }

    $here = (Get-Location).ProviderPath
    $found = @(Get-ChildItem -LiteralPath $here -Filter '*.uproject' -File -ErrorAction SilentlyContinue)
    if ($found.Count -ne 1) {
        throw "${CallerName}: found $($found.Count) .uproject files in '$here'; run it from the project root or pass -ProjectFile."
    }
    $found[0].FullName
}
