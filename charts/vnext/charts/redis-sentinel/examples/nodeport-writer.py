#!/usr/bin/env python3
"""Write a key per interval through a NodePort-exposed redis-sentinel release, read
every key ever written back, and report what is missing.

    pip install redis
    export REDIS_NODES="10.1.2.3:31001,10.1.2.3:31002,10.1.2.3:31003"
    export SENTINEL_NODES="10.1.2.3:32001,10.1.2.3:32002,10.1.2.3:32003"
    export REDIS_PASSWORD=...        # secret key: redis-password
    export SENTINEL_PASSWORD=...     # secret key: sentinel-password   (optional)
    ./nodeport-writer.py

WHY THIS DOES ITS OWN MASTER DISCOVERY, instead of redis.sentinel.Sentinel:

A Sentinel client asks Sentinel for the master address and connects to whatever it gets
back, so that address has to be routable from where the client runs. Over NodePort it is
only routable if the release was configured for it:

    --set externalAccess.service.type=NodePort
    --set externalAccess.service.nodeHost=<node IP or a VIP in front of the nodes>
    --set externalAccess.service.nodePorts.redis={30001,30002,30003}
    --set externalAccess.service.nodePorts.sentinel={31001,31002,31003}

Without nodeHost and the pinned nodePorts the pods announce their in-cluster FQDN, the
address Sentinel hands back is unreachable from outside, and a Sentinel-aware client fails
on the second hop. NOTES.txt says so at install time. (LoadBalancer needs none of this:
each pod gets its own address and the service port IS the reachable one.)

So when the release IS configured that way, a plain
`redis.sentinel.Sentinel([...]).master_for('mymaster')` works and this script is
unnecessary. It exists for the case where it is not - and for one thing a Sentinel client
does not give you: doing the discovery by hand means seeing the roles of ALL pods every
cycle, which is what makes a split brain or a stuck failover visible rather than inferred.

Sentinel is still queried when SENTINEL_NODES is set, but only to PRINT what it reports.
Comparing that address against the endpoints below is the quickest way to tell whether the
announce configuration took: an in-cluster FQDN there means it did not.
"""
import os
import sys
import time
from datetime import datetime, timezone

try:
    import redis
except ImportError:
    sys.exit("pip install redis")


def env_endpoints(name):
    """Parse host:port,host:port,... - and reject a MISSING HOST loudly.

    An unset shell variable is the common way to get here: REDIS_NODES="$NODE:31601"
    with $NODE empty becomes ":31601", which used to be accepted, and every endpoint
    then failed with "Error -2 ... Name or service not known" - three DNS errors that
    say nothing about the actual mistake. Naming the variable is the whole fix.
    """
    raw = os.environ.get(name, "").strip()
    if not raw:
        return []
    out = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        if ":" not in item:
            sys.exit(f"{name}: '{item}' is not host:port")
        host, _, port = item.rpartition(":")
        if not host:
            sys.exit(f"{name}: '{item}' has no host - an unset variable?\n"
                     f"  {name}={raw}\n"
                     f"  Expected something like 10.1.2.3:31601,10.1.2.3:31602")
        if not port.isdigit():
            sys.exit(f"{name}: '{item}' has a non-numeric port")
        out.append((host, int(port)))
    return out


REDIS_NODES = env_endpoints("REDIS_NODES")
SENTINEL_NODES = env_endpoints("SENTINEL_NODES")
REDIS_PASSWORD = os.environ.get("REDIS_PASSWORD") or None
SENTINEL_PASSWORD = os.environ.get("SENTINEL_PASSWORD") or None
INTERVAL = int(os.environ.get("INTERVAL", "60"))
PREFIX = os.environ.get("KEY_PREFIX", "probe")
# The record of what we wrote lives on disk, so restarting this script does not reset the
# ledger it uses to detect loss. Without that, a restart looks like a clean slate and the
# keys a failover ate become invisible.
LEDGER = os.environ.get("LEDGER", f"/tmp/{PREFIX}-ledger.txt")

if not REDIS_NODES:
    sys.exit("REDIS_NODES is required, e.g. 10.1.2.3:31001,10.1.2.3:31002")


def connect(host, port, password, timeout=3):
    return redis.Redis(
        host=host, port=port, password=password,
        socket_connect_timeout=timeout, socket_timeout=timeout,
        decode_responses=True,
    )


def role_of(host, port):
    """(role, error). Never raises - an unreachable node is data, not a crash."""
    try:
        c = connect(host, port, REDIS_PASSWORD)
        info = c.info("replication")
        return info.get("role"), None
    except redis.AuthenticationError as e:
        # Worth separating from a generic failure: this is the two-password mistake.
        return None, f"AUTH failed ({e}) - is REDIS_PASSWORD the redis-password key?"
    except Exception as e:  # noqa: BLE001 - any failure is just "not usable now"
        return None, str(e)


def find_master():
    """The master endpoint, plus the role of everything else. Fails soft."""
    master, roles = None, []
    for host, port in REDIS_NODES:
        role, err = role_of(host, port)
        roles.append((host, port, role or f"unreachable: {err}"))
        if role == "master" and master is None:
            master = (host, port)
    return master, roles


def sentinel_view():
    """What Sentinel reports, for display only. See the module docstring."""
    for host, port in SENTINEL_NODES:
        try:
            c = connect(host, port, SENTINEL_PASSWORD)
            addr = c.execute_command("SENTINEL", "get-master-addr-by-name", "mymaster")
            ck = c.execute_command("SENTINEL", "CKQUORUM", "mymaster")
            return f"{host}:{port} says master={addr[0]}:{addr[1]}  |  {ck}"
        except redis.AuthenticationError:
            return (f"{host}:{port} AUTH failed - SENTINEL_PASSWORD must be the "
                    f"sentinel-password key, which is NOT the redis one")
        except Exception as e:  # noqa: BLE001
            continue
    return "no Sentinel answered"


def load_ledger():
    try:
        with open(LEDGER) as f:
            return [ln.strip() for ln in f if ln.strip()]
    except FileNotFoundError:
        return []


def append_ledger(key):
    with open(LEDGER, "a") as f:
        f.write(key + "\n")


def stamp():
    return datetime.now(timezone.utc).astimezone().strftime("%H:%M:%S")


def main():
    print(f"[{stamp()}] endpoints={len(REDIS_NODES)} interval={INTERVAL}s ledger={LEDGER}")
    written = load_ledger()
    if written:
        print(f"[{stamp()}] resuming with {len(written)} key(s) already written")

    while True:
        master, roles = find_master()

        # Group identical statuses. Printing the same long error once per node made the
        # line unreadable in the one case where reading it matters - a wrong password
        # fails every node with the same sentence.
        groups = {}
        for h, p, r in roles:
            groups.setdefault(r, []).append(f"{h}:{p}")
        parts = []
        for status, nodes in groups.items():
            parts.append(f"{','.join(nodes)} = {status}")
        print(f"\n[{stamp()}] " + "\n           ".join(parts))
        if SENTINEL_NODES:
            print(f"[{stamp()}] sentinel: {sentinel_view()}")

        if master is None:
            # Not a crash: this is the failover window, and staying up through it is the
            # whole point of leaving this running during a test.
            print(f"[{stamp()}] NO MASTER right now - retrying in {INTERVAL}s")
            time.sleep(INTERVAL)
            continue

        mh, mp = master
        key = f"{PREFIX}:{int(time.time())}"
        try:
            c = connect(mh, mp, REDIS_PASSWORD)
            c.set(key, stamp())
            append_ledger(key)
            written.append(key)
            print(f"[{stamp()}] WROTE {key} to master {mh}:{mp}")
        except redis.ReadOnlyError:
            # We picked a node that was master a second ago and is a replica now. Do not
            # record the key: it was never accepted.
            print(f"[{stamp()}] {mh}:{mp} is READONLY - mastership moved mid-write, "
                  f"re-discovering next cycle")
        except Exception as e:  # noqa: BLE001
            print(f"[{stamp()}] write failed on {mh}:{mp}: {e}")

        # Read the WHOLE ledger back, not just the last key. One key proves the connection
        # works; the ledger proves nothing was lost, which is the question a failover
        # actually raises.
        if written:
            try:
                c = connect(mh, mp, REDIS_PASSWORD)
                values = c.mget(written)
                missing = [k for k, v in zip(written, values) if v is None]
                line = (f"[{stamp()}] ledger={len(written)} present={len(written)-len(missing)} "
                        f"missing={len(missing)}")
                if missing:
                    shown = ", ".join(missing[:5])
                    more = "" if len(missing) <= 5 else f" (+{len(missing)-5} more)"
                    print(f"{line}  <-- DATA LOSS: {shown}{more}")
                else:
                    print(line)
            except Exception as e:  # noqa: BLE001
                print(f"[{stamp()}] read-back failed: {e}")

        time.sleep(INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nstopped")
