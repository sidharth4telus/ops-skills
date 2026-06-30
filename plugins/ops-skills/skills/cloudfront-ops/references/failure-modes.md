# CloudFront failure-mode catalog

A long-form companion to the SKILL.md decision tree. Each entry: signature → confirm → root cause → fix → verify.

## 1. 403 AccessDenied from S3 origin

**Signature**
```
HTTP/2 403
<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
```
**Confirm**
```bash
aws cloudfront get-distribution-config --id E123 \
  --query 'DistributionConfig.Origins.Items[].{domain:DomainName,oac:OriginAccessControlId,oai:S3OriginConfig.OriginAccessIdentity}'
aws s3api get-bucket-policy --bucket my-bucket --query Policy --output text | jq .
```
**Root causes & fixes**

| Finding | Cause | Fix |
|---|---|---|
| `oac` set, but bucket policy has no `AWS:SourceArn` condition | Bucket doesn't trust the distribution | Add the OAC bucket policy (service principal + SourceArn) |
| `oai` empty AND `oac` empty | No origin access configured at all | Attach an OAC; remove public access reliance |
| Bucket SSE-KMS | CloudFront can't decrypt | Grant `kms:Decrypt`/`kms:GenerateDataKey` to `cloudfront.amazonaws.com` with SourceArn condition on the key policy |
| Origin is the **website** endpoint (`*.s3-website-*`) | Website endpoints ignore OAC/OAI; need public objects | Switch origin to REST endpoint `my-bucket.s3.<region>.amazonaws.com` |
| `403` only for some keys | Block Public Access + per-object ACL legacy | Use bucket-policy-only; disable ACLs (`BucketOwnerEnforced`) |

**Verify**: `curl -sSI` returns 200 and `x-cache` populated.

## 2. 502 Bad Gateway (custom origin)

**Signature**: CloudFront branded `ERROR The request could not be satisfied` page, HTTP 502, `x-cache: Error from cloudfront`.

**Confirm — isolate CloudFront vs origin**
```bash
# direct to origin, bypassing CloudFront
curl -sSv "https://origin.example.com/health" 2>&1 | grep -iE 'HTTP/|SSL|TLS|certificate|verify'
echo | openssl s_client -servername origin.example.com -connect origin.example.com:443 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```
**Root causes**
- Origin cert expired, self-signed, or CN/SAN doesn't match the `DomainName` configured as origin.
- `OriginProtocolPolicy: https-only` but origin only serves HTTP (or vice versa).
- `OriginSSLProtocols` excludes the only protocol the origin supports (e.g. origin is TLS1.2-only, behavior allows only TLS1.0/1.1).
- Origin returns a malformed/oversized response header.

**Fix**: renew/replace the origin cert with a publicly trusted CA whose SAN matches the origin domain; align protocol policy + SSL protocols. CloudFront requires the origin cert chain be publicly trusted (no self-signed).

## 3. 504 Gateway Timeout

**Signature**: HTTP 504 after ~30s.
**Confirm**
```bash
curl -sS -o /dev/null -w "origin_ttfb=%{time_starttransfer}s total=%{time_total}s\n" "https://origin.example.com/slow"
aws cloudfront get-distribution-config --id E123 \
  --query 'DistributionConfig.Origins.Items[].CustomOriginConfig.{readTimeout:OriginReadTimeout,keepAlive:OriginKeepaliveTimeout}'
```
**Root cause**: origin response slower than `OriginReadTimeout` (default 30s, max 60s without a quota increase).
**Fix**: speed up origin, add Origin Shield to absorb load, or raise the read timeout (and request a quota bump for >60s). For long downloads use streaming and ensure keep-alive is generous.

## 4. 503 Service Unavailable

- Origin itself returned 503 (overloaded) → scale origin / add autoscaling / Origin Shield.
- AWS WAF associated with the distribution blocked/rate-limited → check WAF sampled requests:
  ```bash
  aws wafv2 get-sampled-requests --web-acl-arn <arn> --rule-metric-name <rule> --scope CLOUDFRONT \
    --time-window StartTime=...,EndTime=... --max-items 100 --region us-east-1
  ```
- CloudFront capacity error (`x-edge-detailed-result-type: OriginConnectError`) → transient; retry, add Origin Shield.

## 5. Low cache hit ratio (the deep version)

The cache key is the tuple CloudFront hashes to decide "have I seen this exact request?" Anything in it that varies per user/request multiplies cache entries.

**Audit**
```bash
CP=$(aws cloudfront get-distribution-config --id E123 --query 'DistributionConfig.DefaultCacheBehavior.CachePolicyId' --output text)
aws cloudfront get-cache-policy --id "$CP" \
  --query 'CachePolicy.CachePolicyConfig.ParametersInCacheKeyAndForwardedToOrigin.{qs:QueryStringsConfig,h:HeadersConfig,c:CookiesConfig}'
```
Then in Athena, find the cold paths and the offending query strings:
```sql
SELECT uri, query,
       SUM(CASE WHEN result_type='Miss' THEN 1 ELSE 0 END) AS misses, COUNT(*) reqs
FROM cf_logs WHERE "date" = current_date - interval '1' day
GROUP BY uri, query ORDER BY misses DESC LIMIT 50;
```
If the high-miss rows differ only by `utm_*`/`fbclid`/`gclid`, those tracking params are in the cache key.

**Cache-key hygiene table**

| In cache key? | Field | Rationale |
|---|---|---|
| No | `utm_*`, `fbclid`, `gclid`, `_ga` | tracking; never changes the body |
| No | `Authorization`, `Cookie` (on static assets) | per-user; forks cache infinitely |
| Maybe | `Accept-Encoding` | only if you serve pre-compressed variants; else let CloudFront's `compress=true` handle it |
| Yes | `?v=`, `?lang=`, `?format=` | genuinely change the response body |
| Yes | `Origin` (for CORS resources) | response varies by origin |

**Cache key vs forwarded-to-origin**: a Cache Policy controls the *key*; an Origin Request Policy controls what's *forwarded to the origin* without entering the key. Forward `Authorization` to origin (origin request policy) so the origin can authorize, but keep it OUT of the cache key for cacheable resources.

## 6. TTL precedence (which value actually binds)

```
                      origin sends Cache-Control: max-age / s-maxage / Expires?
                                 │
              ┌──────────────────┴───────────────────┐
             YES                                     NO
              │                                       │
   clamp to [MinTTL, MaxTTL]                    use DefaultTTL
   (s-maxage wins over max-age for shared cache)
```
- `MinTTL` is the floor — a huge MinTTL pins objects even if origin says `max-age=0`.
- `MaxTTL` is the ceiling.
- `DefaultTTL` only applies when the origin sends no caching directive.
- `Cache-Control: no-cache` → revalidate every time (`RefreshHit`), not "don't cache".
- `Cache-Control: no-store` / `private` → don't cache at the edge.

## 7. Signed URL / signed cookie failures

| Signature | Cause | Fix |
|---|---|---|
| `Missing Key-Pair-Id` | request unsigned but behavior requires it | sign the URL; or confirm Key Group attached |
| `AccessDenied` (policy) | signature uses wrong private key | re-sign with the key paired to the uploaded public key |
| 403 too soon | `Expires` past / server clock skew | sync NTP; recompute future epoch |
| custom policy ignored | used `Expires=` with a custom policy | custom policy must pass `Policy=` (base64) + `Signature=`, no `Expires=` |
| cookies not applied | scope mismatch | cookie `Domain`/`Path`/`Secure` must match the request to the distribution over HTTPS |

Modern setup = **Key Groups** (public key uploaded to CloudFront, referenced by a key group, attached to the behavior as `TrustedKeyGroups`). Legacy "trusted signer" (root account CloudFront key pairs) is deprecated.

## 8. CORS through the CDN

Sequence that breaks it:
1. First request arrives with no `Origin` header.
2. Origin responds without `Access-Control-Allow-Origin`.
3. CloudFront caches that header-less response under a key that doesn't include `Origin`.
4. Subsequent cross-origin requests match the same key → get the cached, CORS-less response → browser blocks.

Fixes (any one):
- Add `Origin` to the **cache key** so cross-origin and same-origin responses cache separately, AND forward it via the origin request policy so the origin can echo it.
- Attach a managed **Response Headers Policy** (`CORS-with-preflight…`) to set ACAO at the edge regardless of origin.
- Ensure `OPTIONS` is in `AllowedMethods` for preflight.

## 9. Redirect loops

| Setup | Loop | Fix |
|---|---|---|
| Viewer policy `redirect-to-https` + origin protocol `http-only` + origin 301s HTTP→HTTPS | CF → origin (HTTP) → 301 → CF … | set origin protocol `https-only`/`match-viewer`, or remove origin redirect |
| S3 website redirect rules + CF redirect | mutual redirect | pick one redirect owner |

Trace with `curl -sSIL` and read every `Location`.

## 10. Geo restriction

CloudFront's GeoRestriction uses the **edge POP**'s GeoIP, exposed to origin via the `CloudFront-Viewer-Country` header (must be forwarded). A VPN user or a POP whose IP geolocates oddly can be (un)blocked unexpectedly. For nuanced rules use a CloudFront Function reading `CloudFront-Viewer-Country` rather than the blunt allow/deny list.

## 11. x-edge-detailed-result-type cheat sheet (in access logs / real-time logs)

| Value | Meaning |
|---|---|
| `Hit` / `Miss` / `RefreshHit` | normal cache outcomes |
| `OriginShieldHit` | served from Origin Shield regional cache |
| `LimitExceeded` | request throttled |
| `CapacityExceeded` | edge capacity (transient 503) |
| `OriginConnectError` / `OriginReadError` | couldn't reach / read origin (→ 502/504) |
| `MissGenerationError` | error while fetching from origin |
| `ClientCommError` / `Error` | client-side or generic error |

Real-time logs (Kinesis Data Streams) give second-level granularity vs standard logs' minutes; configure fields incl. `cs-uri-stem`, `x-edge-result-type`, `time-to-first-byte` for live debugging.
