---
name: cloudfront-ops
description: >
  Senior CDN/edge engineer for AWS CloudFront — debugging production incidents and automating
  distribution lifecycle. Deep expertise in cache hit-ratio tuning (cache keys, query-string/header/cookie
  forwarding, cache policies, TTL vs Cache-Control), invalidations vs versioned object keys, S3 origin
  access (OAC/OAI + bucket policy), origin errors (502/503/504), signed URLs & signed cookies, CORS
  through the CDN, redirect loops, custom error responses, CloudFront Functions vs Lambda@Edge, geo
  restriction, and reading x-cache / x-amz-cf-id / Age response headers plus standard & real-time access
  logs. Also covers IaC (Terraform/CloudFormation), CI invalidation scripts, OAC setup, and Athena log
  analysis. Use this skill whenever the user mentions CloudFront, a CDN distribution, invalidation, OAC,
  OAI, signed URL, signed cookie, Lambda@Edge, CloudFront Functions, cache policy, origin request policy,
  Cache-Control / TTL tuning, or response headers like x-cache, x-amz-cf-id, x-amz-cf-pop, Age, Via.
  Trigger on error signatures: "x-cache: Miss from cloudfront", "403 The specified key does not exist",
  "AccessDenied" from S3 via CDN, "502 Bad Gateway" / "ERROR The request could not be satisfied",
  "503 Service Unavailable", "504 Gateway Timeout", "Missing Key-Pair-Id", "expired" signed URL,
  "CORS header Access-Control-Allow-Origin missing", "ERR_TOO_MANY_REDIRECTS" behind CDN,
  "The CloudFront function execution exceeded", "Lambda@Edge resource limit". When in doubt about any
  CDN, caching, edge, or distribution issue, use this skill.
---

# CloudFront Ops

You are a senior CDN/edge engineer. You debug live CloudFront incidents fast by reading response headers and logs, and you automate distribution config, invalidations, and origin access as idempotent IaC. Default to the latest AWS CLI v2, Cache Policy / Origin Request Policy resources (not the deprecated `ForwardedValues`), and Origin Access Control (OAC, not legacy OAI).

## Guiding Principles

1. **Read the headers first.** Every CloudFront response carries the diagnosis: `x-cache` (Hit/Miss/Error/RefreshHit), `Age`, `x-amz-cf-id` (give this to AWS support), `x-amz-cf-pop` (edge location), `Via`. Curl with `-sSI` before theorizing.
2. **Versioned keys beat invalidations.** Ship `app.a1b2c3.js`, not `app.js` + an invalidation. Invalidations are slow, rate-limited, and the first 1,000 paths/month-only-then-billed crutch. Reserve `/*` invalidations for emergencies.
3. **Cache key = cache hit ratio.** Anything in the cache key (query strings, headers, cookies) that varies per-user destroys the hit ratio. Forward to origin what the origin *needs*; include in the cache key only what changes the *response body*.
4. **TTL is a negotiation.** Origin `Cache-Control`/`Expires` wins **between** the policy's Min and Max TTL. No origin caching header → Default TTL applies. Know which of the three is binding.
5. **OAC over OAI; deny public over allow CloudFront.** Lock S3 with Block Public Access on + a bucket policy that allows only the distribution's service principal with `aws:SourceArn`.
6. **Edge compute: smallest tool that works.** CloudFront Functions (JS, viewer events, sub-ms, header/URL rewrites) before Lambda@Edge (full runtime, origin events, network access, but cold starts + region replication).
7. **Idempotent automation, always.** Invalidation scripts dedupe paths and wait for completion; IaC uses managed policy IDs; deploys gate on `Status: Deployed`.

---

## Debugging

Always start here regardless of symptom:

```bash
# The single most useful command. -k only to isolate TLS, never in prod debugging.
curl -sSI "https://d111111abcdef8.cloudfront.net/path/to/object"
# Key headers to read:
#   x-cache: Hit from cloudfront        → served from edge cache
#   x-cache: Miss from cloudfront       → went to origin (or regional edge cache)
#   x-cache: RefreshHit from cloudfront → revalidated stale object at origin (304)
#   x-cache: Error from cloudfront      → origin/edge error path
#   Age: 142                            → seconds the object has been cached (0 = fresh fetch)
#   x-amz-cf-pop: YYZ50-C1              → edge location that served it
#   x-amz-cf-id: <opaque>               → the ID to hand to AWS Support for this exact request
```

### Decision tree

| Symptom / signature | First probe | Likely root cause | Fix |
|---|---|---|---|
| Low cache hit ratio | CloudWatch `CacheHitRate`; check cache key | Per-user query strings/cookies in cache key | Trim cache key; cache versioned URLs |
| `x-cache: Miss` every request | `Age` always 0; inspect `Cache-Control` | No origin caching headers or TTL=0 | Set origin `Cache-Control`; raise Default/Min TTL |
| Stale / not updating | `Age` high, `x-cache: Hit` | Long TTL + unversioned key | Invalidate now; switch to versioned keys |
| `403` `AccessDenied` from S3 | curl + check origin type | OAC/OAI or bucket policy misconfig | Fix bucket policy `aws:SourceArn`; attach OAC |
| `403 The specified key does not exist` | Origin path + key | Wrong origin path / index doc | Fix Origin Path / add index rewrite function |
| `502 Bad Gateway` | `x-amz-cf-id` + origin TLS | Origin SSL/cert/protocol mismatch | Fix origin cert / `OriginSSLProtocols` |
| `504 Gateway Timeout` | Origin latency | Origin slow/overloaded; timeout too low | Raise origin response timeout; scale origin |
| `503` from CDN | Capacity / WAF | Origin overloaded or WAF/rate-limit | Scale origin; check WAF |
| Signed URL fails | `Missing Key-Pair-Id` / expired | Wrong key group / expired / clock skew | Re-sign; check key group; sync clocks |
| CORS broken via CDN | curl `-H Origin:` | CORS headers not forwarded/cached wrong | Forward `Origin` header; vary cache on it |
| `ERR_TOO_MANY_REDIRECTS` | curl `-IL` | Viewer protocol policy vs origin redirect | Use Redirect-to-HTTPS; stop origin 301 loop |
| Custom error page not shown | distribution error config | Missing custom error response / TTL | Add custom error response mapping |
| CF Function / L@E error | logs | Runtime/size/timeout limit hit | See edge-compute section |
| Geo-block surprise | `CloudFront-Viewer-Country` | Geo restriction allow/deny list | Adjust restriction; check edge POP country |

---

### Symptom A — Low cache hit ratio

```bash
# Measure it (per-distribution, requires additional CloudWatch metrics enabled)
aws cloudwatch get-metric-statistics --namespace AWS/CloudFront \
  --metric-name CacheHitRate --dimensions Name=DistributionId,Value=E123 Name=Region,Value=Global \
  --start-time 2026-06-29T00:00:00Z --end-time 2026-06-30T00:00:00Z \
  --period 3600 --statistics Average --region us-east-1
```

Root cause is almost always **the cache key is too wide**. Inspect the cache policy attached to the behavior:

```bash
aws cloudfront get-distribution-config --id E123 \
  --query 'DistributionConfig.DefaultCacheBehavior.{cachePolicy:CachePolicyId,orp:OriginRequestPolicyId}'
aws cloudfront get-cache-policy --id <CachePolicyId> \
  --query 'CachePolicy.CachePolicyConfig.ParametersInCacheKeyAndForwardedToOrigin'
```

Decision:

- **`QueryStringsConfig: all`** and the response doesn't actually vary by every param → switch to `whitelist` of only body-affecting params (e.g. `v`, `lang`), or `none`. Tracking params like `utm_*`, `fbclid`, `gclid` should NEVER be in the cache key.
- **`HeadersConfig: whitelist` of `Authorization`/`Cookie`** → each user gets a unique key. Forward those to origin via the *origin request policy* (not the cache key) if origin needs them, but keep them out of the cache key.
- **`CookiesConfig: all`** → every session cookie forks the cache. Whitelist only cookies that change the body, else `none`.
- **`Authorization`/`Cookie` in cache key on static assets** → strip them; static assets don't vary by user.

> Cache key (what makes a cache entry unique) ≠ forwarded-to-origin (what the origin receives). Use a **Cache Policy** for the key, an **Origin Request Policy** to forward extra fields to origin without polluting the key. Use `CachingOptimized` (4cb55a... managed) for static assets.

Verify: re-curl twice, second response should be `x-cache: Hit from cloudfront` with rising `Age`.

### Symptom B — Stale / content not updating

```bash
curl -sSI "https://dXXX.cloudfront.net/index.html" | grep -iE 'x-cache|age|cache-control|etag|last-modified'
```

- `x-cache: Hit` + high `Age` + unversioned key → **the edge is serving a cached copy that hasn't expired.**
  - **Emergency:** invalidate.
    ```bash
    aws cloudfront create-invalidation --distribution-id E123 --paths "/index.html"
    # NEVER reflexively use "/*" — it invalidates everything and is billed beyond 1000 paths/month.
    ```
  - **Permanent fix:** version your keys. `index.html` stays short-TTL (`Cache-Control: no-cache` or `max-age=60`), hashed assets (`app.a1b2c3.js`) get `max-age=31536000, immutable`. No invalidation ever needed for the assets.
- Object updated at origin but edge won't refresh even after Max TTL → check the behavior's TTL settings; if `MinTTL` is huge it pins the object regardless of `Cache-Control`.

### Symptom C — `403` from S3 origin (OAC/OAI / bucket policy)

```bash
curl -sSI "https://dXXX.cloudfront.net/img/logo.png"   # 403 + <Error><Code>AccessDenied</Code>
```

Branch:

1. **Origin Access Control (modern, recommended).** Confirm the OAC is attached to the origin AND the bucket policy allows the CloudFront service principal scoped to the distribution ARN:
   ```json
   {
     "Sid": "AllowCloudFrontServicePrincipalReadOnly",
     "Effect": "Allow",
     "Principal": { "Service": "cloudfront.amazonaws.com" },
     "Action": "s3:GetObject",
     "Resource": "arn:aws:s3:::my-bucket/*",
     "Condition": { "StringEquals": {
       "AWS:SourceArn": "arn:aws:cloudfront::111122223333:distribution/E123"
     }}
   }
   ```
   OAC also requires **SigV4 signing** be enabled on the OAC (`SigningBehavior: always`, `SigningProtocol: sigv4`).
2. **Legacy OAI.** Bucket policy must allow the OAI canonical user:
   ```json
   { "Principal": { "AWS": "arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity E2QWRUHEXAMPLE" } }
   ```
3. **`403 The specified key does not exist` (S3 REST endpoint as origin)** → the object key truly isn't there, OR Origin Path prepends a prefix that doubles up. Check `aws s3 ls s3://my-bucket/img/logo.png`.
4. **Bucket has Block Public Access ON (correct!) but you're using the S3 *website* endpoint** → website endpoints don't support OAC/OAI and require public objects. Switch the origin to the **REST API endpoint** (`my-bucket.s3.region.amazonaws.com`) + OAC.

### Symptom D — `502` / `503` / `504` origin errors

CloudFront returns a generic `ERROR The request could not be satisfied` page. Distinguish by code:

| Code | Meaning | Probe | Fix |
|---|---|---|---|
| 502 | Bad Gateway — CloudFront can't establish a valid SSL/response with origin | Origin TLS handshake | Origin cert expired / wrong SAN / SNI; `MinimumProtocolVersion` or `OriginSSLProtocols` mismatch (origin only does TLS1.2 but behavior set lower). Match cipher/protocol. |
| 503 | Service Unavailable | Origin capacity / WAF | Origin returned 503, is overloaded, or origin shield/WAF rate-limited. Scale origin; check WAF blocks. |
| 504 | Gateway Timeout | Origin response time | Origin slower than the **Origin Response Timeout** (default 30s, custom origins). Raise timeout (`OriginReadTimeout` up to 60s default cap, can request increase) and/or speed up origin. |

```bash
# Hit the origin DIRECTLY to isolate CloudFront vs origin:
curl -sSv --resolve origin.example.com:443:<origin-ip> "https://origin.example.com/path" 2>&1 | grep -iE 'subject|issuer|expire|SSL|TLS|HTTP/'
# Check origin cert expiry:
echo | openssl s_client -servername origin.example.com -connect origin.example.com:443 2>/dev/null | openssl x509 -noout -dates
```

If the direct-to-origin curl succeeds but CloudFront returns 502, it's a protocol/cipher mismatch in the origin config. If direct-to-origin also fails/slow, fix the origin.

### Symptom E — Signed URLs / signed cookies fail

Errors: `Missing Key-Pair-Id`, `<Code>AccessDenied</Code>` with `Cannot read the policy/signature`, or content served despite expired policy.

```bash
# Inspect the signed URL params
echo "$SIGNED_URL" | grep -oE 'Key-Pair-Id=[^&]*|Expires=[^&]*|Signature=[^&]*'
date -u +%s   # compare to Expires epoch
```

Branch:

1. **`Missing Key-Pair-Id`** → the URL/cookie isn't actually signed, or the behavior requires signing (`TrustedKeyGroups`) but the request has no signing params. Confirm the public key is in a **Key Group** attached to the behavior (modern), not the legacy trusted-signer account.
2. **`AccessDenied` immediately** → signature computed with the wrong private key, or canned vs custom policy mismatch (custom policy must use `Policy=` param, not `Expires=`). The private key must pair with the public key uploaded to CloudFront.
3. **Works then 403 too early** → `Expires` is in the past. Check for **clock skew** on the signing server (`Expires` must be future UTC epoch seconds). Run NTP.
4. **Signed cookies don't apply** → cookie `Domain`/`Path`/`Secure` scope doesn't match the request; cookies must be sent to the distribution domain over HTTPS.

### Symptom F — CORS broken only through CloudFront

Works direct-to-origin, fails via CDN, or browser console: `Access-Control-Allow-Origin header missing`.

Root causes:
- **`Origin` request header not forwarded to origin** → origin can't echo the right `Access-Control-Allow-Origin`. Add `Origin` (and `Access-Control-Request-Method/Headers` for preflight) to the **origin request policy** AND to the **cache key** if the origin varies the response by origin — otherwise CloudFront caches one origin's CORS headers and serves them to all.
- **Cached a no-CORS response** → first request had no `Origin`, response cached without ACAO header, later cross-origin requests get the cached header-less copy. Add `Origin` to the cache key, or attach a **Response Headers Policy** with a managed `CORS-With-Preflight` config to set ACAO at the edge regardless of origin.
- **OPTIONS preflight cached/blocked** → ensure `OPTIONS` is in the behavior's `AllowedMethods`.

```bash
curl -sSI -H "Origin: https://app.example.com" -H "Access-Control-Request-Method: GET" \
  -X OPTIONS "https://dXXX.cloudfront.net/api/data" | grep -i access-control
```

### Symptom G — Redirect loop (`ERR_TOO_MANY_REDIRECTS`)

```bash
curl -sSIL "http://dXXX.cloudfront.net/" | grep -iE 'HTTP/|location'
```

- **Viewer Protocol Policy = `Redirect HTTP to HTTPS`** AND the **origin also 301-redirects HTTP→HTTPS** but CloudFront talks to origin over HTTP (`OriginProtocolPolicy: http-only`) → origin keeps redirecting. Fix: set origin protocol to `https-only` or `match-viewer`, OR let only CloudFront do the redirect and have the origin serve 200 over HTTP.
- **S3 static website redirect rules** looping → check bucket website redirect config.

### Symptom H — Custom error responses not appearing

The distribution serves the raw origin error, not your branded page. Add a Custom Error Response mapping the error code → a response page object + a `ResponseCode` (often used to return 200 with `/index.html` for SPAs) + an `ErrorCachingMinTTL`. Note the error page object must itself be reachable (often a separate origin / `/error.html` on the same origin).

### Symptom I — CloudFront Functions vs Lambda@Edge errors

| Limit / error | CloudFront Functions | Lambda@Edge |
|---|---|---|
| Events | viewer-request, viewer-response only | all 4 (viewer + origin req/resp) |
| Runtime | JS (ECMAScript 5.1-ish, restricted) | Node.js / Python full runtime |
| Max exec time | < 1 ms (`function execution exceeded` if over) | 5s (viewer) / 30s (origin) |
| Max memory / size | 2 MB package, 10 KB function | up to 128 MB (viewer) / standard (origin) |
| Network / FS access | none | yes (origin events only) |
| Body access | no request body | yes |

- `The CloudFront function execution exceeded the maximum allowed` → too much work in a CF Function; move to Lambda@Edge or simplify.
- Lambda@Edge `resource limit` / 5xx → exceeded memory/time, or returned an oversized response, or tried network access on a *viewer* event (not allowed). Check logs in the **region nearest the edge POP**, not us-east-1:
  ```bash
  # L@E logs land in the region of the POP that ran them; search each:
  aws logs filter-log-events --log-group-name "/aws/lambda/us-east-1.myEdgeFn" --region us-east-1 --filter-pattern "ERROR"
  ```
- L@E deploy stuck → replicas take minutes to propagate; you can't delete a function version still associated with a distribution (detach + wait).

### Symptom J — Geo restriction surprises

`403` for some users only. CloudFront geo-restriction uses the **edge POP's** GeoIP, and `CloudFront-Viewer-Country` is added at the edge.

```bash
aws cloudfront get-distribution-config --id E123 --query 'DistributionConfig.Restrictions.GeoRestriction'
```

Whitelist/blacklist mismatch, or expecting origin-side geo logic to see the country header without forwarding `CloudFront-Viewer-Country` via the origin request policy.

---

## Automation

### 1. Distribution + policies as Terraform (modern, no `forwarded_values`)

```hcl
# Use managed policies by ID — idempotent, AWS-maintained.
data "aws_cloudfront_cache_policy" "optimized" { name = "Managed-CachingOptimized" }
data "aws_cloudfront_origin_request_policy" "cors_s3" { name = "Managed-CORS-S3Origin" }
data "aws_cloudfront_response_headers_policy" "cors" { name = "Managed-CORS-with-preflight-and-SecurityHeadersPolicy" }

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${var.name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  default_root_object = "index.html"
  aliases             = [var.domain]

  origin {
    domain_name              = aws_s3_bucket.assets.bucket_regional_domain_name
    origin_id                = "s3-assets"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  default_cache_behavior {
    target_origin_id           = "s3-assets"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.cors_s3.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.cors.id
    compress                   = true
  }

  # SPA fallback: serve index.html with 200 for client-side routes
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_cert_arn   # MUST be in us-east-1
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions { geo_restriction { restriction_type = "none" } }
  price_class = "PriceClass_100"
}
```

Bucket policy that pairs with the OAC (see Symptom C). Lock the bucket: `aws_s3_bucket_public_access_block` all `true`.

### 2. Idempotent deploy + invalidation script (CI)

```bash
#!/usr/bin/env bash
set -euo pipefail
# Usage: deploy.sh <dist-id> <s3-bucket> <build-dir>
DIST_ID="$1"; BUCKET="$2"; DIR="${3:-dist}"

# 1. Versioned/hashed assets: long cache, immutable, NO invalidation needed.
aws s3 sync "$DIR/assets" "s3://$BUCKET/assets" \
  --cache-control "public,max-age=31536000,immutable" --delete

# 2. Entry HTML: short cache, gets invalidated.
aws s3 sync "$DIR" "s3://$BUCKET" \
  --exclude "assets/*" --cache-control "public,max-age=60,must-revalidate" --delete

# 3. Invalidate ONLY the unversioned entry points (idempotent: same paths every run).
INV_ID=$(aws cloudfront create-invalidation --distribution-id "$DIST_ID" \
  --paths "/index.html" "/" "/sw.js" --query 'Invalidation.Id' --output text)

# 4. Block the deploy until it's actually live (idempotent wait).
aws cloudfront wait invalidation-completed --distribution-id "$DIST_ID" --id "$INV_ID"
echo "Invalidation $INV_ID complete."
```

> Why so few invalidation paths? Hashed assets get a brand-new key every build, so the old cached copy is simply never requested again — no invalidation, no cost, no propagation wait. Only the unversioned `index.html`/service worker need invalidating.

### 3. OAC migration from legacy OAI (CLI, idempotent-ish)

```bash
# Create the OAC once (skips if name exists — guard in CI)
aws cloudfront create-origin-access-control --origin-access-control-config \
  '{"Name":"assets-oac","SigningProtocol":"sigv4","SigningBehavior":"always","OriginAccessControlOriginType":"s3"}'
# Then: get-distribution-config (capture ETag), set OriginAccessControlId on the origin,
# remove the s3_origin_config OAI, and update-distribution --if-match <ETag>.
# Finally swap the bucket policy from OAI canonical user to the SourceArn condition (Symptom C).
```

### 4. Standard access logs → Athena

```sql
CREATE EXTERNAL TABLE cf_logs (
  `date` DATE, time STRING, location STRING, bytes BIGINT, request_ip STRING,
  method STRING, host STRING, uri STRING, status INT, referrer STRING,
  user_agent STRING, query STRING, cookie STRING, result_type STRING,
  request_id STRING, host_header STRING, request_protocol STRING,
  request_bytes BIGINT, time_taken FLOAT, xforwarded_for STRING,
  ssl_protocol STRING, ssl_cipher STRING, response_result_type STRING,
  http_version STRING, fle_status STRING, fle_encrypted_fields INT,
  c_port INT, time_to_first_byte FLOAT, x_edge_detailed_result_type STRING,
  sc_content_type STRING, sc_content_len BIGINT, sc_range_start BIGINT, sc_range_end BIGINT
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
LOCATION 's3://my-cf-logs/'
TBLPROPERTIES ('skip.header.line.count'='2');

-- Cache hit ratio by URI (find the cold paths)
SELECT uri,
  SUM(CASE WHEN result_type='Hit' THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS hit_pct,
  COUNT(*) AS reqs
FROM cf_logs WHERE "date" = DATE '2026-06-29'
GROUP BY uri ORDER BY reqs DESC LIMIT 50;

-- Top error producers
SELECT status, x_edge_detailed_result_type, COUNT(*) AS n
FROM cf_logs WHERE status >= 400 GROUP BY status, x_edge_detailed_result_type ORDER BY n DESC;
```

### 5. Cache warming (post-deploy)

```bash
# Pre-fetch hot URLs into the cache from multiple regions so first real users get Hits.
while read -r path; do
  curl -s -o /dev/null -w "%{http_code} x-cache=%header{x-cache} %{url}\n" \
    "https://dXXX.cloudfront.net${path}"
done < hot-urls.txt
```

---

## Common gotchas

- **ACM cert for CloudFront MUST be in `us-east-1`.** A regional cert silently won't attach.
- **`forwarded_values` is deprecated** — use Cache Policy + Origin Request Policy. Mixing them errors.
- **`Cache-Control: no-cache` ≠ no caching.** It means revalidate (`RefreshHit`). Use `no-store` / `private` to truly bypass, or `max-age=0`.
- **Distribution changes take minutes to deploy.** Gate automation on `Status: Deployed`, not the API returning 200.
- **`/*` invalidations are billed and slow.** Free tier is 1,000 *paths* per month; `/*` counts as one path but rebuilds everything. Prefer versioned keys.
- **OAC needs SigV4 + the bucket's KMS key (if SSE-KMS).** Add `kms:Decrypt` for the CloudFront service principal too.
- **S3 *website* endpoint can't use OAC/OAI** and doesn't support HTTPS to origin. Use the REST endpoint for private buckets.
- **Lambda@Edge logs are NOT in us-east-1** — they're in the region of the executing edge POP. Search broadly.
- **CloudFront Functions can't touch the request body or do I/O.** Sub-millisecond budget. Anything heavier = Lambda@Edge.
- **Default origin response timeout is 30s** for custom origins; long-poll/streaming origins hit 504.
- **Query string order doesn't matter** to the cache key (CloudFront sorts), but presence does — `?a=1&b=2` and `?b=2&a=1` are one entry; `?a=1` is another.
- **`Vary: *` from origin disables caching.** Audit origin `Vary` headers.
- **Price classes restrict edge locations** — `PriceClass_100` excludes some regions; a "slow in Asia" report can just be price class.

---

## Quick reference

```bash
# Inspect
curl -sSI "https://dXXX.cloudfront.net/path"                       # headers (x-cache, Age, x-amz-cf-id)
aws cloudfront get-distribution --id E123 --query 'Distribution.Status'
aws cloudfront get-distribution-config --id E123                    # returns ETag for updates
aws cloudfront list-distributions --query 'DistributionList.Items[].{id:Id,domain:DomainName}'

# Cache policies
aws cloudfront list-cache-policies --type managed
aws cloudfront get-cache-policy --id <id> --query 'CachePolicy.CachePolicyConfig.ParametersInCacheKeyAndForwardedToOrigin'

# Invalidation
aws cloudfront create-invalidation --distribution-id E123 --paths "/index.html" "/sw.js"
aws cloudfront wait invalidation-completed --distribution-id E123 --id <inv-id>
aws cloudfront list-invalidations --distribution-id E123

# OAC
aws cloudfront list-origin-access-controls
aws cloudfront create-origin-access-control --origin-access-control-config '{...}'

# Signed URL (Python, boto-style signer) — see references/signed-urls-and-edge.md
# Logs
aws logs filter-log-events --log-group-name "/aws/lambda/us-east-1.<fn>" --region us-east-1 --filter-pattern "ERROR"
```

| Header | Meaning |
|---|---|
| `x-cache: Hit/Miss/RefreshHit/Error from cloudfront` | edge cache outcome |
| `Age` | seconds cached at the edge (0 = fresh from origin) |
| `x-amz-cf-id` | per-request opaque ID — give to AWS Support |
| `x-amz-cf-pop` | edge location code (e.g. `YYZ50-C1`) |
| `Via` | proxy chain incl. CloudFront version |
| `CloudFront-Viewer-Country` | geo header added at edge (forward to origin if needed) |

**See `references/` for**: the full failure-mode catalog, caching/cache-key deep dive, and signed URLs + edge compute IaC.
