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

# --- Shared fixtures: build once per test file, hand each test its own filesystem copy (od task 13) ---
#
# Why copies: a tree with submodules costs seconds per build (measured 2026-10-23: `git submodule add`
# 4.7 s and `git clone --recurse-submodules` 7.3 s on this machine; New-TestProject 11.6 s, a three-level
# tree 17.8 s), while copying the built tree costs well under a second. A copy is a separate set of
# repos: a test may commit, push, deinit or delete in it, and nothing reaches the pristine tree or
# another test's copy. Copy-TestFixture refuses to hand out a copy if the pristine tree changed, so a
# leak fails loudly instead of skewing a later test.

<#
.SYNOPSIS
    Copies a directory tree file by file, keeping every file's creation and last-write time and its
    attributes.
.DESCRIPTION
    Hidden and system entries are copied too (git marks .git hidden). Times are kept on purpose: git's
    index caches each file's size, mtime and ctime (ctime is the creation time on Windows), so a copy
    with fresh times would leave every index entry stat-dirty, and the first `git status` in the copy
    would rewrite its index. With the times kept, the copied index is as fresh as the original's and
    byte-identical to it. Do not replace this with Copy-Item: Copy-Item gives every file a new creation
    time. A reparse point (junction, symlink) throws: no fixture has one, and following it would copy
    something outside the fixture.
.PARAMETER Source
    The directory to copy.
.PARAMETER Destination
    The new directory; it must not exist yet.
#>
function Copy-TestTree {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination
    )
    if (Test-Path -LiteralPath $Destination) { throw "Copy-TestTree: '$Destination' already exists." }
    $src = [System.IO.Path]::GetFullPath($Source).TrimEnd('\')
    $dst = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $options = [System.IO.EnumerationOptions]::new()
    $options.RecurseSubdirectories = $true
    $options.AttributesToSkip      = [System.IO.FileAttributes]::None
    [void] [System.IO.Directory]::CreateDirectory($dst)
    foreach ($dir in [System.IO.Directory]::EnumerateDirectories($src, '*', $options)) {
        if (([System.IO.File]::GetAttributes($dir) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Copy-TestTree: '$dir' is a reparse point; fixtures must not contain links."
        }
        [void] [System.IO.Directory]::CreateDirectory($dst + $dir.Substring($src.Length))
    }
    foreach ($file in [System.IO.Directory]::EnumerateFiles($src, '*', $options)) {
        $info   = [System.IO.FileInfo]::new($file)
        $target = $dst + $file.Substring($src.Length)
        if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Copy-TestTree: '$file' is a reparse point; fixtures must not contain links."
        }
        [System.IO.File]::Copy($file, $target)
        # git's object files are read-only: lift the flag to set the times, then put the attributes back.
        [System.IO.File]::SetAttributes($target, [System.IO.FileAttributes]::Normal)
        [System.IO.File]::SetCreationTimeUtc($target, $info.CreationTimeUtc)
        [System.IO.File]::SetLastWriteTimeUtc($target, $info.LastWriteTimeUtc)
        [System.IO.File]::SetAttributes($target, $info.Attributes)
    }
}

<#
.SYNOPSIS
    A string that changes whenever anything under a directory is added, removed or written.
.DESCRIPTION
    One line per directory (relative path) and per file (relative path, length, last-write ticks),
    sorted ordinally. Cheap (no hashing): it is taken on every Copy-TestFixture call to prove that the
    pristine tree was never written through. A write always moves the last-write time.
.PARAMETER Path
    The directory.
#>
function Get-TestTreeFingerprint {
    param([Parameter(Mandatory)] [string] $Path)
    $root = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $options = [System.IO.EnumerationOptions]::new()
    $options.RecurseSubdirectories = $true
    $options.AttributesToSkip      = [System.IO.FileAttributes]::None
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in [System.IO.Directory]::EnumerateDirectories($root, '*', $options)) {
        $lines.Add('D|' + $dir.Substring($root.Length))
    }
    foreach ($file in [System.IO.Directory]::EnumerateFiles($root, '*', $options)) {
        $info = [System.IO.FileInfo]::new($file)
        $lines.Add('F|' + $file.Substring($root.Length) + '|' + $info.Length + '|' + $info.LastWriteTimeUtc.Ticks)
    }
    $lines.Sort([System.StringComparer]::Ordinal)
    $lines -join "`n"
}

<#
.SYNOPSIS
    Rebases every path in a fixture object from one folder to another, as a deep copy.
.DESCRIPTION
    Strings that are the old folder, or start with it plus '\' or '/', get the new folder instead
    (case-insensitive, as Windows paths are); every other value is kept. Hashtables, PSCustomObjects
    and arrays are rebuilt, so a test that changes its fixture object never changes the cached one.
.PARAMETER Value
    The fixture object (or any part of it).
.PARAMETER From
    The pristine fixture's top folder.
.PARAMETER To
    The copy's top folder.
#>
function ConvertTo-TestFixtureCopy {
    param([AllowNull()] $Value, [Parameter(Mandatory)] [string] $From, [Parameter(Mandatory)] [string] $To)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $cmp = [System.StringComparison]::OrdinalIgnoreCase
        if ($Value.Equals($From, $cmp)) { return $To }
        foreach ($sep in '\', '/') {
            if ($Value.StartsWith($From + $sep, $cmp)) { return $To + $Value.Substring($From.Length) }
        }
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = if ($Value -is [System.Collections.Specialized.OrderedDictionary]) { [ordered]@{} } else { @{} }
        foreach ($k in @($Value.Keys)) { $copy[$k] = ConvertTo-TestFixtureCopy -Value $Value[$k] -From $From -To $To }
        return $copy
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $copy[$p.Name] = ConvertTo-TestFixtureCopy -Value $p.Value -From $From -To $To }
        return [PSCustomObject] $copy
    }
    if ($Value -is [array]) {
        # The leading comma keeps a one-element (or empty) array an array.
        return , @(foreach ($item in $Value) { ConvertTo-TestFixtureCopy -Value $item -From $From -To $To })
    }
    $Value
}

<#
.SYNOPSIS
    Returns a fresh copy of a fixture that is built only once per test file: build once, copy per test.
.DESCRIPTION
    The first call for a -Key runs -Builder, which must create its repos in ONE new folder directly under
    $TestDrive (New-TestDir, New-TestProject) and return an object (hashtable or PSCustomObject) whose
    paths point into it. That folder becomes the pristine tree. Every call, the first included, then
    returns a copy:
      1. the pristine folder is copied (Copy-TestTree: times kept, so the git indexes stay fresh) to a new
         folder beside it, named like it (same prefix, new suffix);
      2. every remote URL in the copy's git config files (.git/config, .git/modules/**/config) that points
         into the pristine folder is rewritten to the copy, so a push or fetch from the copy stays in the
         copy (the measured fixtures store remote URLs as absolute paths; gitfiles and core.worktree are
         relative, which is why the copy is a working set of repos at all);
      3. the copy is checked: no git config and no gitfile may still name the pristine folder;
      4. the returned object is a deep copy of the builder's, with every path rebased onto the copy.
    The pristine folder's fingerprint is checked on every call: if anything wrote into it since it was
    built, this throws. The cache lives in the test file's script scope. Pester clears $TestDrive at the
    end of the Describe/Context that created an item, so a pristine tree built inside a Context is gone
    after it: the next call then finds its folder missing and builds it again.
    Committed content (.gitmodules URLs inside commits) still names the pristine remotes; only `git
    submodule init`/`update`/`sync` would read it, and those only read the pristine (the fingerprint
    check would catch a write).
.PARAMETER Key
    Names the fixture within the test file; one builder per key.
.PARAMETER Builder
    Builds the fixture; runs once per key (again only after Pester removed its folder). It runs inside
    this function, so PowerShell's dynamic scoping shows it this function's $Key and $Builder instead of
    the caller's variables of those names: a builder must not read a variable named $Key or $Builder.
#>
function Copy-TestFixture {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [scriptblock] $Builder
    )
    if ($null -eq $script:OgTestFixtureCache) { $script:OgTestFixtureCache = @{} }
    $ogFixture = $script:OgTestFixtureCache[$Key]
    if ($ogFixture -and -not (Test-Path -LiteralPath $ogFixture.Top)) { $ogFixture = $null }   # Pester cleared it
    if (-not $ogFixture) {
        $ogFixtureValue = & $Builder
        $drive = [System.IO.Path]::GetFullPath($TestDrive).TrimEnd('\')
        $tops = @(Get-TestFixturePathValue -Value $ogFixtureValue | ForEach-Object {
            $full = [System.IO.Path]::GetFullPath($_)
            if ($full.StartsWith($drive + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                $drive + '\' + $full.Substring($drive.Length + 1).Split('\')[0]
            }
        } | Sort-Object -Unique)
        if ($tops.Count -ne 1) {
            throw "Copy-TestFixture '$Key': the builder's paths must all lie in ONE folder directly under `$TestDrive; found $($tops.Count): $($tops -join ', ')."
        }
        $ogFixture = @{ Top = $tops[0]; Value = $ogFixtureValue; Fingerprint = (Get-TestTreeFingerprint -Path $tops[0]) }
        $script:OgTestFixtureCache[$Key] = $ogFixture
    } elseif ((Get-TestTreeFingerprint -Path $ogFixture.Top) -cne $ogFixture.Fingerprint) {
        throw "Copy-TestFixture '$Key': the pristine tree '$($ogFixture.Top)' changed after it was built. A test wrote into it instead of into its copy."
    }

    $leaf   = Split-Path $ogFixture.Top -Leaf
    $prefix = if ($leaf -match '^(.*)-[0-9a-f]{8}$') { $Matches[1] } else { $leaf }
    $copyTop = Join-Path (Split-Path $ogFixture.Top -Parent) ("$prefix-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    Copy-TestTree -Source $ogFixture.Top -Destination $copyTop

    # Remote URLs are stored as absolute paths; git config escapes '\' as '\\'.
    $forms = @(
        @{ Old = $ogFixture.Top.Replace('\', '\\'); New = $copyTop.Replace('\', '\\') }
        @{ Old = $ogFixture.Top.Replace('\', '/');  New = $copyTop.Replace('\', '/') }
        @{ Old = $ogFixture.Top;                    New = $copyTop }
    )
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $gitFiles = @(Get-ChildItem -LiteralPath $copyTop -Recurse -Force -File | Where-Object {
        ($_.Name -eq 'config' -and $_.FullName -match '\\\.git\\(modules\\.*\\)?config$') -or $_.Name -eq '.git'
    })
    foreach ($f in $gitFiles) {
        $text = [System.IO.File]::ReadAllText($f.FullName)
        $new  = $text
        foreach ($form in $forms) {
            $new = [regex]::Replace($new, [regex]::Escape($form.Old), $form.New.Replace('$', '$$'), 'IgnoreCase')
        }
        if ($new -cne $text) {
            [System.IO.File]::WriteAllText($f.FullName, $new, $utf8)
        }
        # Checked after the rewrite: a gitfile or worktree that still names the pristine tree means the
        # copy is not self-contained (git wrote an absolute path this helper does not expect).
        $after = [System.IO.File]::ReadAllText($f.FullName)
        foreach ($form in $forms) {
            if ($after.IndexOf($form.Old, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw "Copy-TestFixture '$Key': '$($f.FullName)' still names the pristine tree after the rewrite."
            }
        }
    }
    ConvertTo-TestFixtureCopy -Value $ogFixture.Value -From $ogFixture.Top -To $copyTop
}

<#
.SYNOPSIS
    Every string in a fixture object that is a rooted path, recursively.
.PARAMETER Value
    The fixture object (or any part of it).
#>
function Get-TestFixturePathValue {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        if ($Value -match '^[A-Za-z]:[\\/]') { $Value }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) { Get-TestFixturePathValue -Value $Value[$k] }
        return
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Value.PSObject.Properties) { Get-TestFixturePathValue -Value $p.Value }
        return
    }
    if ($Value -is [array]) { foreach ($item in $Value) { Get-TestFixturePathValue -Value $item } }
}
