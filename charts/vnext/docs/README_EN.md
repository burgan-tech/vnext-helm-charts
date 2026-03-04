# vNext Workflow Orchestration Platform - Helm Chart

A comprehensive Helm chart for deploying the vNext microservices-based workflow orchestration system on Kubernetes. Includes built-in observability, service mesh (Dapr), secrets management (Vault), and high availability features.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Configuration](#configuration)
  - [Global Configuration](#global-configuration)
  - [Core Services](#core-services)
  - [Infrastructure Components](#infrastructure-components)
  - [Observability Stack](#observability-stack)
  - [Development Tools](#development-tools)
- [Using an External Vault](#using-an-external-vault)
- [Using an External Redis](#using-an-external-redis)
- [Using an External OpenTelemetry Collector](#using-an-external-opentelemetry-collector)
- [Ingress Configuration](#ingress-configuration)
- [Autoscaling](#autoscaling)
- [Security](#security)
- [Monitoring and Health Checks](#monitoring-and-health-checks)
- [Troubleshooting](#troubleshooting)
- [Upgrade and Rollback](#upgrade-and-rollback)
- [Uninstallation](#uninstallation)
- [Parameters Reference](#parameters-reference)

## Architecture Overview

The vNext platform consists of the following core components:

| Component         | Description                                                    |
| ----------------- | -------------------------------------------------------------- |
| **Orchestrator**  | Main workflow orchestration engine managing workflow execution  |
| **Execution**     | Workflow execution engine processing workflow tasks             |
| **Worker-Inbox**  | Receives messages from the orchestrator                        |
| **Worker-Outbox** | Sends messages to the orchestrator                             |
| **Initializer**   | Runs database migrations and initialization (init job)         |

Infrastructure and supporting services:

| Component                   | Description                                                         |
| --------------------------- | ------------------------------------------------------------------- |
| **Dapr**                    | Distributed Application Runtime for service mesh, pub/sub, state    |
| **Redis Sentinel**          | High-availability Redis for caching and state storage               |
| **PostgreSQL**              | Primary relational database                                         |
| **HashiCorp Vault**         | Secrets management                                                  |
| **OpenTelemetry Collector** | Telemetry data collection and export                                |
| **Prometheus + Grafana**    | Metrics collection and visualization                                |

### Deployment Flow

1. Vault initializer job configures Vault (secret engine, policies, etc.)
2. PostgreSQL and Redis Sentinel are provisioned
3. Init job runs database migrations
4. Core services start with Dapr sidecars
5. Observability stack collects metrics and traces

## Prerequisites

- Kubernetes cluster v1.24+
- Helm v3.10+
- `kubectl` configured for the target cluster
- Sufficient cluster resources (minimum 4 CPU, 8 GB RAM recommended)
- A StorageClass provisioner for persistent volumes (if persistence is enabled)

## Quick Start

```bash
# Add chart dependencies
helm dependency build

# Install with default values
helm install vnext . -n vnext --create-namespace

# Wait for all pods to be ready
kubectl wait --for=condition=ready pod -n vnext --all --timeout=300s

# Check deployment status
helm status vnext -n vnext
```

## Installation

### 1. Clone the Repository

```bash
git clone https://github.com/burgan-tech/vnext-helm-charts.git
cd vnext-helm-charts
```

### 2. Build Dependencies

```bash
helm dependency build
```

### 3. Customize Values

Create a custom values file for your environment:

```bash
cp values.yaml my-values.yaml
```

Edit `my-values.yaml` with your environment-specific settings.

### 4. Install the Chart

```bash
helm install vnext . \
  -n vnext \
  --create-namespace \
  -f my-values.yaml
```

### 5. Verify Installation

```bash
kubectl get pods -n vnext
kubectl get svc -n vnext
helm status vnext -n vnext
```

## Configuration

### Global Configuration

Global settings are shared across all components under the `global` key.

#### Application Domain

```yaml
global:
  appDomain: "core"
```

The `appDomain` value is used for generating Dapr app IDs and service discovery. Each deployment must have a unique `appDomain` (e.g., `"banking"`, `"contract"`, `"core"`).

#### Image Pull Configuration

```yaml
global:
  imagePullPolicy: IfNotPresent
  imagePullSecrets:
    - name: regcred
```

#### .NET Runtime Settings

Common environment variables applied to all .NET services:

```yaml
global:
  dotnetEnv:
    DOTNET_NUGET_SIGNATURE_VERIFICATION: "false"
    DOTNET_USE_POLLING_FILE_WATCHER: "1"
    DOTNET_RUNNING_IN_CONTAINER: "true"
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT: "1"
    ASPNETCORE_ENVIRONMENT: "Development"
```

> **Note:** For production, set `ASPNETCORE_ENVIRONMENT` to `"Production"`.

#### Database Configuration

```yaml
global:
  database:
    connectionString: "Host=vnext-postgres-headless;Port=5432;Database=vNext_WorkflowDb;Username=vnext;Password=changeme;"
    clickhouse:
      enabled: false
      connectionString: ""
```

> **Note:** When Vault is enabled (`Vault__Enabled: "true"`), connection strings are retrieved from Vault secrets instead of the ConfigMap.

**ClickHouse Integration:** Optional ClickHouse support is available for workflow analytics. ClickHouse is not included in this chart; it must be deployed separately and configured here.

```yaml
global:
  database:
    clickhouse:
      enabled: true
      connectionString: "Host=clickhouse.analytics.svc;Port=8123;Database=workflow_analytics;Username=default;Password=your-password;"
```

#### Dapr Configuration

Global settings for Dapr service mesh integration:

```yaml
global:
  dapr:
    enabled: true
    protocol: "http"
    placementHost: "dapr-placement:50005"
    httpPort: "42110"
    grpcPort: "42111"
```

#### Telemetry Configuration

```yaml
global:
  telemetry:
    enabled: true
    protocol: "grpc"
    external:
      enabled: false
      endpoint: ""
```

#### Resource Defaults

```yaml
global:
  resources:
    default:
      limits:
        cpu: 1000m
        memory: 2Gi
      requests:
        cpu: 100m
        memory: 256Mi
```

Individual services can override these defaults by specifying their own `resources` block.

#### Health Probe Defaults

```yaml
global:
  probes:
    liveness:
      initialDelaySeconds: 35
      periodSeconds: 10
      failureThreshold: 5
      timeoutSeconds: 30
    readiness:
      initialDelaySeconds: 35
      periodSeconds: 10
      failureThreshold: 5
      successThreshold: 2
      timeoutSeconds: 30
```

#### Security Context

```yaml
global:
  securityContext:
    capabilities:
      drop:
        - ALL
    readOnlyRootFilesystem: true
    runAsNonRoot: false
```

### Core Services

#### Orchestrator

Main workflow orchestration engine:

```yaml
orchestrator:
  enabled: true
  replicaCount: 1
  image:
    repository: ghcr.io/burgan-tech/vnext/orchestrator
    tag: ""          # defaults to appVersion
    pullPolicy: ""   # uses global.imagePullPolicy if empty
  dapr:
    enabled: true
    appId: ""        # auto-generated: vnext-<appDomain>-app
    appPort: "5000"
  service:
    type: ClusterIP
    port: 5000
  appEnvConfig:
    Vault__Enabled: "true"
    Logging__LogLevel__Default: "Debug"
    SignalR__AppId: "http://localhost:6203"
```

##### Initializer (Init Job)

A sub-component of the orchestrator that runs database migrations and initialization:

```yaml
orchestrator:
  initializer:
    enabled: true
    image:
      repository: ghcr.io/burgan-tech/vnext/init
      tag: ""
    service:
      type: ClusterIP
      port: 3000
    envConfig:
      VNEXT_COMPONENT_VERSION: "0.0.18"
      NPM_REGISTRY: "https://registry.npmjs.org/"
    ingress:
      enabled: false
      className: ""
      annotations: {}
      hosts:
        - host: initializer.example.local
          paths:
            - path: /
              pathType: Prefix
      tls: []
```

#### Execution

Workflow execution engine that processes tasks. Supports notification API integration:

```yaml
execution:
  enabled: true
  replicaCount: 1
  image:
    repository: ghcr.io/burgan-tech/vnext/execution
    tag: ""
    pullPolicy: ""
  notificationBinding:
    url: ""          # notification API endpoint (e.g., "http://mockoon:3001/api/notification/send")
  dapr:
    enabled: true
    appId: ""
    appPort: "5000"
  appEnvConfig:
    Vault__Enabled: "true"
    Logging__LogLevel__Default: "Debug"
```

#### Worker-Inbox

Receives messages from the orchestrator:

```yaml
worker-inbox:
  enabled: true
  replicaCount: 1
  image:
    repository: ghcr.io/burgan-tech/vnext/inbox
    tag: ""
    pullPolicy: ""
  dapr:
    enabled: true
    appId: ""
    appPort: "5000"
  appEnvConfig:
    Vault__Enabled: "true"
    Logging__LogLevel__Default: "Debug"
    SignalR__AppId: "http://localhost:6203"
```

#### Worker-Outbox

Sends messages to the orchestrator:

```yaml
worker-outbox:
  enabled: true
  replicaCount: 1
  image:
    repository: ghcr.io/burgan-tech/vnext/outbox
    tag: ""
    pullPolicy: ""
  dapr:
    enabled: true
    appId: ""
    appPort: "5000"
  appEnvConfig:
    Vault__Enabled: "true"
    Logging__LogLevel__Default: "Debug"
    SignalR__AppId: "http://localhost:6203"
```

#### Custom Environment Variables

All services support `extraEnvConfig` for adding custom environment variables:

```yaml
orchestrator:
  extraEnvConfig:
    MY_CUSTOM_VAR: "value"
    ANOTHER_VAR: "another-value"
```

### Infrastructure Components

#### PostgreSQL

Bundled PostgreSQL database:

```yaml
postgres:
  enabled: true
  replicaCount: 1
  image:
    repository: docker.io/library/postgres
    tag: "18.0"
    imagePullPolicy: Always
  auth:
    username: "admin"
    password: "admin"
    database: "vNext_WorkflowDb"
    existingSecret: ""       # use an existing secret
  persistence:
    enabled: true
    size: 8Gi
    storageClass: ""
    accessModes:
      - ReadWriteOnce
```

##### PostgreSQL Performance Tuning

```yaml
postgres:
  config:
    postgresqlMaxConnections: 2048
    postgresqlSharedBuffers: 128MB
    postgresqlEffectiveCacheSize: 4GB
    postgresqlWorkMem: 4MB
    postgresqlMaintenanceWorkMem: 64MB
    postgresqlWalBuffers: 16MB
    postgresqlCheckpointCompletionTarget: 0.7
    postgresqlRandomPageCost: 1.1
    postgresqlLogStatement: "none"
    postgresqlLogMinDurationStatement: -1
```

##### PostgreSQL Metrics Exporter

```yaml
postgres:
  metrics:
    image:
      registry: quay.io
      repository: prometheuscommunity/postgres-exporter
      tag: "v0.18.1"
```

#### Redis Sentinel

High-availability Redis cluster:

```yaml
redis-sentinel:
  enabled: true
  replicaCount: 1
  redis:
    password: ""
    persistence:
      enabled: true
      size: 8Gi
      storageClass: ""
      accessMode: ReadWriteOnce
    maxMemory: "2560mb"
    maxMemoryPolicy: "noeviction"
```

##### Redis Security

```yaml
redis-sentinel:
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    runAsGroup: 999
    fsGroup: 999
  auth:
    existingSecret: ""
    redis:
      passwordKey: "redis-password"
    sentinel:
      passwordKey: "sentinel-password"
```

##### Redis Resource Limits

```yaml
redis-sentinel:
  resources:
    redis:
      limits:
        cpu: 1000m
        memory: 3Gi
      requests:
        cpu: 100m
        memory: 256Mi
    sentinel:
      limits:
        cpu: 200m
        memory: 256Mi
      requests:
        cpu: 50m
        memory: 64Mi
  metrics:
    enabled: true
```

#### HashiCorp Vault

```yaml
vault:
  enabled: true
  server:
    secretShares: 5
    secretThreshold: 3
  injector:
    enabled: true
  global:
    openshift: false
```

#### Dapr

Distributed Application Runtime configuration:

```yaml
dapr:
  enabled: true
  global:
    logAsJson: true
    ha:
      enabled: false
      replicaCount: "3"
    prometheus:
      enabled: true
      port: "9090"
    mtls:
      enabled: true
      workloadCertTTL: 24h
      allowedClockSkew: 15m
  runAsNonRoot: true
```

##### Dapr Sub-Components

```yaml
dapr:
  dapr_operator:
    watchInterval: "3m"
  dapr_scheduler:
    affinity: ...               # zone-aware anti-affinity
  dapr_placement:
    runAsNonRoot: true
    enableMetrics: true
  dapr_sentry:
    tls:
      root:
        ttl: 8760h             # 1 year
      issuer:
        ttl: 2160h             # 90 days
```

### Observability Stack

#### OpenTelemetry Collector

```yaml
opentelemetry-collector:
  enabled: true
  mode: deployment
  image:
    repository: "ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-k8s"
  configMap:
    create: false
    existingName: "opentelemetry-collector-config"
```

> **Note:** Collector configuration is provided via a ConfigMap created by the chart (`opentelemetry-collector-config`).

#### Prometheus + Grafana (kube-prometheus-stack)

```yaml
kube-prometheus-stack:
  enabled: true
  alertmanager:
    enabled: false
  nodeExporter:
    enabled: false
  prometheus:
    prometheusSpec:
      additionalScrapeConfigsSecret:
        enabled: true
        name: "vnext-prometheus-scrape-config"
        key: "additional-scrape-configs.yaml"
  grafana:
    defaultDashboardsEnabled: false
    sidecar:
      dashboards:
        enabled: true
        label: grafana_dashboard
        labelValue: "1"
        searchNamespace: ALL
```

Additional Prometheus scrape configuration is created as a secret by the chart. Grafana dashboards are automatically discovered from all namespaces via sidecar.

#### Dapr Dashboard

```yaml
dapr-dashboard:
  enabled: true
```

### Development Tools

These are optional tools useful during development. **Disable them in production.**

#### pgAdmin

PostgreSQL administration tool:

```yaml
pgAdmin:
  enabled: false
  auth:
    email: "admin@example.com"
    password: "admin"
  persistence:
    enabled: true
    storageClass: ""
    size: 5Gi
```

#### RedisInsight

Redis monitoring and administration tool:

```yaml
redisInsight:
  enabled: false
```

#### Mockoon (API Mocking)

Lightweight API mocking server for development and testing:

```yaml
mockoon:
  enabled: false
  service:
    port: 3001
```

#### OpenObserve

Open-source observability platform:

```yaml
openobserve:
  enabled: false
  auth:
    username: "admin@example.com"
    password: "admin"
```

## Using an External Vault

To connect to an existing Vault instance instead of the bundled one:

```yaml
global:
  externalVault:
    enabled: true
    address: "https://vault.example.com:8200"
    secretEngineName: ""      # auto-generated if empty (vnext-<appDomain>-engine)
    vaultToken: "your-token"

vault:
  enabled: false              # disable bundled Vault
```

## Using an External Redis

To connect to an existing Redis instance:

```yaml
global:
  externalRedis:
    endpoint: "redis.example.com:6379"

redis-sentinel:
  enabled: false              # disable bundled Redis
```

## Using an External OpenTelemetry Collector

```yaml
global:
  telemetry:
    enabled: true
    external:
      enabled: true
      endpoint: "http://otel-collector.observability.svc:4317"

opentelemetry-collector:
  enabled: false              # disable bundled collector
```

## Ingress Configuration

Enable ingress to expose services externally:

```yaml
orchestrator:
  ingress:
    enabled: true
    className: "nginx"
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
    hosts:
      - host: orchestrator.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: orchestrator-tls
        hosts:
          - orchestrator.example.com
```

The initializer service also supports its own ingress:

```yaml
orchestrator:
  initializer:
    ingress:
      enabled: true
      className: "nginx"
      hosts:
        - host: initializer.example.com
          paths:
            - path: /
              pathType: Prefix
```

## Autoscaling

Enable Horizontal Pod Autoscaler (HPA) for core services:

```yaml
orchestrator:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilizationPercentage: 80
    targetMemoryUtilizationPercentage: 80
```

The same structure applies to `execution`, `worker-inbox`, and `worker-outbox`.

## Security

### mTLS

Dapr mTLS is enabled by default for service-to-service communication:

```yaml
dapr:
  global:
    mtls:
      enabled: true
      workloadCertTTL: 24h
      allowedClockSkew: 15m
```

### Container Security Context

Default security context applied to all containers:

```yaml
global:
  securityContext:
    capabilities:
      drop:
        - ALL
    readOnlyRootFilesystem: true
    runAsNonRoot: false
```

### Service Account

```yaml
serviceAccount:
  create: true
  automount: true
  annotations: {}
```

### Production Checklist

- [ ] Set `ASPNETCORE_ENVIRONMENT` to `"Production"` (default: `"Development"`)
- [ ] Set `Logging__LogLevel__Default` to `"Information"` or higher (default: `"Debug"`)
- [ ] Change all default passwords (PostgreSQL, Redis, pgAdmin, OpenObserve)
- [ ] Ensure Dapr mTLS is enabled
- [ ] Configure TLS/HTTPS for ingress
- [ ] Set `runAsNonRoot: true` where possible
- [ ] Use Vault for all sensitive configuration
- [ ] Disable development tools (`pgAdmin`, `redisInsight`, `mockoon`, `openobserve`)
- [ ] Adjust resource limits and requests for your environment
- [ ] Manage PostgreSQL password via `existingSecret`

## Monitoring and Health Checks

### Health Endpoints

| Service       | Liveness  | Readiness |
| ------------- | --------- | --------- |
| Orchestrator  | `/live`   | `/ready`  |
| Execution     | `/live`   | `/ready`  |
| Worker-Inbox  | `/health` | `/health` |
| Worker-Outbox | `/health` | `/health` |

### Useful Commands

```bash
# Check pod status
kubectl get pods -n vnext

# View orchestrator logs
kubectl logs -n vnext -l app.kubernetes.io/component=orchestrator -f

# View execution logs
kubectl logs -n vnext -l app.kubernetes.io/component=execution -f

# Check all resources
kubectl get all -n vnext

# View Dapr components
kubectl get components -n vnext

# Check resource usage
kubectl top pods -n vnext
```

### Accessing Services via Port-Forward

```bash
# Orchestrator
kubectl port-forward -n vnext svc/<release>-orchestrator 5000:5000

# Grafana
kubectl port-forward -n vnext svc/<release>-grafana 3000:80

# Prometheus
kubectl port-forward -n vnext svc/<release>-kube-prometheus-stack-prometheus 9090:9090

# Vault
kubectl port-forward -n vnext svc/<release>-vault 8200:8200

# Dapr Dashboard
kubectl port-forward -n vnext svc/dapr-dashboard 8080:8080

# pgAdmin
kubectl port-forward -n vnext svc/<release>-pgadmin 8080:80

# RedisInsight
kubectl port-forward -n vnext svc/<release>-redisinsight 8001:8001

# OpenObserve
kubectl port-forward -n vnext svc/<release>-openobserve 5080:5080
```

## Troubleshooting

### Pods Not Starting

```bash
kubectl describe pod <pod-name> -n vnext
kubectl logs <pod-name> -n vnext --all-containers
```

### Database Connection Issues

```bash
kubectl exec -n vnext -it <postgres-pod> -- psql -U admin -d vNext_WorkflowDb
```

### Redis Connection Issues

```bash
kubectl exec -n vnext -it <redis-pod> -- redis-cli ping
```

### Dapr Sidecar Issues

```bash
kubectl logs <pod-name> -c daprd -n vnext
kubectl get components,configurations -n vnext
```

### Resource Constraints

```bash
kubectl describe pod <pod-name> -n vnext | grep -i "insufficient\|exceed"
kubectl get events -n vnext --sort-by='.lastTimestamp' | tail -20
```

### Vault Connection Issues

```bash
# Check Vault status
kubectl exec -n vnext -it <vault-pod> -- vault status

# View Vault logs
kubectl logs -n vnext -l app.kubernetes.io/name=vault
```

## Upgrade and Rollback

### Upgrade

```bash
# Update dependencies
helm dependency update

# Upgrade the release
helm upgrade vnext . -n vnext -f my-values.yaml

# View upgrade history
helm history vnext -n vnext
```

### Rollback

```bash
# Rollback to previous revision
helm rollback vnext -n vnext

# Rollback to a specific revision
helm rollback vnext 2 -n vnext
```

## Uninstallation

```bash
# Uninstall the release (all resources will be deleted)
helm uninstall vnext -n vnext

# Delete PVCs if you want to remove persistent data
kubectl delete pvc --all -n vnext

# Optionally delete the namespace
kubectl delete namespace vnext
```

> **Warning:** Uninstallation will delete all deployed resources. PVCs are not deleted automatically; remove them manually if you want to clean up persistent data.

## Parameters Reference

### Global Parameters

| Parameter | Description | Default |
|---|---|---|
| `global.appDomain` | Domain for Dapr app IDs and service discovery | `"core"` |
| `global.imagePullPolicy` | Default image pull policy | `IfNotPresent` |
| `global.imagePullSecrets` | Image pull secrets | `[]` |
| `global.externalVault.enabled` | Use an external Vault | `false` |
| `global.externalVault.address` | External Vault address | `""` |
| `global.externalVault.secretEngineName` | Vault secret engine name | `""` |
| `global.externalVault.vaultToken` | Vault access token | `""` |
| `global.dotnetEnv.ASPNETCORE_ENVIRONMENT` | .NET environment setting | `"Development"` |
| `global.dapr.enabled` | Enable Dapr globally | `true` |
| `global.dapr.protocol` | Dapr communication protocol | `"http"` |
| `global.telemetry.enabled` | Enable telemetry | `true` |
| `global.telemetry.external.enabled` | Use external collector | `false` |
| `global.telemetry.external.endpoint` | External collector endpoint | `""` |
| `global.database.connectionString` | PostgreSQL connection string | `"Host=vnext-postgres-headless;..."` |
| `global.database.clickhouse.enabled` | ClickHouse integration | `false` |
| `global.externalRedis.endpoint` | External Redis endpoint | `""` |
| `global.resources.default.limits.cpu` | Default CPU limit | `1000m` |
| `global.resources.default.limits.memory` | Default memory limit | `2Gi` |
| `global.resources.default.requests.cpu` | Default CPU request | `100m` |
| `global.resources.default.requests.memory` | Default memory request | `256Mi` |

### Service Parameters

| Parameter | Description | Default |
|---|---|---|
| `orchestrator.enabled` | Enable the orchestrator | `true` |
| `orchestrator.replicaCount` | Number of replicas | `1` |
| `orchestrator.image.repository` | Image repository | `ghcr.io/burgan-tech/vnext/orchestrator` |
| `orchestrator.image.tag` | Image tag (defaults to appVersion) | `""` |
| `orchestrator.dapr.enabled` | Enable Dapr sidecar | `true` |
| `orchestrator.dapr.appPort` | Application port | `"5000"` |
| `orchestrator.service.type` | Service type | `ClusterIP` |
| `orchestrator.service.port` | Service port | `5000` |
| `orchestrator.ingress.enabled` | Enable ingress | `false` |
| `orchestrator.autoscaling.enabled` | Enable HPA | `false` |
| `orchestrator.initializer.enabled` | Enable init job | `true` |
| `orchestrator.initializer.envConfig.VNEXT_COMPONENT_VERSION` | vNext component version | `"0.0.18"` |
| `execution.enabled` | Enable execution | `true` |
| `execution.notificationBinding.url` | Notification API URL | `""` |
| `worker-inbox.enabled` | Enable worker-inbox | `true` |
| `worker-outbox.enabled` | Enable worker-outbox | `true` |

### Infrastructure Parameters

| Parameter | Description | Default |
|---|---|---|
| `postgres.enabled` | Enable PostgreSQL | `true` |
| `postgres.auth.username` | Database username | `"admin"` |
| `postgres.auth.password` | Database password | `"admin"` |
| `postgres.auth.database` | Database name | `"vNext_WorkflowDb"` |
| `postgres.persistence.enabled` | Enable persistence | `true` |
| `postgres.persistence.size` | Volume size | `8Gi` |
| `redis-sentinel.enabled` | Enable Redis Sentinel | `true` |
| `redis-sentinel.replicaCount` | Number of replicas | `1` |
| `redis-sentinel.redis.password` | Redis password | `""` |
| `redis-sentinel.redis.persistence.size` | Volume size | `8Gi` |
| `vault.enabled` | Enable Vault | `true` |
| `dapr.enabled` | Enable Dapr | `true` |
| `dapr.global.ha.enabled` | High availability | `false` |
| `dapr.global.mtls.enabled` | mTLS | `true` |

### Observability Parameters

| Parameter | Description | Default |
|---|---|---|
| `opentelemetry-collector.enabled` | Enable OTel Collector | `true` |
| `kube-prometheus-stack.enabled` | Enable Prometheus + Grafana | `true` |
| `dapr-dashboard.enabled` | Enable Dapr Dashboard | `true` |

### Development Tools Parameters

| Parameter | Description | Default |
|---|---|---|
| `pgAdmin.enabled` | Enable pgAdmin | `false` |
| `pgAdmin.auth.email` | pgAdmin email | `"admin@example.com"` |
| `pgAdmin.auth.password` | pgAdmin password | `"admin"` |
| `redisInsight.enabled` | Enable RedisInsight | `false` |
| `mockoon.enabled` | Enable Mockoon | `false` |
| `mockoon.service.port` | Mockoon port | `3001` |
| `openobserve.enabled` | Enable OpenObserve | `false` |
| `openobserve.auth.username` | OpenObserve username | `"admin@example.com"` |
| `openobserve.auth.password` | OpenObserve password | `"admin"` |

## Support

- **Maintainer:** Mustafa Fidan
- **Email:** [mrmustafafidan@gmail.com](mailto:mrmustafafidan@gmail.com)
- **Issues:** [https://github.com/burgan-tech/vnext-helm-charts/issues](https://github.com/burgan-tech/vnext-helm-charts/issues)
