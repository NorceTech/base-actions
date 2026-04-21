# `promote` — Promote Between Environments

Supports two promotion modes:

1. **Canary promotion** — make a staged (canary) deploy live on its own environment
2. **Cross-environment promotion** — copy the image tag from one environment to another (e.g. stage → prod)

---

## Canary Promotion

Use when you deployed with `auto_promote: false` (see [deploy docs](../deploy/README.md#staged-canary-deployments)) and now want to roll the canary out to 100% traffic.

```yaml
- uses: NorceTech/base-actions/promote@v1
  with:
    environment: prod
    canary: true
    api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

Typical pipeline — deploy → review preview URL → promote:

```yaml
name: Staged Deploy to Production

on:
  workflow_dispatch:

jobs:
  deploy-canary:
    runs-on: ubuntu-latest
    outputs:
      preview_url: ${{ steps.deploy.outputs.preview_url }}
    steps:
      - uses: actions/checkout@v4
        with: { sparse-checkout: .base }
      - uses: NorceTech/base-actions/deploy@v1
        id: deploy
        with:
          environment: prod
          image_tag: ${{ github.sha }}
          auto_promote: false
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}

  promote:
    needs: deploy-canary
    runs-on: ubuntu-latest
    environment: production          # Requires GitHub approval
    steps:
      - uses: NorceTech/base-actions/promote@v1
        with:
          environment: prod
          canary: true
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

---

## Cross-Environment Promotion

Copy the image tag running in one environment to another:

```yaml
- uses: NorceTech/base-actions/promote@v1
  with:
    from_environment: stage
    to_environment: prod
    api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

Common pattern — manual promotion from stage to prod:

```yaml
name: Promote to Production

on:
  workflow_dispatch:

jobs:
  promote:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: NorceTech/base-actions/promote@v1
        with:
          from_environment: stage
          to_environment: prod
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

---

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api_key` | Yes | — | Platform API key |
| `environment` | No | — | Target environment (canary promotion — use with `canary: true`) |
| `canary` | No | `false` | `true` → promote a staged canary to live |
| `from_environment` | No | — | Source environment (cross-env promotion) |
| `to_environment` | No | — | Target environment (cross-env promotion) |
| `app` | No | repo name | App name |
| `api_url` | No | `https://base-api.norce.tech` | Platform API URL |

Use **either** `canary: true` + `environment`, **or** `from_environment` + `to_environment` — not both.

## Outputs

| Output | Description |
|--------|-------------|
| `success` | Whether the promotion succeeded |
| `namespace` | Deployment namespace |
| `git_commit_sha` | Commit SHA recorded for this deploy |
| `previous_image_tag` | Tag that was running in the target before promotion |
| `new_image_tag` | Tag now running in the target |
| `message` | Result message |
