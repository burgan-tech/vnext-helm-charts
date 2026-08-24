{{/*
Expand the name of the chart.
*/}}
{{- define "redis-sentinel.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "redis-sentinel.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "redis-sentinel.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redis-sentinel.labels" -}}
helm.sh/chart: {{ include "redis-sentinel.chart" . }}
{{ include "redis-sentinel.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "redis-sentinel.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-sentinel.name" . }}
app.kubernetes.io/namespace: {{ .Release.Namespace }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "redis-sentinel.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "redis-sentinel.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return Redis password secret name
*/}}
{{- define "redis-sentinel.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- include "redis-sentinel.fullname" . -}}
{{- end -}}
{{- end -}}

{{/*
Compose a full image reference from a registry/repository/tag triplet.
Call with a dict: (dict "registry" ... "repository" ... "tag" ...)
An empty registry falls back to the container runtime default (implicit docker.io).
*/}}
{{- define "redis-sentinel.imageRef" -}}
{{- if .registry -}}
{{- printf "%s/%s:%s" .registry .repository .tag -}}
{{- else -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end -}}
{{- end -}}

{{/*
Return Redis image
*/}}
{{- define "redis-sentinel.image" -}}
{{- include "redis-sentinel.imageRef" (dict
      "registry" .Values.image.registry
      "repository" .Values.image.repository
      "tag" (.Values.image.tag | default .Chart.AppVersion)) -}}
{{- end -}}

{{/*
Return Redis metrics image
*/}}
{{- define "redis-sentinel.metrics.image" -}}
{{- include "redis-sentinel.imageRef" (dict
      "registry" .Values.metrics.image.registry
      "repository" .Values.metrics.image.repository
      "tag" .Values.metrics.image.tag) -}}
{{- end -}}

{{/*
Return Sentinel exporter image
*/}}
{{- define "redis-sentinel.sentinelExporter.image" -}}
{{- include "redis-sentinel.imageRef" (dict
      "registry" .Values.sentinelExporter.image.registry
      "repository" .Values.sentinelExporter.image.repository
      "tag" .Values.sentinelExporter.image.tag) -}}
{{- end -}}

{{/*
Return headless service name
*/}}
{{- define "redis-sentinel.headlessServiceName" -}}
{{- printf "%s-headless" (include "redis-sentinel.fullname" .) -}}
{{- end -}}

{{/*
The image for the chart's kubectl-running Jobs. Separate from image.* because these Jobs
do not run Redis - see the jobImage comment in values.yaml for why it is overridable.
*/}}
{{- define "redis-sentinel.jobImage" -}}
{{- include "redis-sentinel.imageRef" (dict
      "registry" .Values.jobImage.registry
      "repository" .Values.jobImage.repository
      "tag" .Values.jobImage.tag) -}}
{{- end -}}

{{/* SHARED-BEGIN memory-parsing
     Kept byte-identical (modulo the chart-name prefix) in all three charts.
     ci/check-shared-helpers.sh fails the build if they drift apart. */}}

{{/*
Convert a Kubernetes memory quantity to whole MiB.

Emits an integer, or an EMPTY string when the value cannot be parsed. Callers
must treat empty as "unknown" rather than as zero - the previous version handled
only Gi and Mi and silently fell through to 0 for everything else, and
"maxmemory 0mb" means UNLIMITED to Redis. A perfectly valid
resources.limits.memory of "3G" (or a plain byte count) therefore produced a
Redis with no memory ceiling inside a 3 GB cgroup: the pod OOMKills instead of
evicting, and with maxmemory-policy noeviction that is a hard crash under load
rather than a slowdown.

Covers the full Kubernetes quantity suffix set: binary Ki/Mi/Gi/Ti/Pi/Ei,
decimal k/K/M/G/T/P/E, and suffix-less bytes. The milli suffix ("512m") is
rejected on purpose - it is legal for CPU but meaningless for memory, and
accepting it would silently yield a sub-byte limit.

MiB is the right output unit because Redis reads "mb" as 1024*1024.
*/}}
{{- define "redis-sentinel.memoryToMB" -}}
{{- $q := . | toString | trim -}}
{{- $bytes := "" -}}
{{- if hasSuffix "Ki" $q -}}
{{- $bytes = mulf (trimSuffix "Ki" $q | float64) 1024 -}}
{{- else if hasSuffix "Mi" $q -}}
{{- $bytes = mulf (trimSuffix "Mi" $q | float64) 1048576 -}}
{{- else if hasSuffix "Gi" $q -}}
{{- $bytes = mulf (trimSuffix "Gi" $q | float64) 1073741824 -}}
{{- else if hasSuffix "Ti" $q -}}
{{- $bytes = mulf (trimSuffix "Ti" $q | float64) 1099511627776 -}}
{{- else if hasSuffix "Pi" $q -}}
{{- $bytes = mulf (trimSuffix "Pi" $q | float64) 1125899906842624 -}}
{{- else if hasSuffix "Ei" $q -}}
{{- $bytes = mulf (trimSuffix "Ei" $q | float64) 1152921504606846976 -}}
{{- else if hasSuffix "m" $q -}}
{{/* milli - not a memory unit, leave $bytes empty */}}
{{- else if or (hasSuffix "k" $q) (hasSuffix "K" $q) -}}
{{- $bytes = mulf (trimSuffix "K" (trimSuffix "k" $q) | float64) 1000 -}}
{{- else if hasSuffix "M" $q -}}
{{- $bytes = mulf (trimSuffix "M" $q | float64) 1000000 -}}
{{- else if hasSuffix "G" $q -}}
{{- $bytes = mulf (trimSuffix "G" $q | float64) 1000000000 -}}
{{- else if hasSuffix "T" $q -}}
{{- $bytes = mulf (trimSuffix "T" $q | float64) 1000000000000 -}}
{{- else if hasSuffix "P" $q -}}
{{- $bytes = mulf (trimSuffix "P" $q | float64) 1000000000000000 -}}
{{- else if hasSuffix "E" $q -}}
{{- $bytes = mulf (trimSuffix "E" $q | float64) 1000000000000000000 -}}
{{- else if regexMatch "^[0-9]+(\\.[0-9]+)?$" $q -}}
{{- $bytes = $q | float64 -}}
{{- end -}}
{{- if $bytes -}}
{{- divf $bytes 1048576 | int -}}
{{- end -}}
{{- end -}}

{{/*
Compute effective maxMemory for Redis:
- If redis.maxMemory is non-empty, use it directly.
- Else if redis.maxMemoryRatio is set, calculate as ratio * resources.limits.memory.
- Otherwise fall back to "0" (unlimited).

Unchanged output for every Gi/Mi limit, so no existing release's maxmemory moves.
Never fails: a missing or unreadable limit still yields "0", because a release
can already be in that state and a render error would block its upgrade. The
condition is reported through NOTES.txt instead.
*/}}
{{- define "redis-sentinel.effectiveMaxMemory" -}}
{{- if .Values.redis.maxMemory -}}
{{- .Values.redis.maxMemory -}}
{{- else -}}
{{- $memMB := include "redis-sentinel.memLimitMB" . -}}
{{- $ratio := include "redis-sentinel.maxMemoryRatio" . -}}
{{- if and $memMB $ratio -}}
{{- mulf ($memMB | float64) ($ratio | float64) | int }}mb
{{- else -}}
0
{{- end -}}
{{- end -}}
{{- end -}}
{{/* SHARED-END memory-parsing */}}

{{/* SHARED-BEGIN cpu-parsing
     Kept byte-identical (modulo the chart-name prefix) in all three charts.
     ci/check-shared-helpers.sh fails the build if they drift apart. */}}

{{/*
Convert a Kubernetes CPU quantity to WHOLE cores, rounding down.

Emits an integer, or an EMPTY string when the value cannot be parsed - the same
fail-closed contract as memoryToMB, and for the same reason: the only caller
sizes a thread count against it, and deriving a thread count from a limit you
could not read is how you get a throttled node.

Kubernetes CPU quantities are either a plain (possibly fractional) number of
cores or an integer with the milli suffix: "4", "0.5", "3.5", "500m", "4000m".
There are no other legal suffixes, so anything else is a typo and stays empty.

Rounding DOWN is deliberate: 3500m is three cores you can count on plus half a
core you cannot.
*/}}
{{- define "redis-sentinel.cpuToCores" -}}
{{- $q := . | toString | trim -}}
{{- if hasSuffix "m" $q -}}
{{- $n := trimSuffix "m" $q -}}
{{- if regexMatch "^[0-9]+$" $n -}}
{{- div (int64 $n) 1000 -}}
{{- end -}}
{{- else if regexMatch "^[0-9]+$" $q -}}
{{- $q | int64 -}}
{{- else if regexMatch "^[0-9]+\\.[0-9]+$" $q -}}
{{- $q | float64 | floor | int64 -}}
{{- end -}}
{{- end -}}

{{/*
What redis.ioThreads="auto" resolves to: max(1, min(cores - 2, 8)) from the
container CPU limit, or EMPTY when that works out to no threading at all (1 or
fewer) or when the limit cannot be read.

This is the ONLY copy of the arithmetic. NOTES.txt asks for it too - to show what
"auto" would give on a release that has not opted in, and to judge whether a
pinned number is too high - and having the clamp in two places is how those two
answers start disagreeing.

Why cores - 2 rather than all of them: I/O threads do socket reads, writes and
protocol parsing; command execution stays on the single main thread, which still
needs a core, and so does everything else in the pod (the health sidecar, the
metrics exporter, kernel work for the sockets themselves). redis.conf's own
guidance is "if you have a 8 cores machine try to use 6 threads", and this
reproduces it. The cap at 8 is from the same file: more is documented as unlikely
to help. So the first thread appears at 4 cores; 1, 2 and 3 get none, which is
right - adding threads to a one-core quota only buys throttling.

Erring low matters more here than in a VM: limits.cpu is a CFS quota, not pinned
cores. Threads beyond what the quota can feed do not idle politely - they get the
whole cgroup throttled at the end of each period, which shows up as latency
spikes that look like Redis stalling.
*/}}
{{- define "redis-sentinel.ioThreadsAuto" -}}
{{- $cores := include "redis-sentinel.cpuLimitCores" . -}}
{{- if $cores -}}
{{- $n := sub (int $cores) 2 -}}
{{- if gt $n 8 -}}{{- $n = 8 -}}{{- end -}}
{{- if gt $n 1 -}}{{- $n -}}{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Resolve redis.ioThreads to the number that should be written to io-threads, or to
an EMPTY string meaning "emit nothing, keep the Redis default of 1".

  ""      -> empty. The chart default. io-threads is not runtime-modifiable, so
             turning it on for an existing release would restart every node AND
             change how it schedules work, in an upgrade meant to be routine. The
             values-examples set "auto" instead, so a NEW install gets it and an
             existing one is never changed behind its back.
  "auto"  -> ioThreadsAuto above.
  <n>     -> that number, with 0 and 1 collapsing to empty (both mean "no I/O
             threads", and emitting "io-threads 1" would only be noise).

Anything else FAILS the render. Allowed by this chart's fail policy - the key is
new in 1.3.0, so no installed release can already carry a bad value - and a
silently-ignored tuning knob is worse than a render error you see once.

ABSENT is not the same as bad, and that distinction cost an upgrade. `helm upgrade
--reuse-values` does not merge the new chart's defaults, so a release installed on
1.2.x reaches this helper with the key MISSING. `nil | toString` is the literal
string "<nil>", which is neither "", "auto" nor a number, so the fail fired on a
value the release had never set:

  Error: UPGRADE FAILED: redis.ioThreads must be "" ... got "<nil>"

nil is therefore normalised to "" (= the chart default, off) BEFORE validating.
kindIs "invalid" is the nil test; checking for the string "<nil>" would work today
and depends on how Go happens to format nil.
*/}}
{{- define "redis-sentinel.ioThreadsEffective" -}}
{{- $v := "" -}}
{{- if not (kindIs "invalid" .Values.redis.ioThreads) -}}
{{- $v = .Values.redis.ioThreads | toString | trim -}}
{{- end -}}
{{- if eq $v "auto" -}}
{{- include "redis-sentinel.ioThreadsAuto" . -}}
{{- else if $v -}}
{{- if regexMatch "^[0-9]+$" $v -}}
{{- if gt (int $v) 1 -}}{{- $v -}}{{- end -}}
{{- else -}}
{{- fail (printf "redis.ioThreads must be \"\" (Redis default), \"auto\" (derive from resources.limits.cpu) or a whole number, got %q" $v) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{/* SHARED-END cpu-parsing */}}

{{/* SHARED-BEGIN performance-shadow
     Kept byte-identical (modulo the chart-name prefix) in all three charts.
     ci/check-shared-helpers.sh fails the build if they drift apart. */}}

{{/*
The performance directives this release would emit that extraConfig ALSO sets, as
a space-separated list. Empty when there is no conflict.

The performance block is rendered BEFORE extraConfig, on purpose: that is what
keeps existing extraConfig tuning authoritative across the upgrade. The cost is
that setting redis.ioThreads (or network.*, or lazyFreeing) while the same
directive sits in extraConfig does NOTHING, and the rendered redis.conf gives no
hint - it just contains the directive twice with different values.

Unlike the persistence directives, these are NOT filtered out of extraConfig even
when the mode is declared: persistence is something the mode owns, tuning is not.
So the only remedy is to report it, which NOTES.txt does.
*/}}
{{- define "redis-sentinel.performanceShadowed" -}}
{{- $emitted := list -}}
{{- $net := .Values.redis.network | default dict -}}
{{- if ne (get $net "tcpBacklog" | toString) "" -}}{{- $emitted = append $emitted "tcp-backlog" -}}{{- end -}}
{{- if ne (get $net "timeout" | toString) "" -}}{{- $emitted = append $emitted "timeout" -}}{{- end -}}
{{- if ne (get $net "tcpKeepalive" | toString) "" -}}{{- $emitted = append $emitted "tcp-keepalive" -}}{{- end -}}
{{- if ne (get (.Values.redis.replication | default dict) "replBacklogSize" | toString) "" -}}{{- $emitted = append $emitted "repl-backlog-size" -}}{{- end -}}
{{- if include "redis-sentinel.ioThreadsEffective" . -}}
{{- $emitted = append $emitted "io-threads" -}}
{{- if .Values.redis.ioThreadsDoReads -}}{{- $emitted = append $emitted "io-threads-do-reads" -}}{{- end -}}
{{- end -}}
{{- if .Values.redis.lazyFreeing -}}
{{- $emitted = concat $emitted (list "lazyfree-lazy-eviction" "lazyfree-lazy-expire" "lazyfree-lazy-server-del" "replica-lazy-flush") -}}
{{- end -}}
{{- $hits := list -}}
{{- range $line := splitList "\n" (.Values.redis.extraConfig | default "") -}}
{{- $t := trim $line -}}
{{- if and $t (not (hasPrefix "#" $t)) -}}
{{- $d := first (splitList " " (replace "\t" " " $t)) -}}
{{- if has $d $emitted -}}
{{- $hits = append $hits $d -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $hits | uniq | sortAlpha | join " " -}}
{{- end -}}
{{/* SHARED-END performance-shadow */}}

{{/*
The container memory limit this chart sizes maxmemory against, in MiB.
Empty when unset or unparseable.

NOT part of the shared block: the lookup path differs per chart. redis-cluster
and redis-replication have a single container's resources at .Values.resources,
redis-sentinel nests them per container at .Values.resources.redis.
*/}}
{{- define "redis-sentinel.memLimitMB" -}}
{{- $limit := "" -}}
{{- if .Values.resources.redis -}}
{{- if .Values.resources.redis.limits -}}
{{- $limit = .Values.resources.redis.limits.memory | default "" -}}
{{- end -}}
{{- end -}}
{{- if $limit -}}
{{- include "redis-sentinel.memoryToMB" $limit -}}
{{- end -}}
{{- end -}}

{{/*
The container CPU limit ioThreads: "auto" derives from, in whole cores.
Empty when unset or unparseable.

NOT part of the shared block, for the same reason as memLimitMB: the lookup path
differs per chart.
*/}}
{{- define "redis-sentinel.cpuLimitCores" -}}
{{- $limit := "" -}}
{{- if .Values.resources.redis -}}
{{- if .Values.resources.redis.limits -}}
{{- $limit = .Values.resources.redis.limits.cpu | default "" -}}
{{- end -}}
{{- end -}}
{{- if $limit -}}
{{- include "redis-sentinel.cpuToCores" $limit -}}
{{- end -}}
{{- end -}}

{{/*
maxmemory-policy, derived from the mode when not set explicitly.

allkeys-lru is right for a cache and wrong for a store: on a durable cluster it
silently deletes committed keys once the limit is reached, and writes the DELs
into the AOF, so the loss is not recoverable from disk either.

The derivation only engages for a DECLARED mode. A release that never set
persistenceMode keeps allkeys-lru even if its mode derives to something durable -
switching it to noeviction behind its back could take maxmemory below
used_memory and turn every write into an OOM error during what was supposed to be
a routine upgrade. NOTES.txt reports the mismatch and names the one-line fix.
*/}}
{{- define "redis-sentinel.maxMemoryPolicy" -}}
{{- $p := .Values.redis.maxMemoryPolicy | default "" | toString | trim -}}
{{- if and $p (ne $p "<nil>") -}}
{{- $p -}}
{{- else -}}
{{- include "redis-sentinel.maxMemoryPolicyDerived" . -}}
{{- end -}}
{{- end -}}

{{/*
What maxMemoryPolicy would be if it were NOT set - i.e. what the mode derives.

Split out so NOTES.txt can tell "pinned to something DIFFERENT from the derived
value" from "pinned to the same value". Without the comparison the warning fired on
every values-example that spells the derived value out, printing the self-refuting
"PINNED so the defaults are NOT in effect: maxMemoryPolicy=noeviction (the mode
would derive noeviction)". A check that cries wolf gets switched off.
*/}}
{{- define "redis-sentinel.maxMemoryPolicyDerived" -}}
{{- if and (eq (include "redis-sentinel.persistence.explicitMode" .) "true") (eq (include "redis-sentinel.persistence.durable" .) "true") -}}
noeviction
{{- else -}}
noeviction
{{- end -}}
{{- end -}}

{{/*
The maxmemory / limit ratio, derived from the mode when not set explicitly.

0.8 assumes Redis never forks. In a durable mode it does: BGSAVE and AOF rewrite
both fork, and copy-on-write can push RSS well above the parent's under write
load. At 80% of the cgroup limit there is no headroom for that, and an OOMKill
skips the preStop hook entirely - so the graceful handover that protects the
shard's data never runs. 0.6 leaves room for the fork.

Same rule as maxMemoryPolicy: derived only for a DECLARED mode.
*/}}
{{- define "redis-sentinel.maxMemoryRatio" -}}
{{- $r := .Values.redis.maxMemoryRatio | default "" | toString | trim -}}
{{- if and $r (ne $r "<nil>") -}}
{{- $r -}}
{{- else -}}
{{- include "redis-sentinel.maxMemoryRatioDerived" . -}}
{{- end -}}
{{- end -}}

{{/*
What maxMemoryRatio would be if it were NOT set - i.e. what the mode derives.

Split out so NOTES.txt can tell "pinned to something DIFFERENT from the derived
value" from "pinned to the same value". Without the comparison the warning fired on
every values-example that spells the derived value out, printing the self-refuting
"PINNED so the defaults are NOT in effect: maxMemoryPolicy=noeviction (the mode
would derive noeviction)". A check that cries wolf gets switched off.
*/}}
{{- define "redis-sentinel.maxMemoryRatioDerived" -}}
{{- if and (eq (include "redis-sentinel.persistence.explicitMode" .) "true") (eq (include "redis-sentinel.persistence.durable" .) "true") -}}
0.6
{{- else -}}
0.78
{{- end -}}
{{- end -}}

{{/* SHARED-BEGIN persistence-mode
     The named templates below are kept byte-identical (modulo the chart-name
     prefix) in all three charts EXCEPT the derivation block inside
     <chart>.persistenceMode, which is necessarily chart-specific: each chart has
     a different set of deprecated keys to derive from. That block is fenced with
     CHART-SPECIFIC markers and excluded from the drift check. */}}

{{/*
Does redis.extraConfig leave RDB snapshotting ON?

extraConfig is rendered as the LAST block of redis.conf, so whatever it says
about `save` wins over anything the chart emits. That makes it part of the
answer to "is this cluster durable today?", which is why the legacy derivation
has to read it: the chart's own default extraConfig ends with `save ""`, while
values-examples/persistent-storage.yaml turns snapshots back on there.

Emits "true"/"false". The LAST save directive wins, matching Redis.
An empty argument (`save ""` or `save ''`) means snapshots are off.
*/}}
{{- define "redis-sentinel.rdbActiveInExtraConfig" -}}
{{- $active := "" -}}
{{- range $line := splitList "\n" (.Values.redis.extraConfig | default "") -}}
{{- $t := trim $line -}}
{{- if and $t (not (hasPrefix "#" $t)) -}}
{{- if or (eq $t "save") (hasPrefix "save " $t) (hasPrefix "save\t" $t) -}}
{{- $arg := trim (substr 4 (len $t) $t) -}}
{{- if or (eq $arg "") (eq $arg "\"\"") (eq $arg "''") -}}
{{- $active = "no" -}}
{{- else -}}
{{- $active = "yes" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if eq $active "yes" -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/*
THE persistence mode. Single source of truth - no template reads
.Values.redis.persistenceMode directly.

Emits exactly one of: diskless | aof | rdb | aof-rdb

Explicitly set (redis.persistenceMode non-empty):
  used as-is. An unknown value FAILS the render - the key is new, so no
  already-installed release can be in that state, and a typo silently falling
  back to some default is a data-loss bug. Setting it to anything other than
  "diskless" while the deprecated redis.disklessCache.enabled is still true also
  FAILS, because silently picking one of the two either turns a cache into a
  disk-filling AOF writer or turns a durable store into `save ""`.

Not set (the default): derived from the deprecated keys so that every existing
release renders exactly what it renders today. Two rules govern the derivation:

  1. redis.disklessCache.enabled=true  ->  diskless, full stop.
     otherwise redis.appendonly        ->  aof (true) / rdb (false)

  2. Only in the non-alias branch, an active `save` in redis.extraConfig upgrades
     aof -> aof-rdb. It never downgrades anything.

Rule 2 is deliberately asymmetric, and the asymmetry is the safe direction.
Consider redis.appendonly=false with the chart's default extraConfig, which ends
with `save ""`: the effective config has NO persistence at all, yet the mode
derives to "rdb" rather than "diskless". Every guard in the chart therefore
treats the cluster as durable and REFUSES to flush it. Deriving "diskless" there
would be more honest about the rendered config but would hand the init job and
the health sidecar permission to erase the cluster unattended. Fail closed, and
report the discrepancy through NOTES.txt instead.

Rule 1 stops at the alias for the mirror-image reason: it must not silently make
an existing release MORE durable either. disklessCache=true with save points in
extraConfig renders `appendonly no` + active snapshots today. Letting rule 2
promote that to "rdb" would flip the config block to the durable branch, which
emits `appendonly yes` (appendonly defaults to true) - turning AOF on for a
cluster that had it off. Such a release keeps mode "diskless", exactly as it
behaves today, and NOTES.txt points out that its snapshots are invisible to the
guards until persistenceMode is declared.
*/}}
{{- define "redis-sentinel.persistenceMode" -}}
{{- $valid := list "diskless" "aof" "rdb" "aof-rdb" -}}
{{- $r := .Values.redis -}}
{{- $raw := "" -}}
{{- if hasKey $r "persistenceMode" -}}
{{- $raw = ($r.persistenceMode | toString | trim | lower) -}}
{{- end -}}
{{- if or (eq $raw "<nil>") (eq $raw "null") -}}
{{- $raw = "" -}}
{{- end -}}
{{- /* CHART-SPECIFIC-BEGIN deprecated-alias */ -}}
{{- /*
  redis-sentinel has no disklessCache flag. Its two deprecated keys already form a
  bijection with the four modes, so this chart is not gaining an API - it is gaining
  a NAME for four states it has always rendered:

    persistence.enabled  appendonly   rendered today                  mode
    true                 true         save 900 1... + appendonly yes  aof-rdb
    true                 false        save 900 1... + appendonly no   rdb
    false                true         save ""       + appendonly yes  aof
    false                false        save ""       + appendonly no   diskless

  From 1.3.0 redis.persistence.enabled means STORAGE ONLY (PVC vs emptyDir). It
  keeps its derivation role here purely so an existing release resolves to the mode
  it already runs.
*/ -}}
{{- $alias := false -}}
{{- $pers := eq ((.Values.redis.persistence).enabled | toString) "true" -}}
{{- $base := "" -}}
{{- if eq ($r.appendonly | toString) "true" -}}
{{- $base = ternary "aof-rdb" "aof" $pers -}}
{{- else -}}
{{- $base = ternary "rdb" "diskless" $pers -}}
{{- end -}}
{{- $aliasName := "redis.persistence.enabled / redis.appendonly" -}}
{{- /* CHART-SPECIFIC-END deprecated-alias */ -}}
{{- if $raw -}}
{{- if not (has $raw $valid) -}}
{{- fail (printf "\n\nredis.persistenceMode must be one of diskless|aof|rdb|aof-rdb, got %q.\nSee values.yaml for what each mode renders.\n" $raw) -}}
{{- end -}}
{{- if and $alias (ne $raw "diskless") -}}
{{- fail (printf "\n\nredis.persistenceMode=%s contradicts the deprecated %s=true.\nRemove %s (or set it to false) and keep persistenceMode.\n" $raw $aliasName $aliasName) -}}
{{- end -}}
{{- $raw -}}
{{- /* CHART-SPECIFIC-BEGIN extraconfig-upgrade
     Bu kural chart'a gore FARKLI olmak ZORUNDA, ve fark bilincli:

       redis-cluster    yalnizca aof -> aof-rdb. Alias'ta DURUR: orada diskless -> rdb
                        promosyonu config blogunu durable dala cevirir ve `appendonly yes`
                        yazar - AOF'u kapali calisan bir cluster icin sessiz davranis
                        degisikligi.
       sentinel/replication  iki yonde de guvenli, cunku aof bileseni modun kendisinde
                        tasinir; hicbir promosyon appendonly'yi cevirmez.

     Drift kontrolu bu bolumu haric tutar. */ -}}
{{- else if and (eq (include "redis-sentinel.rdbActiveInExtraConfig" .) "true") (eq $base "aof") -}}
aof-rdb
{{- else if and (eq (include "redis-sentinel.rdbActiveInExtraConfig" .) "true") (eq $base "diskless") -}}
rdb
{{- else -}}
{{- /* CHART-SPECIFIC-END extraconfig-upgrade */ -}}
{{- $base -}}
{{- end -}}
{{- end -}}

{{/*
Was the mode declared, or derived from the deprecated keys?

This gates every behaviour-changing default in the chart. Declaring
redis.persistenceMode is the opt-in to the safe-for-durable defaults
(noeviction, fork-aware memory ratio, an authoritative persistence block);
a release that has not been touched keeps rendering exactly what it renders
today. Emits "true"/"false".
*/}}
{{- define "redis-sentinel.persistence.explicitMode" -}}
{{- $raw := "" -}}
{{- if hasKey .Values.redis "persistenceMode" -}}
{{- $raw = (.Values.redis.persistenceMode | toString | trim | lower) -}}
{{- end -}}
{{- if or (eq $raw "") (eq $raw "<nil>") (eq $raw "null") -}}false{{- else -}}true{{- end -}}
{{- end -}}

{{/*
Does this cluster hold data that survives a pod restart? Emits "true"/"false".
Every destructive path in the chart (FLUSHALL, CLUSTER RESET HARD,
CLUSTER REPLICATE onto a slot-holder, --cluster fix, discarding nodes.conf)
is gated on this.
*/}}
{{- define "redis-sentinel.persistence.durable" -}}
{{- if eq (include "redis-sentinel.persistenceMode" .) "diskless" -}}false{{- else -}}true{{- end -}}
{{- end -}}

{{/* Is the append-only file enabled? Emits "true"/"false". */}}
{{- define "redis-sentinel.persistence.aof" -}}
{{- $m := include "redis-sentinel.persistenceMode" . -}}
{{- if or (eq $m "aof") (eq $m "aof-rdb") -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/* Are RDB snapshots enabled? Emits "true"/"false". */}}
{{- define "redis-sentinel.persistence.rdb" -}}
{{- $m := include "redis-sentinel.persistenceMode" . -}}
{{- if or (eq $m "rdb") (eq $m "aof-rdb") -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/*
The effective maxmemory in whole MiB, for the sizing checks in NOTES.txt.
Empty when it cannot be determined.

Needed because redis.maxMemory is written in REDIS units (5gb, 512mb), which are
not Kubernetes quantities: memoryToMB cannot read them. Redis reads kb/mb/gb as
1024-based and k/m/g as 1000-based.
*/}}
{{- define "redis-sentinel.maxMemoryMB" -}}
{{- $m := .Values.redis.maxMemory | default "" | toString | trim | lower -}}
{{- if and $m (ne $m "0") -}}
{{- if hasSuffix "kb" $m -}}
{{- divf (trimSuffix "kb" $m | float64) 1024 | int -}}
{{- else if hasSuffix "mb" $m -}}
{{- trimSuffix "mb" $m | float64 | int -}}
{{- else if hasSuffix "gb" $m -}}
{{- mulf (trimSuffix "gb" $m | float64) 1024 | int -}}
{{- else if hasSuffix "k" $m -}}
{{- divf (mulf (trimSuffix "k" $m | float64) 1000) 1048576 | int -}}
{{- else if hasSuffix "m" $m -}}
{{- divf (mulf (trimSuffix "m" $m | float64) 1000000) 1048576 | int -}}
{{- else if hasSuffix "g" $m -}}
{{- divf (mulf (trimSuffix "g" $m | float64) 1000000000) 1048576 | int -}}
{{- else if regexMatch "^[0-9]+$" $m -}}
{{- divf ($m | float64) 1048576 | int -}}
{{- end -}}
{{- else if not $m -}}
{{- $lim := include "redis-sentinel.memLimitMB" . -}}
{{- if $lim -}}
{{- mulf ($lim | float64) (include "redis-sentinel.maxMemoryRatio" . | float64) | int -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The redis.conf directives the persistence block owns.

Used both to filter redis.extraConfig (when the mode is declared) and to report
collisions. Deliberately excludes maxmemory / maxmemory-policy: those are the two
directives most likely to be tuned in extraConfig, and the memory block is
rendered BEFORE extraConfig so that tuning keeps winning.
*/}}
{{- define "redis-sentinel.persistence.ownedDirectives" -}}
save appendonly appendfsync appendfilename appenddirname dbfilename dir no-appendfsync-on-rewrite auto-aof-rewrite-percentage auto-aof-rewrite-min-size aof-load-truncated aof-use-rdb-preamble aof-timestamp-enabled rdbcompression rdbchecksum rdb-del-sync-files stop-writes-on-bgsave-error repl-diskless-sync repl-diskless-sync-delay repl-diskless-load replica-serve-stale-data
{{- end -}}

{{/*
Which owned directives does redis.extraConfig set? Space-joined, deduplicated,
empty when none. Drives the collision warnings.
*/}}
{{- define "redis-sentinel.extraConfigOverrides" -}}
{{- $owned := splitList " " (include "redis-sentinel.persistence.ownedDirectives" . | trim) -}}
{{- $hits := list -}}
{{- range $line := splitList "\n" (.Values.redis.extraConfig | default "") -}}
{{- $t := trim $line -}}
{{- if and $t (not (hasPrefix "#" $t)) -}}
{{- $d := first (splitList " " (replace "\t" " " $t)) -}}
{{- if has $d $owned -}}
{{- $hits = append $hits $d -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- join " " (uniq $hits) -}}
{{- end -}}

{{/*
redis.extraConfig with the owned persistence directives replaced by a comment
naming the value that supersedes them.

Only used when the mode is DECLARED. On the derived path extraConfig is emitted
untouched, in its current position, so existing releases render byte-identically.
*/}}
{{- define "redis-sentinel.extraConfig.filtered" -}}
{{- $owned := splitList " " (include "redis-sentinel.persistence.ownedDirectives" . | trim) -}}
{{- $mode := include "redis-sentinel.persistenceMode" . -}}
{{- $out := list -}}
{{- range $line := splitList "\n" (.Values.redis.extraConfig | default "") -}}
{{- $t := trim $line -}}
{{- $keep := true -}}
{{- if and $t (not (hasPrefix "#" $t)) -}}
{{- $d := first (splitList " " (replace "\t" " " $t)) -}}
{{- if has $d $owned -}}
{{- $keep = false -}}
{{- $out = append $out (printf "# ignored - redis.persistenceMode=%s owns this: %s" $mode $t) -}}
{{- end -}}
{{- end -}}
{{- if $keep -}}
{{- $out = append $out $line -}}
{{- end -}}
{{- end -}}
{{- join "\n" $out -}}
{{- end -}}
{{/* SHARED-END persistence-mode */}}

{{/*
redis-cli invocations for this pod's own Redis and its own Sentinel, as shell
FUNCTIONS rather than string variables: `$RCLI ...` relies on word splitting, so a
password containing a space or a glob breaks every call.

One definition instead of the same three-way TLS branching repeated in every probe
and hook - which is where this chart's preStop bug lives: it passes --cacert but
not --cert/--key while tls.redis.authClients defaults to TRUE, so under the default
TLS configuration the hook has always been a silent no-op.
*/}}
{{- define "redis-sentinel.rcliFunc" -}}
rcli() {
{{- if .Values.tls.enabled }}
{{- if .Values.tls.redis.authClients }}
  redis-cli -h 127.0.0.1 -p {{ .Values.tls.redis.port | default .Values.redis.port }} -a "$REDIS_PASSWORD" --tls --cert /etc/redis/tls/tls.crt --key /etc/redis/tls/tls.key --cacert /etc/redis/tls/ca.crt --no-auth-warning "$@"
{{- else }}
  redis-cli -h 127.0.0.1 -p {{ .Values.tls.redis.port | default .Values.redis.port }} -a "$REDIS_PASSWORD" --tls --cacert /etc/redis/tls/ca.crt --no-auth-warning "$@"
{{- end }}
{{- else }}
  redis-cli -h 127.0.0.1 -p {{ .Values.redis.port }} -a "$REDIS_PASSWORD" --no-auth-warning "$@"
{{- end }}
}
{{- end -}}

{{/* Same, for another node's Redis: rcli_at <host> <port> ... */}}
{{- define "redis-sentinel.rcliAtFunc" -}}
rcli_at() {
  _h=$1; _p=$2; shift 2
{{- if .Values.tls.enabled }}
{{- if .Values.tls.redis.authClients }}
  redis-cli -h "$_h" -p "$_p" -a "$REDIS_PASSWORD" --tls --cert /etc/redis/tls/tls.crt --key /etc/redis/tls/tls.key --cacert /etc/redis/tls/ca.crt --no-auth-warning "$@"
{{- else }}
  redis-cli -h "$_h" -p "$_p" -a "$REDIS_PASSWORD" --tls --cacert /etc/redis/tls/ca.crt --no-auth-warning "$@"
{{- end }}
{{- else }}
  redis-cli -h "$_h" -p "$_p" -a "$REDIS_PASSWORD" --no-auth-warning "$@"
{{- end }}
}
{{- end -}}

{{/* This pod's own Sentinel. SENTINEL_PASSWORD may legitimately be empty. */}}
{{- define "redis-sentinel.scliFunc" -}}
scli() {
{{- if .Values.tls.enabled }}
  if [ -n "$SENTINEL_PASSWORD" ]; then
    redis-cli -h 127.0.0.1 -p {{ .Values.tls.sentinel.port | default .Values.sentinel.port }} -a "$SENTINEL_PASSWORD" --tls {{ if .Values.tls.sentinel.authClients }}--cert /etc/redis/tls/tls.crt --key /etc/redis/tls/tls.key {{ end }}--cacert /etc/redis/tls/ca.crt --no-auth-warning "$@"
  else
    redis-cli -h 127.0.0.1 -p {{ .Values.tls.sentinel.port | default .Values.sentinel.port }} --tls {{ if .Values.tls.sentinel.authClients }}--cert /etc/redis/tls/tls.crt --key /etc/redis/tls/tls.key {{ end }}--cacert /etc/redis/tls/ca.crt --no-auth-warning "$@"
  fi
{{- else }}
  if [ -n "$SENTINEL_PASSWORD" ]; then
    redis-cli -h 127.0.0.1 -p {{ .Values.sentinel.port }} -a "$SENTINEL_PASSWORD" --no-auth-warning "$@"
  else
    redis-cli -h 127.0.0.1 -p {{ .Values.sentinel.port }} --no-auth-warning "$@"
  fi
{{- end }}
}
{{- end -}}

{{/*
The "is the dataset loaded?" gate. Expects $INFO to hold one `INFO` call's output.

Field polarity differs per field on purpose: `loading` is always present, so the
GOOD value is asserted and a missing field also fails (fail closed - a node that
cannot report its state must not take traffic). `async_loading` is Redis >= 7 only,
so the BAD value is asserted and absence means "not applicable", which keeps the
probe working on a pinned older image.tag.
*/}}
{{- define "redis-sentinel.probe.loadedGate" -}}
if echo "$INFO" | grep -q '^loading:1'; then
  PCT=$(echo "$INFO" | grep '^loading_loaded_perc:' | cut -d: -f2 | tr -d '\r\n ')
  ETA=$(echo "$INFO" | grep '^loading_eta_seconds:' | cut -d: -f2 | tr -d '\r\n ')
  echo "loading the dataset from disk (${PCT:-?}% done, eta ${ETA:-?}s) - cannot serve yet"
  exit 1
fi
if echo "$INFO" | grep -q '^async_loading:1'; then
  echo "async_loading in progress - cannot serve yet"
  exit 1
fi
if [ "$(echo "$INFO" | grep -c '^loading:0')" = "0" ]; then
  echo "INFO has no 'loading' field - cannot confirm the dataset is loaded, refusing"
  exit 1
fi
{{- end -}}

{{/*
The handover timeout the preStop hook actually gets, clamped to fit the grace
period. Emits an integer.

  failoverTimeoutEffective = max(5, min(failoverTimeout,
                                        TGP - shutdownTimeout - waitTimeout - 8))

Clamped in Go-template land and rendered into the script as a LITERAL: no shell
arithmetic, so the value in the log is provably the value that was used. Clamping
rather than failing, because a release can already have a combination that does
not fit and a render error would block its upgrade - NOTES.txt reports it instead.

The 8 seconds cover exec overhead plus a safety margin. What is left after the
subtraction is redis-server's own shutdown: waiting for replicas
(shutdown-timeout) and, when save points exist, the blocking RDB save SIGTERM
triggers.
*/}}
{{- define "redis-sentinel.gracefulShutdown.failoverTimeoutEffective" -}}
{{- $gsV := include "redis-sentinel.gracefulShutdownValues" . | fromYaml -}}
{{- $tgp := int (.Values.terminationGracePeriodSeconds | default 60) -}}
{{- $st := int (.Values.redis.shutdownTimeout | default 10) -}}
{{- /* Through the nil-safe view rather than `.Values.gracefulShutdown.x | default n`,
       which broke twice over: it nil-pointers when the whole map is absent (a
       --reuse-values upgrade from 1.2.x), and `default` treats 0 as empty, so an
       explicit waitTimeoutSeconds: 0 silently became 3. */ -}}
{{- $wt := int $gsV.waitTimeoutSeconds -}}
{{- $ft := int $gsV.failoverTimeout -}}
{{- $room := sub $tgp (add $st $wt 8) -}}
{{- if gt $ft $room -}}{{- $ft = $room -}}{{- end -}}
{{- if lt $ft 5 -}}{{- $ft = 5 -}}{{- end -}}
{{- $ft -}}
{{- end -}}

{{/* Another pod's Sentinel: scli_at <host> ... */}}
{{- define "redis-sentinel.scliAtFunc" -}}
scli_at() {
  _sh=$1; shift
{{- if .Values.tls.enabled }}
  if [ -n "$SENTINEL_PASSWORD" ]; then
    redis-cli -h "$_sh" -p {{ .Values.tls.sentinel.port | default .Values.sentinel.port }} -a "$SENTINEL_PASSWORD" --tls {{ if .Values.tls.sentinel.authClients }}--cert /etc/redis/tls/tls.crt --key /etc/redis/tls/tls.key {{ end }}--cacert /etc/redis/tls/ca.crt --no-auth-warning "$@"
  else
    redis-cli -h "$_sh" -p {{ .Values.tls.sentinel.port | default .Values.sentinel.port }} --tls {{ if .Values.tls.sentinel.authClients }}--cert /etc/redis/tls/tls.crt --key /etc/redis/tls/tls.key {{ end }}--cacert /etc/redis/tls/ca.crt --no-auth-warning "$@"
  fi
{{- else }}
  if [ -n "$SENTINEL_PASSWORD" ]; then
    redis-cli -h "$_sh" -p {{ .Values.sentinel.port }} -a "$SENTINEL_PASSWORD" --no-auth-warning "$@"
  else
    redis-cli -h "$_sh" -p {{ .Values.sentinel.port }} --no-auth-warning "$@"
  fi
{{- end }}
}
{{- end -}}

{{/* VALUE-DEFAULTS-BEGIN - generated by ci/check-value-defaults.py, do not edit by hand
     Nil-safe views of the value groups this release introduced.

     `helm upgrade --reuse-values` does NOT merge the new chart's defaults - it reuses the
     previous release's values as they were. A release installed on 1.2.x has none of these
     keys, so a template dereferencing them dies with
     `nil pointer evaluating interface {}.savePoints`. Measured on a live 1.2.2 -> 1.3.0
     upgrade. It fails closed, but it fails.

     Each `...Values` helper merges the user's values ON TOP of the defaults, so a missing
     group renders exactly like the chart default and a partially-set group keeps the rest.

     mergeOverwrite is the only correct primitive here. `merge` and the `default` operator
     both treat false and 0 as "empty" and restore the default over them, which would turn
     a user's `startup.enabled: false` back into true. Verified in a scratch chart:

       mergeOverwrite (deepCopy $def) (deepCopy $user)  -> {"delay":0,"enabled":false}  right
       merge (deepCopy $user) (deepCopy $def)           -> {"delay":10,"enabled":true}  WRONG
       $user.enabled | default true                     -> true                         WRONG

     Read a group with, for example:
       {{- $probes := include "redis-sentinel.probesValues" . | fromYaml }}
       ... {{ $probes.startup.failureThreshold }}
*/}}

{{- define "redis-sentinel.probesDefaults" -}}
startup:
  enabled: false
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 180
liveness:
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 5
readiness:
  initialDelaySeconds: 10
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
{{- end -}}

{{- define "redis-sentinel.probesValues" -}}
{{- mergeOverwrite (include "redis-sentinel.probesDefaults" . | fromYaml) (deepCopy ((.Values.probes) | default dict)) | toYaml -}}
{{- end -}}

{{- define "redis-sentinel.gracefulShutdownDefaults" -}}
enabled: true
failoverTimeout: 20
waitTimeoutSeconds: 3
{{- end -}}

{{- define "redis-sentinel.gracefulShutdownValues" -}}
{{- mergeOverwrite (include "redis-sentinel.gracefulShutdownDefaults" . | fromYaml) (deepCopy ((.Values.gracefulShutdown) | default dict)) | toYaml -}}
{{- end -}}

{{- define "redis-sentinel.rdbDefaults" -}}
savePoints:
- 900 1
- 300 10
- 60 10000
dbfilename: dump.rdb
compression: true
checksum: true
stopWritesOnBgsaveError: false
{{- end -}}

{{- define "redis-sentinel.rdbValues" -}}
{{- mergeOverwrite (include "redis-sentinel.rdbDefaults" . | fromYaml) (deepCopy ((.Values.redis.rdb) | default dict)) | toYaml -}}
{{- end -}}

{{- define "redis-sentinel.aofDefaults" -}}
autoRewritePercentage: 100
autoRewriteMinSize: 64mb
loadTruncated: true
useRdbPreamble: true
timestampEnabled: false
noAppendfsyncOnRewrite: false
appendfilename: appendonly.aof
appenddirname: ''
{{- end -}}

{{- define "redis-sentinel.aofValues" -}}
{{- mergeOverwrite (include "redis-sentinel.aofDefaults" . | fromYaml) (deepCopy ((.Values.redis.aof) | default dict)) | toYaml -}}
{{- end -}}

{{- define "redis-sentinel.networkDefaults" -}}
tcpBacklog: 511
timeout: 0
tcpKeepalive: 60
{{- end -}}

{{- define "redis-sentinel.networkValues" -}}
{{- mergeOverwrite (include "redis-sentinel.networkDefaults" . | fromYaml) (deepCopy ((.Values.redis.network) | default dict)) | toYaml -}}
{{- end -}}

{{- define "redis-sentinel.replicationDefaults" -}}
replDisklessSync: true
replDisklessSyncDelay: 5
replBacklogSize: ''
{{- end -}}

{{- define "redis-sentinel.replicationValues" -}}
{{- mergeOverwrite (include "redis-sentinel.replicationDefaults" . | fromYaml) (deepCopy ((.Values.redis.replication) | default dict)) | toYaml -}}
{{- end -}}

{{/* VALUE-DEFAULTS-END */}}
