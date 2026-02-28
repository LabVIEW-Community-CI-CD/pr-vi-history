# pr-vi-history

Reusable GitHub workflow that treats pull requests as the VI history analysis surface.

## What this repository provides

- `.github/workflows/pr-vi-history.yml` (reusable workflow)
- Pass-through orchestration to the maintained toolchain in
  `svelderrainruiz/compare-vi-cli-action`.

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
    uses: svelderrainruiz/pr-vi-history/.github/workflows/pr-vi-history.yml@main
    with:
      pr_number: ${{ github.event.pull_request.number }}
      fetch_depth: '20'
      max_pairs: '6'
      compare_modes: 'default,attributes'
      include_merge_parents: false
      upload_artifact: true
      post_comment: true
      toolchain_ref: develop
    secrets: inherit
```

## Notes

- This repository is intentionally thin and delegates execution to
  `compare-vi-cli-action` scripts (`toolchain_ref`) to avoid duplicated LabVIEW
  history logic.
- Once a stable tag is published, prefer pinning consumers to `@v1`.
