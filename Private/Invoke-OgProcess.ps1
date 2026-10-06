# SPDX-License-Identifier: MPL-2.0
function Invoke-OgProcess {
    <#
    .SYNOPSIS
        Runs an external program and returns its exit code; the single process seam for UAT and steamcmd.

    .DESCRIPTION
        Runs FilePath with ArgumentList, passing each element as one argument.

        With -LogPath, stdout and stderr are merged, streamed to the host line by line and
        teed to the log file (UTF-8, created with its parent folder if missing).

        Without -LogPath, the program is attached to the console with nothing captured, so
        interactive prompts (for example a Steam Guard code) work.

        Output lines are never written to the pipeline; the only pipeline output is the result object.
        Tests mock this function; nothing else in og-framework starts UAT or steamcmd.

    .PARAMETER FilePath
        Program to run (.exe or .bat/.cmd).

    .PARAMETER ArgumentList
        Arguments, one element per argument.

    .PARAMETER WorkingDirectory
        Working directory for the program. Defaults to the current location.

    .PARAMETER LogPath
        File the merged output is teed to. Omit to run attached to the console.

    .OUTPUTS
        [pscustomobject] with ExitCode, LogPath (or $null) and Duration ([timespan]).

    .EXAMPLE
        Invoke-OgProcess -FilePath 'C:\UE\Engine\Build\BatchFiles\RunUAT.bat' -ArgumentList 'BuildCookRun', '-project=C:\p\p.uproject' -LogPath 'C:\p\Saved\Logs\uat.log'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FilePath,

        [string[]] $ArgumentList = @(),

        [string] $WorkingDirectory = (Get-Location).ProviderPath,

        [string] $LogPath
    )

    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw "Invoke-OgProcess: working directory '$WorkingDirectory' does not exist."
    }

    Write-Verbose "$FilePath $($ArgumentList -join ' ')  [in: $WorkingDirectory]"

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Push-Location -LiteralPath $WorkingDirectory
    try {
        if ($LogPath) {
            $logDir = Split-Path -Parent $LogPath
            if ($logDir -and -not (Test-Path -LiteralPath $logDir -PathType Container)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            & $FilePath @ArgumentList 2>&1 |
                ForEach-Object { "$_" } |
                Tee-Object -FilePath $LogPath |
                Out-Host
            $exitCode = $LASTEXITCODE
        }
        else {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName         = $FilePath
            $psi.WorkingDirectory = $WorkingDirectory
            $psi.UseShellExecute  = $false
            foreach ($arg in $ArgumentList) { $psi.ArgumentList.Add($arg) }
            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.WaitForExit()
            $exitCode = $proc.ExitCode
        }
    }
    finally {
        Pop-Location
        $stopwatch.Stop()
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        LogPath  = if ($LogPath) { $LogPath } else { $null }
        Duration = $stopwatch.Elapsed
    }
}
