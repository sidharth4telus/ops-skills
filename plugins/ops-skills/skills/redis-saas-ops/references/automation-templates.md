# Automation templates — managed Redis

Copy-pasteable IaC, client config, monitoring, and ops scripts. All idempotent / dry-run-first.

---

## 1. Terraform

### AWS ElastiCache — cluster-mode, TLS, RBAC, backups
```hcl
variable "env"    { type = string }
variable "region" { type = string }

resource "aws_elasticache_subnet_group" "this" {
  name       = "app-${var.env}"
  subnet_ids = var.private_subnet_ids
}

resource "aws_security_group" "redis" {
  name   = "app-${var.env}-redis"
  vpc_id = var.vpc_id
  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.client_sg_id]   # least-privilege: only the client SG
  }
  egress { from_port = 0 to_port = 0 protocol = "-1" cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_elasticache_parameter_group" "this" {
  family = "redis7"
  name   = "app-${var.env}"
  parameter { name = "maxmemory-policy" value = "allkeys-lru" }
}

resource "aws_elasticache_user" "app" {
  user_id       = "app-${var.env}"
  user_name     = "appuser"
  engine        = "REDIS"
  access_string = "on ~app:* +@read +@write +@connection"
  authentication_mode { type = "password" passwords = [var.redis_password] }
}
resource "aws_elasticache_user_group" "this" {
  user_group_id = "app-${var.env}"
  engine        = "REDIS"
  user_ids      = [aws_elasticache_user.app.user_id, "default"]
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "app-${var.env}"
  description                = "App cache ${var.env}"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = "cache.r7g.large"
  num_node_groups            = 3
  replicas_per_node_group    = 1
  automatic_failover_enabled = true
  multi_az_enabled           = true
  transit_encryption_enabled = true     # IMMUTABLE — set correctly now
  at_rest_encryption_enabled = true
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.redis.id]
  parameter_group_name       = aws_elasticache_parameter_group.this.name
  user_group_ids             = [aws_elasticache_user_group.this.id]
  snapshot_retention_limit   = 7
  snapshot_window            = "03:00-05:00"
  maintenance_window         = "sun:05:00-sun:07:00"
  apply_immediately          = false
  lifecycle { prevent_destroy = true }
}
output "primary_endpoint" { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
output "reader_endpoint"  { value = aws_elasticache_replication_group.redis.reader_endpoint_address }
```

### GCP Memorystore — Standard HA, TLS, AUTH, persistence
```hcl
resource "google_redis_instance" "redis" {
  name                    = "app-${var.env}"
  tier                    = "STANDARD_HA"      # never BASIC for prod (no failover)
  memory_size_gb          = 5
  region                  = var.region
  redis_version           = "REDIS_7_2"
  authorized_network      = var.vpc_self_link
  connect_mode            = "PRIVATE_SERVICE_ACCESS"
  auth_enabled            = true
  transit_encryption_mode = "SERVER_AUTHENTICATION"
  redis_configs           = { maxmemory-policy = "allkeys-lru" }
  persistence_config {
    persistence_mode    = "RDB"
    rdb_snapshot_period = "TWELVE_HOURS"
  }
  maintenance_policy {
    weekly_maintenance_window { day = "SUNDAY" start_time { hours = 5 } }
  }
  lifecycle { prevent_destroy = true }
}
output "host" { value = google_redis_instance.redis.host }
output "port" { value = google_redis_instance.redis.port }
```

### Redis Cloud — provider RedisLabs/rediscloud
```hcl
resource "rediscloud_subscription_database" "redis" {
  subscription_id    = rediscloud_subscription.this.id
  name               = "app-${var.env}"
  memory_limit_in_gb = 5
  data_persistence   = "aof-every-1-second"
  data_eviction      = "allkeys-lru"
  replication        = true
  enable_tls         = true
  password           = var.redis_password   # from a secret data source, not hardcoded
  modules { name = "RediSearch" }
  modules { name = "RedisJSON" }
}
output "endpoint" { value = rediscloud_subscription_database.redis.public_endpoint }
```

Workflow: `terraform fmt && terraform validate && terraform plan -out tf.plan` → review →
`terraform apply tf.plan`. Pin provider versions in `required_providers`.

---

## 2. Client config (production-grade)

### Node.js — ioredis (standalone)
```js
import Redis from "ioredis";
export const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: Number(process.env.REDIS_PORT ?? 6379),
  username: process.env.REDIS_USER,          // ACL/RBAC user, if any
  password: process.env.REDIS_PASSWORD,
  tls: process.env.REDIS_TLS === "true" ? { servername: process.env.REDIS_HOST } : undefined,
  connectTimeout: 5000,
  commandTimeout: 5000,
  maxRetriesPerRequest: 3,
  retryStrategy: (times) => Math.min(times * 200, 2000),
  reconnectOnError: (err) => /READONLY/.test(err.message),  // recover after failover
  enableReadyCheck: true,
  lazyConnect: false,
});
process.on("SIGTERM", () => redis.quit());   // graceful shutdown frees connections
```

### Node.js — ioredis (cluster)
```js
export const redis = new Redis.Cluster(
  [{ host: process.env.REDIS_HOST, port: Number(process.env.REDIS_PORT ?? 6379) }],
  {
    redisOptions: { username, password, tls: useTls ? {} : undefined, commandTimeout: 5000 },
    slotsRefreshTimeout: 2000,
    scaleReads: "slave",       // read from replicas; writes still go to primary
  }
);
```

### Python — redis-py with pool + retry
```python
import redis
from redis.retry import Retry
from redis.backoff import ExponentialBackoff

pool = redis.ConnectionPool(
    host=os.environ["REDIS_HOST"], port=int(os.environ.get("REDIS_PORT", 6379)),
    username=os.environ.get("REDIS_USER"), password=os.environ["REDIS_PASSWORD"],
    ssl=os.environ.get("REDIS_TLS") == "true", ssl_cert_reqs="required",
    max_connections=50, socket_connect_timeout=5, socket_timeout=5,
    health_check_interval=30,
    retry=Retry(ExponentialBackoff(cap=2, base=0.2), retries=3),
)
client = redis.Redis(connection_pool=pool)
# Cluster: redis.cluster.RedisCluster(host=cfg_endpoint, port=port, ssl=...)
```

---

## 3. Monitoring & alerting

### CloudWatch alarms (ElastiCache)
```bash
for spec in \
  "mem:DatabaseMemoryUsagePercentage:80:GreaterThanThreshold:Average" \
  "cpu:EngineCPUUtilization:80:GreaterThanThreshold:Average" \
  "conn:CurrConnections:50000:GreaterThanThreshold:Average" \
  "evict:Evictions:1000:GreaterThanThreshold:Sum"; do
  IFS=: read name metric thr op stat <<<"$spec"
  aws cloudwatch put-metric-alarm \
    --alarm-name "redis-${ENV}-${name}" \
    --namespace AWS/ElastiCache --metric-name "$metric" \
    --dimensions Name=ReplicationGroupId,Value="app-${ENV}" \
    --statistic "$stat" --period 60 --evaluation-periods 5 \
    --threshold "$thr" --comparison-operator "$op" \
    --alarm-actions "$SNS_TOPIC_ARN" --treat-missing-data notBreaching
done
```

### GCP Cloud Monitoring alert (memory ratio) via gcloud
```bash
gcloud alpha monitoring policies create \
  --display-name="redis-${ENV}-mem-high" \
  --condition-display-name="memory > 80%" \
  --condition-threshold-filter='resource.type="redis_instance" AND metric.type="redis.googleapis.com/stats/memory/usage_ratio"' \
  --condition-threshold-value=0.8 --condition-threshold-comparison=COMPARISON_GT \
  --condition-threshold-duration=300s \
  --notification-channels="$CHANNEL_ID"
```

**Alert on:** memory > 80%, evictions > 0 sustained (if datastore), CPU > 80%, connections >
80% of max, cache hit rate < 80% (cache workloads), replication lag > a few seconds, p99 latency
over SLO.

---

## 4. Safe SCAN-based key ops

```bash
#!/usr/bin/env bash
# scan-delete.sh — paced, idempotent, dry-run-by-default bulk delete
set -euo pipefail
: "${HOST:?}" "${PORT:=6379}" "${PATTERN:?}" "${DRY_RUN:=true}"
TLS_FLAG=""; [ "${TLS:-false}" = "true" ] && TLS_FLAG="--tls"
AUTH=(); [ -n "${PW:-}" ] && AUTH=(-a "$PW" --no-auth-warning)
[ -n "${USER:-}" ] && AUTH+=(--user "$USER")

count=0
while read -r key; do
  [ -z "$key" ] && continue
  if [ "$DRY_RUN" = "true" ]; then
    echo "WOULD UNLINK: $key"
  else
    redis-cli -h "$HOST" -p "$PORT" $TLS_FLAG "${AUTH[@]}" UNLINK "$key" >/dev/null
  fi
  count=$((count+1))
  (( count % 1000 == 0 )) && sleep 0.1     # pace to avoid latency spikes
done < <(redis-cli -h "$HOST" -p "$PORT" $TLS_FLAG "${AUTH[@]}" --scan --pattern "$PATTERN" --count 500)
echo "Processed $count keys (DRY_RUN=$DRY_RUN)"
# Cluster mode: --scan hits one node; loop over each shard's node endpoint.
```

---

## 5. Backup / restore

```bash
# ElastiCache — on-demand snapshot + export to S3
aws elasticache create-snapshot --replication-group-id "app-${ENV}" \
  --snapshot-name "app-${ENV}-$(date +%F)"
aws elasticache copy-snapshot --source-snapshot-name "app-${ENV}-$(date +%F)" \
  --target-snapshot-name "app-${ENV}-export-$(date +%F)" --target-bucket my-redis-backups

# Memorystore — export / import RDB via GCS
gcloud redis instances export "gs://my-bucket/app-${ENV}-$(date +%F).rdb" \
  "app-${ENV}" --region "$REGION"
gcloud redis instances import "gs://my-bucket/app-${ENV}-2026-01-01.rdb" \
  "app-${ENV}" --region "$REGION"

# Restore by creating a new ElastiCache cluster from a snapshot
aws elasticache create-replication-group --replication-group-id "app-${ENV}-restore" \
  --snapshot-name "app-${ENV}-2026-01-01" --replication-group-description "restore"
```

---

## 6. Automated failover test (staging)

```bash
#!/usr/bin/env bash
# failover-test.sh — trigger failover, assert app recovers within budget. STAGING ONLY.
set -euo pipefail
: "${RG:?}" "${HEALTH_URL:?}" "${BUDGET_SEC:=60}"

echo "Triggering failover on $RG ..."
aws elasticache test-failover --replication-group-id "$RG" --node-group-id 0001

deadline=$(( $(date +%s) + BUDGET_SEC ))
until curl -fsS "$HEALTH_URL" >/dev/null 2>&1; do
  [ "$(date +%s)" -ge "$deadline" ] && { echo "FAIL: app did not recover in ${BUDGET_SEC}s"; exit 1; }
  sleep 2
done
echo "PASS: app recovered after failover"
# Memorystore equivalent:
# gcloud redis instances failover "$INST" --region "$REGION" --data-protection-mode=limited-data-loss
```
Never run against production without a change window and a rollback plan.
