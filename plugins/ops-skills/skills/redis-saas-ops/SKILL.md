---
name: redis-saas-ops
description: >
  Debugging and automation expert for managed/SaaS Redis — Redis Cloud (Redis Enterprise),
  AWS ElastiCache (Redis OSS / Valkey), and GCP Memorystore for Redis. Diagnoses connection
  refused/timeout, TLS handshake failures (rediss:// vs redis://, SNI/cert), AUTH errors
  (NOAUTH/WRONGPASS, ACL), max-memory & eviction (OOM command not allowed, maxmemory-policy),
  high latency (slowlog, big keys, O(N) commands like KEYS/SMEMBERS), cluster-mode issues
  (MOVED/CROSSSLOT, non-cluster-aware clients), replication lag & failover, connection-pool
  exhaustion (max number of clients reached), READONLY-on-replica writes, module availability
  (RediSearch/JSON) differences, and RDB/AOF persistence confusion. Also covers automation:
  Terraform provisioning, client config (pooling/timeouts/retries/TLS), monitoring & alerting
  (CloudWatch / Cloud Monitoring / Redis Cloud metrics), backup/restore, safe SCAN-based key
  scanning, and failover testing. Use this skill whenever the user mentions redis, rediss://,
  redis-cli, ElastiCache, Memorystore, Redis Cloud, Redis Enterprise, or pastes error strings
  NOAUTH, WRONGPASS, MOVED, CROSSSLOT, "OOM command not allowed", "max number of clients
  reached", READONLY, "Connection reset by peer", "SSL routines", or mentions ioredis,
  redis-py, lettuce, jedis, or go-redis against a managed Redis endpoint. When in doubt about
  a managed Redis problem, use this skill — over-trigger rather than miss.
---

# redis-saas-ops

You are an SRE specializing in managed/SaaS Redis. You diagnose production incidents fast and
ship automation that prevents them. You are provider-general: every recommendation states what
changes across **Redis Cloud (Redis Enterprise)**, **AWS ElastiCache**, and **GCP Memorystore**.

## Guiding Principles

1. **Endpoint, auth, transport — in that order.** Most "Redis is down" tickets are network or
   TLS, not Redis. Prove TCP reachability before debugging Redis itself.
2. **`rediss://` ≠ `redis://`.** One `s` decides whether the client speaks TLS. Half of managed
   Redis incidents are a scheme/port/TLS-flag mismatch with the provider's actual config.
3. **Never run O(N) commands on prod.** `KEYS`, `SMEMBERS`, `HGETALL`, `FLUSHALL`, unbounded
   `LRANGE` block the single thread. Use `SCAN`/`HSCAN`/`SSCAN` with `COUNT`, always.
4. **Memory pressure is a config decision, not an accident.** Know the `maxmemory-policy`.
   `noeviction` + a write = `OOM command not allowed`. Pick the policy deliberately per workload.
5. **Cluster mode changes the client contract.** If the endpoint is clustered, the client must be
   cluster-aware or you get `MOVED`/`CROSSSLOT`. This is a client bug, not a server bug.
6. **Managed ≠ self-managed.** You don't get `CONFIG SET` on many params, you don't pick the
   persistence story freely, and module availability differs. Check the provider before assuming.
7. **Automate idempotently with dry-run first.** Terraform plan before apply; `SCAN` before
   delete; test failover in staging before trusting it in prod.

## Connection model cheat-sheet (know this before debugging)

| | Redis Cloud (Enterprise) | AWS ElastiCache | GCP Memorystore |
|---|---|---|---|
| Default port | 6379 / assigned (e.g. 12345) | 6379 (TLS often 6380) | 6379 |
| TLS | optional, per-DB toggle | "in-transit encryption" per cluster, immutable after create | "in-transit encryption" tier, set at create |
| Endpoint type | public or private (VPC peering / PrivateLink) | VPC-internal only (no public IP) | VPC-internal only (private IP) |
| Auth | password and/or ACL user | AUTH token (legacy) or RBAC users (ACL) | AUTH string (optional) |
| Cluster mode | per-DB (OSS or Enterprise sharding) | "cluster mode enabled" vs disabled | Cluster vs Basic/Standard tier |
| Reach from laptop | yes if public endpoint | no — needs VPN/bastion/SSM in-VPC | no — needs VPN/bastion in-VPC |

**First move on any connection ticket:** identify provider + whether the endpoint is public,
whether TLS is on, and whether cluster mode is on. Everything branches off these three facts.

## Debugging

Decision flow: **identify symptom → probe with exact command → root cause → fix → verify.**

### Symptom 1 — Connection refused / timeout

```
# Step A: DNS resolves?
nslookup <endpoint-host>          # or: dig +short <endpoint-host>
# Step B: TCP reachable? (this proves network independent of Redis/TLS/auth)
nc -vz <host> <port>              # "succeeded" = network OK ; timeout = network problem
timeout 5 bash -c "cat < /dev/null > /dev/tcp/<host>/<port>" && echo OPEN || echo BLOCKED
# Step C: Redis answers PING?
redis-cli -h <host> -p <port> PING       # add --tls if in-transit encryption is on
```

| Probe result | Root cause | Fix |
|---|---|---|
| DNS fails | wrong endpoint / not in right VPC for private DNS | Use the provider's configuration endpoint; ensure your host is in the peered VPC |
| `nc` times out, DNS ok | Security group / firewall / NACL blocks the port | ElastiCache: SG inbound must allow your client SG on 6379/6380. Memorystore: add client CIDR to authorized network / VPC. Redis Cloud: allow CIDR in DB "Source IP/Subnet" allowlist |
| `nc` times out from laptop, private endpoint | No public reachability by design | Connect from a bastion / VPN / SSM session inside the VPC — managed Redis in AWS/GCP has no public IP |
| `nc` OK, `PING` hangs then resets | TLS expected but client sent plaintext (or reverse) | See Symptom 2 |
| `nc` OK, `PING` → `NOAUTH` / `WRONGPASS` | auth required/wrong | See Symptom 3 |
| Intermittent timeouts under load | pool exhaustion or `maxclients` | See Symptom 7 |

ElastiCache SG check:
```
aws ec2 describe-security-groups --group-ids <redis-sg> \
  --query "SecurityGroups[].IpPermissions[?FromPort==\`6379\`]"
```
Memorystore authorized network / connect mode:
```
gcloud redis instances describe <name> --region <region> \
  --format="value(authorizedNetwork,connectMode,host,port)"
```

### Symptom 2 — TLS handshake failure / `rediss://` vs `redis://`

Error signatures: `Error: Connection reset by peer` immediately after connect,
`SSL routines:ssl3_get_record:wrong version number`, `ECONNRESET` on handshake,
`redis.exceptions.ConnectionError: Error while reading from socket`, client hangs then drops.

```
# Is TLS actually on? Probe both ways:
redis-cli -h <host> -p <port> PING            # plaintext attempt
redis-cli -h <host> -p <port> --tls PING      # TLS attempt
# Inspect the cert / SNI directly:
openssl s_client -connect <host>:<port> -servername <host> </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

| Observation | Root cause | Fix |
|---|---|---|
| plaintext PING hangs/resets, `--tls` PING works | server requires TLS, client used `redis://` | Use `rediss://` URL (or set `tls:{}` / `ssl=True`). See client snippets below |
| `--tls` resets, plaintext works | client forced TLS on a non-TLS DB | Use `redis://`, drop the TLS flag |
| `wrong version number` | scheme/port mismatch (plaintext to TLS port or vice-versa) | Match scheme to port: TLS port → `rediss://` |
| cert `subject` ≠ host you dialed | SNI/hostname mismatch (dialed IP, or behind LB) | Connect by the provider hostname, not IP; pass `servername`/SNI = endpoint host |
| `unable to get local issuer certificate` | client doesn't trust the CA | Point client CA bundle at system roots; for Redis Cloud download their CA if self-signed |

Client wiring (TLS on):
```js
// ioredis — rediss:// auto-enables TLS; or pass tls explicitly
new Redis(`rediss://:${pw}@${host}:${port}`);
new Redis({ host, port, password: pw, tls: { servername: host } });
```
```python
# redis-py
redis.Redis(host=host, port=port, password=pw, ssl=True, ssl_cert_reqs="required")
# or: redis.from_url("rediss://:pw@host:port")
```
```
# lettuce (Java): RedisURI.builder().withSsl(true).withVerifyPeer(true)...build()
```

### Symptom 3 — AUTH errors: `NOAUTH` / `WRONGPASS` / `NOPERM`

| Error | Meaning | Fix |
|---|---|---|
| `NOAUTH Authentication required` | server wants auth, client sent none | Supply password; in URL `redis://:PASSWORD@host:port` (note empty username before `:`) |
| `WRONGPASS invalid username-password pair or user is disabled` | wrong password OR sending password without the right ACL username | If using ACL users (RBAC), pass BOTH user and pass: `--user <user> -a <pass>`. ElastiCache RBAC and Redis Cloud ACL need the username, not just the token |
| `NOPERM this user has no permissions to run the '<cmd>' command` | ACL too restrictive | Inspect with `ACL GETUSER <user>`; widen with `ACL SETUSER` (self-managed) or update the user's ACL rule in the provider console/API |
| auth works in `redis-cli`, fails in app | app reads stale/rotated secret | Re-pull from Secrets Manager / Secret Manager; check the app isn't caching an old token |

```
redis-cli -h <host> -p <port> --user <user> -a <pass> --no-auth-warning ACL WHOAMI
redis-cli ... ACL LIST            # see all users + rules
redis-cli ... ACL GETUSER <user>  # see one user's commands/keys/channels
```
ElastiCache RBAC user check / GCP AUTH:
```
aws elasticache describe-users --query "Users[].[UserName,AccessString,Authentication.Type]"
gcloud redis instances describe <name> --region <region> --format="value(authEnabled)"
gcloud redis get-auth-string <name> --region <region>   # the AUTH token Memorystore expects
```

### Symptom 4 — Max memory & eviction: `OOM command not allowed`

Error: `OOM command not allowed when used memory > 'maxmemory'`.

```
redis-cli ... INFO memory | grep -E "used_memory:|maxmemory:|maxmemory_policy:|mem_fragmentation_ratio:"
redis-cli ... INFO stats  | grep -E "evicted_keys|keyspace_hits|keyspace_misses"
```

| Finding | Root cause | Fix |
|---|---|---|
| `maxmemory_policy:noeviction` + writes failing | by design refuses writes when full | If it's a cache: switch to `allkeys-lru` / `allkeys-lfu`. If it's a datastore: scale memory, don't switch to eviction (you'd lose data) |
| `used_memory ≈ maxmemory`, `evicted_keys` climbing | undersized / no TTLs | Add TTLs (`EXPIRE`), scale node, or fix a key leak. Find offenders with `--bigkeys` (Symptom 5) |
| `mem_fragmentation_ratio > 1.5` | fragmentation | `activedefrag yes` if supported; or scale/restart node in maintenance window |
| volatile policy but keys have no TTL | `volatile-*` only evicts keys WITH a TTL → behaves like `noeviction` for TTL-less keys | Either set TTLs or use an `allkeys-*` policy |

Setting the policy (managed = via provider, NOT `CONFIG SET`):
```
# ElastiCache: parameter group
aws elasticache modify-cache-parameter-group --cache-parameter-group-name <pg> \
  --parameter-name-values "ParameterName=maxmemory-policy,ParameterValue=allkeys-lru"
# Memorystore:
gcloud redis instances update <name> --region <region> \
  --update-redis-config maxmemory-policy=allkeys-lru
# Redis Cloud: set "Data eviction policy" in the DB config (console/API)
```

### Symptom 5 — High latency / slow commands

```
redis-cli ... --latency                 # live min/avg/max round-trip
redis-cli ... --latency-history          # trend over time
redis-cli ... SLOWLOG GET 25             # slowest recent commands (usec + args)
redis-cli ... INFO commandstats | sort -t'=' -k3 -rn | head   # per-command usec_per_call
redis-cli ... --bigkeys                  # biggest key per type (uses SCAN, safe-ish)
redis-cli ... MEMORY USAGE <key>         # exact bytes of one key
```

| Finding | Root cause | Fix |
|---|---|---|
| SLOWLOG shows `KEYS`, `SMEMBERS`, `HGETALL`, `SORT`, `SUNION` | O(N) command blocking the single thread | Replace `KEYS`→`SCAN`; page big collections; precompute; cap result sizes |
| `--bigkeys` shows multi-MB keys / huge collections | hot/big key blocks on every access | Split the key (sharding), use hashes with `HSCAN`, set size limits |
| latency spikes periodically | RDB fork / AOF rewrite / backup window | Move backup window; on a replica-backed tier, back up from replica |
| latency high only at p99 | network jitter / cross-AZ / TLS overhead | Co-locate client and Redis in same AZ/region; reuse connections (pool) |
| Lua/`EVAL` in SLOWLOG | long-running script blocks everything | Keep scripts O(small); avoid full-keyspace scripts |

### Symptom 6 — Cluster mode: `MOVED` / `CROSSSLOT`

| Error | Root cause | Fix |
|---|---|---|
| `MOVED 3999 10.0.1.5:6379` | client is NOT cluster-aware, hit wrong shard | Use a cluster client: ioredis `new Redis.Cluster([...])`, redis-py `RedisCluster(...)`, lettuce `RedisClusterClient`, go-redis `NewClusterClient`. Connect to the **configuration endpoint**, not a node IP |
| `CROSSSLOT Keys in request don't hash to the same slot` | multi-key op (`MGET`, `MSET`, `SUNIONSTORE`, transactions) across different slots | Use hash tags so related keys share a slot: `user:{42}:name`, `user:{42}:email` → both hash on `42`. Or split into per-key calls |
| `MOVED` storms after a resize | client cached old slot map | Ensure client refreshes topology (`slotsRefreshTimeout`); reconnect after scaling |

```
redis-cli -c -h <host> -p <port> ...          # -c = follow redirects (cluster mode)
redis-cli ... CLUSTER INFO                      # cluster_state:ok ?
redis-cli ... CLUSTER SLOTS                      # slot → node map
redis-cli ... CLUSTER KEYSLOT "user:{42}:name"  # which slot a key lands in
```

### Symptom 7 — Connection pool exhaustion / `max number of clients reached`

Error: `ERR max number of clients reached`, app-side `Connection pool exhausted` /
`ioredis ... max retries`, rising connect latency.

```
redis-cli ... INFO clients   | grep -E "connected_clients|blocked_clients|maxclients"
redis-cli ... CONFIG GET maxclients     # (managed: may be read-only)
redis-cli ... CLIENT LIST | awk '{print $NF}' | sort | uniq -c   # connections by source
```

| Finding | Root cause | Fix |
|---|---|---|
| `connected_clients` near `maxclients` | client leak — new connection per request, never closed | Use ONE shared pooled client per process; never `new Redis()` per request |
| many idle conns from one host | pool too large × many instances | Size pool: `pool = (peak concurrent cmds)`, not "big number". 10–50/instance is plenty for most apps |
| `blocked_clients` high | `BLPOP`/`BRPOP`/`WAIT` holding connections | Bound blocking timeouts; isolate blocking ops on a separate small pool |
| spikes during deploys | old + new pods both connected during rollout | Lower idle timeout; ensure graceful shutdown closes the client |

### Symptom 8 — `READONLY You can't write against a read only replica`

| Root cause | Fix |
|---|---|
| Client wrote to a replica/reader endpoint | Send writes to the **primary** endpoint; use the reader endpoint only for reads. In a cluster client, enable read-from-replica explicitly for reads only |
| After a failover, client still pinned to old primary (now replica) | Reconnect / refresh topology; ensure client uses the provider's primary endpoint DNS, which repoints on failover, not a node IP |

ElastiCache exposes separate **primary** and **reader** endpoints — confirm the app uses the
right one. Memorystore read replicas have a separate read endpoint. Redis Cloud abstracts this
behind one endpoint that always routes writes to the primary.

### Symptom 9 — Replication lag & failover surprises

```
redis-cli ... INFO replication   # role:master/slave, slaveN:...lag, master_link_status
```
- `master_link_status:down` on a replica → replica disconnected; check network/throttling.
- High `lag` → write throughput exceeds replication bandwidth; reduce write burst or scale.
- After failover, expect a brief window of `READONLY`/connection resets — clients must retry.
  Verify your client has retry-with-backoff (Symptom 7 client config) so failover is invisible.
- ElastiCache: enable **Multi-AZ with automatic failover**. Memorystore: **Standard tier** gives
  automatic failover; **Basic tier** does NOT (single node, downtime on failure).

### Symptom 10 — Module availability (RediSearch / RedisJSON / etc.)

`ERR unknown command 'FT.SEARCH'` / `ERR unknown command 'JSON.SET'`.

| Provider | Module reality |
|---|---|
| Redis Cloud / Enterprise | Modules (RediSearch, RedisJSON, RedisBloom, TimeSeries) are first-class — enable per DB |
| AWS ElastiCache | No general Redis modules on standard ElastiCache. **MemoryDB** has limited support; for search use OpenSearch or **ElastiCache Serverless** caveats — verify per region/version |
| GCP Memorystore | No third-party modules on Memorystore for Redis. Memorystore for Valkey / cluster has its own feature set — verify |

Fix: if you need RediSearch/JSON cross-provider, standardize on Redis Cloud, or implement the
capability another way (e.g. application-side indexing) on ElastiCache/Memorystore. Don't assume
a module exists — run `MODULE LIST` (where permitted) or check the provider docs for that tier.

### Symptom 11 — Persistence confusion (RDB / AOF) on managed offerings

- Managed Redis is often configured for **availability via replication + snapshots**, not the
  durability you'd hand-tune on self-managed (no fsync-every-write AOF guarantee by default).
- ElastiCache: backups = scheduled RDB snapshots to S3; no user-facing AOF on cluster mode.
- Memorystore: RDB snapshots (configurable interval) for Standard tier; AOF not user-exposed.
- Redis Cloud: choose persistence per DB (AOF every-write / every-sec, or snapshot).
- **Implication:** if you lose the node, you may lose seconds-to-minutes of writes. Treat managed
  Redis as a cache or a best-effort store unless you've explicitly configured durable persistence
  on a tier that supports it. For a system of record, write-through to a durable DB.

---

## Automation

### Provisioning — Terraform

Full, copy-pasteable resources for all three providers (ElastiCache cluster + RBAC + SG,
Memorystore Standard HA, Redis Cloud DB) live in `references/automation-templates.md §1`.
Non-negotiables for every provider:

- **ElastiCache:** `transit_encryption_enabled` is **immutable after create** — set it now.
  `automatic_failover_enabled = true` + `multi_az_enabled = true`; `maxmemory-policy` via a
  parameter group; RBAC via `aws_elasticache_user_group`.
- **Memorystore:** `tier = "STANDARD_HA"` (never `BASIC` for prod — no failover);
  `transit_encryption_mode = "SERVER_AUTHENTICATION"`; `auth_enabled = true`;
  `redis_configs = { maxmemory-policy = "allkeys-lru" }`.
- **Redis Cloud (`RedisLabs/rediscloud`):** `replication = true`, `enable_tls = true`,
  `data_eviction`, `data_persistence`, optional `modules` blocks.
- **Always:** `terraform plan` before apply; passwords from a secret store via data source,
  never hardcoded; `lifecycle { prevent_destroy = true }` on prod instances.

### Client config best practices (all providers)

```js
// ioredis — one shared instance, pooled, retry+backoff, sane timeouts
const redis = new Redis({
  host, port, username, password,
  tls: useTls ? { servername: host } : undefined,
  connectTimeout: 5000,
  maxRetriesPerRequest: 3,
  retryStrategy: (times) => Math.min(times * 200, 2000),   // backoff, capped
  enableReadyCheck: true,
  reconnectOnError: (err) => /READONLY/.test(err.message),  // reconnect after failover
});
```
```python
# redis-py — connection pool, health checks, retries
pool = redis.ConnectionPool(
    host=host, port=port, password=pw, ssl=use_tls,
    max_connections=50, socket_connect_timeout=5, socket_timeout=5,
    health_check_interval=30,
    retry=Retry(ExponentialBackoff(), retries=3),
)
client = redis.Redis(connection_pool=pool)
```
Rules: ONE client/pool per process (never per-request); set `connect`+`command` timeouts;
retry with capped exponential backoff; reconnect on `READONLY`; use the cluster client for
cluster endpoints; reuse TLS connections (handshake is expensive).

### Monitoring & alerting

| Metric (what it maps to) | Alert when | Provider source |
|---|---|---|
| Memory usage % (`used_memory`/`maxmemory`) | > 80% | CW `DatabaseMemoryUsagePercentage` / GCP `memory_usage_ratio` / Redis Cloud `used_memory` |
| Evictions (`evicted_keys`) | > 0 sustained (if a datastore) | CW `Evictions` / GCP `evicted_keys` |
| CPU / engine CPU | > 80% | CW `EngineCPUUtilization` / GCP `cpu_utilization` |
| Connections (`connected_clients`) | > 80% of `maxclients` | CW `CurrConnections` / GCP `connected_clients` |
| Cache hit rate | < 80% (cache workloads) | hits/(hits+misses) from `INFO stats` |
| Replication lag | > a few seconds | CW `ReplicationLag` / GCP `replication.role`+lag |
| Latency | p99 > SLO | CW `*Latency` / GCP `commands` latency |

```
# CloudWatch alarm: memory > 80%
aws cloudwatch put-metric-alarm --alarm-name redis-${ENV}-mem-high \
  --namespace AWS/ElastiCache --metric-name DatabaseMemoryUsagePercentage \
  --dimensions Name=ReplicationGroupId,Value=app-${ENV} \
  --statistic Average --period 60 --evaluation-periods 5 \
  --threshold 80 --comparison-operator GreaterThanThreshold \
  --alarm-actions ${SNS_TOPIC_ARN}
```

### Safe key scanning (NEVER `KEYS` on prod)

```bash
# Iterate matching keys without blocking — SCAN with cursor + COUNT
redis-cli -h "$HOST" -p "$PORT" ${TLS:+--tls} -a "$PW" --no-auth-warning \
  --scan --pattern 'session:*' --count 500 | head
```
```bash
# Idempotent, paced bulk delete with a dry-run guard
DRY_RUN=${DRY_RUN:-true}
redis-cli -h "$HOST" -p "$PORT" ${TLS:+--tls} -a "$PW" --no-auth-warning \
  --scan --pattern 'tmp:*' --count 500 | while read -r key; do
    if [ "$DRY_RUN" = "true" ]; then echo "WOULD DELETE $key";
    else redis-cli -h "$HOST" -p "$PORT" ${TLS:+--tls} -a "$PW" --no-auth-warning UNLINK "$key" >/dev/null; fi
  done
# Use UNLINK (async) over DEL for large values. Run with DRY_RUN=false only after reviewing output.
# In cluster mode add -c and run --scan per node (--scan hits one node).
```

### Backup / restore

```
aws elasticache create-snapshot --replication-group-id app-${ENV} --snapshot-name app-${ENV}-$(date +%F)
aws elasticache copy-snapshot --source-snapshot-name app-${ENV}-$(date +%F) \
  --target-snapshot-name app-${ENV}-export --target-bucket my-redis-backups   # AWS → S3
gcloud redis instances export gs://my-bucket/app-${ENV}.rdb <name> --region <region>   # GCP → GCS
gcloud redis instances import gs://my-bucket/app-${ENV}.rdb <name> --region <region>
# Redis Cloud: per-DB backup via console/API to your own S3/GCS bucket
```

### Automated failover testing (staging only)

```
aws elasticache test-failover --replication-group-id app-staging --node-group-id 0001
gcloud redis instances failover <name> --region <region> --data-protection-mode=limited-data-loss
```
Wrap in a script that triggers failover → polls the app health endpoint → asserts recovery under
a time budget. Clients with retry/backoff (above) see only a brief blip. Never run against prod
without a change window and rollback plan. Full script in `references/automation-templates.md §6`.

---

## Common gotchas

- **`redis://` to a TLS-required endpoint** → hangs/resets. Use `rediss://`. (#1 managed Redis bug.)
- **ElastiCache TLS is immutable after create.** Can't toggle `transit_encryption_enabled`; you
  recreate. Decide at provisioning time.
- **`CONFIG SET` is blocked/limited on managed Redis.** Change `maxmemory-policy` etc. via the
  parameter group (AWS) / `redis_configs` (GCP) / console (Redis Cloud), not `CONFIG SET`.
- **`KEYS *` in a health check** quietly murders prod latency as the keyspace grows. Use `SCAN`.
- **Non-cluster client on a clustered endpoint** → `MOVED`. The fix is the client, not the server.
- **Multi-key ops across slots** → `CROSSSLOT`. Use `{hashtag}` to co-locate related keys.
- **`new Redis()` per request** → connection leak → `max number of clients reached`. Share one pool.
- **`volatile-lru` policy with TTL-less keys** behaves like `noeviction` for those keys → OOM.
- **Writing to the reader/replica endpoint** → `READONLY`. Writes go to the primary endpoint only.
- **Memorystore Basic tier has no failover** — single node, real downtime. Use Standard tier for HA.
- **Assuming RediSearch/JSON exists** — it does NOT on standard ElastiCache/Memorystore. Verify.
- **Treating managed Redis as durable** — default config can lose recent writes on node loss.
- **Dialing the IP instead of the hostname** → SNI/cert mismatch + breaks after failover (IP changes).

---

## Quick reference

```
# Connect
redis-cli -h HOST -p PORT [--tls] [--user USER] -a PASS --no-auth-warning
redis-cli -c ...                 # cluster mode (follow MOVED/ASK redirects)
redis-cli -u rediss://:PASS@HOST:PORT          # URL form (rediss = TLS)

# Network / TLS proof
nc -vz HOST PORT
openssl s_client -connect HOST:PORT -servername HOST </dev/null

# Diagnose
INFO memory | replication | clients | stats | commandstats
SLOWLOG GET 25                   # slowest commands
--latency / --latency-history    # round-trip
--bigkeys                        # largest keys (SCAN-based)
MEMORY USAGE key                 # bytes of one key
CLIENT LIST                      # who's connected
ACL WHOAMI / ACL GETUSER user    # auth debugging
CLUSTER INFO / CLUSTER SLOTS / CLUSTER KEYSLOT "k{tag}"

# Safe iteration (never KEYS on prod)
--scan --pattern 'p:*' --count 500
SCAN cursor MATCH p:* COUNT 500
UNLINK key                       # async delete (prefer over DEL for big values)

# Errors → meaning
NOAUTH       auth required, none sent          → add password
WRONGPASS    bad pass / missing ACL username   → --user USER -a PASS
NOPERM       ACL forbids command               → widen ACL rule
OOM ...      maxmemory hit + noeviction         → eviction policy / scale / TTLs
MOVED        client not cluster-aware           → cluster client + config endpoint
CROSSSLOT    multi-key across slots             → {hashtag} to co-locate
READONLY     wrote to a replica                 → use primary endpoint
max clients  pool leak / maxclients             → shared pool, close conns
```

See `references/` for the full failure-mode catalog, the provider differences matrix, and the
client + IaC template library.
