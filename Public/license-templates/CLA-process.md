<!-- SPDX-License-Identifier: MPL-2.0 -->
# CLA Process

This document describes how contributors sign the Individual Contributor License Agreement (CLA) for projects maintained by the Licensor, and what happens if a contributor refuses.

---

## Tooling: CLAassistant GitHub App

Signing is handled automatically by the [CLAassistant GitHub App](https://github.com/cla-assistant/cla-assistant).

CLAassistant is configured per-repository. When installed, it monitors all incoming pull requests and checks whether the PR author (and any co-authors) have previously signed the CLA. The CLA text it presents is `CLA-Individual.md.template` rendered for the target repository.

---

## Signing Flow

1. A contributor opens a pull request against a protected repository.
2. CLAassistant automatically checks whether the contributor's GitHub account is linked to a prior signed CLA.
3. If no signed CLA is on record, CLAassistant posts a comment on the PR with a link to the CLA signing page.
4. The contributor reads `CLA-Individual.md.template` and signs electronically by following the CLAassistant link and authenticating with their GitHub account.
5. CLAassistant records the signed agreement and updates the PR status check to "passed."
6. The PR can now be reviewed and merged normally.

If a PR has multiple authors (via `Co-Authored-By` trailer), **each author** must have a signed CLA on record before the status check passes.

---

## Where Signed CLAs Are Archived

CLAassistant stores all signed agreements in a designated GitHub Gist or repository (configured at installation time). The storage location is set when CLAassistant is installed on the organization. Refer to the CLAassistant documentation for retrieval procedures.

The Licensor does not store signed CLAs separately — CLAassistant is the authoritative record.

---

## What Happens If a Contributor Refuses

If a contributor refuses to sign the CLA:

- The CLAassistant status check on their PR remains **failed/blocked**.
- The PR **cannot be merged** into any protected branch while the check is failing.
- The Licensor will not merge the contribution under any circumstance without a signed CLA on record, because doing so would create ambiguity about the relicensing rights needed for future license changes (see Section 4 of the CLA).
- The contributor's PR will remain open but unmerged until either (a) the contributor signs, or (b) the PR is closed by the contributor or a maintainer.

There is no exception path for unsigned contributions, regardless of the size of the change.

---

## When CLAassistant Gets Installed

CLAassistant is **not** installed as part of the `OGBrawlerConvertToBSL` initiative. It will be installed at the time of first public release of each repository, as documented in `docs/public-release-runbook.md`.

Until repositories are made public and CLAassistant is configured, the CLA process is not yet active. All current changes are made by the sole author (Licensor) and do not require a CLA.

---

## Reference

- CLAassistant GitHub App: https://github.com/cla-assistant/cla-assistant
- CLA text: `CLA-Individual.md.template` (in this directory)
