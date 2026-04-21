# Secrets

Secrets are stored in the platform's secure vault and delivered to your app at runtime as environment variables.

Two parts:

1. **`.base/secrets.yaml`** — declares which secrets each environment uses and where they come from
2. **`sync-secrets` action** — pushes the actual secret values from GitHub Secrets into the platform vault

Once a secret is in the vault, **every deploy** automatically mounts it into the matching environments based on its scope tags. You only re-run `sync-secrets` when a value changes.

---

## `.base/secrets.yaml`

Maps GitHub secret names to vault entries, scoped per environment.

```yaml
environments:
  # Global secrets — synced to every environment
  global:
    - github: SHARED_API_KEY
      vault: shared-api-key

  # Per-environment secrets
  stage:
    - github: DATABASE_PASSWORD_STAGE
      vault: database-password
    - github: API_SECRET_STAGE
      vault: api-secret

  prod:
    - github: DATABASE_PASSWORD_PROD
      vault: database-password
    - github: API_SECRET_PROD
      vault: api-secret
    - github: STRIPE_SECRET_KEY
      vault: stripe-secret-key
```

| Field | Description |
|-------|-------------|
| `github` | Name of the GitHub Actions secret on your repo |
| `vault` | Name the secret will have in the platform vault (and inside the running container) |

**Naming rules for vault entries**

- Global secrets are stored as `app-<vault-name>` (e.g. `app-shared-api-key`)
- Per-environment secrets are stored as `app-<env>-<vault-name>` (e.g. `app-prod-database-password`)
- Global secrets are **always** synced, even when targeting a single environment

---

## Scope Tags

Each vault entry carries a scope tag that controls which environments see it.

| Tag | Scope |
|-----|-------|
| `environment=all` | Every environment, including PR previews and staged canary |
| `environment=<env>` | One named environment (e.g. `environment=prod`) |
| `environment=<env>-preview` | Overrides applied during staged (canary) deploys |
| `environment=preview` | All PR environments |

### Staged-Deploy Overrides

Use `<env>-preview` to inject a different secret value during the canary phase of a staged deploy:

```yaml
# .base/secrets.yaml
environments:
  global:
    - github: SHARED_API_KEY
      vault: shared-api-key

  prod:
    - github: STRIPE_SECRET_KEY
      vault: stripe-secret-key

  prod-preview:                                # Active only during staged deploys on prod
    - github: STRIPE_TEST_KEY
      vault: stripe-secret-key                 # Same vault name → overrides the live value
```

During a staged deploy on `prod`, the canary instances receive:

```
environment=all   +   environment=prod   +   environment=prod-preview
```

After promotion the preview scope is removed — live instances fall back to `environment=all` + `environment=prod`.

---

## Syncing Values

Use the [`sync-secrets` action](../sync-secrets/README.md) to push values from GitHub Actions to the platform vault. The action reads `.base/secrets.yaml` to know what to sync; the values come from `env:` inputs in your workflow.

```yaml
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
