---
name: pwsh-pester-gotchas
description: Windows tar/pwsh argument-marshalling quirks and a Pester v5 scoping trap hit while implementing og-tools' Show-OgDiff persistent-export feature.
metadata:
  type: project
---

Three concrete gotchas hit implementing `og-tools-diff-against-ref` item 2 (persistent `git
archive` export for `Show-OgDiff -Against -DirDiff`, see [[og-tools-conventions]]). All three only
surfaced by actually running the code/tests, not by reasoning about it — worth prototyping any new
external-process or Pester-helper code with a standalone `pwsh -Command` one-liner before writing
it into the module, per the timing this cost.

**1. `Get-Command <name> -CommandType Application` can return an array on this machine.** Git for
Windows bundles `usr\bin\tar.exe` (MSYS2-linked GNU tar) and Windows 10+ ships its own
`System32\tar.exe` (bsdtar) — both end up on PATH. Piping the un-filtered result straight into
`.Source` silently produces one bogus multi-path string argument instead of erroring at the
`Get-Command` call site. Always `| Select-Object -First 1` (or otherwise disambiguate) when
resolving an external tool this way.

**2. GNU tar (MSYS2-linked) called from `pwsh.exe` with a raw `C:\...` backslash path fails in two
different ways, and forward-slashing the path is the fix for both.** As a non-MSYS caller, pwsh
hands GNU tar a plain Windows path; GNU tar's own argv layer either (a) misparses the drive letter
as an `ssh`-style `host:path` remote-archive spec (`Cannot connect to C: resolve failed`), or (b)
even with `--force-local` added to suppress that heuristic, mangles the backslashes outright
(`Cannot open: No such file or directory` for a directory that provably exists). Converting both
the archive path and the destination path to forward slashes (`$path.Replace('\', '/')`) before
handing them to `tar.exe` fixes both failure modes, and Windows' bsdtar-based `System32\tar.exe`
accepts forward-slash paths identically (no quirk to work around there, but no objection either) —
so forward-slashing unconditionally, and only adding `--force-local` when `tar --version` output
matches `GNU tar` (bsdtar rejects that flag as unrecognised), is the portable answer regardless of
which `tar` resolved.

**3. Pester v5: a function declared directly in a `Context { }` / `Describe { }` body (not inside
`BeforeAll`) only exists during Pester's *discovery* phase, not its *run* phase.** Every `It` block
that calls it fails with `CommandNotFoundException` even though the function is visible right above
it in the source — discovery and run are genuinely separate execution passes over the file, and
only `BeforeAll`/`BeforeEach` content (plus top-level `BeforeAll` in this repo's convention, see
[[og-tools-conventions]]) survives into run-phase scope. Any test-local helper function belongs in
a `BeforeAll` block, even a tiny one-off used by a single `Context`.

**4. This repo's `git-in` Pester test helper collapses multi-line git stdout into one trimmed
string** (`($out | Out-String).Trim()`), not an array of lines. `Should -Contain` against that
collapsed string checks it as a single collection element, so an assertion like
`(git-in $repo ls-tree -r --name-only $sha) | Should -Contain 'file.txt'` silently fails even when
`file.txt` is genuinely one of the listed lines. Split on `-split '\r?\n'` before using
array-style assertions (`-Contain`/`-Not -Contain`/`.Count`) against `git-in` output.
