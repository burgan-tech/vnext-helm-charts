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
| `values-nonprod.yaml` | dev / test / staging. Identical to the chart default. | 8 (fixed) |
| `values-low.yaml` | Prod, light or business-hours-only traffic. **Expected to fit most of the 50+ domains.** | 6 → 20 |
| `values-normal.yaml` | Prod, steady traffic. Orchestration 10 / execution 5 / inbox 3 / outbox 3 as the HPA floor. | 21 → 53 |
| `values-high.yaml` | Prod, the few hottest domains only. | 42 → 106 |

Start at `low` and move up on **evidence**, not expectation. Moving a domain up is a
values change and a rollout; it is not expensive to do later.

> **Upgrading an existing release?** `redis-sentinel.redis.persistence.enabled` is now
> `false` (the PVC was never written to — Risk 3). Because `volumeClaimTemplates` is
> immutable, `helm upgrade` **fails** until the Redis StatefulSet is deleted. Follow
> [the migration procedure](#migrating-an-existing-release-off-the-redis-pvc) first.

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
connections per domain = SUM over hosts ( pods_host x redisComponents_host x poolSize )

  orchestrator  4   state, lock, pubsub, pubsub-broadcast
  execution     2   state, pubsub
  worker-inbox  1   pubsub
  worker-outbox 1   pubsub
  db-migrator   1   lock      (a Job -- transient, but it does hold a pool)
```

It is a per-host sum rather than `pods x components` because each sidecar loads only the
components it is scoped to — see [Scoping](#scoping-what-actually-cut-the-budget-in-half).

It must stay under `redis-sentinel.redis.network.maxClients`, with headroom for the
reconnect burst that follows a Sentinel failover (roughly double the steady figure).

| Profile | `poolSize` | at floor | at HPA ceiling | `maxClients` |
|---|---|---|---|---|
| nonprod | 5 | 80 | n/a (HPA off) | 1000 |
| low | 10 | 140 | 440 | 5000 |
| normal | 20 | 1120 | 2560 | 10000 |
| high | 20 | 2240 | 5120 | 20000 |

`high` keeps `maxClients: 20000` even though 5120 fits under Redis's 10000 default: a
Sentinel failover reconnects the whole fleet at once, and 5120 x 2 would cross it.

### Scoping: what actually cut the budget in half

Before scoping, all five components were unscoped, so **every** sidecar in the namespace
loaded **all** of them — a ~35-pod domain opened ~175 independent pools. The components
are now scoped to the hosts that consume them, and the `configuration` component was
deleted outright:

| Component | Loaded by | Why |
|---|---|---|
| `state` | orchestrator, execution | platform cache; `StateStoreTask`/`CacheAsideTask` fall back to it |
| `lock` | orchestrator, **db-migrator** | `InstanceStatusLock` etc.; `SchemaMigrationRunner` |
| `pubsub` | orchestrator, execution, both workers | outbox nudge, subscriptions, domain tasks |
| `pubsub-broadcast` | orchestrator | held for a planned invalidation path; `DAPR_PUBSUB_BROADCAST_STORE_NAME` is emitted on the orchestrator so it can address it |
| `configuration` | **deleted** | no code calls the Dapr Configuration API |
| `secretstore` | everyone (unscoped) | every Redis component's `auth.secretStore` |

That is the source of the numbers above: 4 components on the orchestrator, 2 on
execution, 1 on each worker. The mapping comes from
`vnext/docs/runtime/dapr-component-footprint.md`, which derives it from **consumption
points in code** rather than DI registrations (a registration is lazy and proves nothing).

**A component and the env name that resolves it must be kept or dropped together.** Each
`DAPR_*_STORE_NAME` is emitted only on the hosts scoped to the matching component, so the
env matrix is a mirror image of the table above:

| Key | orchestrator | execution | worker-inbox | worker-outbox | db-migrator |
|---|---|---|---|---|---|
| `DAPR_STATE_STORE_NAME` | ✅ | ✅ | — | — | — |
| `DAPR_LOCK_STORE_NAME` | ✅ | — | — | — | ✅ |
| `DAPR_PUBSUB_STORE_NAME` | ✅ | ✅ | ✅ | ✅ | — |
| `DAPR_PUBSUB_BROADCAST_STORE_NAME` | ✅ | — | — | — | — |

Both failure directions are silent until first use: a host holding a name whose component
its sidecar cannot serve, and a host scoped to a component it has no name for. CI asserts
both matrices. `DAPR_PUBSUB_BROADCAST_STORE_NAME` is kept even though no runtime C# reads
it *yet* — the component is deliberately held for a planned path, so dropping the name
would leave the orchestrator unable to address a component it loads.

Two traps worth knowing before you edit `scopes`:

- **`db-migrator` is a Job but it does get a sidecar.** Leaving it out of `lock` fails
  the schema migration.
- **`execution` is in `pubsub` by default** even though only domain-authored
  `DaprPubSubTask`s use it. Domains are authored independently and 50+ exist; an execution
  sidecar outside the scope fails when such a task **first runs** — at runtime, not at
  render. One pool per execution pod is cheap insurance. Drop it once you have confirmed
  no domain publishes from a task.

An override **replaces** a component's default list rather than merging, and an explicit
empty list restores unscoped load-everywhere behaviour:

```yaml
global:
  dapr:
    redis:
      scopes:
        pubsub: ["vnext-<domain>-app", "vnext-<domain>-worker-inbox-app"]
```

Do **not** scope the secretstore. Every Redis component names it as `auth.secretStore`, so
a sidecar scoped out of it loses `redis-password`; and it is create-once (`lookup` guard
plus `helm.sh/resource-policy: keep`), so a scope added later would not even reach an
existing release.

## Replicas

The HPA floor *is* the profile's replica count. `replicas` is omitted from the Deployment
whenever `autoscaling.enabled` is true, so `helm upgrade` never fights the HPA.

| Component | nonprod | low | normal | high |
|---|---|---|---|---|
| orchestrator | 2, HPA off | 2 / 6 | 10 / 20 | 20 / 40 |
| execution | 2, HPA off | 2 / 6 | 5 / 15 | 10 / 30 |
| worker-inbox | 2, HPA off | 1 / 4 | 3 / 9 | 6 / 18 |
| worker-outbox | 2, HPA off | 1 / 4 | 3 / 9 | 6 / 18 |
| redis-sentinel | 3, quorum 2 | 3, quorum 2 | 3, quorum 2 | 3, quorum 2 |

Prod HPA targets are 75% CPU and 75% memory. HPA needs requests present to compute
utilisation at all — every profile sets them, so this holds.

**Nonprod runs 2 replicas per app component, not 1.** Two is the minimum that exercises
the multi-instance code paths production actually runs — competing consumers on the Redis
pub/sub streams, distributed locks, cache invalidation races. At 1 replica nonprod never
reaches them while prod runs 10/5/3/3, which is how multi-instance bugs reach production.
It also survives a node drain, which matters here because the chart ships **no
PodDisruptionBudget** for the app components (Risk 8): a single replica is simply gone
until it is rescheduled. Cost is ~0.9 CPU and ~2.8Gi of requests per nonprod domain.

**Redis runs 3 nodes / quorum 2 in nonprod too**, for the same reason the app components
run 2: a single node never exercises what production does — Sentinel failover, the
client's `failover: true` path, the multi-host sentinel list that `vnext.redisEndpoint`
builds from `replicaCount` and feeds to every Dapr component's `redisHost`, or a
replica's diskless resync. (That list no longer reaches the *application*: the
`Redis__Standalone__EndPoints__0` env key was removed because the runtime dropped
`AddRedis()` — only the Dapr sidecar consumes it now.) It also
makes the subchart's PodDisruptionBudget (`maxUnavailable: 1`) and the default
`podAntiAffinity` meaningful, both of which are moot at 1 replica.

Cost is 3 Redis pods instead of 1: **0.375 CPU and 1.03Gi** of requests per nonprod
domain (**+0.25 CPU, +0.69Gi** over a single node). Note each pod runs **three**
containers, not two — `redis` (50m/192Mi), `sentinel` (25m/32Mi) and the `metrics`
exporter (50m/128Mi), the last of which the subchart sizes and which nothing currently
scrapes (Risk 1).

**2 nodes is never a valid topology — do not "split the difference".** With `quorum: 2` a
single node loss leaves one Sentinel that can never reach quorum, so no failover happens;
with `quorum: 1` both Sentinels can elect themselves and split-brain. Only **1/1** (no
failover at all) and **3/2** are self-consistent.

**Adding Redis nodes does not add connection capacity.** `maxclients` is per-node and
clients connect to the **master**, so the master absorbs the entire
`pods x components x poolSize` budget regardless of how many nodes exist. Scale
`poolSize` and `maxClients` for connection pressure — never node count.

**Sentinel quorum must match the node count.** The chart historically shipped
`replicaCount: 1` against the subchart's `sentinel.quorum: 2` — a pair that can never
elect a master. `NOTES.txt` warned; nothing blocked it. Every profile now ships `3`/`2`.
If you override `replicaCount`, override `quorum` to `(replicaCount / 2) + 1`.

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

daprd holds `poolSize` connections per Redis component it is **scoped to** — 4 for the
orchestrator, 2 for execution, 1 for each worker — each with its own read/write buffers.

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

3. **Redis is diskless — now explicitly.** `redis.extraConfig` sets `appendonly no` and
   `save ""`, and extraConfig is emitted **last**, so it wins over the persistence block.
   This was always the effective behaviour; the difference is that
   `persistence.enabled` is now `false` to match, instead of binding 3 x 8Gi per domain
   (~1.2Ti across 50) that Redis never wrote to. **Nothing became less durable** — but
   the standing consequence is unchanged and worth stating plainly: **a quorum loss
   discards all cache state and all in-flight pub/sub streams.** That is only acceptable
   because every event is re-derivable from Postgres via the outbox. If that ever stops
   being true, turn on real persistence via `redis.persistenceMode` (not by flipping
   `persistence.enabled` alone, which extraConfig would override straight back).
   Migrating an existing release requires the StatefulSet procedure below.

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

9. **`DAPR_PLACEMENT_HOST` is dead *and* wrong, and is left in place deliberately.** No
   runtime C# reads it, and its default `dapr-placement:50005` names no Service this chart
   deploys — the vendored subchart's Service is `dapr-placement-server`
   (`charts/dapr/templates/_address_placement.tpl`). Turning actors/placement off is
   tracked as separate work. Note that in production the Dapr control plane lives in its
   own namespace (`intprod-dapr`) and the injector supplies `--placement-host-address`
   itself, so flipping the chart's vendored `dapr.global.actors.enabled` would **not**
   remove the production placement StatefulSet — that needs the `intprod-dapr` owner.

10. **The `configuration` component is deleted here but still provisioned in the runtime
    repo.** `vnext/etc/*/dapr/components/config.yaml` still creates `vnext-config`
    (`configuration.redis`) for all five hosts, and the platform audit calls keeping it
    "a decision". Deleting it in Kubernetes is functionally safe — verified zero
    `GetConfiguration`/`SubscribeConfiguration` calls — but Kubernetes now diverges from
    local/compose. One side should move; raise it with the platform team.

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

**This upgrade needs the PVC migration first.** `persistence.enabled` is now `false`, and
`volumeClaimTemplates` is immutable on a live StatefulSet, so `helm upgrade` against an
existing release **fails** until you follow
[Migrating an existing release off the Redis PVC](#migrating-an-existing-release-off-the-redis-pvc).
Do that before anything below.

**This upgrade also restarts Redis.** The `redis.conf` contents change (`maxclients` is
added, and `maxmemory` moves with the memory limit), which changes the StatefulSet's
`checksum/config` and `checksum/scripts` annotations and therefore rolls the Redis pods.
On a 3-node prod topology that means one Sentinel-driven failover; on a nonprod
single-node topology it is a brief full outage of that domain's cache and pub/sub. Because
Redis is effectively diskless (Risk 3), **anything in Redis at that moment is lost** —
schedule it accordingly, and confirm in-flight work is drained or replayable first.

The app Deployments also roll, since their `resources` and `podAnnotations` change.

## Migrating an existing release off the Redis PVC

`persistence.enabled` moved from `true` to `false` (see Risk 3). **This is not a values
flip.** `volumeClaimTemplates` is immutable on a live StatefulSet, so `helm upgrade`
against an existing release fails with:

```
Forbidden: updates to statefulset spec for fields other than 'replicas', 'ordinals',
'template', 'updateStrategy', 'persistentVolumeClaimRetentionPolicy' and
'minReadySeconds' are forbidden
```

The StatefulSet must be deleted first. Doing so takes that domain's Redis fully down, so
**all cache state and all in-flight pub/sub streams are lost** — which is survivable only
because Redis was already non-durable and events replay from Postgres via the outbox.
Confirm that before you start, and do one domain at a time.

Substitute `<ns>` and `<rel>` (the Helm release, e.g. `vnext-contract`):

```bash
# 0. Record what you have, so a rollback is mechanical rather than reconstructed.
helm get values <rel> -n <ns> > /tmp/<rel>-values-backup.yaml
oc -n <ns> get sts <rel>-redis-sentinel -o yaml > /tmp/<rel>-sts-backup.yaml
oc -n <ns> get pvc | grep <rel>-redis-sentinel

# 1. Drain: stop the apps writing before Redis disappears, so fewer messages are
#    in flight at the cut. Skip only if you accept the larger replay.
oc -n <ns> scale deploy/<rel>-worker-inbox deploy/<rel>-worker-outbox --replicas=0

# 2. Delete the StatefulSet AND its pods. This is the step helm cannot do for you.
oc -n <ns> delete sts <rel>-redis-sentinel --cascade=foreground

# 3. Reclaim the storage. PVCs from a volumeClaimTemplate are NOT garbage-collected,
#    and they carry no chart labels, so delete them by name (one per ordinal --
#    3 in every profile now).
oc -n <ns> delete pvc data-<rel>-redis-sentinel-0 \
                      data-<rel>-redis-sentinel-1 \
                      data-<rel>-redis-sentinel-2

# 4. Upgrade. The StatefulSet is recreated with an emptyDir.
helm upgrade <rel> oci://ghcr.io/burgan-tech/vnext/vnext -n <ns> \
  -f charts/vnext/profiles/values-<profile>.yaml -f <your-domain-values>.yaml

# 5. Verify: no volumeClaimTemplates, no PVCs, and a healthy master/replica set.
oc -n <ns> get sts <rel>-redis-sentinel -o jsonpath='{.spec.volumeClaimTemplates}'; echo
oc -n <ns> get pvc | grep <rel>-redis-sentinel || echo "no PVCs - reclaimed"
oc -n <ns> rollout status sts/<rel>-redis-sentinel
oc -n <ns> exec <rel>-redis-sentinel-0 -c redis -- \
  redis-cli -a "$REDIS_PASSWORD" info replication | grep -E "role|connected_slaves"

# 6. Restore the workers.
oc -n <ns> scale deploy/<rel>-worker-inbox deploy/<rel>-worker-outbox --replicas=3
```

**Rollback.** Because Redis was never durable, rolling back loses nothing that step 2 had
not already discarded: re-run steps 2 and 4 with
`--set redis-sentinel.redis.persistence.enabled=true`, and fresh empty PVCs are created.
There is no data to restore, which is the whole point of Risk 3.

**Sanity check before starting:** confirm this release really is diskless, so you are not
deleting a PVC that something wrote to.

```bash
oc -n <ns> exec <rel>-redis-sentinel-0 -c redis -- \
  redis-cli -a "$REDIS_PASSWORD" config get appendonly save
# expect: appendonly "no"   and   save ""
oc -n <ns> exec <rel>-redis-sentinel-0 -c redis -- ls -la /data
# expect: no dump.rdb and no appendonlydir - only sentinel.conf
```

If either check disagrees, **stop**: that release is persisting data and needs the
`redis.persistenceMode` route instead.

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

# the pool bound reaches every Redis component (5th, configuration.redis, was deleted)
grep -c 'name: poolSize' /tmp/normal.yaml        # expect 4

# every Redis component is scoped, and the secretstore is not
grep -c 'scopes:' /tmp/normal.yaml               # expect 7 (4 Redis + 2 resiliency + 1 binding)

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
