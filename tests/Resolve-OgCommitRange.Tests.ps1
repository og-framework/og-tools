# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

# Covers the commit-range resolver (Resolve-OgCommitRange) and the picker's touch summary
# (Get-OgCommitTouchSummary), od task 4a.
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
        , @(InModuleScope og-framework -Parameters @{ P = $P } { Resolve-OgCommitRange @P })
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
    # "added submodule" cascade).
    function New-ThreeLevelTree {
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
        $p = New-TestProject
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

    It 'is read-only on every repo, even with stat-dirty work trees' {
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

        $after = Get-TestRepoSnapshot -Project $t.Project -WorkTrees $workTrees
        $after | Should -Be $before
        $removed.Count | Should -Be 2   # it did resolve (the comparison is not vacuous)
        $cascade.Count | Should -Be 3
    }

    It 'gives a parentless root commit an empty base' {
        $p = New-TestProject
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
        $p = New-TestProject
        { Resolve-TestRange -ProjectRoot $p.Project -Commit 'no-such-ref' } | Should -Throw '*does not name a commit*'
        { Resolve-TestRange -ProjectRoot $p.Project -Commit '--all' }       | Should -Throw '*invalid revision*'
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
