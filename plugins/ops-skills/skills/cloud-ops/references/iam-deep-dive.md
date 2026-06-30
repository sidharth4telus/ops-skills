# IAM deep dive — policy & role evaluation (AWS + GCP)

How both clouds decide "allow" vs "deny", how to read a real denial, and how to author the
minimal grant that fixes it.

## AWS — the evaluation order

For a given request, AWS evaluates (simplified):

```
1. Explicit DENY anywhere (identity policy, resource policy, SCP, permission boundary, session policy)?
   → DENY (wins over everything)
2. SCP (Organizations) allows the action?           → if no SCP allows, implicit DENY
3. Resource-based policy allows?                     ┐
4. Identity-based policy allows?                     ├─ need at least one Allow across the applicable set
5. Permission boundary allows (if attached)?         ┘  AND no boundary/SCP/session-policy denies it
6. Session policy (assume-role) allows?
→ default: implicit DENY if nothing explicitly allows
```

Key consequences:
- **Explicit `Deny` always wins.** A perfect Allow can be overridden by a `Deny` in an SCP, a permission boundary, or a resource policy.
- **Cross-account** access needs an Allow on BOTH sides: the identity policy in the caller account AND the resource policy in the resource account.
- A **permission boundary** caps the maximum — the effective permission is the *intersection* of the identity policy and the boundary.

### Read a real AWS denial

```
User: arn:aws:iam::111122223333:user/ci is not authorized to perform:
  kms:Decrypt on resource: arn:aws:kms:ca-central-1:111122223333:key/abcd-... because
  no identity-based policy allows the kms:Decrypt action
```
- **Principal:** `user/ci` in `111122223333`
- **Action:** `kms:Decrypt`
- **Resource:** that KMS key
- **Reason phrase tells you the layer:** "no identity-based policy allows" → add an identity grant. If it said "with an explicit deny in a resource-based policy" → fix the **key policy**, not the identity policy.

### Confirm without changing

```bash
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::111122223333:user/ci \
  --action-names kms:Decrypt \
  --resource-arns arn:aws:kms:ca-central-1:111122223333:key/abcd-... \
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision,DeniedBy:MatchedStatements[?Effect==`Deny`]}'
```
`EvalDecision`: `allowed` | `explicitDeny` | `implicitDeny`. If `explicitDeny`, `MatchedStatements` shows which statement and whether it came from an SCP/boundary.

### Find the layer that's blocking

```bash
# SCPs in effect (need org access)
aws organizations list-policies-for-target --target-id <account-id> --filter SERVICE_CONTROL_POLICY
# Permission boundary on the principal
aws iam get-role --role-name <role> --query 'Role.PermissionsBoundary'
# Resource policy (S3 / KMS / SQS / Secrets Manager etc.)
aws s3api get-bucket-policy --bucket <b>
aws kms get-key-policy --key-id <id> --policy-name default
```

### Least-privilege authoring rules (AWS)
- Name **specific actions**, never `s3:*` and never `"Action": "*"`.
- Scope **`Resource`** to exact ARNs (object-level vs bucket-level are different ARNs).
- Use **Conditions** to tighten: `aws:SourceVpce`, `aws:PrincipalTag`, `s3:prefix`, `aws:SecureTransport`.
- Validate: `aws accessanalyzer validate-policy --policy-document file://p.json --policy-type IDENTITY_POLICY` (flags overly-broad and invalid statements).
- Generate from real usage: IAM Access Analyzer **policy generation** from CloudTrail produces a least-priv policy from what the principal actually used.

## GCP — the model

GCP IAM = **bindings** of `{role → members}` attached at a **resource node**, and policies **inherit
down the hierarchy**: `Organization → Folder → Project → Resource`. The effective permission set is
the **union** of all roles granted at the resource and every ancestor.

```
permission granted? = ∃ a role (at the resource or any ancestor) that contains the permission
                      AND no Deny policy denies it
                      AND not blocked by an Org Policy constraint or VPC Service Controls perimeter
```

- There is **no resource-level explicit allow vs deny like AWS** by default, but GCP now has **IAM Deny policies** (`gcloud iam policies`) which, like AWS explicit Deny, override allows.
- **Org Policy constraints** (e.g. `constraints/iam.disableServiceAccountKeyCreation`) can block actions regardless of IAM.
- **VPC Service Controls** can return `PERMISSION_DENIED` even with correct IAM — it's a perimeter, not an IAM grant.
- **IAM Conditions** on a binding (CEL expression on resource name, time, etc.) can make a role apply only sometimes.

### Read a real GCP denial

```
PERMISSION_DENIED: Permission 'secretmanager.versions.access' denied for resource
  'projects/myproj/secrets/db-pass/versions/latest' (or it may not exist).
```
- **Permission:** `secretmanager.versions.access` (note: *permission*, not role — find a role that contains it)
- **"or it may not exist"** → ALSO verify the secret + project are real before assuming IAM.

### Confirm / inspect

```bash
# What roles does this member hold (project-level), flattened
gcloud projects get-iam-policy myproj \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:app@myproj.iam.gserviceaccount.com" \
  --format="table(bindings.role, bindings.condition.title)"

# Does a candidate role contain the needed permission?
gcloud iam roles describe roles/secretmanager.secretAccessor --format='value(includedPermissions)' | tr ';' '\n' | grep versions.access

# Resource-level bindings (a binding can be on the secret itself, not the project)
gcloud secrets get-iam-policy db-pass --project=myproj

# Org policies that might be blocking
gcloud org-policies list --project=myproj
```

### Least-privilege authoring rules (GCP)
- Prefer a **predefined role** scoped to the **narrowest resource** (grant on the secret/bucket/topic, not the project).
- If no predefined role is tight enough, make a **custom role** with exactly the permissions used.
- Bind to a **service account**, not a user, for workloads; use **Workload Identity Federation** instead of SA keys where possible.
- Use **IAM Conditions** to limit by resource name prefix or time.
- Audit with the **Policy Analyzer** / `gcloud asset analyze-iam-policy` to see who can do what.

## Quick cross-map

| Concept | AWS | GCP |
|---|---|---|
| Grant unit | Policy (JSON) attached to identity or resource | Role binding on a resource node |
| Inheritance | None (explicit per principal/resource) | Org → Folder → Project → Resource (union) |
| Override allow | Explicit `Deny` / SCP / boundary | IAM Deny policy / Org Policy / VPC-SC |
| Workload identity | IAM role + STS assume-role / IRSA | Service account + Workload Identity Federation |
| Simulate | `iam simulate-principal-policy` | `asset analyze-iam-policy`, role describe |
| Least-priv generator | Access Analyzer policy generation (CloudTrail) | Recommender (role recommendations) |
| Validate policy | `accessanalyzer validate-policy` | `gcloud iam roles describe` review |
