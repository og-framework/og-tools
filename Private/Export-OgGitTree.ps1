# SPDX-License-Identifier: MPL-2.0

function Export-OgGitTree {
    <#
    .SYNOPSIS
        Exports a commit-ish's full tree into a persistent directory via `git archive`, read-only
        on the repo.

    .DESCRIPTION
        Runs `git archive --output=<tmpfile> <Tree>` (writing straight to a file rather than
        through stdout -- Invoke-Git reads stdout as text, which would corrupt a binary tar/zip
        stream) and then extracts that file into -Destination, which is cleared first so a stale
        prior export cannot masquerade as a fresh one.

        Prefers `tar.exe` (ships with Windows 10+ and with Git for Windows) when it actually
        resolves on PATH; falls back to `git archive --format=zip` + Expand-Archive (both git and
        PowerShell built-ins, no extra dependency) when it does not. Neither path needs network or
        admin rights.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory)]
        [string] $Tree,

        [Parameter(Mandatory)]
        [string] $Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    # More than one 'tar' can resolve on PATH (Git for Windows bundles usr\bin\tar.exe alongside
    # Windows' own System32\tar.exe) -- take the first match rather than let an array reach
    # $tarCmd.Source and silently become a single bogus multi-path argument.
    $tarCmd = Get-Command -Name 'tar' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $useTar = $null -ne $tarCmd

    $stagingFile = Join-Path ([System.IO.Path]::GetTempPath()) `
        ('og-diff-archive-' + [guid]::NewGuid().ToString('N') + $(if ($useTar) { '.tar' } else { '.zip' }))

    try {
        $archiveArgs = if ($useTar) {
            @('archive', "--output=$stagingFile", $Tree)
        } else {
            @('archive', '--format=zip', "--output=$stagingFile", $Tree)
        }

        $archiveResult = Invoke-Git -WorkingDirectory $WorkingDirectory -Arguments $archiveArgs
        if ($archiveResult.ExitCode -ne 0) {
            throw "git archive failed for '$Tree' in '$WorkingDirectory': $($archiveResult.StdErr)"
        }

        if ($useTar) {
            # GNU tar (ships in Git for Windows' usr\bin) is an MSYS2-linked binary; called with a
            # raw "C:\..." backslash path from a non-MSYS process (pwsh.exe) it either mis-parses
            # the drive letter as a "host:path" remote-archive spec ("Cannot connect to C: resolve
            # failed") or, even with that disabled via --force-local, mangles the backslashes
            # outright ("Cannot open: No such file or directory" for a directory that does exist).
            # Forward slashes sidestep both failure modes and work identically for Windows' own
            # bsdtar-based System32\tar.exe, which has neither quirk but also raises no objection to
            # '/' -- so always convert, and only add --force-local for a genuine GNU tar (bsdtar
            # rejects the unrecognised flag outright).
            $stagingFileForTar = $stagingFile.Replace('\', '/')
            $destinationForTar = $Destination.Replace('\', '/')

            $tarArgs = @('-xf', $stagingFileForTar, '-C', $destinationForTar)
            $versionOutput = & $tarCmd.Source --version 2>&1 | Select-Object -First 1
            if ($versionOutput -match 'GNU tar') { $tarArgs = @('--force-local') + $tarArgs }

            & $tarCmd.Source @tarArgs
            if ($LASTEXITCODE -ne 0) {
                throw "tar extraction of '$stagingFile' into '$Destination' failed (exit $LASTEXITCODE)"
            }
        } else {
            Expand-Archive -LiteralPath $stagingFile -DestinationPath $Destination -Force
        }
    } finally {
        Remove-Item -LiteralPath $stagingFile -Force -ErrorAction SilentlyContinue
    }
}
