# SPDX-License-Identifier: MPL-2.0
function Install-OgSteamCmd {
    <#
    .SYNOPSIS
        Downloads and bootstraps Valve's steamcmd for Windows; returns the steamcmd.exe path.

    .DESCRIPTION
        Downloads https://client-update.steamstatic.com/installer/steamcmd.zip (the Windows download
        listed on https://developer.valvesoftware.com/wiki/SteamCMD) into -Destination, extracts it,
        deletes the zip and runs 'steamcmd.exe +quit' once, attached to the console, so steamcmd
        downloads its own update.

        steamcmd can exit non-zero from the run in which it updates itself. When the first bootstrap
        run exits non-zero it is run once more; only a failure of that second run is an error.

        When steamcmd.exe already exists in -Destination and -Force is not given, nothing is
        downloaded or run and the existing path is returned.

        The default -Destination is the location Resolve-OgSteamCmd checks after -Path and
        $env:OG_STEAMCMD, so later og-tools commands find this install without configuration.

    .PARAMETER Destination
        Install folder. Default: $env:LOCALAPPDATA\og-tools\steamcmd.

    .PARAMETER Force
        Download, extract and bootstrap again even when steamcmd.exe already exists.

    .OUTPUTS
        [string] absolute path of steamcmd.exe.

    .EXAMPLE
        Install-OgSteamCmd

    .EXAMPLE
        Install-OgSteamCmd -Destination D:\tools\steamcmd -Force
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateNotNullOrEmpty()]
        [string] $Destination = (Join-Path $env:LOCALAPPDATA 'og-tools\steamcmd'),

        [switch] $Force
    )

    $downloadUri = 'https://client-update.steamstatic.com/installer/steamcmd.zip'

    $Destination = [System.IO.Path]::GetFullPath($Destination)
    $exe         = Join-Path $Destination 'steamcmd.exe'

    if ((Test-Path -LiteralPath $exe -PathType Leaf) -and -not $Force) {
        Write-Verbose "Install-OgSteamCmd: '$exe' already exists; pass -Force to reinstall."
        return $exe
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $zip = Join-Path $Destination 'steamcmd.zip'
    try {
        Write-Verbose "Install-OgSteamCmd: downloading $downloadUri -> $zip"
        try {
            Invoke-WebRequest -Uri $downloadUri -OutFile $zip -ErrorAction Stop
        }
        catch {
            throw "Install-OgSteamCmd: download of $downloadUri failed: $($_.Exception.Message)"
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $Destination -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $zip -PathType Leaf) {
            Remove-Item -LiteralPath $zip -Force
        }
    }

    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Install-OgSteamCmd: '$downloadUri' did not contain steamcmd.exe (expected '$exe')."
    }

    $bootstrap = Invoke-OgProcess -FilePath $exe -ArgumentList '+quit' -WorkingDirectory $Destination
    if ($bootstrap.ExitCode -ne 0) {
        Write-Verbose "Install-OgSteamCmd: bootstrap run exited $($bootstrap.ExitCode); running '+quit' again."
        $bootstrap = Invoke-OgProcess -FilePath $exe -ArgumentList '+quit' -WorkingDirectory $Destination
        if ($bootstrap.ExitCode -ne 0) {
            throw "Install-OgSteamCmd: '$exe +quit' exited $($bootstrap.ExitCode) twice; steamcmd did not finish bootstrapping in '$Destination'."
        }
    }

    $exe
}
