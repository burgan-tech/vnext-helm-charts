# Resource & Scheduling Defaults — Rationale and Environment Overrides

## What the chart defaults are (since chart > 1.0.103)

| Component | requests | limits | Why |
|---|---|---|---|
| orchestrator | 200m / 512Mi | 2 CPU / 2Gi | Steady RSS measured 440-475Mi; CPU limit >= 2 keeps .NET Server GC enabled |
| execution | 100m / 256Mi | 2 CPU / 2Gi | Latency-critical invoke path; headroom for 64Mi payloads |
| worker-inbox / worker-outbox | 75m / 256Mi | 1 CPU / 1Gi | Background processing |

Anti-affinity: each of these components ships a default *preferred* podAntiAffinity
(hostname topology). Override wholesale via `<component>.affinity`.

Body size: `global.dapr.maxBodySize: "64Mi"` emits `dapr.io/max-body-size`. The
deprecated `dapr.io/http-max-request-size` is emitted only if you set
`global.dapr.httpMaxRequestSize` explicitly.

## IMPORTANT: environments override these defaults

An environment values file that sets `global.resources.default` and leaves
`<component>.resources: {}` will IGNORE the tiered defaults above (component-empty
falls back to the ENVIRONMENT's global default). To adopt the tiers in an
environment, either delete the env's `global.resources.default` override or copy the
per-component blocks into the env file.

## Known gap (deliberate, 2026-09-01 decision)

The daprd sidecar carries NO resource requests/limits (BestEffort, cpu.shares=2).
It was the primary suspect in the intprod 40 ms sidecar->app latency finding.
Fixing it needs `dapr.io/sidecar-cpu-request`-family annotations — out of scope
here by explicit decision; revisit if tail latency persists after these changes.
