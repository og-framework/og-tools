# SPDX-License-Identifier: MPL-2.0

function Resolve-OgDiffToolCommand {
    <#
    .SYNOPSIS
        Resolves the external diff tool's command-line template for a repo, honouring an explicit
        tool-name override, without ever running the tool itself.

    .DESCRIPTION
        Mirrors what `git difftool` itself resolves: the tool name comes from -Tool if given,
        otherwise from the repo's `diff.tool` config; the command template then comes from
        `difftool.<tool>.cmd`. Returns $null if either step is unresolved -- callers must treat
        that as "no tool configured" and report a clear error, never fall back to `git difftool`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [string] $Tool
    )

    $toolName = $Tool
    if ([string]::IsNullOrEmpty($toolName)) {
        $nameResult = Invoke-Git -WorkingDirectory $WorkingDirectory -Arguments 'config', '--get', 'diff.tool'
        if ($nameResult.ExitCode -eq 0 -and -not [string]::IsNullOrEmpty($nameResult.StdOut)) {
            $toolName = $nameResult.StdOut
        }
    }
    if ([string]::IsNullOrEmpty($toolName)) { return $null }

    $cmdResult = Invoke-Git -WorkingDirectory $WorkingDirectory `
        -Arguments 'config', '--get', "difftool.$toolName.cmd"
    if ($cmdResult.ExitCode -ne 0 -or [string]::IsNullOrEmpty($cmdResult.StdOut)) { return $null }

    $cmdResult.StdOut
}

function Expand-OgDiffToolCommand {
    <#
    .SYNOPSIS
        Substitutes $LOCAL / $REMOTE placeholders in a resolved diff-tool command template with
        real paths. Pure string substitution -- launches nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $CommandTemplate,

        [Parameter(Mandatory)]
        [string] $LocalPath,

        [Parameter(Mandatory)]
        [string] $RemotePath
    )

    $CommandTemplate.Replace('$LOCAL', $LocalPath).Replace('$REMOTE', $RemotePath)
}

function Get-OgDiffToolArgumentList {
    <#
    .SYNOPSIS
        Composes the cmd.exe argument vector for an already-expanded diff tool command line.

    .DESCRIPTION
        PURE and side-effect free, and kept separate from Start-OgDiffToolProcess ON PURPOSE: the
        composition is the part that was wrong, and a test that mocks the spawn seam cannot see it.

        cmd.exe STRIPS THE FIRST AND LAST QUOTE when the command line begins with a quote -- which
        this one always does, because `difftool.<tool>.cmd` quotes the tool path:

            "C:\Program Files\Diffinity\Diffinity.exe" "<base>" "<head>"

        Under a plain /c, cmd removes that outer pair, mangles the line and exits 1. /s plus an
        extra wrapping pair tells cmd to take everything between the outer quotes verbatim.

        MEASURED 2026-09-09 against the real tool and the real exported trees:
            cmd /c  <line>     -> exit 1, nothing launches
            cmd /s /c "<line>" -> Diffinity.exe appears in tasklist
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $CommandLine
    )

    # NOTE: parenthesise the concatenation. PowerShell's comma operator binds TIGHTER than '+',
    # so @('/s', '/c', '"' + $CommandLine + '"') parses as @('/s','/c','"') + $CommandLine + '"'
    # -- a FIVE element array that splits the quotes away from the command line. Measured.
    $quoted = '"' + $CommandLine + '"'
    @('/s', '/c', $quoted)
}

function Start-OgDiffToolProcess {
    <#
    .SYNOPSIS
        Launches an already-composed external diff tool command line and reports whether it started.

    .DESCRIPTION
        Thin seam around process launch so Pester can mock this single function and never spawn a
        real GUI tool -- there is no display in the test environment. Callers must have already
        substituted $LOCAL/$REMOTE (see Expand-OgDiffToolCommand).

        DOES NOT WAIT FOR THE TOOL, matching `git difftool`'s own
        fire-and-forget-to-a-single-instance-app behaviour -- but it does wait a bounded moment so
        that a launch which fails IMMEDIATELY is still observable, which is the only launch failure
        a fire-and-forget caller can detect at all. A mangled command line or a missing exe makes
        cmd exit within milliseconds; a real GUI tool outlives the window comfortably. So:

            exited inside the window with a non-zero code -> Launched = $false
            still running, or exited 0                    -> Launched = $true

        WHY THIS EXISTS: the previous version passed -WindowStyle Hidden with no -PassThru and no
        exit-code check, so a hard launch failure was invisible twice over -- cmd's error went to a
        hidden window, and the caller reported Action = 'opened' regardless. A status that names an
        outcome while testing nothing is worse than no status at all.

    .OUTPUTS
        PSCustomObject with Launched (bool), ExitCode (int or $null) and Detail (string or $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $CommandLine,

        # Bounded fail-fast window: long enough that a mangled line has certainly exited, short
        # enough that a successful launch is never meaningfully waited on.
        [int] $FailFastMilliseconds = 1500
    )

    $arguments = Get-OgDiffToolArgumentList -CommandLine $CommandLine

    try {
        $process = Start-Process -FilePath $env:ComSpec -ArgumentList $arguments `
            -WindowStyle Hidden -PassThru -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{
            Launched = $false
            ExitCode = $null
            Detail   = "Start-Process failed: $($_.Exception.Message)"
        }
    }

    if ($null -eq $process) {
        return [PSCustomObject]@{
            Launched = $false
            ExitCode = $null
            Detail   = 'Start-Process returned no process object.'
        }
    }

    $null = $process.WaitForExit($FailFastMilliseconds)

    if ($process.HasExited -and $process.ExitCode -ne 0) {
        return [PSCustomObject]@{
            Launched = $false
            ExitCode = $process.ExitCode
            Detail   = "The diff tool command exited $($process.ExitCode) immediately: $CommandLine"
        }
    }

    [PSCustomObject]@{
        Launched = $true
        ExitCode = $(if ($process.HasExited) { $process.ExitCode } else { $null })
        Detail   = $null
    }
}
