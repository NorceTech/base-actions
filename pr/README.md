# `pr` — Manage PR Environments

Creates, updates, and deletes **per-PR preview environments**. Each PR gets an isolated environment on a unique preview URL, and it's automatically cleaned up when the PR closes.

The platform's GitHub App comments on the PR with live status: ⏳ *Deploying* → 🚀 *Ready* (with preview URL) → 🗑️ *Deleted* (when the PR closes).

## Quick Start

```yaml
name: PR Environment

on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

jobs:
  build:
    if: github.event.action != 'closed'
    runs-on: ubuntu-latest
    outputs:
      image_tag: pr-${{ github.event.pull_request.number }}
    steps:
      - uses: actions/checkout@v4
      - name: Build and push
        run: |
          # Build with tag pr-<number>

  pr:
    needs: build
    if: always()
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        if: github.event.action != 'closed'
        with: { sparse-checkout: .base }
      - uses: NorceTech/base-actions/pr@v1
        with:
          action: ${{ github.event.action == 'closed' && 'delete' || (github.event.action == 'opened' && 'create' || 'update') }}
          image_tag: ${{ needs.build.outputs.image_tag }}
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

The three `action` values:

| Action | When | Effect |
|--------|------|--------|
| `create` | PR opened | Creates a new preview environment |
| `update` | PR updated (`synchronize`, `reopened`) | Deploys the new image tag |
| `delete` | PR closed or merged | Tears the environment down |

## Config

PR environments use the `environments.pr` template in `.base/config.yaml`:

```yaml
environments:
  stage:
    replicas: 2
    env:
      - name: LOG_LEVEL
        value: info

  pr:
    inherits: stage          # Start from stage config
    replicas: 1              # Override
    env:
      - name: PREVIEW
        value: 'true'
```

Full reference → [docs/config.md](../docs/config.md).

PR environments always scale to zero when idle — there's no need to configure autoscaling for them.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `action` | Yes | — | `create`, `update`, or `delete` |
| `image_tag` | No | — | Image tag (not required for `delete`) |
| `api_key` | Yes | — | Platform API key |
| `app` | No | repo name | App name |
| `config_file` | No | `.base/config.yaml` | Path to app config |
| `api_url` | No | `https://base-api.norce.tech` | Platform API URL |

## Outputs

| Output | Description |
|--------|-------------|
| `success` | Whether the action succeeded |
| `preview_url` | URL of the PR environment (set on `create`/`update`) |
| `message` | Result message |

## Related Docs

- [`.base/config.yaml` reference](../docs/config.md) — see the `environments.pr` section
- [Secrets](../docs/secrets.md) — PR environments get `environment=preview`-tagged secrets
