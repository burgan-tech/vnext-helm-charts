#!/usr/bin/env python3
"""
Simple Redis Sentinel Connection Test
Quick test script to verify connectivity
"""

import os
import sys

try:
    from redis.sentinel import Sentinel
    from redis.exceptions import RedisError, ConnectionError
except ImportError:
    print("✗ redis-py not installed")
    print("  Run: pip install redis[hiredis]==5.0.1")
    sys.exit(1)


def test_connection():
    """Test connection to Redis via Sentinel"""
    
    # Get configuration
    sentinel_hosts = os.getenv('SENTINEL_HOSTS', 'localhost:26379')
    master_name = os.getenv('MASTER_NAME', 'mymaster')
    redis_password = os.getenv('REDIS_PASSWORD', '')
    sentinel_password = os.getenv('SENTINEL_PASSWORD', '')
    use_tls = os.getenv('USE_TLS', 'false').lower() == 'true'
    
    print("=" * 60)
    print("Redis Sentinel Connection Test")
    print("=" * 60)
    print(f"Sentinel Hosts: {sentinel_hosts}")
    print(f"Master Name: {master_name}")
    print(f"TLS: {use_tls}")
    print()
    
    # Parse hosts
    sentinel_nodes = []
    for host in sentinel_hosts.split(','):
        if ':' in host:
            h, p = host.split(':')
            sentinel_nodes.append((h, int(p)))
        else:
            sentinel_nodes.append((host, 26379))
    
    try:
        # Connect to Sentinel
        print("[1/4] Connecting to Sentinel...")
        
        if use_tls:
            ca_cert = os.getenv('TLS_CA_CERT', '/certs/ca.crt')
            sentinel = Sentinel(
                sentinel_nodes,
                sentinel_kwargs={
                    'password': sentinel_password if sentinel_password else None,
                    'ssl': True,
                    'ssl_cert_reqs': 'required',
                    'ssl_ca_certs': ca_cert,
                    'ssl_check_hostname': False
                },
                ssl=True,
                ssl_cert_reqs='required',
                ssl_ca_certs=ca_cert,
                ssl_check_hostname=False,
                password=redis_password,
                decode_responses=True
            )
        else:
            sentinel = Sentinel(
                sentinel_nodes,
                sentinel_kwargs={
                    'password': sentinel_password if sentinel_password else None
                },
                password=redis_password,
                decode_responses=True
            )
        
        print("✓ Connected to Sentinel")
        
        # Discover master
        print("[2/4] Discovering master...")
        master_addr = sentinel.discover_master(master_name)
        print(f"✓ Master found: {master_addr[0]}:{master_addr[1]}")
        
        # Connect to master
        print("[3/4] Connecting to master...")
        master = sentinel.master_for(master_name, socket_timeout=5)
        master.ping()
        print("✓ Connected to master")
        
        # Test operation
        print("[4/4] Testing operations...")
        master.set('test_key', 'test_value')
        value = master.get('test_key')
        master.delete('test_key')
        
        if value == 'test_value':
            print("✓ Operations work correctly")
        else:
            print("✗ Operation failed")
            return False
        
        print()
        print("=" * 60)
        print("✓ All tests passed!")
        print("=" * 60)
        
        master.close()
        return True
        
    except ConnectionError as e:
        print(f"\n✗ Connection Error: {e}")
        return False
    except RedisError as e:
        print(f"\n✗ Redis Error: {e}")
        return False
    except Exception as e:
        print(f"\n✗ Unexpected Error: {e}")
        import traceback
        traceback.print_exc()
        return False


if __name__ == '__main__':
    success = test_connection()
    sys.exit(0 if success else 1)

