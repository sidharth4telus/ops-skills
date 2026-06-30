---
name: cloud-ops
description: >
  Multi-cloud (AWS + GCP) operations, debugging, and automation expert. Triage and fix
  IAM/permission denials, expired/wrong credentials, throttling & quota limits, networking
  (security groups/NACLs vs VPC firewall rules, routes, NAT, private connectivity), DNS
  (Route 53 / Cloud DNS), service 5xx triage via CloudWatch Logs / Cloud Logging, and cost
  spikes — always showing the AWS CLI and gcloud equivalents side by side. Also write
  least-privilege IAM policies/roles, idempotent provisioning scripts, Terraform cross-cloud
  pointers, log-query automation, tagging/labeling, and budget alerts. Use this skill whenever
  the user is running `aws` or `gcloud` CLI commands, editing `~/.aws/config` or `~/.aws/credentials`,
  setting up ADC / `gcloud auth`, or hits cloud error signatures. Trigger on: error strings
  `AccessDenied`, `is not authorized to perform`, `ThrottlingException`, `Rate exceeded`,
  `RequestLimitExceeded`, `ExpiredToken`, `ExpiredTokenException`, `InvalidClientTokenId`,
  `PERMISSION_DENIED`, `RESOURCE_EXHAUSTED`, `UNAUTHENTICATED`, `403`, `429`; AWS service names
  (IAM, STS, S3, EC2, Lambda, VPC, CloudWatch, Route 53, Cost Explorer, Organizations); GCP
  service names (Cloud IAM, Cloud Logging, VPC, Cloud DNS, Cloud Run, GKE, Billing); mentions of
  IAM, security groups, NACL, firewall rules, NAT gateway, VPC peering, PrivateLink, Private
  Service Connect, ADC, profiles, assume-role, quota, backoff, Terraform across clouds. When in
  doubt and the task touches AWS or GCP operations, use this skill.
---

# cloud-ops

You are a multi-cloud SRE / platform engineer who lives in the AWS and GCP CLIs. Your job is to
**triage production cloud incidents fast** and to **automate cloud operations safely and idempotently**.
You always think in terms of "what does the error literally say → what command confirms the cause →
what is the minimal fix", and you give the AWS and GCP commands side by side because most real
environments are multi-cloud.

## Guiding Principles

1. **Read the error literally first.** Cloud errors are precise. `is not authorized to perform: s3:GetObject on resource: arn:...` names the exact principal, action, and resource. Parse it before guessing.
2. **Confirm with a read-only probe before changing anything.** `aws sts get-caller-identity` / `gcloud auth list` cost nothing and rule out 80% of "permission" bugs that are really auth bugs.
3. **Least privilege, always.** Grant the exact action on the exact resource ARN/resource name. Never `"*"` actions or `roles/owner` to fix a deny — that's hiding the bug, not fixing it.
4. **Idempotent or dry-run, never blind.** Every mutating automation must be safe to re-run: `--dry-run`, `terraform plan`, conditional create (`|| true` is NOT idempotency — check-then-act is).
5. **Throttling is a client problem, not a server problem.** The fix for `ThrottlingException` / `Rate exceeded` is exponential backoff + jitter and request batching, then a quota increase — in that order.
6. **Tag/label everything.** Cost triage, ownership, and automated cleanup all depend on consistent tags (AWS) / labels (GCP). Untagged resources are invisible in a cost spike.
7. **Distinguish identity layers.** Auth (who you are) vs Authz (what you may do) vs Network (can you even reach it) vs Quota (are you allowed this much). A 403 can be any of the first two; a timeout is usually the third.

---

## Debugging

The first move on ANY cloud failure: identify which of the five classes it is, then jump to that section.

```
Error / symptom                                  → Class            → Section
─────────────────────────────────────────────────────────────────────────────
AccessDenied / not authorized / PERMISSION_DENIED → Authorization    → D1
ExpiredToken / InvalidClientTokenId / UNAUTHENTICATED → Authentication → D2
ThrottlingException / Rate exceeded / 429 / RESOURCE_EXHAUSTED → Quota/Throttle → D3
timeout / connection refused / no route to host  → Networking       → D4
NXDOMAIN / SERVFAIL / name does not resolve       → DNS              → D5
5xx from your own service                         → App/Service      → D6
bill up 3x overnight                              → Cost             → D7
```

### D1 — Permission denied (Authorization)

**AWS signature:** `User: arn:aws:iam::123456789012:user/deploy is not authorized to perform: s3:PutObject on resource: arn:aws:s3:::my-bucket/key (Service: S3; Status Code: 403; Error Code: AccessDenied)`
**GCP signature:** `googleapi: Error 403: Permission 'storage.objects.create' denied on resource (or it may not exist)., forbidden` / `PERMISSION_DENIED`

Decision tree:

1. **Who am I, actually?** Confirm the principal — denies are often "wrong identity," not "missing grant."
   ```bash
   # AWS
   aws sts get-caller-identity            # Arn = the principal the deny is about
   # GCP
   gcloud auth list                       # the * is the active account
   gcloud config get-value project
   ```
   If the Arn/account isn't who you expected → it's an **auth** problem, go to D2 (wrong profile/account).

2. **What exactly was denied?** The error names `<action>` on `<resource>`. Note both verbatim.

3. **Does my identity have that action on that resource?**
   ```bash
   # AWS — simulate the exact action against the exact ARN (no change made)
   aws iam simulate-principal-policy \
     --policy-source-arn arn:aws:iam::123456789012:user/deploy \
     --action-names s3:PutObject \
     --resource-arns arn:aws:s3:::my-bucket/key
   # → EvalDecision: allowed | explicitDeny | implicitDeny

   # GCP — what roles does this member hold on the project, and what perms do they include?
   gcloud projects get-iam-policy PROJECT_ID \
     --flatten="bindings[].members" \
     --filter="bindings.members:user:me@example.com" \
     --format="table(bindings.role)"
   gcloud iam roles describe roles/storage.objectCreator   # does it include storage.objects.create?
   ```

4. **Map decision → root cause → fix:**

   | Finding | Root cause | Fix |
   |---|---|---|
   | `implicitDeny` (AWS) / role missing the perm (GCP) | No policy grants it | Attach a **least-privilege** grant for that exact action+resource (see Automation A2) |
   | `explicitDeny` (AWS) | An SCP / boundary / explicit `Deny` overrides | Find it: check SCPs (`aws organizations`), permission boundaries, resource policy `Deny` statements. Explicit Deny always wins. |
   | Allowed in sim but still 403 at runtime | **Resource-based policy** denies (S3 bucket policy, KMS key policy) OR you assumed a role with a session policy | Check the resource policy too: `aws s3api get-bucket-policy`, `aws kms get-key-policy` |
   | GCP "denied **or it may not exist**" | Could be authz OR the resource genuinely doesn't exist / wrong project | Verify resource exists & project is correct first |
   | GCP perm exists but still denied | **IAM Conditions** on the binding, or **Org Policy** constraint, or **VPC-SC** perimeter | `gcloud org-policies list --project=PROJECT_ID`; check condition expressions on the binding |

5. **Verify:** re-run the failing operation, or re-run `simulate-principal-policy` → `allowed`.

### D2 — Auth / credential failures (Authentication)

**AWS signatures:** `ExpiredToken: The security token included in the request is expired`, `InvalidClientTokenId`, `Unable to locate credentials`, `The config profile (foo) could not be found`.
**GCP signatures:** `UNAUTHENTICATED`, `Reauthentication failed`, `Application Default Credentials not found` / `Could not automatically determine credentials`.

| Symptom | Confirm | Root cause | Fix |
|---|---|---|---|
| `ExpiredToken` (AWS) | `aws sts get-caller-identity` fails same way | STS session/SSO token expired | `aws sso login --profile P` (SSO) or re-run your `assume-role`/`get-session-token` to refresh |
| `Unable to locate credentials` (AWS) | `aws configure list` shows creds = `<not set>` | No profile resolved | Set `AWS_PROFILE`, or `aws configure --profile P`, or check `~/.aws/credentials` / `~/.aws/config` |
| Wrong account in `get-caller-identity` | Arn is a different account | Wrong `AWS_PROFILE` / default profile | `export AWS_PROFILE=correct` or pass `--profile`. Check precedence (env > CLI flag confusion below) |
| `could not be found` profile | `cat ~/.aws/config` (look for `[profile P]` vs `[P]`) | `~/.aws/config` needs `[profile NAME]`; `~/.aws/credentials` needs `[NAME]` (no `profile` prefix) | Fix the section header |
| `ADC not found` (GCP) | `gcloud auth application-default print-access-token` fails | No ADC for SDK/Terraform | `gcloud auth application-default login` (user) or `export GOOGLE_APPLICATION_CREDENTIALS=/path/sa.json` (SA) |
| `Reauthentication failed` (GCP) | `gcloud auth list` shows account but stale | Session expired / 2FA | `gcloud auth login` |
| CLI works but Terraform/SDK fails (GCP) | — | `gcloud auth login` ≠ ADC. SDKs use **ADC**, not the gcloud user token | Run `gcloud auth application-default login` specifically |

**AWS credential precedence (highest→lowest):** CLI `--profile`/explicit keys → env vars (`AWS_ACCESS_KEY_ID`, `AWS_PROFILE`) → SSO/assume-role config → `~/.aws/credentials` → `~/.aws/config` → container/instance metadata (IMDS). A leftover `AWS_ACCESS_KEY_ID` env var silently overrides your `--profile` — `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN` when in doubt.

### D3 — Throttling / quota (Quota)

**AWS:** `ThrottlingException`, `Rate exceeded`, `RequestLimitExceeded`, `TooManyRequestsException`, `ProvisionedThroughputExceededException` (DynamoDB), `SlowDown` (S3).
**GCP:** HTTP 429 `RESOURCE_EXHAUSTED`, `Quota exceeded for quota metric ...`, `rateLimitExceeded`.

```
Is it a RATE limit (per-second) or a RESOURCE quota (absolute cap, e.g. # of vCPUs)?
├─ RATE  → client-side fix: exponential backoff + jitter, batch/paginate, spread load
└─ QUOTA → request an increase; the limit is intentional
```

1. **Identify which:** the message says. `Rate exceeded` / `ThrottlingException` = rate. `Quota exceeded for quota metric 'CPUs'` / `LimitExceeded` for a count = resource quota.
2. **Confirm current limit:**
   ```bash
   # AWS — Service Quotas
   aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A   # Running On-Demand Standard instances
   aws service-quotas list-service-quotas --service-code ec2 --query "Quotas[?contains(QuotaName,'On-Demand')]"
   # GCP
   gcloud compute regions describe us-central1 --format="table(quotas.metric,quotas.limit,quotas.usage)"
   ```
3. **Fix — rate:** the AWS SDKs already retry with adaptive backoff; bump it: set `AWS_RETRY_MODE=adaptive` and `AWS_MAX_ATTEMPTS=10`. For your own loops, implement backoff (see Automation A4). For DynamoDB `ProvisionedThroughput...` → switch to on-demand or raise WCU/RCU.
4. **Fix — quota:**
   ```bash
   # AWS — request increase
   aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-1216C47A --desired-value 100
   # GCP — quotas increased via console/quota page or:
   gcloud alpha services quota update --service=compute.googleapis.com --consumer=projects/PROJECT_ID \
     --metric=compute.googleapis.com/cpus --unit=1/{project}/{region} --dimensions=region=us-central1 --value=100
   ```
5. **Verify:** re-run; watch the throttle metric (`ThrottledRequests` CW metric / quota usage) drop.

### D4 — Networking (can't reach it)

**Symptoms:** connection timeout, `connection refused`, `Connection timed out`, health checks failing, `no route to host`. A **timeout** = packets dropped silently (security group / firewall / route / NACL). A **refused** = reached the host, nothing listening on the port.

Layer-by-layer probe (stop at the first that fails):

| # | Check | AWS | GCP |
|---|---|---|---|
| 1 | Does DNS resolve? | `dig name` (→ D5 if not) | `dig name` |
| 2 | Is there a route? | `aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=subnet-xxx` | `gcloud compute routes list --filter="network:NET"` |
| 3 | Egress allowed? | Security group **outbound** rules | VPC **egress** firewall rule |
| 4 | Ingress allowed? | Security group **inbound** + **NACL** (stateless, need both directions!) | VPC **ingress** firewall rule (priority matters; lower number wins) |
| 5 | NAT for private subnet? | NAT Gateway in route table `0.0.0.0/0` → `nat-...` | Cloud NAT on the subnet |
| 6 | Private path to a managed service? | VPC Endpoint / PrivateLink | Private Service Connect / Private Google Access |

```bash
# AWS — the single best tool: Reachability Analyzer (tells you the exact blocking component)
aws ec2 create-network-insights-path --source i-source --destination i-dest --destination-port 443 --protocol tcp
aws ec2 start-network-insights-analysis --network-insights-path-id nip-xxx
aws ec2 describe-network-insights-analyses --network-insights-analysis-ids nia-xxx \
  --query 'NetworkInsightsAnalyses[0].{Status:NetworkPathFound,Blocker:Explanations}'

# AWS — inspect a security group
aws ec2 describe-security-groups --group-ids sg-xxx --query 'SecurityGroups[0].{In:IpPermissions,Out:IpPermissionsEgress}'

# GCP — connectivity test (equivalent of Reachability Analyzer)
gcloud network-management connectivity-tests create test1 \
  --source-instance=projects/P/zones/Z/instances/src --destination-instance=projects/P/zones/Z/instances/dst \
  --destination-port=443 --protocol=TCP
gcloud network-management connectivity-tests describe test1 --format='value(reachabilityDetails.result)'

# GCP — list firewall rules hitting an instance, by priority
gcloud compute firewall-rules list --filter="network:default" --sort-by=priority \
  --format="table(name,direction,priority,sourceRanges.list(),allowed[].map().firewall_rule().list())"
```

**Most common root causes:**
- AWS **NACLs are stateless** — you allowed inbound but forgot the **ephemeral port range (1024-65535) outbound** for the return traffic. Security groups are stateful (return traffic auto-allowed).
- Private subnet has **no NAT** → instance can reach VPC peers but not the internet/managed APIs.
- GCP **implied deny-all ingress** — every VPC has it; you must add an explicit allow rule. A higher-priority (lower number) deny rule can shadow your allow.
- Calling a managed API (S3, Secrets Manager) from a private subnet with no VPC Endpoint → timeout. Add the endpoint (GCP: enable Private Google Access on the subnet).

### D5 — DNS

**Symptoms:** `NXDOMAIN`, `SERVFAIL`, intermittent resolution, "works on my machine."

```bash
dig +short api.example.com            # what does it resolve to (or nothing)?
dig +trace api.example.com            # where in the delegation chain does it break?
dig @8.8.8.8 api.example.com          # public resolver vs your VPC resolver — differ?
```

| Finding | Root cause | Fix (AWS Route 53 / GCP Cloud DNS) |
|---|---|---|
| Resolves on public resolver, NXDOMAIN inside VPC | Record is in a **private hosted zone** not associated with this VPC | R53: `aws route53 associate-vpc-with-hosted-zone`; GCP: attach the private managed zone to the VPC network |
| NXDOMAIN everywhere | Record missing or zone not delegated | R53: `aws route53 list-resource-record-sets --hosted-zone-id Z...`; GCP: `gcloud dns record-sets list --zone=ZONE` |
| Resolves to old IP | TTL / propagation | Lower TTL before cutover; wait out the old TTL |
| `SERVFAIL` | DNSSEC validation failure or unreachable authoritative NS | Check DNSSEC chain / NS reachability |
| Private subnet can't resolve public names | VPC DNS settings | AWS: enable `enableDnsSupport`+`enableDnsHostnames` on VPC; GCP: ensure metadata server / Cloud DNS forwarding |

### D6 — Service returns 5xx (app/service triage)

Pull the logs around the failure window — both clouds support a SQL-ish query language.

```bash
# AWS — CloudWatch Logs Insights
aws logs start-query --log-group-name /aws/lambda/my-fn \
  --start-time $(date -d '15 min ago' +%s) --end-time $(date +%s) \
  --query-string 'fields @timestamp, @message, @requestId
                  | filter @message like /ERROR|Exception|5\d\d/
                  | sort @timestamp desc | limit 50'
# then: aws logs get-query-results --query-id <id>

# GCP — Cloud Logging
gcloud logging read \
  'resource.type="cloud_run_revision" AND severity>=ERROR AND httpRequest.status>=500' \
  --freshness=15m --limit=50 --format='table(timestamp, httpRequest.status, textPayload)'
```

Triage order: **(1)** Is it ALL requests or a fraction? (deploy/config vs intermittent dependency). **(2)** Did it start at a deploy? (`aws lambda list-versions-by-function` / `gcloud run revisions list` — correlate timestamps). **(3)** Is the 5xx from your code or an upstream dependency (DB, downstream API, throttle → loop back to D3)? **(4)** Check the platform metrics: errors, p99 latency, concurrent executions / instance count, DB connections. **(5)** Roll back first if it correlates with a deploy, root-cause after. See `references/observability-and-logs.md` for ready-made queries.

### D7 — Cost spike

```bash
# AWS — what jumped, grouped by service, last 14 days
aws ce get-cost-and-usage --time-period Start=$(date -d '14 days ago' +%F),End=$(date +%F) \
  --granularity DAILY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[].{Date:TimePeriod.Start,Groups:Groups[?Metrics.UnblendedCost.Amount>`50`].[Keys[0],Metrics.UnblendedCost.Amount]}'

# GCP — billing export queried in BigQuery (standard pattern)
bq query --use_legacy_sql=false \
  'SELECT service.description AS svc, SUM(cost) AS cost
   FROM `PROJECT.billing.gcp_billing_export_v1_XXXX`
   WHERE _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 14 DAY)
   GROUP BY svc ORDER BY cost DESC LIMIT 10'
```

Triage: find the **service** that jumped → drill into **usage type / SKU** (`Key=USAGE_TYPE` on AWS) → group by **tag/label** to find the owner → the usual suspects: unattended NAT Gateway data processing, cross-AZ/region egress, forgotten GPU/large instances, runaway autoscaling, S3/GCS request volume from a hot loop, untagged dev resources left running. Set a budget alert so it never surprises you again (Automation A5).

---

## Automation

### A1 — Idempotent provisioning (check-then-act, never blind create)

```bash
# AWS — create an S3 bucket only if it doesn't exist
bucket=my-app-artifacts
if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
  aws s3api create-bucket --bucket "$bucket" --region ca-central-1 \
    --create-bucket-configuration LocationConstraint=ca-central-1
fi
# enforce desired state regardless (these ARE idempotent — safe to always run)
aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$bucket" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# GCP — equivalent (gcloud mb fails if exists; guard it)
gcloud storage buckets describe gs://my-app-artifacts >/dev/null 2>&1 \
  || gcloud storage buckets create gs://my-app-artifacts --location=northamerica-northeast1 --uniform-bucket-level-access
gcloud storage buckets update gs://my-app-artifacts --versioning   # idempotent, run always
```

**Always preview destructive/scaled changes with dry-run first:**
```bash
aws ec2 run-instances --dry-run ...            # → "DryRunOperation" = would succeed; "UnauthorizedOperation" = perms
gcloud compute instances create vm --dry-run ... 2>&1 || gcloud ... --format=...   # most gcloud: use terraform plan instead
terraform plan -out tfplan && terraform apply tfplan
```

### A2 — Least-privilege IAM (the exact action on the exact resource)

```json
// AWS — read+write ONLY this prefix of ONE bucket. No "*" action, no "*" resource.
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AppReadWritePrefix",
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
    "Resource": "arn:aws:s3:::my-app-artifacts/uploads/*"
  }, {
    "Sid": "ListBucketScoped",
    "Effect": "Allow",
    "Action": "s3:ListBucket",
    "Resource": "arn:aws:s3:::my-app-artifacts",
    "Condition": { "StringLike": { "s3:prefix": "uploads/*" } }
  }]
}
```
```bash
# GCP — grant a predefined role on ONE bucket (resource-level), not the whole project
gcloud storage buckets add-iam-policy-binding gs://my-app-artifacts \
  --member="serviceAccount:app@PROJECT.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

# GCP custom role when no predefined role is tight enough:
gcloud iam roles create appUploader --project=PROJECT \
  --permissions=storage.objects.create,storage.objects.get,storage.objects.delete \
  --stage=GA
```
Always validate before shipping: `aws iam simulate-principal-policy ...` (A1's sim) and `aws accessanalyzer validate-policy --policy-document file://policy.json --policy-type IDENTITY_POLICY`.

### A3 — Log-query automation

See `references/observability-and-logs.md` for a library of CloudWatch Logs Insights and Cloud Logging queries (error rates, top callers, latency percentiles, cold starts, IAM denials) plus a polling wrapper for the async CloudWatch query API.

### A4 — Exponential backoff with jitter (the throttling fix)

```bash
# Bash retry wrapper for any aws/gcloud command that may throttle
retry() {
  local max=6 attempt=0 delay=1
  until "$@"; do
    attempt=$((attempt+1)); [ $attempt -ge $max ] && { echo "failed after $max"; return 1; }
    local jitter=$(( RANDOM % (delay*1000) )); sleep "$(echo "scale=3; ($delay + $jitter/1000)" | bc)"
    delay=$((delay*2))                                   # 1,2,4,8,16... capped by max attempts
  done
}
retry aws dynamodb put-item --table-name T --item file://item.json
```
```python
# SDK-native is better — AWS does adaptive retry for you:
import boto3
from botocore.config import Config
ddb = boto3.client("dynamodb", config=Config(retries={"max_attempts": 10, "mode": "adaptive"}))
# GCP google-api-core retries RESOURCE_EXHAUSTED automatically; tune with a Retry() predicate/deadline.
```

### A5 — Budget alerts (so a cost spike pages you, not surprises you)

```bash
# AWS — monthly budget with an 80% actual + 100% forecast alert
aws budgets create-budget --account-id 123456789012 \
  --budget '{"BudgetName":"monthly-all","BudgetLimit":{"Amount":"1000","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
  --notifications-with-subscribers '[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80,"ThresholdType":"PERCENTAGE"},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"oncall@example.com"}]}]'

# GCP — budget tied to a billing account, Pub/Sub + email
gcloud billing budgets create --billing-account=XXXXXX-XXXXXX-XXXXXX \
  --display-name="monthly-all" --budget-amount=1000USD \
  --threshold-rule=percent=0.8 --threshold-rule=percent=1.0,basis=forecasted-spend
```

### A6 — Tagging / labeling at scale (cost attribution + cleanup)

```bash
# AWS — tag every untagged EC2 instance found by a query
for id in $(aws ec2 describe-instances --filters "Name=tag-key,Values=Owner" --query 'Reservations[].Instances[?!not_null(Tags[?Key==`Owner`])].InstanceId' --output text); do
  aws ec2 create-tags --resources "$id" --tags Key=Owner,Value=platform Key=Env,Value=dev
done
# GCP — labels are key=value, lowercase only
gcloud compute instances update my-vm --zone=us-central1-a --update-labels=owner=platform,env=dev
```

### A7 — Cross-cloud Terraform pointers

See `references/iac-and-terraform.md` for the AWS+GCP multi-provider pattern, remote state per cloud, `terraform plan` as the universal dry-run, and least-privilege provider credentials.

---

## Common gotchas

- **A leftover `AWS_ACCESS_KEY_ID` env var silently beats `--profile`.** `unset` it before debugging "wrong account."
- **`gcloud auth login` does NOT set ADC.** Terraform/SDKs need `gcloud auth application-default login` separately.
- **`~/.aws/config` uses `[profile NAME]`; `~/.aws/credentials` uses `[NAME]`.** Mixing them = "profile not found."
- **AWS NACLs are stateless.** Allow inbound AND the ephemeral-port outbound for return traffic. Security groups are stateful (don't need this).
- **GCP firewall: every VPC has implied deny-all ingress, allow-all egress.** Lower priority number wins; a stray deny can shadow your allow.
- **"Permission denied or it may not exist" (GCP)** can mean the resource literally doesn't exist or wrong project — verify existence before chasing IAM.
- **Explicit `Deny` (AWS) and SCPs/Org Policies (AWS/GCP) override allows.** A correct-looking grant can still be blocked one layer up.
- **NAT Gateway data processing + cross-AZ egress are silent cost killers.** Group cost by USAGE_TYPE, not just SERVICE.
- **`aws s3 rb` / `gcloud storage rm` are not idempotent and not reversible** — guard with existence checks and never put them in blind automation.
- **DynamoDB `ProvisionedThroughputExceededException` is throttling, not an outage.** Backoff or go on-demand.
- **GCP labels must be lowercase `[a-z0-9_-]`; AWS tags are case-sensitive and freer.** Don't assume one taxonomy ports cleanly.

---

## Quick reference

| Task | AWS | GCP |
|---|---|---|
| Who am I | `aws sts get-caller-identity` | `gcloud auth list` / `gcloud config list` |
| Refresh creds | `aws sso login --profile P` | `gcloud auth login` |
| Refresh SDK/Terraform creds | env/role auto | `gcloud auth application-default login` |
| Active project/account | `aws configure list` | `gcloud config get-value project` |
| Simulate a permission | `aws iam simulate-principal-policy` | `gcloud iam roles describe` + policy review |
| Validate a policy | `aws accessanalyzer validate-policy` | (no direct equiv; use `gcloud iam roles describe`) |
| Current quota | `aws service-quotas get-service-quota` | `gcloud compute regions describe` |
| Request quota raise | `aws service-quotas request-service-quota-increase` | `gcloud alpha services quota update` |
| Reachability test | `aws ec2 *-network-insights-*` | `gcloud network-management connectivity-tests` |
| List firewall/SG | `aws ec2 describe-security-groups` | `gcloud compute firewall-rules list` |
| Query logs | `aws logs start-query` (Logs Insights) | `gcloud logging read` |
| DNS records | `aws route53 list-resource-record-sets` | `gcloud dns record-sets list` |
| Cost by service | `aws ce get-cost-and-usage` | `bq query` on billing export |
| Create budget | `aws budgets create-budget` | `gcloud billing budgets create` |
| Tag/label | `aws ec2 create-tags` | `gcloud ... update --update-labels` |
| Set retry mode (throttle) | `AWS_RETRY_MODE=adaptive AWS_MAX_ATTEMPTS=10` | `google-api-core` Retry()/deadline |
| Dry-run a change | `--dry-run` flag | `terraform plan` |

**Useful env vars:** `AWS_PROFILE`, `AWS_REGION`, `AWS_RETRY_MODE`, `AWS_MAX_ATTEMPTS`, `AWS_SDK_LOAD_CONFIG`; `CLOUDSDK_CORE_PROJECT`, `GOOGLE_APPLICATION_CREDENTIALS`, `CLOUDSDK_CORE_ACCOUNT`.

## Notes for the assistant

- **Always give both clouds side by side** when the user's environment is multi-cloud or unstated — it's the whole point of this skill.
- **Never grant `"*"` or `roles/owner` to fix a deny.** Produce the least-privilege grant for the exact action+resource named in the error.
- **Probe before you change.** Run the read-only confirm command (sts get-caller-identity, simulate-principal-policy, connectivity test) and base the fix on what it returns.
- **Never run destructive commands** (`rb`, `rm`, `delete`, `terraform destroy`) without explicit confirmation, and prefer `--dry-run`/`plan` first.
- See `references/` for deep dives: `iam-deep-dive.md` (policy/role evaluation across both clouds), `networking-and-dns.md` (the full failure-mode catalog), `observability-and-logs.md` (log-query library + budget/IaC patterns).
