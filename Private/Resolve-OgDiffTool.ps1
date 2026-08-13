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

function Start-OgDiffToolProcess {
    <#
    .SYNOPSIS
        Launches an already-composed external diff tool command line.

    .DESCRIPTION
        Thin seam around process launch so Pester can mock this single function and never spawn a
        real GUI tool -- there is no display in the test environment. Callers must have already
        substituted $LOCAL/$REMOTE (see Expand-OgDiffToolCommand); this function does not wait for
        the launched process, matching `git difftool`'s own fire-and-forget-to-a-single-instance-app
        behaviour.

        ⛔ THE COMMAND LINE IS WRAPPED IN AN EXTRA QUOTE PAIR, AND IT MUST BE. `cmd.exe /c` applies
        a documented quote-stripping rule when its command begins with a quote: it removes the
        OUTER pair. A configured tool command almost always begins with a quoted executable path —
        e.g.

            difftool.diffinity.cmd = "C:\Program Files\Diffinity\Diffinity.exe" "$LOCAL" "$REMOTE"

        — so passing it through unwrapped leaves cmd trying to execute `C:\Program`. It fails
        instantly, and because `Start-Process` returns as soon as cmd is spawned (and the window is
        hidden) NOTHING is visible: the caller happily reports 'opened' for every repo while no tool
        ever ran. Wrapping restores the pair cmd consumes.

        Measured on 2026-08-13 against a real Diffinity install, three arms:
          unwrapped + hidden  -> 0 processes   (the shipped defect)
          unwrapped + visible -> 0 processes   (so the window style was NOT the cause)
          wrapped   + hidden  -> 1 process, window "base - head - Diffinity"  ✅
        The middle arm is the one that matters: it rules out window style and isolates the fault to
        cmd's quote handling. Do not "simplify" this back to a bare $CommandLine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $CommandLine
    )

    # See the quote-stripping note above before touching this line.
    Start-Process -FilePath $env:ComSpec `
                  -ArgumentList @('/c', ('"' + $CommandLine + '"')) `
                  -WindowStyle Hidden
}
