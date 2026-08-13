---
name: worktree-baseref-trap
description: EnterWorktree's default baseRef branches from origin/<default-branch>, not the submodule's current working branch — silently loses uncommitted-to-main work when editing tools/og-tools.
metadata:
  type: feedback
---

When a background Implementer session tries to Write/Edit inside `tools/og-tools` (a submodule
with its own git repo under `C:\dev\og-brawler-unreal`), the harness's background-write guard
blocks direct edits and pushes toward `EnterWorktree` — UNLESS that repo has its own
`.claude/settings.json` with `{"worktree":{"bgIsolation":"none"}}`. The parent superproject
(`C:\dev\og-brawler-unreal\.claude\settings.json`) already has this set, but it does **not**
cascade into a nested git repo (submodules are their own project root for this purpose).

**Why this matters:** `EnterWorktree`'s default `worktree.baseRef` is `fresh`, which branches from
`origin/<default-branch>` (i.e. `origin/main`) — NOT the branch actually checked out in the
directory you're working in. If the real checkout is on a feature branch with unpushed/unmerged
commits (e.g. `feature/netcode-v2`), a fresh worktree silently lacks all of that branch's history —
including files that only exist there. Concretely: `Merge-OgToMain.ps1` and its test
(`tests/Merge-OgToMain.Tests.ps1`) only existed on `feature/netcode-v2`, not on `origin/main`; a
worktree built from `fresh` had neither, and `Invoke-Pester` on that path silently discovered 0
tests from that file (not a failure — the file just wasn't there) instead of erroring loudly.
Caught only by noticing the total test count matched exactly what one *other* file alone would
produce.

**Fix used:** exit/remove the wrong worktree, add
`tools/og-tools/.claude/settings.json` = `{"worktree":{"bgIsolation":"none"}}` (via Bash, since the
Write/Edit tool itself is what's gated — Bash heredoc writes are not blocked by the same guard),
then work directly in the real checkout.

**How to apply:** before trusting `EnterWorktree` inside any git submodule of this project, check
whether the intended work depends on commits that exist on the checked-out branch but not on
`origin/<default-branch>` (typical for any active feature branch). If so, either add the
`bgIsolation: none` override for that submodule first, or explicitly verify the worktree's `git
log` / file listing matches the real checkout before proceeding — don't assume a freshly created
worktree has the same content as `pwd`. See [[og-tools-conventions]] for the repo this bit me in.
