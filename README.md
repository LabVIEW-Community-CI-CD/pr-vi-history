# pr-vi-history

Reusable GitHub workflow that treats pull requests as the VI history analysis surface.

## What this repository provides

- `.github/workflows/pr-vi-history.yml` (reusable workflow)
- Local `tools/*` scripts required to generate manifest, run history compare,
  and render PR summaries.

## Downstream usage

```yaml
name: PR VI History Analysis

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review, labeled]
    paths:
      - '**/*.vi'

permissions:
  contents: read
  pull-requests: write

jobs:
  vi-history:
    if: ${{ !github.event.pull_request.draft }}
    uses: LabVIEW-Community-CI-CD/pr-vi-history/.github/workflows/pr-vi-history.yml@<sha>
    with:
      pr_number: ${{ github.event.pull_request.number }}
      fetch_depth: '20'
      max_pairs: '6'
      compare_modes: 'default,attributes'
      include_merge_parents: false
      windows_runner: windows-2022
      windows_image: nationalinstruments/labview:2026q1-windows
      linux_runner: ubuntu-latest
      linux_image: nationalinstruments/labview:latest-linux
      enable_linux_smoke: true
      upload_artifact: true
      post_comment: true
    secrets: inherit
```

## Reusable workflow inputs

- `windows_image` (string, default `nationalinstruments/labview:2026q1-windows`)
- `linux_image` (string, default `nationalinstruments/labview:latest-linux`)
- `windows_runner` (string, default `windows-2022`)
- `linux_runner` (string, default `ubuntu-latest`)
- `enable_linux_smoke` (boolean, default `true`)

## Reusable workflow outputs

- Existing outputs remain unchanged:
  - `summary_path`, `results_root`, `manifest_path`, `pair_count`,
    `target_count`, `completed_count`, `diff_count`, `markdown_path`,
    `artifact_name`
- Additive lane-status outputs:
  - `windows_lane_status`
  - `linux_lane_status`

## Notes

- The workflow is self-contained and executes from this repository only.
- The compare lane is hosted Windows runner + NI windows container.
- The linux smoke lane is hosted Ubuntu + NI linux container and is
  informational (soft-gated).
- For stabilization, prefer SHA-pinned reusable references in callers, then
  promote to `@v1` after evidence gates.

## Local fast loop (required before push)

Use Docker Desktop as the default local gate before pushing:

```powershell
pwsh -NoLogo -NoProfile -File ./tools/Test-DockerDesktopFastLoop.ps1
```

This gate:

- auto-switches Docker Desktop between Windows and Linux engines
- validates image digest lock alignment against `toolchain-lock.json`
- runs probe + deterministic smoke compare in both lanes
- writes `pr-vi-history-docker-fast-loop@v1` summary under
  `tests/results/local-parity/`

Enable pre-push enforcement once per clone:

```powershell
pwsh -NoLogo -NoProfile -File ./Enable-GitHooks.ps1
```

Optional waiver format (for known temporary issues):

- `lane:signature:reference`
- lanes: `windows-smoke`, `linux-smoke`, `windows-strict`, `linux-strict`,
  `drift`

Example:

```powershell
$env:PRVI_FAST_LOOP_WAIVERS='linux-smoke:exit-139:#1234'
git push
```

Refresh lock digests intentionally (do not auto-update during gate):

```powershell
pwsh -NoLogo -NoProfile -File ./tools/Refresh-ToolchainLockDigests.ps1
```
