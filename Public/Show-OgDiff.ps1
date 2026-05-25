# SPDX-License-Identifier: MPL-2.0
function Show-OgDiff {
    <#
    .SYNOPSIS
        Opens git difftool on every modified file across the og-framework tree.

    .DESCRIPTION
        For each repo with uncommitted tracked modifications, runs `git difftool
        --no-prompt`. The actual tool used is whatever git's diff.tool config
        points at (or pass -Tool to override).

        To set up Diffinity once, globally:
            git config --global diff.tool diffinity
            git config --global difftool.diffinity.cmd '"C:/Path/To/Diffinity.exe" "$LOCAL" "$REMOTE"'

        Then `oggitdiff` uses Diffinity automatically.

    .PARAMETER ProjectRoot
        Path to the project root. Defaults to current working directory.

    .PARAMETER Tool
        Name of a git-configured diff tool (e.g., 'diffinity', 'vscode', 'meld').
        Overrides diff.tool for this invocation.

    .PARAMETER DirDiff
        Open one tool window per repo (directory diff) instead of one window per file.

    .PARAMETER Staged
        Compare staged changes vs HEAD instead of working-tree vs HEAD.

    .EXAMPLE
        oggitdiff
        # Opens difftool on each modified file in every dirty repo. Uses git's
        # default diff.tool.

    .EXAMPLE
        oggitdiff -Tool diffinity -DirDiff
        # Opens Diffinity once per dirty repo with a directory comparison.

    .EXAMPLE
        oggitdiff -Staged
        # Diffs the staged index vs HEAD (review what's about to be committed).

    .OUTPUTS
        PSCustomObject — one per repo touched:
          Repo, Path, Action ('opened' | 'clean' | 'failed'), Error
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string] $ProjectRoot = (Get-Location).Path,

        [string] $Tool,

        [switch] $DirDiff,

        [switch] $Staged
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
    $tree        = Resolve-OgRepoTree -ProjectRoot $ProjectRoot

    $diffArgs = @('difftool', '--no-prompt')
    if ($DirDiff) { $diffArgs += '--dir-diff' }
    if ($Staged)  { $diffArgs += '--cached' }
    if ($Tool)    { $diffArgs += "--tool=$Tool" }

    $checkArgs = if ($Staged) { @('diff', '--cached', '--quiet') } else { @('diff', '--quiet') }

    foreach ($repo in $tree) {
        $absPath = $repo.AbsolutePath
        if (-not (Test-Path -LiteralPath $absPath)) { continue }

        # git diff --quiet exits 0 if no diff, 1 if there is a diff
        $check = Invoke-Git -WorkingDirectory $absPath -Arguments $checkArgs
        if ($check.ExitCode -eq 0) {
            [PSCustomObject]@{ PSTypeName = 'Og.DiffResult';
                Repo   = $repo.Name
                Path   = $repo.Path
                Action = 'clean'
                Error  = $null
            }
            continue
        }

        Write-Verbose "Opening difftool in $($repo.Path)..."
        $diff = Invoke-Git -WorkingDirectory $absPath -Arguments $diffArgs
        if ($diff.ExitCode -eq 0) {
            [PSCustomObject]@{ PSTypeName = 'Og.DiffResult';
                Repo   = $repo.Name
                Path   = $repo.Path
                Action = 'opened'
                Error  = $null
            }
        } else {
            Write-Warning "git difftool failed in '$($repo.Path)': $($diff.StdErr)"
            [PSCustomObject]@{ PSTypeName = 'Og.DiffResult';
                Repo   = $repo.Name
                Path   = $repo.Path
                Action = 'failed'
                Error  = $diff.StdErr
            }
        }
    }
}
