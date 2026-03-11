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
    startupGracePeriod: 90           # optional: seconds to wait for app startup (default: 300)
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
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
    replicas: 2
    healthCheckPath: /api/health
    startupGracePeriod: 90
    resources:
      requests:
        cpu: 500m
        memory: 1.5Gi
      limits:
        cpu: 2000m
        memory: 3Gi
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      behaviorPreset: gradual           # 'default' | 'gradual' | 'cautious' | 'custom'
      triggers:
        - type: cpu
          utilizationPercentage: 60
        - type: memory
          utilizationPercentage: 75
        - type: http
          requestsPerSecond: 10
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
- **`behaviorPreset`** — Controls how fast autoscaling adds/removes pods. See [Scaling Behavior](#scaling-behavior) below.

### Scaling Behavior

Controls **how fast** KEDA scales up/down (not **when** — that's what triggers do). Protects slow-starting apps from being killed or starved during scale events.

#### Presets

| Preset | Scale Up | Scale Down | Min Ready | Shutdown | Best For |
|--------|----------|------------|-----------|----------|----------|
| `default` | No limits | No limits | 0s | 30s | Fast apps (Next.js, static) |
| `gradual` | +2 pods/60s | -1 pod/120s, 5 min stabilization | 30s | 30s | Most apps |
| `cautious` | +1 pod/120s, 60s stabilization | -1 pod/300s, 10 min stabilization | 60s | 60s | Java/.NET, slow starters |
| `custom` | User-defined | User-defined | User-defined | User-defined | Full control |

Set it in `.base/config.yaml`:

```yaml
environments:
  prod:
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      behaviorPreset: gradual        # Pick a preset
      triggers:
        - type: cpu
          utilizationPercentage: 70
```

For full control, use `custom` with explicit behavior:

```yaml
environments:
  prod:
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      behaviorPreset: custom
      behavior:
        scaleUp:
          maxPods: 3
          periodSeconds: 45
          stabilizationWindowSeconds: 0   # 0 = immediate scale-up (default: preset-dependent)
        scaleDown:
          maxPods: 1
          periodSeconds: 120
          stabilizationWindowSeconds: 300
        minReadySeconds: 30
        terminationGracePeriodSeconds: 60
      pollingInterval: 15            # How often KEDA checks metrics (seconds)
      cooldownPeriod: 300            # Wait after last scale event (seconds)
      triggers:
        - type: cpu
          utilizationPercentage: 60
        - type: memory
          utilizationPercentage: 75
        - type: http
          requestsPerSecond: 10
```

| Field | Description | Range |
|-------|-------------|-------|
| `behaviorPreset` | Preset name | `default`, `gradual`, `cautious`, `custom` |
| `behavior.scaleUp.maxPods` | Max pods to add at once | 1-10 |
| `behavior.scaleUp.periodSeconds` | Wait between scale-ups | 15-600 |
| `behavior.scaleUp.stabilizationWindowSeconds` | Look-back window for scale-up | 0-600 |
| `behavior.scaleDown.maxPods` | Max pods to remove at once | 1-10 |
| `behavior.scaleDown.periodSeconds` | Wait between scale-downs | 60-900 |
| `behavior.scaleDown.stabilizationWindowSeconds` | Look-back window for scale-down | 0-900 |
| `behavior.minReadySeconds` | Pod must stay healthy before getting traffic | 0-300 |
| `behavior.terminationGracePeriodSeconds` | Graceful shutdown time | 30-300 |
| `pollingInterval` | How often KEDA checks metrics | 10-300 |
| `cooldownPeriod` | Wait after last scale event | 60-900 |

The portal Scaling tab also shows a recommendation based on your app's observed startup time.

### Scaling Triggers

Triggers control **when** scaling happens. You can combine multiple triggers — the platform scales up when **any** trigger exceeds its threshold.

#### CPU

Scale based on CPU utilization percentage. Works on all apps — no domain setup required.

```yaml
environments:
  prod:
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      triggers:
        - type: cpu
          utilizationPercentage: 70    # Scale up when CPU > 70%
```

| Field | Range | Default |
|-------|-------|---------|
| `utilizationPercentage` | 1–100 | 70 |

Best for: CPU-intensive apps (SSR, image processing, API servers).

#### Memory

Scale based on memory utilization percentage. Works on all apps — no domain setup required.

```yaml
environments:
  prod:
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      triggers:
        - type: memory
          utilizationPercentage: 80    # Scale up when memory > 80%
```

| Field | Range | Default |
|-------|-------|---------|
| `utilizationPercentage` | 1–100 | 80 |

Best for: Apps that cache data in memory or handle large payloads.

#### HTTP

Scale based on incoming HTTP requests per second.

Measures incoming requests per second across all domains (internal and custom). Works out of the box — no custom domain required.

```yaml
environments:
  prod:
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      triggers:
        - type: http
          requestsPerSecond: 100       # Scale up when > 100 req/s per instance
        - type: cpu
          utilizationPercentage: 70    # Safety net — always works
```

| Field | Range | Default |
|-------|-------|---------|
| `requestsPerSecond` | 1–10,000 | 100 |

The threshold is **per pod** (KEDA AverageValue semantics). KEDA calculates desired replicas as `ceil(total_rps / threshold)`. Example: with `minReplicas: 3` and `requestsPerSecond: 50`, scale-up to 4 pods triggers when total traffic exceeds 150 req/s (50 × 3).

Best for: Web apps and APIs where traffic directly correlates with load. Always combine with a CPU trigger as a safety net.

#### Scheduled (Cron)

Scale to a specific number of instances on a schedule. Useful for known traffic patterns.

```yaml
environments:
  prod:
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 20
      triggers:
        - type: cron
          timezone: Europe/Stockholm
          schedule: '0 8 * * 1-5'          # Scale up at 08:00 on weekdays
          endSchedule: '0 18 * * 1-5'      # Scale down at 18:00 on weekdays
          desiredReplicas: 5
```

| Field | Description |
|-------|-------------|
| `timezone` | IANA timezone (e.g., `Europe/Stockholm`, `UTC`) |
| `schedule` | Cron expression for when to scale up |
| `endSchedule` | Cron expression for when to scale down (optional) |
| `desiredReplicas` | Number of instances during the scheduled period |

Common cron patterns:

| Pattern | Meaning |
|---------|---------|
| `0 8 * * 1-5` | 08:00 on weekdays |
| `0 6 * * *` | 06:00 every day |
| `0 0 25 11 *` | Midnight on November 25 (Black Friday prep) |
| `30 9 * * 1` | 09:30 every Monday |

Best for: Known traffic patterns — business hours, campaign launches, seasonal events.

#### Combining Triggers

You can use multiple triggers together. Example with CPU + HTTP + scheduled scaling:

```yaml
environments:
  prod:
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 20
      behaviorPreset: gradual
      triggers:
        - type: cpu
          utilizationPercentage: 60
        - type: memory
          utilizationPercentage: 75
        - type: http
          requestsPerSecond: 10
        - type: cron
          timezone: Europe/Stockholm
          schedule: '0 7 * * 1-5'
          endSchedule: '0 19 * * 1-5'
          desiredReplicas: 5
```

This configuration:
- Keeps at least **2 instances** running always
- Scales to **5 instances** during business hours (Mon–Fri 07:00–19:00)
- Scales further if CPU > 60%, memory > 75%, or traffic > 10 req/s per instance
- Never exceeds **20 instances**
- Uses **gradual** behavior to protect slow-starting apps

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
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 250m
        memory: 256Mi
    env:
      - name: BRAND
        value: brand-a
      - name: SITE_URL
        value: 'https://stage.brand-a.com'

  brand-a-prod:
    replicas: 2
    resources:
      requests:
        cpu: 500m
        memory: 1.5Gi
      limits:
        cpu: 2000m
        memory: 3Gi
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      triggers:
        - type: cpu
          utilizationPercentage: 60
        - type: memory
          utilizationPercentage: 75
        - type: http
          requestsPerSecond: 10
    env:
      - name: BRAND
        value: brand-a
      - name: SITE_URL
        value: 'https://www.brand-a.com'

  brand-b-stage:
    replicas: 1
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 250m
        memory: 256Mi
    env:
      - name: BRAND
        value: brand-b
      - name: SITE_URL
        value: 'https://stage.brand-b.com'

  brand-b-prod:
    replicas: 2
    resources:
      requests:
        cpu: 500m
        memory: 1.5Gi
      limits:
        cpu: 2000m
        memory: 3Gi
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      triggers:
        - type: cpu
          utilizationPercentage: 60
        - type: memory
          utilizationPercentage: 75
        - type: http
          requestsPerSecond: 10
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

## Custom Domains

Custom domains are managed through the **Portal** (Settings tab), not through `.base/config.yaml`. When you add a custom domain in the Portal, the platform automatically:

1. Issues an HTTPS certificate (Let's Encrypt)
2. Configures traffic routing

HTTP scaling metrics count all traffic regardless of which hostname it arrives on — the platform identifies traffic by upstream namespace, not by hostname. No extra configuration is needed when adding or removing custom domains.

## Advanced Configuration

Partners also have direct access to their `base-apps-<partner>` repository for advanced configuration and custom manifests.
