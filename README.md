# Base Platform GitHub Actions

Official GitHub Actions for deploying to the Norce Base Platform.

## Available Actions

| Action | Description |
|--------|-------------|
| `NorceTech/base-actions/deploy` | Deploy to any environment |
| `NorceTech/base-actions/preview` | Manage PR preview environments |
| `NorceTech/base-actions/promote` | Promote between environments |

## Setup

1. Get your partner webhook token from NorceTech
2. Add it as a repository secret: `BASE_PLATFORM_TOKEN`

## Usage Examples

### Deploy to Environment

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
          # Your build steps here
          echo "tag=${{ github.sha }}" >> $GITHUB_OUTPUT

  deploy-stage:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          sparse-checkout: .base
      - uses: NorceTech/base-actions/deploy@v1
        with:
          partner: your-partner-name
          environment: stage
          image_tag: ${{ needs.build.outputs.image_tag }}
          token: ${{ secrets.BASE_PLATFORM_TOKEN }}

  deploy-prod:
    needs: deploy-stage
    runs-on: ubuntu-latest
    environment: production  # Optional: requires approval
    steps:
      - uses: actions/checkout@v4
        with:
          sparse-checkout: .base
      - uses: NorceTech/base-actions/deploy@v1
        with:
          partner: your-partner-name
          environment: prod
          image_tag: ${{ needs.build.outputs.image_tag }}
          token: ${{ secrets.BASE_PLATFORM_TOKEN }}
```

### PR Preview Environments

```yaml
name: PR Preview

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

  preview:
    needs: build
    if: always()
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        if: github.event.action != 'closed'
        with:
          sparse-checkout: .base
      - uses: NorceTech/base-actions/preview@v1
        with:
          partner: your-partner-name
          action: ${{ github.event.action == 'closed' && 'delete' || (github.event.action == 'opened' && 'create' || 'update') }}
          image_tag: ${{ needs.build.outputs.image_tag }}
          token: ${{ secrets.BASE_PLATFORM_TOKEN }}
```

### Promote Stage to Prod

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
          partner: your-partner-name
          from_environment: stage
          to_environment: prod
          token: ${{ secrets.BASE_PLATFORM_TOKEN }}
```

## Configuration

Create `.base/config.yaml` in your repository for environment-specific settings:

```yaml
environments:
  preview:
    replicas: 1
    resources:
      limits:
        cpu: 100m
        memory: 128Mi

  stage:
    replicas: 1
    resources:
      limits:
        cpu: 250m
        memory: 256Mi

  prod:
    replicas: 3
    resources:
      limits:
        cpu: 500m
        memory: 512Mi
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      targetCPUUtilization: 80
```

## Action Reference

### `deploy`

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `partner` | Yes | - | Partner name on Base platform |
| `environment` | Yes | - | Target environment (stage, prod, etc.) |
| `image_tag` | Yes | - | Image tag to deploy |
| `customer` | No | repo name | Customer name |
| `config_file` | No | `.base/config.yaml` | Path to config file |
| `api_url` | No | `https://api.base.norce.tech` | Base API URL |
| `token` | Yes | - | Authentication token |

| Output | Description |
|--------|-------------|
| `success` | Whether deployment succeeded |
| `namespace` | Kubernetes namespace |
| `git_commit_sha` | Commit SHA in GitOps repo |
| `previous_image_tag` | Previous image tag |
| `message` | Result message |

### `preview`

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `partner` | Yes | - | Partner name on Base platform |
| `action` | Yes | - | Action: create, update, delete |
| `image_tag` | No | - | Image tag (not needed for delete) |
| `customer` | No | repo name | Customer name |
| `config_file` | No | `.base/config.yaml` | Path to config file |
| `api_url` | No | `https://api.base.norce.tech` | Base API URL |
| `token` | Yes | - | Authentication token |

| Output | Description |
|--------|-------------|
| `success` | Whether action succeeded |
| `preview_url` | URL of the preview environment |
| `namespace` | Kubernetes namespace |
| `git_commit_sha` | Commit SHA in GitOps repo |
| `message` | Result message |

### `promote`

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `partner` | Yes | - | Partner name on Base platform |
| `from_environment` | Yes | - | Source environment |
| `to_environment` | Yes | - | Target environment |
| `customer` | No | repo name | Customer name |
| `api_url` | No | `https://api.base.norce.tech` | Base API URL |
| `token` | Yes | - | Authentication token |

| Output | Description |
|--------|-------------|
| `success` | Whether promotion succeeded |
| `namespace` | Kubernetes namespace |
| `git_commit_sha` | Commit SHA in GitOps repo |
| `previous_image_tag` | Previous tag in target env |
| `new_image_tag` | Promoted image tag |
| `message` | Result message |

## How It Works

1. Your workflow calls the action with deployment parameters
2. Action reads config from `.base/config.yaml` (if present)
3. Action calls the Base Platform API
4. Base Platform commits changes to your GitOps repository
5. ArgoCD syncs the changes to your cluster

All deployments follow GitOps principles - changes go through Git, ArgoCD syncs from Git.

## Direct GitOps Access

Partners also have direct access to their `base-apps-<partner>` repository for:
- Custom Kustomize overlays
- Advanced configuration
- Custom Kubernetes manifests
