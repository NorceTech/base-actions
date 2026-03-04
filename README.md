# Base Platform GitHub Actions

Official GitHub Actions for deploying to the Norce Base Platform.

## Available Actions

| Action | Description |
|--------|-------------|
| `NorceTech/base-actions/deploy` | Deploy to any environment |
| `NorceTech/base-actions/pr` | Manage PR environments |
| `NorceTech/base-actions/promote` | Promote between environments |
| `NorceTech/base-actions/sync-secrets` | Sync GitHub Secrets to your secure vault |

## Setup

1. Get your partner API key from NorceTech (or generate via Base Portal)
2. Add it as a repository secret: `BASE_PLATFORM_API_KEY`

The API key identifies your partner - no need to pass partner name in your workflows.

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
          environment: stage
          image_tag: ${{ needs.build.outputs.image_tag }}
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}

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
          environment: prod
          image_tag: ${{ needs.build.outputs.image_tag }}
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

### PR Environments

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
        with:
          sparse-checkout: .base
      - uses: NorceTech/base-actions/pr@v1
        with:
          action: ${{ github.event.action == 'closed' && 'delete' || (github.event.action == 'opened' && 'create' || 'update') }}
          image_tag: ${{ needs.build.outputs.image_tag }}
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

### Promote Stage to Prod (Cross-Environment)

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

### Promote Canary to Live

```yaml
name: Promote Canary

on:
  workflow_dispatch:

jobs:
  promote:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: NorceTech/base-actions/promote@v1
        with:
          environment: prod
          canary: true
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

### Sync Secrets

Syncs GitHub Secrets to your secure vault via the Base Platform API. Uses the same `environments.global` / `environments.<env>` structure as `config.yaml`.

1. Create `.base/secrets.yaml` with secret mappings:

```yaml
environments:
  # Global secrets — synced to all environments
  global:
    - github: SHARED_API_KEY
      keyvault: shared-api-key

  # Per-environment secrets
  stage:
    - github: DATABASE_PASSWORD_STAGE
      keyvault: database-password
    - github: API_SECRET_STAGE
      keyvault: api-secret

  prod:
    - github: DATABASE_PASSWORD_PROD
      keyvault: database-password
    - github: API_SECRET_PROD
      keyvault: api-secret
    - github: STRIPE_SECRET_KEY
      keyvault: stripe-secret-key
```

- **Global secrets** (`environments.global`) are stored as `app-shared-api-key` (no env prefix)
- **Per-environment secrets** (`environments.<env>`) are stored as `app-stage-database-password`, `app-prod-database-password`
- Global secrets always sync, even when targeting a specific environment
- Legacy format: a top-level `secrets:` key is also supported as an alias for `environments.global`

2. Pass the actual secret values as `env:` variables in your workflow:

```yaml
name: Sync Secrets

on:
  workflow_dispatch:

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          sparse-checkout: .base
      - uses: NorceTech/base-actions/sync-secrets@v1
        env:
          SHARED_API_KEY: ${{ secrets.SHARED_API_KEY }}
          DATABASE_PASSWORD_STAGE: ${{ secrets.DATABASE_PASSWORD_STAGE }}
          DATABASE_PASSWORD_PROD: ${{ secrets.DATABASE_PASSWORD_PROD }}
          API_SECRET_STAGE: ${{ secrets.API_SECRET_STAGE }}
          API_SECRET_PROD: ${{ secrets.API_SECRET_PROD }}
          STRIPE_SECRET_KEY: ${{ secrets.STRIPE_SECRET_KEY }}
        with:
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

You can sync only a specific environment, or set a custom app name:

```yaml
      - uses: NorceTech/base-actions/sync-secrets@v1
        with:
          app: my-app              # defaults to repo name
          environment: prod        # only sync prod secrets (global secrets always sync)
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

Each `env:` name must match a `github` field in the mapping file. Secrets not found in the environment are skipped with a warning.

### Deploy with Custom Image Name

When the container image name differs from the app name, use the `image` input:

```yaml
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          sparse-checkout: .base
      - uses: NorceTech/base-actions/deploy@v1
        with:
          app: my-app
          environment: my-env
          image: my-image            # Uses image "my-image" instead of "my-app"
          image_tag: ${{ needs.build.outputs.image_tag }}
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

This deploys the image `my-image:<tag>` instead of `my-app:<tag>`.

### Deploy with All Inputs

```yaml
  deploy-prod:
    needs: build
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
        with:
          sparse-checkout: .base
      - uses: NorceTech/base-actions/deploy@v1
        with:
          environment: prod
          image_tag: ${{ needs.build.outputs.image_tag }}
          app: my-app
          image: my-image
          config_file: .base/config.yaml
          api_url: https://base-api.norce.tech
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
          wait_for_healthy: 'true'
          wait_timeout: '600'
```

## Environment Model

### Named Environments

The platform supports four named environments:

| Name | Type | Purpose |
|------|------|---------|
| `dev` | development | Development/local testing |
| `test` | staging | Integration testing |
| `stage` | staging | Pre-production testing |
| `prod` | production | Live production |

### PR Environments (ephemeral)

Pattern-based names that are auto-created per PR and auto-deleted when the PR closes:

`pr-*`, `preview-*`, `feature-*`, `branch-*`

### Staged Deployment

Any named environment can use staged deployment. When `auto_promote: false`, deploys create a canary version on a preview URL. After testing, promote to make it live.

Set the strategy from CI/CD using the `auto_promote` input on the deploy action, or toggle it in the portal Settings tab.

```yaml
name: Staged Deploy to Production

on:
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image_tag: ${{ steps.build.outputs.tag }}
    steps:
      - uses: actions/checkout@v4
      - name: Build and push
        id: build
        run: echo "tag=${{ github.sha }}" >> $GITHUB_OUTPUT

  deploy-canary:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          sparse-checkout: .base
      - uses: NorceTech/base-actions/deploy@v1
        id: deploy
        with:
          environment: prod
          image_tag: ${{ needs.build.outputs.image_tag }}
          auto_promote: false    # Staged: canary pauses for review
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}

      # Preview URL is available when deployment is Suspended
      - name: Show preview URL
        run: echo "Preview → ${{ steps.deploy.outputs.preview_url }}"

  promote:
    needs: deploy-canary
    runs-on: ubuntu-latest
    environment: production    # Requires manual approval
    steps:
      - uses: NorceTech/base-actions/promote@v1
        with:
          environment: prod
          canary: true
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

## Configuration

Create `.base/config.yaml` in your repository. Use `environments.global` for env vars shared across all environments, and per-environment sections for environment-specific settings:

```yaml
environments:
  # Global env vars — applied to all environments
  global:
    env:
      - name: PORT
        value: '3000'
      - name: HOSTNAME
        value: '0.0.0.0'

  # Per-environment config
  stage:
    replicas: 1
    containerPort: 3000              # default, can be omitted
    healthCheckPath: /api/health     # optional: HTTP readiness probe (omit for TCP default)
    startupGracePeriod: 300          # optional: seconds to wait for app startup (default: 300)
    resources:
      limits:
        cpu: 250m
        memory: 256Mi
    env:
      - name: LOG_LEVEL
        value: debug

  stage-preview:                     # Overrides during staged deployments on stage
    env:
      - name: DEBUG
        value: 'true'

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
      triggers:
        - type: cpu
          utilizationPercentage: 80
    env:
      - name: LOG_LEVEL
        value: warn

  prod-preview:                      # Overrides during staged deployments on prod
    env:
      - name: CANARY_METRICS
        value: 'enabled'

  # Config scope for PR environments (not a named environment)
  pr:
    inherits: stage                  # Inherit stage config as base
    replicas: 1
    resources:
      limits:
        cpu: 250m
        memory: 256Mi
    env:
      - name: PREVIEW
        value: 'true'
```

### Config Resolution

| Scenario | Config vars | Secrets |
|----------|-------------|---------|
| Named env deploy | `global` + `<env>` | `all` + `<env>` |
| Staged deployment | `global` + `<env>` + `<env>-preview` | `all` + `<env>` + `<env>-preview` |
| PR environment | `global` + `<inherited-env>` + `pr` | `all` + `preview` |

### Key Notes

- **Global env vars** (`environments.global.env`) are merged into every deploy and shown separately in the portal Config tab
- **Per-environment env vars** override globals if they share the same name
- **`environments.pr`** is the config scope for PR environments, NOT a named environment. Use `inherits` to base PR config on a named environment.
- **`environments.<env>-preview`** is a top-level key for staged deployment overrides (e.g., `environments.prod-preview`). Same structure as secrets.
- Resources, replicas, and autoscaling are always per-environment
- **`healthCheckPath`** — HTTP readiness probe path. Default is TCP port check (safe for auth-protected apps). Only set if your app has a public health endpoint returning HTTP 200.
- **`startupGracePeriod`** — Seconds to wait for app startup (default: 300, range: 10–900). Increase for slow-starting apps like large Next.js SSR builds.
- **`containerPort`** — Port your app listens on (default: 3000). Updates Deployment containerPort and Service targetPort.
- **Env var values are always converted to strings** — you can write `value: 3000`, `value: '3000'`, or `value: "3000"` and the result is the same. The platform handles the conversion automatically.

### Secrets

Secrets are managed in Azure KeyVault with tag-based scoping:

| Tag | Scope |
|-----|-------|
| `environment=all` | All environments (including PR previews and staged deployments) |
| `environment=<env>` | Specific named environment (e.g., `environment=prod`) |
| `environment=<env>-preview` | Staged deployment overrides (e.g., `environment=prod-preview`) |
| `environment=preview` | All PR environments |

Secrets follow the same override pattern as config vars. Use the `<env>-preview` convention in `.base/secrets.yaml` to override secrets during staged deployments:

```yaml
# .base/secrets.yaml
environments:
  global:
    - github: SHARED_API_KEY
      keyvault: shared-api-key

  prod:
    - github: STRIPE_SECRET_KEY
      keyvault: stripe-secret-key

  prod-preview:                          # Overrides during staged deployments on prod
    - github: STRIPE_TEST_KEY
      keyvault: stripe-secret-key        # Same keyvault name → overrides prod value
```

During staged deployments, canary pods receive: `environment=all` + `environment=<env>` + `environment=<env>-preview`. After promotion, preview overrides are removed and the live version uses only `environment=all` + `environment=<env>`.

Use `sync-secrets` to sync GitHub Secrets to KeyVault (see above).

## How It Works

1. Your workflow calls the action with deployment parameters
2. Action reads config from `.base/config.yaml` (if present)
3. Action calls the Base Platform API (partner identified by API key)
4. Base Platform updates the deployment configuration
5. Changes are synced to your cluster
6. Action polls for deployment health status (if `wait_for_healthy: true`)

## Action Reference

### `deploy`

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `environment` | Yes | - | Target environment (stage, prod, etc.) |
| `image_tag` | Yes | - | Image tag to deploy |
| `app` | No | repo name | App name |
| `image` | No | app name | Container image name (when image name differs from app) |
| `config_file` | No | `.base/config.yaml` | Path to config file |
| `api_url` | No | `https://base-api.norce.tech` | Base API URL |
| `api_key` | Yes | - | API key (identifies partner) |
| `wait_for_healthy` | No | `true` | Wait for deployment to become healthy |
| `wait_timeout` | No | `300` | Timeout in seconds when waiting for healthy status |
| `auto_promote` | No | - | `false` = staged canary, `true` = instant rollout. Omit to use portal setting. |

| Output | Description |
|--------|-------------|
| `success` | Whether deployment succeeded (includes health check if enabled) |
| `namespace` | Deployment namespace |
| `git_commit_sha` | Commit SHA for the deployment |
| `previous_image_tag` | Previous image tag |
| `message` | Result message |
| `health_status` | Final health status (Healthy, Progressing, Degraded, Timeout) |
| `sync_status` | Final sync status |

#### Health Status Polling

By default, the deploy action waits for your deployment to become healthy before completing. This ensures your CI/CD pipeline reflects the actual deployment status.

**What it checks:**
- Health status: `Healthy`, `Progressing`, `Degraded`, `Missing`
- Image tag matches the deployed tag

**Example output:**
```
⏳ Waiting for deployment to become healthy (timeout: 300s)...
  [10s] Health: Progressing, Tag: main-bc5059
  [20s] Health: Progressing, Tag: main-bc5059
  [35s] Health: Healthy, Tag: main-bc5059

✅ Deployment healthy and synced! (35s)
```

**Disable health polling** (not recommended):
```yaml
- uses: NorceTech/base-actions/deploy@v1
  with:
    environment: stage
    image_tag: ${{ steps.tag.outputs.tag }}
    api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
    wait_for_healthy: 'false'
```

**Adjust timeout:**
```yaml
- uses: NorceTech/base-actions/deploy@v1
  with:
    environment: prod
    image_tag: ${{ steps.tag.outputs.tag }}
    api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
    wait_timeout: '600'  # 10 minutes for larger deployments
```

### `pr` (PR environments)

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `action` | Yes | - | Action: create, update, delete |
| `image_tag` | No | - | Image tag (not needed for delete) |
| `app` | No | repo name | App name |
| `config_file` | No | `.base/config.yaml` | Path to config file |
| `api_url` | No | `https://base-api.norce.tech` | Base API URL |
| `api_key` | Yes | - | API key (identifies partner) |

| Output | Description |
|--------|-------------|
| `success` | Whether action succeeded |
| `preview_url` | URL of the PR environment |
| `message` | Result message |

### `promote`

Supports two modes:
- **Canary promotion** (`canary: true` + `environment`): promotes a staged canary to live
- **Cross-environment** (`from_environment` + `to_environment`): copies image from one env to another

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `environment` | No | - | Target environment for canary promotion (use with `canary: true`) |
| `canary` | No | `false` | Set to `true` to promote a staged canary to live |
| `from_environment` | No | - | Source environment for cross-env promotion |
| `to_environment` | No | - | Target environment for cross-env promotion |
| `app` | No | repo name | App name |
| `api_url` | No | `https://base-api.norce.tech` | Base API URL |
| `api_key` | Yes | - | API key (identifies partner) |

| Output | Description |
|--------|-------------|
| `success` | Whether promotion succeeded |
| `namespace` | Deployment namespace |
| `git_commit_sha` | Commit SHA for the deployment |
| `previous_image_tag` | Previous tag in target env |
| `new_image_tag` | Promoted image tag |
| `message` | Result message |

### `sync-secrets`

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `app` | No | repo name | App name |
| `environment` | No | all | Sync only this environment (default: all) |
| `secrets_file` | No | `.base/secrets.yaml` | Path to secrets mapping file |
| `api_url` | No | `https://base-api.norce.tech` | Base API URL |
| `api_key` | Yes | - | API key (identifies partner) |

| Output | Description |
|--------|-------------|
| `synced_count` | Number of secrets successfully synced |
| `failed_count` | Number of secrets that failed to sync |
| `synced_names` | Comma-separated list of synced secret names |

## API Endpoints

The actions call the following endpoints:

| Action | Endpoint |
|--------|----------|
| `deploy` | `POST /api/v1/deploy` |
| `deploy` (status polling) | `GET /api/v1/deploy/status` |
| `pr` | `POST /api/v1/preview` |
| `promote` (cross-env) | `POST /api/v1/deploy` (with action=promote) |
| `promote` (canary) | `POST /api/v1/deploy` (with action=promote-canary) |
| `sync-secrets` | `POST /api/v1/secrets` |

## Multi-Brand / Multi-Site Deployments

If you manage multiple brands or sites from a single codebase (e.g., `brand-a.com` and `brand-b.com`), use **one app with multiple environments** rather than creating separate apps per brand. This gives you:

- **Shared container image** — one build, deployed to all sites
- **Global config/secrets** — shared settings applied everywhere
- **Per-site config/secrets** — brand-specific settings per environment

### Architecture

```
App: my-brand-group (single codebase, single container image)
├── brand-a-stage   (domain: stage.brand-a.com)
├── brand-a-prod    (domain: www.brand-a.com)
├── brand-b-stage   (domain: stage.brand-b.com)
└── brand-b-prod    (domain: www.brand-b.com)
```

Each environment gets its own Kubernetes namespace, deployment, secrets, and domain.

### Config

```yaml
# .base/config.yaml
environments:
  global:
    env:
      - name: PORT
        value: '3000'
      - name: CDN_URL
        value: 'https://cdn.my-brand-group.com'

  brand-a-stage:
    replicas: 1
    resources:
      limits:
        cpu: 250m
        memory: 256Mi
    env:
      - name: BRAND
        value: brand-a
      - name: SITE_URL
        value: 'https://stage.brand-a.com'

  brand-a-prod:
    replicas: 3
    resources:
      limits:
        cpu: 500m
        memory: 512Mi
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      triggers:
        - type: cpu
          utilizationPercentage: 80
    env:
      - name: BRAND
        value: brand-a
      - name: SITE_URL
        value: 'https://www.brand-a.com'

  brand-b-stage:
    replicas: 1
    resources:
      limits:
        cpu: 250m
        memory: 256Mi
    env:
      - name: BRAND
        value: brand-b
      - name: SITE_URL
        value: 'https://stage.brand-b.com'

  brand-b-prod:
    replicas: 3
    resources:
      limits:
        cpu: 500m
        memory: 512Mi
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      triggers:
        - type: cpu
          utilizationPercentage: 80
    env:
      - name: BRAND
        value: brand-b
      - name: SITE_URL
        value: 'https://www.brand-b.com'
```

### Secrets

```yaml
# .base/secrets.yaml
environments:
  # Shared across all brands and environments
  global:
    - github: SHARED_API_KEY
      keyvault: shared-api-key

  # Per brand+environment
  brand-a-stage:
    - github: BRAND_A_DB_PASSWORD_STAGE
      keyvault: database-password

  brand-a-prod:
    - github: BRAND_A_DB_PASSWORD_PROD
      keyvault: database-password
    - github: BRAND_A_PAYMENT_KEY
      keyvault: payment-secret-key

  brand-b-stage:
    - github: BRAND_B_DB_PASSWORD_STAGE
      keyvault: database-password

  brand-b-prod:
    - github: BRAND_B_DB_PASSWORD_PROD
      keyvault: database-password
    - github: BRAND_B_PAYMENT_KEY
      keyvault: payment-secret-key
```

### Workflow

Use a matrix strategy to deploy all sites in parallel:

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
          # Build once — shared image for all brands
          echo "tag=${{ github.sha }}" >> $GITHUB_OUTPUT

  deploy-stage:
    needs: build
    runs-on: ubuntu-latest
    strategy:
      matrix:
        environment: [brand-a-stage, brand-b-stage]
    steps:
      - uses: actions/checkout@v4
        with:
          sparse-checkout: .base
      - uses: NorceTech/base-actions/deploy@v1
        with:
          app: my-brand-group
          environment: ${{ matrix.environment }}
          image_tag: ${{ needs.build.outputs.image_tag }}
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}

  deploy-prod:
    needs: deploy-stage
    runs-on: ubuntu-latest
    environment: production
    strategy:
      matrix:
        environment: [brand-a-prod, brand-b-prod]
    steps:
      - uses: actions/checkout@v4
        with:
          sparse-checkout: .base
      - uses: NorceTech/base-actions/deploy@v1
        with:
          app: my-brand-group
          environment: ${{ matrix.environment }}
          image_tag: ${{ needs.build.outputs.image_tag }}
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

### How it maps

| Concept | Base Platform |
|---------|---------------|
| Brand group | App (e.g., `my-brand-group`) |
| Brand + env | Environment (e.g., `brand-a-prod`) |
| Shared image | One container image per app |
| Global secrets | `environments.global` in `.base/secrets.yaml` |
| Per-brand secrets | `environments.<brand>-<env>` in `.base/secrets.yaml` |
| Global config | `environments.global.env` in `.base/config.yaml` |
| Per-brand config | `environments.<brand>-<env>.env` in `.base/config.yaml` |

## Advanced Configuration

Partners also have direct access to their `base-apps-<partner>` repository for advanced configuration and custom manifests.
