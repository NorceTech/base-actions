# `deploy` — Deploy to an Environment

Deploys a new image tag to any named environment (`dev`, `test`, `stage`, `prod`, or custom names you define). Handles config resolution, health polling, and optional staged (canary) rollouts.

## Quick Start

```yaml
- uses: actions/checkout@v4
  with:
    sparse-checkout: .base
- uses: NorceTech/base-actions/deploy@v1
  with:
    environment: stage
    image_tag: ${{ needs.build.outputs.image_tag }}
    api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

The `sparse-checkout: .base` line is required — the action reads `.base/config.yaml`, `.base/secrets.yaml`, `.base/nginx.yaml`, and `.base/redirects.yaml` from the runner's working directory.

## Full Example

```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image_tag: ${{ steps.build.outputs.tag }}
    steps:
      - uses: actions/checkout@v4
      - name: Build and push
        id: build
        run: |
          # Your build + push steps
          echo "tag=${{ github.sha }}" >> $GITHUB_OUTPUT

  deploy-stage:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { sparse-checkout: .base }
      - uses: NorceTech/base-actions/deploy@v1
        with:
          environment: stage
          image_tag: ${{ needs.build.outputs.image_tag }}
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}

  deploy-prod:
    needs: deploy-stage
    runs-on: ubuntu-latest
    environment: production  # Optional: requires GitHub approval
    steps:
      - uses: actions/checkout@v4
        with: { sparse-checkout: .base }
      - uses: NorceTech/base-actions/deploy@v1
        with:
          environment: prod
          image_tag: ${{ needs.build.outputs.image_tag }}
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

## Staged (Canary) Deployments

Set `auto_promote: false` to deploy a canary version first. The canary lives on a preview URL until you promote it with the [`promote` action](../promote/README.md).

```yaml
- uses: NorceTech/base-actions/deploy@v1
  id: deploy
  with:
    environment: prod
    image_tag: ${{ needs.build.outputs.image_tag }}
    auto_promote: false                              # canary pauses for review
    api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}

- name: Show preview URL
  run: echo "Preview → ${{ steps.deploy.outputs.preview_url }}"
```

Skip `auto_promote` to use the default configured in the portal (Settings → *Auto-promote*).

## Custom Image Name

When the container image name differs from the app name:

```yaml
- uses: NorceTech/base-actions/deploy@v1
  with:
    app: my-app
    environment: stage
    image: my-image                                  # deploys my-image:<tag>
    image_tag: ${{ needs.build.outputs.image_tag }}
    api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

## Health Polling

By default the action waits for the deployment to become healthy before exiting. The CI run reflects actual deployment status, not just "the API accepted the request".

**What's checked:**
- Health status reaches `Healthy`. Values seen during polling: `Progressing`, `Degraded`, `Missing`, `Healthy`, and `Suspended` (staged deploys — the canary is live on the preview URL and awaiting promotion).
- Running image tag matches the one you deployed

**Example log:**

```
⏳ Waiting for deployment to become healthy (timeout: 300s)…
  [10s] Health: Progressing, Tag: main-bc5059
  [20s] Health: Progressing, Tag: main-bc5059
  [35s] Health: Healthy,     Tag: main-bc5059

✅ Deployment healthy and synced (35s)
```

Disable polling (not recommended):

```yaml
wait_for_healthy: 'false'
```

Extend the timeout for slow-starting apps:

```yaml
wait_timeout: '600'   # 10 minutes
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `environment` | Yes | — | Target environment (`stage`, `prod`, `brand-a-prod`, …) |
| `image_tag` | Yes | — | Image tag to deploy |
| `api_key` | Yes | — | Platform API key — identifies the partner |
| `app` | No | repo name | App name |
| `image` | No | app name | Container image name (when the image name differs from the app) |
| `config_file` | No | `.base/config.yaml` | Path to app config |
| `nginx_config_file` | No | `.base/nginx.yaml` | Path to custom proxy config |
| `redirects_file` | No | `.base/redirects.yaml` | Path to bulk redirects file (`.yaml` or `.csv`). Falls back to `.csv` if `.yaml` is not present. See [proxy config & redirects](../docs/nginx.md). |
| `api_url` | No | `https://base-api.norce.tech` | Platform API URL |
| `wait_for_healthy` | No | `true` | Wait for the deploy to become healthy before exiting |
| `wait_timeout` | No | `300` | Health-polling timeout (seconds) |
| `auto_promote` | No | — | `false` → staged canary, `true` → instant rollout. Omit to use portal setting. |

## Outputs

| Output | Description |
|--------|-------------|
| `success` | Whether the deploy succeeded (includes health check if enabled) |
| `namespace` | Deployment namespace |
| `git_commit_sha` | Commit SHA the platform recorded for this deploy |
| `previous_image_tag` | Tag that was running before this deploy |
| `message` | Result message |
| `health_status` | Final health status (`Healthy`, `Progressing`, `Degraded`, `Suspended`, `Missing`, `Timeout`) |
| `sync_status` | Final sync status (`Synced`, `OutOfSync`, etc.) |
| `preview_url` | Preview URL for staged deploys. Populated when `health_status=Suspended`; empty for standard deploys. |

## Related Docs

- [`.base/config.yaml` reference](../docs/config.md)
- [Autoscaling](../docs/scaling.md)
- [Secrets](../docs/secrets.md)
- [Proxy config & redirects](../docs/nginx.md)
- [Multi-brand deploys](../docs/multi-brand.md)
