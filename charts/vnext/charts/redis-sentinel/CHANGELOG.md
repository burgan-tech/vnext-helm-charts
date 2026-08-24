# Redis Sentinel Chart - Changelog

## Version 1.3.0 - Persistence modes, a real handover, and four latent bugs (Current)

### 🔑 `redis.persistenceMode`

`diskless | aof | rdb | aof-rdb`. This chart is not gaining an API so much as a NAME for
four states it has always rendered - its two deprecated keys form a bijection with them:

| `persistence.enabled` | `appendonly` | rendered today | mode |
|---|---|---|---|
| true | true | `save 900 1...` + `appendonly yes` | `aof-rdb` |
| true | false | `save 900 1...` + `appendonly no` | `rdb` |
| false | true | `save ""` + `appendonly yes` | `aof` |
| false | false | `save ""` + `appendonly no` | `diskless` |

`""` (the default) derives from those keys, so an existing release is untouched. From
1.3.0 `redis.persistence.enabled` means STORAGE ONLY (PVC vs emptyDir).

`appendfsync` and `appendfilename` were hardcoded; `stop-writes-on-bgsave-error`, every
`aof-*`, every `rdb*`, `repl-diskless-*` and `replica-serve-stale-data` were set nowhere -
which is why `values-examples/persistent-external-tls.yaml` had to hand-write ten of them
into `extraConfig`. All values now.

### 🐞 Fixed: the external-access restart job restarted every pod for nothing

`externalAccess.restartJob.enabled` is new and defaults to **false**, so enabling external
access no longer deletes all three pods after the release settles. The job could not have
been achieving its stated purpose in this chart:

- every announce value (`nodeHost`, `nodePorts`, `loadBalancerIPs`) is a render-time
  constant in the scripts ConfigMap; the only value read at runtime is `POD_IP` from the
  downward API, which is present at first boot. There is no lookup of a Service, an IP or
  a port anywhere in `start-redis.sh` / `start-sentinel.sh`;
- both config files are recreated from that ConfigMap on every boot
  (`cp /config/redis.conf /data/redis.conf`, same for `sentinel.conf`) with the announce
  lines appended after.

So boot 1 and boot 2 produce byte-identical announce configuration.

Measured on a fresh 3-pod NodePort install: all three pods `Running 3/3` at 35s, the job
finished at **2m51s**, and in between it deleted all three - one of which was the master,
so mastership moved. On an upgrade it was a *second* rollout on top of Helm's own, since
the changed scripts ConfigMap already changes `checksum/scripts` and rolls the pods.

It was also the most likely way to fail an upgrade: `helm`'s default `--timeout` is 5m,
below this job's `helmHookTimeout` of 20m, so the hook got killed and the release went to
`failed` while the job was still working.

Two smaller fixes for anyone who sets it back to `true`:

- the wait loop only accepted `readyReplicas == replicas`, which is **also true at the
  start of a rollout**, before the controller has terminated the first pod. Since Helm
  runs post-upgrade hooks without waiting for the workload, the job could land in exactly
  that window and delete pods while the StatefulSet controller was deleting its own. It
  now additionally requires `updatedReplicas == replicas` and
  `currentRevision == updateRevision`;
- the comment claiming reverse order avoids "disrupting the master (pod-0)" was wrong -
  the loop reaches pod-0 regardless, and after a failover the master is not pod-0 anyway.

**`redis-cluster` keeps this job on, and must.** There the announce is gated on
`/data/nodes.conf`: the first boot announces the pod IP because `--cluster create` has to
form the cluster pod-to-pod, and the external IP is only written on a later boot. The
restart is what produces that later boot. The two charts are deliberately not aligned, and
both `values.yaml` files now say so.

### 🐞 Fixed: the preStop hooks were silent no-ops under TLS

Both passed `--cacert` but not `--cert/--key` while `tls.*.authClients` defaults to TRUE,
so the command always failed and `|| echo "Note: ... failed"` hid it. For every TLS user
of this chart, these hooks have never done anything.

### 🐞 Fixed: a synchronous `SAVE` on every shutdown

`SAVE` blocks the server for the whole snapshot, and it was redundant - SIGTERM already
performs a blocking save when save points exist, so the chart paid for TWO full snapshots
inside one grace period. In an aof-only mode it was worse than redundant: it created a
`dump.rdb` that Redis will never read.

Replaced by a real handover: `SENTINEL FAILOVER mymaster` against this pod's own Sentinel,
whose process is still alive during preStop and whose decision is gossiped. Without it a
stopping master simply disappears and writes fail for `downAfterMilliseconds`; in diskless
mode a master that restarts faster than that is never marked down, comes back EMPTY, and
the replicas resync FROM EMPTY - losing the whole dataset.

`NOGOODSLAVE`, an in-progress failover and Sentinel's repeat-failover rate limit are each
handled as log-and-continue. When the failover is refused the hook no longer waits out the
full timeout: measured 20s → 1s, returned to redis-server's own shutdown.

### 🐞 Fixed: `sentinel.conf` was written to the container root filesystem

`dir` was `/tmp` when persistence was disabled - but `/tmp` is NOT a mounted volume in the
sentinel container (it mounts `/data`, `/config`, `/scripts`, `/secrets`), so Sentinel
rewrote its config onto the root filesystem, which breaks under any `securityContext` with
`readOnlyRootFilesystem: true`. Now unconditionally `/data`, which is mounted in both cases.

### 🐞 Fixed: pod-0 restarted as a SECOND master

`start-redis.sh` decided topology with one rule: pod-0 is the master, everyone else is
`replicaof pod-0`, unconditionally, on every start. After any failover the master is a
different ordinal - so a restarted pod-0 came back as a second master holding an old but
plausible dataset, accepted writes until Sentinel demoted it, and the full resync then
discarded them.

`start-sentinel.sh` already had the discovery for this; the same question is now asked in
`start-redis.sh` for EVERY ordinal. When no Sentinel answers we are a fresh install and the
pod-0 rule is both correct and the historical behaviour.

**This mattered more because of the handover above**, which deliberately moves mastership
OFF the pod being restarted.

### 🐞 Fixed: the chart contradicted itself on three network directives

The template wrote `tcp-keepalive 300` while the chart's OWN default `extraConfig`
overrode it with 60, and `timeout 0` was emitted twice. Values now, defaulting to the
EFFECTIVE values, so nothing changes.

### ⭐ New: loading-aware readiness, with a guard so failover cannot empty the Service

`readinessRequiresReplicationLink` could NOT be ported verbatim from redis-cluster. There a
replica with a dead link holds nothing and clients reach other shards. Here it may be the
LAST COPY of the data - and when the master dies EVERY replica reports link down at once,
so the naive check empties the Service of ALL endpoints for both ports. Clients then cannot
even reach Sentinel to learn the new master.

    role != slave                  Ready
    link up                        Ready
    link down, master reachable    NOT ready  (this pod is the problem)
    link down, master unreachable  Ready      (serve stale reads)

Reachability goes through this pod's own Sentinel; a Sentinel that does not answer counts
as unreachable, so the probe fails OPEN.

`startupProbe` ships DISABLED here, unlike redis-cluster: this chart has no sidecar to warn
before the budget runs out, and an exhausted startup probe kills the container and restarts
the load from zero.

### ⭐ New: `io-threads` / `lazyFreeing` values, and the examples stopped lying

`redis.ioThreads`, `redis.ioThreadsDoReads`, `redis.lazyFreeing` (plus
`redis.network.*` where the chart did not already have it). All default to empty, so no
existing release's effective `redis.conf` moves.

`redis.ioThreads` is a tri-state: `""` keeps Redis's default of 1, a number pins it,
`"auto"` derives `max(1, min(cores - 2, 8))` from the container CPU limit. Not `"auto"` by
default because `io-threads` is not runtime-modifiable - enabling it restarts every node.
The values-examples set `"auto"` instead, so a new install gets it while an existing
release is never changed behind its back.
`cores - 2` follows `redis.conf`'s own guidance and errs low on purpose: `limits.cpu` is a
CFS quota, not pinned cores, so over-threading throttles the whole cgroup rather than
running the extra threads slowly. An unreadable limit emits nothing and says so in NOTES.

`redis.ioThreadsDoReads` is for a pinned **Redis 7.x** image only. Measured on
`redis:8.8.0-alpine`: still accepted by the config parser (`redis-server` starts) but gone
from `CONFIG GET` - Redis 8 folded the read/parse offload into `io-threads` itself, so on
8.x it is a retained-for-compatibility no-op, not a startup failure. Emitted only when true.

These render **before** `extraConfig`, so existing `extraConfig` tuning still wins - and
NOTES now names any directive set in both places, because the value silently loses.
`repl-backlog-size` moved out of the mode-gated persistence block: it is not a persistence
directive, and that block only renders for a DECLARED mode, so a release on the deprecated
keys could set `replBacklogSize` and get nothing.

Measured against `redis:8.8.0-alpine` with `CONFIG GET`, most of what the examples wrote
into `extraConfig` was the Redis default written out, and `maxMemory` was pinned in nearly
all of them - which defeats the mode-derived ratio, the exact trap this release added a
NOTES warning for. Pins are gone except where the PVC (not RAM) is the binding ceiling and
`volumeClaimTemplates` immutability means the disk cannot be grown later.

### 🐞 Fixed: a completed init-job pod took the PodDisruptionBudget to zero

Reported from the live test: node drains and evictions were refused with
"disruption not allowed" while nothing was actually wrong.

Every Job in this chart stamps its pod with `selectorLabels` - name + instance - and
the PDB selected on exactly those two labels. The StatefulSet's pods carried nothing
to tell them apart. So the PDB also matched the **completed** completed job pod (cleanup, tls-cert-gen, external-access restart), which
is not Ready but still counts toward the PDB's expected total: with
`maxUnavailable: 1` and 3 Redis pods plus one finished job pod, allowed-disruptions
went to 0 until the job's `ttlSecondsAfterFinished` (3600) expired.

Fixed at the root rather than by shortening the TTL - shortening it would only narrow
the window and would cost the jobs' logs.
The Redis pods now carry `app.kubernetes.io/component: redis` and the PDB selects on
it, so no Job pod can ever match, whether running or finished.

Added to the **pod template only**. `spec.selector` and
`volumeClaimTemplates.metadata.labels` are immutable and deliberately keep just
name+instance; putting it there would make every existing release unupgradable.
Verified: zero diff in `serviceName`, `podManagementPolicy`, `selector` and
`volumeClaimTemplates` across every values-example, and the PDB now matches the
StatefulSet's pods and none of the three Job pods.

**No extra upgrade step.** The PDB is enabled by default, so this changes
`spec.selector` on every installed release - and `policy/v1` accepts that. Measured
against the live API server before shipping, which is not something to take on faith
when being wrong would break every upgrade:

```
$ kubectl -n <ns> patch pdb <release>-redis-sentinel --type=merge --dry-run=server \
    -p '{"spec":{"selector":{"matchLabels":{"app.kubernetes.io/component":"redis"}}}}'
poddisruptionbudget.policy/<release>-redis-sentinel patched
```

(If a validating webhook in your cluster rejects it anyway, delete the PDB and let
Helm recreate it: `kubectl -n <ns> delete pdb <release>-redis-sentinel`. The gap is seconds and costs
only drain protection.)

**How to recognise the bug you are upgrading away from:** it is visible for exactly
`ttlSecondsAfterFinished` after each install or upgrade - one hour by default - and
then disappears on its own when Kubernetes garbage-collects the finished job. So
`ALLOWED DISRUPTIONS 0` right after a release and `1` an hour later is the signature,
not two different problems.

### 🐞 Fixed: the shutdown handover asked its own dying Sentinel, and never happened

Found by the live test, and it is a data-loss bug in the diskless mode - the exact loss
this hook was written to prevent.

`preStop` sent `SENTINEL FAILOVER mymaster` to `127.0.0.1:26379`, the Sentinel in the
pod being terminated, on the reasoning that its process is still alive at that moment.
It is - for the moment. Both containers are terminating; the sentinel container's own
preStop is short, so its process takes SIGTERM a second or two later, while the failover
it just accepted needs several seconds to select a replica, promote it, and reconfigure
the others. It dies mid-way:

```
[preStop] role=master mode=diskless
[preStop] asking the local Sentinel to fail over mymaster ...
[preStop]   Sentinel: OK
[preStop] handover did NOT complete in 20s (still master) - stopping anyway
```

The peers' logs confirm nothing ever started - `+sdown` and `-sdown` a second apart, and
**no `+odown`, no `+try-failover`, no `+switch-master`** anywhere. Sentinel never even
reached the point of agreeing the master was down, because the pod came back inside
`down-after-milliseconds` (30s):

```
14:43:41 +sdown master mymaster ...
14:43:42 -sdown master mymaster ...
```

And in diskless mode the returning pod is **empty** - `master_repl_offset:0` against
replicas holding `87540` - so the replicas full-resync from it and the dataset is gone:
`MASTER <-> REPLICA sync: Flushing old data` / `Finished with success (0 bytes)`.

The request now goes to the **peer** Sentinels, which are not terminating. Two details
that are not incidental:

- **Every peer is asked, and the loop does not stop at the first OK.** Skipping our own
  ordinal needs our pod name. `$HOSTNAME` does carry it - measured on
  `redis:8.8.0-alpine`, the runtime sets it equal to `hostname`, which for a StatefulSet
  pod is the pod name, and `start-redis.sh` already derives `POD_INDEX` the same way - so
  the skip works. Correctness simply must not depend on it: on a runtime that did not set
  it we would ask pod-0, possibly ourselves, take the same useless OK, break, and
  reintroduce this bug while appearing fixed. A second `SENTINEL FAILOVER` returns
  `-INPROG`, which the existing classification already treats as fine, so asking all of
  them costs one round trip and removes the dependency.
- The local Sentinel remains as a last resort for `replicaCount: 1`, where no peer
  exists, and says in the log that a local failover usually dies with the pod.

Confirmed on the live release the bug was found on:

```
[preStop] asked the Sentinel on pod-1: OK
[preStop] handover complete after 12s - this node is now a replica
```

and afterwards pod-2 was master with `connected_slaves:2`, pod-0 back as a replica, and
all three offsets equal - no loss. Both peers answered `OK` rather than the `-INPROG` the
first version of this note predicted, so when our own identity IS known the loop now stops
at the first accepted request: two forced failovers can in principle select different
replicas, and issuing the second one buys nothing.

Verified with a stubbed `redis-cli` across all three identity cases - `$HOSTNAME` set,
`$HOSTNAME` empty with `hostname` answering, and both empty. In the worst case every peer
is still reached, and `127.0.0.1` is asked in none of them.

**Also worth knowing, measured in the same run:** a replica whose master disappeared can
spend a full 60 seconds (`repl-timeout`) hung on a sync attempt to a master that is back
but not yet ready to serve one, before retrying and succeeding. With loading-aware
readiness that shows up as a genuine `2/3` window and a readiness event that says exactly
why:

```
Readiness probe failed: replica link is 'down' while master ... IS reachable - not ready
```

That probe is behaving correctly - the replica should stay out of the Service while it
cannot serve fresh data - and the Service does not empty, because the master's own
endpoint is Ready. Whether `repl-timeout` should be lowered for this chart is not
decided here; it also bounds a legitimate full sync, so it needs its own measurement.

### ⭐ New: NOTES names both passwords and says which goes where

Reported from the live test: RedisInsight added the Sentinel connection fine and then
refused the Redis one with "Failed to authenticate, please check the username or password"
- while `redis-cli` worked with the password the user had.

The chart generates **two independent 32-character passwords** and nothing said so:

| secret key | written as | used to reach |
|---|---|---|
| `redis-password` | `requirepass` + `masterauth` on Redis | port 6379 |
| `sentinel-password` | `requirepass` on Sentinel | port 26379 |

Sentinel authenticates to Redis with the *Redis* password
(`sentinel auth-pass mymaster $REDIS_PASSWORD`), so inside the release everything works and
the split is invisible. A Sentinel-aware client needs **both**: the Sentinel password to ask
who the master is, and the Redis password to then connect to it. Giving the Sentinel
password to both fields authenticates, discovers the master, and fails on the second hop -
which looks exactly like a wrong password.

NOTES now prints both secret keys, the `kubectl` command for each, which port each opens,
and the specific shape of the trap in RedisInsight's Auto-Discover screen, where the
per-primary-group Password column starts as "not assigned" and wants the **Redis** one. It
also says to leave any username field empty, since the chart configures no ACL user.

Rendered from `auth.existingSecret` and the two `passwordKey` values, so it stays correct
for a release that brings its own secret.

**The chart is not the problem when a GUI still fails after that**, and NOTES now says so
with the measurement behind it. Reproducing RedisInsight's Auto-Discover flow from a plain
pod: Sentinel answers `PONG` on the Sentinel password, reports the master as
`<release>-redis-sentinel-0.<headless>...` on **port 6379**, that master answers `PONG` on
the Redis password and reports `redis_version:8.8.0`, and both replicas answer too. Every
hop works. Connecting to Redis with the SENTINEL password instead reproduces the tool's
error exactly - `WRONGPASS invalid username-password pair` - so the tool is forwarding the
Sentinel credential rather than the per-primary-group password it collected.

Two documented ways out, with the trade-off of each stated: equalise the two passwords
(discovery keeps working whatever is forwarded, but reaching Sentinel becomes enough to
authenticate to Redis), or add the master directly by pod FQDN (nothing is weakened, but
the connection points at a replica after a failover).

And the trap in between, which NOTES now warns about: pointing such a tool at the
`<release>` Service for writes. It selects every pod, so writes land on a replica at
random. There is deliberately no master-only Service here - keeping one accurate would need
a controller relabelling pods on failover, which is precisely the job Sentinel does for
clients that discover through it.

### ⭐ New: NodePort external access that Sentinel discovery can actually use

`externalAccess` worked for LoadBalancer and silently could not work for NodePort. The
difference is not a detail:

- **LoadBalancer** gives every pod its **own address on the same port**, so announcing one
  shared port - `externalAccess.service.redisPort` - is correct for all of them.
- **NodePort** gives every pod the **same address on a different port**. Announcing one
  shared port sends every client to a port nothing is listening on, and the chart's
  external Services carried no `nodePort:` field at all, so Kubernetes assigned random
  ones that nothing could have announced anyway.

The result was that with `type: NodePort` the pods fell through to announcing their
in-cluster FQDN. A client outside the cluster could reach a pod directly, ask Sentinel who
the master was, and get back an address it could not route to - failing on the second hop
with no indication of why.

Two new values, both NodePort-only and both ignored for LoadBalancer:

```yaml
externalAccess:
  service:
    type: NodePort
    nodeHost: "10.1.2.3"          # a node IP, or a VIP in front of the nodes
    nodePorts:
      redis:    [30001, 30002, 30003]
      sentinel: [31001, 31002, 31003]
```

The Services now pin those ports, each pod announces **its own** pair, and
`sentinel monitor` is seeded with the master's external address instead of its in-cluster
one - without which discovery would stay internal-only until the first failover.

`nodeHost` is one shared address rather than each pod announcing its own node, and that is
forced rather than chosen: on a fresh install every Sentinel writes `sentinel monitor`
pointing at pod-0, so pod-1 has to know pod-0's external address - which it cannot learn if
that address is "whichever node pod-0 landed on". It therefore requires
`externalTrafficPolicy: Cluster`, where any node routes to any pod.

Four NOTES warnings, because every one of these mistakes is invisible until a client
somewhere else times out:

- NodePort with `nodeHost` empty or a `nodePorts` list missing - discovery is in-cluster
  only, with the exact `--set` lines to fix it, and a note that this is *fine* if your
  clients are in-cluster
- a `nodePorts` list shorter than `replicaCount` - the pods past the end announce nothing,
  including after a failover promotes one of them
- `nodeHost` together with `externalTrafficPolicy: Local`, which cannot work

`values-examples/nodeport.yaml` was rewritten as part of this, because it demonstrated the
wrong one of the chart's two NodePort paths. It used `service.type: NodePort` - a single
NodePort in front of the shared Service, which selects **every** pod - so a client landed
on a random one and roughly two writes in three came back `READONLY`. That is fine for
reaching *a* Sentinel, since any of them can say who the master is, and wrong for Redis.
The file now uses `externalAccess` with per-pod Services, keeps the shared Service on
ClusterIP, and its header explains the difference so nobody restores the old shape.

**Nothing changes for an existing release.** Both values default to empty, so a NodePort
release keeps announcing exactly what it announces today, and the LoadBalancer path is
untouched. Verified: with comments stripped, the rendered scripts are **byte-identical**
across all nine values-examples, including the four that enable externalAccess; `nodePort:`
appears only when the type is NodePort; and the fully-configured case is the only NodePort
combination that produces no warning.

### 🐞 Fixed: replication followed whatever address Sentinel reported, including dead ones

Found on a live rolling restart, and it took down a `helm upgrade` with it.

`start-redis.sh` asks a Sentinel who the master is and used that answer **verbatim** as the
`replicaof` target. Sentinel learns replicas from the master's `INFO replication`, which
lists **IPs**, so after a failover it reports the new master by pod IP. `replicaof` holds a
literal address, so when that pod was recreated with a new IP the replica had nothing to
correct it:

```
Sentinel on pod-0 reports the master is 10.194.74.56:6379
Starting as replica of 10.194.74.56:6379 (pod-2)
...
# Timeout connecting to the MASTER 10.194.74.56:6379      (repeating for minutes)
```

The consequences cascaded: the replica could not sync, loading-aware readiness correctly
held it NotReady, the external-access restart job waits for every pod to be Ready, and its
600s budget ran out - so `helm upgrade` failed on a post-upgrade hook while nothing was
actually wrong with Redis.

Enabling NodePort announcement would have made it worse in a quieter way: once the pods
announce `nodeHost:nodePort`, Sentinel reports THAT, and replication between two pods in
the same namespace would leave the cluster and come back through the router. It works,
which is why nobody would notice, and it makes pod-to-pod replication depend on an ingress
path.

**Sentinel says who the master is. It no longer says how to reach it.** The reported
address is now mapped onto the master's in-cluster pod FQDN, using whatever the chart knows:

| Sentinel reports | mapped by |
|---|---|
| a pod FQDN | its first DNS label |
| `nodeHost:<nodePort>` | the port's index in `nodePorts.redis` |
| a LoadBalancer IP | its index in `loadBalancerIPs` |
| a bare pod IP | asking each pod which one reports `role:master` |

That last branch is also what recovers from the failure above: when the reported address is
**dead**, probing finds the pod that is actually serving. If nothing maps, the address is
used as given - never worse than before - with a line saying why it is fragile.

A pod FQDN resolves through the headless Service, which carries
`publishNotReadyAddresses`, so it survives every IP change and keeps replication inside the
cluster.

**This changes behaviour for existing releases, deliberately.** A release that has failed
over at least once currently replicates from a pod IP; after this it replicates from an
FQDN. Same traffic path, same peer - it just stops breaking when the pod is recreated. Only
the scripts change: `redis.conf` and the StatefulSet (bar `checksum/scripts`) are identical
across all nine values-examples.

Verified by executing the mapper against a stubbed `redis-cli`: an FQDN maps to itself; a
pod IP falls through to the probe and finds the real master; each of the three nodePorts and
each of the three LoadBalancer IPs map to their own ordinal; and an unmappable address with
no master anywhere returns failure so the caller falls back.

Confirmed on the live release, twice - once where Sentinel reported pod-0's external address
and once where it reported pod-2's:

```
Sentinel on pod-1 reports the master is 10.180.141.16:31603
Replicating from the in-cluster address instead:
  sentinel-diskless-redis-sentinel-2.<headless>.test-devops.svc.cluster.local:6379
```

Clients get the external address; replication stays inside the cluster. The two being
different is the correct outcome, not a discrepancy.

### 🐞 Fixed: a restarting Sentinel could monitor a REPLICA as the master

Caught by reading a live log line that was **right by luck**. pod-1 restarted into a
healthy cluster and its Sentinel said:

```
Found master from Sentinel: 10.180.141.16
Fresh install: monitoring pod-0 at its external address 10.180.141.16:31601
```

It was not a fresh install - it had just found the master from a peer - and the answer was
only correct because pod-0 happened to be the master at that moment.

`start-sentinel.sh`'s discovery took `get-master-addr-by-name` and kept `| head -1`: the
**host**, discarding the **port**. Over NodePort the host is `nodeHost`, identical for every
pod, so the port is the *only* thing that says which pod is master. With `MASTER_PORT`
empty the monitor line fell back to `nodePorts.redis[0]`, so with the master on pod-1 or
pod-2 a restarting Sentinel would have written `sentinel monitor mymaster <nodeHost>
<pod-0's port>` and begun monitoring a **replica** as the master.

A second defect in the same block: pod-0 was excluded from asking at all
(`if [ "$POD_INDEX" != "0" ]`), so a pod-0 restarting into a cluster whose master is pod-2
monitored itself. `start-redis.sh` had already dropped that exclusion for exactly this
reason - "for EVERY ordinal, not just non-zero ones" - and this script never followed.

Both had rotted here for the same structural reason: **six near-identical `redis-cli`
invocations** (TLS on/off x authClients on/off x password or not) that nobody wants to edit
six times. It now uses `scli_at`, the helper `start-redis.sh` already uses, so the two
scripts discover identically and cannot drift again.

And the fallback is no longer "assume pod-0". When a peer reports an **in-cluster** address -
which happens while its own announce has not taken effect - the pod's ordinal is read from
the DNS label and translated to *that* pod's external port:

| peer reports | monitored |
|---|---|
| nothing (genuinely fresh) | `nodeHost:nodePorts.redis[0]` - pod-0, correct on a fresh install |
| an external address | left exactly as reported |
| an in-cluster pod-2 FQDN | `nodeHost:nodePorts.redis[2]` |
| something unmappable | used as given, with a warning that external clients cannot route to it |

Verified by executing the block against all six cases, including the two that were
previously wrong (in-cluster pod-1 and pod-2 now resolve to their own ports instead of
pod-0's), then confirmed on the live release in the state that actually triggers it -
mastership deliberately moved off pod-0 first, then pod-0 restarted:

```
master artik 31603 (pod-0 degil)
Sentinel on pod-1 reports the master is 10.180.141.16:31603
```

`31603` is pod-2. The old code wrote `31601` there - pod-0's own port - so pod-0 would have
monitored **itself** as the master while pod-2 held it.

Only the scripts change: `redis.conf` and the StatefulSet bar `checksum/scripts` are
identical across all nine values-examples.

### 🐞 Fixed: `WAITAOF` ran after the handover, so it failed every time it mattered

Measured on redis 8.8.0: a master answers `WAITAOF 1 0 3000` with `1 1`, a replica answers
`ERR WAITAOF cannot be used with replica instances.` The call sat after the mastership
handover, by which point the node had just been demoted — so on every graceful master
shutdown, the one case it existed for, it errored. It now runs inside the "still a master"
branch, which is where the local AOF really is the only copy. The log line also blamed the
server version for any error, printing "needs Redis >= 7.2" on 8.8.0; it now prints the
actual error.

### 🐞 Fixed: `helm upgrade --reuse-values` could not render at all

`--reuse-values` does not merge the new chart's defaults, so a release installed on 1.2.x
arrived with `probes`, `gracefulShutdown`, `redis.rdb`, `redis.aof`, `redis.network` and
`redis.replication` missing, plus the new scalars. Live 1.2.2 → 1.3.0 hit
`nil pointer evaluating interface {}.savePoints`, then
`redis.ioThreads must be "" … got "<nil>"`, then a pod CrashLoopBackOff on
`'appendfsync' wrong number of arguments`. All three fixed with generated defaults blocks and
`mergeOverwrite`, guarded by `ci/check-value-defaults.py` and
`ci/test/check-nil-safe-values.py`.

The consequence with no code fix is documented instead: `--reuse-values` carries the OLD
chart's defaults, so declaring a mode changed the persistence block but left `maxmemory` at
`2396mb` where a clean install gives `1843mb`. NOTES detects it;
`--reset-then-reuse-values` fixes it, verified live.

### ⭐ New: `jobImage`, because the old one has no arm64 manifest

Four Job templates in this chart hardcoded `quay.io/openshift/origin-cli:latest`, which
publishes no arm64 manifest — so on an ARM node the cleanup Job and both TLS certificate Jobs
fail with `no matching manifest for linux/arm64/v8`. Now
`jobImage.{registry,repository,tag}` with the default unchanged.

### 📖 docs/redis-sentinel/persistence.md rewritten

All 455 lines taught persistence as OLD-vs-NEW `extraConfig` snippets and never mentioned
`persistenceMode` — advice this release actively overrides, since a declared mode comments
those directives out. Rewritten around what is specific to a master–replica pair, including
the two measurements that need explaining: the AOF did **not** save the data on a master
delete (the surviving master's copy did, because a demoted master full-resyncs anyway), and a
single small write does not prove a full disk (~40 bytes fit the AOF's allocated tail block,
so `df` at 0 still returned `OK`).

### 📋 Upgrade notes

- Every pod restarts (`checksum/config` + `checksum/scripts`).
- No `--cascade=orphan` needed, ever: this chart's `volumeClaimTemplates` never carried
  labels, so it never leaked the chart version. **Do not add labels to it.**
- `terminationGracePeriodSeconds` is now a value, same 60 default.
- Readiness now checks loading and (guarded) the replication link, so a rolling update
  waits for a loading pod instead of moving on.
- `sentinel.quorum` is now validated in NOTES.txt against `(replicaCount / 2) + 1`.
  Nothing checked it before, and both directions are dangerous.

### ✅ Verified

Gate A / Gate E over the rendered manifests after every commit; the derivation checked
against all 8 values-examples plus default values; probes and both preStop hooks extracted
and executed against a stubbed `redis-cli`, including the failover-window scenario where
the Service must NOT be emptied.

---

## Version 1.2.2 - Consistent chart packaging

Packaging only: `templates/` and `values.yaml` are untouched.

### 📦 One `.helmignore` shared by all three charts

Each chart shipped a different subset of its directory, and each policy was
partly wrong:

| Chart | before | `helm show readme` |
|---|---|---|
| redis-cluster | no `.helmignore` at all - everything shipped, including `examples/python-client/` (Dockerfile, `app.py`, `ca.crt`) and the operator scripts | worked |
| redis-sentinel | `*.md` excluded - the artifact carried no documentation | **empty** |
| redis-replication | `README.md` excluded while `CHANGELOG.md` and 4 other docs shipped | **empty** |

All three now use the same file:

- `*.md` ships, so `helm show readme` works everywhere
- `examples/`, `scripts/` and `values-examples/` do not. They are reference
  material that lives in git and is linked from `docs/`; nothing under
  `templates/` reads them (there is no `.Files.Get` in any chart)
- the usual VCS / editor / backup noise and `*.tgz` are excluded

Every package now has the same shape - `Chart.yaml`, `values.yaml`,
`.helmignore`, the `*.md` docs, `templates/`.

### Upgrade note

⚠️ Upgrading restarts every pod. `checksum/config` hashes the rendered ConfigMap,
whose `metadata.labels` contain `helm.sh/chart`, so any version bump reaches the
pod template. Nothing about the delivered configuration changes - plan it as a
rolling restart, not a no-op. (True of every version bump in these charts.)

---

## Version 1.2.1 - Explicit image registry

> **1.2.0 was never published.** Its content is identical to this release. The
> chart changes reached master across three separate PRs, and the master build
> only publishes when the *last* merge changed a `Chart.yaml` version - so no
> build ever packaged 1.2.0 and it does not exist in Harbor. Use 1.2.1.
>
> Rule of thumb until the pipeline's publish logic is reworked: any PR that
> touches chart content must bump `Chart.yaml` version, and chart changes should
> land in a single PR.

### 🔧 Image defaults: `docker.io/redis:8.8.0-alpine`

- Default tag is now `8.8.0-alpine` (was `8.2.2-alpine`)
- `appVersion` corrected to `8.8.0`. It said `7.4.1` while the chart actually
  pulled an 8.x image - the two never matched
- New `image.registry`, `metrics.image.registry` and
  `sentinelExporter.image.registry` values, default `docker.io`, so every
  rendered reference names its registry explicitly:
  `docker.io/redis:8.8.0-alpine`, `docker.io/oliver006/redis_exporter:v1.79.0`.
  This is what registry mirrors and `ImageContentSourcePolicy` rules match on,
  and it makes image provenance visible in `kubectl describe` and audits
- Set `registry: ""` to fall back to the runtime default (implicit docker.io), or
  point it at an internal registry:
  `--set image.registry=intprod-harbor.burgan.com.tr`
- References are built by the new `redis-sentinel.image`,
  `redis-sentinel.sentinelExporter.image` and `redis-sentinel.imageRef` helpers
  in `_helpers.tpl` instead of being inlined in 3 templates. The statefulset also
  gains the `appVersion` fallback when `image.tag` is empty

### 🐞 Fixed: two silently ignored settings in values-examples

- `securityContext: {runAsNonRoot: true}` was written flat in 7 examples, but the
  templates only read `securityContext.kubernetes` and `securityContext.openshift`
  (selected by `openshift.enabled`), so the setting did nothing. Rewritten in the
  nested form; verified that the pod now actually renders runAsUser/fsGroup 999
- `podDisruptionBudget.minAvailable: 2` had no effect: values.yaml pins
  `maxUnavailable: 1`, which survives the merge and the template prefers it. The
  examples rendered `maxUnavailable: 1` while claiming `minAvailable: 2`. They now
  set `maxUnavailable: null` alongside, so the stated intent is what renders

### 📋 values-examples aligned with the new structure

All 8 examples carry `image.registry: docker.io`, `tag: 8.8.0-alpine` and an
exporter `registry`. Every example was rendered to confirm it still templates.

⚠️ **Upgrade note:** the image string changes even when the image itself does not
(`redis:8.2.2-alpine` → `docker.io/redis:8.8.0-alpine`). Kubernetes compares pod
templates as strings, so upgrading an existing release **rolls all pods**, in
reverse ordinal order. Plan it as a restart, not a no-op.

The `quay.io/openshift/origin-cli:latest` image used by the TLS, cleanup and
external-access jobs is still hardcoded, tag included - not covered by this change.

---

## Version 1.1.0

Initial versioned release: Sentinel-based automatic failover, TLS certificate
jobs, external access via LoadBalancer/NodePort, cleanup job, Prometheus
exporters for both Redis and Sentinel.
