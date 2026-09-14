{{/*
Expand the name of the chart.
*/}}
{{- define "vnext.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "vnext.fullname" -}}
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
{{- define "vnext.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "vnext.labels" -}}
helm.sh/chart: {{ include "vnext.chart" . }}
{{ include "vnext.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "vnext.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vnext.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "vnext.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "vnext.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Component labels - adds component label to common labels
Usage: {{ include "vnext.componentLabels" (dict "context" . "component" "orchestrator") }}
*/}}
{{- define "vnext.componentLabels" -}}
{{ include "vnext.labels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Component selector labels
Usage: {{ include "vnext.componentSelectorLabels" (dict "context" . "component" "orchestrator") }}
*/}}
{{- define "vnext.componentSelectorLabels" -}}
{{ include "vnext.selectorLabels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Get image pull policy with global default fallback
Usage: {{ include "vnext.imagePullPolicy" (dict "component" .Values.orchestrator "global" .Values.global) }}
*/}}
{{- define "vnext.imagePullPolicy" -}}
{{- if .component.image.pullPolicy -}}
{{- .component.image.pullPolicy -}}
{{- else -}}
{{- .global.imagePullPolicy | default "IfNotPresent" -}}
{{- end -}}
{{- end }}

{{/*
Get image reference (supports both tag and digest)
Usage: {{ include "vnext.image" (dict "image" .Values.orchestrator.image "defaultTag" .Chart.AppVersion) }}
*/}}
{{- define "vnext.image" -}}
{{- if .image.digest -}}
{{- printf "%s@%s" .image.repository .image.digest -}}
{{- else -}}
{{- $tag := .image.tag | default .defaultTag -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}
{{- end }}

{{/*
Merge global and component security context
Usage: {{ include "vnext.securityContext" (dict "component" .Values.orchestrator "global" .Values.global) }}
*/}}
{{- define "vnext.securityContext" -}}
{{- if .component.securityContext -}}
{{- toYaml .component.securityContext -}}
{{- else if .global.securityContext -}}
{{- toYaml .global.securityContext -}}
{{- end -}}
{{- end }}

{{/*
Merge global and component resources
Usage: {{ include "vnext.resources" (dict "component" .Values.orchestrator "global" .Values.global) }}
*/}}
{{- define "vnext.resources" -}}
{{/* Precedence: (1) the component's own resources when NON-EMPTY, (2) global.resources.default
     when set (typically by an environment values file — one knob sizing every component whose
     resources is empty), (3) the component's chart-shipped resourcesFallback (the measured
     defaults). The fallback lives in its own key precisely so an environment's
     global.resources.default can win over it: Helm map-merge cannot clear a non-empty chart
     default with `resources: {}`, which is what made the previous shape (tiers directly in
     `resources`) unoverridable from an env global. */}}
{{- if .component.resources -}}
{{- toYaml .component.resources -}}
{{- else if .global.resources.default -}}
{{- toYaml .global.resources.default -}}
{{- else if .component.resourcesFallback -}}
{{- toYaml .component.resourcesFallback -}}
{{- end -}}
{{- end }}

{{/*
Generate Dapr pod annotations
Usage: {{ include "vnext.daprAnnotations" (dict "dapr" .Values.orchestrator.dapr "enabled" .Values.global.dapr.enabled "component" "orchestrator" "appDomain" .Values.global.appDomain "globalProtocol" .Values.global.dapr.protocol "logAsJson" .Values.global.dapr.logAsJson) }}
*/}}
{{- define "vnext.daprAnnotations" -}}
{{- if and .dapr.enabled .enabled -}}
dapr.io/enabled: "true"
{{- if eq .component "execution" }}
dapr.io/app-id: {{ .dapr.appId | default (printf "vnext-%s-execution-app" .appDomain) | quote }}
{{- else if eq .component "worker-inbox" }}
dapr.io/app-id: {{ .dapr.appId | default (printf "vnext-%s-worker-inbox-app" .appDomain) | quote }}
{{- else if eq .component "worker-outbox" }}
dapr.io/app-id: {{ .dapr.appId | default (printf "vnext-%s-worker-outbox-app" .appDomain) | quote }}
{{- else if eq .component "db-migrator" }}
dapr.io/app-id: {{ .dapr.appId | default (printf "vnext-%s-db-migrator-app" .appDomain) | quote }}
{{- else }}
dapr.io/app-id: {{ .dapr.appId | default (printf "vnext-%s-app" .appDomain) | quote }}
{{- end }}
{{- if ne .component "db-migrator" }}
dapr.io/app-port: {{ .dapr.appPort | quote }}
{{/* Per-component .dapr.protocol wins when set; global.dapr.protocol is the real
     fallback (not a hardcoded "http") so that global value is not dead config. Callers
     that don't pass "globalProtocol" still land on "http" via the final default. */}}
dapr.io/app-protocol: {{ .dapr.protocol | default .globalProtocol | default "http" | quote }}
{{- end }}
{{/* Sidecar log format. daprd defaults to plain text; JSON is what makes the sidecar's
     own logs parseable in Elastic alongside the app's structured logs (the app already
     ships OTLP/console via global.telemetry.logging). Distinct from dapr.global.logAsJson
     in the vendored subchart, which is the CONTROL PLANE's setting and does not reach
     these sidecars.
     Guarded with kindIs "invalid" rather than `default`/`coalesce`: this is a BOOLEAN, and
     both of those treat false as empty, which would silently ignore an explicit false. */}}
{{- if not (kindIs "invalid" .logAsJson) }}
dapr.io/log-as-json: {{ .logAsJson | quote }}
{{- end }}
{{/* Preferred body-size annotation (Dapr >= 1.13, resource-quantity string e.g. "64Mi").
     The legacy MB-integer annotation below is deprecated but still emitted when a user
     sets httpMaxRequestSize explicitly — e.g. an environment pinned to an old sidecar. */}}
{{- if .maxBodySize }}
dapr.io/max-body-size: {{ .maxBodySize | quote }}
{{- end }}
{{- if .httpMaxRequestSize }}
dapr.io/http-max-request-size: {{ .httpMaxRequestSize | quote }}
{{- end }}
{{/* Sidecar container sizing (dapr.io/sidecar-*) and shutdown behavior
     (graceful-shutdown-seconds / block-shutdown-duration) are deliberately NOT emitted by
     the chart: environments supply them through <component>.podAnnotations, which is
     flexible and avoids duplicate annotation keys against user values. Format reminders
     for those values files: graceful-shutdown-seconds is an INTEGER second count ("20" —
     a duration like "20s" fails to parse), block-shutdown-duration is a Go DURATION
     string ("30s"), and their sum must fit inside the pod's terminationGracePeriodSeconds
     (see global.terminationGracePeriodSeconds). */}}
{{- end }}
{{- end }}

{{/*
Environment variables every .NET service needs, regardless of which Dapr building
blocks it uses.

The DAPR_*_STORE_NAME keys used to live here and were emitted identically into all
five configmaps. They are now per-host in vnext.daprStoreEnvVars, because a store
name set on a host whose sidecar does NOT load that component resolves to nothing
and fails only at first use. DAPR_SECRET_STORE_NAME stays here: every host reads it
when Vault is on, and the secretstore component is deliberately unscoped.

DAPR_PUBSUB_BROADCAST_STORE_NAME moved there too, narrowed from all five hosts to
the orchestrator alone -- the only host the pubsub-broadcast component is scoped to.
Usage: {{ include "vnext.commonEnvVars" . }}
*/}}
{{- define "vnext.commonEnvVars" -}}
ASPNETCORE_URLS: "http://+:5000"
{{/* DAPR_PLACEMENT_HOST is dead config: no runtime C# reads it, and its default
     (dapr-placement:50005) names no Service this chart deploys -- the vendored
     subchart's Service is dapr-placement-server. Left in place deliberately: turning
     actors/placement off is tracked as separate work, and in production the Dapr
     control plane lives in its own namespace where the injector supplies the
     placement address itself. See docs/SIZING_PROFILES.md. */}}
DAPR_PLACEMENT_HOST: {{ .Values.global.dapr.placementHost | quote }}
DAPR_HTTP_PORT: {{ .Values.global.dapr.httpPort | quote }}
DAPR_GRPC_PORT: {{ .Values.global.dapr.grpcPort | quote }}
DAPR_SECRET_STORE_NAME: {{ printf "%s-secret" (include "vnext.fullname" .) | quote }}
{{- end }}

{{/*
Per-host Dapr store names. Emits ONLY the stores the given host actually reads,
mirroring the scope policy in vnext.daprRedisScopes -- the two are deliberate mirror
images, and the failure mode this prevents is a host holding a store name its sidecar
cannot serve.

Derived from vnext/docs/runtime/dapr-component-footprint.md, which maps building
blocks to the consumption points in code (not DI registrations, which are lazy and
prove nothing):

  DAPR_STATE_STORE_NAME   orchestrator (platform cache), execution (StateStoreTask /
                          CacheAsideTask fall back to it when a task omits storeName)
  DAPR_LOCK_STORE_NAME    orchestrator (InstanceStatusLock, TransitionLockScopeFactory,
                          DaprResourceLockService), db-migrator (SchemaMigrationRunner)
  DAPR_PUBSUB_STORE_NAME  orchestrator (OutboxWakeupEvent publish), execution
                          (domain-authored DaprPubSubTask), both workers (subscribe)
  DAPR_PUBSUB_BROADCAST_STORE_NAME
                          orchestrator ONLY -- and deliberately kept even though no
                          runtime C# reads it yet (it survives in the runtime repo's
                          launchSettings.json / .vscode/tasks.json). The
                          pubsub-broadcast component is held on the orchestrator for
                          a planned pod-to-pod invalidation path; the component and
                          the name that resolves it have to be kept or dropped
                          TOGETHER, or the orchestrator ends up with a component it
                          cannot address. It was previously emitted for all five
                          hosts, four of which never load the component.

Usage: {{ include "vnext.daprStoreEnvVars" (dict "root" . "component" "worker-inbox") }}
*/}}
{{- define "vnext.daprStoreEnvVars" -}}
{{- $full := include "vnext.fullname" .root -}}
{{- $c := .component -}}
{{- if has $c (list "orchestrator" "execution") }}
DAPR_STATE_STORE_NAME: {{ printf "%s-state" $full | quote }}
{{- end }}
{{- if has $c (list "orchestrator" "db-migrator") }}
DAPR_LOCK_STORE_NAME: {{ printf "%s-redis-lock" $full | quote }}
{{- end }}
{{- if has $c (list "orchestrator" "execution" "worker-inbox" "worker-outbox") }}
DAPR_PUBSUB_STORE_NAME: {{ printf "%s-pubsub" $full | quote }}
{{- end }}
{{- if has $c (list "orchestrator") }}
DAPR_PUBSUB_BROADCAST_STORE_NAME: {{ printf "%s-pubsub-broadcast" $full | quote }}
{{- end }}
{{- end }}

{{/*
Generate global dotnet environment variables
Usage: {{ include "vnext.dotnetEnvVars" .Values.global.dotnetEnv }}
*/}}
{{- define "vnext.dotnetEnvVars" -}}
{{- range $key, $value := . }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- end }}

{{/*
Generate application-level environment variables
Usage: {{ include "vnext.appEnvVars" .Values.global.appEnvConfig }}
*/}}
{{- define "vnext.appEnvVars" -}}
{{- range $key, $value := . }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- end }}

{{/*
Generate telemetry environment variables
Usage: {{ include "vnext.telemetryEnvVars" (dict "serviceName" "vnext-app" "serviceVersion" (.Values.orchestrator.image.tag | default .Chart.AppVersion) "global" .Values.global "context" .) }}
*/}}
{{- define "vnext.telemetryEnvVars" -}}
{{- if .global.telemetry.enabled -}}
Telemetry__ServiceName: {{ .serviceName | quote }}
Telemetry__ServiceNamespace: {{ .global.appDomain | quote }}
{{- if .serviceVersion }}
Telemetry__ServiceVersion: {{ .serviceVersion | quote }}
{{- end }}
Telemetry__Otlp__Endpoint: {{ include "vnext.otelEndpoint" .context | quote }}
Telemetry__Otlp__Protocol: {{ .global.telemetry.protocol | quote }}
OTEL_SERVICE_NAME: {{ .serviceName | quote }}
{{- if .serviceVersion }}
OTEL_SERVICE_VERSION: {{ .serviceVersion | quote }}
{{- end }}
OTEL_EXPORTER_OTLP_ENDPOINT: {{ include "vnext.otelEndpoint" .context | quote }}
OTEL_EXPORTER_OTLP_PROTOCOL: {{ .global.telemetry.protocol | quote }}
{{- end -}}
{{- end }}

{{/*
Generate liveness probe configuration with global defaults
Usage: {{ include "vnext.livenessProbe" (dict "probe" .Values.orchestrator.livenessProbe "global" .Values.global.probes.liveness) }}
*/}}
{{- define "vnext.livenessProbe" -}}
{{- if .probe -}}
{{- if .probe.httpGet -}}
httpGet:
  {{- toYaml .probe.httpGet | nindent 2 }}
{{- else if .probe.exec -}}
exec:
  {{- toYaml .probe.exec | nindent 2 }}
{{- else if .probe.tcpSocket -}}
tcpSocket:
  {{- toYaml .probe.tcpSocket | nindent 2 }}
{{- end }}
initialDelaySeconds: {{ .probe.initialDelaySeconds | default .global.initialDelaySeconds }}
periodSeconds: {{ .probe.periodSeconds | default .global.periodSeconds }}
failureThreshold: {{ .probe.failureThreshold | default .global.failureThreshold }}
timeoutSeconds: {{ .probe.timeoutSeconds | default .global.timeoutSeconds }}
{{- end -}}
{{- end }}

{{/*
Generate readiness probe configuration with global defaults
Usage: {{ include "vnext.readinessProbe" (dict "probe" .Values.orchestrator.readinessProbe "global" .Values.global.probes.readiness) }}
*/}}
{{- define "vnext.readinessProbe" -}}
{{- if .probe -}}
{{- if .probe.httpGet -}}
httpGet:
  {{- toYaml .probe.httpGet | nindent 2 }}
{{- else if .probe.exec -}}
exec:
  {{- toYaml .probe.exec | nindent 2 }}
{{- else if .probe.tcpSocket -}}
tcpSocket:
  {{- toYaml .probe.tcpSocket | nindent 2 }}
{{- end }}
initialDelaySeconds: {{ .probe.initialDelaySeconds | default .global.initialDelaySeconds }}
periodSeconds: {{ .probe.periodSeconds | default .global.periodSeconds }}
failureThreshold: {{ .probe.failureThreshold | default .global.failureThreshold }}
successThreshold: {{ .probe.successThreshold | default .global.successThreshold }}
timeoutSeconds: {{ .probe.timeoutSeconds | default .global.timeoutSeconds }}
{{- end -}}
{{- end }}

{{/*
Extract PostgreSQL major version from image tag
*/}}
{{- define "vnext.postgres.majorVersion" -}}
{{- $tag := .Values.postgres.image.tag -}}
{{- if contains "@" $tag -}}
  {{- $tag = (split "@" $tag)._0 -}}
{{- end -}}
{{- if contains "." $tag -}}
  {{- (split "." $tag)._0 -}}
{{- else -}}
  {{- $tag -}}
{{- end -}}
{{- end }}

{{/*
Return PGDATA path based on major version
For PostgreSQL 18+, use version-specific PGDATA; for older versions use traditional PGDATA
*/}}
{{- define "vnext.postgres.pgdataPath" -}}
{{- $majorVersion := include "vnext.postgres.majorVersion" . | int -}}
{{- if ge $majorVersion 18 -}}
{{- printf "/var/lib/postgresql/%d/docker" $majorVersion -}}
{{- else -}}
{{- printf "/var/lib/postgresql/data/pgdata" -}}
{{- end -}}
{{- end }}

{{/*
Return PostgreSQL data directory based on major version
For PostgreSQL 18+, use version-specific path; for older versions use traditional path
*/}}
{{- define "vnext.postgres.dataDir" -}}
{{- $majorVersion := include "vnext.postgres.majorVersion" . | int -}}
{{- if ge $majorVersion 18 -}}
{{- printf "/var/lib/postgresql" -}}
{{- else -}}
{{- printf "/var/lib/postgresql/data" -}}
{{- end -}}
{{- end }}

{{/*
Return PostgreSQL initialization scripts ConfigMap name
*/}}
{{- define "vnext.postgres.initdb.scriptsCM" -}}
{{- if .Values.postgres.initdb.scriptsConfigMap -}}
    {{- printf "%s" (tpl .Values.postgres.initdb.scriptsConfigMap $) -}}
{{- else -}}
    {{- printf "%s-postgres-init-scripts" (include "vnext.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Render a value that contains template perhaps
*/}}
{{- define "vnext.tplvalues.render" -}}
  {{- $value := typeIs "string" .value | ternary .value (.value | toYaml) }}
  {{- if contains "{{" (toString $value) }}
    {{- tpl $value .context }}
  {{- else }}
    {{- $value }}
  {{- end }}
{{- end -}}

{{/*
Validate required values
*/}}
{{- define "vnext.validateValues" -}}
{{- $messages := list -}}

{{/* Validate global.appDomain is set */}}
{{- if not .Values.global.appDomain -}}
{{- $messages = append $messages "global.appDomain is required" -}}
{{- end -}}

{{/* Validate database connection when vault is disabled */}}
{{- if and .Values.orchestrator.enabled (eq .Values.orchestrator.appEnvConfig.Vault__Enabled "false") -}}
  {{- if not .Values.global.database.connectionString -}}
  {{- $messages = append $messages "global.database.connectionString is required when Vault is disabled" -}}
  {{- end -}}
{{- end -}}

{{/* Validate Cosign keyless configuration when enabled */}}
{{- if .Values.global.cosign.enabled -}}
  {{- if not .Values.global.cosign.keyless.issuer -}}
    {{- $messages = append $messages "global.cosign.keyless.issuer is required when cosign verification is enabled" -}}
  {{- end -}}
  {{- if not .Values.global.cosign.keyless.subject -}}
    {{- $messages = append $messages "global.cosign.keyless.subject is required when cosign verification is enabled" -}}
  {{- end -}}
{{- end -}}

{{/* Validate plugins configuration */}}
{{- if and .Values.orchestrator.plugins .Values.orchestrator.plugins.enabled -}}
  {{- range $i, $repo := .Values.orchestrator.plugins.repos -}}
    {{- if not $repo.url -}}
      {{- $messages = append $messages (printf "orchestrator.plugins.repos[%d].url is required" $i) -}}
    {{- end -}}
  {{- end -}}
  {{- $persistence := .Values.orchestrator.plugins.persistence | default dict -}}
  {{- if and (not $persistence.existingClaim) (ne ($persistence.accessMode | default "ReadWriteMany") "ReadWriteMany") -}}
    {{- $messages = append $messages "orchestrator.plugins.persistence.accessMode should be ReadWriteMany so multiple pods can share the plugins" -}}
  {{- end -}}
{{- end -}}

{{/* Output validation errors if any */}}
{{- if $messages -}}
{{- printf "\nVALUES VALIDATION ERRORS:\n" -}}
{{- range $messages -}}
{{- printf "  - %s\n" . -}}
{{- end -}}
{{- fail "Values validation failed" -}}
{{- end -}}
{{- end -}}

{{/*
Get Redis endpoint with fallback
Generates comma-separated sentinel host list based on replicaCount
Usage: {{ include "vnext.redisEndpoint" . }}
*/}}
{{- define "vnext.redisEndpoint" -}}
{{- if .Values.global.externalRedis.endpoint -}}
{{- .Values.global.externalRedis.endpoint -}}
{{- else -}}
{{- $fullName := include "vnext.fullname" . -}}
{{- $replicaCount := int (index .Values "redis-sentinel" "replicaCount") -}}
{{- $port := int (index .Values "redis-sentinel" "sentinel" "port") -}}
{{- $headless := printf "%s-redis-sentinel-headless" $fullName -}}
{{- range $i := until $replicaCount -}}
{{- if $i }},{{ end -}}
{{- printf "%s-redis-sentinel-%d.%s:%d" $fullName $i $headless $port -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Dapr Redis client connection metadata, shared by every Redis-backed component
(state, pubsub, pubsub-broadcast, configuration, lock).

WHY THIS EXISTS: with poolSize unset, the go-redis client Dapr embeds derives its
pool from GOMAXPROCS -- i.e. the NODE's core count, not the sidecar's CPU limit.
On large workers that is hundreds of connections per component. It used to be worse:
the components declared no scopes, so every sidecar in the namespace loaded all five.
They are now scoped per host (see vnext.daprRedisScopes) and the configuration
component is gone, so the budget is a per-host sum rather than pods x 5.

A key set to "" is OMITTED rather than emitted as an empty value, which is the only
way an environment can hand a setting back to the client's own default: Helm's
coalesce restores a chart default over `null`, so `null` cannot clear these.
Usage: {{ include "vnext.daprRedisConnectionMetadata" . | trim | nindent 2 }}
*/}}
{{- define "vnext.daprRedisConnectionMetadata" -}}
{{- $r := .Values.global.dapr.redis | default dict -}}
{{- range $k := list "poolSize" "minIdleConns" "idleTimeout" "dialTimeout" "readTimeout" "writeTimeout" "maxRetries" "maxRetryBackoff" }}
{{- $v := get $r $k -}}
{{- if and (not (kindIs "invalid" $v)) (ne ($v | toString) "") }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Dapr Redis pub/sub-only metadata. Bounds in-flight handler invocations and caps
stream length, which is what keeps a backed-up consumer from growing the stream
past maxmemory (the policy is noeviction, so a full Redis REJECTS writes).
Same ""-omits-the-key contract as the connection metadata above.
Usage: {{ include "vnext.daprRedisPubsubMetadata" . | trim | nindent 2 }}
*/}}
{{- define "vnext.daprRedisPubsubMetadata" -}}
{{- $p := (.Values.global.dapr.redis | default dict).pubsub | default dict -}}
{{- range $k := list "concurrency" "processingTimeout" "redeliverInterval" "queueDepth" "maxLenApprox" }}
{{- $v := get $p $k -}}
{{- if and (not (kindIs "invalid" $v)) (ne ($v | toString) "") }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
scopes block for a Redis component -- CHART POLICY, not an operator guess.

An unscoped Dapr component is loaded by EVERY sidecar in the namespace, and each one
costs a Redis client and a connection pool whether the app calls it or not. The
defaults below come from vnext/docs/runtime/dapr-component-footprint.md, which maps
each building block to the consumption points in code:

  state             orchestrator (platform cache: CacheSet, ComponentCacheStore,
                    StateFunctionCache, DistributedCacheIdempotencyStore ...)
                    execution   (DaprStateStoreClient; a StateStoreTask or
                                CacheAsideTask with no storeName falls back to it)
  lock              orchestrator (InstanceStatusLock, TransitionLockScopeFactory,
                                DiscoveryCacheRefresher, DaprResourceLockService)
                    db-migrator (SchemaMigrationOrchestrator.MigrateSchemaWithLockAsync)
  pubsub            orchestrator (publishes OutboxWakeupEvent), worker-inbox and
                    worker-outbox (subscribe), execution (domain-authored
                    DaprPubSubTask -- see the note below)
  pubsubBroadcast   orchestrator only; held for a planned pod-to-pod invalidation
                    path, read by no C# code today

execution is included in `pubsub` on purpose even though the audit marks it
"domain-authored only": domains are authored independently, and an execution sidecar
outside the scope fails when a DaprPubSubTask first runs -- at RUNTIME, not at render.
One pool per execution pod is cheap insurance. Remove it via the override below once
you have confirmed no domain publishes from a task.

db-migrator is easy to forget: it is a Job, but it DOES get a sidecar
(db-migrator-job.yaml calls vnext.daprAnnotations), so leaving it out of `lock` fails
the migration. mcp-server has no sidecar at all and is never a scope member.

The secretstore component is deliberately NOT scoped: every Redis component names it
as auth.secretStore, and it is create-once (lookup guard + resource-policy: keep), so
a scope added later would not even be applied to an existing release.

Override per component with global.dapr.redis.scopes.<key>, which REPLACES the default
list (it does not merge). An explicit empty list restores the unscoped
load-everywhere behaviour.
Usage: {{ include "vnext.daprRedisScopes" (dict "root" . "key" "state") }}
*/}}
{{- define "vnext.daprRedisScopes" -}}
{{- $d := .root.Values.global.appDomain -}}
{{- $defaults := dict
      "state"           (list "orchestrator" "execution")
      "lock"            (list "orchestrator" "db-migrator")
      "pubsub"          (list "orchestrator" "execution" "worker-inbox" "worker-outbox")
      "pubsubBroadcast" (list "orchestrator")
-}}
{{- $override := index ((.root.Values.global.dapr.redis | default dict).scopes | default dict) .key -}}
{{- $scopes := list -}}
{{- if not (kindIs "invalid" $override) -}}
{{/* Operator-supplied app-ids are used verbatim -- they may name sidecars this chart
     does not create (e.g. a cross-domain caller). */}}
{{- $scopes = $override -}}
{{- else -}}
{{- range $comp := (index $defaults .key | default list) -}}
{{- $scopes = append $scopes (include "vnext.daprAppId" (dict "component" $comp "appDomain" $d)) -}}
{{- end -}}
{{- end -}}
{{- with $scopes }}
scopes:
{{- range . }}
- {{ . | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Get Vault address with fallback
Usage: {{ include "vnext.vaultAddress" . }}
*/}}
{{- define "vnext.vaultAddress" -}}
{{- if .Values.global.externalVault.enabled -}}
{{- .Values.global.externalVault.address -}}
{{- else -}}
{{- printf "http://%s-vault:8200" (include "vnext.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Get OpenTelemetry endpoint with fallback
Usage: {{ include "vnext.otelEndpoint" . }}
*/}}
{{- define "vnext.otelEndpoint" -}}
{{- if .Values.global.telemetry.external.enabled -}}
{{- .Values.global.telemetry.external.endpoint -}}
{{- else -}}
{{- printf "http://%s-opentelemetry-collector:4317" (include "vnext.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Component-specific Dapr app ID. MUST stay in lockstep with vnext.daprAnnotations,
which is what actually injects dapr.io/app-id -- a divergence here silently produces
scopes and env values that name a sidecar that does not exist.

This helper previously collapsed worker-inbox, worker-outbox and db-migrator to
`vnext-<d>-app`, which is wrong for all three; it was dead code at the time, so
nothing broke, but it is now load-bearing for scope generation.

mcp-server is deliberately absent: templates/mcp-server/deployment.yaml never calls
vnext.daprAnnotations, so it has no sidecar and can never be a legitimate scope member.
Usage: {{ include "vnext.daprAppId" (dict "component" "worker-inbox" "appDomain" .Values.global.appDomain) }}
*/}}
{{- define "vnext.daprAppId" -}}
{{- if eq .component "execution" -}}
{{- printf "vnext-%s-execution-app" .appDomain -}}
{{- else if eq .component "worker-inbox" -}}
{{- printf "vnext-%s-worker-inbox-app" .appDomain -}}
{{- else if eq .component "worker-outbox" -}}
{{- printf "vnext-%s-worker-outbox-app" .appDomain -}}
{{- else if eq .component "db-migrator" -}}
{{- printf "vnext-%s-db-migrator-app" .appDomain -}}
{{- else -}}
{{- printf "vnext-%s-app" .appDomain -}}
{{- end -}}
{{- end -}}

{{/*
Check if a component is enabled
Usage: {{ include "vnext.componentEnabled" (dict "component" .Values.orchestrator) }}
*/}}
{{- define "vnext.componentEnabled" -}}
{{- if hasKey .component "enabled" -}}
{{- .component.enabled -}}
{{- else -}}
true
{{- end -}}
{{- end -}}

{{/*
==============================================================================
PLUGINS
Helpers for the plugins feature (configured under .Values.orchestrator.plugins).
A single populator Job (see templates/plugins/job.yaml) reconciles a
ReadWriteMany PVC to match the `pluginNames` allowlist of DLL file names;
consumers mount the PVC read-only. Missing DLLs are copied flat into mountPath
(last repo wins on duplicate names); DLLs already present are left untouched
unless forceRefresh is set; files dropped from the list are removed. Because
the Job is the only writer, no lock is needed.
==============================================================================
*/}}

{{/*
Whether plugin fetching is active (enabled and at least one repo defined).
Usage: {{ if eq (include "vnext.plugins.enabled" .) "true" }}
*/}}
{{- define "vnext.plugins.enabled" -}}
{{- $p := .Values.orchestrator.plugins | default dict -}}
{{- if and $p.enabled $p.repos -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/*
Name of the generated Secret that holds inline (dev) plugin tokens.
*/}}
{{- define "vnext.plugins.secretName" -}}
{{- printf "%s-plugin-tokens" (include "vnext.fullname" .) -}}
{{- end -}}

{{/*
Name of the PVC backing the plugins (existingClaim override or generated).
*/}}
{{- define "vnext.plugins.claimName" -}}
{{- $persistence := .Values.orchestrator.plugins.persistence | default dict -}}
{{- if $persistence.existingClaim -}}
{{- $persistence.existingClaim -}}
{{- else -}}
{{- printf "%s-plugins" (include "vnext.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
The shared PVC volume that holds the cloned plugins.
Usage: {{ include "vnext.plugins.volume" . | nindent 8 }}
*/}}
{{- define "vnext.plugins.volume" -}}
{{- if eq (include "vnext.plugins.enabled" .) "true" -}}
- name: plugins
  persistentVolumeClaim:
    claimName: {{ include "vnext.plugins.claimName" . }}
{{- end -}}
{{- end -}}

{{/*
The read-only mount of the plugins volume into a consuming container.
Usage: {{ include "vnext.plugins.volumeMount" . | nindent 12 }}
*/}}
{{- define "vnext.plugins.volumeMount" -}}
{{- if eq (include "vnext.plugins.enabled" .) "true" -}}
{{- $p := .Values.orchestrator.plugins -}}
- name: plugins
  mountPath: {{ $p.mountPath | default "/app/assemblies" }}
  readOnly: true
{{- end -}}
{{- end -}}

{{/*
Default preferred pod anti-affinity for a scalable component: spread the component's
replicas across nodes. preferred (not required) so a small cluster can still schedule
more replicas than nodes; weight 100 so the scheduler treats it as the dominant soft
rule. Rendered ONLY when the component's .affinity value is empty — a non-empty
<component>.affinity replaces this wholesale (no merge), same contract as every other
value-driven block in these deployments.
Usage: {{ include "vnext.defaultPodAntiAffinity" (dict "context" . "component" "orchestrator") }}
*/}}
{{- define "vnext.defaultPodAntiAffinity" -}}
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            {{- include "vnext.componentSelectorLabels" (dict "context" .context "component" .component) | nindent 12 }}
{{- end -}}

{{/*
Token env vars for the plugin-fetcher Job. Each repo's token comes from the
resolved secret (per-repo existingSecret -> defaultAuth -> generated inline
secret) and never appears in the rendered manifest as plaintext.
Usage: {{ include "vnext.plugins.tokenEnv" . | nindent 12 }}
*/}}
{{- define "vnext.plugins.tokenEnv" -}}
{{- $p := .Values.orchestrator.plugins -}}
{{- $genSecret := include "vnext.plugins.secretName" . -}}
{{- range $i, $repo := $p.repos }}
{{- $auth := $repo.auth | default $p.defaultAuth | default dict }}
{{- if $auth.existingSecret }}
- name: PLUGIN_TOKEN_{{ $i }}
  valueFrom:
    secretKeyRef:
      name: {{ $auth.existingSecret }}
      key: {{ $auth.tokenKey | default "token" }}
{{- else if $auth.token }}
- name: PLUGIN_TOKEN_{{ $i }}
  valueFrom:
    secretKeyRef:
      name: {{ $genSecret }}
      key: {{ printf "plugin-%d-token" $i }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Name of the ConfigMap holding runtimeconfig.json.
*/}}
{{- define "vnext.runtimeConfig.name" -}}
{{- printf "%s-runtime-config" (include "vnext.fullname" .) -}}
{{- end -}}

{{/*
The ConfigMap volume carrying runtimeconfig.json.
Usage: {{ include "vnext.runtimeConfig.volume" . | nindent 8 }}
*/}}
{{- define "vnext.runtimeConfig.volume" -}}
{{- if .Values.global.runtimeConfigJson -}}
- name: runtime-config
  configMap:
    name: {{ include "vnext.runtimeConfig.name" . }}
{{- end -}}
{{- end -}}

{{/*
Mounts runtimeconfig.json as a single file under /app. A subPath mount is used
on purpose: /app already holds the application, so mounting the ConfigMap as a
directory would shadow it.
Note: subPath mounts are not refreshed when the ConfigMap changes, so consuming
deployments carry a checksum/runtime-config annotation to force a pod roll.
Usage: {{ include "vnext.runtimeConfig.volumeMount" . | nindent 12 }}
*/}}
{{- define "vnext.runtimeConfig.volumeMount" -}}
{{- if .Values.global.runtimeConfigJson -}}
- name: runtime-config
  mountPath: /app/runtimeconfig.json
  subPath: runtimeconfig.json
  readOnly: true
{{- end -}}
{{- end -}}
