# Automation recipes — dashboards, notebooks, exports

Skeletons for the artifacts you produce after an investigation. Structure deep-dives live in
**dt-app-dashboards** / **dt-app-notebooks** and the **dtctl** dashboards/notebooks refs; this file is
the *ready-to-apply* patterns and the "freeze an investigation" recipe.

Build→verify→apply loop applies to all of them:
```bash
dtctl verify query '<dql>' --fail-on-warn
dtctl diff  -f artifact.yaml
dtctl apply -f artifact.yaml --set env=prod
```

---

## 1. RED dashboard (incident overview)

`dashboards/checkout-red.yaml`:
```yaml
name: "{{.env}} · Checkout RED"
type: dashboard
content:
  settings:
    defaultTimeframe: { enabled: true, value: { from: now()-3h, to: now() } }
  layouts:
    "1": { x: 0,  "y": 0, w: 8,  h: 6 }    # quote "y" — bare y: parses as boolean
    "2": { x: 8,  "y": 0, w: 8,  h: 6 }
    "3": { x: 16, "y": 0, w: 8,  h: 6 }
    "4": { x: 0,  "y": 6, w: 24, h: 6 }
  tiles:
    "1":
      title: "Requests/s";  type: data;  visualization: lineChart
      query: |
        timeseries reqs=sum(dt.service.request.count), by:{dt.service.name},
          filter:{dt.service.name=="checkout"}
      davis: { enabled: false }
    "2":
      title: "Error rate %"; type: data; visualization: lineChart
      query: |
        timeseries reqs=sum(dt.service.request.count), fails=sum(dt.service.request.failure_count),
          by:{dt.service.name}, filter:{dt.service.name=="checkout"}
        | fieldsAdd error_rate_pct = (fails[]*100.0)/reqs[]
      davis: { enabled: false }
    "3":
      title: "p95 latency (ms)"; type: data; visualization: singleValue
      query: |
        timeseries p95=percentile(dt.service.request.response_time,95),
          by:{dt.service.name}, filter:{dt.service.name=="checkout"}
        | fieldsAdd p95_ms = p95[]/1000
      davis: { enabled: false }
    "4":
      title: "Top failing endpoints"; type: data; visualization: table
      query: |
        fetch spans, from: now()-3h
        | filter dt.service.name=="checkout" and request.is_failed==true
        | summarize n=count(), by:{endpoint.name, span.events.exception.type}
        | sort n desc | limit 20
      davis: { enabled: false }
```
Gotchas: quote `"y"`; `davis.enabled: false` on every data tile; `timeseries` for metrics,
`makeTimeseries` when charting logs/spans over time.

---

## 2. Freeze an investigation into a notebook (postmortem appendix)

One markdown section + one DQL section per investigation step. The notebook becomes the next
responder's runbook and the COE evidence trail.

`notebooks/2026-06-30-checkout-incident.yaml`:
```yaml
name: "Incident 2026-06-30 · checkout 500s"
type: notebook
content:
  sections:
    - type: markdown
      markdown: |
        ## Summary
        Deploy `checkout v2.7.1` @ 14:32 introduced an NPE in `OrderValidator`.
        Error rate 0.2%→11% from 14:33; rolled back 14:51.
    - type: markdown
      markdown: "### 1. RED — error rate vs baseline"
    - type: dql
      state: { input: { value: |
        timeseries reqs=sum(dt.service.request.count), fails=sum(dt.service.request.failure_count),
          by:{dt.service.name}, from: 2026-06-30T14:00:00Z, to: 2026-06-30T15:00:00Z,
          filter:{dt.service.name=="checkout"}
        | fieldsAdd err_pct=(fails[]*100.0)/reqs[] } }
    - type: markdown
      markdown: "### 2. Failing spans by exception"
    - type: dql
      state: { input: { value: |
        fetch spans, from: 2026-06-30T14:00:00Z, to: 2026-06-30T15:00:00Z
        | filter dt.service.name=="checkout" and request.is_failed==true
        | summarize n=count(), by:{endpoint.name, span.events.exception.type}
        | sort n desc } }
    - type: markdown
      markdown: "### 3. Deploy correlation"
    - type: dql
      state: { input: { value: |
        fetch events, from: 2026-06-30T13:00:00Z, to: 2026-06-30T15:00:00Z
        | filter event.kind=="DEPLOYMENT"
        | fields timestamp, event.name, deployment.version | sort timestamp desc } }
```
```bash
dtctl apply -f notebooks/2026-06-30-checkout-incident.yaml
```
Exact notebook section schema varies by tenant version — if `apply` rejects the shape, export a known-
good notebook (`dtctl get notebook <id> -o yaml --plain`) and mirror it. The investigation *content*
(which queries, in what order) is the durable part.

---

## 3. SLO + sharing

```bash
dtctl apply -f slos/checkout-availability.yaml --set env=prod      # (skeleton in dtctl-automation.md)
dtctl share dashboard <id> --user oncall@example.com
dtctl share notebook  <id> --group sre
```

---

## 4. Exporting findings (postmortem / ticket attachment)

```bash
# raw evidence as CSV
dtctl query -f investigations/checkout-failures.dql -o csv --plain > evidence/checkout-failures.csv

# snapshot artifact definitions into git for review
dtctl get dashboard <id> -o yaml --plain > dashboards/checkout-red.yaml
dtctl get notebook  <id> -o yaml --plain > notebooks/2026-06-30-checkout-incident.yaml

# time-series as an ASCII chart straight into a Slack/ticket comment
dtctl query 'timeseries err=sum(dt.service.request.failure_count), filter:{dt.service.name=="checkout"}' \
  -o chart --plain
```

---

## 5. Promotion across environments

One YAML, many envs — `--set` substitutes the templated `{{.env}}` fields:
```bash
for e in dev sit prod; do
  dtctl --context "$e" diff  -f dashboards/checkout-red.yaml --set env="$e"
  dtctl --context "$e" apply -f dashboards/checkout-red.yaml --set env="$e"
done
```
Keep the resource `id` per-env (a `dashboards/checkout-red.<env>.id` mapping or separate files), since
ids are environment-scoped and `apply` upserts by id.
