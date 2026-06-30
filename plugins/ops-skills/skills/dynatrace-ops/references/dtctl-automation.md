# dtctl automation — Workflows, SLOs, scheduled DQL, CI gates

CLI *mechanics* (auth, verbs, output modes, `--set` templating, safety levels) belong to the **dtctl**
skill. This file is the *automation patterns* layer: real YAML you can `dtctl apply -f`, deployed
idempotently. Always run the build→verify→diff→apply loop:

```bash
dtctl verify query '<dql>' --fail-on-warn       # syntax/cost check, no run
dtctl query   '<dql>' -o json --plain           # confirm it returns the right answer
dtctl diff    -f artifact.yaml                   # what changes vs live
dtctl apply   -f artifact.yaml --set env=prod    # idempotent upsert (by id)
```

---

## 1. Scheduled DQL via a Workflow (the workhorse)

Run a DQL check on a cron, branch on the result, notify. `workflows/nightly-error-budget.yaml`:

```yaml
title: "{{.env}} · nightly error-budget check"
type: workflow
tasks:
  query_errors:
    action: dynatrace.automations:execute-dql-query
    input:
      query: |
        timeseries reqs=sum(dt.service.request.count),
                   fails=sum(dt.service.request.failure_count),
          by:{dt.service.name}, from: now()-24h
        | fieldsAdd err_pct = (arraySum(fails)*100.0)/arraySum(reqs)
        | filter err_pct > 1.0
        | fields dt.service.name, err_pct
        | sort err_pct desc
  decide:
    action: dynatrace.automations:run-javascript
    conditions:
      states: { query_errors: SUCCESS }
    input:
      script: |
        import { execution } from '@dynatrace-sdk/automation-utils';
        export default async function ({ execution_id }) {
          const ex = await execution(execution_id);
          const res = await ex.result('query_errors');
          const breached = res.records ?? [];
          return { breached_count: breached.length, breached };
        }
  notify:
    action: dynatrace.slack:send-message
    conditions:
      states: { decide: SUCCESS }
      custom: "{{ result('decide').breached_count > 0 }}"
    input:
      channel: "#sre-alerts"
      message: "{{ result('decide').breached_count }} services over 1% error budget (24h)."
trigger:
  schedule:
    rule: "0 8 * * *"        # 08:00 daily
    timezone: "America/Toronto"
```

Deploy & operate:
```bash
dtctl apply -f workflows/nightly-error-budget.yaml --set env=prod
dtctl exec  workflow <id>                          # run once, on demand
dtctl get   workflow-execution --mine -o json --plain | jq '.[0]'
dtctl logs  workflow-execution <exec-id> --plain   # inspect a run
```

Notes:
- Action identifiers (`dynatrace.automations:*`, `dynatrace.slack:*`) come from installed apps — list
  with `dtctl describe workflow <existing-id> -o yaml --plain` to copy exact ids for your tenant.
- `conditions.custom` uses Jinja-ish workflow expressions referencing prior task `result()`.
- Reference values via `--set` for env portability; keep ids in committed YAML so `apply` updates.

---

## 2. Burn-rate alert workflow (fast + slow window)

Multi-window burn-rate is the standard SLO alerting pattern (page on fast burn, ticket on slow burn):

```yaml
title: "{{.env}} · checkout SLO burn-rate"
type: workflow
tasks:
  burn:
    action: dynatrace.automations:execute-dql-query
    input:
      query: |
        timeseries good5m=sum(dt.service.request.count, default:0),
                   bad5m =sum(dt.service.request.failure_count, default:0),
          from: now()-5m, filter:{dt.service.name=="checkout"}
        | fieldsAdd burn_5m = arraySum(bad5m)*1.0 / (arraySum(good5m)+1)
        | filter burn_5m > 0.0144      // 14.4x burn of a 99.9% SLO
  page:
    action: dynatrace.pagerduty:create-incident
    conditions: { states: { burn: SUCCESS }, custom: "{{ result('burn').records | length > 0 }}" }
    input: { summary: "checkout fast SLO burn (14.4x over 5m)" }
trigger:
  schedule: { rule: "*/5 * * * *" }
```

---

## 3. SLO as code

`slos/checkout-availability.yaml`:
```yaml
name: "{{.env}} · checkout availability"
type: slo
description: "Successful checkout requests / total"
criteria:
  - timeframeFrom: now()-7d
    timeframeTo: now()
    target: 99.9
    warning: 99.95
sliReference: |
  timeseries total = sum(dt.service.request.count),
             fail  = sum(dt.service.request.failure_count),
    filter:{dt.service.name=="checkout"}
  | fieldsAdd sli = ((arraySum(total)-arraySum(fail))*100.0)/arraySum(total)
```
```bash
dtctl apply -f slos/checkout-availability.yaml --set env=prod
dtctl get slo -o json --plain | jq -r '.[] | "\(.name)\t\(.evaluatedPercentage)\t\(.status)"'
```
Field names vary slightly by SLO schema version — `dtctl get slo <id> -o yaml --plain` on an existing
SLO and mirror its shape rather than guessing.

---

## 4. CI gate — fail a pipeline on a query result

Use in a release pipeline post-deploy smoke gate (bash, exits non-zero to fail the stage):
```bash
#!/usr/bin/env bash
set -euo pipefail
SVC="${1:?service}"; WINDOW="${2:-15m}"
ERR=$(dtctl query "
  timeseries reqs=sum(dt.service.request.count), fails=sum(dt.service.request.failure_count),
    by:{dt.service.name}, from: now()-${WINDOW}, filter:{dt.service.name==\"${SVC}\"}
  | fieldsAdd err_pct = (arraySum(fails)*100.0)/arraySum(reqs)
  | fields err_pct" -o json --plain | jq -r '.[0].err_pct // 0')

echo "post-deploy error rate for ${SVC}: ${ERR}%"
awk -v e="$ERR" 'BEGIN{ exit (e+0 > 2.0) }' \
  || { echo "::error::error rate ${ERR}% exceeds 2% — rolling back"; exit 1; }
```

---

## 5. OpenPipeline & buckets (where the data lands)

- **Buckets** control retention/scope of ingested records. List + inspect:
  `dtctl get buckets -o json --plain`; `dtctl describe bucket <name> -o yaml --plain`.
- **OpenPipeline** transforms/routes ingest (parse fields, route to bucket, derive metrics/events) —
  manage definitions via `dtctl get`/`apply` on the pipeline resource; verify the resulting records with
  a plain `fetch logs|spans|bizevents` query before relying on derived fields in dashboards.
- For automation, the pattern is the same: define as YAML, `diff`, `apply --set`, verify with a query.

---

## 6. Operating notes

- **Permissions first:** `dtctl auth can-i create workflows`, `... apply slos`. A token missing a scope
  fails at apply, not verify.
- **Safety level gates destructive verbs:** `dtctl config describe-context $(dtctl config
  current-context) --plain`. `delete`/`edit` on prod may be blocked by design.
- **Keep ids in git.** `apply` upserts by `id`; dropping the id silently creates duplicates.
- **`--set` for everything env-specific** so one YAML promotes dev→sit→prod.
