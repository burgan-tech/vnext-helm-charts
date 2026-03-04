# Redis Sentinel Python Client with TLS

A production-ready Python application that connects to Redis Sentinel with TLS support and external access (compatible with Redis 7.4.1-alpine).

## Features

- ✅ Redis Sentinel support (automatic failover)
- ✅ TLS/SSL connection support
- ✅ Client certificate authentication
- ✅ External access via LoadBalancer IPs
- ✅ Master and replica connection handling
- ✅ Example operations (SET/GET, Hash, List, Set, etc.)
- ✅ Health monitoring mode
- ✅ Production-ready Dockerfile

## Prerequisites

1. Redis Sentinel deployed with external access
2. TLS certificates (ca.crt, optionally tls.crt/tls.key) extracted from cluster
3. Redis password and Sentinel password

## Quick Start

### 1. Extract TLS Certificates

```bash
# Extract ca.crt from Kubernetes secret
kubectl get secret <release-name>-tls -n <namespace> \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt

# If using client certificate authentication, also extract:
kubectl get secret <release-name>-tls -n <namespace> \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > tls.crt

kubectl get secret <release-name>-tls -n <namespace> \
  -o jsonpath='{.data.tls\.key}' | base64 -d > tls.key
```

### 2. Get Redis and Sentinel Passwords

```bash
# Get Redis password
export REDIS_PASSWORD=$(kubectl get secret <release-name> \
  -n <namespace> -o jsonpath="{.data.redis-password}" | base64 -d)

# Get Sentinel password
export SENTINEL_PASSWORD=$(kubectl get secret <release-name> \
  -n <namespace> -o jsonpath="{.data.sentinel-password}" | base64 -d)

echo "Redis Password: $REDIS_PASSWORD"
echo "Sentinel Password: $SENTINEL_PASSWORD"
```

### 3. Run Locally (Without Docker)

#### Without TLS (Internal Access)

```bash
# Install dependencies
pip install -r requirements.txt

# Set environment variables
export SENTINEL_HOSTS="localhost:26379,localhost:26380,localhost:26381"
export MASTER_NAME="mymaster"
export REDIS_PASSWORD="your-redis-password"
export SENTINEL_PASSWORD="your-sentinel-password"
export USE_TLS="false"

# Run the application
python app.py
```

#### With TLS (External Access)

```bash
# Install dependencies
pip install -r requirements.txt

# Set environment variables
export SENTINEL_HOSTS="10.1.2.11:26379,10.1.2.12:26379,10.1.2.13:26379"
export MASTER_NAME="mymaster"
export REDIS_PASSWORD="your-redis-password"
export SENTINEL_PASSWORD="your-sentinel-password"
export TLS_CA_CERT="./ca.crt"
export USE_TLS="true"

# If using client certificate authentication
export TLS_CERT="./tls.crt"
export TLS_KEY="./tls.key"

# Run the application
python app.py
```

### 4. Run with Docker

#### Build the image

```bash
docker build -t redis-sentinel-client:latest .
```

#### Without TLS

```bash
docker run --rm \
  -e SENTINEL_HOSTS="10.1.2.11:26379,10.1.2.12:26379,10.1.2.13:26379" \
  -e MASTER_NAME="mymaster" \
  -e REDIS_PASSWORD="your-redis-password" \
  -e SENTINEL_PASSWORD="your-sentinel-password" \
  -e USE_TLS="false" \
  redis-sentinel-client:latest
```

#### With TLS (CA Certificate Only)

```bash
docker run --rm \
  -v $(pwd)/ca.crt:/certs/ca.crt:ro \
  -e SENTINEL_HOSTS="10.1.2.11:26379,10.1.2.12:26379,10.1.2.13:26379" \
  -e MASTER_NAME="mymaster" \
  -e REDIS_PASSWORD="your-redis-password" \
  -e SENTINEL_PASSWORD="your-sentinel-password" \
  -e USE_TLS="true" \
  redis-sentinel-client:latest
```

#### With TLS (Client Certificate Authentication)

```bash
docker run --rm \
  -v $(pwd)/ca.crt:/certs/ca.crt:ro \
  -v $(pwd)/tls.crt:/certs/tls.crt:ro \
  -v $(pwd)/tls.key:/certs/tls.key:ro \
  -e SENTINEL_HOSTS="10.1.2.11:26379,10.1.2.12:26379,10.1.2.13:26379" \
  -e MASTER_NAME="mymaster" \
  -e REDIS_PASSWORD="your-redis-password" \
  -e SENTINEL_PASSWORD="your-sentinel-password" \
  -e USE_TLS="true" \
  redis-sentinel-client:latest
```

### 5. Run on Kubernetes

Create `k8s-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-sentinel-client
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-sentinel-client
  template:
    metadata:
      labels:
        app: redis-sentinel-client
    spec:
      containers:
      - name: client
        image: redis-sentinel-client:latest
        imagePullPolicy: IfNotPresent
        env:
        - name: SENTINEL_HOSTS
          value: "10.1.2.11:26379,10.1.2.12:26379,10.1.2.13:26379"
        - name: MASTER_NAME
          value: "mymaster"
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: <release-name>
              key: redis-password
        - name: SENTINEL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: <release-name>
              key: sentinel-password
        - name: USE_TLS
          value: "true"
        - name: TLS_CA_CERT
          value: "/certs/ca.crt"
        - name: TLS_CERT
          value: "/certs/tls.crt"
        - name: TLS_KEY
          value: "/certs/tls.key"
        - name: KEEP_ALIVE
          value: "true"  # Keep running for monitoring
        volumeMounts:
        - name: tls-certs
          mountPath: /certs
          readOnly: true
      volumes:
      - name: tls-certs
        secret:
          secretName: <release-name>-tls
          items:
          - key: ca.crt
            path: ca.crt
          - key: tls.crt
            path: tls.crt
          - key: tls.key
            path: tls.key
```

Deploy:

```bash
kubectl apply -f k8s-deployment.yaml

# Check logs
kubectl logs -f deployment/redis-sentinel-client
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `SENTINEL_HOSTS` | Comma-separated list of Sentinel nodes | `10.1.2.11:26379` |
| `MASTER_NAME` | Sentinel master name | `mymaster` |
| `REDIS_PASSWORD` | Redis password | `""` (empty) |
| `SENTINEL_PASSWORD` | Sentinel password | `""` (empty) |
| `TLS_CA_CERT` | Path to CA certificate | `/certs/ca.crt` |
| `TLS_CERT` | Path to client certificate | `/certs/tls.crt` |
| `TLS_KEY` | Path to client key | `/certs/tls.key` |
| `USE_TLS` | Enable TLS | `false` |
| `KEEP_ALIVE` | Keep connection alive | `false` |

### Example Configurations

#### Internal Access (No TLS)

```bash
export SENTINEL_HOSTS="redis-sentinel-0.redis-sentinel-headless:26379,redis-sentinel-1.redis-sentinel-headless:26379,redis-sentinel-2.redis-sentinel-headless:26379"
export MASTER_NAME="mymaster"
export USE_TLS="false"
```

#### External Access with TLS

```bash
export SENTINEL_HOSTS="10.1.2.11:26379,10.1.2.12:26379,10.1.2.13:26379"
export MASTER_NAME="mymaster"
export USE_TLS="true"
export TLS_CA_CERT="./ca.crt"
export TLS_CERT="./tls.crt"
export TLS_KEY="./tls.key"
```

## Example Output

```
============================================================
Redis Sentinel Client - Connecting...
============================================================
Sentinel Nodes: [('10.1.2.11', 26379), ('10.1.2.12', 26379), ('10.1.2.13', 26379)]
Master Name: mymaster
TLS Enabled: True
CA Certificate: /certs/ca.crt

Using TLS with client certificate authentication
Discovering master...
✓ Successfully connected to Redis Master via Sentinel!
✓ Successfully connected to Redis Replica!

Sentinel & Redis Information:
------------------------------------------------------------
  Master Name: mymaster
  Master Address: 10.1.2.11:6379
  Master Status: master
  Number of Replicas: 2
  Quorum: 2

  Replicas:
    1. 10.1.2.12:6379 (slave)
    2. 10.1.2.13:6379 (slave)

  Sentinels Monitoring Master:
    1. 10.1.2.11:26379 (sentinel)
    2. 10.1.2.12:26379 (sentinel)
    3. 10.1.2.13:26379 (sentinel)

  Redis Master Info:
    Role: master
    Connected Slaves: 2
    Used Memory: 1.23M
    Max Memory: 2.00G
------------------------------------------------------------

============================================================
Running Example Operations
============================================================

[1] Basic SET/GET:
  SET hello='world' (on master)
  GET hello='world' (from master)
  GET hello='world' (from replica)
  ✓ Success

[2] Counter Operations:
  INCR counter → 1
  INCR counter → 2
  INCR counter → 3
  INCR counter → 4
  INCR counter → 5
  ✓ Success

... (more examples)

[8] Sentinel Awareness Test:
  Current Master: 10.1.2.11:6379
  ✓ Sentinel can discover master
  ✓ Automatic failover supported

============================================================
All examples completed successfully! ✓
============================================================
```

## Features Explained

### Sentinel Automatic Failover

The client uses Redis Sentinel which provides:
- **Automatic failover**: If master goes down, Sentinel promotes a replica
- **Service discovery**: Client always connects to current master
- **High availability**: Application continues working during failover

### TLS Support

Two modes supported:
1. **CA Certificate Only**: Verifies server identity
2. **Client Certificate**: Mutual TLS authentication

### Read/Write Split

- **Writes**: Always go to master
- **Reads**: Can be served by replicas (reduces master load)

## Troubleshooting

### Connection Refused

```
✗ Connection Error: Error connecting to Sentinel
```

**Solutions**:
- Check `SENTINEL_HOSTS` - ensure Sentinel nodes are reachable
- Verify network connectivity
- Check Sentinel is running: `redis-cli -h <host> -p 26379 ping`

### Certificate Verification Failed

```
✗ SSL Error: certificate verify failed
```

**Solutions**:
- Ensure `ca.crt` is valid and matches server certificate
- If using client certs, ensure `tls.crt` and `tls.key` match
- Check certificate paths are correct

### Authentication Failed

```
✗ Redis Error: NOAUTH Authentication required
```

**Solutions**:
- Set correct `REDIS_PASSWORD`
- Set correct `SENTINEL_PASSWORD` if Sentinel requires authentication

### Master Not Found

```
✗ Sentinel Error: No master found for 'mymaster'
```

**Solutions**:
- Check `MASTER_NAME` matches Sentinel configuration
- Verify Sentinel cluster is healthy: `redis-cli -h <host> -p 26379 sentinel masters`

### Client Certificate Required

```
✗ SSL Error: tlsv1 alert certificate required
```

**Solution**: Server requires client certificates - provide `TLS_CERT` and `TLS_KEY`

## Production Considerations

### High Availability

```python
# Client automatically handles failover
# If master fails, Sentinel promotes replica
# Client reconnects to new master automatically
```

### Connection Pooling

redis-py handles connection pooling automatically. Configure if needed:

```python
# In app.py, modify connection_kwargs:
connection_kwargs = {
    # ... existing config ...
    'max_connections': 50,
    'socket_keepalive': True,
    'socket_keepalive_options': {
        socket.TCP_KEEPIDLE: 1,
        socket.TCP_KEEPINTVL: 1,
        socket.TCP_KEEPCNT: 5
    }
}
```

### Error Handling

The client includes comprehensive error handling:
- Connection failures
- Authentication errors
- TLS/SSL errors
- Sentinel errors
- Automatic retry via Sentinel

### Monitoring

Use `KEEP_ALIVE=true` mode:
- Pings master every 30 seconds
- Logs master address
- Detects failover events

### Security Best Practices

1. **Never hardcode passwords** - use environment variables or secrets
2. **Use TLS in production** - encrypt all communications
3. **Enable client certificates** - mutual TLS authentication
4. **Rotate certificates** - before expiry
5. **Use strong passwords** - for Redis and Sentinel

## Testing Failover

### Simulate Master Failure

```bash
# In one terminal - run client with KEEP_ALIVE
export KEEP_ALIVE="true"
python app.py

# In another terminal - kill master pod
kubectl delete pod redis-sentinel-0 -n <namespace>

# Watch client logs - should automatically reconnect to new master
```

Expected behavior:
1. Master goes down
2. Sentinel detects failure (after `down-after-milliseconds`)
3. Sentinel promotes a replica
4. Client discovers new master
5. Operations continue seamlessly

## Dependencies

- **python**: 3.11-slim
- **redis**: 5.0.1 (with Sentinel support)
- **hiredis**: 2.3.2 (performance boost)

## Advanced Usage

### Custom Operations

Add to `run_examples()` in `app.py`:

```python
# Example: Your custom operation
print("[9] Custom Operation:")
result = self.master.your_redis_command()
print(f"  Result: {result}")
print(f"  ✓ Success\n")
```

### Read from Replica

```python
# Use replica connection for read operations
if self.replica:
    value = self.replica.get('some_key')
```

### Direct Sentinel Commands

```python
# Get all masters
masters = self.sentinel.sentinel_masters()

# Force failover (for testing)
self.sentinel.sentinel_failover(self.master_name)
```

## License

This example is provided as-is for use with your Redis Sentinel deployment.

