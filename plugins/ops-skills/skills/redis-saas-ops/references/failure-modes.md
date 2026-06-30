# Managed Redis — Failure-mode catalog

A deeper, exhaustive companion to the SKILL.md decision trees. Grouped by category.
Each entry: error signature → probe → root cause → fix. Provider notes inline.

---

## 1. Connectivity

### `Could not connect to Redis at HOST:PORT: Connection timed out`
- **Probe:** `nc -vz HOST PORT`; `dig +short HOST`.
- **If `nc` times out:** network path blocked.
  - **AWS:** the client's security group is not allowed inbound on the Redis SG. Add a rule:
    `aws ec2 authorize-security-group-ingress --group-id <redis-sg> --protocol tcp --port 6379 --source-group <client-sg>`.
    Also confirm client and Redis subnets route to each other (same VPC or peered with routes).
  - **GCP:** client not in the authorized network, or PSA range not allocated. Confirm
    `connectMode` and that the client VPC has the private services access range.
  - **Redis Cloud:** the DB's CIDR allowlist ("Source IP/Subnet") doesn't include the client's
    egress IP, or you're using the public endpoint without allowlisting, or VPC peering isn't active.
- **If `nc` succeeds but `redis-cli PING` hangs:** it's TLS or auth, not network (see below).

### `Connection reset by peer` immediately
- Almost always a TLS mismatch — see §2.

### Connection works from bastion, fails from app
- App is in a different subnet/SG than the bastion, or app's egress SG lacks the rule, or the
  app uses the wrong (public vs private) endpoint. Compare the exact host:port both use.

### Connection drops every ~N minutes
- An idle-timeout on a NAT/LB/firewall in the path, or Redis `timeout` config. Enable TCP
  keepalive in the client; lower `health_check_interval`. ElastiCache has a `tcp-keepalive` param.

---

## 2. TLS / encryption-in-transit

### `SSL routines:ssl3_get_record:wrong version number`
- Client spoke TLS to a plaintext port, or plaintext to a TLS port. Match scheme↔port:
  TLS endpoints want `rediss://`, plaintext want `redis://`.

### `unable to get local issuer certificate` / `CERTIFICATE_VERIFY_FAILED`
- Client doesn't trust the server CA. For public CAs, point the client at system root CAs.
  For Redis Cloud with a private CA, download their CA cert and pass it
  (`ssl_ca_certs=` in redis-py, `ca:` in ioredis tls options).
- **Do NOT** disable verification in prod (`ssl_cert_reqs=none` / `rejectUnauthorized:false`)
  except as a temporary diagnostic — it defeats the point of TLS.

### Cert subject mismatch / SNI
- You dialed an IP or a load-balancer name; the cert is for the endpoint hostname. Always dial
  the provider hostname and pass `servername`/SNI equal to it.

### TLS works in `redis-cli --tls` but not in the app
- App didn't enable TLS in the client config, or used `redis://`. Wire `tls`/`ssl=True`.
- For lettuce: `RedisURI.builder().withSsl(true).withStartTls(false).build()` and ensure the
  truststore has the CA.

---

## 3. Authentication & ACL

### `NOAUTH Authentication required.`
- Server requires a password; client sent none. URL form: `redis://:THEPASSWORD@host:port`
  (note the empty username slot before the colon when using a password-only/`default` user).

### `WRONGPASS invalid username-password pair or user is disabled.`
- Wrong password, OR you're on an ACL/RBAC setup and sent a password without the username.
  Pass both: `--user appuser -a 'secret'`. ElastiCache RBAC and Redis Cloud ACL require the
  username; the legacy ElastiCache "AUTH token" is password-only against the `default` user.
- Also: the user may be disabled. `ACL GETUSER appuser` → look for `off`/`on`.

### `NOPERM this user has no permissions to run the 'GET' command`
- ACL command/key/channel rule too narrow. Inspect `ACL GETUSER appuser`; the access string
  looks like `on >pass ~app:* +@read +@write`. Add the missing command category
  (`+@read`, `+@write`, `+@connection`) or key pattern (`~app:*`).
- **AWS:** update the `aws_elasticache_user` `access_string`. **Redis Cloud:** edit the role/ACL
  in the console. Never patch ACLs only at runtime in managed setups — they reset on changes.

### Auth fine in CLI, app gets `WRONGPASS`
- App holds a rotated/stale secret. Re-fetch from Secrets Manager / Secret Manager at startup
  and on auth failure; don't bake the password into the image or cache it forever.

---

## 4. Memory & eviction

### `OOM command not allowed when used memory > 'maxmemory'.`
- `INFO memory` → `maxmemory_policy`. If `noeviction`, writes fail when full by design.
  - Cache workload → set an `allkeys-*` policy.
  - Datastore workload → scale up; do NOT silently start evicting data.
- Find what's eating memory: `redis-cli --bigkeys`; `MEMORY USAGE <key>`;
  `INFO keyspace` (keys per db + how many have TTLs).

### Eviction policy not taking effect
- On managed Redis you cannot `CONFIG SET maxmemory-policy`. You must change the parameter group
  (AWS) / `redis_configs` (GCP) / DB config (Redis Cloud), then apply (may need a brief restart).

### Surprising key disappearance
- An `allkeys-lru`/`allkeys-lfu` policy evicted keys you expected to persist. If certain keys
  must never evict, either use a `volatile-*` policy and give only the disposable keys TTLs, or
  separate durable data into a different DB/instance with `noeviction` + adequate memory.

### `volatile-lru` but nothing evicts → OOM
- `volatile-*` policies only consider keys that HAVE a TTL. If most keys are TTL-less, the
  instance can't free memory and behaves like `noeviction`. Set TTLs or switch to `allkeys-*`.

### Fragmentation
- `mem_fragmentation_ratio` well above 1.0 (e.g. >1.5) means allocator overhead. Enable
  `activedefrag` if the tier allows, or scale/restart in a maintenance window.

---

## 5. Latency & throughput

### General triage order
1. `--latency` / `--latency-history` — is it network round-trip or server?
2. `SLOWLOG GET 25` — which commands are slow and with what args?
3. `INFO commandstats` — `usec_per_call` per command; find the expensive ones.
4. `--bigkeys` — are there pathologically large keys/collections?
5. `INFO stats` — `instantaneous_ops_per_sec`, hit ratio, evictions.

### O(N) command offenders
`KEYS`, `SMEMBERS`, `HGETALL`, `LRANGE 0 -1`, `SUNION`, `SINTER`, `SORT`, `ZRANGEBYSCORE`
without limits. Each blocks the single thread for the whole collection. Replace with:
- `KEYS` → `SCAN`/`HSCAN`/`SSCAN`/`ZSCAN` with `COUNT`.
- full-collection reads → paginate or restructure (e.g. hash of fields you actually need).

### Hot key
One key gets disproportionate traffic and serializes everything. Detect via `--hotkeys`
(needs LFU policy) or app metrics. Fix: client-side cache, shard the key, or add a read replica.

### Periodic latency spikes
RDB fork (snapshot) or AOF rewrite pauses. Move the backup window; on replica-backed tiers, back
up from a replica. ElastiCache: set `snapshot-window` off-peak.

### TLS / cross-AZ overhead at p99
TLS handshakes and cross-AZ hops add latency. Reuse pooled connections (don't reconnect per
request); co-locate client and Redis in the same AZ/region.

---

## 6. Cluster mode

### `MOVED <slot> <ip>:<port>`
- Client isn't cluster-aware and connected to the wrong shard. Use the cluster-mode client
  class and connect to the **configuration endpoint**:
  - ioredis: `new Redis.Cluster([{ host, port }], { redisOptions: { tls, password } })`
  - redis-py: `RedisCluster(host=cfg_endpoint, port=port, ssl=...)`
  - lettuce: `RedisClusterClient.create(RedisURI...)`
  - go-redis: `redis.NewClusterClient(&redis.ClusterOptions{Addrs: []string{cfg}})`
- `redis-cli -c` follows redirects for manual debugging.

### `CROSSSLOT Keys in request don't hash to the same slot`
- A multi-key op spanned slots. Co-locate related keys with a hash tag — only the substring
  inside `{}` is hashed: `order:{1001}:items`, `order:{1001}:total` → same slot. Then `MGET`,
  `MSET`, transactions, and Lua over those keys work.

### MOVED storms after resize/scale
- Client cached a stale slot map. Ensure topology refresh is enabled (ioredis
  `slotsRefreshTimeout`/`slotsRefreshInterval`; lettuce periodic/adaptive refresh) and reconnect.

### `CLUSTERDOWN Hash slot not served`
- Some slots have no owner — a shard is down or a resharding is mid-flight. `CLUSTER INFO`
  (`cluster_state:fail`), `CLUSTER SLOTS`. Wait for recovery / failover; check node health.

---

## 7. Connections & pooling

### `ERR max number of clients reached`
- `INFO clients` → `connected_clients` vs `maxclients`. `CLIENT LIST | awk '{print $NF}'`
  groups by source command — but better, group by `addr` to find the leaking host.
- Root cause is nearly always a client creating a new connection per request and never closing
  it. Fix: one shared pooled client per process.
- Secondary: pool size × instance count exceeds `maxclients`. Right-size the pool (10–50/instance
  is plenty for most apps) and/or scale the node (bigger nodes allow more clients).

### `Connection pool exhausted` / `Timeout waiting for connection from pool`
- Pool too small for concurrency, or connections held by slow/blocking commands. Increase pool
  modestly, bound command timeouts, isolate blocking ops (`BLPOP`/`BRPOP`) on a separate pool.

### Connections spike during deploys
- Old and new pods overlap during rolling deploys. Lower idle-connection timeout; ensure
  graceful shutdown calls `client.quit()`/`pool.disconnect()`.

---

## 8. Replication, failover, READONLY

### `READONLY You can't write against a read only replica.`
- Writing to a replica/reader endpoint. Use the **primary** endpoint for writes. After a
  failover, a client pinned to a node IP may now be talking to the new replica — use the
  provider's primary DNS endpoint (it repoints) and reconnect on `READONLY`.

### `master_link_status:down` on replica
- Replica lost its link to the primary. Check network, throttling, and primary health.

### High replication lag
- Write burst exceeds replication bandwidth. Reduce write spikes, pipeline less aggressively, or
  scale. Monitor CW `ReplicationLag` / GCP replication metrics.

### Failover causes a flurry of errors
- Expected: a few seconds of resets/`READONLY` during promotion. Clients MUST retry with
  backoff and reconnect to make this invisible. Test it (SKILL.md "failover testing").
- **Memorystore Basic tier = no failover** (single node → downtime). Use Standard tier for HA.
- **ElastiCache** needs Multi-AZ + automatic failover enabled for transparent failover.

---

## 9. Modules & persistence

### `ERR unknown command 'FT.SEARCH'` / `'JSON.SET'`
- Module not present. `MODULE LIST` where permitted. Standard ElastiCache and Memorystore for
  Redis do NOT ship RediSearch/RedisJSON. Use Redis Cloud/Enterprise for modules, or implement
  the capability differently. Don't assume parity across providers.

### Data loss after a node replacement
- Managed Redis defaults favor availability over strict durability. If you need durability,
  configure AOF/persistence on a tier that supports it (Redis Cloud per-DB; ElastiCache/
  Memorystore via snapshots, with the understanding that you can lose writes between snapshots).
  For a true system of record, write-through to a durable database and treat Redis as a cache.
