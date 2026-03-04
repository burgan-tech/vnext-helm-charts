# Redis Sentinel Python Client - Quick Reference

## Files Overview

| File | Purpose |
|------|---------|
| `app.py` | Main Python application with comprehensive examples |
| `test-connection.py` | Simple connection test script |
| `requirements.txt` | Python dependencies |
| `Dockerfile` | Container image definition |
| `k8s-deployment.yaml` | Kubernetes deployment manifest |
| `quickstart.sh` | Automated setup and run script |
| `README.md` | Complete documentation |

## Quick Commands

### 1. Local Testing (No TLS)

```bash
# Install dependencies
pip install -r requirements.txt

# Set minimal config
export SENTINEL_HOSTS="localhost:26379"
export REDIS_PASSWORD="your-password"
export USE_TLS="false"

# Test connection
python test-connection.py

# Run full examples
python app.py
```

### 2. External Access with TLS

```bash
# Extract certificates
kubectl get secret my-redis-sentinel-tls -n default \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt

# Configure
export SENTINEL_HOSTS="10.1.2.11:26379,10.1.2.12:26379,10.1.2.13:26379"
export REDIS_PASSWORD=$(kubectl get secret my-redis-sentinel -n default -o jsonpath="{.data.redis-password}" | base64 -d)
export USE_TLS="true"
export TLS_CA_CERT="./ca.crt"

# Run
python app.py
```

### 3. Automated Quick Start

```bash
# Internal access, no TLS
RELEASE_NAME=my-redis-sentinel NAMESPACE=default USE_TLS=false ./quickstart.sh

# External access with TLS
RELEASE_NAME=my-redis-sentinel NAMESPACE=default USE_TLS=true EXTERNAL_ACCESS=true ./quickstart.sh
```

### 4. Docker

```bash
# Build
docker build -t redis-sentinel-client:latest .

# Run
docker run --rm \
  -e SENTINEL_HOSTS="10.1.2.11:26379,10.1.2.12:26379,10.1.2.13:26379" \
  -e REDIS_PASSWORD="your-password" \
  -v $(pwd)/ca.crt:/certs/ca.crt:ro \
  redis-sentinel-client:latest
```

### 5. Kubernetes

```bash
# Update k8s-deployment.yaml with your values
# Then deploy
kubectl apply -f k8s-deployment.yaml

# Check logs
kubectl logs -f deployment/redis-sentinel-client
```

## Environment Variables Reference

### Required
- `SENTINEL_HOSTS` - Comma-separated Sentinel nodes (e.g., "host1:26379,host2:26379")
- `REDIS_PASSWORD` - Redis authentication password

### Optional
- `MASTER_NAME` - Sentinel master name (default: "mymaster")
- `SENTINEL_PASSWORD` - Sentinel authentication password
- `USE_TLS` - Enable TLS (default: "false")
- `TLS_CA_CERT` - CA certificate path (default: "/certs/ca.crt")
- `TLS_CERT` - Client certificate path (default: "/certs/tls.crt")
- `TLS_KEY` - Client key path (default: "/certs/tls.key")
- `KEEP_ALIVE` - Keep connection alive (default: "false")

## Configuration Examples

### Internal Kubernetes Access

```bash
export SENTINEL_HOSTS="redis-sentinel-0.redis-sentinel-headless.default.svc.cluster.local:26379,redis-sentinel-1.redis-sentinel-headless.default.svc.cluster.local:26379,redis-sentinel-2.redis-sentinel-headless.default.svc.cluster.local:26379"
export MASTER_NAME="mymaster"
export USE_TLS="false"
```

### External Access (No TLS)

```bash
export SENTINEL_HOSTS="10.1.2.11:26379,10.1.2.12:26379,10.1.2.13:26379"
export MASTER_NAME="mymaster"
export USE_TLS="false"
```

### External Access (With TLS)

```bash
export SENTINEL_HOSTS="10.1.2.11:26379,10.1.2.12:26379,10.1.2.13:26379"
export MASTER_NAME="mymaster"
export USE_TLS="true"
export TLS_CA_CERT="./ca.crt"
```

### External Access (With Client Certificates)

```bash
export SENTINEL_HOSTS="10.1.2.11:26379,10.1.2.12:26379,10.1.2.13:26379"
export MASTER_NAME="mymaster"
export USE_TLS="true"
export TLS_CA_CERT="./ca.crt"
export TLS_CERT="./tls.crt"
export TLS_KEY="./tls.key"
```

## Common Issues & Solutions

### Issue: Cannot connect to Sentinel

```
✗ Connection Error: Error connecting to Sentinel
```

**Check:**
1. `SENTINEL_HOSTS` is correct
2. Network connectivity: `telnet <host> 26379`
3. Sentinel is running: `kubectl get pods -l app=redis-sentinel`

### Issue: TLS verification failed

```
✗ SSL Error: certificate verify failed
```

**Solutions:**
- Verify `ca.crt` is extracted correctly
- Check certificate is not expired
- Ensure CA cert matches server certificate

### Issue: Authentication failed

```
✗ Redis Error: NOAUTH Authentication required
```

**Solutions:**
- Set correct `REDIS_PASSWORD`
- Set `SENTINEL_PASSWORD` if required
- Verify passwords: `kubectl get secret <name> -o yaml`

### Issue: Master not found

```
✗ Sentinel Error: No master found for 'mymaster'
```

**Solutions:**
- Check `MASTER_NAME` matches Sentinel config
- Verify Sentinel: `redis-cli -h <host> -p 26379 sentinel masters`

## Testing Scenarios

### Basic Connectivity Test

```bash
python test-connection.py
```

### Run Full Examples

```bash
python app.py
```

### Keep Alive Mode (Monitoring)

```bash
export KEEP_ALIVE="true"
python app.py
```

### Test Failover

```bash
# Terminal 1: Run client with keep-alive
export KEEP_ALIVE="true"
python app.py

# Terminal 2: Simulate master failure
kubectl delete pod redis-sentinel-0

# Watch Terminal 1: Client should reconnect to new master
```

## Python Code Examples

### Simple Connection

```python
from redis.sentinel import Sentinel

sentinel = Sentinel([('localhost', 26379)], socket_timeout=5)
master = sentinel.master_for('mymaster', socket_timeout=5, password='pass')
master.set('key', 'value')
print(master.get('key'))
```

### With TLS

```python
sentinel = Sentinel(
    [('10.1.2.11', 26379)],
    sentinel_kwargs={
        'ssl': True,
        'ssl_ca_certs': '/certs/ca.crt'
    },
    ssl=True,
    ssl_ca_certs='/certs/ca.crt',
    password='redis-pass'
)
master = sentinel.master_for('mymaster')
```

### Read from Replica

```python
sentinel = Sentinel([('localhost', 26379)])
master = sentinel.master_for('mymaster')
replica = sentinel.slave_for('mymaster')

# Write to master
master.set('key', 'value')

# Read from replica
print(replica.get('key'))
```

## Production Checklist

- [ ] TLS enabled (`USE_TLS=true`)
- [ ] Strong passwords set
- [ ] Client certificates configured (if required)
- [ ] Multiple Sentinel nodes configured (3+)
- [ ] Resource limits set in Kubernetes
- [ ] Health monitoring enabled (`KEEP_ALIVE=true`)
- [ ] Proper error handling in application code
- [ ] Connection pooling configured
- [ ] Certificates rotated before expiry

## Support

For detailed documentation, see:
- `README.md` - Complete documentation
- `app.py` - Source code with comments
- Main helm chart documentation in `../../doc/`

## Version Information

- Python: 3.11+
- redis-py: 5.0.1
- Redis: 7.4.1-alpine
- Supports: Redis Sentinel with/without TLS

