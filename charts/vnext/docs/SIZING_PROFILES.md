# Sizing Profiles — Redis/Dapr Connection Budget, Replicas and Resources

## TL;DR

The chart's own defaults are **nonprod-sized**: 1 replica per component, 1 Redis node, no
HPA. **Every production install must pass one of the three prod profiles.**

```bash
helm upgrade --install vnext-<domain> oci://ghcr.io/burgan-tech/vnext/vnext \
  -f charts/vnext/profiles/values-low.yaml \
  -f <your-domain-values>.yaml
```

| Profile | Use for | App pods (floor → ceiling) |
|---|---|---|
| `values-nonprod.yaml` | dev / test / staging. Identical to the chart default. | 4 (fixed) |
| `values-low.yaml` | Prod, light or business-hours-only traffic. **Expected to fit most of the 50+ domains.** | 6 → 20 |
| `values-normal.yaml` | Prod, steady traffic. Orchestration 10 / execution 5 / inbox 3 / outbox 3 as the HPA floor. | 21 → 53 |
| `values-high.yaml` | Prod, the few hottest domains only. | 42 → 106 |

Start at `low` and move up on **evidence**, not expectation. Moving a domain up is a
values change and a rollout; it is not expensive to do later.

## The measured baseline (since chart > 1.0.109)

Measured on `bmprod` / `intprod-vnext-contract` — the highest-volume vNext domain by log
volume — on **2026-09-09**, via `oc adm top pods` equivalents plus the live pod specs.

| Container | CPU measured | Memory RSS | Was configured as |
|---|---|---|---|
| orchestrator (5 pods) | 1.0–1.4m | **520–541Mi** | req 500m / 512Mi, lim 2 / 4Gi |
| execution (10 pods) | 0.7–1.5m | 128–149Mi | req 500m / 512Mi, lim 2 / 4Gi |
| worker-inbox (10 pods) | 0.6–1.0m | 118–132Mi | req 500m / 512Mi, lim 2 / 4Gi |
| worker-outbox (10 pods) | 0.6–1.0m | 110–115Mi | req 500m / 512Mi, lim 2 / 4Gi |
| daprd (every pod) | 0.6–2.0m | 48–81Mi | req 50m / 128Mi, lim 200m / 256Mi |
| redis (3 pods) | **12–17m** | **58–84Mi** | req 50m / 64Mi, lim 1 CPU / 4Gi |
| sentinel (3 pods) | 12.8–13.4m | 11–12Mi | req 50m / 32Mi, lim 1 CPU / 512Mi |

Two findings drive everything below.

**Redis is not resource-starved — it is idle.** 12–17 millicores and under 90Mi against a
1 CPU / 4Gi limit. Sentinel burns *more* CPU than Redis, which is what a Redis doing
almost nothing looks like: Sentinel's fixed polling dominates. So **do NOT add Redis
replicas or Redis resources to fix connection errors.** Nothing about the node is the
constraint.

**The uniform `global.resources.default: 500m/512Mi` was wrong in both directions.** The
orchestrator's RSS (530Mi) *exceeded* its 512Mi request, making the request-facing
component the first one evicted under node memory pressure; execution and the workers
requested 3.5–4.5x what they use.

## Why the connection pool exhausted

Not capacity — **connection count**. Five Dapr components are backed by Redis:
`state.redis`, `pubsub.redis`, a second `pubsub.redis` for broadcast,
`configuration.redis` and `lock.redis`. Before chart 1.0.110:

- Each templated **only `redisHost`**. There was no `poolSize`, `minIdleConns`,
  `dialTimeout`, `readTimeout`, `writeTimeout`, `maxRetries` or `maxRetryBackoff` — and
  no values key to set them.
- With `poolSize` unset, the go-redis client inside `daprd` sizes its pool from
  `GOMAXPROCS`, i.e. the **node's** core count — not the sidecar's 200m CPU limit. On
  64-core-class workers that is hundreds of connections per component.
- **None of the five declares `scopes`**, so every sidecar in the namespace loads all
  five. A domain running ~35 pods therefore opens **~175 independent pools**.
- `maxclients` was not settable at all; Redis's built-in default is 10000.

The fix is an explicitly bounded pool, which is correct regardless of what the client's
implicit default happens to be on a given node size.

### The budget, and how to check yours

```
connections per domain  =  pods  x  5 components  x  global.dapr.redis.poolSize
```

It must stay under `redis-sentinel.redis.network.maxClients`, with headroom for the
reconnect burst that follows a Sentinel failover.

| Profile | `poolSize` | at floor | at HPA ceiling | `maxClients` |
|---|---|---|---|---|
| nonprod | 5 | 100 | n/a (HPA off) | 1000 |
| low | 10 | 300 | 1000 | 5000 |
| normal | 20 | 2100 | 5300 | 10000 |
| high | 20 | 4200 | **10600** | 20000 |

Note `high` is the reason `maxClients` is raised to 20000: at its ceiling it would
otherwise cross Redis's 10000 default and Redis would start refusing connections — which
surfaces in the apps as exactly the pool errors this change addresses.

**If you need more headroom, narrow `scopes` before raising `maxClients`.** Restricting
which app-ids load each component is the single largest reduction available:

```yaml
global:
  dapr:
    redis:
      scopes:
        lock: ["vnext-<domain>-app"]
        configuration: ["vnext-<domain>-app", "vnext-<domain>-execution-app"]
```

Empty (the default) preserves the historical behaviour of loading everywhere. **Verify
actual usage first** — a component a running app needs but is not scoped to fails at
runtime, not at render time.

## Replicas

The HPA floor *is* the profile's replica count. `replicas` is omitted from the Deployment
whenever `autoscaling.enabled` is true, so `helm upgrade` never fights the HPA.

| Component | nonprod | low | normal | high |
|---|---|---|---|---|
| orchestrator | 1, HPA off | 2 / 6 | 10 / 20 | 20 / 40 |
| execution | 1, HPA off | 2 / 6 | 5 / 15 | 10 / 30 |
| worker-inbox | 1, HPA off | 1 / 4 | 3 / 9 | 6 / 18 |
| worker-outbox | 1, HPA off | 1 / 4 | 3 / 9 | 6 / 18 |
| redis-sentinel | **1, quorum 1** | 3, quorum 2 | 3, quorum 2 | 3, quorum 2 |

Prod HPA targets are 75% CPU and 75% memory. HPA needs requests present to compute
utilisation at all — every profile sets them, so this holds.

**Sentinel quorum must match the node count.** The chart historically shipped
`replicaCount: 1` against the subchart's `sentinel.quorum: 2` — a pair that can never
elect a master. `NOTES.txt` warned; nothing blocked it. Nonprod now ships `1`/`1` and all
prod profiles ship `3`/`2`. If you override `replicaCount`, override `quorum` to
`(replicaCount / 2) + 1`.

## Resources per component

Memory requests come from measured RSS plus .NET GC headroom. **CPU requests are
calibrated for HPA responsiveness, not derived from the measurement** — measured idle CPU
of 1–2m says nothing about peak, and a request that low would make the HPA scale on noise.

| Component | nonprod (default) | low | normal | high | Why |
|---|---|---|---|---|---|
| orchestrator | 200m / 640Mi → 2 / 2Gi | 150m / 640Mi → 2 / 2Gi | 300m / 768Mi → 2 / 2Gi | 500m / 1Gi → 3 / 3Gi | Request must exceed measured 520–541Mi RSS; request-facing |
| execution | 100m / 256Mi → 2 / 2Gi | 100m / 256Mi → 2 / 2Gi | 200m / 320Mi → 2 / 2Gi | 400m / 512Mi → 3 / 2Gi | Latency-critical invoke path; headroom for 64Mi payloads |
| worker-inbox | 75m / 256Mi → 1 / 1Gi | 75m / 256Mi → 1 / 1Gi | 150m / 256Mi → 2 / 1Gi | 300m / 384Mi → 2 / 1.5Gi | Background processing, not client-facing |
| worker-outbox | 75m / 256Mi → 1 / 1Gi | 75m / 256Mi → 1 / 1Gi | 150m / 256Mi → 2 / 1Gi | 300m / 384Mi → 2 / 1.5Gi | Background processing, not client-facing |
| redis | 50m / 192Mi → 500m / 1Gi | 100m / 256Mi → 500m / 1Gi | 200m / 512Mi → 1 / 2Gi | 500m / 1Gi → 2 / 4Gi | Idle at every observed load; limit doubles as `maxmemory` |
| sentinel | 25m / 32Mi → 200m / 256Mi | 25m / 32Mi → 200m / 256Mi | 50m / 64Mi → 500m / 512Mi | 50m / 64Mi → 500m / 512Mi | Fixed polling cost only |

Do **NOT** drop the orchestrator or execution CPU **limit** to 1 CPU. `ProcessorCount`
would become 1 and .NET falls back to Workstation GC. That is why every profile keeps
those limits at 2 CPU or more.

**`resources.redis.limits.memory` is also the `maxmemory` knob.** Unless
`redis.maxMemory` is set, `maxmemory = 0.78 x limits.memory`. So the `normal` profile's
2Gi limit yields ~1.6Gi of `maxmemory` against an observed ~84Mi dataset. Raise the limit
to raise `maxmemory`; there is no separate profile knob.

Profiles set per-component `resources` (precedence 1) and deliberately leave
`global.resources.default` **empty** — see [RESOURCE_TUNING.md](RESOURCE_TUNING.md) for
the precedence rules. **One value cannot serve a 530Mi orchestrator and a 115Mi outbox
worker.** If you set `global.resources.default` *alongside* a profile, the profile's
per-component blocks win and your global is silently ignored.

### Dapr sidecar

Sidecar sizing is an environment concern by chart design (the chart does not emit
`dapr.io/sidecar-*`), so each prod profile carries it in `podAnnotations`:

| | low | normal | high |
|---|---|---|---|
| `sidecar-cpu-request` / `-limit` | 50m / 200m | 100m / 500m | 150m / 1000m |
| `sidecar-memory-request` / `-limit` | 96Mi / 384Mi | 200Mi / 512Mi | 256Mi / 768Mi |

**These are deliberately well above the measured idle figure, and that is the point.**
daprd at rest is only 0.6–2.0m CPU and 48–81Mi RSS, but idle RSS is the wrong basis for
sizing it: the chart emits `dapr.io/max-body-size: 64Mi`, so a **single** in-flight body
can add ~64Mi to the sidecar's working set, and each profile allows 5 / 10 / 20 concurrent
pub/sub handler invocations respectively. Two rules follow:

- the memory **request** stays above `baseline + one 64Mi body`, so the sidecar does not
  become the first eviction candidate on a pod that sits on every request path;
- the memory **limit** covers several concurrent bodies. A 256Mi limit tolerates only two
  before OOM, which is why even `low` is at 384Mi.

daprd also now holds up to `poolSize x 5 components` Redis connections per sidecar, each
with its own read/write buffers.

CPU limits do not reserve node capacity, so they are cheap headroom. CPU and memory
**requests** do reserve, and the sidecar is multiplied by every pod — see the cost note
below before raising them further.

`dapr.io/graceful-shutdown-seconds` is an **integer** (`"20s"` fails to parse, silently);
`dapr.io/block-shutdown-duration` is a Go **duration** (`"30s"`). Their sum must fit
inside `global.terminationGracePeriodSeconds` (60).

**Known nonprod trade-off:** because `values-nonprod.yaml` is kept byte-identical to the
chart default, it sets no sidecar annotations, so nonprod `daprd` runs **BestEffort**
(`cpu.shares=2`). That was the primary suspect in the intprod 40 ms sidecar→app latency
finding. If a nonprod domain shows sidecar latency, add the `low` profile's
`podAnnotations` block to that domain's values.

## Cost

Comparing the resource *shape* alone, at the replica floor production runs today
(5/5/3/3 = 16 app pods):

| | `global.resources.default` (before) | per-component (after) |
|---|---|---|
| App CPU requests | 16 x 500m = **8.0** | **3.4** (−57%) |
| App memory requests | 16 x 512Mi = **8.0Gi** | **6.8Gi** (−15%) |

At the `normal` profile's own floor (21 app pods) it is **4.9 CPU** — still well below
today's 8.0 despite 31% more pods — and **10.6Gi** memory, up from 8.0Gi. That memory
increase is the doubled orchestrator count plus raising its request above measured RSS: a
deliberate trade of memory for stability, not an accident.

**The sidecars are not free, and they scale with pod count.** At the `normal` floor of 21
pods, `100m / 200Mi` requests add **2.1 CPU and 4.1Gi per domain** (at the HPA ceiling of
53 pods: 5.3 CPU and 10.4Gi). That is roughly double what a `50m / 96Mi` sidecar would
reserve, and it eats into the app-side CPU saving: net saving at the `normal` floor is
about **2 CPU per domain** rather than 3.1. The trade is deliberate — an OOMKilled or
CPU-starved sidecar takes the whole pod's traffic with it, and a BestEffort daprd was the
primary suspect in the intprod 40 ms sidecar→app latency finding — but if you are
capacity-constrained, the sidecar **requests** are the first place to look, not the limits.

Across 50 domains the app-side CPU saving is roughly **150–230 CPU** depending on the
profile mix; sidecar requests give back about **50 CPU** of that at `normal`.

## Risks and known defects

These are **not** fixed by this change. Read before rolling out.

1. **Redis has no Prometheus coverage.** Verified 2026-09-09: `bmprod` scrapes *no*
   metrics for `intprod-vnext-*`. `redis_connected_clients` is empty for these namespaces
   even though every `redis-sentinel` pod runs a `metrics` exporter container — other
   namespaces such as `intprod-kkb-redis` do report it, so the exporter works and simply
   is not scraped. `dapr.io/metrics-enabled` is `true` on every app pod and also
   unscraped; there is no cAdvisor data either. **The numbers in this document are a
   calibrated starting point, not a measured optimum** — you cannot currently confirm a
   connection budget or an HPA threshold from metrics. Fixing this is the prerequisite
   for the next round of tuning.

2. **`redis-sentinel.redis.persistence.{maxMemory,maxMemoryPolicy,appendonly}` are dead
   keys.** The subchart reads them at `redis.maxMemory`, `redis.maxMemoryPolicy` and
   `redis.appendonly`. Anything set under `persistence:` is **silently ignored** — the
   production values file's `maxMemory: "2560mb"`, `noeviction` and `appendonly: false`
   have never taken effect. Left as-is deliberately; fixing the nesting would change
   runtime behaviour and needs its own change.

3. **Redis is effectively diskless despite holding a PVC.** `redis.extraConfig` sets
   `appendonly no` and `save ""`, and extraConfig is emitted **last**, so it wins over
   the persistence block — while `persistence.enabled: true` still binds **3 x 8Gi per
   domain (~1.2Ti across 50 domains)** that Redis never writes to. A quorum loss
   discards all state *and* all in-flight pub/sub streams. Acceptable only if every
   event is re-derivable from Postgres via the outbox.

4. **`maxmemory-policy: noeviction` is a write-failure cliff, not an eviction policy.**
   At `maxmemory`, Redis **rejects writes** rather than evicting. Safe today (~84Mi
   against ~1.6Gi) but it needs an alert, which item 1 currently prevents.

5. **`redis-sentinel.securityContext.{runAsNonRoot,runAsUser,runAsGroup,fsGroup}` is
   dead** in the flat form the parent values use — the subchart reads only
   `securityContext.kubernetes` and `securityContext.openshift`.

6. **`vnext.validateValues` never executes.** No values-level guardrail fires, including
   `replicaCount` vs `autoscaling.minReplicas` and the quorum/replica pairing above.

7. **`mcp-server.dapr` is dead config** — the value enables it but the mcp-server
   Deployment never calls `vnext.daprAnnotations`, so no sidecar is injected.

8. **No PodDisruptionBudget for the app components** (only `redis-sentinel` has one), and
   no `topologySpreadConstraints` anywhere — only a *preferred* `podAntiAffinity`, which
   a busy scheduler is free to ignore.

## Migrating an existing production domain

The current environment files conflict with each other. `prod-values.yaml` sets fixed
`replicaCount` 10/10/5/5 with worker HPA off; `prod-resource-values.yaml` enables HPA at
min 5/5/3/3. **Applied together the HPA branch wins and the effective floor drops to
5/5/3/3** — which is what the live cluster shows for the orchestrator. Live inbox and
outbox sit at 10 pods, above *both* files' `maxReplicas: 6`, so the deployed state matches
neither file.

Reconcile that first, then:

1. Delete `global.resources.default` and every per-component `resources` / `autoscaling`
   block from your environment file.
2. Add `-f profiles/values-<low|normal|high>.yaml` **before** your domain values file, so
   domain-specific keys still win.
3. Keep only genuinely per-domain values in your own file: `global.appDomain`,
   `global.externalVault.*`, ingress hosts, `appEnvConfig`.
4. Diff before applying: `helm template ... > new.yaml` against the current release.

**This upgrade restarts Redis.** The `redis.conf` contents change (`maxclients` is added,
and `maxmemory` moves with the memory limit), which changes the StatefulSet's
`checksum/config` and `checksum/scripts` annotations and therefore rolls the Redis pods.
On a 3-node prod topology that means one Sentinel-driven failover; on a nonprod
single-node topology it is a brief full outage of that domain's cache and pub/sub. Because
Redis is effectively diskless (Risk 3), **anything in Redis at that moment is lost** —
schedule it accordingly, and confirm in-flight work is drained or replayable first.

The app Deployments also roll, since their `resources` and `podAnnotations` change.

## Verification

```bash
helm dependency build charts/vnext

# every profile renders
for p in nonprod low normal high; do
  helm template t charts/vnext -f charts/vnext/profiles/values-$p.yaml > /tmp/$p.yaml || echo "FAIL $p"
done

# the nonprod profile must stay identical to the chart default
# (the redis/sentinel passwords are randAlphaNum per render, so exclude them)
helm template t charts/vnext > /tmp/default.yaml
diff <(grep -vE 'redis-password:|sentinel-password:' /tmp/default.yaml) \
     <(grep -vE 'redis-password:|sentinel-password:' /tmp/nonprod.yaml)

# the pool bound reaches all five Redis components
grep -c 'name: poolSize' /tmp/normal.yaml        # expect 5

# maxclients, maxmemory and a coherent quorum
grep -E 'maxclients|maxmemory ' /tmp/normal.yaml
grep -oE 'sentinel monitor mymaster \S+ [0-9]+ [0-9]+' /tmp/normal.yaml

# replicas are HPA-owned in prod, fixed in nonprod
grep -c 'kind: HorizontalPodAutoscaler' /tmp/normal.yaml   # expect 4
grep -c 'kind: HorizontalPodAutoscaler' /tmp/nonprod.yaml  # expect 0
```

After rollout, re-measure one domain and confirm the pool errors stop in
`logs-production_vnext_<domain>_*`. That is the only real proof available until item 1
in Risks is addressed.
