#!/usr/bin/env python3
"""
Redis Sentinel Client with TLS
Compatible with Redis 7.4.1-alpine
"""

import os
import sys
import time
import ssl
from redis.sentinel import Sentinel
from redis import Redis
from redis.exceptions import RedisError, ConnectionError

class RedisSentinelClient:
    """Redis Sentinel client with TLS support"""
    
    def __init__(self):
        # Configuration from environment variables
        self.sentinel_hosts = os.getenv('SENTINEL_HOSTS', '10.1.2.21:26379').split(',')
        self.redis_password = os.getenv('REDIS_PASSWORD', '')
        self.sentinel_password = os.getenv('SENTINEL_PASSWORD', '')
        self.master_name = os.getenv('MASTER_NAME', 'mymaster')
        self.tls_ca_cert = os.getenv('TLS_CA_CERT', '/certs/ca.crt')
        self.tls_cert = os.getenv('TLS_CERT', '/certs/tls.crt')
        self.tls_key = os.getenv('TLS_KEY', '/certs/tls.key')
        self.use_tls = os.getenv('USE_TLS', 'false').lower() == 'true'
        
        # Parse sentinel hosts
        self.sentinel_nodes = []
        for host in self.sentinel_hosts:
            if ':' in host:
                host_part, port_part = host.split(':')
                self.sentinel_nodes.append((host_part, int(port_part)))
            else:
                self.sentinel_nodes.append((host, 26379))
        
        self.sentinel = None
        self.master = None
        self.replica = None
        
    def connect(self):
        """Establish connection to Redis via Sentinel"""
        print("=" * 60)
        print("Redis Sentinel Client - Connecting...")
        print("=" * 60)
        print(f"Sentinel Nodes: {self.sentinel_nodes}")
        print(f"Master Name: {self.master_name}")
        print(f"TLS Enabled: {self.use_tls}")
        if self.use_tls:
            print(f"CA Certificate: {self.tls_ca_cert}")
        print()
        
        try:
            # Configure SSL/TLS settings
            if self.use_tls:
                # Check if client certificates are required
                use_client_cert = os.path.exists(self.tls_cert) and os.path.exists(self.tls_key)
                
                if use_client_cert:
                    print("Using TLS with client certificate authentication")
                    # Create SSL context for Sentinel
                    sentinel_ssl_kwargs = {
                        'ssl': True,
                        'ssl_cert_reqs': 'required',
                        'ssl_ca_certs': self.tls_ca_cert,
                        'ssl_certfile': self.tls_cert,
                        'ssl_keyfile': self.tls_key,
                        'ssl_check_hostname': False
                    }
                    
                    # Create SSL context for Redis connections
                    connection_kwargs = {
                        'ssl': True,
                        'ssl_cert_reqs': 'required',
                        'ssl_ca_certs': self.tls_ca_cert,
                        'ssl_certfile': self.tls_cert,
                        'ssl_keyfile': self.tls_key,
                        'ssl_check_hostname': False,
                        'password': self.redis_password,
                        'decode_responses': True
                    }
                else:
                    print("Using TLS with CA certificate only")
                    # Without client certificates
                    sentinel_ssl_kwargs = {
                        'ssl': True,
                        'ssl_cert_reqs': 'required',
                        'ssl_ca_certs': self.tls_ca_cert,
                        'ssl_check_hostname': False
                    }
                    
                    connection_kwargs = {
                        'ssl': True,
                        'ssl_cert_reqs': 'required',
                        'ssl_ca_certs': self.tls_ca_cert,
                        'ssl_check_hostname': False,
                        'password': self.redis_password,
                        'decode_responses': True
                    }
                
                # Create Sentinel connection with TLS
                self.sentinel = Sentinel(
                    self.sentinel_nodes,
                    sentinel_kwargs={
                        'password': self.sentinel_password if self.sentinel_password else None,
                        **sentinel_ssl_kwargs
                    },
                    **connection_kwargs
                )
            else:
                # Connect without TLS
                self.sentinel = Sentinel(
                    self.sentinel_nodes,
                    sentinel_kwargs={
                        'password': self.sentinel_password if self.sentinel_password else None
                    },
                    password=self.redis_password,
                    decode_responses=True
                )
            
            # Discover and connect to master
            print("Discovering master...")
            self.master = self.sentinel.master_for(self.master_name, socket_timeout=5)
            
            # Test master connection
            self.master.ping()
            print("✓ Successfully connected to Redis Master via Sentinel!")
            
            # Get replica connection (for read operations)
            try:
                self.replica = self.sentinel.slave_for(self.master_name, socket_timeout=5)
                self.replica.ping()
                print("✓ Successfully connected to Redis Replica!")
            except Exception as e:
                print(f"⚠ Note: Could not connect to replica: {e}")
                print("  (This is OK if you have no replicas configured)")
            
            print()
            
            # Print sentinel and redis info
            self.print_sentinel_info()
            
            return True
            
        except ConnectionError as e:
            print(f"✗ Connection Error: {e}")
            return False
        except RedisError as e:
            print(f"✗ Redis Error: {e}")
            return False
        except Exception as e:
            print(f"✗ Unexpected Error: {e}")
            import traceback
            traceback.print_exc()
            return False
    
    def print_sentinel_info(self):
        """Print Sentinel and Redis information"""
        try:
            print("Sentinel & Redis Information:")
            print("-" * 60)
            
            # Get master info from Sentinel
            master_info = self.sentinel.sentinel_master(self.master_name)
            print(f"  Master Name: {master_info.get('name', 'N/A')}")
            print(f"  Master Address: {master_info.get('ip', 'N/A')}:{master_info.get('port', 'N/A')}")
            print(f"  Master Status: {master_info.get('flags', 'N/A')}")
            print(f"  Number of Replicas: {master_info.get('num-slaves', 'N/A')}")
            print(f"  Quorum: {master_info.get('quorum', 'N/A')}")
            
            # Get replica info
            try:
                replicas = self.sentinel.sentinel_slaves(self.master_name)
                if replicas:
                    print(f"\n  Replicas:")
                    for i, replica in enumerate(replicas, 1):
                        status = replica.get('flags', 'unknown')
                        print(f"    {i}. {replica.get('ip')}:{replica.get('port')} ({status})")
            except Exception as e:
                print(f"  Replicas: Could not retrieve ({e})")
            
            # Get sentinels monitoring this master
            try:
                sentinels = self.sentinel.sentinel_sentinels(self.master_name)
                print(f"\n  Sentinels Monitoring Master:")
                for i, sent in enumerate(sentinels, 1):
                    print(f"    {i}. {sent.get('ip')}:{sent.get('port')} ({sent.get('flags', 'unknown')})")
            except Exception as e:
                print(f"  Sentinels: Could not retrieve ({e})")
            
            # Get Redis master info
            try:
                redis_info = self.master.info('replication')
                print(f"\n  Redis Master Info:")
                print(f"    Role: {redis_info.get('role', 'N/A')}")
                print(f"    Connected Slaves: {redis_info.get('connected_slaves', 'N/A')}")
                
                # Get memory info
                memory_info = self.master.info('memory')
                used_memory_human = memory_info.get('used_memory_human', 'N/A')
                maxmemory_human = memory_info.get('maxmemory_human', 'N/A')
                print(f"    Used Memory: {used_memory_human}")
                print(f"    Max Memory: {maxmemory_human}")
            except Exception as e:
                print(f"  Redis Info: Could not retrieve ({e})")
            
            print("-" * 60)
            print()
            
        except Exception as e:
            print(f"  Warning: Could not retrieve complete info: {e}")
            print()
    
    def run_examples(self):
        """Run example operations"""
        if not self.master:
            print("✗ Not connected to Redis master!")
            return False
        
        print("=" * 60)
        print("Running Example Operations")
        print("=" * 60)
        print()
        
        try:
            # Example 1: Basic SET/GET
            print("[1] Basic SET/GET:")
            self.master.set('hello', 'world')
            value = self.master.get('hello')
            print(f"  SET hello='world' (on master)")
            print(f"  GET hello='{value}' (from master)")
            
            # Try reading from replica
            if self.replica:
                try:
                    replica_value = self.replica.get('hello')
                    print(f"  GET hello='{replica_value}' (from replica)")
                except:
                    pass
            
            print(f"  ✓ Success\n")
            
            # Example 2: Counter
            print("[2] Counter Operations:")
            self.master.set('counter', 0)
            for i in range(1, 6):
                new_val = self.master.incr('counter')
                print(f"  INCR counter → {new_val}")
            print(f"  ✓ Success\n")
            
            # Example 3: Hash operations
            print("[3] Hash Operations:")
            user_data = {
                'name': 'John Doe',
                'email': 'john@example.com',
                'age': '30'
            }
            self.master.hset('user:1001', mapping=user_data)
            print(f"  HSET user:1001 → {user_data}")
            
            retrieved = self.master.hgetall('user:1001')
            print(f"  HGETALL user:1001 → {retrieved}")
            print(f"  ✓ Success\n")
            
            # Example 4: List operations
            print("[4] List Operations:")
            self.master.delete('mylist')
            items = ['apple', 'banana', 'cherry', 'date']
            for item in items:
                self.master.rpush('mylist', item)
            print(f"  RPUSH mylist → {items}")
            
            list_items = self.master.lrange('mylist', 0, -1)
            print(f"  LRANGE mylist 0 -1 → {list_items}")
            print(f"  ✓ Success\n")
            
            # Example 5: Set operations
            print("[5] Set Operations:")
            self.master.delete('myset')
            members = ['red', 'green', 'blue', 'red']  # 'red' duplicated
            for member in members:
                self.master.sadd('myset', member)
            print(f"  SADD myset → {members}")
            
            set_members = self.master.smembers('myset')
            print(f"  SMEMBERS myset → {set_members}")
            print(f"  ✓ Success (duplicates removed)\n")
            
            # Example 6: Key expiration
            print("[6] Key Expiration (TTL):")
            self.master.setex('temp_key', 10, 'expires in 10 seconds')
            ttl = self.master.ttl('temp_key')
            print(f"  SETEX temp_key 10 'expires in 10 seconds'")
            print(f"  TTL temp_key → {ttl} seconds")
            print(f"  ✓ Success\n")
            
            # Example 7: Pipeline (for performance)
            print("[7] Pipeline Operations:")
            pipe = self.master.pipeline()
            for i in range(5):
                pipe.set(f'key:{i}', f'value:{i}')
            results = pipe.execute()
            print(f"  Pipelined 5 SET operations")
            print(f"  ✓ Success (faster than individual commands)\n")
            
            # Example 8: Sentinel-specific - Test failover awareness
            print("[8] Sentinel Awareness Test:")
            current_master = self.sentinel.discover_master(self.master_name)
            print(f"  Current Master: {current_master[0]}:{current_master[1]}")
            print(f"  ✓ Sentinel can discover master")
            print(f"  ✓ Automatic failover supported\n")
            
            print("=" * 60)
            print("All examples completed successfully! ✓")
            print("=" * 60)
            print()
            
            return True
            
        except Exception as e:
            print(f"\n✗ Error during examples: {e}")
            import traceback
            traceback.print_exc()
            return False
    
    def cleanup_examples(self):
        """Clean up example keys"""
        if not self.master:
            return
        
        print("Cleaning up example keys...")
        keys_to_delete = [
            'hello', 'counter', 'user:1001', 
            'mylist', 'myset', 'temp_key'
        ]
        
        for key in keys_to_delete:
            try:
                self.master.delete(key)
            except:
                pass
        
        # Clean up pipeline keys
        for i in range(5):
            try:
                self.master.delete(f'key:{i}')
            except:
                pass
        
        print("✓ Cleanup complete\n")
    
    def close(self):
        """Close connections"""
        if self.master:
            self.master.close()
        if self.replica:
            self.replica.close()
        print("Connections closed.")


def main():
    """Main application"""
    client = RedisSentinelClient()
    
    # Connect via Sentinel
    if not client.connect():
        print("\n✗ Failed to connect to Redis via Sentinel!")
        print("Please check:")
        print("  - SENTINEL_HOSTS environment variable")
        print("  - MASTER_NAME environment variable")
        print("  - REDIS_PASSWORD environment variable")
        print("  - SENTINEL_PASSWORD environment variable (if required)")
        print("  - TLS_CA_CERT file exists and is valid (if USE_TLS=true)")
        print("  - Network connectivity to Sentinel nodes")
        sys.exit(1)
    
    try:
        # Run examples
        success = client.run_examples()
        
        if success:
            # Optional: Keep connection alive for testing
            keep_alive = os.getenv('KEEP_ALIVE', 'false').lower() == 'true'
            
            if keep_alive:
                print("=" * 60)
                print("Connection kept alive. Press Ctrl+C to exit.")
                print("=" * 60)
                print("Monitoring master status...")
                print()
                
                while True:
                    try:
                        # Ping master every 30 seconds
                        client.master.ping()
                        current_master = client.sentinel.discover_master(client.master_name)
                        print(f"[{time.strftime('%H:%M:%S')}] ✓ Master is responsive: {current_master[0]}:{current_master[1]}")
                        time.sleep(30)
                    except KeyboardInterrupt:
                        print("\n\nShutting down...")
                        break
                    except Exception as e:
                        print(f"[{time.strftime('%H:%M:%S')}] ⚠ Warning: {e}")
                        print("  Sentinel will automatically failover if master is down")
                        time.sleep(5)
            else:
                # Clean up
                client.cleanup_examples()
        
    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
    except Exception as e:
        print(f"\n✗ Unexpected error: {e}")
        sys.exit(1)
    finally:
        client.close()
    
    print("\n✓ Application finished successfully!")


if __name__ == '__main__':
    main()

