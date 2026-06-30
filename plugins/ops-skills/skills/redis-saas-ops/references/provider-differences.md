# Provider differences — Redis Cloud vs ElastiCache vs Memorystore

The single source of "what's different" when a recommendation must change per provider. Verify
specifics against current provider docs/regions — capabilities evolve.

---

## At-a-glance matrix

| Capability | Redis Cloud (Enterprise) | AWS ElastiCache | GCP Memorystore for Redis |
|---|---|---|---|
| Reachability | public or private (VPC peering / PrivateLink) | VPC-internal only | VPC-internal only (private IP) |
| TLS in transit | per-DB toggle, can change | `transit_encryption_enabled` — **immutable after create** | `transit_encryption_mode` — set at create |
| TLS at rest | yes | `at_rest_encryption_enabled` | KMS, set at create |
| Auth | password and/or ACL/RBAC users | legacy AUTH token OR RBAC user groups | optional AUTH string |
| ACL / RBAC | full ACL, roles | RBAC via user groups | not exposed (AUTH string only) |
| Cluster sharding | OSS cluster API or Enterprise (proxy hides sharding) | "cluster mode enabled/disabled" | Cluster tier vs Basic/Standard |
| HA / failover | replication + auto failover | Multi-AZ + automatic failover (opt-in) | Standard tier = auto failover; Basic = none |
| Read replicas | yes | yes (reader endpoint) | yes (read replicas, separate read endpoint) |
| Modules (Search/JSON/Bloom/TS) | first-class, per DB | not on standard ElastiCache | not on Memorystore for Redis |
| Change `maxmemory-policy` | DB config (console/API) | parameter group | `redis_configs` on instance |
| Backups | per-DB to your S3/GCS, scheduled | RDB snapshots to S3 | RDB export/import to GCS |
| Persistence options | AOF (per-write / per-sec) or snapshot, per DB | snapshots; no user AOF on cluster mode | RDB snapshots (interval); no user AOF |
| Scaling | resize DB / shards | modify node type / shards (some online) | scale tier / memory (may restart) |
| Connect endpoint | single endpoint (proxy) | primary + reader endpoints (+ config endpoint in cluster mode) | host:port (+ read endpoint) |

---

## Connecting — exact commands

### Redis Cloud
```
# Public or private endpoint, often a non-6379 port, often TLS:
redis-cli -h redis-12345.c1.us-east-1-1.ec2.cloud.redislabs.com -p 12345 \
  --tls --user default -a "$REDIS_PW" PING
# URL form
redis-cli -u "rediss://default:$REDIS_PW@redis-12345.c1...redislabs.com:12345"
```
Allowlist your client's egress IP/CIDR in the DB "Source IP/Subnet" settings, or set up VPC
peering / PrivateLink for private connectivity.

### AWS ElastiCache (must be in-VPC — use a bastion/SSM/VPN)
```
# Get endpoints
aws elasticache describe-replication-groups --replication-group-id app-prod \
  --query "ReplicationGroups[0].[NodeGroups[0].PrimaryEndpoint, NodeGroups[0].ReaderEndpoint, ConfigurationEndpoint]"
# Connect (TLS on if transit encryption enabled; RBAC user if configured)
redis-cli -h <primary-endpoint> -p 6379 --tls --user appuser -a "$TOKEN" PING
```
- Cluster mode enabled → use the **configuration endpoint** + a cluster client.
- No public endpoint exists. From a laptop you need an SSM session / bastion / VPN inside the VPC.

### GCP Memorystore (must be in-VPC)
```
gcloud redis instances describe app-prod --region us-central1 \
  --format="value(host,port,readEndpoint,authEnabled,transitEncryptionMode)"
gcloud redis get-auth-string app-prod --region us-central1   # the AUTH token if authEnabled
redis-cli -h <host> -p 6379 ${TLS:+--tls} -a "$AUTH" PING
```
- Private IP only. Reach it from a Compute Engine VM, GKE pod, or via VPN in the authorized VPC.
- Basic tier = single node (no failover). Standard tier = HA with automatic failover.

---

## "It works on provider X but not Y" — the usual culprits

| Symptom moving providers | Why | Fix |
|---|---|---|
| RediSearch/JSON commands vanish | only Redis Cloud/Enterprise ships modules | re-architect or stay on Redis Cloud for those features |
| `CONFIG SET` rejected | managed locks runtime config | use parameter group / redis_configs / DB config |
| can't toggle TLS | ElastiCache transit encryption is immutable | recreate the cluster with TLS as desired |
| failover causes downtime | Memorystore Basic tier has no failover | move to Standard tier |
| public connect fails | AWS/GCP have no public endpoint | connect from inside the VPC |
| AUTH differs | ElastiCache RBAC needs username; Memorystore uses a single AUTH string | match the auth model per provider |
| different default ports | Redis Cloud assigns ports (e.g. 12345); AWS TLS often 6380 | always read the provider's actual host:port |

---

## Endpoint selection rules

- **Writes** → always the **primary** endpoint. Never the reader/replica (→ `READONLY`).
- **Reads that tolerate staleness** → reader endpoint (ElastiCache) / read endpoint (Memorystore)
  or read-from-replica in a cluster client.
- **Cluster mode** → the **configuration endpoint** with a cluster-aware client (never a node IP).
- **Always the hostname, never the IP** — IPs change on failover and break TLS SNI.
