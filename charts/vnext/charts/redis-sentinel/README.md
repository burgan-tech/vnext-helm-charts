# Redis Sentinel Helm Chart

Production-ready Helm chart for Redis Sentinel with high availability, TLS encryption, and persistence.

## Features

- Master-replica replication with automatic failover
- TLS/SSL encryption support
- External access via LoadBalancer
- Persistent disk storage with AOF + RDB
- Prometheus metrics and monitoring
- OpenShift compatible

## Installation

```bash
# Basic installation
helm install my-redis-sentinel charts/redis-sentinel/

# With persistence, external access, and TLS
helm install my-redis-sentinel charts/redis-sentinel/ \
  -f charts/redis-sentinel/values-examples/persistent-external-tls.yaml
```

## Configuration Examples

See `values-examples/` directory for different deployment scenarios:
- `basic.yaml` - Basic configuration
- `external-access-tls.yaml` - External access with TLS
- `persistent-external-tls.yaml` - Full production setup (optimal memory config)
- `nodeport.yaml` - NodePort service type
- `production.yaml` - Full monitoring and features

## Memory Configuration (CRITICAL!)

### ⚠️ Critical Requirement

**Always set Redis `maxMemory` to 80-90% of the Kubernetes pod memory limit!**

If `maxMemory` > pod limit → Kubernetes OOM kills the pod → data loss!
If `maxMemory` = 0 (unlimited) → pod grows until OOM kill → data loss!

### Current Configuration Summary

All example values files now use the **correct memory relationship**:

| File | Pod Memory | Redis maxMemory | Ratio | Status |
|------|-----------|-----------------|-------|--------|
| `values.yaml` | 3Gi | 2560mb | 78% | ✅ Optimal |
| `basic.yaml` | 3Gi | 2560mb | 78% | ✅ Optimal |
| `external-access.yaml` | 3Gi | 2560mb | 78% | ✅ Optimal |
| `external-access-tls.yaml` | 3Gi | 2560mb | 78% | ✅ Optimal |
| `persistent-external-tls.yaml` | 3Gi | 2400mb | 75% | ✅ Optimal |

### Recommended Values

| Pod Memory Limit | Redis maxMemory | Usage % | Use Case |
|-----------------|-----------------|---------|----------|
| 1Gi | 800mb | 78% | Small |
| 2Gi | 1600mb | 78% | Standard |
| **3Gi** | **2560mb** | **78%** | ✅ **Default** |
| 4Gi | 3200mb | 78% | Medium |
| 6Gi | 5000mb | 81% | Large |
| 8Gi | 7000mb | 85% | Production |

### Example Configuration

```yaml
# Set pod memory limit
resources:
  redis:
    limits:
      memory: 3Gi        # Kubernetes enforces this

# Set Redis maxMemory to 80-90% of pod limit
redis:
  maxMemory: "2560mb"    # 78% of 3Gi = safe margin
  maxMemoryPolicy: "noeviction"
```

### Why 80-90%?

Redis needs extra headroom for:
- Memory fragmentation (~10-15%)
- Client output buffers
- Replication buffers
- Sentinel overhead
- Connection overhead

For more details, see the Redis Cluster [MEMORY-CONFIGURATION.md](../redis-cluster/MEMORY-CONFIGURATION.md).

## Documentation

Full documentation available at: [docs/redis-sentinel/](../../docs/redis-sentinel/)

## Values

See [values.yaml](values.yaml) for all configuration options.
