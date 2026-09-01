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
`global.dapr.httpMaxRequestSize` explicitly. Environments pinned to Dapr < 1.13
that relied on the old chart default `httpMaxRequestSize: "64"` must now set it
explicitly, or the sidecar falls back to its 4MB default.

## IMPORTANT: environments override these defaults

- After upgrading past 1.0.103, the four components ADOPT the chart tiers automatically even in environments that set `global.resources.default` and left `<component>.resources: {}` — an empty map cannot clear a non-empty chart default (Helm map-merge).
- To keep an environment on its own sizing for a component, set an explicit `<component>.resources` block in the env file (it masks the chart tier), or set `<component>.resources: null` to fall back to that environment's `global.resources.default`.
- `global.resources.default` continues to apply only to components without explicit chart-level blocks (mcp-server, initializer, db-migrator).

## Known gap (deliberate, 2026-09-01 decision)

The daprd sidecar carries NO resource requests/limits (BestEffort, cpu.shares=2).
It was the primary suspect in the intprod 40 ms sidecar->app latency finding.
Fixing it needs `dapr.io/sidecar-cpu-request`-family annotations — out of scope
here by explicit decision; revisit if tail latency persists after these changes.
