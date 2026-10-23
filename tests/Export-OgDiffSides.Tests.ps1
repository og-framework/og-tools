# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

# Covers the sparse changed-paths export engine (Get-OgDiffChange / Export-OgDiffSides, od task 1).
# Every repo is a throwaway under $TestDrive, sandboxed by Enter-OgGitSandbox; nothing launches a tool.
#
# The read-only tests are deliberately HOSTILE: each fixture leaves tracked files stat-dirty (same
# content, newer mtime). MEASURED 2026-10-22: plain `git diff HEAD` rewrites .git/index in exactly that
# state, so an engine that ever hands the real index to git fails the index-hash check here.
# The snapshot's own `git status` runs with --no-optional-locks for the same reason.

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force
    . "$PSScriptRoot\OgGitTestHelpers.ps1"
    Enter-OgGitSandbox -Root (Join-Path $TestDrive 'sandbox')

    # Non-ASCII names built from code points so this file stays ASCII.
    $script:UniFile = "spaced dir/$([char]0x00FC)n$([char]0x00EF) c$([char]0x00F6)d$([char]0x00E9).txt"
    $script:UniNew  = "spaced dir/n$([char]0x00EB)w f$([char]0x00EF)l$([char]0x00E9).txt"

    # Binary content with NUL bytes and CRLF pairs: any text or eol conversion would change it.
    $script:BinBase = [byte[]] (@(0, 1, 13, 10, 2, 255, 13, 10) + (0..255))
    $script:BinHead = [byte[]] (@(0, 13, 10, 13, 10, 254) + (255..0))

    $script:Utf8 = [System.Text.UTF8Encoding]::new($false)

    function Write-TestText {
        param([string] $Dir, [string] $Rel, [string] $Text)
        $path = Join-Path $Dir $Rel
        [void] [System.IO.Directory]::CreateDirectory((Split-Path $path -Parent))
        [System.IO.File]::WriteAllText($path, $Text, $script:Utf8)
    }

    function Write-TestBytes {
        param([string] $Dir, [string] $Rel, [byte[]] $Bytes)
        $path = Join-Path $Dir $Rel
        [void] [System.IO.Directory]::CreateDirectory((Split-Path $path -Parent))
        [System.IO.File]::WriteAllBytes($path, $Bytes)
    }

    function Read-TestBytes {
        param([string] $Dir, [string] $Rel)
        [System.IO.File]::ReadAllBytes((Join-Path $Dir $Rel))
    }

    # Every file under a folder as sorted, '/'-separated relative paths (empty array for none), hidden
    # ones included. Nothing is filtered out (od task 7): the engine's marker sits BESIDE a destination,
    # never in it, so every content assertion here also proves that a side holds only exported files.
    function Get-TestRelFiles {
        param([string] $Dir)
        if (-not (Test-Path -LiteralPath $Dir)) { return @() }
        $root = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\') + '\'
        @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force |
            ForEach-Object { $_.FullName.Substring($root.Length).Replace('\', '/') } |
            Sort-Object -CaseSensitive)
    }

    # The engine's marker for a destination, as od task 7 writes it: '<parent>\<leaf>.og-diff-side'.
    function Get-TestMarkerPath {
        param([string] $Dir)
        Join-Path (Split-Path $Dir -Parent) ((Split-Path $Dir -Leaf) + '.og-diff-side')
    }

    # Gives files a newer mtime without changing their content: stat-dirty in the index.
    function Set-TestStatDirty {
        param([string] $Dir, [string[]] $Rel)
        foreach ($r in $Rel) {
            (Get-Item -LiteralPath (Join-Path $Dir $r)).LastWriteTime = (Get-Date).AddMinutes(5)
        }
    }

    # What "read-only on the repo" must leave identical.
    function Get-TestRepoSnapshot {
        param([string] $Dir)
        $gitDir = Join-Path $Dir '.git'
        [PSCustomObject]@{
            IndexHash  = (Get-FileHash -LiteralPath (Join-Path $gitDir 'index') -Algorithm SHA256).Hash
            ConfigHash = (Get-FileHash -LiteralPath (Join-Path $gitDir 'config') -Algorithm SHA256).Hash
            Status     = Invoke-TestGit $Dir --no-optional-locks status --porcelain=v1 --untracked-files=all
            Refs       = Invoke-TestGit $Dir for-each-ref '--format=%(refname) %(objectname)'
            Head       = Invoke-TestGit $Dir symbolic-ref -q HEAD
        }
    }

    function Invoke-TestSides {
        param([hashtable] $P)
        InModuleScope og-framework -Parameters @{ P = $P } { Export-OgDiffSides @P }
    }

    function Invoke-TestChange {
        param([hashtable] $P)
        InModuleScope og-framework -Parameters @{ P = $P } { Get-OgDiffChange @P }
    }

    # A repo with core.autocrlf=true (as in the user's repos) and one base commit.
    function New-TestSidesRepo {
        $dir = New-TestDir 'sides'
        Invoke-TestGit $dir init -q | Out-Null
        Invoke-TestGit $dir config core.autocrlf true | Out-Null
        Write-TestText  $dir '.gitignore' "*.log`r`n"
        Write-TestText  $dir 'keep.txt' "keep`r`n"
        Write-TestText  $dir 'crlf.txt' "one`r`ntwo`r`n"
        Write-TestText  $dir 'mod.txt' "before`r`n"
        Write-TestText  $dir 'del.txt' "gone`r`n"
        Write-TestText  $dir 'old name.txt' "renamed`r`n"
        Write-TestBytes $dir 'bin.dat' $script:BinBase
        Write-TestText  $dir 'nested/deep/er/file.txt' "deep`r`n"
        Write-TestText  $dir $script:UniFile "uni`r`n"
        Invoke-TestGit $dir add -A | Out-Null
        Invoke-TestGit $dir commit -q -m base | Out-Null
        $dir
    }

    # Applies the same logical change set for each comparison kind: in the working tree only
    # (WorkingTree; the rename and the tracked add are staged, everything else is not), staged
    # (Staged), or committed (Range). Untracked and ignored files are always left on disk, and the
    # two unchanged files are made stat-dirty.
    function Set-TestSidesChanges {
        param([string] $Dir, [string] $Kind)
        Write-TestText  $Dir 'mod.txt' "after`r`n"
        Remove-Item -LiteralPath (Join-Path $Dir 'del.txt')
        Invoke-TestGit $Dir mv 'old name.txt' 'new name.txt' | Out-Null
        Write-TestText  $Dir 'added.txt' "added`r`n"
        Invoke-TestGit $Dir add -- 'added.txt' | Out-Null
        Write-TestBytes $Dir 'bin.dat' $script:BinHead
        Write-TestText  $Dir 'nested/deep/er/file.txt' "deeper`r`n"
        Write-TestText  $Dir $script:UniFile "uni2`r`n"
        Write-TestText  $Dir $script:UniNew "new uni`r`n"
        if ($Kind -eq 'WorkingTree') { Invoke-TestGit $Dir add -N -- $script:UniNew | Out-Null }

        if ($Kind -ne 'WorkingTree') {
            Invoke-TestGit $Dir add -u | Out-Null
            Invoke-TestGit $Dir add -- $script:UniNew | Out-Null
        }
        if ($Kind -eq 'Range') { Invoke-TestGit $Dir commit -q -m change | Out-Null }

        # After staging/committing: a disk-only edit that Staged and Range must NOT see.
        if ($Kind -ne 'WorkingTree') { Write-TestText $Dir 'mod.txt' "after-unstaged`r`n" }

        Write-TestText $Dir 'untracked.txt' "untracked`r`n"
        Write-TestText $Dir 'debug.log' "ignored`r`n"
        Set-TestStatDirty $Dir 'keep.txt', 'crlf.txt'
    }

    function Get-TestKindArgs {
        param([string] $Kind)
        if ($Kind -eq 'Range') { @{ Kind = 'Range'; BaseRev = 'HEAD~1'; HeadRev = 'HEAD' } }
        else { @{ Kind = $Kind } }
    }
}

AfterAll {
    Exit-OgGitSandbox
}

Describe 'Export-OgDiffSides: <Kind>' -ForEach @(
    @{ Kind = 'WorkingTree' }
    @{ Kind = 'Staged' }
    @{ Kind = 'Range' }
) {
    BeforeAll {
        $script:repo = New-TestSidesRepo
        Set-TestSidesChanges -Dir $script:repo -Kind $Kind
        $script:out  = New-TestDir 'out'
        $script:base = Join-Path $script:out 'base'
        $script:head = Join-Path $script:out 'head'

        $script:before = Get-TestRepoSnapshot $script:repo
        $p = Get-TestKindArgs $Kind
        $p.WorkingDirectory = $script:repo
        $p.BaseDestination  = $script:base
        $p.HeadDestination  = $script:head
        $script:result = Invoke-TestSides $p
        $script:after  = Get-TestRepoSnapshot $script:repo

        $script:expectBase = @('bin.dat', 'del.txt', 'mod.txt', 'nested/deep/er/file.txt', 'old name.txt',
            $script:UniFile) | Sort-Object -CaseSensitive
        $headList = @('added.txt', 'bin.dat', 'mod.txt', 'nested/deep/er/file.txt', 'new name.txt',
            $script:UniFile, $script:UniNew)
        if ($Kind -eq 'WorkingTree') { $headList += 'untracked.txt' }
        $script:expectHead = $headList | Sort-Object -CaseSensitive
    }

    It 'lists every changed path with its status, a rename as a delete plus an add' {
        $expected = [ordered]@{
            'added.txt'               = 'Added'
            'bin.dat'                 = 'Modified'
            'del.txt'                 = 'Deleted'
            'mod.txt'                 = 'Modified'
            'nested/deep/er/file.txt' = 'Modified'
            'new name.txt'            = 'Added'
            'old name.txt'            = 'Deleted'
        }
        $expected[$script:UniFile] = 'Modified'
        $expected[$script:UniNew]  = 'Added'
        if ($Kind -eq 'WorkingTree') { $expected['untracked.txt'] = 'Added' }

        $actual = @($script:result.Files | ForEach-Object { "$($_.Path)=$($_.Status)" }) | Sort-Object -CaseSensitive
        $want   = @($expected.Keys | ForEach-Object { "$_=$($expected[$_])" }) | Sort-Object -CaseSensitive
        ($actual -join '|') | Should -BeExactly ($want -join '|')
        $script:result.FileCount | Should -Be $expected.Count
    }

    It 'sets OnBase/OnHead from the status' {
        foreach ($f in $script:result.Files) {
            $f.OnBase | Should -Be ($f.Status -ne 'Added') -Because $f.Path
            $f.OnHead | Should -Be ($f.Status -ne 'Deleted') -Because $f.Path
        }
    }

    It 'writes ONLY the changed paths on each side (sparse; unchanged, ignored and stat-dirty files absent)' {
        Get-TestRelFiles $script:base | Should -Be $script:expectBase
        Get-TestRelFiles $script:head | Should -Be $script:expectHead
    }

    It 'never lists an ignored file, nor an unchanged CRLF file that is stat-dirty' {
        $script:result.Files.Path | Should -Not -Contain 'debug.log'
        $script:result.Files.Path | Should -Not -Contain 'crlf.txt'
        $script:result.Files.Path | Should -Not -Contain 'keep.txt'
    }

    It 'includes the untracked file only in WorkingTree mode, flagged Untracked' {
        $untracked = @($script:result.Files | Where-Object Untracked)
        if ($Kind -eq 'WorkingTree') {
            $untracked.Path | Should -Be @('untracked.txt')
        } else {
            $untracked | Should -BeNullOrEmpty
            $script:result.Files.Path | Should -Not -Contain 'untracked.txt'
        }
    }

    It 'keeps binary content byte-exact on both sides' {
        (Read-TestBytes $script:base 'bin.dat') | Should -Be $script:BinBase
        (Read-TestBytes $script:head 'bin.dat') | Should -Be $script:BinHead
    }

    It 'puts the object sides through the checkout conversion (core.autocrlf=true -> CRLF)' {
        $script:Utf8.GetString((Read-TestBytes $script:base 'mod.txt')) | Should -BeExactly "before`r`n"
        $script:Utf8.GetString((Read-TestBytes $script:base 'old name.txt')) | Should -BeExactly "renamed`r`n"
        $script:Utf8.GetString((Read-TestBytes $script:head 'new name.txt')) | Should -BeExactly "renamed`r`n"
    }

    It 'takes the head side from the right source (disk / index / commit)' {
        # Staged and Range must ignore the later disk-only edit ("after-unstaged").
        $script:Utf8.GetString((Read-TestBytes $script:head 'mod.txt')) | Should -BeExactly "after`r`n"
    }

    It 'survives paths with spaces and non-ASCII characters' {
        $script:Utf8.GetString((Read-TestBytes $script:base $script:UniFile)) | Should -BeExactly "uni`r`n"
        $script:Utf8.GetString((Read-TestBytes $script:head $script:UniFile)) | Should -BeExactly "uni2`r`n"
        $script:Utf8.GetString((Read-TestBytes $script:head $script:UniNew)) | Should -BeExactly "new uni`r`n"
    }

    It 'returns the resolved commits and the full destinations' {
        $headSha = Invoke-TestGit $script:repo rev-parse HEAD
        if ($Kind -eq 'Range') {
            $script:result.BaseCommit | Should -Be (Invoke-TestGit $script:repo rev-parse 'HEAD~1')
            $script:result.HeadCommit | Should -Be $headSha
        } else {
            $script:result.BaseCommit | Should -Be $headSha
            $script:result.HeadCommit | Should -BeNullOrEmpty
        }
        $script:result.BaseDestination | Should -Be ([System.IO.Path]::GetFullPath($script:base))
        $script:result.HeadDestination | Should -Be ([System.IO.Path]::GetFullPath($script:head))
        $script:result.Kind | Should -Be $Kind
    }

    It 'is read-only on the repo: index bytes, status, refs, HEAD and config unchanged' {
        $script:after.IndexHash  | Should -Be $script:before.IndexHash
        $script:after.Status     | Should -BeExactly $script:before.Status
        $script:after.Refs       | Should -BeExactly $script:before.Refs
        $script:after.Head       | Should -BeExactly $script:before.Head
        $script:after.ConfigHash | Should -Be $script:before.ConfigHash
    }
}

Describe 'Export-OgDiffSides: 600 changed paths in one call (<Kind>)' -ForEach @(
    @{ Kind = 'WorkingTree' }
    @{ Kind = 'Staged' }
    @{ Kind = 'Range' }
) {
    It 'exports all 600 on both sides, with no command-line limit' {
        $repo = New-TestDir 'many'
        Invoke-TestGit $repo init -q | Out-Null
        $names = 0..599 | ForEach-Object { 'many/sub {0:D2}/a fairly long file name number {1:D4}.txt' -f ($_ % 20), $_ }
        foreach ($n in $names) { Write-TestText $repo $n "v1 $n`n" }
        Invoke-TestGit $repo add -A | Out-Null
        Invoke-TestGit $repo commit -q -m base | Out-Null
        foreach ($n in $names) { Write-TestText $repo $n "v2 $n`n" }
        if ($Kind -ne 'WorkingTree') { Invoke-TestGit $repo add -A | Out-Null }
        if ($Kind -eq 'Range') { Invoke-TestGit $repo commit -q -m change | Out-Null }

        $out = New-TestDir 'many-out'
        $p = Get-TestKindArgs $Kind
        $p.WorkingDirectory = $repo
        $p.BaseDestination  = Join-Path $out 'base'
        $p.HeadDestination  = Join-Path $out 'head'
        $r = Invoke-TestSides $p

        $r.FileCount | Should -Be 600
        $sorted = @($names | Sort-Object -CaseSensitive)
        Get-TestRelFiles $p.BaseDestination | Should -Be $sorted
        Get-TestRelFiles $p.HeadDestination | Should -Be $sorted
        $script:Utf8.GetString((Read-TestBytes $p.HeadDestination $names[599])) | Should -BeExactly "v2 $($names[599])`n"
    }
}

Describe 'Export-OgDiffSides: a submodule whose gitlink changed (<Kind>)' -ForEach @(
    @{ Kind = 'WorkingTree' }
    @{ Kind = 'Staged' }
    @{ Kind = 'Range' }
) {
    It 'excludes the gitlink: no entry, no folder, no placeholder file' {
        $t = New-TestProject
        $project = $t.Project
        $child = Join-Path $project 'libs/child'
        Add-TestCommit -Dir $child -File 'child.txt' -Message 'move the pin'
        Write-TestText $project 'README.md' "# parent changed`n"
        if ($Kind -ne 'WorkingTree') { Invoke-TestGit $project add -- 'README.md' 'libs/child' | Out-Null }
        if ($Kind -eq 'Range') { Invoke-TestGit $project commit -q -m 'bump child' | Out-Null }

        # The gitlink change really is there, so the exclusion below is not vacuous.
        $raw = if ($Kind -eq 'Range') { Invoke-TestGit $project diff --raw HEAD~1 HEAD }
               elseif ($Kind -eq 'Staged') { Invoke-TestGit $project diff --raw --cached }
               else { Invoke-TestGit $project diff --raw HEAD }
        $raw | Should -Match '160000 160000 .* M\s+libs/child'

        $out = New-TestDir 'sub-out'
        $p = Get-TestKindArgs $Kind
        $p.WorkingDirectory = $project
        $p.BaseDestination  = Join-Path $out 'base'
        $p.HeadDestination  = Join-Path $out 'head'
        $r = Invoke-TestSides $p

        @($r.Files.Path) | Should -Be @('README.md')
        Get-TestRelFiles $p.BaseDestination | Should -Be @('README.md')
        Get-TestRelFiles $p.HeadDestination | Should -Be @('README.md')
        Test-Path -LiteralPath (Join-Path $p.HeadDestination 'libs') | Should -BeFalse
    }
}

Describe 'Export-OgDiffSides: destinations' {
    It 'clears an earlier export before writing (a stale file never survives)' {
        $repo = New-TestSidesRepo
        Write-TestText $repo 'mod.txt' "after`r`n"
        $out = New-TestDir 'stale'
        $base = Join-Path $out 'base'; $head = Join-Path $out 'head'
        $p = @{ WorkingDirectory = $repo; Kind = 'WorkingTree'; BaseDestination = $base; HeadDestination = $head }
        Invoke-TestSides $p | Out-Null              # the earlier export (writes the markers)
        Write-TestText $base 'stale-from-last-run.txt' 'old'
        Write-TestText $head 'stale/deep.txt' 'old'

        Invoke-TestSides $p | Out-Null

        Get-TestRelFiles $base | Should -Be @('mod.txt')
        Get-TestRelFiles $head | Should -Be @('mod.txt')
    }

    It 'creates empty side folders when one side has nothing (only a delete)' {
        $repo = New-TestSidesRepo
        Remove-Item -LiteralPath (Join-Path $repo 'del.txt')
        $out = New-TestDir 'onesided'
        $r = Invoke-TestSides @{ WorkingDirectory = $repo; Kind = 'WorkingTree'
            BaseDestination = (Join-Path $out 'base'); HeadDestination = (Join-Path $out 'head') }
        $r.Files[0].Status | Should -Be 'Deleted'
        Get-TestRelFiles $r.BaseDestination | Should -Be @('del.txt')
        Test-Path -LiteralPath $r.HeadDestination -PathType Container | Should -BeTrue
        Get-TestRelFiles $r.HeadDestination | Should -Be @()
    }

    It 'refuses the repo itself, a folder inside it, or a parent of it, and leaves the repo intact' {
        $repo = New-TestSidesRepo
        Write-TestText $repo 'mod.txt' "after`r`n"
        $before = Get-TestRelFiles $repo
        $elsewhere = Join-Path (New-TestDir 'ok') 'head'
        foreach ($bad in @($repo, (Join-Path $repo 'out'), (Split-Path $repo -Parent))) {
            { Invoke-TestSides @{ WorkingDirectory = $repo; Kind = 'WorkingTree'; BaseDestination = $bad; HeadDestination = $elsewhere } } |
                Should -Throw '*overlaps the repo*'
        }
        Get-TestRelFiles $repo | Should -Be $before
    }

    It 'refuses overlapping base and head destinations' {
        $repo = New-TestSidesRepo
        $out = New-TestDir 'overlap'
        { Invoke-TestSides @{ WorkingDirectory = $repo; Kind = 'WorkingTree'; BaseDestination = $out; HeadDestination = (Join-Path $out 'head') } } |
            Should -Throw '*overlap*'
    }
}

Describe 'Export-OgDiffSides: empty sides (Range with an empty rev)' {
    BeforeAll {
        $script:repo = New-TestSidesRepo   # 9 tracked files
    }

    It 'an empty BaseRev exports every file of HeadRev as Added, with an empty base side' {
        $out = New-TestDir 'empty-base'
        $r = Invoke-TestSides @{ WorkingDirectory = $script:repo; Kind = 'Range'; BaseRev = ''; HeadRev = 'HEAD'
            BaseDestination = (Join-Path $out 'base'); HeadDestination = (Join-Path $out 'head') }
        $r.BaseCommit | Should -BeNullOrEmpty
        @($r.Files.Status | Sort-Object -Unique) | Should -Be @('Added')
        $r.FileCount | Should -Be 9
        Get-TestRelFiles $r.BaseDestination | Should -Be @()
        @(Get-TestRelFiles $r.HeadDestination).Count | Should -Be 9
    }

    It 'an empty HeadRev exports every file of BaseRev as Deleted, with an empty head side' {
        $out = New-TestDir 'empty-head'
        $r = Invoke-TestSides @{ WorkingDirectory = $script:repo; Kind = 'Range'; BaseRev = 'HEAD'; HeadRev = ''
            BaseDestination = (Join-Path $out 'base'); HeadDestination = (Join-Path $out 'head') }
        $r.HeadCommit | Should -BeNullOrEmpty
        @($r.Files.Status | Sort-Object -Unique) | Should -Be @('Deleted')
        @(Get-TestRelFiles $r.BaseDestination).Count | Should -Be 9
        Get-TestRelFiles $r.HeadDestination | Should -Be @()
    }
}

Describe 'Get-OgDiffChange: the listing without an export' {
    It 'answers FileCount 0 for a clean repo with stat-dirty files, writing nothing' {
        $repo = New-TestSidesRepo
        Set-TestStatDirty $repo 'keep.txt', 'crlf.txt', 'mod.txt'
        $before = Get-TestRepoSnapshot $repo
        foreach ($kind in 'WorkingTree', 'Staged') {
            (Invoke-TestChange @{ WorkingDirectory = $repo; Kind = $kind }).FileCount | Should -Be 0 -Because $kind
        }
        (Invoke-TestChange @{ WorkingDirectory = $repo; Kind = 'Range'; BaseRev = 'HEAD'; HeadRev = 'HEAD' }).FileCount |
            Should -Be 0
        (Get-TestRepoSnapshot $repo).IndexHash | Should -Be $before.IndexHash
    }

    It 'counts a repo whose only change is a new untracked file (WorkingTree), from a subfolder too' {
        $repo = New-TestSidesRepo
        Write-TestText $repo 'nested/brand new.txt' 'x'
        $r = Invoke-TestChange @{ WorkingDirectory = (Join-Path $repo 'nested/deep'); Kind = 'WorkingTree' }
        $r.FileCount | Should -Be 1
        $r.Files[0].Path | Should -BeExactly 'nested/brand new.txt'
        $r.Files[0].Untracked | Should -BeTrue
        $r.RepoRoot | Should -Be ([System.IO.Path]::GetFullPath($repo))
        (Invoke-TestChange @{ WorkingDirectory = $repo; Kind = 'Staged' }).FileCount | Should -Be 0
    }

    It 'handles `git rm --cached`: unchanged on disk -> not listed, changed on disk -> Modified' {
        $repo = New-TestSidesRepo
        Invoke-TestGit $repo rm -q --cached -- 'keep.txt' 'mod.txt' | Out-Null
        Write-TestText $repo 'mod.txt' "changed on disk`r`n"
        $r = Invoke-TestChange @{ WorkingDirectory = $repo; Kind = 'WorkingTree' }
        @($r.Files | ForEach-Object { "$($_.Path)=$($_.Status)" }) | Should -Be @('mod.txt=Modified')
        $r.Files[0].OnBase | Should -BeTrue
        $r.Files[0].OnHead | Should -BeTrue
    }

    It 'compares an unborn HEAD against the empty tree' {
        $repo = New-TestDir 'unborn'
        Invoke-TestGit $repo init -q | Out-Null
        Write-TestText $repo 'first.txt' 'x'
        Invoke-TestGit $repo add -- 'first.txt' | Out-Null
        $r = Invoke-TestChange @{ WorkingDirectory = $repo; Kind = 'Staged' }
        $r.BaseCommit | Should -BeNullOrEmpty
        @($r.Files | ForEach-Object { "$($_.Path)=$($_.Status)" }) | Should -Be @('first.txt=Added')
    }

    It 'rejects a Range without both revs, revs on another kind, and a rev that does not resolve' {
        $repo = New-TestSidesRepo
        { Invoke-TestChange @{ WorkingDirectory = $repo; Kind = 'Range'; BaseRev = 'HEAD' } } | Should -Throw '*both -BaseRev and -HeadRev*'
        { Invoke-TestChange @{ WorkingDirectory = $repo; Kind = 'WorkingTree'; BaseRev = 'HEAD' } } | Should -Throw '*belong to -Kind Range*'
        { Invoke-TestChange @{ WorkingDirectory = $repo; Kind = 'Range'; BaseRev = 'nope'; HeadRev = 'HEAD' } } | Should -Throw '*does not resolve*'
        { Invoke-TestChange @{ WorkingDirectory = $TestDrive; Kind = 'WorkingTree' } } | Should -Throw '*Not inside a git work tree*'
    }

    It 'refuses Staged during a conflict (the index side is undefined)' {
        $repo = New-TestSidesRepo
        Invoke-TestGit $repo checkout -q -b other | Out-Null
        Write-TestText $repo 'mod.txt' "theirs`r`n"; Invoke-TestGit $repo commit -q -am theirs | Out-Null
        Invoke-TestGit $repo checkout -q - | Out-Null
        Write-TestText $repo 'mod.txt' "ours`r`n"; Invoke-TestGit $repo commit -q -am ours | Out-Null
        & git -C $repo merge -q other 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
        { Invoke-TestChange @{ WorkingDirectory = $repo; Kind = 'Staged' } } | Should -Throw '*Unmerged path*'
        # The working tree side of a conflict is still a plain file: WorkingTree lists it.
        @((Invoke-TestChange @{ WorkingDirectory = $repo; Kind = 'WorkingTree' }).Files.Path) | Should -Be @('mod.txt')
    }

    It 'exports a listing as-is through -ChangeSet (no second listing)' {
        $repo = New-TestSidesRepo
        Write-TestText $repo 'mod.txt' "after`r`n"
        Write-TestText $repo 'new.txt' "new`r`n"
        $cs = Invoke-TestChange @{ WorkingDirectory = $repo; Kind = 'WorkingTree' }
        $cs.FileCount | Should -Be 2
        Mock -ModuleName og-framework Get-OgDiffChange { throw 'must not list again' }
        $out = New-TestDir 'cs'
        $r = Invoke-TestSides @{ ChangeSet = $cs; BaseDestination = (Join-Path $out 'base'); HeadDestination = (Join-Path $out 'head') }
        $r.FileCount | Should -Be 2
        Get-TestRelFiles $r.BaseDestination | Should -Be @('mod.txt')
        Get-TestRelFiles $r.HeadDestination | Should -Be @('mod.txt', 'new.txt')
    }
}

Describe 'Export-OgDiffSides: destination guard refuses <Name> (nothing deleted)' -ForEach @(
    # The od-1 review's probes. Absolute real folders are NEVER touched: every side effect after the guard
    # is mocked to record and throw, so even a broken guard deletes nothing, and the proof is that no side
    # effect was invoked. Relative and drive-relative probes resolve inside a sandbox holding canaries.
    @{ Name = 'the drive root C:\'; Dest = 'C:\'; Reason = '*is the root*' }
    @{ Name = 'the user profile'; Dest = $env:USERPROFILE; Reason = '*overlaps the repo*|*marker*' }
    @{ Name = '$env:TEMP'; Dest = $env:TEMP; Reason = '*overlaps the repo*|*marker*' }
    @{ Name = 'Documents'; Dest = [Environment]::GetFolderPath('MyDocuments'); Reason = '*marker*' }
    @{ Name = 'C:\Windows'; Dest = 'C:\Windows'; Reason = '*marker*' }
    @{ Name = 'the relative path base'; Dest = 'base'; Reason = '*fully qualified*' }
    @{ Name = 'the relative path .'; Dest = '.'; Reason = '*fully qualified*' }
    @{ Name = 'the relative path ..'; Dest = '..'; Reason = '*fully qualified*' }
    @{ Name = 'the drive-relative C:'; Dest = 'C:'; Reason = '*fully qualified*' }
    @{ Name = 'the drive-relative C:foo'; Dest = 'C:foo'; Reason = '*fully qualified*' }
) {
    BeforeAll {
        $script:gRepo = New-TestSidesRepo
        Write-TestText $script:gRepo 'mod.txt' "after`r`n"
        # Listed BEFORE any mock: the probes export this ChangeSet, so no git call runs under the mocks.
        $script:gCs = Invoke-TestChange @{ WorkingDirectory = $script:gRepo; Kind = 'WorkingTree' }
        $script:gHead = Join-Path (New-TestDir 'guard-ok') 'head'

        # The sandbox that '.', '..', 'base', 'C:' and 'C:foo' resolve into (both the PowerShell location
        # and [Environment]::CurrentDirectory point at gCwd during each probe), with a canary at each level.
        $script:gParent = New-TestDir 'guard-cwd'
        $script:gCwd = Join-Path $script:gParent 'cwd'
        $script:canaries = @(
            (Join-Path $script:gParent 'canary-parent.txt')
            (Join-Path $script:gCwd 'canary.txt')
            (Join-Path $script:gCwd 'base\canary-base.txt')
            (Join-Path $script:gCwd 'foo\canary-foo.txt')
        )
        foreach ($c in $script:canaries) {
            [void] [System.IO.Directory]::CreateDirectory((Split-Path $c -Parent))
            Set-Content -LiteralPath $c -Value 'canary'
        }
    }

    BeforeEach {
        Mock -ModuleName og-framework Initialize-OgDiffSideFolder { throw "SIDE EFFECT REACHED: clear '$Path'" }
        Mock -ModuleName og-framework Remove-Item { throw "SIDE EFFECT REACHED: Remove-Item '$LiteralPath'" }
        Mock -ModuleName og-framework Export-OgDiffObjectSide { throw 'SIDE EFFECT REACHED: export' }
        Mock -ModuleName og-framework Copy-OgDiffWorkingTreeFile { throw 'SIDE EFFECT REACHED: copy' }
    }

    It 'refuses it as the base destination before any side effect' {
        $savedCwd = [Environment]::CurrentDirectory
        Push-Location -LiteralPath $script:gCwd
        [Environment]::CurrentDirectory = $script:gCwd
        try {
            $err = { Invoke-TestSides @{ ChangeSet = $script:gCs; BaseDestination = $Dest; HeadDestination = $script:gHead } } |
                Should -Throw -PassThru
        } finally {
            Pop-Location
            [Environment]::CurrentDirectory = $savedCwd
        }
        $err.Exception.Message | Should -BeLike 'Refusing export destination*'
        @($Reason -split '\|' | Where-Object { $err.Exception.Message -like $_ }).Count | Should -BeGreaterThan 0 -Because $err.Exception.Message
        Should -Invoke -ModuleName og-framework Initialize-OgDiffSideFolder -Times 0 -Exactly
        Should -Invoke -ModuleName og-framework Remove-Item -Times 0 -Exactly
        Should -Invoke -ModuleName og-framework Export-OgDiffObjectSide -Times 0 -Exactly
        Should -Invoke -ModuleName og-framework Copy-OgDiffWorkingTreeFile -Times 0 -Exactly
        foreach ($c in $script:canaries) { Test-Path -LiteralPath $c -PathType Leaf | Should -BeTrue -Because $c }
        Test-Path -LiteralPath $script:gHead | Should -BeFalse
    }
}

Describe 'Export-OgDiffSides: destination guard and marker' {
    BeforeAll {
        $script:mRepo = New-TestSidesRepo
        Write-TestText $script:mRepo 'mod.txt' "after`r`n"
    }

    # od task 7: the marker moved out of the side folder (it was listed in every Diffinity tab).
    It 'writes a hidden SIDE.og-diff-side marker BESIDE each destination it creates, and nothing inside' {
        $out = New-TestDir 'marker'
        $r = Invoke-TestSides @{ WorkingDirectory = $script:mRepo; Kind = 'WorkingTree'
            BaseDestination = (Join-Path $out 'my base'); HeadDestination = (Join-Path $out 'my head') }
        foreach ($d in $r.BaseDestination, $r.HeadDestination) {
            $m = Get-Item -LiteralPath (Get-TestMarkerPath $d) -Force
            $m.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $d '.og-diff-side') | Should -BeFalse
            Get-TestRelFiles $d | Should -Be @('mod.txt')
        }
        @(Get-ChildItem -LiteralPath $out -Force | ForEach-Object Name | Sort-Object) |
            Should -Be @('my base', 'my base.og-diff-side', 'my head', 'my head.og-diff-side')
    }

    It 're-exports into the same destinations: the earlier export (and its hidden marker) is replaced' {
        # The marker survives the clear (it is outside the folder) and is HIDDEN, which WriteAllText cannot
        # overwrite: the engine must delete it first, or every second export into a folder fails.
        $out = New-TestDir 'reexport'
        $p = @{ WorkingDirectory = $script:mRepo; Kind = 'WorkingTree'
            BaseDestination = (Join-Path $out 'base'); HeadDestination = (Join-Path $out 'head') }
        $null = Invoke-TestSides $p
        Write-TestText (Join-Path $out 'head') 'stale.txt' 'from the first export'
        $r = Invoke-TestSides $p
        Get-TestRelFiles $r.BaseDestination | Should -Be @('mod.txt')
        Get-TestRelFiles $r.HeadDestination | Should -Be @('mod.txt')
        foreach ($d in $r.BaseDestination, $r.HeadDestination) {
            (Get-Item -LiteralPath (Get-TestMarkerPath $d) -Force).Attributes.HasFlag([System.IO.FileAttributes]::Hidden) | Should -BeTrue
        }
    }

    It 'clears a destination that carries the sibling marker, user files inside it included' {
        $out = New-TestDir 'marked'
        foreach ($side in 'base', 'head') {
            $null = New-Item -ItemType Directory (Join-Path $out $side)
            Write-TestText $out "$side.og-diff-side" 'm'
            (Get-Item -LiteralPath (Join-Path $out "$side.og-diff-side") -Force).Attributes = 'Hidden'
            Write-TestText (Join-Path $out $side) 'old/stuff.txt' 'old'
        }
        $r = Invoke-TestSides @{ WorkingDirectory = $script:mRepo; Kind = 'WorkingTree'
            BaseDestination = (Join-Path $out 'base'); HeadDestination = (Join-Path $out 'head') }
        Get-TestRelFiles $r.BaseDestination | Should -Be @('mod.txt')
        Get-TestRelFiles $r.HeadDestination | Should -Be @('mod.txt')
    }

    It 'clears a destination that carries the OLD in-folder marker (exports before od task 7) and moves the marker beside it' {
        $out = New-TestDir 'marked-old'
        foreach ($side in 'base', 'head') {
            Set-Content -LiteralPath (Join-Path (New-Item -ItemType Directory (Join-Path $out $side)) '.og-diff-side') -Value 'm'
            Write-TestText (Join-Path $out $side) 'old/stuff.txt' 'old'
        }
        $r = Invoke-TestSides @{ WorkingDirectory = $script:mRepo; Kind = 'WorkingTree'
            BaseDestination = (Join-Path $out 'base'); HeadDestination = (Join-Path $out 'head') }
        Get-TestRelFiles $r.BaseDestination | Should -Be @('mod.txt')
        Get-TestRelFiles $r.HeadDestination | Should -Be @('mod.txt')
        foreach ($d in $r.BaseDestination, $r.HeadDestination) {
            Test-Path -LiteralPath (Get-TestMarkerPath $d) -PathType Leaf | Should -BeTrue
        }
    }

    It 'refuses a non-empty folder beside which only a FOLDER of the marker''s name exists' {
        $out = New-TestDir 'markerdir'
        Write-TestText (Join-Path $out 'head') 'precious.txt' 'user data'
        $null = New-Item -ItemType Directory (Join-Path $out 'head.og-diff-side')
        { Invoke-TestSides @{ WorkingDirectory = $script:mRepo; Kind = 'WorkingTree'
            BaseDestination = (Join-Path $out 'base'); HeadDestination = (Join-Path $out 'head') } } |
            Should -Throw "*has no '.og-diff-side' marker*"
        Test-Path -LiteralPath (Join-Path $out 'head\precious.txt') | Should -BeTrue
    }

    It 'accepts an existing EMPTY folder' {
        $out = New-TestDir 'emptydirs'
        New-Item -ItemType Directory (Join-Path $out 'base'), (Join-Path $out 'head') | Out-Null
        $r = Invoke-TestSides @{ WorkingDirectory = $script:mRepo; Kind = 'WorkingTree'
            BaseDestination = (Join-Path $out 'base'); HeadDestination = (Join-Path $out 'head') }
        Get-TestRelFiles $r.HeadDestination | Should -Be @('mod.txt')
    }

    It 'refuses a non-empty folder without the marker, and clears NEITHER side' {
        $out = New-TestDir 'unmarked'
        $base = Join-Path $out 'base'; $head = Join-Path $out 'head'
        $p = @{ WorkingDirectory = $script:mRepo; Kind = 'WorkingTree'; BaseDestination = $base; HeadDestination = $head }
        Invoke-TestSides $p | Out-Null                      # base and head are now earlier exports
        Remove-Item -LiteralPath (Get-TestMarkerPath $head) -Force
        Write-TestText $head 'precious.txt' 'user data'      # head: a user's folder (no marker)
        Write-TestText $base 'stale.txt' 'old'              # base: an earlier export, clearable on its own

        { Invoke-TestSides $p } | Should -Throw "*has no '.og-diff-side' marker*"

        Test-Path -LiteralPath (Join-Path $head 'precious.txt') | Should -BeTrue
        # Both destinations are guarded before either is cleared: the clearable base was left alone too.
        Test-Path -LiteralPath (Join-Path $base 'stale.txt') | Should -BeTrue
    }

    It 'refuses an existing file as a destination' {
        $out = New-TestDir 'afile'
        $file = Join-Path $out 'base'
        Set-Content -LiteralPath $file -Value 'a file'
        { Invoke-TestSides @{ WorkingDirectory = $script:mRepo; Kind = 'WorkingTree'; BaseDestination = $file
            HeadDestination = (Join-Path $out 'head') } } | Should -Throw '*existing file*'
        Get-Content -LiteralPath $file | Should -Be 'a file'
    }

    It 'refuses an empty or whitespace destination' {
        # '' is already refused by parameter binding (Mandatory); whitespace reaches the guard.
        { Invoke-TestSides @{ WorkingDirectory = $script:mRepo; Kind = 'WorkingTree'; BaseDestination = ''
            HeadDestination = (Join-Path (New-TestDir 'ws') 'head') } } | Should -Throw
        { Invoke-TestSides @{ WorkingDirectory = $script:mRepo; Kind = 'WorkingTree'; BaseDestination = '   '
            HeadDestination = (Join-Path (New-TestDir 'ws') 'head') } } | Should -Throw '*fully qualified*'
    }
}

Describe 'Export-OgDiffSides: type changes (Range)' {
    It 'reports a file -> symlink change as TypeChanged, on both sides' {
        $repo = New-TestDir 'typechange'
        Invoke-TestGit $repo init -q | Out-Null
        Invoke-TestGit $repo config core.symlinks false | Out-Null   # deterministic: a link checks out as a text file
        Write-TestText $repo 'link' "a regular file`n"
        Invoke-TestGit $repo add -- 'link' | Out-Null
        Invoke-TestGit $repo commit -q -m file | Out-Null
        $targetFile = Join-Path (New-TestDir 'blob') 'target'
        [System.IO.File]::WriteAllText($targetFile, 'target.txt', $script:Utf8)
        # Direct git call: '-w' would be taken as an ambiguous PowerShell common parameter by Invoke-TestGit.
        $blob = (& git -C $repo hash-object -w -- $targetFile).Trim()
        $LASTEXITCODE | Should -Be 0
        Invoke-TestGit $repo rm -q --cached -- 'link' | Out-Null
        Invoke-TestGit $repo update-index --add --cacheinfo "120000,$blob,link" | Out-Null
        Invoke-TestGit $repo commit -q -m symlink | Out-Null

        $out = New-TestDir 'typechange-out'
        $r = Invoke-TestSides @{ WorkingDirectory = $repo; Kind = 'Range'; BaseRev = 'HEAD~1'; HeadRev = 'HEAD'
            BaseDestination = (Join-Path $out 'base'); HeadDestination = (Join-Path $out 'head') }

        @($r.Files | ForEach-Object { "$($_.Path)=$($_.Status)" }) | Should -Be @('link=TypeChanged')
        $r.Files[0].OnBase | Should -BeTrue
        $r.Files[0].OnHead | Should -BeTrue
        $r.Files[0].BaseMode | Should -Be '100644'
        $r.Files[0].HeadMode | Should -Be '120000'
        $script:Utf8.GetString((Read-TestBytes $r.BaseDestination 'link')) | Should -BeExactly "a regular file`n"
        $script:Utf8.GetString((Read-TestBytes $r.HeadDestination 'link')) | Should -BeExactly 'target.txt'
    }

    It 'keeps only the file side of a file-to-gitlink change and back (Deleted one way, Added the other)' {
        $repo = New-TestDir 'filegitlink'
        Invoke-TestGit $repo init -q | Out-Null
        Write-TestText $repo 'sub' "was a file`n"
        Invoke-TestGit $repo add -- 'sub' | Out-Null
        Invoke-TestGit $repo commit -q -m file | Out-Null
        $someCommit = Invoke-TestGit $repo rev-parse HEAD
        Invoke-TestGit $repo rm -q --cached -- 'sub' | Out-Null
        Invoke-TestGit $repo update-index --add --cacheinfo "160000,$someCommit,sub" | Out-Null
        Invoke-TestGit $repo commit -q -m gitlink | Out-Null
        (Invoke-TestGit $repo ls-tree HEAD -- 'sub') | Should -Match '^160000 commit'

        $out = New-TestDir 'filegitlink-out'
        $toLink = Invoke-TestSides @{ WorkingDirectory = $repo; Kind = 'Range'; BaseRev = 'HEAD~1'; HeadRev = 'HEAD'
            BaseDestination = (Join-Path $out 'b1'); HeadDestination = (Join-Path $out 'h1') }
        @($toLink.Files | ForEach-Object { "$($_.Path)=$($_.Status)" }) | Should -Be @('sub=Deleted')
        Get-TestRelFiles $toLink.BaseDestination | Should -Be @('sub')
        Get-TestRelFiles $toLink.HeadDestination | Should -Be @()

        $toFile = Invoke-TestSides @{ WorkingDirectory = $repo; Kind = 'Range'; BaseRev = 'HEAD'; HeadRev = 'HEAD~1'
            BaseDestination = (Join-Path $out 'b2'); HeadDestination = (Join-Path $out 'h2') }
        @($toFile.Files | ForEach-Object { "$($_.Path)=$($_.Status)" }) | Should -Be @('sub=Added')
        Get-TestRelFiles $toFile.BaseDestination | Should -Be @()
        Get-TestRelFiles $toFile.HeadDestination | Should -Be @('sub')
    }
}

Describe 'Invoke-OgGitPlumbing' {
    It 'reports git''s exit code and stderr when git exits before reading stdin (no raw broken-pipe error)' {
        $big = 'x' * (4 * 1024 * 1024)   # far beyond a pipe buffer, so the write outlives git
        $r = InModuleScope og-framework -Parameters @{ D = $TestDrive; T = $big } {
            Invoke-OgGitPlumbing -WorkingDirectory $D -Arguments 'hash-object', '--no-such-option-od1' -InputText $T
        }
        $r.ExitCode | Should -Not -Be 0
        $r.StdErr | Should -Match 'no-such-option-od1|unknown option|usage'
    }
}
