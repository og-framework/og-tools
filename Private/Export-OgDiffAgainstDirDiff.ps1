# SPDX-License-Identifier: MPL-2.0

function Export-OgDiffAgainstDirDiff {
    <#
    .SYNOPSIS
        Orchestrates Show-OgDiff's -Against -DirDiff path: export the merge-base tree and HEAD to
        persistent directories, then launch the configured diff tool against them.

    .DESCRIPTION
        `git difftool --dir-diff` copies both sides into a temp directory it deletes the instant
        the tool process exits -- fatal for a <ref>...HEAD comparison (both sides are temporary
        copies) opened in a single-instance tool that hands off to an already-running window and
        exits immediately. This exports both sides itself via Export-OgGitTree into persistent,
        per-repo directories and launches the tool against those directly instead. See
        Show-OgDiff's own .DESCRIPTION for the full story.

        Every exit path returns a single Og.DiffResult PSCustomObject, matching what Show-OgDiff
        emits inline for its other branches.
    #>
    [CmdletBinding()]
    param(
        # Resolve-OgRepoTree entry for this repo (Name, Path, AbsolutePath, ...).
        [Parameter(Mandatory)]
        [PSCustomObject] $Repo,

        [Parameter(Mandatory)]
        [string] $AbsPath,

        [Parameter(Mandatory)]
        [string] $Against,

        # The already-resolved '<ref>...HEAD' range string, carried through onto the result.
        [Parameter(Mandatory)]
        [string] $Range,

        [string] $Tool
    )

    function New-OgDiffFailedResult {
        param([string] $ErrorMessage)
        [PSCustomObject]@{ PSTypeName = 'Og.DiffResult';
            Repo     = $Repo.Name
            Path     = $Repo.Path
            Action   = 'failed'
            Error    = $ErrorMessage
            Ref      = $Against
            Range    = $Range
            BasePath = $null
            HeadPath = $null
        }
    }

    # ⭐ Derive the base with `merge-base <ref> HEAD`, never export <ref> itself -- that is what
    # preserves the three-dot semantics established for the emptiness check / difftool range above.
    # Exporting <ref>'s own tip would silently reintroduce the two-dot bug in a new place.
    $mergeBaseResult = Invoke-Git -WorkingDirectory $AbsPath -Arguments 'merge-base', $Against, 'HEAD'
    if ($mergeBaseResult.ExitCode -ne 0) {
        Write-Warning "git merge-base failed in '$($Repo.Path)': $($mergeBaseResult.StdErr)"
        return New-OgDiffFailedResult $mergeBaseResult.StdErr
    }
    $mergeBase = $mergeBaseResult.StdOut

    $toolCommandTemplate = Resolve-OgDiffToolCommand -WorkingDirectory $AbsPath -Tool $Tool
    if ([string]::IsNullOrEmpty($toolCommandTemplate)) {
        $errorMessage = "No difftool configured for '$($Repo.Path)' (set diff.tool / " +
            "difftool.<tool>.cmd, or pass -Tool). Refusing to fall back to 'git difftool " +
            "--dir-diff', which is the temp-dir-cleanup bug this export path exists to avoid."
        Write-Warning $errorMessage
        return New-OgDiffFailedResult $errorMessage
    }

    # Predictable per-repo root, cleared (per side, inside Export-OgGitTree) before each export so
    # a stale prior run can never masquerade as a fresh one.
    $exportRoot = Join-Path $env:TEMP (Join-Path 'og-diff' $Repo.Name)
    $basePath   = Join-Path $exportRoot 'base'
    $headPath   = Join-Path $exportRoot 'head'

    try {
        Export-OgGitTree -WorkingDirectory $AbsPath -Tree $mergeBase -Destination $basePath
        Export-OgGitTree -WorkingDirectory $AbsPath -Tree 'HEAD'     -Destination $headPath
    } catch {
        Write-Warning "Export failed in '$($Repo.Path)': $($_.Exception.Message)"
        return New-OgDiffFailedResult $_.Exception.Message
    }

    $commandLine = Expand-OgDiffToolCommand -CommandTemplate $toolCommandTemplate `
        -LocalPath $basePath -RemotePath $headPath
    Write-Verbose "Launching exported directory diff in $($Repo.Path): $commandLine"
    Start-OgDiffToolProcess -CommandLine $commandLine

    [PSCustomObject]@{ PSTypeName = 'Og.DiffResult';
        Repo     = $Repo.Name
        Path     = $Repo.Path
        Action   = 'opened'
        Error    = $null
        Ref      = $Against
        Range    = $Range
        BasePath = $basePath
        HeadPath = $headPath
    }
}
