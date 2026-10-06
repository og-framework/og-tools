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
| `Sync-OgFramework` | `oggitsync` | Fetch + ff-merge cascade deepest-first |
| `Add-OgChange` | `oggitadd` | Stage changes across the tree |
| `New-OgCommit` | `oggitcommit` | Commit + auto pin-advance cascade |
| `Push-OgFramework` | `oggitpush` | Push with `--recurse-submodules=on-demand` |
| `Update-LicenseChangeDate` | `oglicstamp` | Stamp BSL Change Date at release time |
| `Update-OgLibPin` | — | Niche: pin a submodule to a specific historical SHA |
| `New-OgFeatureBranch` | — | Cross-repo branch creation |
| `New-OgCloneScenario` | — | Scenario clone (simulation/brawler/unreal/cmake-runner) |
| `Test-OgPinConsistency` | — | CI validation; sets exit code 0/1 |
| `Publish-OgSteamBuild` | `ogsteampublish` | Package every depot, write SteamPipe VDFs, upload with steamcmd ([Steam publishing](#steam-publishing)) |
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

`Push-OgFramework` (`oggitpush`) is a thin wrapper around
`git push --recurse-submodules=on-demand`. If you prefer to manage push directly,
set this git option globally and skip the alias:

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

### Config schema (`.psd1`, schema version 1)

Relative paths resolve against the config file's own folder. Unknown keys are rejected.

```powershell
@{
    SchemaVersion  = 1
    ProjectFile    = '..\..\MyGame.uproject'   # must exist
    EngineRoot     = ''            # optional; '' => resolve from the .uproject EngineAssociation
    Platform       = 'Win64'       # only 'Win64'
    BuilderAccount = ''            # Steam login name; '' allowed except when uploading
    Branch         = ''            # beta branch to SetLive; '' => no SetLive; 'default' is always rejected
    OutputRoot     = '..\..\Saved\Steam\Builds'
    KeepLast       = 3             # build folders kept in OutputRoot; >= 1
    Apps = @(
        @{
            Name   = 'game'
            AppId  = 0             # 0 = placeholder; allowed only with -NoUpload
            Depots = @(
                @{
                    Name               = 'game-win64'          # unique across the file; [a-z0-9-]+
                    DepotId            = 0                     # 0 = placeholder, same rule as AppId
                    TargetType         = 'Client'              # Client | Server | Game
                    Configuration      = 'Shipping'            # Development | Shipping
                    ExpectedExecutable = 'MyGameClient.exe'    # relative to the depot ContentRoot
                    FileExclusions     = @('*.pdb', 'Manifest_*.txt')
                    ExtraFiles         = @()                   # @(@{ Source = 'rel\to\config'; Destination = 'rel\to\ContentRoot' })
                    # ServerLauncher   = @{ ... }              # optional, Server/Game depots; see "Dedicated-server host launcher"
                }
            )
        }
    )
}
```

### Cmdlets

| Cmdlet | Purpose |
|---|---|
| `Publish-OgSteamBuild` (`ogsteampublish`) | The pipeline: validate config → check git → package each depot → write `build_info.txt` into each depot → write VDFs → steamcmd upload per app → prune old builds. |
| `Invoke-OgUnrealPackage` | One UAT BuildCookRun (build, cook, stage, package, pak, archive) for a Win64 Client, Server or Game target. |
| `Install-OgSteamCmd` | Downloads Valve's `steamcmd.zip` and runs it once so it self-updates. Idempotent unless `-Force`. |
| `New-OgDedicatedServerLauncher` | Writes the host launcher below into a folder; `Publish-OgSteamBuild` calls it for every depot with a `ServerLauncher` key. |
| `Import-OgSteamConfig` (private) | Loads and validates the config above. |
| `New-OgSteamBuildVdf` (private) | Writes the `app_build_<AppId>.vdf` and `depot_build_<DepotId>.vdf` files. |

Build layout: `<OutputRoot>\<label>\<DepotName>\` holds each packaged depot and
`<OutputRoot>\<label>\_steam\<AppName>\` its VDFs; steamcmd logs go to
`<OutputRoot>\<label>\_steam\output\`. The label is `yyyyMMdd-HHmmss-<sha7>`, with
`-dirty` appended for an `-AllowDirty` build.

Every depot ContentRoot gets a generated `build_info.txt` (also with `-SkipPackage`), so the
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
  `FileExclusions` match.

```powershell
Install-OgSteamCmd
Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -NoUpload     # local check, no Steam
Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -Preview      # Steam-side dry run
Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -Branch beta  # upload, set live on 'beta'
Publish-OgSteamBuild -ConfigPath .\tools\steam\steam-publish.psd1 -SkipPackage -BuildLabel <label>  # reuse a build
```

steamcmd runs attached to the console, so on the first login it asks for the password and
the Steam Guard code itself; steamcmd caches the login afterwards. og-tools never stores or
passes credentials.

### Dedicated-server host launcher

A depot with a `ServerLauncher` key (TargetType `Server` or `Game`, `ExpectedExecutable` set)
gets four generated files in its ContentRoot, also with `-SkipPackage`:

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
    ClientLaunch     = 'steam://rungameid/{AppId:game}'  # optional; a URI or a path relative to the ContentRoot
    LocalHint        = ''                     # optional; extra line printed after the game is offered
}
```

`JoinLinePattern` is matched against every server log line and must define the named groups
**`joined`** and **`left`** (exactly one of them matches a line) and **`players`** (the player
count after the event). **`tested`** (the tested session size) and `local` are optional. A match
prints `Player joined (2/3)`, `Player left (1/3)` or, above the tested size,
`Player joined (4 players - above the tested 3, expect degraded performance)`; nobody is ever
refused. `{AppId:<app name>}` in `ClientLaunch` is filled from the config; an AppId of `0`
(placeholder) makes the launcher say it cannot start the game instead.

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
7. **Game:** once `ReadyLinePattern` matches (or straight away when it is empty), it asks
   `Start the game on this PC now? [Y/n]` and runs `ClientLaunch`.

Local mode runs steps 1, 4, 5 and 7 only, and makes no router or internet call.

### Safety invariants

- **S1** The branch `default` (any case) is rejected at config load, for `-Branch` and in the VDF writer; the default branch is set live only in the Steamworks web UI.
- **S2** AppId/DepotId `0` and an empty `BuilderAccount` are rejected whenever an upload would happen, before any packaging.
- **S3** A git tree with uncommitted changes (or a `-dirty` label with `-SkipPackage`) is refused unless `-AllowDirty`.
- **S4** steamcmd only ever gets `+login <BuilderAccount> +run_app_build <vdf> +quit`; never a password.
- **S5** Packaging refuses to start while an `UnrealEditor` process is running.

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
