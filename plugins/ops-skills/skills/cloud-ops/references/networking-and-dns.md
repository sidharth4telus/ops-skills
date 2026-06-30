# Networking & DNS failure-mode catalog (AWS + GCP)

A symptom → confirm → root cause → fix catalog for the connectivity problems that actually page
people. Golden rule: **timeout = packets silently dropped (filter/route problem); connection
refused = you reached the host but nothing is listening on that port.**

## The layered probe (run top-down, stop at first failure)

| Layer | Question | AWS check | GCP check |
|---|---|---|---|
| DNS | Does the name resolve, and to the right IP? | `dig +short name` | `dig +short name` |
| Route | Is there a route to the destination? | route table on the subnet | `gcloud compute routes list` |
| Egress filter | Is outbound allowed from source? | SG egress rule | egress firewall rule |
| Ingress filter | Is inbound allowed at dest? | SG ingress + NACL | ingress firewall rule (priority!) |
| NAT | Private subnet reaching internet/APIs? | NAT Gateway in route table | Cloud NAT on subnet |
| Private path | Reaching a managed API privately? | VPC Endpoint / PrivateLink | Private Google Access / PSC |
| Listener | Is something on the port? | `ss -tlnp` on host | `ss -tlnp` on host |

### The two best tools (use these first)

```bash
# AWS Reachability Analyzer — names the exact blocking hop
aws ec2 create-network-insights-path --source <src> --destination <dst> --destination-port 443 --protocol tcp
aws ec2 start-network-insights-analysis --network-insights-path-id nip-...
aws ec2 describe-network-insights-analyses --network-insights-analysis-ids nia-... \
  --query 'NetworkInsightsAnalyses[0].{Reachable:NetworkPathFound,Why:Explanations[].ExplanationCode}'

# GCP Connectivity Tests — same idea
gcloud network-management connectivity-tests create t1 \
  --source-instance=projects/P/zones/Z/instances/src \
  --destination-instance=projects/P/zones/Z/instances/dst --destination-port=443 --protocol=TCP
gcloud network-management connectivity-tests describe t1 \
  --format='value(reachabilityDetails.result, reachabilityDetails.traces)'
```

## Catalog

### N1 — Inbound allowed but connection still times out (AWS)
**Root cause:** NACLs are **stateless**. You allowed inbound on 443 but the NACL has no outbound rule
for the **ephemeral return ports (1024–65535)**, so the response is dropped.
**Confirm:** `aws ec2 describe-network-acls --filters Name=association.subnet-id,Values=subnet-xxx`
**Fix:** add NACL egress rule allowing `1024-65535` to the client CIDR. (Security groups are stateful — they don't need this; if you only use SGs and default NACLs, this isn't your bug.)

### N2 — GCP: rule looks correct but traffic dropped
**Root cause:** firewall rule **priority**. A lower-numbered (higher-priority) deny rule shadows your
allow. Or you forgot that every VPC has an **implied deny-all ingress**.
**Confirm:**
```bash
gcloud compute firewall-rules list --sort-by=priority \
  --format="table(name,direction,priority,sourceRanges.list(),allowed[].map().firewall_rule().list(),disabled)"
```
**Fix:** give your allow rule a lower priority number than the deny, or remove/scope the deny.

### N3 — Private subnet can reach VPC peers but not the internet / managed APIs
**Root cause:** no NAT for the private subnet (AWS) / no Cloud NAT or Private Google Access (GCP).
**Confirm (AWS):** route table for the subnet has no `0.0.0.0/0 → nat-...` entry.
**Fix (AWS):** create/associate a NAT Gateway and add the default route. For AWS-managed services
(S3, DynamoDB, Secrets Manager, ECR), prefer a **VPC Endpoint** (no NAT cost, stays on AWS backbone):
```bash
aws ec2 create-vpc-endpoint --vpc-id vpc-x --service-name com.amazonaws.ca-central-1.s3 \
  --route-table-ids rtb-x --vpc-endpoint-type Gateway
```
**Fix (GCP):** enable **Private Google Access** on the subnet (reach `*.googleapis.com` without
external IP) and/or create Cloud NAT for general egress:
```bash
gcloud compute networks subnets update SUBNET --region=REGION --enable-private-ip-google-access
gcloud compute routers nats create nat1 --router=R --region=REGION --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
```

### N4 — Cross-account / cross-project private connectivity
- **AWS PrivateLink:** expose a service via an endpoint service (NLB) and consumers create interface
  endpoints — no VPC peering, no overlapping-CIDR problems.
- **GCP Private Service Connect:** consumer endpoint → producer service attachment. Same pattern.
- **VPC peering** (both) is non-transitive and breaks on overlapping CIDRs — prefer PrivateLink/PSC for service exposure.

### N5 — Load balancer health checks failing
**Confirm:** target/backend health.
```bash
aws elbv2 describe-target-health --target-group-arn arn:...   # see Reason: Target.Timeout / Target.ResponseCodeMismatch
gcloud compute backend-services get-health BACKEND --global
```
**Common causes:** health-check path returns non-2xx; SG/firewall doesn't allow the LB/health-check
source ranges (GCP health checks come from `35.191.0.0/16` and `130.211.0.0/22` — must be allowed);
app not listening on the health-check port; container slow to start (raise the grace period).

### N6 — MTU / fragmentation (intermittent, large payloads hang)
**Symptom:** small requests fine, large ones hang (VPN/overlay/jumbo-frame mismatch).
**Fix:** clamp MSS or align MTU (1460 on GCP VPC by default; VPNs often need lower). Often surfaces
as TLS handshakes that start then stall.

## DNS catalog

```bash
dig +short name              # final answer (or empty = NXDOMAIN)
dig +trace name              # where the delegation chain breaks
dig @<vpc-resolver-or-8.8.8.8> name   # compare internal vs public resolver
```

| Symptom | Root cause | Fix |
|---|---|---|
| Public resolver OK, NXDOMAIN inside VPC | Private hosted zone not associated with this VPC | AWS: `aws route53 associate-vpc-with-hosted-zone --hosted-zone-id Z --vpc VPCRegion=...,VPCId=vpc-x`; GCP: bind the private managed zone to the network |
| NXDOMAIN everywhere | Record missing / zone not delegated | List records: `aws route53 list-resource-record-sets --hosted-zone-id Z` / `gcloud dns record-sets list --zone=Z` |
| Stale IP after cutover | TTL not yet expired | Lower TTL *before* the change; wait out old TTL |
| `SERVFAIL` | DNSSEC validation fail / authoritative NS unreachable | Check DNSSEC chain (`dig +dnssec`); verify NS reachable |
| Private subnet can't resolve public names | VPC DNS disabled | AWS: enable `enableDnsSupport` + `enableDnsHostnames`; GCP: ensure metadata server reachable / Cloud DNS forwarding configured |
| Split-horizon surprises | Same name in public + private zone resolving differently | Decide intentionally; private zone wins inside associated VPCs |

### Route 53 record change (idempotent UPSERT)
```bash
aws route53 change-resource-record-sets --hosted-zone-id Z123 --change-batch '{
  "Changes":[{"Action":"UPSERT","ResourceRecordSet":{
    "Name":"api.example.com","Type":"A","TTL":60,
    "ResourceRecords":[{"Value":"203.0.113.10"}]}}]}'
```
### Cloud DNS record change
```bash
gcloud dns record-sets update api.example.com. --zone=myzone --type=A --ttl=60 --rrdatas=203.0.113.10
```
