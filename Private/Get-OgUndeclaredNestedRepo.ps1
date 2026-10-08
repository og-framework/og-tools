# SPDX-License-Identifier: MPL-2.0
function Get-OgUndeclaredNestedRepo {
    <#
    .SYNOPSIS
        Lists untracked directories inside a repo that hold their own '.git' but are NOT
        declared in that repo's .gitmodules. Returns repo-relative paths (forward slashes,
        no trailing slash).

    .DESCRIPTION
        'git add -A' stages such a directory as an embedded gitlink with no .gitmodules
        entry: a broken pin that no other clone can resolve. The typical case is a
        submodule that exists only on a feature branch, left on disk after checking out
        main.

        Detection reads 'git ls-files --others --exclude-standard': git does not descend
        into a nested repo, so it lists the repo's directory with a trailing slash. Ignored
        directories never appear, and a declared submodule is never untracked unless its
        gitlink was not staged yet, in which case it is declared and therefore not reported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoPath
    )

    $others = Invoke-Git -WorkingDirectory $RepoPath -Arguments 'ls-files', '--others', '--exclude-standard', '-z'
    if ($others.ExitCode -ne 0 -or -not $others.StdOut) { return }

    $declared = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in (Get-OgSubmoduleDeclaration -RepoPath $RepoPath)) {
        if ($d.Path) { [void]$declared.Add($d.Path.Trim('/')) }
    }

    foreach ($entry in ($others.StdOut -split "`0")) {
        if (-not $entry.EndsWith('/')) { continue }
        $rel = $entry.TrimEnd('/')
        if ($declared.Contains($rel)) { continue }
        $abs = Join-Path $RepoPath ($rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if (Test-OgRepoInitialised -AbsolutePath $abs) { $rel }
    }
}
