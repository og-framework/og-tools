# SPDX-License-Identifier: MPL-2.0
function Invoke-Git {
    <#
    .SYNOPSIS
        Thin wrapper around git.exe returning stdout, stderr, exit code, and working directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory, ValueFromRemainingArguments)]
        [string[]] $Arguments
    )

    Write-Verbose "git $($Arguments -join ' ')  [in: $WorkingDirectory]"

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'git'
    $psi.WorkingDirectory       = $WorkingDirectory
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    foreach ($arg in $Arguments) { $psi.ArgumentList.Add($arg) }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    [PSCustomObject]@{
        ExitCode         = $proc.ExitCode
        StdOut           = $stdout.TrimEnd("`r", "`n")
        StdErr           = $stderr.TrimEnd("`r", "`n")
        WorkingDirectory = $WorkingDirectory
    }
}
