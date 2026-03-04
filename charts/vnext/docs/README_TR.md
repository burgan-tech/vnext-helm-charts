# vNext Workflow Orchestration Platform - Helm Chart

Kubernetes üzerinde vNext mikro servis tabanlı iş akışı orkestrasyon sistemini dağıtmak için kapsamlı bir Helm chart. Yerleşik gözlemlenebilirlik, servis mesh (Dapr), gizli bilgi yönetimi (Vault) ve yüksek erişilebilirlik özellikleri içerir.

## İçindekiler

- [Mimari Genel Bakış](#mimari-genel-bakış)
- [Ön Gereksinimler](#ön-gereksinimler)
- [Hızlı Başlangıç](#hızlı-başlangıç)
- [Kurulum](#kurulum)
- [Yapılandırma](#yapılandırma)
  - [Global Yapılandırma](#global-yapılandırma)
  - [Çekirdek Servisler](#çekirdek-servisler)
  - [Altyapı Bileşenleri](#altyapı-bileşenleri)
  - [Gözlemlenebilirlik Bileşenleri](#gözlemlenebilirlik-bileşenleri)
  - [Geliştirme Araçları](#geliştirme-araçları)
- [Harici Vault Kullanımı](#harici-vault-kullanımı)
- [Harici Redis Kullanımı](#harici-redis-kullanımı)
- [Harici OpenTelemetry Collector Kullanımı](#harici-opentelemetry-collector-kullanımı)
- [Ingress Yapılandırması](#ingress-yapılandırması)
- [Otomatik Ölçeklendirme](#otomatik-ölçeklendirme)
- [Güvenlik](#güvenlik)
- [İzleme ve Sağlık Kontrolleri](#izleme-ve-sağlık-kontrolleri)
- [Sorun Giderme](#sorun-giderme)
- [Güncelleme ve Geri Alma](#güncelleme-ve-geri-alma)
- [Kaldırma](#kaldırma)
- [Parametreler Referansı](#parametreler-referansı)

## Mimari Genel Bakış

vNext platformu aşağıdaki çekirdek bileşenlerden oluşur:

| Bileşen           | Açıklama                                                               |
| ----------------- | ---------------------------------------------------------------------- |
| **Orchestrator**  | İş akışı yürütmesini yöneten ana orkestrasyon motoru                   |
| **Execution**     | İş akışı görevlerini işleyen yürütme motoru                            |
| **Worker-Inbox**  | Orchestrator'dan mesaj alan servis                                     |
| **Worker-Outbox** | Orchestrator'a mesaj gönderen servis                                   |
| **Initializer**   | Veritabanı migrasyonlarını ve başlangıç ayarlarını çalıştıran init job |

Altyapı ve destekleyici servisler:

| Bileşen                     | Açıklama                                                                    |
| --------------------------- | --------------------------------------------------------------------------- |
| **Dapr**                    | Servis mesh, pub/sub, state management için dağıtık uygulama çalışma zamanı |
| **Redis Sentinel**          | Önbellek ve state yönetimi için yüksek erişilebilir Redis                   |
| **PostgreSQL**              | Ana ilişkisel veritabanı                                                    |
| **HashiCorp Vault**         | Gizli bilgi yönetimi                                                        |
| **OpenTelemetry Collector** | Telemetri verisi toplama ve dışa aktarma                                    |
| **Prometheus + Grafana**    | Metrik toplama ve görselleştirme                                            |

### Dağıtım Akışı

1. Vault initializer job'ı Vault'u yapılandırır (secret engine, policy vb.)
2. PostgreSQL ve Redis Sentinel hazırlanır
3. Init job veritabanı migrasyonlarını çalıştırır
4. Çekirdek servisler Dapr sidecar'ları ile başlar
5. Gözlemlenebilirlik bileşenleri metrik ve trace verisi toplar

## Ön Gereksinimler

- Kubernetes cluster v1.24+
- Helm v3.10+
- Hedef cluster için yapılandırılmış `kubectl`
- Yeterli cluster kaynakları (minimum 4 CPU, 8 GB RAM önerilir)
- Kalıcı diskler için bir StorageClass provisioner (persistence etkinse)

## Hızlı Başlangıç

```bash
# Chart bağımlılıklarını indir
helm dependency build

# Varsayılan değerlerle kur
helm install vnext . -n vnext --create-namespace

# Tüm pod'ların hazır olmasını bekle
kubectl wait --for=condition=ready pod -n vnext --all --timeout=300s

# Dağıtım durumunu kontrol et
helm status vnext -n vnext
```

## Kurulum

### 1. Repository'yi Klonla

```bash
git clone https://github.com/burgan-tech/vnext-helm-charts.git
cd vnext-helm-charts
```

### 2. Bağımlılıkları İndir

```bash
helm dependency build
```

### 3. Değerleri Özelleştir

Ortamınıza özel bir values dosyası oluşturun:

```bash
cp values.yaml my-values.yaml
```

`my-values.yaml` dosyasını ortamınıza uygun şekilde düzenleyin.

### 4. Chart'ı Kur

```bash
helm install vnext . \
  -n vnext \
  --create-namespace \
  -f my-values.yaml
```

### 5. Kurulumu Doğrula

```bash
kubectl get pods -n vnext
kubectl get svc -n vnext
helm status vnext -n vnext
```

## Yapılandırma

### Global Yapılandırma

Global ayarlar `global` anahtarı altında tüm bileşenler tarafından paylaşılır.

#### Uygulama Domain'i

```yaml
global:
  appDomain: "core"
```

`appDomain` değeri Dapr uygulama kimliklerini ve servis keşfini oluşturmak için kullanılır. Her dağıtımın benzersiz bir `appDomain` değerine sahip olması gerekir (örn. `"banking"`, `"contract"`, `"core"`).

#### Image Pull Yapılandırması

```yaml
global:
  imagePullPolicy: IfNotPresent
  imagePullSecrets:
    - name: regcred
```

#### .NET Çalışma Zamanı Ayarları

Tüm .NET servislerine uygulanan ortak ortam değişkenleri:

```yaml
global:
  dotnetEnv:
    DOTNET_NUGET_SIGNATURE_VERIFICATION: "false"
    DOTNET_USE_POLLING_FILE_WATCHER: "1"
    DOTNET_RUNNING_IN_CONTAINER: "true"
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT: "1"
    ASPNETCORE_ENVIRONMENT: "Development"
```

> **Not:** Üretim ortamı için `ASPNETCORE_ENVIRONMENT` değerini `"Production"` olarak ayarlayın.

#### Veritabanı Yapılandırması

```yaml
global:
  database:
    connectionString: "Host=vnext-postgres-headless;Port=5432;Database=vNext_WorkflowDb;Username=vnext;Password=changeme;"
    clickhouse:
      enabled: false
      connectionString: ""
```

> **Not:** Vault etkinken (`Vault__Enabled: "true"`), bağlantı dizeleri ConfigMap yerine Vault secret'larından alınır.

**ClickHouse Entegrasyonu:** İş akışı analitiği için isteğe bağlı ClickHouse desteği mevcuttur. ClickHouse bu chart'a dahil değildir; ayrı olarak dağıtılmalı ve bağlantı bilgisi burada yapılandırılmalıdır.

```yaml
global:
  database:
    clickhouse:
      enabled: true
      connectionString: "Host=clickhouse.analytics.svc;Port=8123;Database=workflow_analytics;Username=default;Password=your-password;"
```

#### Dapr Yapılandırması

Dapr servis mesh entegrasyonu için global ayarlar:

```yaml
global:
  dapr:
    enabled: true
    protocol: "http"
    placementHost: "dapr-placement:50005"
    httpPort: "42110"
    grpcPort: "42111"
```

#### Telemetri Yapılandırması

```yaml
global:
  telemetry:
    enabled: true
    protocol: "grpc"
    external:
      enabled: false
      endpoint: ""
```

#### Varsayılan Kaynak Limitleri

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

Her servis kendi `resources` bloğunu tanımlayarak bu varsayılan değerleri geçersiz kılabilir.

#### Varsayılan Sağlık Probe Ayarları

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

#### Güvenlik Bağlamı

```yaml
global:
  securityContext:
    capabilities:
      drop:
        - ALL
    readOnlyRootFilesystem: true
    runAsNonRoot: false
```

### Çekirdek Servisler

#### Orchestrator

Ana iş akışı orkestrasyon motoru:

```yaml
orchestrator:
  enabled: true
  replicaCount: 1
  image:
    repository: ghcr.io/burgan-tech/vnext/orchestrator
    tag: ""          # varsayılan olarak appVersion kullanılır
    pullPolicy: ""   # boşsa global.imagePullPolicy kullanılır
  dapr:
    enabled: true
    appId: ""        # otomatik oluşturulur: vnext-<appDomain>-app
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

Orchestrator'ın alt bileşeni olarak çalışan, veritabanı migrasyonları ve başlangıç ayarlarını yapan init job:

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

İş akışı görevlerini işleyen yürütme motoru. Bildirim API'si ile entegrasyon desteği sunar:

```yaml
execution:
  enabled: true
  replicaCount: 1
  image:
    repository: ghcr.io/burgan-tech/vnext/execution
    tag: ""
    pullPolicy: ""
  notificationBinding:
    url: ""          # bildirim API endpoint'i (örn. "http://mockoon:3001/api/notification/send")
  dapr:
    enabled: true
    appId: ""
    appPort: "5000"
  appEnvConfig:
    Vault__Enabled: "true"
    Logging__LogLevel__Default: "Debug"
```

#### Worker-Inbox

Orchestrator'dan mesaj alan servis:

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

Orchestrator'a mesaj gönderen servis:

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

#### Özel Ortam Değişkenleri

Tüm servisler `extraEnvConfig` ile özel ortam değişkenleri eklemeyi destekler:

```yaml
orchestrator:
  extraEnvConfig:
    MY_CUSTOM_VAR: "value"
    ANOTHER_VAR: "another-value"
```

### Altyapı Bileşenleri

#### PostgreSQL

Chart'a dahil olan PostgreSQL veritabanı:

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
    existingSecret: ""       # mevcut secret kullanmak için
  persistence:
    enabled: true
    size: 8Gi
    storageClass: ""
    accessModes:
      - ReadWriteOnce
```

##### PostgreSQL Performans Ayarları

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

##### PostgreSQL Metrik Exporter

```yaml
postgres:
  metrics:
    image:
      registry: quay.io
      repository: prometheuscommunity/postgres-exporter
      tag: "v0.18.1"
```

#### Redis Sentinel

Yüksek erişilebilir Redis cluster:

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

##### Redis Güvenlik

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

##### Redis Kaynak Limitleri

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

Dağıtık uygulama çalışma zamanı yapılandırması:

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

##### Dapr Alt Bileşenleri

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
        ttl: 8760h             # 1 yıl
      issuer:
        ttl: 2160h             # 90 gün
```

### Gözlemlenebilirlik Bileşenleri

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

> **Not:** Collector yapılandırması chart tarafından oluşturulan ConfigMap üzerinden sağlanır (`opentelemetry-collector-config`).

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

Prometheus ek scrape yapılandırması chart tarafından bir secret olarak oluşturulur. Grafana dashboard'ları sidecar aracılığıyla tüm namespace'lerden otomatik olarak keşfedilir.

#### Dapr Dashboard

```yaml
dapr-dashboard:
  enabled: true
```

### Geliştirme Araçları

Geliştirme sürecinde faydalı olan isteğe bağlı araçlardır. **Üretim ortamında devre dışı bırakılmalıdır.**

#### pgAdmin

PostgreSQL yönetim aracı:

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

Redis izleme ve yönetim aracı:

```yaml
redisInsight:
  enabled: false
```

#### Mockoon (API Mocklama)

Geliştirme ve test için hafif API mocklama sunucusu:

```yaml
mockoon:
  enabled: false
  service:
    port: 3001
```

#### OpenObserve

Açık kaynaklı gözlemlenebilirlik platformu:

```yaml
openobserve:
  enabled: false
  auth:
    username: "admin@example.com"
    password: "admin"
```

## Harici Vault Kullanımı

Yerleşik Vault yerine mevcut bir Vault sunucusuna bağlanmak için:

```yaml
global:
  externalVault:
    enabled: true
    address: "https://vault.example.com:8200"
    secretEngineName: ""      # boş bırakılırsa otomatik oluşturulur (vnext-<appDomain>-engine)
    vaultToken: "your-token"

vault:
  enabled: false              # yerleşik Vault'u devre dışı bırak
```

## Harici Redis Kullanımı

Mevcut bir Redis sunucusuna bağlanmak için:

```yaml
global:
  externalRedis:
    endpoint: "redis.example.com:6379"

redis-sentinel:
  enabled: false              # yerleşik Redis'i devre dışı bırak
```

## Harici OpenTelemetry Collector Kullanımı

```yaml
global:
  telemetry:
    enabled: true
    external:
      enabled: true
      endpoint: "http://otel-collector.observability.svc:4317"

opentelemetry-collector:
  enabled: false              # yerleşik collector'ı devre dışı bırak
```

## Ingress Yapılandırması

Servisleri dışarıya açmak için ingress'i etkinleştirin:

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

Initializer servisi için de ayrı ingress yapılandırması mevcuttur:

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

## Otomatik Ölçeklendirme

Çekirdek servisler için Horizontal Pod Autoscaler (HPA) etkinleştirme:

```yaml
orchestrator:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilizationPercentage: 80
    targetMemoryUtilizationPercentage: 80
```

Aynı yapı `execution`, `worker-inbox` ve `worker-outbox` servisleri için de geçerlidir.

## Güvenlik

### mTLS

Servisler arası iletişim için Dapr mTLS varsayılan olarak etkindir:

```yaml
dapr:
  global:
    mtls:
      enabled: true
      workloadCertTTL: 24h
      allowedClockSkew: 15m
```

### Konteyner Güvenlik Bağlamı

Tüm konteynerlere uygulanan varsayılan güvenlik bağlamı:

```yaml
global:
  securityContext:
    capabilities:
      drop:
        - ALL
    readOnlyRootFilesystem: true
    runAsNonRoot: false
```

### Servis Hesabı

```yaml
serviceAccount:
  create: true
  automount: true
  annotations: {}
```

### Üretim Kontrol Listesi

- [ ] `ASPNETCORE_ENVIRONMENT` değerini `"Production"` olarak ayarlayın (varsayılan: `"Development"`)
- [ ] `Logging__LogLevel__Default` değerini `"Information"` veya üstü yapın (varsayılan: `"Debug"`)
- [ ] Tüm varsayılan şifreleri değiştirin (PostgreSQL, Redis, pgAdmin, OpenObserve)
- [ ] Dapr mTLS'nin etkin olduğundan emin olun
- [ ] Ingress için TLS/HTTPS yapılandırın
- [ ] Mümkün olan yerlerde `runAsNonRoot: true` ayarlayın
- [ ] Tüm hassas yapılandırmalar için Vault kullanın
- [ ] Geliştirme araçlarını devre dışı bırakın (`pgAdmin`, `redisInsight`, `mockoon`, `openobserve`)
- [ ] Kaynak limitleri ve isteklerini ortamınıza uygun şekilde ayarlayın
- [ ] PostgreSQL şifresini `existingSecret` üzerinden yönetin

## İzleme ve Sağlık Kontrolleri

### Sağlık Endpoint'leri

| Servis        | Liveness  | Readiness |
| ------------- | --------- | --------- |
| Orchestrator  | `/live`   | `/ready`  |
| Execution     | `/live`   | `/ready`  |
| Worker-Inbox  | `/health` | `/health` |
| Worker-Outbox | `/health` | `/health` |

### Faydalı Komutlar

```bash
# Pod durumunu kontrol et
kubectl get pods -n vnext

# Orchestrator loglarını görüntüle
kubectl logs -n vnext -l app.kubernetes.io/component=orchestrator -f

# Execution loglarını görüntüle
kubectl logs -n vnext -l app.kubernetes.io/component=execution -f

# Tüm kaynakları kontrol et
kubectl get all -n vnext

# Dapr bileşenlerini görüntüle
kubectl get components -n vnext

# Kaynak kullanımını kontrol et
kubectl top pods -n vnext
```

### Port-Forward ile Servislere Erişim

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

## Sorun Giderme

### Pod'lar Başlamıyor

```bash
kubectl describe pod <pod-adi> -n vnext
kubectl logs <pod-adi> -n vnext --all-containers
```

### Veritabanı Bağlantı Sorunları

```bash
kubectl exec -n vnext -it <postgres-pod> -- psql -U admin -d vNext_WorkflowDb
```

### Redis Bağlantı Sorunları

```bash
kubectl exec -n vnext -it <redis-pod> -- redis-cli ping
```

### Dapr Sidecar Sorunları

```bash
kubectl logs <pod-adi> -c daprd -n vnext
kubectl get components,configurations -n vnext
```

### Kaynak Kısıtlamaları

```bash
kubectl describe pod <pod-adi> -n vnext | grep -i "insufficient\|exceed"
kubectl get events -n vnext --sort-by='.lastTimestamp' | tail -20
```

### Vault Bağlantı Sorunları

```bash
# Vault durumunu kontrol et
kubectl exec -n vnext -it <vault-pod> -- vault status

# Vault loglarını görüntüle
kubectl logs -n vnext -l app.kubernetes.io/name=vault
```

## Güncelleme ve Geri Alma

### Güncelleme

```bash
# Bağımlılıkları güncelle
helm dependency update

# Release'i güncelle
helm upgrade vnext . -n vnext -f my-values.yaml

# Güncelleme geçmişini görüntüle
helm history vnext -n vnext
```

### Geri Alma

```bash
# Bir önceki sürüme geri dön
helm rollback vnext -n vnext

# Belirli bir sürüme geri dön
helm rollback vnext 2 -n vnext
```

## Kaldırma

```bash
# Release'i kaldır (tüm kaynaklar silinecektir)
helm uninstall vnext -n vnext

# Kalıcı verileri de silmek istiyorsanız PVC'leri silin
kubectl delete pvc --all -n vnext

# İsteğe bağlı olarak namespace'i silin
kubectl delete namespace vnext
```

> **Uyarı:** Kaldırma işlemi dağıtılan tüm kaynakları silecektir. PVC'ler otomatik olarak silinmez; kalıcı verileri temizlemek istiyorsanız bunları manuel olarak kaldırın.

## Parametreler Referansı

### Global Parametreler

| Parametre | Açıklama | Varsayılan |
|---|---|---|
| `global.appDomain` | Dapr uygulama kimliği ve servis keşfi için domain | `"core"` |
| `global.imagePullPolicy` | Varsayılan image pull policy | `IfNotPresent` |
| `global.imagePullSecrets` | Image pull secret'ları | `[]` |
| `global.externalVault.enabled` | Harici Vault kullanımı | `false` |
| `global.externalVault.address` | Harici Vault adresi | `""` |
| `global.externalVault.secretEngineName` | Vault secret engine adı | `""` |
| `global.externalVault.vaultToken` | Vault erişim token'ı | `""` |
| `global.dotnetEnv.ASPNETCORE_ENVIRONMENT` | .NET ortam ayarı | `"Development"` |
| `global.dapr.enabled` | Global Dapr etkinleştirme | `true` |
| `global.dapr.protocol` | Dapr iletişim protokolü | `"http"` |
| `global.telemetry.enabled` | Telemetri etkinleştirme | `true` |
| `global.telemetry.external.enabled` | Harici collector kullanımı | `false` |
| `global.telemetry.external.endpoint` | Harici collector endpoint'i | `""` |
| `global.database.connectionString` | PostgreSQL bağlantı dizesi | `"Host=vnext-postgres-headless;..."` |
| `global.database.clickhouse.enabled` | ClickHouse entegrasyonu | `false` |
| `global.externalRedis.endpoint` | Harici Redis endpoint'i | `""` |
| `global.resources.default.limits.cpu` | Varsayılan CPU limiti | `1000m` |
| `global.resources.default.limits.memory` | Varsayılan bellek limiti | `2Gi` |
| `global.resources.default.requests.cpu` | Varsayılan CPU isteği | `100m` |
| `global.resources.default.requests.memory` | Varsayılan bellek isteği | `256Mi` |

### Servis Parametreleri

| Parametre | Açıklama | Varsayılan |
|---|---|---|
| `orchestrator.enabled` | Orchestrator'ı etkinleştir | `true` |
| `orchestrator.replicaCount` | Replika sayısı | `1` |
| `orchestrator.image.repository` | Image repository | `ghcr.io/burgan-tech/vnext/orchestrator` |
| `orchestrator.image.tag` | Image tag (boşsa appVersion) | `""` |
| `orchestrator.dapr.enabled` | Dapr sidecar etkinleştir | `true` |
| `orchestrator.dapr.appPort` | Uygulama portu | `"5000"` |
| `orchestrator.service.type` | Servis tipi | `ClusterIP` |
| `orchestrator.service.port` | Servis portu | `5000` |
| `orchestrator.ingress.enabled` | Ingress etkinleştir | `false` |
| `orchestrator.autoscaling.enabled` | HPA etkinleştir | `false` |
| `orchestrator.initializer.enabled` | Init job'ı etkinleştir | `true` |
| `orchestrator.initializer.envConfig.VNEXT_COMPONENT_VERSION` | vNext bileşen sürümü | `"0.0.18"` |
| `execution.enabled` | Execution'ı etkinleştir | `true` |
| `execution.notificationBinding.url` | Bildirim API URL'si | `""` |
| `worker-inbox.enabled` | Worker-Inbox'ı etkinleştir | `true` |
| `worker-outbox.enabled` | Worker-Outbox'ı etkinleştir | `true` |

### Altyapı Parametreleri

| Parametre | Açıklama | Varsayılan |
|---|---|---|
| `postgres.enabled` | PostgreSQL'i etkinleştir | `true` |
| `postgres.auth.username` | Veritabanı kullanıcısı | `"admin"` |
| `postgres.auth.password` | Veritabanı şifresi | `"admin"` |
| `postgres.auth.database` | Veritabanı adı | `"vNext_WorkflowDb"` |
| `postgres.persistence.enabled` | Kalıcı disk | `true` |
| `postgres.persistence.size` | Disk boyutu | `8Gi` |
| `redis-sentinel.enabled` | Redis Sentinel'i etkinleştir | `true` |
| `redis-sentinel.replicaCount` | Replika sayısı | `1` |
| `redis-sentinel.redis.password` | Redis şifresi | `""` |
| `redis-sentinel.redis.persistence.size` | Disk boyutu | `8Gi` |
| `vault.enabled` | Vault'u etkinleştir | `true` |
| `dapr.enabled` | Dapr'ı etkinleştir | `true` |
| `dapr.global.ha.enabled` | Yüksek erişilebilirlik | `false` |
| `dapr.global.mtls.enabled` | mTLS | `true` |

### Gözlemlenebilirlik Parametreleri

| Parametre | Açıklama | Varsayılan |
|---|---|---|
| `opentelemetry-collector.enabled` | OTel Collector'ı etkinleştir | `true` |
| `kube-prometheus-stack.enabled` | Prometheus + Grafana'yı etkinleştir | `true` |
| `dapr-dashboard.enabled` | Dapr Dashboard'u etkinleştir | `true` |

### Geliştirme Araçları Parametreleri

| Parametre | Açıklama | Varsayılan |
|---|---|---|
| `pgAdmin.enabled` | pgAdmin'i etkinleştir | `false` |
| `pgAdmin.auth.email` | pgAdmin e-posta | `"admin@example.com"` |
| `pgAdmin.auth.password` | pgAdmin şifresi | `"admin"` |
| `redisInsight.enabled` | RedisInsight'ı etkinleştir | `false` |
| `mockoon.enabled` | Mockoon'u etkinleştir | `false` |
| `mockoon.service.port` | Mockoon portu | `3001` |
| `openobserve.enabled` | OpenObserve'u etkinleştir | `false` |
| `openobserve.auth.username` | OpenObserve kullanıcı | `"admin@example.com"` |
| `openobserve.auth.password` | OpenObserve şifresi | `"admin"` |

## Destek

- **Bakımcı:** Mustafa Fidan
- **E-posta:** [mrmustafafidan@gmail.com](mailto:mrmustafafidan@gmail.com)
- **Sorunlar:** [https://github.com/burgan-tech/vnext-helm-charts/issues](https://github.com/burgan-tech/vnext-helm-charts/issues)
