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
Get image reference
Usage: {{ include "vnext.image" (dict "image" .Values.orchestrator.image "defaultTag" .Chart.AppVersion) }}
*/}}
{{- define "vnext.image" -}}
{{- $tag := .image.tag | default .defaultTag -}}
{{- printf "%s:%s" .image.repository $tag -}}
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
{{- if .component.resources -}}
{{- toYaml .component.resources -}}
{{- else if .global.resources.default -}}
{{- toYaml .global.resources.default -}}
{{- end -}}
{{- end }}

{{/*
Generate Dapr pod annotations
Usage: {{ include "vnext.daprAnnotations" (dict "dapr" .Values.orchestrator.dapr "enabled" .Values.global.dapr.enabled "component" "orchestrator" "appDomain" .Values.global.appDomain) }}
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
{{- else }}
dapr.io/app-id: {{ .dapr.appId | default (printf "vnext-%s-app" .appDomain) | quote }}
{{- end }}
dapr.io/app-port: {{ .dapr.appPort | quote }}
dapr.io/app-protocol: {{ .dapr.protocol | default "http" | quote }}
{{- end }}
{{- end }}

{{/*
Generate common environment variables for .NET services
Usage: {{ include "vnext.commonEnvVars" . }}
*/}}
{{- define "vnext.commonEnvVars" -}}
ASPNETCORE_URLS: "http://+:5000"
DAPR_PLACEMENT_HOST: {{ .Values.global.dapr.placementHost | quote }}
DAPR_HTTP_PORT: {{ .Values.global.dapr.httpPort | quote }}
DAPR_GRPC_PORT: {{ .Values.global.dapr.grpcPort | quote }}
DAPR_SECRET_STORE_NAME: {{ printf "%s-secret" (include "vnext.fullname" .) | quote }}
DAPR_STATE_STORE_NAME: {{ printf "%s-state" (include "vnext.fullname" .) | quote }}
DAPR_PUBSUB_STORE_NAME: {{ printf "%s-pubsub" (include "vnext.fullname" .) | quote }}
DAPR_PUBSUB_BROADCAST_STORE_NAME: {{ printf "%s-pubsub-broadcast" (include "vnext.fullname" .) | quote }}
DAPR_LOCK_STORE_NAME: {{ printf "%s-redis-lock" (include "vnext.fullname" .) | quote }}
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
Usage: {{ include "vnext.telemetryEnvVars" (dict "serviceName" "vnext-app" "global" .Values.global "context" .) }}
*/}}
{{- define "vnext.telemetryEnvVars" -}}
{{- if .global.telemetry.enabled -}}
Telemetry__ServiceName: {{ .serviceName | quote }}
Telemetry__Otlp__Endpoint: {{ include "vnext.otelEndpoint" .context | quote }}
Telemetry__Otlp__Protocol: {{ .global.telemetry.protocol | quote }}
OTEL_SERVICE_NAME: {{ .serviceName | quote }}
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
Usage: {{ include "vnext.redisEndpoint" . }}
*/}}
{{- define "vnext.redisEndpoint" -}}
{{- if .Values.global.externalRedis.endpoint -}}
{{- .Values.global.externalRedis.endpoint -}}
{{- else -}}
{{- printf "%s-redis-sentinel-headless:6379" (include "vnext.fullname" .) -}}
{{- end -}}
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
Generate component-specific app ID for Dapr
Usage: {{ include "vnext.daprAppId" (dict "component" "orchestrator" "appDomain" .Values.global.appDomain) }}
*/}}
{{- define "vnext.daprAppId" -}}
{{- if eq .component "execution" -}}
{{- printf "vnext-%s-execution-app" .appDomain -}}
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
