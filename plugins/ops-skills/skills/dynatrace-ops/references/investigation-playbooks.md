# Investigation playbooks — symptom → RCA, end to end

Full catalog of incident-investigation flows. Each is the orchestration; DQL **syntax** is owned by
**dt-dql-essentials**, domain field semantics by the relevant **dt-obs-*** skill. Run every query with
`dtctl query "<dql>" -o json --plain`. Pin one tight time window and reuse it across all queries in an
investigation so curves line up.

> **The `uid` trap repeats everywhere below.** `trace.id` and `span.id` are `uid`-typed.
> `filter trace.id == "<hex>"` returns ZERO rows silently. Always
> `fieldsAdd t = toString(trace.id) | filter t == "<hex>"`.

---

## Playbook A — Latency spike (p95/p99 up, errors flat)

```
detect → localize service → localize endpoint → self vs downstream → attribute
```

1. **Detect & scope** (which service slowed, vs baseline):
```dql
timeseries p95=percentile(dt.service.request.response_time,95),
           p99=percentile(dt.service.request.response_time,99),
  by:{dt.service.name}, from: now()-3h, interval: 1m
| fieldsAdd p95_ms=p95[]/1000, p99_ms=p99[]/1000
| sort arrayMax(p99) desc | limit 10
```

2. **Slowest endpoints on the suspect service:**
```dql
fetch spans, from: now()-2h
| filter dt.service.name == "checkout" and request.is_root_span == true
| summarize p95=percentile(duration,95), n=count(), by:{endpoint.name}
| sort p95 desc | limit 15
```

3. **Self time vs downstream wait** (the key fork):
```dql
fetch spans, from: now()-2h
| filter dt.service.name=="checkout" and endpoint.name=="POST /order" and request.is_root_span==true
| summarize p95_dur=percentile(duration,95), p95_cpu=percentile(span.timing.cpu_self,95), n=count()
```
| Result | Root-cause direction |
|--------|----------------------|
| `p95_cpu` ≈ `p95_dur` | CPU-bound in THIS service — GC pauses, hot loop, unbounded regex, sync serialization. Check process CPU (dt-obs-hosts) + GC suspension. |
| `p95_dur` ≫ `p95_cpu` | Waiting on a downstream call / DB / lock → step 4. |

4. **Where the wait goes — child client spans by peer:**
```dql
fetch spans, from: now()-2h
| filter dt.service.name=="checkout" and span.kind=="client"
| summarize p95=percentile(duration,95), n=count(),
            by:{db.system, db.namespace, server.address}
| sort p95 desc | limit 15
```
DB-bound → the slow peer is your next target (its own RED + slow-query logs). External HTTP → re-run
Playbook A scoped to that downstream service. (Trace-tree expansion: see Playbook E.)

5. **GC / suspension sanity check** (Java/.NET CPU-bound cases) — delegate metric specifics to
   **dt-obs-services**, but the pattern: correlate the latency ramp with
   `dt.runtime.jvm.gc.suspension_time` (or runtime equivalent) on the same window.

---

## Playbook B — Error-rate spike (errors up)

```
detect → dominant exception? → one (read stack) | many (look upstream) → deploy correlation
```

1. **Detect & rank by error rate:**
```dql
timeseries reqs=sum(dt.service.request.count), fails=sum(dt.service.request.failure_count),
  by:{dt.service.name}, from: now()-3h, interval: 1m
| fieldsAdd err_pct=(fails[]*100.0)/reqs[]
| sort arrayMax(err_pct) desc | limit 10
```

2. **Group failures by exception + endpoint:**
```dql
fetch spans, from: now()-2h
| filter dt.service.name=="checkout" and request.is_failed==true
| summarize n=count(), by:{endpoint.name, span.events.exception.type, span.events.exception.message}
| sort n desc | limit 20
```
| Pattern | Branch |
|---------|--------|
| ONE exception type dominates (>70%) | Read its stack via logs (step 3). Likely a code/deploy bug → Playbook D. |
| MANY unrelated exceptions across endpoints | Shared dependency failing (DB down, downstream 5xx, pool exhausted). Look upstream → Playbook E + check the downstream's RED. |
| Errors only on ONE pod/host | Bad node / partial rollout → dt-obs-kubernetes; check `k8s.pod.name` dimension. |

3. **Stack trace via logs** (pivot on the exception):
```dql
fetch logs, from: now()-2h
| filter dt.service.name=="checkout" and loglevel=="ERROR"
| filter matchesPhrase(content, "NullPointerException")
| summarize n=count(), example=takeFirst(content), by:{dt.process_group.detected_name}
| sort n desc
```

4. **HTTP status breakdown** (separate client 4xx from server 5xx):
```dql
fetch spans, from: now()-2h
| filter dt.service.name=="checkout" and request.is_root_span==true and isNotNull(http.response.status_code)
| summarize n=count(), by:{http.response.status_code, endpoint.name}
| sort n desc
```
A spike in 4xx = bad input / auth / contract change (often a *caller* change). 5xx = your fault.

---

## Playbook C — Availability drop (traffic collapses / "no data")

```
confirm traffic→0 → pods? → endpoints/Service → upstream LB/ingress
```

1. **Confirm the request count actually fell** (vs a metrics gap):
```dql
timeseries reqs=sum(dt.service.request.count), by:{dt.service.name},
  from: now()-3h, interval: 1m
| filter dt.service.name=="checkout"
```
2. If reqs→0: is the workload up? Delegate to **dt-obs-kubernetes** — check pod phase, restarts,
   OOMKills, readiness. CrashLoop/OOM there is your root cause.
3. If pods are healthy but no traffic: **Service has no endpoints** or **ingress is misrouting** — again
   dt-obs-kubernetes (endpoints / ingress refs).
4. If everything downstream is healthy but Davis still flags AVAILABILITY: synthetic/HTTP monitor angle
   — check the monitor's own failures.

---

## Playbook D — "Did the deploy break it?" (regression ↔ change correlation)

The single most common real RCA. Goal: prove (or disprove) onset == change time.

1. **List deploys/config changes on the impacted entity:**
```dql
fetch events, from: now()-12h
| filter in(event.kind, "DEPLOYMENT", "CONFIGURATION_EVENT")
| fields timestamp, event.kind, event.name, deployment.version, dt.entity.service
| sort timestamp desc
```
2. **Pin the regression onset** (first interval where error rate crosses baseline):
```dql
timeseries fails=sum(dt.service.request.failure_count), reqs=sum(dt.service.request.count),
  by:{dt.service.name}, from: now()-6h, interval: 1m, filter:{dt.service.name=="checkout"}
| fieldsAdd err_pct=(fails[]*100.0)/reqs[]
```
Find the first timestamp where `err_pct` jumps. (Read the array; remember computed indexes are illegal —
inspect the series, don't `arr[onset_idx]`.)

3. **Verdict:**
| Timeline | Conclusion |
|----------|------------|
| onset within ~2 min after a deploy | **That deploy is the root cause.** Recommend rollback to prior `deployment.version`. |
| onset *before* any deploy | Deploy is a red herring. Look upstream/infra (Playbook E / C). |
| onset == config change (feature flag, env var) | Config change is root cause; revert the flag. |

4. **Persist** the overlay: a notebook tile with the RED `timeseries` + a markdown note of the deploy
   timestamp is the postmortem evidence.

---

## Playbook E — Cross-service / cascading failure (trace following)

When "checkout is slow/failing but it's actually billing's fault".

1. **Pick a representative bad trace** (slowest failing root span):
```dql
fetch spans, from: now()-2h
| filter dt.service.name=="checkout" and request.is_failed==true and request.is_root_span==true
| fieldsAdd t = toString(trace.id)
| sort duration desc | fields t, duration | limit 1
```
2. **Expand the full trace tree** (uid gotcha on the way in):
```dql
fetch spans, from: now()-2h
| fieldsAdd t = toString(trace.id)
| filter t == "<paste>"
| fields start_time, dt.service.name, span.name, span.kind, duration,
         request.is_failed, span.events.exception.message
| sort start_time asc
```
3. **Read top-down:** the first span whose `duration` dominates while its children are cheap is the
   culprit hop. If it's `span.kind=="client"` → the callee service is the real suspect. Re-anchor
   Playbook A/B on that service.
4. **Find the service dependency map** to understand fan-out (delegate edge/Smartscape syntax to
   dt-dql-essentials topology ref):
```dql
fetch spans, from: now()-1h
| filter dt.service.name=="checkout" and span.kind=="client"
| summarize calls=count(), errs=countIf(request.is_failed==true), by:{server.address}
| fieldsAdd err_pct=(errs*100.0)/calls | sort err_pct desc
```

---

## Playbook F — Resource saturation / noisy neighbor

```
RESOURCE problem → which container/host → which workload → throttle or leak?
```

1. Davis RESOURCE problem → grab the entity. Delegate the actual host/container metric queries to
   **dt-obs-hosts** / **dt-obs-kubernetes** (CPU throttling, memory working set, OOMKills).
2. Pattern to remember: **memory climbing steadily then OOMKill** = leak; **memory sawtooth at limit** =
   sized too small or legit load. **CPU throttling with low usage** = CPU *limit* too low (throttled),
   not CPU starvation.
3. Tie it back to the latency/error symptom: a saturated pod is often the hop Playbook E lands on.

---

## Closing every investigation

1. State the chain: change → mechanism → symptom → blast radius → mitigation, each clause backed by a
   query result.
2. Recommend the action (rollback / scale / flag-revert / fix-forward) with the specific version/value.
3. Persist the queries into a notebook (Automation section / automation-recipes.md). The notebook is the
   postmortem appendix and the next responder's runbook.
