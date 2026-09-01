# Resource & Scheduling Defaults — Rationale and Environment Overrides

## Sizing precedence (since chart > 1.0.104)

Every component rendered through the `vnext.resources` helper is sized by the first
non-empty source in this order:

1. `<component>.resources` — an explicit block always wins.
2. `global.resources.default` — one knob (typically set in an environment values file)
   that sizes every component whose `resources` is empty.
3. `<component>.resourcesFallback` — the chart-shipped measured defaults below. Applies
   only when neither of the above is set. Chart-managed: do not edit from an environment.

So an environment that sets `global.resources.default` and leaves `resources: {}` gets
its own sizing on all of these components; delete the global to fall back to the measured
defaults.

## What the measured fallbacks are

| Component | requests | limits | Why |
|---|---|---|---|
| orchestrator | 200m / 512Mi | 2 CPU / 2Gi | Steady RSS measured 440-475Mi; CPU limit >= 2 keeps .NET Server GC enabled |
| execution | 100m / 256Mi | 2 CPU / 2Gi | Latency-critical invoke path; headroom for 64Mi payloads |
| worker-inbox / worker-outbox | 75m / 256Mi | 1 CPU / 1Gi | Background processing |
| mcp-server / db-migrator | 100m / 256Mi | 1 CPU / 2Gi | The chart's former global default |

Anti-affinity: each of these components ships a default *preferred* podAntiAffinity
(hostname topology). Override wholesale via `<component>.affinity`.

Body size: `global.dapr.maxBodySize: "64Mi"` emits `dapr.io/max-body-size`. The
deprecated `dapr.io/http-max-request-size` is emitted only if you set
`global.dapr.httpMaxRequestSize` explicitly. Environments pinned to Dapr < 1.13
that relied on the old chart default `httpMaxRequestSize: "64"` must now set it
explicitly, or the sidecar falls back to its 4MB default.

## Version note

Chart 1.0.104 briefly shipped the measured tiers directly in each component's
`resources` key. That made them unoverridable from an environment's
`global.resources.default` (Helm map-merge: `resources: {}` cannot clear a non-empty
chart default). The tiers were therefore moved to `resourcesFallback` keys, restoring
the empty-means-global contract described above. The orchestrator-initializer job sets
no resources at all (neither a chart block nor the global default applies to it).

## Dapr sidecar sizing & shutdown (environment responsibility, by design)

The chart deliberately does NOT emit `dapr.io/sidecar-*` sizing or the shutdown
annotations — environments supply them per component via `podAnnotations`, which keeps
them flexible and avoids duplicate annotation keys against user values. DO set them:
a BestEffort daprd (cpu.shares=2) was the primary suspect in the intprod 40 ms
sidecar->app latency finding (measured daprd usage: 1.5-5.4m CPU, 44-72Mi). A known-good
starting point:

```yaml
podAnnotations:
  dapr.io/config: appconfig
  dapr.io/sidecar-cpu-request: "50m"
  dapr.io/sidecar-cpu-limit: "200m"        # raise to 300m if invoke tail latency persists
  dapr.io/sidecar-memory-request: "128Mi"
  dapr.io/sidecar-memory-limit: "256Mi"    # raise to 512Mi if 64Mi payloads are common
  dapr.io/graceful-shutdown-seconds: "20"  # INTEGER — "20s" fails to parse (silently)
  dapr.io/block-shutdown-duration: "30s"   # Go DURATION — unlike the integer above
```

Do NOT also set `dapr.io/max-body-size` in podAnnotations — the chart already emits it
from `global.dapr.maxBodySize` and a duplicate key resolves unpredictably. block +
graceful (30s + 20s = 50s above) must fit inside `global.terminationGracePeriodSeconds`
(chart default 60; the Kubernetes default of 30 is too short and SIGKILLs mid-shutdown).
