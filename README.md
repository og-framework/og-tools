<!-- SPDX-License-Identifier: MPL-2.0 -->
# og-tools

PowerShell module for working with a multi-submodule git tree as one logical repo.
Provides typed, pipeline-composable cmdlets for status inspection, sync, staging,
committing with automatic pin-advance cascade, and push — so the full cross-repo
workflow across og-simulation, og-brawler, og-simulation-ue, og-brawler-ue, test
repos, and og-brawler-unreal becomes a handful of commands instead of many separate
`git -C <path>` invocations.

Dependency-free as of v1.0: no external PowerShell modules required.

## Position in the og-framework graph

og-tools is a **cross-cutting utility** submoduled by both consumer projects.

```
og-tools  (this repo — PowerShell toolkit)
    ↓ submoduled at tools/og-tools/ in
og-brawler-unreal      — UE game project
og-tests-cmake-runner  — CMake test runner
```

## Related repos

| Repo | Role |
|---|---|
| [og-brawler-unreal](https://github.com/og-framework/og-brawler-unreal) | Primary consumer; imports og-tools for cross-repo dev workflow |
| [og-tests-cmake-runner](https://github.com/og-framework/og-tests-cmake-runner) | Secondary consumer |

---

## Prerequisites

- **PowerShell 7.4+**
- `git` available on `$env:PATH`

---

## Installation

### Direct import

```powershell
Import-Module C:\path\to\og-tools\og-framework.psd1 -Force
```

### Persist across sessions (add to `$PROFILE`)

```powershell
# Add this line to your $PROFILE so the module loads every session:
Import-Module C:\dev\og-brawler-unreal\tools\og-tools\og-framework.psd1 -Force
```

Open `$PROFILE` in an editor: `notepad $PROFILE`

### As a submodule in an og-framework consumer project

og-tools is submoduled at `tools/og-tools/` inside og-brawler-unreal and
og-tests-cmake-runner. After cloning with `--recurse-submodules`, import from
the project root:

```powershell
# From e.g. C:\dev\og-brawler-unreal
Import-Module .\tools\og-tools\og-framework.psd1 -Force
```

Verify the import:

```powershell
Get-Command -Module og-framework | Select-Object Name, CommandType
```

---

## Cmdlet inventory

| Cmdlet | Alias | Purpose |
|--------|-------|---------|
| `Get-OgRepoStatus` | `oggitstatus` | Read tree state (PSObjects per repo) |
| `Show-OgDiff` | `oggitdiff` | Open what changed across the tree in the diff tool: one directory-diff tab per changed repo in one window; `-Staged`, `-Against`, `-Commit`, `-Pick`, `-From`, `-PerFile` ([reviewing changes](#reviewing-changes-with-oggitdiff)) |
| `Sync-OgFramework` | `oggitsync` | Fetch + ff-merge cascade deepest-first; initialises new submodules; `-Branch` syncs a feature branch instead of main |
| `Add-OgChange` | `oggitadd` | Stage changes across the tree; skips (with a warning) nested repos not declared in `.gitmodules` |
| `New-OgCommit` | `oggitcommit` | Commit + auto pin-advance cascade |
| `Push-OgFramework` | `oggitpush` | Push every repo deepest-first; `-u` for a branch new on origin |
| `Merge-OgToMain` | `oggitmerge` | Merge a feature branch into main deepest-first; initialises submodules new on main |
| `Add-OgSubmodule` | `oggitsubadd` | Add a repo as a submodule in the repo that owns the path, on the owner's feature branch; staged, not committed |
| `Remove-OgSubmodule` | `oggitsubrm` | Retire a submodule (deinit, `git rm`, clean `.git/modules`); staged, not committed; refuses on unpushed work |
| `Update-LicenseChangeDate` | `oglicstamp` | Stamp BSL Change Date at release time |
| `Update-OgLibPin` | — | Niche: pin a submodule to a specific historical SHA |
| `New-OgFeatureBranch` | — | Cross-repo branch creation; re-runnable (existing branches are skipped quietly); `-Repo` filter |
| `New-OgCloneScenario` | — | Scenario clone (simulation/brawler/unreal/cmake-runner); `-Branch` checks out a feature branch |
| `Test-OgPinConsistency` | — | CI validation; sets exit code 0/1 |
| `Publish-OgSteamBuild` | `ogsteampublish` | Package every depot, write SteamPipe VDFs, upload with steamcmd ([Steam publishing](#steam-publishing)) |
| `Invoke-OgUnrealBuild` | `ogbuild` | UBT (Build.bat) build of one or more targets; default `<Project>Editor` Win64 Development, the binary `ogplaytest` runs ([local playtest](#local-playtest)) |
| `Start-OgPlaytest` | `ogplaytest` | Local playtest: a dedicated server + N rendered clients (Editor binary, `-game`), or `-Join` clients to a running server ([local playtest](#local-playtest)) |
| `Invoke-OgUnrealPackage` | — | UAT BuildCookRun wrapper for one Win64 Client/Server/Game target |
| `Install-OgSteamCmd` | — | Download and bootstrap steamcmd into `%LOCALAPPDATA%\og-tools\steamcmd` |
| `New-OgDedicatedServerLauncher` | — | Write a Windows PowerShell 5.1-compatible host launcher next to a packaged dedicated server ([host launcher](#dedicated-server-host-launcher)) |

All mutating cmdlets support `-WhatIf` and `-Confirm`, except the Steam cmdlets (`Publish-OgSteamBuild`, `Invoke-OgUnrealPackage`, `Install-OgSteamCmd`); see [Steam publishing](#steam-publishing).

Use `Get-Help <Cmdlet> -Full` for parameter details and examples.

---

## Canonical workflow

```powershell
# Check tree state
oggitstatus | Format-Table -AutoSize

# If anything is behind origin/main
oggitsync

# Edit files anywhere in the tree...

# Stage everything
oggitadd

# Commit with automatic pin-advance cascade (deepest-first)
oggitcommit -Message "feat: my change"

# Push — always run manually; agents never push
oggitpush
```

`New-OgCommit` handles the cascade automatically: after committing a child repo it
stages the new pin in the immediate parent, so each repo in the tree gets exactly
one commit per `oggitcommit` call.

---

## Adding (and retiring) a repo on a feature branch

A new repo joins the tree as a submodule **on the feature branch**, so `main` never
references it until the feature merges. Example: `og-simulation-jolt` inside
og-simulation-ue, with every repo on `feat/jolt-scheduler`.

```powershell
# 1. On GitHub, create the repo WITH an initial commit (README or LICENSE), so 'main' exists.
#    oggitsubadd refuses a remote without 'main'.

# 2. Add it. The owner is the deepest repo containing the path (here og-simulation-ue);
#    the new submodule gets the owner's branch, created from its main.
oggitsubadd -Url https://github.com/og-framework/og-simulation-jolt.git `
            -Path Plugins/OGSimulation/Source/OGSimulationJolt/og-simulation-jolt

# 3. Commit (.gitmodules + gitlink in the owner, then the pin cascade) and push.
#    The new repo's branch is pushed first, with -u.
oggitcommit -Message "Add og-simulation-jolt submodule"
oggitpush

# Other clones: fetch, initialise the new submodule, and stay on the feature branch.
oggitsync -Branch feat/jolt-scheduler

# A fresh clone of the branch (the unreal scenario includes og-simulation-jolt):
New-OgCloneScenario -Scenario unreal -Target C:\dev\scratch -Branch feat/jolt-scheduler
```

Things that make this safe:

- `oggitadd` skips a directory that has its own `.git` but is not declared in that
  repo's `.gitmodules` (for example the new repo left on disk after checking out
  `main`), and warns. Otherwise git would stage it as an embedded gitlink with no
  `.gitmodules` entry.
- `New-OgFeatureBranch` can be re-run after a submodule joins: repos that already have
  the branch are skipped quietly. `-Repo <name-or-path>` targets one repo.
- `oggitmerge` initialises submodules that are new on `main` after the merge cascade.

**Retiring a repo.** On the feature branch alone, just do not merge it. If the
submodule ever reached `main`:

```powershell
# Refuses if the submodule (or anything nested in it) has uncommitted or unpushed work; -Force overrides.
oggitsubrm -Path Plugins/OGSimulation/Source/OGSimulationJolt/og-simulation-jolt
oggitcommit -Message "Retire og-simulation-jolt"
oggitpush
```

Then archive the GitHub repo (read-only). Do not delete it: pins in the branch history
must keep resolving.

---

## Reviewing changes with `oggitdiff`

`Show-OgDiff` (`oggitdiff`) opens what changed across the whole og tree (the project root and its
submodules, recursively) in the git-configured diff tool. By default each repo with a change opens as a
**directory diff of its changed files only**, and all of them land as **tabs of one Diffinity window**,
one tab per changed repo. Run it from the project root, or pass `-ProjectRoot <path>`.

```powershell
oggitdiff                               # working tree vs HEAD in every repo (untracked files included)
oggitdiff -Staged                       # the index vs HEAD: what you are about to commit
oggitdiff -Against origin/main          # HEAD vs its merge base with origin/main (<ref>...HEAD)
oggitdiff -Against origin/main -Fetch   # the same, after git fetch --recurse-submodules
oggitdiff -Commit 6245add               # what one oggitcommit run (root commit 6245add) changed, every repo
oggitdiff -Pick                         # pick that root commit from a list of the last 30 (or a range: see below)
oggitdiff -Pick -Count 50
oggitdiff -From 758fb77 -To 07414fb     # every repo between two root commits (two-dot: pin at A..pin at B)
oggitdiff -From 758fb77                 # the same up to HEAD
oggitdiff -From 758fb77 -IncludeWorkingTree   # root commit 758fb77 against the working tree, uncommitted work included
oggitdiff -PerFile                      # git difftool's per-file windows instead (with any mode above)
oggitdiff -Tool meld                    # another git-configured tool for this call
```

### Modes

| Mode | Base side | Head side |
|---|---|---|
| (default) | HEAD | the working tree, including untracked files that are not ignored (a repo with only a new file opens) |
| `-Staged` | HEAD | the index |
| `-Against <ref>` | `git merge-base <ref> HEAD`, never `<ref>`'s tip | HEAD |
| `-Commit <rev>` | each touched repo's old pin | its new pin |
| `-Pick [-Count <n>]` | as `-Commit` for a picked commit, as `-From` for a picked range (Space + Enter, `h`, `w`) | |
| `-From <A> [-To <B>]` | each repo's pin at `<A>` | its pin at `<B>` (default HEAD) |
| `-From <A> -IncludeWorkingTree` | each repo's pin at `<A>` | its working tree, including untracked files that are not ignored |

- **`-Against`** is the three-dot range on purpose: only what your branch added since the branch point, not
  what `<ref>` gained since. A repo where `<ref>` does not resolve is `no-ref` and skipped; one without a
  merge base is `failed`; the sweep goes on. `-Fetch` (only with `-Against`) runs
  `git fetch --recurse-submodules` from the project root first, which updates the remote-tracking refs
  (see [Read-only](#what-a-diff-contains) for the other exception, `-PerFile`).
- **`-Commit <rev>`**: `<rev>` names a commit in the project root (a sha, short sha, `HEAD`, ...). The root's
  own change is `<rev>^1..<rev>` (the first parent, so a merge commit works), shown only if it changed root
  files. Each submodule whose pin the commit moved is diffed from its old pin to its new pin, exactly those
  two gitlink ids (never its current HEAD), and nested submodules through the pin changes inside that range.
  Only the repos the commit touched get a result. The run is labelled `commit-<short sha>`.
- **`-From <A> [-To <B>]`**: a range between two root commits; both name commits in the project root and
  `-To` defaults to HEAD. Every repo either commit reaches through its submodule pins is paired by its
  og-tree path; each repo whose pin differs is diffed from its pin at `<A>` to its pin at `<B>` (nested pins
  read from their parent's *pinned* commit, never a current HEAD or tip). The root is `<A>..<B>`, shown only
  if root files differ. **Two-dot, never a merge base:** the two trees are compared as they are, so two
  unrelated commits (no common history) work like any other pair, and what `<B>` lacks of `<A>` shows as
  deleted. A repo pinned at the same commit at both ends gets no result; a submodule that only one end has
  gets an empty side (added / removed, as under `-Commit`); a pin missing locally is `missing-commit`. One
  cascade is the special case: `-From X^1 -To X` gives exactly the results of `-Commit X` (apart from `Commit`
  and the run folder). The run is labelled `range-<A short>-<B short>`. Two ends that name the same commit
  (e.g. `-From HEAD`, or `h` on the picker's top row) print one warning, `Nothing between <A short> and
  <B short>` (`... and HEAD` when `-To` is `HEAD` or left out), and open nothing.
- **`-From <A> -IncludeWorkingTree`** (instead of `-To`): root commit `<A>` against the working tree. Every
  repo of the tree as it is checked out now is compared from its pin at `<A>` to the files on disk: commits
  since `<A>`, staged and unstaged changes and untracked files, all at once. Every checked-out repo of the
  tree gets a result (`clean` when nothing differs), plus one per repo only `<A>` has, and the missing-commit
  exception below. A repo `<A>` does not contain has an empty base (every file added);
  a repo `<A>` pins that the tree no longer has is diffed to an empty head; a pin missing at `<A>` is
  `missing-commit`, and so is every repo below it (its pin at `<A>` is unknown; `Error` names the repo above
  it). A repo that is not checked out is skipped, as in the default mode, with one exception (a submodule
  whose parent keeps no git dir is `missing-commit`: see
  [Submodules that are not checked out](#what-a-diff-contains)). The run is labelled
  `range-<A short>-working`. `-To` and `-IncludeWorkingTree` together are a parameter-binding error.
- **`-PerFile`** keeps `git difftool --no-prompt` per repo (`--cached` for `-Staged`, `<ref>...HEAD` for
  `-Against`, `<old> <new>` per repo for `-Commit`, `<pin at A> <pin at B>` (or `<pin at A>` alone with
  `-IncludeWorkingTree`) for `-From`, and for `-Pick` as the command it stands for; `--tool=<Tool>` with
  `-Tool`): one window per changed file, temp files managed by git. See [-PerFile](#-perfile).
- **`-DirDiff`** is accepted and ignored: directory diffs are the default, and `git difftool --dir-diff` is
  never used (below).
- `-Staged`, `-Against`, `-Commit`, `-Pick` and `-From` are mutually exclusive. `-From` and `-To` take
  any revision that names a commit in the project root; an option-like value (a leading `-`) or one that
  names no commit is an error before anything is listed.

### Results

One `Og.DiffResult` per repo, in tree order: `Repo`, `Path`, `Action`, `Error`, `Ref`, `Range`, `BasePath`,
`HeadPath`, `Commit`, `BaseRev`, `HeadRev`, `FileCount`, `RunPath`. The default table shows `Repo`,
`Action`, `Files` (= `FileCount`, the number of changed files) and `Error`. With `-Commit` only the
touched repos are listed, with `-From -To` only the repos whose pin differs, with `-From -IncludeWorkingTree`
every checked-out repo of the tree (plus one per repo only `<A>` has, and the missing-commit exception in
[Modes](#modes)); `-Pick` lists what the command its choice stands for lists, and nothing when
cancelled. `Commit` is set only by `-Commit` and a single picked commit (a range has no one root commit;
`BaseRev`/`HeadRev` are each repo's two sides). `Get-Help Show-OgDiff -Full` has every field.

| Action | Meaning |
|---|---|
| `opened` | its changed files were exported and the directory diff launched (`-PerFile`: git difftool ran) |
| `clean` | nothing to show (`Files` 0), no tab |
| `failed` | the listing, export or launch failed, or no diff tool is configured; `Error` says why. `BasePath`/`HeadPath`/`RunPath` are set when the export worked, so you can open the folders by hand |
| `no-ref` | `-Against`: `<ref>` does not resolve in that repo |
| `missing-commit` | `-Commit`/`-Pick`/`-From`: a pin commit is not present locally (never fetched), or the submodule's objects are nowhere here (never initialised, or removed together with its git dir, as `oggitsubrm` does), or with `-From -IncludeWorkingTree` a repo below one whose pin at `<A>` is missing (its pin there is unknown). A warning, never fatal: the other repos still open |

### What a diff contains

- **Changed files only.** A modified file is on both sides, an added file on the head side only, a deleted
  file on the base side only; a rename is a delete plus an add, so both names appear.
- **Same line endings on both sides.** Every side read from git goes through git's own checkout conversion
  (`core.autocrlf`, `.gitattributes`), as the working tree did, so an unchanged CRLF file never shows as a
  difference. The working-tree side is copied byte for byte.
- **Submodules are tabs, never folders.** A submodule is never a folder or placeholder in its parent's diff:
  it is a repo of its own, with its own tab. Under `-Commit`, a submodule whose only change is moved pins of
  its own submodules has no changed file: it is `clean`, with no tab (its nested repos have their own
  results). Under `-PerFile` it is `opened`, because git difftool shows the moved pin itself.
- **Submodules that are not checked out** (the default mode, `-Staged`, `-Against`, and `-PerFile` with them):
  a submodule whose folder is missing, or is an empty folder that is not its own work tree (never
  initialised, e.g. after a clone without `--recurse-submodules`, or deinit-ed), is skipped with no result
  (`-Verbose` names an empty folder it skipped). git run in such a folder would reach the PARENT repo and
  diff it a second time. `-From -IncludeWorkingTree` skips it too, unless `<A>` pins it and its parent keeps
  no git dir for it: then its pin at `<A>` cannot be checked here and it is `missing-commit`. `-Commit` and
  `-From -To` read such a submodule's commits from the git dir its parent kept (next item).
- **Removed or deinit-ed submodules** (`-Commit`, `-From -To`): a submodule the commit (or the range)
  removed, or one without a work tree here, is still diffed, from the git dir its parent kept
  (`.git/modules/<name>`); a removed one's head side is empty, an added one's base side. Only when that git
  dir is gone too (after `oggitsubrm`, or never created in this clone) is it `missing-commit`.
- **Read-only, with two exceptions.** The directory diffs (every mode without `-PerFile`) never write to a
  repo: no index, ref or config change. Their listing and export run on a temporary copy of the index,
  because a plain `git diff` rewrites `.git/index` when files are only stat-dirty (measured, even with
  `GIT_OPTIONAL_LOCKS=0`). The exceptions: `-Fetch` updates the remote-tracking refs, and `-PerFile`'s
  `git difftool`, git's own interactive command, may refresh the index's stat information, as any
  `git diff` does.

### Run folders and retention

Every call that opens anything creates a new run folder:

```text
%TEMP%\og-diff\<yyyyMMdd-HHmmss>-<label>\<repo>\<side>
```

- `<label>`: `worktree`, `staged`, `against-<ref>`, `commit-<short sha>`, `range-<A short>-<B short>` or
  `range-<A short>-working`, made filesystem-safe
  (`origin/main` becomes `origin-main`) and cut to 24 characters. A second run in the same second gets
  `-2`, `-3`, ...
- `<repo>`: the repo's folder name, or its og-tree path made safe when two touched repos share a name.
- `<side>`: `<repo> base <sha7>`, `<repo> head <sha7>`, `<repo> working`, `<repo> index`, or
  `<repo> base empty` / `<repo> head empty` for an empty side, where `<repo>` is the repo folder name above.
  Diffinity titles a folder-diff tab from the two folder names only, so the repo is in each side's name and a
  tab reads e.g. `og-brawler base e289ac3 - og-brawler head db4ec6a`. The names contain spaces, which is fine
  as long as the difftool command quotes `"$LOCAL"` and `"$REMOTE"` (as the setup below does).
- `%TEMP%` is .NET's `GetTempPath()` (`%TMP%`, else `%TEMP%`).

Runs never overwrite each other, so the tabs of an earlier run that are still open keep their files.
**Retention:** the 10 newest runs are kept (by the timestamp in the name) and older ones are deleted after
each launch; the run just opened always survives. Only folders that are provably runs are ever deleted: the
name pattern above, holding only repo folders that hold nothing but side folders and their marker files,
with every side folder marked (below), and no junction or link anywhere in that shape. Everything else under
`og-diff` is left alone (a run with an unmarked side or a file you dropped into it is kept whole). In particular the
**legacy `og-diff\<repo>\{base,head}` folders** that `-Against -DirDiff` wrote before 1.6.0 are never
pruned (no timestamp, no marker): delete them once by hand.

```powershell
# List the legacy folders (no timestamp prefix); check them, then delete them yourself.
Get-ChildItem "$([System.IO.Path]::GetTempPath())og-diff" -Directory | Where-Object Name -notmatch '^\d{8}-\d{6}-'
```

**The `.og-diff-side` marker.** Every side folder has a small hidden marker file **beside** it in the repo
folder, named after it: `<side>.og-diff-side`, e.g.
`og-brawler\og-brawler base e289ac3.og-diff-side`. It exists because the export clears a side folder before
writing into it: a destination is cleared only if it is empty or carries its marker, so a wrong path can
never delete your files, and the retention prune requires it too. It sits beside the folder, not inside,
so the side folders hold nothing but the exported files and the diff never lists it.

**Older run folders** (made before this layout, with sides named `base-<sha7>`, `head-<sha7>`, `working`,
`index`, `empty`) carry the marker as a hidden `.og-diff-side` file *inside* each side folder. That form is
still accepted by the export and by the retention prune, so those runs still age out under retention like
any other.

### Diffinity setup and the single window

```powershell
git config --global diff.tool diffinity
git config --global difftool.diffinity.cmd '"C:/Program Files/Diffinity/Diffinity.exe" "$LOCAL" "$REMOTE"'
```

Turn on tabs in Diffinity. Each changed repo's launch is then a tab of the running window.

- **The configured command is the only command line.** `$LOCAL` and `$REMOTE` become the two side folders;
  `oggitdiff` never adds a tool flag, and in particular never `-forceNewInstance` (which would open a
  window per repo).
- The tool is resolved **once per call**, in the first changed repo: `-Tool`, else `diff.tool`, then
  `difftool.<tool>.cmd`. A repo-local difftool config in a later repo is not honoured in directory mode.
  With no tool configured, every changed repo is `failed` with a clear error, nothing is exported, and there
  is no fallback to `git difftool --dir-diff`.
- **Launch order.** The launches are sequential. If the tool is not running yet, `oggitdiff` waits after the
  first launch **up to 10 s** until the tool's process is up (so the first tab can take a moment), then
  launches the rest with a 300 ms pause before each, so they cannot race into separate windows. If the
  process does not appear in time, it warns and launches the rest anyway. When the tool is already running
  there is no wait, only the pauses.
- **A `cmd /c`-wrapped command defeats the wait.** The process looked for is the command line's first token.
  A command such as `cmd /c "...Diffinity.exe" "$LOCAL" "$REMOTE"` names `cmd`, which is always running, so
  the wait is skipped and the tabs may open in separate windows. Point the command at the tool's exe.

**Why never `git difftool --dir-diff`.** It copies the sides into a temp directory, launches the tool, and
deletes that directory the moment the tool's *process* exits. A single-instance tool (Diffinity included)
hands a new invocation to the running window and exits at once, so git deletes the files while the window
still shows them and the panes go empty. Hence the persistent run folders above.

### `-PerFile`

- The "is there a change?" check before git difftool is git's own `git diff --name-only` with the same
  arguments, run on a temporary copy of the index. Like git difftool, it compares the working tree with the
  **index** (not HEAD) and ignores untracked files: a repo whose only change is staged, or untracked, is
  `clean` and opens nothing (use the default mode, or `-Staged`). git difftool itself is git's interactive
  command and may refresh the index's stat information, as any `git diff` does.
- Under `-Commit` (and a single commit picked with `-Pick`) some repos have no per-file form and report
  `failed` with a hint to the directory mode (`oggitdiff -Commit <sha>`): a submodule the commit added or
  removed (an empty side), a root commit without a parent, and a repo without a work tree here (present only
  in its parent's `modules/`).
- Under `-From` (and a range picked with `-Pick`) each repo runs `git difftool --no-prompt <pin at A> <pin at B>`,
  or with `-IncludeWorkingTree` `git difftool --no-prompt <pin at A>` (its working tree against that commit:
  tracked files only, so an untracked file is not shown, unlike the directory mode). A repo only one end
  contains (an empty side) or without a work tree here reports `failed` with a hint to the directory mode
  (`oggitdiff -From <A> -To <B>` or `oggitdiff -From <A> -IncludeWorkingTree`).

### The commit picker (`-Pick`)

`oggitdiff -Pick` lists the project root's last `-Count` commits (default 30) on the first-parent line of
HEAD, newest first, one line each, then opens the picked one exactly as `oggitdiff -Commit <its sha>`, or a
picked range exactly as the `oggitdiff -From` command it stands for:

```text
> 6245add  2026-10-21 23:29  root +5       Split the game-agnostic half of ...
```

The columns are the short sha, the author date (local time), the repos the commit touched, and the subject.

| Key | Action |
|---|---|
| Up / Down, PgUp / PgDn, Home / End | move the selection |
| Space | mark the selected row as one end of a range (`*` after the selection marker); Space on the marked row clears the mark, on another row moves it (one mark at a time) |
| Enter | no mark: open the selected commit (`oggitdiff -Commit <sha>`); with a mark: open the range between the marked and the selected row, the **older** (lower) row as the base, whichever was marked first (`oggitdiff -From <older> -To <newer>`); on the marked row itself: nothing, the picker stays open |
| h | open the selected row to HEAD (`oggitdiff -From <sha> -To HEAD`) |
| w | open the selected row to the working tree, uncommitted and untracked work included (`oggitdiff -From <sha> -IncludeWorkingTree`) |
| Esc or q | cancel: nothing is opened and nothing is returned |

- While a row is marked, the header ends in `base: <short sha>`: the base **Enter** would use from the
  current selection (the older of the marked and the selected row; on the marked row, where Enter does
  nothing, the mark itself). `h` and `w` ignore the mark and always start at the selected row, so `base:`
  does not name their base.
- `h` on the top row (HEAD itself) compares HEAD with HEAD: a warning says there is nothing between them and
  nothing is opened.
- A picked range runs the `-From` path in full: its results, its run label (`range-<A short>-<B short>`, or
  `range-<A short>-working` for `w`) and `Commit` (`$null`) are those of the `-From` command.

The touched column:

| Text | Meaning |
|---|---|
| `root +5` | the root's own files and 5 more repos |
| `og-brawler +1` | no root files: the first touched submodule and 1 more |
| `root +2 (1 missing)` | 1 of the touched repos is `missing-commit` |
| `(no changes)` | an empty commit |
| `…` | not resolved yet |
| `!` | the commit cannot be resolved; the reason is on the detail line |

- Only the commits on screen are resolved, the selected one first and each at most once, so the list appears
  at once and fills in while you look (about 0.1–0.7 s per commit on og-brawler-unreal).
- The **detail line** under the list names every repo the selected commit touched, the root by its folder
  name, with its range (`0000000` for an empty side), e.g.
  `repos: og-brawler-unreal 758fb77..6245add, og-brawler e289ac3..db4ec6a, ...`, plus `(added)` or
  `(removed)`; a `missing-commit` repo shows as `<name> (missing-commit)`.
- A `!` row can still be picked: Enter then fails with the same error as `-Commit <its sha>` would. As an end
  of a range (a mark and Enter, `h` or `w`) it runs the `-From` path, which reads the pins of the two ends and
  never resolves that row's own cascade: the range may open, or fail with the error of the `-From` command
  it stands for.
- The picker draws on the console's **alternate screen** and restores the screen, cursor and colours in a
  `finally`, also after an error or Ctrl+C (which may only take effect at the next key press). The results
  of what you picked are written after that, on your normal screen.
- It needs an **interactive console**. With redirected input or output (a script, a pipe, CI) or a host
  without virtual-terminal support it fails before running any git command:
  `The commit picker needs an interactive console, but its input is redirected. Name the commit instead: oggitdiff -Commit <sha>`.
  A range is named with `oggitdiff -From <A> [-To <B> | -IncludeWorkingTree]`.
- `…` needs a console whose output encoding is UTF-8 (code page 65001); on an OEM code page such as 437 it
  shows as `?`. A subject with wide characters (CJK, emoji) may wrap, as the width counts UTF-16 units.
- `-PerFile` and `-Tool` apply to what you pick, as to the `-Commit` or `-From` command it stands for.
  `-Count` without `-Pick` makes PowerShell prompt for `-Pick`.

### Limits

- **Case-only paths.** Two changed paths that differ only in case (`A.txt` and `a.txt`) are one file on
  NTFS: in the export one overwrites the other.
- **`core.splitIndex=true`.** Refreshing the temporary index copy can write a new `sharedindex.*` file into
  `.git` (never the index itself). Split index is not git's default.
- **Long paths.** The run label is cut to 24 characters so ordinary runs stay well under 260 characters, and
  the export's git calls run with `-c core.longpaths=true` (on the command line, never written to a config),
  so a deep repo path under a run folder still exports. Whether the diff tool can open a path beyond 260
  characters is up to the tool.

---

## Pipeline composition examples

```powershell
# Find dirty repos
Get-OgRepoStatus | Where-Object Dirty | Format-Table Name, Path, Head

# Find repos with stale or non-canonical remote URLs
Get-OgRepoStatus | Where-Object { -not $_.RemoteOk } | Format-Table Name, Path

# Machine-readable snapshot
Get-OgRepoStatus | ConvertTo-Json -Depth 3

# Block on stale pins before starting a feature branch
$stale = Get-OgRepoStatus | Where-Object { $_.PinStatus -notin 'in-sync', 'n/a' }
if ($stale) { $stale | Format-Table Name, PinStatus; throw "Stale pins — sync first." }
New-OgFeatureBranch -Name "feat/my-feature"

# Show repos that are ahead of origin (have unpushed commits)
Get-OgRepoStatus | Where-Object { $_.Ahead -gt 0 } | Format-Table Name, Ahead, Head
```

---

## Note on `git push --recurse-submodules`

`Push-OgFramework` (`oggitpush`) does not use `git push --recurse-submodules=on-demand`,
which only descends one level. It walks the tree deepest-first and pushes each repo with
unpushed commits, stopping at the first failure, and uses `git push -u` for a branch that
origin does not have yet. If you prefer to manage push directly for a shallow tree, set
this git option globally and skip the alias:

```powershell
git config --global push.recurseSubmodules on-demand
git push   # now handles submodules automatically
```

---

## Operational model

The cascade is content-driven: og-tools walks `.gitmodules` recursively at runtime
to discover the repo tree. No project-specific config file is required. Each consumer
project (og-brawler-unreal, og-tests-cmake-runner) is supported out of the box as
long as its submodule layout is declared in `.gitmodules`.

The `New-OgCommit` pre-pass detects repos where a child was committed manually outside
og-tools (`PinStatus = parent-behind`) and stages the missing pin advance before
the main commit loop runs — so ad-hoc `git commit` calls in submodules do not break
the cascade.

---

## Local playtest

Build the Editor target, then start a dedicated server and rendered clients as standalone `-game` processes (the shape of
multi-process PIE, without the editor UI). Run both from the project root, or pass `-ProjectFile`.

```powershell
ogbuild                                   # <Project>Editor Win64 Development (refuses while UnrealEditor runs)
ogbuild -Target Editor, OGSimulationTests # several targets, in order; stops at the first failure

ogplaytest                                # server + 2 clients, PIE's packet emulation, logs in Saved\Playtest\<timestamp>
ogplaytest -Clients 3 -Tag gate14         # three clients, logs in Saved\Playtest\gate14
ogplaytest -Join                          # one more client joins the running server (logs into the newest session as the next clientN.log)
ogplaytest -Join -Clients 2 -Address 192.168.1.20 -Port 7777
ogplaytest -NoEmulation -Trace -LogLevels @{ LogOGNet = 'Verbose'; LogOGSim = 'Log' }
```

- The server loads the project's `GameDefaultMap` (`Config\DefaultEngine.ini`) unless `-Map` is given, and listens on `-Port` (default 17900).
- `-NoEmulation` turns off the packet lag/loss profile (outgoing 15–50 ms / 1 %, incoming 15–50 ms / 2 %); `-Trace` records an Unreal
  Insights trace of the server; `-LogLevels` sets `[Core.Log]` verbosities on every process; `-ExtraArgs`, `-ServerArgs` and
  `-ClientArgs` pass anything else.
- A new session refuses to start while an `UnrealEditor` process runs (`-Force` overrides); `-Join` does not, since the server is one.
- To leave mid-match, close a client window; to rejoin, `ogplaytest -Join`. Close the clients before the server.

---

## Steam publishing

Packages an Unreal project with UAT and uploads it to Steam through SteamPipe, driven by
one config file per project. The game itself needs **no Steam SDK** for this pipeline:
steamcmd uploads files, it does not link into the game.

### Prerequisites

- A Windows Unreal Engine install or source build; `EngineRoot` may be left empty when
  the `.uproject` `EngineAssociation` is registered (a source-build GUID in HKCU or a
  launcher version in HKLM).
- A Steamworks app with depots, and a builder Steam account allowed to publish it. None of
  this is needed for `-NoUpload`.
- steamcmd: run `Install-OgSteamCmd` once, or point `$env:OG_STEAMCMD` / `-SteamCmdPath`
  at an existing `steamcmd.exe`.
- No running `UnrealEditor` while packaging.

### Config schema (`.psd1`, schema version 2)

Relative paths resolve against the config file's own folder. Unknown keys are rejected at every
level, and every error names the key. Version 2 separates **what is packaged** (`Builds`) from
**where it goes** (the depots of each app), so one packaged build can feed several depots, for
example a dedicated server shipped both inside the game and as its own tool app.

```powershell
@{
    SchemaVersion  = 2
    ProjectFile    = '..\..\MyGame.uproject'   # must exist
    EngineRoot     = ''            # optional; '' => resolve from the .uproject EngineAssociation
    Platform       = 'Win64'       # only 'Win64'
    BuilderAccount = ''            # Steam login name; '' allowed except when uploading
    Branch         = ''            # beta branch to SetLive; '' => no SetLive; 'default' is always rejected
    OutputRoot     = '..\..\Saved\Steam\Builds'
    KeepLast       = 3             # build folders kept in OutputRoot; >= 1
    Builds = @(                    # what is packaged; each build at most once per publish
        @{
            Name               = 'client'              # unique; [a-z0-9-]+
            TargetType         = 'Client'              # Client | Server | Game
            Configuration      = 'Shipping'            # Development | Shipping
            ExpectedExecutable = 'MyGameClient.exe'    # relative to the build ContentRoot
            FileExclusions     = @('*.pdb', 'Manifest_*.txt')
            ExtraFiles         = @()                   # @(@{ Source = 'rel\to\config'; Destination = 'rel\to\ContentRoot' })
        }
        @{
            Name               = 'server'
            TargetType         = 'Server'
            Configuration      = 'Shipping'
            ExpectedExecutable = 'MyGameServer.exe'
            FileExclusions     = @('*.pdb', 'Manifest_*.txt', 'HostLogs\*', 'join_info.txt')
            # ServerLauncher   = @{ ... }              # optional, Server/Game builds; see "Dedicated-server host launcher"
        }
    )
    Apps = @(                      # where it goes
        @{
            Name   = 'game'
            AppId  = 0             # 0 = placeholder; allowed only when the app is not uploaded
            Depots = @(
                @{ Name = 'game-client'; DepotId = 0; Build = 'client' }                         # DepotId 0 = placeholder, as AppId
                @{ Name = 'game-server'; DepotId = 0; Build = 'server'; DepotPath = 'Server' }   # lands in <install>\Server
            )
        }
        @{
            Name   = 'server-tool'
            AppId  = 0
            Depots = @( @{ Name = 'tool-server'; DepotId = 0; Build = 'server' } )
        }
    )
    Profiles = @{                  # optional; named depot sets for -Profile
        Default         = 'playtest'                   # required when Profiles is present
        'playtest'      = @('game-client', 'game-server')
        'playtest-tool' = @('game-client', 'game-server', 'tool-server')
    }
}
```

- **Builds**: `Name`, `TargetType` and `Configuration` are required. A build no depot uses only gives
  a warning.
- **Depots**: `Name` is `[a-z0-9-]+` and unique across all apps; `Build` names a build of the file.
  `DepotPath` (default `.`) is the folder inside the app install that the build lands in: relative,
  with no `..` segment, no wildcard and no character a folder name cannot hold. `\` and `/` are both
  accepted and written as `\`.
- **Profiles**: every key but `Default` is a profile name (`[a-z0-9-]+`) listing one or more depots.
  A key with a `-` must be quoted in a `.psd1` (`'playtest-tool' = ...`); a bare `playtest-tool`
  does not parse. Without `Profiles` a publish selects every depot.
- References to builds and depots match case-insensitively.

**Schema version 1** is still accepted, with unchanged behaviour: there are no `Builds`, every
depot carries the build keys itself (`TargetType`, `Configuration`, `ExpectedExecutable`,
`FileExclusions`, `ExtraFiles`, `ServerLauncher`), and each depot becomes an implicit build named
after it, with `DepotPath` `.`. `Builds`, `Profiles` and `DepotPath` are unknown keys in version 1;
`-Depots` works on version 1 files too.

```powershell
@{
    SchemaVersion = 1
    # ProjectFile, EngineRoot, Platform, BuilderAccount, Branch, OutputRoot, KeepLast as above
    Apps = @(
        @{
            Name   = 'game'
            AppId  = 0
            Depots = @(
                @{
                    Name               = 'game-win64'
                    DepotId            = 0
                    TargetType         = 'Client'
                    Configuration      = 'Shipping'
                    ExpectedExecutable = 'MyGameClient.exe'
                    FileExclusions     = @('*.pdb', 'Manifest_*.txt')
                    ExtraFiles         = @()
                }
            )
        }
    )
}
```

### Choosing destinations per upload

One build feeds every destination of a run: `Publish-OgSteamBuild` packages each build the
selected depots need **exactly once**, and every selected depot of every app gets the same build
label. The selection is:

| Passed | Selected depots |
|---|---|
| `-Depots <name>[, <name>...]` | exactly those |
| `-Profile <name>` | the depots of that profile |
| neither | `Profiles.Default`, or every depot when the config has no `Profiles` |

`-Profile` and `-Depots` cannot be combined. An unknown profile or depot name is an error that
lists the valid names. Only the apps with a selected depot get an app VDF and a steamcmd run.

**Partial-app guard (S6).** If an app has a selected depot, all of its configured depots must be
selected, otherwise the publish stops before git and packaging, naming the depots it leaves out.
What Steam does with a depot that an app build leaves out is not documented: its previous build
could stay installed next to the new one, e.g. an old server with a mismatching build label.
`-AllowPartialApp` uploads anyway. The guard also applies to `-NoUpload` and `-Preview`, so a dry
run shows it.

Shared depots (one depot listed in two apps by Steam) are not an option while the owning app is
unreleased: Steam refuses to share a depot from an unreleased application. Listing the same build
under two apps, as `server` above, uploads it once per app instead.

### Cmdlets

| Cmdlet | Purpose |
|---|---|
| `Publish-OgSteamBuild` (`ogsteampublish`) | The pipeline: validate config → select depots (`-Profile`, `-Depots`) → partial-app guard → check git → package each selected build once → write `build_info.txt` into each build → write VDFs → steamcmd upload per selected app → prune old builds. |
| `Invoke-OgUnrealPackage` | One UAT BuildCookRun (build, cook, stage, package, pak, archive) for a Win64 Client, Server or Game target. |
| `Install-OgSteamCmd` | Downloads Valve's `steamcmd.zip` and runs it once so it self-updates. Idempotent unless `-Force`. |
| `New-OgDedicatedServerLauncher` | Writes the host launcher below into a folder; `Publish-OgSteamBuild` calls it for every depot with a `ServerLauncher` key. |
| `Import-OgSteamConfig` (private) | Loads and validates the config above. |
| `New-OgSteamBuildVdf` (private) | Writes the `app_build_<AppId>.vdf` and `depot_build_<DepotId>.vdf` files. |

Build layout: `<OutputRoot>\<label>\<BuildName>\` holds each packaged build (for a version 1
config, the depot name) and `<OutputRoot>\<label>\_steam\<AppName>\` each selected app's VDFs;
steamcmd logs go to `<OutputRoot>\<label>\_steam\output\`. The label is `yyyyMMdd-HHmmss-<sha7>`,
with `-dirty` appended for an `-AllowDirty` build. `-SkipPackage -BuildLabel <label>` reuses the
`<label>\<BuildName>\` folders the selection needs, so one cook can be published to other
destinations later.

Each depot VDF maps its build's ContentRoot to the depot's `DepotPath`
(`"LocalPath" "*"`, `"DepotPath" "Server"`, `"recursive" "1"`) with the build's `FileExclusions`.
In a dry run where several depots of one app still have the placeholder DepotId `0`, their depot
VDFs are named `depot_build_0_<DepotName>.vdf` so they do not overwrite each other; an upload never
gets that far with a placeholder.

Every build ContentRoot gets a generated `build_info.txt` (also with `-SkipPackage`), so the
shipped build can identify itself: UTF-8 without BOM, LF, the lines `label=<label>`, `sha=<sha7>`,
`dirty=true|false` and `created=<yyyy-MM-ddTHH:mm:ssZ>` (UTC time of the publish run). A
`FileExclusions` pattern that matches it, or an `ExtraFiles` entry that targets it, is rejected.

`FileExclusions` are SteamPipe `FileExclusion` patterns. Each one is a path relative to the depot
ContentRoot, matched case-insensitively. Only `*` and `?` are wildcards, and `*` also spans folders:
`*.pdb` drops a `.pdb` in any folder, and `HostLogs\*` drops everything below `HostLogs`. Use them
to keep out files that running the build in place writes into the ContentRoot, such as
`HostLogs\*` or `<Project>\Saved\*`. Each result depot reports two sizes:

- `SizeBytes`: the whole ContentRoot.
- `UploadBytes`: what the depot VDF hands to steamcmd, i.e. the ContentRoot without the files its
  build's `FileExclusions` match.

The result also has `Profile` (the profile whose depots were selected, or `''`), `Depots` (one entry
per selected depot: `Name`, `AppName`, `Build`, `DepotPath`, `ContentRoot`, `BuildInfoPath`,
`ServerLauncher`, `SizeBytes`, `UploadBytes`; depots of one build share its values) and
`Destinations` (one entry per selected depot: `App`, `Depot`, `Build`, `DepotPath`, `UploadBytes`).

```powershell
Install-OgSteamCmd
Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -NoUpload     # default profile, no Steam
Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -Preview      # Steam-side dry run
Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -Branch beta  # upload, set live on 'beta'
Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -Profile playtest-tool  # another depot set
Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -Depots game-client -AllowPartialApp  # one depot of 'game'
Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -SkipPackage -BuildLabel <label> -Profile playtest-tool  # reuse a build
```

steamcmd runs attached to the console, so on the first login it asks for the password and
the Steam Guard code itself; steamcmd caches the login afterwards. og-tools never stores or
passes credentials.

### Dedicated-server host launcher

A build (version 1: a depot) with a `ServerLauncher` key (TargetType `Server` or `Game`,
`ExpectedExecutable` set) gets four generated files in its ContentRoot, also with `-SkipPackage`:

| File | Purpose |
|---|---|
| `Host Local Playtest.bat` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File host_server.ps1 -Mode Local` |
| `Host Online Playtest.bat` | the same with `-Mode Online` |
| `host_server.ps1` | the host script: Windows PowerShell 5.1 and PowerShell 7, no modules, so host PCs need neither og-tools nor PowerShell 7 |
| `host_server.settings.psd1` | the values below, read by the script |

```powershell
ServerLauncher = @{
    Title            = 'MyGame server'        # required; console title, firewall rule and UPnP name; no double quote
    Port             = 7777                   # required; UDP port
    JoinLinePattern  = 'Session: (?:(?<joined>joined)|(?<left>left)) players=(?<players>\d+) tested=(?<tested>\d+)'  # required
    ServerArguments  = '/Game/Maps/Arena'     # optional; put before -port=<Port> -log -abslog=<log>
    ReadyLinePattern = ''                     # optional; the log line that shows the server listens
    ClientLaunch     = @('..\MyGameClient.exe', 'steam://rungameid/{AppId:game}')  # optional; one entry or fallbacks, see below
    LocalHint        = ''                     # optional; extra line printed after the game is offered
}
```

`JoinLinePattern` is matched against every server log line and must define the named groups
**`joined`** and **`left`** (exactly one of them matches a line) and **`players`** (the player
count after the event). **`tested`** (the tested session size) and `local` are optional. A match
prints `Player joined (2/3)`, `Player left (1/3)` or, above the tested size,
`Player joined (4 players - above the tested 3, expect degraded performance)`; nobody is ever
refused.

`ClientLaunch` is one string or a list of fallbacks; each entry is a URI or a path relative to the
server's ContentRoot (an absolute path is rejected). `{AppId:<app name>}` is filled from the
config per entry; a token whose app still has the AppId `0` stays in the settings file and makes
that entry unusable. When the game is offered, the **first usable entry** in list order wins: a
path that exists, or a URI without a placeholder token. If none is usable, the launcher says why
(each missing path, each placeholder app) and asks the host to start the game themselves; with no
entry it only prints the hint. That lets one server package work in both places:
`'..\MyGameClient.exe'` finds the client when the server is installed in the game's `Server\`
folder (`DepotPath = 'Server'`), and `'steam://rungameid/{AppId:game}'` starts it through Steam
when the server is installed as its own tool app.

What the script does, in order:

1. **Firewall:** an inbound rule on the UDP port for the program that listens: the staged
   `<Project>\Binaries\Win64\<exe name>[-Win64-<Config>].exe` when the server exe is Unreal's root
   launcher stub, else the server exe itself. One UAC prompt; skipped when the rule exists.
   A declined prompt only prints a warning.
2. **Router (Online only):** a UPnP mapping via `HNetCfg.NATUPnP`. When UPnP is unavailable or
   fails, it prints how to forward the port by hand and carries on.
3. **Public IP (Online only):** from HTTPS lookup services, with fallbacks, plus the router's
   external IP. When they differ, or the router's IP is in `100.64.0.0/10`, it warns about
   carrier-grade NAT and lists alternatives.
4. **Join address:** printed in a box (internet first in Online mode, otherwise LAN), copied to
   the clipboard and written to `join_info.txt`. The this-PC (`127.0.0.1`) and LAN addresses are
   listed too.
5. **Server:** started with `-port=<Port> -log -abslog=HostLogs\server-<time>.log`. The script
   tails that log and prints the friendly join/leave lines.
6. **Cleanup:** on exit or Ctrl+C it stops the server and removes the UPnP mapping. Closing the
   window instead leaves the mapping in place; the next run reuses it and then removes it.
7. **Game:** once `ReadyLinePattern` matches (or straight away when it is empty), it picks the
   first usable `ClientLaunch` entry, asks `Start the game on this PC now? [Y/n]` and starts it.

Local mode runs steps 1, 4, 5 and 7 only, and makes no router or internet call.

### Safety invariants

- **S1** The branch `default` (any case) is rejected at config load, for `-Branch` and in the VDF writer; the default branch is set live only in the Steamworks web UI.
- **S2** AppId/DepotId `0` of a selected depot or of its app, and an empty `BuilderAccount`, are rejected whenever an upload would happen, before any packaging. An app with no selected depot may keep the placeholder. A real ID used twice anywhere in the config is rejected too.
- **S3** A git tree with uncommitted changes (or a `-dirty` label with `-SkipPackage`) is refused unless `-AllowDirty`.
- **S4** steamcmd only ever gets `+login <BuilderAccount> +run_app_build <vdf> +quit`; never a password.
- **S5** Packaging refuses to start while an `UnrealEditor` process is running.
- **S6** An app is uploaded with all of its depots or not at all, unless `-AllowPartialApp`; checked before git and packaging, also for `-NoUpload` and `-Preview`.

The Steam cmdlets do not support `-WhatIf`; use `-NoUpload` or `-Preview` for a dry run.

---

## License templates

`Public/license-templates/` contains reusable license templates for og-framework repos:

| File | Purpose |
|---|---|
| `LICENSE-BUSL.template` | BUSL-1.1 template with approved Licensor and Additional Use Grant pre-filled. `{{LICENSED_WORK}}` and `{{CHANGE_DATE}}` are left as placeholders for per-repo substitution at release time. |
| `LICENSE-MPL.template` | Verbatim MPL-2.0 text (no placeholders). Use as-is for MPL-only repos or as the `LICENSE-MPL` companion file in mixed-license repos. |

To render a BUSL template for a specific repo, substitute `{{LICENSED_WORK}}` with the repo/product name and `{{CHANGE_DATE}}` with the release date plus 4 years (YYYY-MM-DD). Use `Update-LicenseChangeDate` for automated date stamping.

---

## License-change-date stamping

`Update-LicenseChangeDate` (`oglicstamp`) stamps the BSL Change Date in a repo's
`LICENSE` file based on the release date. Run this at release time to stamp the BSL
Change Date based on the release date. Default is +4 years per og-framework policy.

It locates either the `{{CHANGE_DATE}}` placeholder (pre-release template state) or
an existing `Change Date:` line (already-stamped state from a previous release) and
replaces it with the computed or explicit date formatted `YYYY-MM-DD`.

### Examples

**Default: +4 years from release date**

```powershell
# Stamps Change Date as 2030-06-01
Update-LicenseChangeDate -Path C:\dev\og-brawler -ReleaseDate 2026-06-01
```

**Custom conversion window**

```powershell
# Stamps Change Date as 2027-06-01 (+1 year early liberation)
Update-LicenseChangeDate -Path C:\dev\og-brawler -ReleaseDate 2026-06-01 -YearsFromRelease 1
```

**Absolute date override**

```powershell
# Stamps Change Date as 2029-01-15 regardless of YearsFromRelease
# Use when aligning multiple repos to a contractual date
Update-LicenseChangeDate -Path C:\dev\og-brawler -ReleaseDate 2026-06-01 -ChangeDate 2029-01-15
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Path` | Yes | — | Repo root containing the BSL `LICENSE` file |
| `-ReleaseDate` | Yes | — | Date this release ships; base for the Change Date calculation |
| `-YearsFromRelease` | No | `4` | Years to add to `-ReleaseDate`. Must be >= 0. |
| `-ChangeDate` | No | — | Absolute override; takes precedence over `-YearsFromRelease` |

### Output

Returns a `PSCustomObject` with: `Path`, `OldChangeDate`, `NewChangeDate`, `Action`.

`Action` values: `placeholder-substituted`, `date-overwritten`, `skipped-not-bsl`.

If the LICENSE file does not appear to be a BSL file, the cmdlet emits a warning and
returns `Action: 'skipped-not-bsl'` without modifying anything.

If `-ChangeDate` is more than 4 years after `-ReleaseDate`, a warning is emitted
(BSL §43-47 caps the effective date at the 4-year anniversary regardless), but the
file is still written — the user may have a reason for a later documentation date.

---

## License and contributing

MPL-2.0. Inbound = outbound.

See [CONTRIBUTING.md](https://github.com/og-framework/og-brawler-unreal/blob/main/CONTRIBUTING.md) for the decision tree on where to make your change.
