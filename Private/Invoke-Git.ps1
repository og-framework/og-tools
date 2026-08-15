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

    # Drain both pipes concurrently BEFORE WaitForExit. Reading one stream to end while
    # the other's OS pipe buffer fills (>~4KB) would deadlock a large git error dump
    # (e.g. a merge/checkout refusal listing hundreds of files in a UE-sized repo).
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    [PSCustomObject]@{
        ExitCode         = $proc.ExitCode
        StdOut           = $stdout.TrimEnd("`r", "`n")
        StdErr           = $stderr.TrimEnd("`r", "`n")
        WorkingDirectory = $WorkingDirectory
    }
}
