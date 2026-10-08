# SPDX-License-Identifier: MPL-2.0
# Shared fixtures for the submodule-workflow tests. Dot-source inside a BeforeAll block.
# Every repo lives under the caller's $TestDrive; every remote is a local bare repo there.
# Nothing here touches a real repo or a network remote.

# Sandboxes git for the test process: a private global config (identity, no signing,
# 'main' as the default branch, and the file transport allowed for submodules, which
# git blocks by default since 2.38.1) and no system config. Child processes, including
# the git.exe that Invoke-Git starts, inherit it.
function Enter-OgGitSandbox {
    param([Parameter(Mandatory)] [string] $Root)

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $config = Join-Path $Root 'gitconfig'
    @(
        '[user]'
        '    name = og-tools test'
        '    email = test@example.com'
        '[commit]'
        '    gpgsign = false'
        '[tag]'
        '    gpgsign = false'
        '[init]'
        '    defaultBranch = main'
        '[protocol "file"]'
        '    allow = always'
        '[advice]'
        '    detachedHead = false'
    ) | Set-Content -LiteralPath $config

    $global:OgTestSandboxSaved = @{
        GIT_CONFIG_GLOBAL   = $env:GIT_CONFIG_GLOBAL
        GIT_CONFIG_NOSYSTEM = $env:GIT_CONFIG_NOSYSTEM
    }
    $env:GIT_CONFIG_GLOBAL   = $config
    $env:GIT_CONFIG_NOSYSTEM = '1'
}

function Exit-OgGitSandbox {
    if (-not $global:OgTestSandboxSaved) { return }
    foreach ($k in $global:OgTestSandboxSaved.Keys) {
        $v = $global:OgTestSandboxSaved[$k]
        if ($null -eq $v) { Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue }
        else { Set-Item -Path "env:$k" -Value $v }
    }
    $global:OgTestSandboxSaved = $null
}

# Runs git in a directory and returns trimmed stdout; throws on a non-zero exit.
function Invoke-TestGit {
    param(
        [Parameter(Mandatory)] [string] $Dir,
        [Parameter(ValueFromRemainingArguments)] [string[]] $GitArgs
    )
    $out = & git -C $Dir @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed in ${Dir}: $out" }
    ($out | Out-String).Trim()
}

# A fresh, unique directory under $TestDrive.
function New-TestDir {
    param([string] $Prefix = 't')
    $dir = Join-Path $TestDrive ("$Prefix-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $dir
}

# Writes a file (creating folders), stages and commits it.
function Add-TestCommit {
    param(
        [Parameter(Mandatory)] [string] $Dir,
        [string] $File = 'file.txt',
        [string] $Content = ([System.Guid]::NewGuid().ToString('N')),
        [string] $Message = 'change'
    )
    $path = Join-Path $Dir $File
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    Set-Content -LiteralPath $path -Value $Content
    Invoke-TestGit $Dir add -- $File | Out-Null
    Invoke-TestGit $Dir commit -q -m $Message | Out-Null
}

# Creates a bare remote '<Root>/<Name>.git' whose 'main' has one commit (unless -Empty).
# Returns the remote's path, usable as a clone URL.
function New-TestRemote {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Name,
        [switch] $Empty
    )
    $bare = Join-Path $Root "$Name.git"
    & git init -q --bare $bare 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git init --bare failed: $bare" }
    if (-not $Empty) {
        $seed = Join-Path $Root "seed-$Name"
        Invoke-TestGit $Root clone -q $bare $seed | Out-Null
        Add-TestCommit -Dir $seed -File 'README.md' -Content "# $Name" -Message 'initial'
        Invoke-TestGit $seed push -q origin main | Out-Null
        Remove-Item -LiteralPath $seed -Recurse -Force
    }
    $bare
}

# Builds a two-level project on local remotes and returns a recursive working clone:
#   parent.git                       (the project root)
#     libs/child  -> child.git       (submodule NAME 'child-module', so name != path)
# Returns @{ Root; Remotes; ParentUrl; ChildUrl; Project } where Project is the clone.
function New-TestProject {
    param([switch] $NoRecurse)

    $root    = New-TestDir 'proj'
    $remotes = Join-Path $root 'remotes'
    New-Item -ItemType Directory -Path $remotes | Out-Null

    $childUrl  = New-TestRemote -Root $remotes -Name 'child'
    $parentUrl = New-TestRemote -Root $remotes -Name 'parent'

    $seed = Join-Path $root 'seed-parent'
    Invoke-TestGit $root clone -q $parentUrl $seed | Out-Null
    Invoke-TestGit $seed submodule add -q --name child-module -- $childUrl libs/child | Out-Null
    Invoke-TestGit $seed commit -q -m 'add child submodule' | Out-Null
    Invoke-TestGit $seed push -q origin main | Out-Null
    Remove-Item -LiteralPath $seed -Recurse -Force

    $project = Join-Path $root 'project'
    if ($NoRecurse) {
        Invoke-TestGit $root clone -q $parentUrl $project | Out-Null
    } else {
        Invoke-TestGit $root clone -q --recurse-submodules $parentUrl $project | Out-Null
        # Clones leave submodules detached; put the child on main like a synced tree.
        Invoke-TestGit (Join-Path $project 'libs/child') checkout -q main | Out-Null
    }

    @{
        Root      = $root
        Remotes   = $remotes
        ParentUrl = $parentUrl
        ChildUrl  = $childUrl
        Project   = $project
    }
}

# Returns the staged changes of a repo as 'X<TAB>path' lines.
function Get-TestStaged {
    param([Parameter(Mandatory)] [string] $Dir)
    $out = Invoke-TestGit $Dir diff --cached --name-status
    if (-not $out) { return @() }
    @($out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
