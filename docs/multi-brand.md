# Multi-Brand / Multi-Site Deployments

If you run multiple brands or sites from a **single codebase** (e.g. `brand-a.com` and `brand-b.com`), model it as **one app with multiple environments** rather than separate apps per brand.

You get:

- **Shared container image** — one build, deployed everywhere
- **Global config and secrets** — shared settings applied to every site
- **Per-site overrides** — brand-specific settings per environment

---

## Layout

```
App: my-brand-group (single codebase, single container image)
├── brand-a-stage    →  stage.brand-a.com
├── brand-a-prod     →  www.brand-a.com
├── brand-b-stage    →  stage.brand-b.com
└── brand-b-prod     →  www.brand-b.com
```

Each environment is isolated — its own config, secrets, domain, and routing.

---

## Config

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
      requests: { cpu: 100m, memory: 128Mi }
      limits:   { cpu: 250m, memory: 256Mi }
    env:
      - name: BRAND
        value: brand-a
      - name: SITE_URL
        value: 'https://stage.brand-a.com'

  brand-a-prod:
    replicas: 2
    resources:
      requests: { cpu: 500m,  memory: 1.5Gi }
      limits:   { cpu: 2000m, memory: 3Gi }
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      triggers:
        - type: cpu
          utilizationPercentage: 60
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
      requests: { cpu: 100m, memory: 128Mi }
      limits:   { cpu: 250m, memory: 256Mi }
    env:
      - name: BRAND
        value: brand-b
      - name: SITE_URL
        value: 'https://stage.brand-b.com'

  brand-b-prod:
    replicas: 2
    resources:
      requests: { cpu: 500m,  memory: 1.5Gi }
      limits:   { cpu: 2000m, memory: 3Gi }
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      triggers:
        - type: cpu
          utilizationPercentage: 60
        - type: http
          requestsPerSecond: 10
    env:
      - name: BRAND
        value: brand-b
      - name: SITE_URL
        value: 'https://www.brand-b.com'
```

---

## Secrets

```yaml
# .base/secrets.yaml
environments:
  # Shared across every brand and environment
  global:
    - github: SHARED_API_KEY
      vault: shared-api-key

  # Per brand+environment
  brand-a-stage:
    - github: BRAND_A_DB_PASSWORD_STAGE
      vault: database-password

  brand-a-prod:
    - github: BRAND_A_DB_PASSWORD_PROD
      vault: database-password
    - github: BRAND_A_PAYMENT_KEY
      vault: payment-secret-key

  brand-b-stage:
    - github: BRAND_B_DB_PASSWORD_STAGE
      vault: database-password

  brand-b-prod:
    - github: BRAND_B_DB_PASSWORD_PROD
      vault: database-password
    - github: BRAND_B_PAYMENT_KEY
      vault: payment-secret-key
```

---

## Workflow

Use a matrix to build once and deploy every site in parallel:

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
          # Build once — shared image for every brand
          echo "tag=${{ github.sha }}" >> $GITHUB_OUTPUT

  deploy-stage:
    needs: build
    runs-on: ubuntu-latest
    strategy:
      matrix:
        environment: [brand-a-stage, brand-b-stage]
    steps:
      - uses: actions/checkout@v4
        with: { sparse-checkout: .base }
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
        with: { sparse-checkout: .base }
      - uses: NorceTech/base-actions/deploy@v1
        with:
          app: my-brand-group
          environment: ${{ matrix.environment }}
          image_tag: ${{ needs.build.outputs.image_tag }}
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

---

## Mapping

| Concept | Platform representation |
|---------|-------------------------|
| Brand group | App (e.g. `my-brand-group`) |
| Brand + env | Environment (e.g. `brand-a-prod`) |
| Shared image | One container image per app |
| Global secrets | `environments.global` in `.base/secrets.yaml` |
| Per-brand secrets | `environments.<brand>-<env>` in `.base/secrets.yaml` |
| Global env vars | `environments.global.env` in `.base/config.yaml` |
| Per-brand env vars | `environments.<brand>-<env>.env` in `.base/config.yaml` |
