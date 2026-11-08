# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

# Covers the commit-range resolver (Resolve-OgCommitRange) and the picker's touch summary
# (Get-OgCommitTouchSummary), od task 4a; and the pins of a tree and the range between two root commits
# (Get-OgTreePins, Resolve-OgTreeRange), od task 8. Every Resolve-OgCommitRange fixture also checks that
# Resolve-OgTreeRange -From X^1 -To X returns the same entries (Resolve-TestRange).
#
# Every tree is a throwaway under $TestDrive, sandboxed by Enter-OgGitSandbox, and is built and committed
# with the real og cmdlets (Add-OgSubmodule, Add-OgChange, New-OgCommit), so the ranges asserted are the
# ones a real `oggitcommit` cascade produces. Expected ids are read back from the gitlinks themselves
# (`git rev-parse <commit>:<path>`), never from a submodule's current HEAD.

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force
    . "$PSScriptRoot\OgGitTestHelpers.ps1"
    Enter-OgGitSandbox -Root (Join-Path $TestDrive 'sandbox')

    $script:EntryFields = @('Repo', 'Path', 'WorkingDirectory', 'BaseRev', 'HeadRev', 'Status', 'Error', 'GitDir', 'HasWorkTree')

    function Resolve-TestRange {
        param([string] $ProjectRoot, [string] $Commit, [object[]] $RepoTree)
        $P = @{ ProjectRoot = $ProjectRoot; Commit = $Commit }
        if ($RepoTree) { $P.RepoTree = $RepoTree }
        $entries = @(InModuleScope og-framework -Parameters @{ P = $P } { Resolve-OgCommitRange @P })
        # od task 8 (R2): on EVERY fixture of this file, the same commit resolved through the pin pairing
        # (Resolve-OgTreeRange -From <commit>^1 -To <commit>) must give exactly these entries.
        Assert-TestTreeRangeEquivalent -ProjectRoot $ProjectRoot -Commit $Commit -RepoTree $RepoTree -Expected $entries
        , $entries
    }

    function Resolve-TestTreeRange {
        param([string] $ProjectRoot, [AllowEmptyString()] [string] $From, [string] $To, [object[]] $RepoTree)
        $P = @{ ProjectRoot = $ProjectRoot; From = $From; To = $To }
        if ($RepoTree) { $P.RepoTree = $RepoTree }
        , @(InModuleScope og-framework -Parameters @{ P = $P } { Resolve-OgTreeRange @P })
    }

    function Get-TestPins {
        param([string] $ProjectRoot, [string] $Commit, [object[]] $RepoTree)
        $P = @{ ProjectRoot = $ProjectRoot; Commit = $Commit }
        if ($RepoTree) { $P.RepoTree = $RepoTree }
        , @(InModuleScope og-framework -Parameters @{ P = $P } { Get-OgTreePins @P })
    }

    # Every field of every entry, type name included, one line per entry (compared case-sensitively).
    function Format-TestEntries {
        param([object[]] $Entries)
        @(foreach ($e in $Entries) {
            (@("type=$($e.PSObject.TypeNames[0])") + @(foreach ($f in $script:EntryFields) { "$f=$($e.$f)" })) -join ' | '
        }) -join "`n"
    }

    # Resolve-OgTreeRange from the commit's FIRST parent (the empty tree, -From '', for a parentless one)
    # to the commit equals Resolve-OgCommitRange of the commit, entry by entry and field by field.
    $script:EquivalenceChecks = 0
    function Assert-TestTreeRangeEquivalent {
        param([string] $ProjectRoot, [string] $Commit, [object[]] $RepoTree, [object[]] $Expected)
        $parent = & git -C $ProjectRoot rev-parse --verify --quiet "$Commit^1^{commit}" 2>$null
        $from   = if ($LASTEXITCODE -eq 0) { "$parent".Trim() } else { '' }
        $actual = Resolve-TestTreeRange -ProjectRoot $ProjectRoot -From $from -To $Commit -RepoTree $RepoTree
        Format-TestEntries $actual | Should -BeExactly (Format-TestEntries $Expected) `
            -Because "Resolve-OgTreeRange -From '$from' -To $Commit must equal Resolve-OgCommitRange -Commit $Commit"
        $script:EquivalenceChecks++
    }

    function Get-TestSummary {
        param([object[]] $Entries, [switch] $Detail)
        InModuleScope og-framework -Parameters @{ E = $Entries; D = [bool] $Detail } {
            Get-OgCommitTouchSummary -Entry $E -Detail:$D
        }
    }

    # The full id of a revision, or of a gitlink with '<commit>:<path>'.
    function Get-TestRev {
        param([string] $Dir, [string] $Rev = 'HEAD')
        Invoke-TestGit $Dir rev-parse $Rev
    }

    # Three levels: project (root) -> libs/child -> libs/child/ext/nested, the nested one added with
    # oggitsubadd and committed with oggitadd + oggitcommit (so the tree's newest root commit IS the
    # "added submodule" cascade). Built once per file; each test gets its own filesystem copy (od task 13,
    # Copy-TestFixture in OgGitTestHelpers.ps1): a rebuild cost ~18 s (two `git submodule add`, one
    # `clone --recurse-submodules`), a copy ~0.3 s, and a test's commits, pushes and rm's stay in its copy.
    function New-ThreeLevelTree {
        Copy-TestFixture -Key 'three-level' -Builder {
            $p = New-TestProject
            $nestedUrl = New-TestRemote -Root $p.Remotes -Name 'nested'
            Add-OgSubmodule -Url $nestedUrl -Path 'libs/child/ext/nested' -ProjectRoot $p.Project | Out-Null
            Add-OgChange -ProjectRoot $p.Project | Out-Null
            New-OgCommit -Message 'add nested' -ProjectRoot $p.Project | Out-Null
            $p.Child  = Join-Path $p.Project 'libs\child'
            $p.Nested = Join-Path $p.Project 'libs\child\ext\nested'
            $p.GitDir = Join-Path $p.Project '.git'
            $p
        }
    }

    # Every file under the root's .git (submodule git dirs are absorbed there: modules/...), hashed, plus
    # each repo's porcelain status read WITHOUT optional locks (so the snapshot itself never refreshes an
    # index). Any write by the resolver -- index, refs, config, logs, objects -- changes this string.
    function Get-TestRepoSnapshot {
        param([string] $Project, [string[]] $WorkTrees)
        $gitDir = Join-Path $Project '.git'
        $files = Get-ChildItem -LiteralPath $gitDir -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
            "$($_.FullName.Substring($gitDir.Length))|$($_.LastWriteTimeUtc.Ticks)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
        }
        $status = foreach ($wt in $WorkTrees) {
            "$wt>" + ((& git -C $wt --no-optional-locks status --porcelain --ignore-submodules=none 2>&1) -join ';')
        }
        (@($files) + @($status)) -join "`n"
    }

    # Same content, newer mtime: the stat-dirty state in which plain `git diff`/`git status` rewrite
    # .git/index (measured in od task 1). A resolver that ever ran one fails the snapshot comparison.
    function Set-TestStatDirty {
        param([string[]] $WorkTrees)
        $later = (Get-Date).AddMinutes(5)
        foreach ($wt in $WorkTrees) {
            foreach ($f in (Get-ChildItem -LiteralPath $wt -File -Force)) {
                if ($f.Name -eq '.git') { continue }
                $f.LastWriteTime = $later
            }
        }
    }
}

AfterAll {
    Exit-OgGitSandbox
}

Describe 'Resolve-OgCommitRange' {

    It 'returns the exact pinned old..new of every repo in a three-level oggitcommit cascade (no root entry for pins only)' {
        $t = New-ThreeLevelTree
        $oldChild  = Get-TestRev $t.Project 'HEAD:libs/child'
        $oldNested = Get-TestRev $t.Child 'HEAD:ext/nested'

        # Two nested commits inside one cascade: a manual one (picked up by oggitcommit's pre-pass) and
        # the cascade's own, so the old pin is NOT the new pin's parent.
        Add-TestCommit -Dir $t.Nested -File 'manual.txt' -Message 'manual'
        Set-Content -LiteralPath (Join-Path $t.Nested 'work.txt') -Value 'cascade work'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'cascade' -ProjectRoot $t.Project | Out-Null

        $sha       = Get-TestRev $t.Project
        $newChild  = Get-TestRev $t.Project 'HEAD:libs/child'
        $newNested = Get-TestRev $t.Child 'HEAD:ext/nested'
        Get-TestRev $t.Nested "$newNested^1" | Should -Not -Be $oldNested   # precondition: a two-commit range

        $e = Resolve-TestRange -ProjectRoot $t.Project -Commit $sha

        $e.Count | Should -Be 2
        $e[0].PSObject.TypeNames[0] | Should -Be 'Og.CommitRangeEntry'
        @($e[0].PSObject.Properties.Name) | Should -Be $script:EntryFields

        $e[0].Repo             | Should -Be 'child'
        $e[0].Path             | Should -Be 'libs/child'
        $e[0].WorkingDirectory | Should -Be $t.Child
        $e[0].BaseRev          | Should -Be $oldChild
        $e[0].HeadRev          | Should -Be $newChild
        $e[0].Status           | Should -Be 'changed'
        $e[0].Error            | Should -Be ''
        $e[0].HasWorkTree      | Should -BeTrue

        $e[1].Repo             | Should -Be 'nested'
        $e[1].Path             | Should -Be 'libs/child/ext/nested'
        $e[1].WorkingDirectory | Should -Be $t.Nested
        $e[1].BaseRev          | Should -Be $oldNested
        $e[1].HeadRev          | Should -Be $newNested
        $e[1].Status           | Should -Be 'changed'
        $e[1].HasWorkTree      | Should -BeTrue
    }

    It 'puts the root entry first (first parent..commit) when the run also changed root files' {
        $t = New-ThreeLevelTree
        $oldChild = Get-TestRev $t.Project 'HEAD:libs/child'
        $parent   = Get-TestRev $t.Project

        Set-Content -LiteralPath (Join-Path $t.Project 'root.txt') -Value 'root work'
        Set-Content -LiteralPath (Join-Path $t.Child 'child.txt') -Value 'child work'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'root and child' -ProjectRoot $t.Project | Out-Null
        $sha = Get-TestRev $t.Project

        $e = Resolve-TestRange -ProjectRoot $t.Project -Commit $sha

        @($e.Path) | Should -Be @('', 'libs/child')
        $e[0].Repo             | Should -Be (Split-Path $t.Project -Leaf)
        $e[0].WorkingDirectory | Should -Be $t.Project
        $e[0].BaseRev          | Should -Be $parent
        $e[0].HeadRev          | Should -Be $sha
        $e[0].Status           | Should -Be 'changed'
        $e[0].GitDir           | Should -Be $t.GitDir
        $e[1].BaseRev          | Should -Be $oldChild
        $e[1].HeadRev          | Should -Be (Get-TestRev $t.Project 'HEAD:libs/child')
    }

    It 'resolves a root-only commit to the root entry alone' {
        $t = New-ThreeLevelTree
        $parent = Get-TestRev $t.Project
        Add-TestCommit -Dir $t.Project -File 'docs/readme.txt' -Message 'root only'
        $sha = Get-TestRev $t.Project

        $e = Resolve-TestRange -ProjectRoot $t.Project -Commit 'HEAD'

        $e.Count      | Should -Be 1
        $e[0].Path    | Should -Be ''
        $e[0].BaseRev | Should -Be $parent
        $e[0].HeadRev | Should -Be $sha
        $e[0].Status  | Should -Be 'changed'
    }

    It 'diffs a merge commit against its FIRST parent' {
        $t = New-ThreeLevelTree
        $oldChild = Get-TestRev $t.Project 'HEAD:libs/child'

        Invoke-TestGit $t.Project checkout -q -b side | Out-Null
        Add-TestCommit -Dir $t.Child -File 'side.txt' -Message 'side child work'
        Invoke-TestGit $t.Project add -- libs/child | Out-Null
        Add-TestCommit -Dir $t.Project -File 'side-root.txt' -Message 'side root work + child pin'
        $sideChild = Get-TestRev $t.Project 'HEAD:libs/child'
        $sideTip   = Get-TestRev $t.Project

        Invoke-TestGit $t.Project checkout -q main | Out-Null
        Invoke-TestGit $t.Child checkout -q $oldChild | Out-Null
        Add-TestCommit -Dir $t.Project -File 'main.txt' -Message 'main work'
        $mainTip = Get-TestRev $t.Project
        Invoke-TestGit $t.Project merge -q --no-ff -m 'merge side' side | Out-Null
        $merge = Get-TestRev $t.Project
        Get-TestRev $t.Project "$merge^2" | Should -Be $sideTip   # precondition: a real two-parent merge

        $e = Resolve-TestRange -ProjectRoot $t.Project -Commit $merge

        @($e.Path)    | Should -Be @('', 'libs/child')
        $e[0].BaseRev | Should -Be $mainTip
        $e[0].HeadRev | Should -Be $merge
        $e[1].BaseRev | Should -Be $oldChild
        $e[1].HeadRev | Should -Be $sideChild
        $e[1].Status  | Should -Be 'changed'
    }

    It 'reports an added submodule with an empty base (the oggitsubadd cascade)' {
        $t = New-ThreeLevelTree
        $sha = Get-TestRev $t.Project

        $e = Resolve-TestRange -ProjectRoot $t.Project -Commit $sha

        @($e.Path)       | Should -Be @('libs/child', 'libs/child/ext/nested')
        $e[0].Status     | Should -Be 'changed'
        $e[0].BaseRev    | Should -Be (Get-TestRev $t.Project 'HEAD~1:libs/child')
        $e[1].Status     | Should -Be 'added'
        $e[1].BaseRev    | Should -Be ''
        $e[1].HeadRev    | Should -Be (Get-TestRev $t.Child 'HEAD:ext/nested')
        $e[1].HasWorkTree | Should -BeTrue
    }

    It 'reports a removed submodule with an empty head, read from the git dir its parent kept' {
        $t = New-ThreeLevelTree
        $oldChild  = Get-TestRev $t.Project 'HEAD:libs/child'
        $oldNested = Get-TestRev $t.Child 'HEAD:ext/nested'

        Invoke-TestGit $t.Child rm -q -- ext/nested | Out-Null
        New-OgCommit -Message 'drop nested' -ProjectRoot $t.Project | Out-Null
        Test-Path -LiteralPath $t.Nested | Should -BeFalse   # precondition: no work tree left

        $e = Resolve-TestRange -ProjectRoot $t.Project -Commit 'HEAD'

        @($e.Path)    | Should -Be @('libs/child', 'libs/child/ext/nested')
        $e[0].BaseRev | Should -Be $oldChild
        $e[0].HeadRev | Should -Be (Get-TestRev $t.Project 'HEAD:libs/child')
        $e[1].Status           | Should -Be 'removed'
        $e[1].BaseRev          | Should -Be $oldNested
        $e[1].HeadRev          | Should -Be ''
        $e[1].Error            | Should -Be ''
        $e[1].WorkingDirectory | Should -Be $t.Nested
        $e[1].HasWorkTree      | Should -BeFalse
        $e[1].GitDir           | Should -Be (Join-Path $t.GitDir 'modules\child-module\modules\ext\nested')
    }

    It 'follows a removed submodule into its nested repos, finding its git dir by the NAME in the commit''s .gitmodules' {
        # libs/child is declared as submodule 'child-module': its git dir is modules/child-module, not
        # modules/libs/child, and after `git rm` the working tree's .gitmodules no longer names it.
        $t = New-ThreeLevelTree
        $oldChild  = Get-TestRev $t.Project 'HEAD:libs/child'
        $oldNested = Get-TestRev $t.Child 'HEAD:ext/nested'

        Invoke-TestGit $t.Project rm -q -- libs/child | Out-Null
        Invoke-TestGit $t.Project commit -q -m 'drop child' | Out-Null
        Test-Path -LiteralPath $t.Child | Should -BeFalse   # precondition: no work tree left

        $e = Resolve-TestRange -ProjectRoot $t.Project -Commit 'HEAD'

        @($e.Path)    | Should -Be @('', 'libs/child', 'libs/child/ext/nested')   # root: its .gitmodules changed
        @($e.Status)  | Should -Be @('changed', 'removed', 'removed')
        $e[1].BaseRev | Should -Be $oldChild
        $e[1].HeadRev | Should -Be ''
        $e[1].GitDir  | Should -Be (Join-Path $t.GitDir 'modules\child-module')
        $e[2].BaseRev | Should -Be $oldNested
        $e[2].HeadRev | Should -Be ''
        $e[2].GitDir  | Should -Be (Join-Path $t.GitDir 'modules\child-module\modules\ext\nested')
    }

    It 'reports a submodule removed by oggitsubrm (git dir deleted) as missing-commit, not an error' {
        $t = New-ThreeLevelTree
        $oldNested = Get-TestRev $t.Child 'HEAD:ext/nested'

        Remove-OgSubmodule -Path 'libs/child/ext/nested' -ProjectRoot $t.Project -Confirm:$false | Out-Null
        New-OgCommit -Message 'oggitsubrm nested' -ProjectRoot $t.Project | Out-Null

        $e = Resolve-TestRange -ProjectRoot $t.Project -Commit 'HEAD'

        @($e.Path)    | Should -Be @('libs/child', 'libs/child/ext/nested')
        $e[0].Status  | Should -Be 'changed'
        $e[1].Status  | Should -Be 'missing-commit'
        $e[1].BaseRev | Should -Be $oldNested
        $e[1].HeadRev | Should -Be ''
        $e[1].GitDir  | Should -Be ''
        $e[1].Error   | Should -Match 'not initialised'
    }

    It 'reports a pin moved to a commit not present locally as missing-commit, does not follow it, and resolves the rest' {
        $t = New-ThreeLevelTree
        $oldChild = Get-TestRev $t.Project 'HEAD:libs/child'

        # A real child commit that exists only on the remote (pushed from another clone, never fetched here).
        $other = Join-Path $t.Root 'other-child'
        Invoke-TestGit $t.Root clone -q $t.ChildUrl $other | Out-Null
        Add-TestCommit -Dir $other -File 'remote-only.txt' -Message 'remote only'
        Invoke-TestGit $other push -q origin HEAD:refs/heads/remote-only | Out-Null
        $remoteOnly = Get-TestRev $other
        { Invoke-TestGit $t.Child cat-file -e "$remoteOnly^{commit}" } | Should -Throw   # precondition

        Set-Content -LiteralPath (Join-Path $t.Project 'root.txt') -Value 'root work'
        Invoke-TestGit $t.Project add -- root.txt | Out-Null
        Invoke-TestGit $t.Project update-index --cacheinfo "160000,$remoteOnly,libs/child" | Out-Null
        Invoke-TestGit $t.Project commit -q -m 'pin to a commit not fetched' | Out-Null

        $e = Resolve-TestRange -ProjectRoot $t.Project -Commit 'HEAD'

        @($e.Path)       | Should -Be @('', 'libs/child')   # nothing under libs/child/ is followed
        $e[0].Status     | Should -Be 'changed'
        $e[1].Status     | Should -Be 'missing-commit'
        $e[1].BaseRev    | Should -Be $oldChild
        $e[1].HeadRev    | Should -Be $remoteOnly
        $e[1].Error      | Should -Match "head pin $remoteOnly"
        $e[1].Error      | Should -Not -Match 'base pin'
        $e[1].GitDir     | Should -Be (Join-Path $t.GitDir 'modules\child-module')
        $e[1].HasWorkTree | Should -BeTrue
    }

    It 'reports a submodule that is not initialised in the working tree as missing-commit at where it would be' {
        $p = Copy-TestFixture -Key 'project' -Builder { New-TestProject }   # od task 13: built once, copied
        $child = Join-Path $p.Project 'libs\child'
        Add-TestCommit -Dir $child -File 'c.txt' -Message 'child work'
        Invoke-TestGit $child push -q origin main | Out-Null
        Invoke-TestGit $p.Project add -- libs/child | Out-Null
        Invoke-TestGit $p.Project commit -q -m 'bump child' | Out-Null
        Invoke-TestGit $p.Project push -q origin main | Out-Null

        $clone = Join-Path $p.Root 'shallow-clone'
        Invoke-TestGit $p.Root clone -q $p.ParentUrl $clone | Out-Null   # no --recurse-submodules

        $e = Resolve-TestRange -ProjectRoot $clone -Commit 'HEAD'

        $e.Count               | Should -Be 1
        $e[0].Path             | Should -Be 'libs/child'
        $e[0].Status           | Should -Be 'missing-commit'
        $e[0].WorkingDirectory | Should -Be (Join-Path $clone 'libs\child')
        $e[0].HasWorkTree      | Should -BeFalse
        $e[0].GitDir           | Should -Be ''
        $e[0].HeadRev          | Should -Be (Get-TestRev $child)
        $e[0].Error            | Should -Match 'not initialised'
    }

    It 'resolves two cascades in a row each to its own ranges only' {
        $t = New-ThreeLevelTree
        $child0  = Get-TestRev $t.Project 'HEAD:libs/child'
        $nested0 = Get-TestRev $t.Child 'HEAD:ext/nested'

        Set-Content -LiteralPath (Join-Path $t.Nested 'a.txt') -Value 'cascade A'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'cascade A' -ProjectRoot $t.Project | Out-Null
        $rootA   = Get-TestRev $t.Project
        $childA  = Get-TestRev $t.Project 'HEAD:libs/child'
        $nestedA = Get-TestRev $t.Child 'HEAD:ext/nested'

        Set-Content -LiteralPath (Join-Path $t.Child 'b.txt') -Value 'cascade B'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'cascade B' -ProjectRoot $t.Project | Out-Null
        $rootB  = Get-TestRev $t.Project
        $childB = Get-TestRev $t.Project 'HEAD:libs/child'

        $a = Resolve-TestRange -ProjectRoot $t.Project -Commit $rootA
        $b = Resolve-TestRange -ProjectRoot $t.Project -Commit $rootB

        @($a.Path)    | Should -Be @('libs/child', 'libs/child/ext/nested')
        $a[0].BaseRev | Should -Be $child0
        $a[0].HeadRev | Should -Be $childA
        $a[1].BaseRev | Should -Be $nested0
        $a[1].HeadRev | Should -Be $nestedA

        @($b.Path)    | Should -Be @('libs/child')
        $b[0].BaseRev | Should -Be $childA
        $b[0].HeadRev | Should -Be $childB
    }

    # od task 13: this was two tests, one per Describe, on the same fixture with the same snapshot (one for this
    # resolver, one for od task 8's Get-OgTreePins and Resolve-OgTreeRange): merged, every call runs between the
    # two snapshots, so a write by any of the three fails it.
    It 'is read-only on every repo, even with stat-dirty work trees: Resolve-OgCommitRange, Get-OgTreePins and Resolve-OgTreeRange' {
        $t = New-ThreeLevelTree
        Set-Content -LiteralPath (Join-Path $t.Nested 'n.txt') -Value 'nested'
        Set-Content -LiteralPath (Join-Path $t.Project 'r.txt') -Value 'root'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'cascade' -ProjectRoot $t.Project | Out-Null
        # A removed submodule too, so the modules-dir path (--git-dir/--work-tree) is exercised.
        Invoke-TestGit $t.Child rm -q -- ext/nested | Out-Null
        New-OgCommit -Message 'drop nested' -ProjectRoot $t.Project | Out-Null
        # Uncommitted work left in every repo, staged and unstaged.
        Set-Content -LiteralPath (Join-Path $t.Project 'dirty.txt') -Value 'dirty'
        Set-Content -LiteralPath (Join-Path $t.Child 'staged.txt') -Value 'staged'
        Invoke-TestGit $t.Child add -- staged.txt | Out-Null

        $workTrees = @($t.Project, $t.Child)
        Set-TestStatDirty -WorkTrees $workTrees
        $before = Get-TestRepoSnapshot -Project $t.Project -WorkTrees $workTrees

        $removed = Resolve-TestRange -ProjectRoot $t.Project -Commit 'HEAD'
        $cascade = Resolve-TestRange -ProjectRoot $t.Project -Commit 'HEAD~1'
        $pins    = Get-TestPins -ProjectRoot $t.Project -Commit 'HEAD~1'
        $range   = Resolve-TestTreeRange -ProjectRoot $t.Project -From 'HEAD~2' -To 'HEAD'

        $after = Get-TestRepoSnapshot -Project $t.Project -WorkTrees $workTrees
        $after | Should -Be $before
        $removed.Count | Should -Be 2   # it did resolve (the comparison is not vacuous)
        $cascade.Count | Should -Be 3
        $pins.Count  | Should -Be 3     # it did read, through modules/ too
        $pins[2].HasWorkTree | Should -BeFalse
        $range.Count | Should -Be 3
    }

    It 'gives a parentless root commit an empty base' {
        $p = Copy-TestFixture -Key 'project' -Builder { New-TestProject }   # od task 13: built once, copied
        $first = Invoke-TestGit $p.Project rev-list --max-parents=0 HEAD

        $e = Resolve-TestRange -ProjectRoot $p.Project -Commit $first

        $e.Count      | Should -Be 1
        $e[0].Status  | Should -Be 'added'
        $e[0].BaseRev | Should -Be ''
        $e[0].HeadRev | Should -Be $first
    }

    It 'names repos from a passed -RepoTree' {
        $t = New-ThreeLevelTree
        $tree = @(InModuleScope og-framework -Parameters @{ R = $t.Project } { Resolve-OgRepoTree -ProjectRoot $R } |
            ForEach-Object { $n = $_.PSObject.Copy(); $n.Name = "tree-$($n.Name)"; $n })

        $e = Resolve-TestRange -ProjectRoot $t.Project -Commit 'HEAD' -RepoTree $tree

        @($e.Repo) | Should -Be @('tree-child', 'tree-nested')
    }

    It 'throws for a revision that is not a commit, or that looks like an option' {
        $p = Copy-TestFixture -Key 'project' -Builder { New-TestProject }   # od task 13: built once, copied
        { Resolve-TestRange -ProjectRoot $p.Project -Commit 'no-such-ref' } | Should -Throw '*does not name a commit*'
        { Resolve-TestRange -ProjectRoot $p.Project -Commit '--all' }       | Should -Throw '*invalid revision*'
    }

    It 'checked Resolve-OgTreeRange X^1..X against Resolve-OgCommitRange X on every fixture above (od task 8)' {
        # Resolve-TestRange runs the equivalence assertion on each call that resolves; the tests above make
        # 16 such calls (two each in the "two cascades" and "read-only" tests, none in the "throws" test).
        # A lower count means the check was skipped, so the equivalence would be pinned vacuously. Run
        # this Describe whole: a filtered run cannot reach the count. Adding a fixture above: raise it.
        $script:EquivalenceChecks | Should -Be 16
    }
}

Describe 'Get-OgTreePins and Resolve-OgTreeRange' {

    BeforeAll {
        $script:PinFields = @('Repo', 'Path', 'WorkingDirectory', 'Pin', 'GitDir', 'HasWorkTree', 'Status', 'Error')

        # A real child commit that exists only on the remote (pushed from another clone, never fetched into
        # the tree); returns its id.
        function New-TestRemoteOnlyChildCommit {
            param([hashtable] $Tree)
            $other = Join-Path $Tree.Root ('other-child-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 6))
            Invoke-TestGit $Tree.Root clone -q $Tree.ChildUrl $other | Out-Null
            Add-TestCommit -Dir $other -File 'remote-only.txt' -Message 'remote only'
            Invoke-TestGit $other push -q origin HEAD:refs/heads/remote-only | Out-Null
            Get-TestRev $other
        }

        # A root commit built from plumbing in a private index (the work trees are not touched): -Parent ''
        # gives a parentless commit with no history in common with the tree; -Entries are
        # '<mode>,<id>,<path>' cacheinfo strings added on top of -BaseTree ('' = an empty tree).
        function New-TestPlumbingCommit {
            param([string] $Dir, [string] $BaseTree = '', [string] $Parent = '', [string[]] $Entries, [string] $Message)
            $saved = $env:GIT_INDEX_FILE
            $env:GIT_INDEX_FILE = Join-Path $TestDrive ('plumb-' + [System.Guid]::NewGuid().ToString('N') + '.index')
            try {
                if ($BaseTree) { Invoke-TestGit $Dir read-tree $BaseTree | Out-Null }
                else { Invoke-TestGit $Dir read-tree --empty | Out-Null }
                foreach ($entry in $Entries) { Invoke-TestGit $Dir update-index --add --cacheinfo $entry | Out-Null }
                $tree = Invoke-TestGit $Dir write-tree
            } finally {
                if ($null -eq $saved) { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue } else { $env:GIT_INDEX_FILE = $saved }
            }
            # Quoted: a bare -p would bind to a PowerShell common parameter (-PipelineVariable) instead.
            if ($Parent) { Invoke-TestGit $Dir commit-tree $tree '-p' $Parent '-m' $Message }
            else { Invoke-TestGit $Dir commit-tree $tree '-m' $Message }
        }
    }

    It 'lists every repo a commit reaches, each nested pin read from its parent''s PINNED commit, never a tip' {
        $t = New-ThreeLevelTree
        Set-Content -LiteralPath (Join-Path $t.Nested 'a.txt') -Value 'cascade 1'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'cascade 1' -ProjectRoot $t.Project | Out-Null
        $r1 = Get-TestRev $t.Project
        $c1 = Get-TestRev $t.Project "${r1}:libs/child"
        $n1 = Get-TestRev $t.Child "${c1}:ext/nested"

        # A later cascade, then unpinned commits on top: the child's and the nested repo's tips (and the
        # child's own tree at its tip) are no longer what r1 pins.
        Set-Content -LiteralPath (Join-Path $t.Nested 'b.txt') -Value 'cascade 2'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'cascade 2' -ProjectRoot $t.Project | Out-Null
        Add-TestCommit -Dir $t.Nested -File 'tip.txt' -Message 'nested tip'
        Add-TestCommit -Dir $t.Child -File 'tip.txt' -Message 'child tip'
        Get-TestRev $t.Child                  | Should -Not -Be $c1   # preconditions: the tips differ
        Get-TestRev $t.Child 'HEAD:ext/nested' | Should -Not -Be $n1
        Get-TestRev $t.Nested                 | Should -Not -Be $n1

        $pins = Get-TestPins -ProjectRoot $t.Project -Commit $r1

        @($pins.Path) | Should -Be @('', 'libs/child', 'libs/child/ext/nested')
        $pins[0].PSObject.TypeNames[0] | Should -Be 'Og.TreePin'
        @($pins[0].PSObject.Properties.Name) | Should -Be $script:PinFields

        $pins[0].Repo             | Should -Be (Split-Path $t.Project -Leaf)
        $pins[0].WorkingDirectory | Should -Be $t.Project
        $pins[0].Pin              | Should -Be $r1
        $pins[0].GitDir           | Should -Be $t.GitDir
        $pins[0].HasWorkTree      | Should -BeTrue
        $pins[0].Status           | Should -Be 'present'
        $pins[0].Error            | Should -Be ''

        $pins[1].Repo             | Should -Be 'child'
        $pins[1].WorkingDirectory | Should -Be $t.Child
        $pins[1].Pin              | Should -Be $c1
        $pins[1].GitDir           | Should -Be (Join-Path $t.GitDir 'modules\child-module')
        $pins[1].HasWorkTree      | Should -BeTrue
        $pins[1].Status           | Should -Be 'present'

        $pins[2].Repo             | Should -Be 'nested'
        $pins[2].WorkingDirectory | Should -Be $t.Nested
        $pins[2].Pin              | Should -Be $n1
        $pins[2].GitDir           | Should -Be (Join-Path $t.GitDir 'modules\child-module\modules\ext\nested')
        $pins[2].Status           | Should -Be 'present'
    }

    It 'reports a pin missing locally as missing-commit and lists nothing below it, not even as absent' {
        $t = New-ThreeLevelTree
        $remoteOnly = New-TestRemoteOnlyChildCommit -Tree $t
        Invoke-TestGit $t.Project update-index --cacheinfo "160000,$remoteOnly,libs/child" | Out-Null
        Invoke-TestGit $t.Project commit -q -m 'pin to a commit not fetched' | Out-Null

        $pins = Get-TestPins -ProjectRoot $t.Project -Commit 'HEAD'

        @($pins.Path)       | Should -Be @('', 'libs/child')   # libs/child/ext/nested is unknown here
        $pins[1].Status     | Should -Be 'missing-commit'
        $pins[1].Pin        | Should -Be $remoteOnly
        $pins[1].Error      | Should -Match "pin $remoteOnly"
        $pins[1].GitDir     | Should -Be (Join-Path $t.GitDir 'modules\child-module')
        $pins[1].HasWorkTree | Should -BeTrue
    }

    It 'adds the og tree''s repos that the commit does not contain as absent rows, in tree order' {
        $t = New-ThreeLevelTree   # HEAD added libs/child/ext/nested; HEAD~1 has no nested repo

        $pins = Get-TestPins -ProjectRoot $t.Project -Commit 'HEAD~1'

        @($pins.Path)   | Should -Be @('', 'libs/child', 'libs/child/ext/nested')
        @($pins.Status) | Should -Be @('present', 'present', 'absent')
        $pins[1].Pin    | Should -Be (Get-TestRev $t.Project 'HEAD~1:libs/child')
        $pins[2].Repo             | Should -Be 'nested'
        $pins[2].WorkingDirectory | Should -Be $t.Nested
        $pins[2].Pin              | Should -Be ''
        $pins[2].GitDir           | Should -Be ''
        $pins[2].HasWorkTree      | Should -BeFalse
        $pins[2].Error            | Should -Be ''
    }

    It 'reads a removed submodule''s pin through the git dir its parent kept, and an uninitialised one as missing-commit' {
        $t = New-ThreeLevelTree
        $nested = Get-TestRev $t.Child 'HEAD:ext/nested'
        Invoke-TestGit $t.Child rm -q -- ext/nested | Out-Null
        New-OgCommit -Message 'drop nested' -ProjectRoot $t.Project | Out-Null

        $before = Get-TestPins -ProjectRoot $t.Project -Commit 'HEAD~1'
        $after  = Get-TestPins -ProjectRoot $t.Project -Commit 'HEAD'

        @($before.Path)        | Should -Be @('', 'libs/child', 'libs/child/ext/nested')
        $before[2].Status      | Should -Be 'present'
        $before[2].Pin         | Should -Be $nested
        $before[2].HasWorkTree | Should -BeFalse
        $before[2].GitDir      | Should -Be (Join-Path $t.GitDir 'modules\child-module\modules\ext\nested')
        @($after.Path)         | Should -Be @('', 'libs/child')

        $clone = Join-Path $t.Root 'plain-clone'
        Invoke-TestGit $t.Root clone -q $t.ParentUrl $clone | Out-Null   # no --recurse-submodules
        $pins = Get-TestPins -ProjectRoot $clone -Commit 'HEAD'
        @($pins.Path)    | Should -Be @('', 'libs/child')
        $pins[1].Status  | Should -Be 'missing-commit'
        $pins[1].GitDir  | Should -Be ''
        $pins[1].HasWorkTree | Should -BeFalse
        $pins[1].Error   | Should -Match 'not initialised'
    }

    It 'gives the exact pin pairs of a range across several cascades, root first, then depth-first' {
        $t = New-ThreeLevelTree
        $r0 = Get-TestRev $t.Project
        $c0 = Get-TestRev $t.Project 'HEAD:libs/child'
        $n0 = Get-TestRev $t.Child 'HEAD:ext/nested'

        Set-Content -LiteralPath (Join-Path $t.Nested 'one.txt') -Value 'cascade 1'
        Set-Content -LiteralPath (Join-Path $t.Project 'root.txt') -Value 'cascade 1'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'cascade 1' -ProjectRoot $t.Project | Out-Null
        $r1 = Get-TestRev $t.Project
        Set-Content -LiteralPath (Join-Path $t.Child 'two.txt') -Value 'cascade 2'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'cascade 2' -ProjectRoot $t.Project | Out-Null
        $r2 = Get-TestRev $t.Project
        Set-Content -LiteralPath (Join-Path $t.Nested 'three.txt') -Value 'cascade 3'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'cascade 3' -ProjectRoot $t.Project | Out-Null
        $r3 = Get-TestRev $t.Project
        $c3 = Get-TestRev $t.Project 'HEAD:libs/child'
        $n3 = Get-TestRev $t.Child 'HEAD:ext/nested'

        $e = Resolve-TestTreeRange -ProjectRoot $t.Project -From $r0 -To $r3

        @($e.Path) | Should -Be @('', 'libs/child', 'libs/child/ext/nested')
        $e[0].PSObject.TypeNames[0] | Should -Be 'Og.CommitRangeEntry'
        @($e[0].PSObject.Properties.Name) | Should -Be $script:EntryFields
        $e[0].BaseRev | Should -Be $r0
        $e[0].HeadRev | Should -Be $r3
        $e[0].Status  | Should -Be 'changed'
        $e[0].GitDir  | Should -Be $t.GitDir
        $e[1].BaseRev | Should -Be $c0
        $e[1].HeadRev | Should -Be $c3
        $e[1].Status  | Should -Be 'changed'
        $e[1].GitDir  | Should -Be (Join-Path $t.GitDir 'modules\child-module')
        $e[2].BaseRev | Should -Be $n0
        $e[2].HeadRev | Should -Be $n3
        $e[2].Status  | Should -Be 'changed'
        $e[2].Error   | Should -Be ''
        $e[2].HasWorkTree | Should -BeTrue

        # Each cascade on its own, through both resolvers (the R2 equivalence on this fixture too).
        foreach ($sha in $r1, $r2, $r3) {
            $single = Resolve-TestRange -ProjectRoot $t.Project -Commit $sha   # asserts the equivalence
            $single.Count | Should -BeGreaterThan 0
        }
    }

    It 'drops every repo pinned at the same commit at both ends' {
        $t = New-ThreeLevelTree
        Set-Content -LiteralPath (Join-Path $t.Nested 'one.txt') -Value 'cascade 1'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'cascade 1' -ProjectRoot $t.Project | Out-Null
        $r1 = Get-TestRev $t.Project
        Set-Content -LiteralPath (Join-Path $t.Child 'two.txt') -Value 'cascade 2'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'cascade 2' -ProjectRoot $t.Project | Out-Null
        $r2 = Get-TestRev $t.Project
        # Precondition: the nested pin is the same at both ends, the child's is not.
        Get-TestRev $t.Child "$(Get-TestRev $t.Project "${r1}:libs/child"):ext/nested" |
            Should -Be (Get-TestRev $t.Child "$(Get-TestRev $t.Project "${r2}:libs/child"):ext/nested")

        $e = Resolve-TestTreeRange -ProjectRoot $t.Project -From $r1 -To $r2

        @($e.Path)    | Should -Be @('libs/child')   # no root files changed; the nested pin did not move
        $e[0].BaseRev | Should -Be (Get-TestRev $t.Project "${r1}:libs/child")
        $e[0].HeadRev | Should -Be (Get-TestRev $t.Project "${r2}:libs/child")
        (Resolve-TestTreeRange -ProjectRoot $t.Project -From $r2 -To 'HEAD').Count | Should -Be 0
    }

    It 'reports repos added and removed between the ends' {
        $t = New-ThreeLevelTree
        $rA = Get-TestRev $t.Project 'HEAD~1'   # before libs/child/ext/nested was added
        Set-Content -LiteralPath (Join-Path $t.Nested 'one.txt') -Value 'cascade'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'cascade' -ProjectRoot $t.Project | Out-Null
        $rB = Get-TestRev $t.Project
        $nB = Get-TestRev $t.Child 'HEAD:ext/nested'
        Invoke-TestGit $t.Child rm -q -- ext/nested | Out-Null
        New-OgCommit -Message 'drop nested' -ProjectRoot $t.Project | Out-Null
        $rC = Get-TestRev $t.Project
        $nestedGitDir = Join-Path $t.GitDir 'modules\child-module\modules\ext\nested'

        $added   = Resolve-TestTreeRange -ProjectRoot $t.Project -From $rA -To $rB
        $removed = Resolve-TestTreeRange -ProjectRoot $t.Project -From $rB -To $rC
        $neither = Resolve-TestTreeRange -ProjectRoot $t.Project -From $rA -To $rC

        @($added.Path)    | Should -Be @('libs/child', 'libs/child/ext/nested')
        $added[1].Status  | Should -Be 'added'
        $added[1].BaseRev | Should -Be ''
        $added[1].HeadRev | Should -Be $nB
        $added[1].GitDir  | Should -Be $nestedGitDir   # its work tree is gone now: read from modules/
        $added[1].HasWorkTree | Should -BeFalse

        @($removed.Path)    | Should -Be @('libs/child', 'libs/child/ext/nested')
        $removed[1].Status  | Should -Be 'removed'
        $removed[1].BaseRev | Should -Be $nB
        $removed[1].HeadRev | Should -Be ''
        $removed[1].GitDir  | Should -Be $nestedGitDir
        $removed[1].Error   | Should -Be ''

        @($neither.Path)   | Should -Be @('libs/child')   # absent at both ends
        $neither[0].Status | Should -Be 'changed'
    }

    It 'reports a missing pin at either end as missing-commit, naming the side, and pairs nothing below it' {
        $t = New-ThreeLevelTree
        $r0 = Get-TestRev $t.Project
        $c0 = Get-TestRev $t.Project 'HEAD:libs/child'
        $remoteOnly = New-TestRemoteOnlyChildCommit -Tree $t
        Set-Content -LiteralPath (Join-Path $t.Project 'root.txt') -Value 'root work'
        Invoke-TestGit $t.Project add -- root.txt | Out-Null
        Invoke-TestGit $t.Project update-index --cacheinfo "160000,$remoteOnly,libs/child" | Out-Null
        Invoke-TestGit $t.Project commit -q -m 'pin to a commit not fetched' | Out-Null
        $rM = Get-TestRev $t.Project

        $forward  = Resolve-TestTreeRange -ProjectRoot $t.Project -From $r0 -To $rM
        $backward = Resolve-TestTreeRange -ProjectRoot $t.Project -From $rM -To $r0

        # r0 reaches libs/child/ext/nested, rM cannot (its child pin is unreadable): not 'removed'.
        @($forward.Path)    | Should -Be @('', 'libs/child')
        $forward[1].Status  | Should -Be 'missing-commit'
        $forward[1].BaseRev | Should -Be $c0
        $forward[1].HeadRev | Should -Be $remoteOnly
        $forward[1].Error   | Should -Match "head pin $remoteOnly"
        $forward[1].Error   | Should -Not -Match 'base pin'

        @($backward.Path)    | Should -Be @('', 'libs/child')
        $backward[1].Status  | Should -Be 'missing-commit'
        $backward[1].BaseRev | Should -Be $remoteOnly
        $backward[1].HeadRev | Should -Be $c0
        $backward[1].Error   | Should -Match "base pin $remoteOnly"
        $backward[1].Error   | Should -Not -Match 'head pin'
    }

    It 'compares two root commits as they are (two-dot): unrelated histories, and diverged branches never via their merge base' {
        $t = New-ThreeLevelTree
        $r0 = Get-TestRev $t.Project
        $c0 = Get-TestRev $t.Project 'HEAD:libs/child'
        $n0 = Get-TestRev $t.Child 'HEAD:ext/nested'
        Set-Content -LiteralPath (Join-Path $t.Nested 'one.txt') -Value 'cascade 1'
        Add-OgChange -ProjectRoot $t.Project | Out-Null
        New-OgCommit -Message 'cascade 1' -ProjectRoot $t.Project | Out-Null
        $r1 = Get-TestRev $t.Project
        $c1 = Get-TestRev $t.Project 'HEAD:libs/child'
        $n1 = Get-TestRev $t.Child 'HEAD:ext/nested'

        # Unrelated: a parentless root commit of its own, with one file, the .gitmodules, libs/child at c0 and
        # a gitlink 'aaa/extra' that sorts before libs/child and exists nowhere locally.
        $blob = ('unrelated' | & git -C $t.Project hash-object -w --stdin).Trim()
        $gitmodules = Get-TestRev $t.Project "${r0}:.gitmodules"
        $unrelated = New-TestPlumbingCommit -Dir $t.Project -Message 'unrelated' -Entries @(
            "100644,$blob,unrelated.txt", "100644,$gitmodules,.gitmodules", "160000,$c0,libs/child", "160000,$c0,aaa/extra")
        { Invoke-TestGit $t.Project merge-base $r1 $unrelated } | Should -Throw   # precondition: no common history

        $u    = Resolve-TestTreeRange -ProjectRoot $t.Project -From $r1 -To $unrelated
        $back = Resolve-TestTreeRange -ProjectRoot $t.Project -From $unrelated -To $r1

        @($u.Path)    | Should -Be @('', 'aaa/extra', 'libs/child', 'libs/child/ext/nested')
        $u[0].BaseRev | Should -Be $r1
        $u[0].HeadRev | Should -Be $unrelated
        $u[1].Status  | Should -Be 'missing-commit'   # no work tree, no git dir: unreadable, reported
        $u[1].HeadRev | Should -Be $c0
        $u[2].BaseRev | Should -Be $c1
        $u[2].HeadRev | Should -Be $c0
        $u[3].BaseRev | Should -Be $n1
        $u[3].HeadRev | Should -Be $n0
        # Tree order holds when a repo exists only at the BASE end, too.
        @($back.Path)    | Should -Be @('', 'aaa/extra', 'libs/child', 'libs/child/ext/nested')
        $back[1].BaseRev | Should -Be $c0
        $back[1].HeadRev | Should -Be ''

        # Diverged: a side commit on r0 that moves libs/child to a new child commit cS (made on top of c1,
        # so cS pins the nested repo at n1, as r1 does). Their merge base is r0: a three-dot range would
        # give the child as c0..cS and the nested repo as n0..n1. Two-dot: the child c1..cS, and the nested
        # repo, pinned at n1 at both ends, dropped.
        Add-TestCommit -Dir $t.Child -File 'side.txt' -Message 'side child work'
        $cS   = Get-TestRev $t.Child
        Get-TestRev $t.Child "${cS}:ext/nested" | Should -Be $n1   # precondition
        $side = New-TestPlumbingCommit -Dir $t.Project -BaseTree "${r0}^{tree}" -Parent $r0 -Message 'side' -Entries @(
            "160000,$cS,libs/child")
        Invoke-TestGit $t.Project merge-base $r1 $side | Should -Be $r0   # precondition

        $d = Resolve-TestTreeRange -ProjectRoot $t.Project -From $r1 -To $side

        @($d.Path)    | Should -Be @('libs/child')
        $d[0].BaseRev | Should -Be $c1
        $d[0].HeadRev | Should -Be $cS
        $d[0].Status  | Should -Be 'changed'
    }

    It 'treats -From '''' as the empty tree, and refuses a -From or -To that is not a commit' {
        $t = New-ThreeLevelTree

        $e = Resolve-TestTreeRange -ProjectRoot $t.Project -From '' -To 'HEAD'

        @($e.Path)    | Should -Be @('', 'libs/child', 'libs/child/ext/nested')
        @($e.Status)  | Should -Be @('added', 'added', 'added')
        @($e.BaseRev) | Should -Be @('', '', '')
        $e[0].HeadRev | Should -Be (Get-TestRev $t.Project)

        { Resolve-TestTreeRange -ProjectRoot $t.Project -From 'no-such-ref' -To 'HEAD' } | Should -Throw '*(-From) does not name a commit*'
        { Resolve-TestTreeRange -ProjectRoot $t.Project -From 'HEAD' -To '--all' }       | Should -Throw '*invalid revision*(-To)*'
        { Resolve-TestTreeRange -ProjectRoot $t.Project -From 'HEAD' -To '' }            | Should -Throw
        { Get-TestPins -ProjectRoot $t.Project -Commit 'no-such-ref' }                   | Should -Throw '*does not name a commit*'
        { Get-TestPins -ProjectRoot $t.Project -Commit '-x' }                            | Should -Throw '*invalid revision*'
    }
}

Describe 'Get-OgCommitTouchSummary' {

    BeforeAll {
        function New-TestEntry {
            param([string] $Repo, [string] $Path, [string] $Status = 'changed',
                  [string] $BaseRev = ('a' * 40), [string] $HeadRev = ('b' * 40))
            [PSCustomObject]@{ PSTypeName = 'Og.CommitRangeEntry'
                Repo = $Repo; Path = $Path; WorkingDirectory = "C:\x\$Path"; BaseRev = $BaseRev; HeadRev = $HeadRev
                Status = $Status; Error = ''; GitDir = ''; HasWorkTree = $true }
        }
    }

    It 'names the root as root and counts the other repos' {
        $entries = @(
            New-TestEntry -Repo 'og-brawler-unreal' -Path ''
            New-TestEntry -Repo 'og-brawler' -Path 'Plugins/og-brawler'
            New-TestEntry -Repo 'og-simulation' -Path 'Plugins/og-brawler/og-simulation'
            New-TestEntry -Repo 'og-tools' -Path 'tools/og-tools'
        )
        Get-TestSummary -Entries $entries | Should -Be 'root +3'
    }

    It 'starts with the first submodule when the root only moved pins, and has no "+0"' {
        Get-TestSummary -Entries @(
            New-TestEntry -Repo 'og-brawler' -Path 'Plugins/og-brawler'
            New-TestEntry -Repo 'og-simulation' -Path 'Plugins/og-brawler/og-simulation'
        ) | Should -Be 'og-brawler +1'
        Get-TestSummary -Entries @(New-TestEntry -Repo 'og-tools' -Path 'tools/og-tools') | Should -Be 'og-tools'
    }

    It 'counts missing-commit entries, and says (no changes) for none' {
        Get-TestSummary -Entries @(
            New-TestEntry -Repo 'r' -Path ''
            New-TestEntry -Repo 'a' -Path 'a' -Status 'missing-commit'
            New-TestEntry -Repo 'b' -Path 'b'
        ) | Should -Be 'root +2 (1 missing)'
        Get-TestSummary -Entries @() | Should -Be '(no changes)'
    }

    It 'lists every repo and range with -Detail, an empty side as empty' {
        $entries = @(
            New-TestEntry -Repo 'r' -Path '' -BaseRev ('1234567' + '0' * 33) -HeadRev ('89abcde' + '0' * 33)
            New-TestEntry -Repo 'new' -Path 'libs/new' -Status 'added' -BaseRev '' -HeadRev ('fedcba9' + '0' * 33)
            New-TestEntry -Repo 'old' -Path 'libs/old' -Status 'removed' -BaseRev ('7654321' + '0' * 33) -HeadRev ''
        )
        Get-TestSummary -Entries $entries -Detail |
            Should -Be 'root 1234567..89abcde, new empty..fedcba9 [added], old 7654321..empty [removed]'
    }

    It 'takes pipeline input' {
        $s = InModuleScope og-framework {
            @(
                [PSCustomObject]@{ Repo = 'r'; Path = ''; Status = 'changed'; BaseRev = ''; HeadRev = '' }
                [PSCustomObject]@{ Repo = 'c'; Path = 'c'; Status = 'changed'; BaseRev = ''; HeadRev = '' }
            ) | Get-OgCommitTouchSummary
        }
        $s | Should -Be 'root +1'
    }
}
