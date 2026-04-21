# Config Reference — `.base/config.yaml`

Every app can define environment-specific configuration in `.base/config.yaml`. Global settings apply to all environments; per-environment sections override them.

## Full Example

```yaml
environments:
  # Global env vars — applied to every environment
  global:
    env:
      - name: PORT
        value: '3000'
      - name: HOSTNAME
        value: '0.0.0.0'

  stage:
    replicas: 1
    containerPort: 3000              # default, can be omitted
    healthCheckPath: /api/health     # optional: HTTP readiness probe
    startupGracePeriod: 90           # optional: seconds to wait for startup (default 300)
    resources:
      requests: { cpu: 100m, memory: 128Mi }
      limits:   { cpu: 250m, memory: 256Mi }
    env:
      - name: LOG_LEVEL
        value: debug

  stage-preview:                     # Overrides applied during staged (canary) deploys on stage
    env:
      - name: DEBUG
        value: 'true'

  prod:
    replicas: 2
    healthCheckPath: /api/health
    startupGracePeriod: 90
    is_private: false                # default false — set true for internal-only (no public endpoint)
    resources:
      requests: { cpu: 500m,  memory: 1.5Gi }
      limits:   { cpu: 2000m, memory: 3Gi }
    autoscaling:                     # See docs/scaling.md
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      behaviorPreset: gradual
      triggers:
        - type: cpu
          utilizationPercentage: 60
    env:
      - name: LOG_LEVEL
        value: warn

  prod-preview:                      # Staged-deploy overrides on prod
    env:
      - name: CANARY_METRICS
        value: 'enabled'

  # PR scope — not an environment, a config template for PR previews
  pr:
    inherits: stage                  # Use stage as the base
    replicas: 1
    resources:
      limits: { cpu: 250m, memory: 256Mi }
    env:
      - name: PREVIEW
        value: 'true'
```

## Resolution

| Scenario | Config vars resolved from |
|----------|---------------------------|
| Named environment deploy | `global` + `<env>` |
| Staged (canary) deploy | `global` + `<env>` + `<env>-preview` |
| PR environment | `global` + `<inherited-env>` + `pr` |

## Keys

| Key | Description |
|-----|-------------|
| `replicas` | Fixed replica count when autoscaling is disabled. |
| `containerPort` | Port the app listens on (default `3000`). |
| `healthCheckPath` | HTTP readiness probe path. Omit to use a TCP port check (safe for auth-protected apps). |
| `startupGracePeriod` | Seconds to wait before failing the startup probe (default `300`, range `10–900`). Increase for slow-start apps. |
| `is_private` | `true` hides the environment from the public internet — no public endpoint, no DNS. See [Internal-Only Deployments](#internal-only-deployments). |
| `resources.requests` / `resources.limits` | CPU and memory reservations. |
| `autoscaling` | Autoscaling rules — see [docs/scaling.md](scaling.md). |
| `env` | List of `{ name, value }` environment variables. Values are always stringified — `value: 3000` and `value: '3000'` behave identically. |

## Environment Variable Merging

- `environments.global.env` is merged into every deploy. Globals show up separately in the portal Config tab.
- Per-environment `env` entries override globals with the same `name`.
- Staged deploys add a third merge layer from `<env>-preview`.

## PR Environments

The `environments.pr` section is a **config template**, not a named environment. Use `inherits` to base the template on a named environment:

```yaml
environments:
  stage:
    replicas: 2
    env:
      - name: LOG_LEVEL
        value: info

  pr:
    inherits: stage       # PRs start from stage config
    replicas: 1           # override
    env:
      - name: PREVIEW
        value: 'true'
```

Every PR gets its own isolated environment named `pr-<number>`, auto-created when the PR opens and auto-deleted when it closes.

Pattern names that auto-route through the `pr` template: `pr-*`, `preview-*`, `feature-*`, `branch-*`.

## Internal-Only Deployments

Set `is_private: true` for apps that should not be reachable from the public internet (internal APIs, bots, background services):

```yaml
environments:
  prod:
    is_private: true
    replicas: 2
    env:
      - name: PORT
        value: '3000'
```

When `is_private: true`:

- No public endpoint, no DNS, no HTTPS certificate
- Staged deploys use instance-based canary (replica scaling) instead of traffic splitting
- The app is only reachable from other apps in the same organization via an internal platform address

The toggle is also available in the portal (Environments → *Internal only*). Once set, it flows through promotions and rollbacks automatically.

> ⚠️ Switching an existing public environment to `is_private: true` **removes** all public routing and DNS. Existing traffic will be dropped.
