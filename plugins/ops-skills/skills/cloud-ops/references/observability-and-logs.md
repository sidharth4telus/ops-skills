# Observability, log queries, budgets & cross-cloud IaC

A library of copy-pasteable log queries (CloudWatch Logs Insights + Cloud Logging), a polling
wrapper for the async CloudWatch query API, budget/alert recipes, and the cross-cloud Terraform
pattern. All read-only or guarded.

## CloudWatch Logs Insights — query library

Run pattern:
```bash
qid=$(aws logs start-query --log-group-name /aws/lambda/my-fn \
  --start-time $(date -d '1 hour ago' +%s) --end-time $(date +%s) \
  --query-string '<QUERY>' --query queryId --output text)
# poll until Complete
until [ "$(aws logs get-query-results --query-id "$qid" --query status --output text)" = "Complete" ]; do sleep 1; done
aws logs get-query-results --query-id "$qid" --query 'results' --output table
```

Queries:
```
# Error rate over time (5-min buckets)
fields @timestamp | filter @message like /ERROR|Exception|Traceback/
| stats count(*) as errors by bin(5m)

# Top error messages
filter @message like /ERROR/ | parse @message /(?<msg>ERROR.*)/ 
| stats count(*) as n by msg | sort n desc | limit 20

# p50/p90/p99 latency from Lambda REPORT lines
filter @type = "REPORT"
| stats avg(@duration), pct(@duration,50), pct(@duration,90), pct(@duration,99), max(@duration) by bin(5m)

# Cold starts
filter @type="REPORT" and ispresent(@initDuration)
| stats count(*) as coldstarts, avg(@initDuration) by bin(15m)

# Throttling / 5xx by requestId
filter @message like /Throttl|Rate exceeded|status.?5\d\d/ 
| fields @timestamp, @requestId, @message | sort @timestamp desc | limit 50

# Find IAM denials in app logs
filter @message like /AccessDenied|not authorized|PERMISSION_DENIED/ 
| stats count(*) as denials by bin(1h)
```

## Cloud Logging — query library

```bash
gcloud logging read '<FILTER>' --freshness=1h --limit=50 --format='table(timestamp,severity,resource.labels.service_name,textPayload)'
```
Filters:
```
# All 5xx from Cloud Run
resource.type="cloud_run_revision" AND httpRequest.status>=500

# Errors with stack traces
severity>=ERROR AND (textPayload:"Traceback" OR jsonPayload.stack_trace:*)

# IAM denials (audit logs)
protoPayload.status.code=7 AND protoPayload.@type="type.googleapis.com/google.cloud.audit.AuditLog"

# Throttling / quota
jsonPayload.message:("RESOURCE_EXHAUSTED" OR "Quota exceeded" OR "rateLimitExceeded")

# Slow requests (>1s)
resource.type="cloud_run_revision" AND httpRequest.latency>"1s"
```
Aggregate / count over a window via the Logging API or export to BigQuery:
```bash
gcloud logging read 'severity>=ERROR' --freshness=1h --format='value(resource.labels.service_name)' | sort | uniq -c | sort -rn
```

## Metric alarms (alert before users notice)

```bash
# AWS — alarm on Lambda errors
aws cloudwatch put-metric-alarm --alarm-name my-fn-errors \
  --namespace AWS/Lambda --metric-name Errors --dimensions Name=FunctionName,Value=my-fn \
  --statistic Sum --period 60 --evaluation-periods 5 --threshold 5 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching \
  --alarm-actions arn:aws:sns:ca-central-1:123:oncall

# GCP — alert policy on Cloud Run 5xx (via gcloud, condition from a file)
gcloud alpha monitoring policies create --policy-from-file=policy.json
```

## Budget alerts

```bash
# AWS — see SKILL.md A5; add an SNS subscriber for automation instead of email:
aws budgets create-notification --account-id 123456789012 --budget-name monthly-all \
  --notification '{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":90,"ThresholdType":"PERCENTAGE"}' \
  --subscribers '[{"SubscriptionType":"SNS","Address":"arn:aws:sns:ca-central-1:123:billing-alerts"}]'

# GCP — budget with Pub/Sub for programmatic response (e.g. auto-throttle)
gcloud billing budgets create --billing-account=XXXXXX-XXXXXX-XXXXXX \
  --display-name=monthly --budget-amount=1000USD \
  --threshold-rule=percent=0.9 \
  --notifications-rule-pubsub-topic=projects/PROJECT/topics/budget-alerts
```

## Cost-spike drill-down recipes

```bash
# AWS — by USAGE_TYPE for a single service (find WHY a service jumped)
aws ce get-cost-and-usage --time-period Start=$(date -d '14 days ago' +%F),End=$(date +%F) \
  --granularity DAILY --metrics UnblendedCost \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["EC2 - Other"]}}' \
  --group-by Type=DIMENSION,Key=USAGE_TYPE

# AWS — by tag (who owns the spike)
aws ce get-cost-and-usage --time-period Start=$(date -d '7 days ago' +%F),End=$(date +%F) \
  --granularity DAILY --metrics UnblendedCost --group-by Type=TAG,Key=Owner
```
Usual suspects: `NatGateway-Bytes` (data processing), `DataTransfer-Regional-Bytes` (cross-AZ),
idle large/GPU instances, S3/GCS request volume from a hot loop, runaway autoscaling, untagged dev.

## Cross-cloud Terraform (IaC) pattern

`terraform plan` is the universal idempotent dry-run for both clouds. Multi-provider skeleton:

```hcl
terraform {
  required_providers {
    aws    = { source = "hashicorp/aws",    version = "~> 5.0" }
    google = { source = "hashicorp/google", version = "~> 5.0" }
  }
  backend "s3" {                      # or "gcs" — keep state per cloud
    bucket = "tf-state-prod"
    key    = "cross-cloud/terraform.tfstate"
    region = "ca-central-1"
  }
}

provider "aws"    { region = var.aws_region }
provider "google" { project = var.gcp_project, region = var.gcp_region }

# Example: an S3 bucket and a GCS bucket, both hardened, in one apply
resource "aws_s3_bucket" "artifacts" { bucket = "my-app-artifacts" }
resource "aws_s3_bucket_versioning" "v" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_public_access_block" "pab" {
  bucket = aws_s3_bucket.artifacts.id
  block_public_acls = true; block_public_policy = true
  ignore_public_acls = true; restrict_public_buckets = true
}

resource "google_storage_bucket" "artifacts" {
  name                        = "my-app-artifacts-gcp"
  location                    = "NORTHAMERICA-NORTHEAST1"
  uniform_bucket_level_access = true
  versioning { enabled = true }
}
```

Operating rules:
- **`terraform plan -out tfplan` then `apply tfplan`** — review the diff before mutating. Never `apply -auto-approve` interactively in prod.
- **Least-privilege provider creds:** the AWS principal and GCP service account Terraform runs as should hold only what the config touches — not admin.
- **State is sensitive** (it can contain secrets): encrypt the backend bucket, restrict access, never commit `*.tfstate`.
- **Drift:** `terraform plan` with no code change should show "No changes." Anything else = out-of-band edit; reconcile in code, don't click-fix.
- **Imports for existing resources:** `terraform import aws_s3_bucket.artifacts my-app-artifacts` / `terraform import google_storage_bucket.artifacts my-app-artifacts-gcp` before managing them.
