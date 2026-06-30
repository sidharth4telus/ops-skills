---
name: dynatrace-ops
description: >
  Production incident investigation and observability automation with Dynatrace (Grail/DQL, the dtctl
  CLI, and Workflows). This is the ORCHESTRATION layer: repeatable incident-triage playbooks
  (problem → impacted entities → failing services → failure traces → exception/log correlation →
  root-cause hypothesis), latency-spike and error-rate-spike investigations, cross-service trace
  following, correlating a deploy with a regression, and turning findings into dashboards/notebooks/SLOs
  as code. Use this skill whenever the user is debugging a production incident with Dynatrace, asks to
  "investigate latency", "find the error spike", "what caused this problem / RCA", "follow this trace",
  "which deploy broke X", or wants observability AUTOMATION — saved DQL via Workflows, dashboards/
  notebooks/SLOs from YAML, scheduled queries, alerting, or exporting findings. Trigger on: Dynatrace,
  Davis, Grail, DQL, dtctl, Smartscape, problem/RCA/root cause, "fetch spans/logs/bizevents", trace.id/
  span.id, RED metrics, SLO, dashboard, notebook, workflow, error budget, deploy regression, incident,
  observability automation, scheduled query, error spike, latency investigation. Delegates DQL SYNTAX to
  dt-dql-essentials and DOMAIN queries to the dt-obs-* skills; delegates raw CLI mechanics to dtctl.
  When an incident is in flight or someone wants observability-as-code, use this skill.
---

# Dynatrace Ops — incident investigation & observability automation

You drive Dynatrace as an SRE: you run **repeatable investigation playbooks** to find root cause fast,
and you turn what you learn into **durable automation** (dashboards, notebooks, SLOs, scheduled
workflows). You orchestrate the other Dynatrace skills rather than re-deriving them.

**Skill boundaries — delegate, don't duplicate:**

| Need | Use |
|------|-----|
| DQL syntax, operators, `summarize`/`makeTimeseries`, pitfalls | **dt-dql-essentials** (load before writing any DQL) |
| `dtctl` install/auth/verbs, output modes, YAML mechanics | **dtctl** |
| RED metrics, runtime-specific service telemetry | **dt-obs-services** |
| Span/trace field reference, span kinds, sampling | **dt-obs-tracing** |
| Log fields, severity, pattern search | **dt-obs-logs** |
| Problem entities, `event.*`, Davis RCA fields | **dt-obs-problems** |
| K8s entity types, pod/workload debugging | **dt-obs-kubernetes** |
| Dashboard/notebook JSON structure deep-dive | **dt-app-dashboards** / **dt-app-notebooks** |

This skill adds: the **glue** — which query to run next, how findings chain into a root-cause
hypothesis, and how to persist the result.

## Guiding Principles

1. **Top-down, not bottom-up.** Start from a Davis problem or an impacted SLO, narrow to entities, then
   to services (RED), then to traces, then to spans/logs. Never start by grepping logs blindly.
2. **One hypothesis at a time, each backed by a query.** State "I think X because <query result>", then
   the next query either confirms or kills it. Write the queries down — they become the notebook.
3. **Always bound the time window and the scope.** Pin a tight `from:`/`to:` around the incident and
   reuse it for every query so results line up. Filter to the impacted service/namespace early.
4. **Compare against a baseline.** A number is only a symptom next to "what it was before". Every
   investigation query has a sibling that looks at the hour/day before the incident.
5. **Correlate, then attribute.** Failing traces → exception class → log lines → deploy event. Don't
   declare root cause until the timeline lines up (regression starts within minutes of the change).
6. **Verify with DQL before writing automation.** A dashboard tile or SLO is just a saved query — get
   the query returning the right answer in `dtctl query` first, then `apply -f`.
7. **Automation is idempotent and reviewed.** Resources are YAML in git; `dtctl apply -f` upserts by
   `id`; `diff`/`verify` before apply; destructive ops gated on safety level + confirmation.

---

## Debugging — incident investigation playbooks

> Load **dt-dql-essentials** before running any DQL below. The queries here are correct patterns but the
> syntax skill is authoritative. Run everything through `dtctl query "<dql>" -o json --plain`.

### The master triage flow (start here for any "prod is broken")

```
1. Is Davis already on it?      get the problem + its RCA / impacted entities
2. What is impacted?            problem.affected_entity_ids → services / hosts / k8s
3. Which service is failing?    RED metrics on impacted services (rate/errors/duration vs baseline)
4. How is it failing?           fetch failing root spans on that service
5. Why is it failing?           exception attrs on those spans → correlate to logs
6. Did something change?        deploy / config-change / k8s rollout events on the timeline
7. Hypothesis + verify          state root cause; confirm regression onset == change time
8. Persist                      save the queries to a notebook; raise/adjust SLO if needed
```

Each step is a branch below. Jump in at whichever step you already have evidence for.

### Step 1 — Anchor on the Davis problem

Symptom: alert fired / pager went off / "is anything broken".

```bash
dtctl query 'fetch dt.davis.problems, from: now()-6h
| filter event.status == "ACTIVE"
| fields display_id, event.name, event.category, root_cause_entity_name, affected_entity_ids, event.start' -o json --plain
```
- `event.category` (AVAILABILITY / ERROR / SLOWDOWN / RESOURCE) tells you which playbook below to run.
- `root_cause_entity_name` is Davis's guess — a starting hint, **not gospel**. Validate it.
- `affected_entity_ids` is your blast radius for Step 2.
- Field semantics live in **dt-obs-problems** — consult it if a field is unexpected.

No problem found but users complain → Davis hasn't detected it yet; skip to Step 3 and drive RED
metrics directly.

### Step 2 — Map the blast radius

Resolve affected entity IDs to names and types so you know what you're looking at:

```dql
fetch dt.davis.problems, from: now()-6h
| filter display_id == "P-2506301"
| expand affected_entity_ids
| fieldsAdd name = entityName(affected_entity_ids)
| fields affected_entity_ids, name
```
- If they're `SERVICE-*` → Step 3 (RED). If `KUBERNETES_*`/`HOST-*` → delegate to **dt-obs-kubernetes** /
  dt-obs-hosts for pod/node health, then come back.

### Step 3 — RED metrics: which service, how bad, vs baseline

Symptom: need to confirm a service is the failing one and quantify it.

```dql
timeseries {
  reqs   = sum(dt.service.request.count),
  fails  = sum(dt.service.request.failure_count),
  p95_us = percentile(dt.service.request.response_time, 95)
}, by: {dt.service.name}, from: now()-3h, interval: 1m
| fieldsAdd error_rate_pct = (fails[] * 100.0) / reqs[]
| fieldsAdd p95_ms = p95_us[] / 1000
| sort arrayMax(error_rate_pct) desc
```
Decision tree on what the curve shows:

| Curve shape | Branch |
|-------------|--------|
| Error-rate step up at time T | **Error-rate spike** playbook ↓ |
| p95/p99 ramp, error rate flat | **Latency spike** playbook ↓ |
| Both rise together at T | usually a downstream dependency — go to **cross-service trace following** ↓ |
| Request count collapses to ~0 | AVAILABILITY — service/pod down → dt-obs-kubernetes |

Detailed RED queries and runtime-specific metrics live in **dt-obs-services**.

### Step 4a — Error-rate spike playbook

```
symptom: error_rate_pct jumps at T
 ├─ pull the failing root spans on that service around T
 ├─ group by exception class + endpoint  → is it one error or many?
 ├─ ONE dominant exception → correlate to logs by trace.id → read the stack
 ├─ MANY unrelated errors  → look upstream: a shared dependency failing? (Step 6)
 └─ confirm onset T lines up with a deploy/config change (Step 7)
```

Failing root spans, grouped:
```dql
fetch spans, from: now()-3h
| filter dt.service.name == "checkout" and request.is_failed == true
| summarize n = count(), by: {endpoint.name, span.events.exception.message}
| sort n desc | limit 20
```

> **GOTCHA — `trace.id`/`span.id` are `uid` type.** `filter trace.id == "<hex>"` silently matches
> NOTHING (no error, zero rows). You MUST stringify first:
> ```dql
> fetch spans, from: now()-3h
> | fieldsAdd t = toString(trace.id)
> | filter t == "5b8aa5a2d2c872e8321cf37308d69df2"
> ```

### Step 4b — Latency spike playbook

```
symptom: p95/p99 ramp, errors flat
 ├─ slowest endpoints on the service?
 ├─ for the slowest endpoint: where is the time going — self vs children?
 │     span.timing.cpu_self high  → CPU-bound in THIS service (GC, hot loop, regex)
 │     duration ≫ cpu_self        → waiting on a downstream call or DB → follow the trace (Step 5)
 └─ DB-bound? group child client spans by db.statement / peer service
```

Time attribution on the slow endpoint:
```dql
fetch spans, from: now()-2h
| filter dt.service.name == "checkout" and endpoint.name == "POST /order"
| filter request.is_root_span == true
| summarize p95_dur = percentile(duration, 95),
            p95_cpu = percentile(span.timing.cpu_self, 95),
            n = count()
```
Span timing fields and span kinds are documented in **dt-obs-tracing**.

### Step 5 — Cross-service trace following (find the slow/failing hop)

Take one representative bad trace (slowest or a failing one), then expand the whole tree:

```dql
// 1. grab a candidate trace id (note the toString gotcha applies on the way OUT too)
fetch spans, from: now()-2h
| filter dt.service.name == "checkout" and request.is_failed == true
| fieldsAdd t = toString(trace.id)
| sort duration desc | fields t, duration | limit 1
```
```dql
// 2. expand that trace — every span, ordered, with self/child timing
fetch spans, from: now()-2h
| fieldsAdd t = toString(trace.id)
| filter t == "<paste-from-step-1>"
| fields start_time, dt.service.name, span.name, span.kind, duration,
         request.is_failed, span.events.exception.message
| sort start_time asc
```
Read the tree top-down: the first span whose `duration` dominates and whose children are cheap is the
**culprit hop**. If that hop is `span.kind == client` to another service, that downstream service is the
next investigation target — re-run Step 3 scoped to it.

### Step 6 — Exception ↔ log correlation

Pull the logs for the failing traces to get the stack trace / cause:

```dql
fetch logs, from: now()-2h
| filter dt.service.name == "checkout" and loglevel == "ERROR"
| fieldsAdd t = toString(trace.id)
| filter isNotNull(t) and t != ""
| summarize n = count(), example = takeFirst(content), by: {status, dt.process_group.detected_name}
| sort n desc
```
Or pivot from a known bad trace id to its log lines (same `toString` join trick). Log fields, severities
and pattern-matching helpers (`matchesPhrase`) are in **dt-obs-logs**.

### Step 7 — Correlate the regression with a change/deploy

The clincher: a regression that starts within minutes of a deploy/config change is almost certainly that
change.

```dql
// deployment & config-change events on the impacted entity around the incident
fetch events, from: now()-6h
| filter in(event.kind, "DEPLOYMENT", "CONFIGURATION_EVENT")
| fields timestamp, event.kind, event.name, dt.entity.service, deployment.version
| sort timestamp desc
```
- Overlay the RED `timeseries` from Step 3 against these timestamps in a notebook tile.
- **Confirmed root cause** = error/latency onset time ≈ deployment timestamp (± a couple of minutes).
- If onset *precedes* the deploy, the deploy is a red herring — keep looking upstream (Step 5/6).

### Step 8 — Hypothesis, then persist

State the chain explicitly:
> "Root cause: deploy `checkout v2.7.1` at 14:32 introduced an NPE in `OrderValidator` (span exception
> `NullPointerException`, 2.4k failing `POST /order` root spans, error rate 0.2%→11% starting 14:33).
> Mitigation: roll back to v2.7.0."

Then turn the investigation queries into a **notebook** (one section per step) so the next responder
inherits the trail — see Automation ↓.

### Quick symptom → first-query index

| Symptom | First query / branch |
|---------|----------------------|
| Pager fired, unknown cause | Step 1 (Davis problem) |
| "API is throwing 500s" | Step 3 RED → Step 4a |
| "Everything's slow" | Step 3 RED → Step 4b |
| "Checkout times out, others fine" | Step 5 trace following |
| "Did the 2pm deploy break it?" | Step 7 deploy correlation + Step 3 overlay |
| "What's the stack trace?" | Step 6 log correlation |
| `filter trace.id == ...` returns nothing | `toString(trace.id)` gotcha (Step 4a) |

---

## Automation — observability as code

> Mechanics (auth, verbs, output modes, template `--set`) are in **dtctl**. This section is the
> *patterns*: build it as a query, save it as YAML, deploy idempotently, schedule it.

### The build → verify → apply loop (use for every artifact)

```bash
# 1. build & verify the query in isolation
dtctl verify query 'timeseries reqs=sum(dt.service.request.count), by:{dt.service.name}' --fail-on-warn
dtctl query   'timeseries reqs=sum(dt.service.request.count), by:{dt.service.name}' -o json --plain

# 2. diff the artifact against what's live (no surprises)
dtctl diff -f dashboards/checkout-red.yaml

# 3. upsert idempotently (id in file → update; no id → create once)
dtctl apply -f dashboards/checkout-red.yaml --set env=prod

# 4. confirm
dtctl get dashboard <id> -o yaml --plain | head
```

### Dashboard as code (RED overview skeleton)

`dashboards/checkout-red.yaml`:
```yaml
name: "{{.env}} · Checkout RED"
type: dashboard
content:
  settings:
    defaultTimeframe: { enabled: true, value: { from: now()-3h, to: now() } }
  layouts:
    "1": { x: 0,  "y": 0, w: 12, h: 6 }      # NOTE: quote "y" or YAML parses it as boolean false
    "2": { x: 12, "y": 0, w: 12, h: 6 }
  tiles:
    "1":
      title: "Error rate %"
      type: data
      query: |
        timeseries reqs=sum(dt.service.request.count), fails=sum(dt.service.request.failure_count),
          by:{dt.service.name}, filter:{dt.service.name=="checkout"}
        | fieldsAdd error_rate_pct = (fails[]*100.0)/reqs[]
      visualization: lineChart
      davis: { enabled: false }               # always disable davis on data tiles
    "2":
      title: "p95 latency (ms)"
      type: data
      query: |
        timeseries p95=percentile(dt.service.request.response_time,95),
          by:{dt.service.name}, filter:{dt.service.name=="checkout"}
        | fieldsAdd p95_ms = p95[]/1000
      visualization: lineChart
      davis: { enabled: false }
```
Layout/tile field details and more visualization types → **dt-app-dashboards** + dtctl's dashboards ref.

### Notebook as code (freeze an investigation)

Turn the 8-step trail into a shareable notebook — one markdown + one DQL section per step. Skeleton and
the full failing-trace investigation notebook live in
[references/automation-recipes.md](references/automation-recipes.md). The point: after every Sev1, the
notebook IS the postmortem appendix and the next responder's runbook.

### SLO + error-budget alerting

```bash
dtctl apply -f slos/checkout-availability.yaml --set env=prod
dtctl get slo -o json --plain | jq -r '.[] | "\(.name)\t\(.status)\t\(.evaluatedPercentage)"'
```
SLO YAML skeleton (availability via RED metrics) and a burn-rate alert workflow are in
[references/automation-recipes.md](references/automation-recipes.md).

### Scheduled DQL via Workflows (the automation workhorse)

Use a Workflow to run a DQL check on a cron and act on the result (notify, open a ticket, export). Full
workflow YAML (cron trigger → `run_javascript`/`execute_dql` task → conditional Slack/email) is in
[references/dtctl-automation.md](references/dtctl-automation.md). Deploy + run:
```bash
dtctl apply -f workflows/nightly-error-budget.yaml --set env=prod
dtctl exec workflow <id>                         # fire once, on demand
dtctl logs workflow-execution <exec-id> --plain  # inspect a run
```

### Exporting findings

```bash
# raw evidence for a postmortem / ticket attachment
dtctl query -f investigations/checkout-failures.dql -o csv --plain > evidence.csv

# snapshot a notebook/dashboard definition into git
dtctl get notebook <id> -o yaml --plain > notebooks/2026-06-30-checkout-incident.yaml
```

---

## Common gotchas

- **`trace.id` / `span.id` are `uid`, not string.** `filter trace.id == "<hex>"` matches nothing,
  silently. Always `fieldsAdd t = toString(trace.id) | filter t == "<hex>"`.
- **Array index must be a literal.** `arr[n-1]` is invalid; use `arr[-1]` for last, `arr[0]` for first.
  Negative literals are fine; computed indexes are not.
- **`summarize by:{f}` needs an aggregation.** `summarize by:{service}` errors — add `count()` (or
  similar): `summarize n=count(), by:{service}`. To just dedup, use `dedup` or `fields ... | dedup`.
- **`join`'s right (lookup) side is size-limited.** Filter/scope the right subquery tightly (and prefer
  `lookup` for enrichment); an unbounded right side fails. Put the big stream on the left.
- **`filter ... in [..]` array literal doesn't exist** — use `in(field, "a", "b")`.
- **Bound the time window everywhere.** `fetch spans` with no `from:` scans the default window and is
  slow/expensive; always pass `from: now()-Xh` and the same window across correlated queries.
- **`davis.enabled: false` on every data tile** — leaving it on makes dashboards apply oddly.
- **Quote `"y"` in dashboard layouts** — bare `y:` is parsed as YAML boolean.
- **`apply` upserts by `id`.** Re-applying a file *with* an `id` updates; remove the `id` and you create
  a duplicate. Keep ids in the committed YAML.
- **Davis `root_cause_entity_name` is a hint, not proof.** Validate the onset-vs-change timeline before
  declaring root cause.
- **Confirm safety level before destructive ops.** `dtctl config describe-context $(dtctl config
  current-context) --plain`; `delete`/`edit` on prod can be blocked — that's a feature.

---

## Quick reference

```bash
# context / perms
dtctl config current-context
dtctl auth whoami --plain
dtctl auth can-i create dashboards

# investigate
dtctl query '<dql>' -o json --plain                 # run a query (load dt-dql-essentials first)
dtctl query -f q.dql --set service=checkout -o csv --plain
dtctl wait query '<dql>' --for=count=1 --timeout 5m # poll until rows appear
dtctl verify query '<dql>' --fail-on-warn           # validate, don't run

# automate (build → verify → diff → apply)
dtctl diff   -f artifact.yaml
dtctl apply  -f artifact.yaml --set env=prod        # idempotent upsert by id
dtctl get    <dashboard|notebook|slo|workflow> -o yaml --plain
dtctl describe <resource> <id> -o json --plain
dtctl exec   workflow <id>                          # run a workflow now
dtctl logs   workflow-execution <exec-id> --plain
dtctl delete <resource> <id>                        # destructive — confirm + safety level
```

| Investigation step | Anchor data source |
|---------------------|--------------------|
| 1 Davis problem | `fetch dt.davis.problems` |
| 2 Blast radius | `affected_entity_ids` + `entityName()` |
| 3 RED metrics | `timeseries dt.service.request.*` |
| 4 Failing/slow spans | `fetch spans \| filter request.is_failed` |
| 5 Trace tree | `fetch spans \| filter toString(trace.id)==...` |
| 6 Logs | `fetch logs \| filter loglevel=="ERROR"` |
| 7 Deploy correlation | `fetch events \| filter event.kind=="DEPLOYMENT"` |

| Reference | Contents |
|-----------|----------|
| [references/investigation-playbooks.md](references/investigation-playbooks.md) | Full symptom→RCA catalog: latency, error spike, availability, saturation, cascading failure, noisy-neighbor — each end-to-end with queries. |
| [references/dtctl-automation.md](references/dtctl-automation.md) | Workflow YAML (scheduled DQL, burn-rate alert), SLO YAML, OpenPipeline/bucket notes, CI gate examples. |
| [references/automation-recipes.md](references/automation-recipes.md) | Dashboard + notebook + SLO skeletons, the "freeze an investigation into a notebook" recipe, export patterns. |
