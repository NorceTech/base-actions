# Proxy Config & Redirects

Two optional files in your repo let you shape how the platform's edge proxy handles requests:

- `.base/nginx.yaml` — custom proxy directives (headers, timeouts, redirects, maintenance mode)
- `.base/redirects.yaml` (or `.csv`) — bulk URL redirects (migrations, SEO restructures)

Both files are **optional**. The next deploy picks up changes automatically — no workflow changes required.

---

## Custom Proxy Config — `.base/nginx.yaml`

Override proxy defaults by adding NGINX-style snippets.

```yaml
# .base/nginx.yaml
snippets:
  - context: http.server
    value: |
      proxy_buffer_size 16k;
      proxy_buffers 4 16k;
      proxy_busy_buffers_size 32k;
```

### Contexts

`context` controls where the snippet is injected.

| Context | Scope | Use case |
|---------|-------|----------|
| `http.server` | Per server block | Proxy buffers, headers, timeouts (most common) |
| `http.server.location` | Per location block | Per-path overrides |
| `http` | Global http block | Map variables, shared settings |
| `main` | Top-level | Worker settings (rarely needed) |

### Examples

**Larger proxy buffers** (needed for Supabase / Azure auth with big tokens):

```yaml
snippets:
  - context: http.server
    value: |
      proxy_buffer_size 16k;
      proxy_buffers 4 16k;
      proxy_busy_buffers_size 32k;
```

**Custom cache headers per location:**

```yaml
snippets:
  - context: http.server.location
    value: |
      add_header Cache-Control "public, max-age=3600";
```

**Redirect `www` to naked domain (301):**

```yaml
snippets:
  - context: http.server
    value: |
      if ($host = 'www.example.com') {
        return 301 https://example.com$request_uri;
      }
```

**Redirect old paths to new paths:**

```yaml
snippets:
  - context: http.server.location
    value: |
      rewrite ^/old-page$ /new-page permanent;
      rewrite ^/blog/(.*)$ /articles/$1 permanent;
```

**Redirect an entire old domain to a new one:**

```yaml
snippets:
  - context: http.server
    value: |
      if ($host = 'old-brand.com') {
        return 301 https://new-brand.com$request_uri;
      }
      if ($host = 'www.old-brand.com') {
        return 301 https://new-brand.com$request_uri;
      }
```

**Force HTTPS on specific routes:**

```yaml
snippets:
  - context: http.server.location
    value: |
      if ($scheme = 'http') {
        return 301 https://$host$request_uri;
      }
```

**Maintenance mode (503 with retry):**

```yaml
snippets:
  - context: http.server.location
    value: |
      return 503;
      add_header Retry-After 3600;
```

> `return` (simple, whole-URL) and `rewrite` (pattern-based path rewrites) are both allowed. Use `permanent` (301) for SEO-safe redirects, `redirect` (302) for temporary ones.

### Blocked Directives

For security, these directives return a 400 error at deploy time:

`proxy_pass`, `upstream`, `include`, `env`, `lua_*`, `ssl_certificate`, `load_module`

---

## Bulk Redirects — `.base/redirects.yaml` / `.csv`

For large redirect lists (migrations, SEO restructures, brand changes), use a dedicated file instead of raw proxy snippets. Handles lists in the six figures — see [Limits](#limits) for the exact ceiling and what happens when you reach it.

### YAML format (recommended for < 1,000 entries)

```yaml
# .base/redirects.yaml
redirects:
  - from: /gamla-kategorin/produkt-a
    to:   /nya-kategorin/produkt-a
    status: 301
  - from: /kampanj-2023
    to:   https://example.com/kampanjer
    status: 301
```

### CSV format (recommended for large lists)

```csv
# .base/redirects.csv
from,to,status
/gamla-kategorin/produkt-a,/nya-kategorin/produkt-a,301
/kampanj-2023,https://example.com/kampanjer,301
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `from` | Yes | Source path — must start with `/`, no whitespace or quotes |
| `to` | Yes | Target path (starts with `/`) or absolute URL (`https://…`) |
| `status` | No | HTTP status: `301` (default), `302`, `307`, or `308` |

### Limits

- Max **16 proxy-config chunks** per app. In practice that is roughly **120,000
  redirects** with typical product URLs, and up to **160,000** if your paths are
  short. The binding limit is URL length, not entry count — long URLs fill a chunk
  before it reaches its entry cap.
- Max **2,048 characters** per `from` and `to`
- Paths cannot contain whitespace or quotes

The 16-chunk ceiling comes from the Gateway API specification (max 16 filters per
route) and **cannot be raised** — not per app, not on request. A deploy that would
exceed it fails with an explicit error naming your entry count; it never ships a
partial redirect list.

**Do not build around the ceiling.** It is a platform limit, not a starting point to
design around. Splitting one site's redirect list across several apps to get more
capacity is **not a supported configuration** — if such a setup misbehaves, we cannot
help you debug it. If you are approaching the limit, talk to us first.

The usual way to shrink a list is to stop enumerating. Entries that share a shape — a
whole retired category tree, a locale prefix — normally collapse into a single pattern
rewrite in `.base/nginx.yaml`, which costs no chunk budget at all. See
[Coexistence](#coexistence).

### Performance

- Redirects use **O(1) lookup** — speed is independent of list size
- Config reload takes < 1 second at 40k entries, < 5 seconds at 160k entries
- No memory overhead per request

### How it scales

Very large lists are automatically split into multiple proxy-config chunks under the hood. You don't need to think about it — both small and large lists activate simultaneously on deploy.

A chunk holds 7,500-10,000 entries depending on URL length. Typical output:

- 40k redirects → 4-6 chunks
- 100k redirects → 10-14 chunks
- ~120k redirects → at or near the 16-chunk ceiling with typical URLs

### Rollback

Remove or empty the file and deploy. Stale entries are cleaned up automatically.

### Redirects and domains

Redirects apply to the domains an app serves **as of its last deploy**. Adding a
domain to an app, or moving a domain between apps, does not activate redirects on
that domain by itself — **deploy the app that now owns the domain.**

Until you do, requests to that domain reach your application directly and your
redirects do not fire. Nothing errors; the redirects are simply absent.

This comes up whenever an app's set of domains changes — a new market domain, a domain
handed over from another app. After adding `stage.example.dk` to `myapp`, deploy
`myapp`.

### Coexistence

`.base/nginx.yaml` and `.base/redirects.yaml` can be used in the same app. Both are applied to the same routing setup at deploy time.
