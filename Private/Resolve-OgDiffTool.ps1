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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $CommandLine
    )

    Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', $CommandLine) -WindowStyle Hidden
}
