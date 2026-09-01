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

## Dapr sidecar sizing & shutdown (closes the former BestEffort gap)

`global.dapr.sidecarResources` (defaults: request 50m/128Mi, limit 200m/256Mi) emits the
`dapr.io/sidecar-*` annotations on every dapr-enabled pod, so daprd no longer runs
BestEffort (cpu.shares=2) — the primary suspect in the intprod 40 ms sidecar->app
latency finding. Measured daprd usage: 1.5-5.4m CPU, 44-72Mi.

Shutdown: `global.dapr.gracefulShutdownSeconds: "20"` (INTEGER seconds — `"20s"` fails to
parse) and `global.dapr.blockShutdownDuration: "30s"` (Go duration). Their sum must fit
inside `global.terminationGracePeriodSeconds` (default 60; Kubernetes' own default of 30
is too short). The db-migrator Job deliberately gets only the sizing annotations, not the
shutdown ones. If an environment's `podAnnotations` still set any `dapr.io/sidecar-*` or
shutdown keys, remove them there — duplicate annotation keys resolve unpredictably.
