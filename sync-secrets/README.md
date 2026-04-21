# `sync-secrets` — Sync GitHub Secrets to the Platform Vault

Pushes the values of GitHub Actions secrets into the platform's secure vault. Every subsequent deploy automatically mounts those values as environment variables in the matching environments.

You only run `sync-secrets` **when a secret value changes**. Config changes in `.base/secrets.yaml` (scoping, adding new mappings) flow into deploys on their own.

## Quick Start

1. Declare mappings in [`.base/secrets.yaml`](../docs/secrets.md):

```yaml
environments:
  global:
    - github: SHARED_API_KEY
      keyvault: shared-api-key

  stage:
    - github: DATABASE_PASSWORD_STAGE
      keyvault: database-password

  prod:
    - github: DATABASE_PASSWORD_PROD
      keyvault: database-password
    - github: STRIPE_SECRET_KEY
      keyvault: stripe-secret-key
```

2. In the workflow, pass the actual values via `env:` — the action reads them and pushes them into the vault:

```yaml
name: Sync Secrets

on:
  workflow_dispatch:

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { sparse-checkout: .base }
      - uses: NorceTech/base-actions/sync-secrets@v1
        env:
          SHARED_API_KEY:          ${{ secrets.SHARED_API_KEY }}
          DATABASE_PASSWORD_STAGE: ${{ secrets.DATABASE_PASSWORD_STAGE }}
          DATABASE_PASSWORD_PROD:  ${{ secrets.DATABASE_PASSWORD_PROD }}
          STRIPE_SECRET_KEY:       ${{ secrets.STRIPE_SECRET_KEY }}
        with:
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

Each `env:` name must match a `github:` field in the mapping file. Secrets not found in the workflow `env:` are skipped with a warning.

## Sync a Single Environment

By default every environment is synced. Restrict to one:

```yaml
- uses: NorceTech/base-actions/sync-secrets@v1
  with:
    environment: prod          # only prod secrets (global always syncs too)
    api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

## Custom App Name

```yaml
- uses: NorceTech/base-actions/sync-secrets@v1
  with:
    app: my-app                # defaults to repo name
    api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api_key` | Yes | — | Platform API key |
| `app` | No | repo name | App name |
| `environment` | No | all | Sync only this environment (global secrets always sync) |
| `secrets_file` | No | `.base/secrets.yaml` | Path to secrets mapping file |
| `api_url` | No | `https://base-api.norce.tech` | Platform API URL |

## Outputs

| Output | Description |
|--------|-------------|
| `synced_count` | Number of secrets pushed successfully |
| `failed_count` | Number of secrets that failed to sync |
| `synced_names` | Comma-separated list of pushed secret names |

## Related Docs

- [Secrets — scoping and the `.base/secrets.yaml` format](../docs/secrets.md)
