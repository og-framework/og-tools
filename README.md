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

All mutating cmdlets support `-WhatIf` and `-Confirm`.

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
