# Base Platform GitHub Actions

Official GitHub Actions for deploying apps to the **Norce Base Platform**.

## Actions

| Action | Purpose |
|--------|---------|
| [`deploy`](deploy/README.md) | Deploy an image tag to any named environment |
| [`pr`](pr/README.md) | Create, update, and delete per-PR preview environments |
| [`promote`](promote/README.md) | Promote a staged canary to live, or copy an image between environments |
| [`sync-secrets`](sync-secrets/README.md) | Push GitHub secret values to the platform vault |

## Setup

1. Get your partner API key from the Base Portal (or from your NorceTech contact)
2. Add it as a repository secret named **`BASE_PLATFORM_API_KEY`**

The API key identifies your partner — there's no need to pass the partner name in your workflows.

### Runner requirements

These actions parse your `.base/*.yaml` files with [`yq`](https://github.com/mikefarah/yq),
falling back to `python3` + PyYAML. **GitHub-hosted runners ship `yq` preinstalled, so
nothing is needed there.** On a self-hosted runner, make sure one of the two is present
on the image, or install `yq` in a step before the action:

```yaml
- name: Ensure yq is available
  run: |
    set -euo pipefail
    command -v yq >/dev/null && exit 0
    # Pick the asset for THIS runner — an amd64 binary on an arm64 runner
    # fails with a confusing "cannot execute binary file".
    case "$(uname -m)" in
      x86_64) YQ_ARCH=amd64 ;;
      aarch64|arm64) YQ_ARCH=arm64 ;;
      *) echo "unsupported arch $(uname -m)"; exit 1 ;;
    esac
    mkdir -p "$RUNNER_TEMP/bin"
    curl -fsSL -o "$RUNNER_TEMP/bin/yq" \
      "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${YQ_ARCH}"
    chmod +x "$RUNNER_TEMP/bin/yq"
    echo "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"
```

For anything beyond a stopgap, pin the release and verify it — this step puts an
executable on `PATH` for every later step in the job. Pin `yq_linux_<arch>` to a
tagged version and check it against the SHA-256 column of that release's
`checksums` asset before `chmod +x`.

If neither is available the action now stops with an explicit error naming what is
missing. Before `v1.1.2` it exited 1 with an empty log.

## Minimal Deploy

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
        run: echo "tag=${{ github.sha }}" >> $GITHUB_OUTPUT

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
```

See the [`deploy` action docs](deploy/README.md) for the full picture.

## Environment Model

**Named environments** — created by you in the portal:

| Suggested name | Typical use |
|----------------|-------------|
| `dev` | Local / developer testing |
| `test` | Integration testing |
| `stage` | Pre-production testing |
| `prod` | Live production |

You can create environments with any name you like — `brand-a-prod`, `eu-stage`, `demo`, etc.

**PR environments** — ephemeral, one per PR, auto-created and auto-deleted:

`pr-*`, `preview-*`, `feature-*`, `branch-*`

## Configuration Files

All optional. Place them in `.base/` at the repo root:

| File | Purpose | Docs |
|------|---------|------|
| `.base/config.yaml` | Per-environment config (replicas, resources, env vars, autoscaling) | [docs/config.md](docs/config.md) |
| `.base/secrets.yaml` | Which secrets each environment uses | [docs/secrets.md](docs/secrets.md) |
| `.base/nginx.yaml` | Custom proxy directives (headers, buffers, redirects) | [docs/nginx.md](docs/nginx.md) |
| `.base/redirects.yaml` *or* `.csv` | Bulk URL redirects (migrations, SEO) | [docs/nginx.md](docs/nginx.md) |

## Topic Guides

- [Configuration reference](docs/config.md) — `.base/config.yaml` keys, PR templates, internal-only apps
- [Autoscaling](docs/scaling.md) — triggers (CPU, memory, HTTP, cron), behavior presets, scale-to-zero
- [Secrets](docs/secrets.md) — `.base/secrets.yaml`, scope tags, staged-deploy overrides
- [Proxy config & redirects](docs/nginx.md) — custom snippets, bulk URL redirects
- [Multi-brand deploys](docs/multi-brand.md) — run multiple sites from a single app

## Custom Domains

Custom domains are managed in the **Base Portal** (Settings → *Domains*). When you add one, the platform automatically:

1. Issues an HTTPS certificate
2. Configures traffic routing

No workflow changes needed when adding or removing custom domains. HTTP-based autoscaling counts traffic from every domain (internal and custom) against the same environment.

## How It Works

1. Your workflow calls the action with deployment parameters
2. The action reads `.base/*.yaml` from the runner's working directory
3. The action calls the Base Platform API (partner is identified by the API key)
4. The platform applies the configuration to your environment
5. The action polls for health status (when `wait_for_healthy: true`, the default for `deploy`)

## Advanced Configuration

Partners also have a dedicated configuration repository for advanced overrides and custom manifests. Reach out to NorceTech if you need access.
