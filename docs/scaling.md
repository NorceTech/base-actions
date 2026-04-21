# Autoscaling

Autoscaling decides **how many instances** of your app run and **when** to add or remove them.

Two independent parts:

- **Triggers** — what conditions cause scaling (CPU, memory, HTTP traffic, schedule)
- **Behavior** — how fast scaling reacts (protects slow-starting apps)

Enable it in `.base/config.yaml` per environment:

```yaml
environments:
  prod:
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      behaviorPreset: gradual
      triggers:
        - type: cpu
          utilizationPercentage: 70
```

---

## Triggers

You can combine multiple triggers — the platform scales up when **any** trigger exceeds its threshold.

### CPU

Scales based on CPU utilization percentage. Works on every app.

```yaml
triggers:
  - type: cpu
    utilizationPercentage: 70    # Scale up when CPU > 70%
```

| Field | Range | Default |
|-------|-------|---------|
| `utilizationPercentage` | 1–100 | 70 |

Best for CPU-intensive workloads — SSR, image processing, API servers.

### Memory

Scales based on memory utilization percentage. Works on every app.

```yaml
triggers:
  - type: memory
    utilizationPercentage: 80    # Scale up when memory > 80%
```

| Field | Range | Default |
|-------|-------|---------|
| `utilizationPercentage` | 1–100 | 80 |

Best for apps that cache data in memory or handle large payloads.

### HTTP

Scales based on incoming requests per second across all domains (internal and custom).

```yaml
triggers:
  - type: http
    requestsPerSecond: 100         # Scale up when > 100 req/s per instance
  - type: cpu
    utilizationPercentage: 70      # Safety net — always add a CPU trigger
```

| Field | Range | Default |
|-------|-------|---------|
| `requestsPerSecond` | 1–10,000 | 100 |

The threshold is **per instance**. Desired replicas = `ceil(total_rps / threshold)`. Example: with `minReplicas: 3` and `requestsPerSecond: 50`, scaling to 4 instances kicks in at 150 req/s (`50 × 3`).

Best for web apps and APIs. **Always** combine with CPU or memory as a safety net.

### Scheduled (Cron)

Scale to a specific instance count on a schedule. Perfect for known traffic patterns — business hours, campaign launches, seasonal events.

```yaml
triggers:
  - type: cron
    timezone: Europe/Stockholm
    schedule:    '0 8 * * 1-5'       # Scale up at 08:00 on weekdays
    endSchedule: '0 18 * * 1-5'      # Scale down at 18:00 on weekdays
    desiredReplicas: 5
```

| Field | Description |
|-------|-------------|
| `timezone` | IANA timezone (`Europe/Stockholm`, `UTC`, etc.) |
| `schedule` | Cron expression — when to scale up |
| `endSchedule` | Cron expression — when to scale down (optional) |
| `desiredReplicas` | Instance count during the scheduled window |

Common patterns:

| Cron | Meaning |
|------|---------|
| `0 8 * * 1-5` | 08:00 on weekdays |
| `0 6 * * *` | 06:00 every day |
| `0 0 25 11 *` | Midnight on November 25 (Black Friday prep) |
| `30 9 * * 1` | 09:30 every Monday |

### Combining Triggers

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
          schedule:    '0 7 * * 1-5'
          endSchedule: '0 19 * * 1-5'
          desiredReplicas: 5
```

This configuration:

- Keeps **at least 2 instances** running at all times
- Ensures **5 instances** during business hours (Mon–Fri 07:00–19:00)
- Scales further if CPU > 60%, memory > 75%, or traffic > 10 req/s per instance
- Never exceeds **20 instances**
- Uses `gradual` behavior to protect slow-starting apps

---

## Behavior Presets

Behavior controls **how fast** instances are added or removed. Protects slow-starting apps from being killed or starved during scale events.

| Preset | Scale Up | Scale Down | Min Ready | Shutdown | Best For |
|--------|----------|------------|-----------|----------|----------|
| `default` | No limits | No limits | 0s | 30s | Fast-starting apps (Next.js, static sites) |
| `gradual` | +2 per 60s | −1 per 120s, 5 min window | 30s | 30s | Most apps |
| `cautious` | +1 per 120s, 60s window | −1 per 300s, 10 min window | 60s | 60s | Java, .NET, slow starters |
| `custom` | User-defined | User-defined | User-defined | User-defined | Full control |

```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  behaviorPreset: gradual
  triggers:
    - type: cpu
      utilizationPercentage: 70
```

### Custom Behavior

For full control, set `behaviorPreset: custom` and define the behavior explicitly:

```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  behaviorPreset: custom
  behavior:
    scaleUp:
      maxPods: 3
      periodSeconds: 45
      stabilizationWindowSeconds: 0    # 0 = immediate scale-up
    scaleDown:
      maxPods: 1
      periodSeconds: 120
      stabilizationWindowSeconds: 300
    minReadySeconds: 30
    terminationGracePeriodSeconds: 60
  pollingInterval: 15                  # How often metrics are polled (seconds)
  cooldownPeriod: 300                  # Wait after the last scale event (seconds)
  triggers:
    - type: cpu
      utilizationPercentage: 60
```

| Field | Description | Range |
|-------|-------------|-------|
| `behavior.scaleUp.maxPods` | Max instances added per period | 1–10 |
| `behavior.scaleUp.periodSeconds` | Wait between scale-ups | 15–600 |
| `behavior.scaleUp.stabilizationWindowSeconds` | Look-back window for scale-up decisions | 0–600 |
| `behavior.scaleDown.maxPods` | Max instances removed per period | 1–10 |
| `behavior.scaleDown.periodSeconds` | Wait between scale-downs | 60–900 |
| `behavior.scaleDown.stabilizationWindowSeconds` | Look-back window for scale-down decisions | 0–900 |
| `behavior.minReadySeconds` | Instance must stay healthy this long before receiving traffic | 0–300 |
| `behavior.terminationGracePeriodSeconds` | Graceful shutdown time | 30–300 |
| `pollingInterval` | Metric polling frequency | 10–300 |
| `cooldownPeriod` | Wait after last scale event | 60–900 |

The portal Scaling tab also shows a recommendation based on your app's observed startup time.

---

## Scale to Zero

Environments with low or intermittent traffic can scale down to **zero instances** when idle. A new instance is created on the first incoming request (cold start ~10–30 seconds, depending on image size and startup time).

```yaml
environments:
  stage:
    autoscaling:
      enabled: true
      scaleToZero: true
      maxReplicas: 5
      triggers:
        - type: http
          requestsPerSecond: 10
```

| State | With `scaleToZero: true` | Default |
|-------|--------------------------|---------|
| Idle > 5 min | 0 instances | `minReplicas` instances |
| First request after idle | ~10–30s cold start | Instant |
| Active traffic | Scales 1 → `maxReplicas` | Scales normally |

**Good fit:**
- Stage / test environments used only during working hours
- PR environments (enabled automatically — PRs always scale to zero)
- Low-traffic internal tools

**Don't use for:**
- Production customer-facing apps (cold start = bad UX)
- Apps with slow external dependencies (health checks may time out during cold start)

Remove `scaleToZero: true` to restore normal behavior — `minReplicas` applies again.
