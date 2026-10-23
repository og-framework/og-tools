# SPDX-License-Identifier: MPL-2.0
function Invoke-OgGitPlumbing {
    <#
    .SYNOPSIS
        Runs one git command with extra environment variables and optional stdin text, returning its
        UTF-8 stdout untrimmed, its stderr and its exit code.

    .DESCRIPTION
        Invoke-Git's sibling for the plumbing that Export-OgDiffSides needs. It exists because
        Invoke-Git cannot do three things that engine depends on, and Invoke-Git itself must stay
        unchanged (every cmdlet uses it):

          - ENVIRONMENT. The export never lets git touch the real index; every call points
            GIT_INDEX_FILE at a private temporary index file instead. Invoke-Git cannot set a
            child-only environment variable, and setting $env:GIT_INDEX_FILE in this process would
            leak into every other git call until it is restored.
          - STDIN. Path lists go to git on stdin (`update-index -z --index-info`,
            `hash-object --stdin-paths`), never on the command line, so there is no length limit at
            600 or 60,000 paths.
          - ENCODING. stdout and stderr are decoded as UTF-8 and stdout is NOT trimmed. Git writes
            paths as UTF-8 bytes; Invoke-Git decodes with the console code page (which mangles
            non-ASCII paths) and trims the end (which would cut the final NUL of a -z list).

        Text only: stdout is decoded as UTF-8 text, so this must never carry file content. File
        content always goes git -> file directly (`checkout-index --prefix`).

        Both pipes are drained asynchronously BEFORE stdin is written and BEFORE WaitForExit, for the
        same deadlock reason Invoke-Git documents: a full pipe buffer on one stream blocks git while
        this side waits on another.

    .PARAMETER WorkingDirectory
        Directory git runs in.

    .PARAMETER Arguments
        Git arguments, one element per argument.

    .PARAMETER Environment
        Extra environment variables for the git child only (name -> value).

    .PARAMETER InputText
        Text written to git's stdin as UTF-8 without a BOM. Omitted or $null: stdin is closed at once,
        so a git command that would read stdin never waits on the console.

    .OUTPUTS
        PSCustomObject with ExitCode, StdOut (untrimmed), StdErr (trimmed) and WorkingDirectory.

    .EXAMPLE
        Invoke-OgGitPlumbing -WorkingDirectory $repo -Arguments 'update-index', '-z', '--index-info' `
            -Environment @{ GIT_INDEX_FILE = $tempIndex } -InputText "100644 $sha`tpath`0"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [hashtable] $Environment = @{},

        [AllowNull()]
        [string] $InputText
    )

    Write-Verbose "git $($Arguments -join ' ')  [in: $WorkingDirectory]"

    $utf8 = [System.Text.UTF8Encoding]::new($false)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'git'
    $psi.WorkingDirectory       = $WorkingDirectory
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding  = $utf8
    $psi.CreateNoWindow         = $true
    foreach ($arg in $Arguments) { $psi.ArgumentList.Add($arg) }
    foreach ($name in $Environment.Keys) { $psi.Environment[$name] = [string] $Environment[$name] }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    # Write raw bytes to the base stream: the StreamWriter's own encoding may emit a BOM, which git
    # would read as part of the first path.
    # A git that exits before reading all of stdin (bad arguments, an early error) breaks the pipe.
    # Swallow that IOException here: the exit code and stderr below are the real report, and a raw
    # "pipe is broken" would hide them.
    try {
        if (-not [string]::IsNullOrEmpty($InputText)) {
            $bytes = $utf8.GetBytes($InputText)
            $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $proc.StandardInput.BaseStream.Flush()
        }
        $proc.StandardInput.Close()
    } catch [System.IO.IOException] {
        Write-Verbose "git closed stdin early: $($_.Exception.Message)"
        try { $proc.StandardInput.Dispose() } catch [System.IO.IOException] { }
    }

    $proc.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    [PSCustomObject]@{
        ExitCode         = $proc.ExitCode
        StdOut           = $stdout
        StdErr           = $stderr.TrimEnd("`r", "`n")
        WorkingDirectory = $WorkingDirectory
    }
}
