---
name: og-tools-conventions
description: Module layout, git-call seam, Pester test conventions, and git policy for the og-tools PowerShell repo (og-framework module).
metadata:
  type: project
---

`og-tools` (submodule of `C:\dev\og-brawler-unreal`, own git repo, module name `og-framework`) is
a small (~13 cmdlet) PowerShell 7.4+ toolkit for the og-framework multi-repo submodule tree. MPL-2.0
SPDX header on every `.ps1`. No `CONTRIBUTING.md` — style comes from reading `Public/*.ps1` and
`tests/*.ps1` directly.

**Layout:**
- `Public/<Verb-OgNoun>.ps1` — one exported cmdlet per file, dot-sourced by `og-framework.psm1`,
  listed in `og-framework.psd1` (`FunctionsToExport`/`AliasesToExport`).
- `Private/Invoke-Git.ps1` — every git call in `Public/*` goes through this wrapper
  (`{ExitCode, StdOut, StdErr, WorkingDirectory}`), never shells to `git` directly. This is also the
  seam Pester tests mock.
- `Private/Resolve-OgRepoTree.ps1` — walks `.gitmodules` **purely textually** (parses the file +
  checks the filesystem for a real `.git` at that path). Does NOT consult git's own submodule
  registration/gitlinks. Consequence: you can build a real multi-repo test tree by hand-writing a
  `.gitmodules` entry (`git config -f <path>/.gitmodules submodule.X.path X` /
  `submodule.X.url ...`) pointing at a plain nested git repo — no `git submodule add` needed, which
  sidesteps modern git's file-protocol restrictions entirely.
- `og-framework.format.ps1xml` — `PSTypeName`-keyed table views (`Og.DiffResult`,
  `Og.MergeResult`, `Og.RepoStatus`, ...). Adding new properties to a result object does NOT
  require updating this file (extras just don't show in the default table).

**Pester conventions (5.7.1):** each `tests/<Cmdlet>.Tests.ps1` is self-contained — `BeforeAll`
does `Import-Module "$moduleRoot\og-framework.psd1" -Force`, then redefines a local `git-in`
(throws on non-zero exit) and `New-TestGitRepo` (single-commit throwaway repo under the OS temp
dir) rather than sharing a common helper file. To avoid ever launching a real GUI difftool in
tests: `Mock -ModuleName og-framework -CommandName Invoke-Git -ParameterFilter { $Arguments
-contains 'difftool' } -MockWith { ... }` — this intercepts only the difftool call and lets every
other `Invoke-Git` call (emptiness checks, ref resolution, etc.) run for real against the temp
repo, so test assertions are backed by genuine git behavior, not a fully-mocked fake.

**Git policy for agents working in this repo:** read-only git against the project's own repos
(this repo, parent, any submodule) is fine; state-changing git against them is forbidden for
agents (the user runs it manually) — EXCEPT Pester tests creating/mutating throwaway temp repos
under the OS temp dir, which is expected and how the existing suite already works. A cmdlet
running a mutating git command *at runtime because the user passed a flag for it* (e.g.
`Show-OgDiff -Fetch`, `Merge-OgToMain -Force`) is the feature working as designed, not a policy
violation — the constraint is on what the agent runs directly during development/testing.

**Private helpers for a complex sub-feature:** when one `Public/*.ps1` cmdlet's behaviour branches
into a multi-step, multi-failure-mode sub-flow (e.g. `Show-OgDiff`'s `-Against -DirDiff` export
path), it's fine to split that into a few new `Private/*.ps1` files (one orchestrator + smaller
single-purpose helpers) rather than inlining everything into the public cmdlet's loop — the module
loader dot-sources everything under `Private/` automatically (no manifest changes needed), and
`Mock -ModuleName og-framework -CommandName <PrivateFn>` works identically regardless of which
function in the module calls it, so the existing `Invoke-Git`-mocking test strategy is unaffected.

See also [[worktree-baseref-trap]] for a related environment gotcha specific to this submodule, and
[[pwsh-pester-gotchas]] for tar/pwsh argument-marshalling and Pester v5 scoping traps hit while
building `Show-OgDiff`'s persistent-export feature.
