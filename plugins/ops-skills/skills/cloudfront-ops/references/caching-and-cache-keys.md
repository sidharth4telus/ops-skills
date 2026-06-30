# Caching, cache keys, and invalidation strategy

The single biggest lever on CloudFront cost and performance is the cache key. This doc goes deep on getting it right, and on why versioned object keys beat invalidations.

## The mental model

```
Request ──► [ Cache Key ]  ──► hash ──► cache lookup
              ├─ host / path (always)
              ├─ query strings  (none | whitelist | all)
              ├─ headers         (none | whitelist | allViewer | allViewerAndWhitelistCloudFront)
              └─ cookies         (none | whitelist | all)

         [ Forwarded to origin ]  ── what the ORIGIN receives (superset is fine)
              controlled by the Origin Request Policy, NOT counted in the key
```

Two independent knobs:
- **Cache Policy** → defines the key + the TTLs. Wide key = low hit ratio.
- **Origin Request Policy** → defines what's forwarded to the origin. Forwarding more here does NOT hurt the hit ratio.

This separation lets you keep `Authorization` *out of the cache key* (so a cacheable asset is shared across users) while still *forwarding it to the origin* (so the origin can authorize the request).

## Managed policies (prefer these)

| Use case | Managed Cache Policy | Managed Origin Request Policy |
|---|---|---|
| Static assets, hashed names | `CachingOptimized` (`658327ea-f89d-4fab-a63d-7e88639e58f6`) | — |
| Static assets, also forward CORS to S3 | `CachingOptimized` | `CORS-S3Origin` |
| Don't cache (always to origin) | `CachingDisabled` | `AllViewer` |
| Pass everything to a dynamic origin | `CachingOptimizedForUncompressedObjects` or custom | `AllViewer` |

Look up the current IDs:
```bash
aws cloudfront list-cache-policies --type managed \
  --query 'CachePolicyList.Items[].CachePolicy.{name:CachePolicyConfig.Name,id:Id}' --output table
aws cloudfront list-origin-request-policies --type managed \
  --query 'OriginRequestPolicyList.Items[].OriginRequestPolicy.{name:OriginRequestPolicyConfig.Name,id:Id}' --output table
```

## Custom cache policy (Terraform) — tight key

```hcl
resource "aws_cloudfront_cache_policy" "api" {
  name        = "api-tight-key"
  default_ttl = 60
  max_ttl     = 300
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true

    query_strings_config {
      query_string_behavior = "whitelist"
      query_strings { items = ["v", "lang", "page"] }   # body-affecting only
    }
    headers_config {
      header_behavior = "whitelist"
      headers { items = ["Origin"] }                     # for CORS variance
    }
    cookies_config { cookie_behavior = "none" }          # cookies don't change body
  }
}

# Forward the auth header to origin WITHOUT putting it in the cache key:
resource "aws_cloudfront_origin_request_policy" "api" {
  name = "api-forward-auth"
  query_strings_config { query_string_behavior = "all" }
  headers_config {
    header_behavior = "whitelist"
    headers { items = ["Authorization", "Origin"] }
  }
  cookies_config { cookie_behavior = "none" }
}
```

## TTL: which value binds

| Origin sends | Behavior |
|---|---|
| `Cache-Control: max-age=600` | cached 600s, clamped to `[min_ttl, max_ttl]` |
| `Cache-Control: s-maxage=600, max-age=60` | shared caches (CloudFront) use 600 |
| `Cache-Control: no-cache` | revalidate each request (`RefreshHit` / 304) |
| `Cache-Control: no-store` or `private` | not cached at edge |
| nothing | `default_ttl` applies |
| `max-age=0` but `min_ttl=3600` | pinned 3600s — MinTTL floor wins |

## Versioned keys > invalidations (the core doctrine)

Two ways to push new content:

**A. Invalidation** — tell CloudFront "forget the cached copy of `/app.js`."
- Slow: propagation takes time.
- Rate-limited / billed: 1,000 free *paths* per month, then charged; `/*` rebuilds everything.
- Race-prone: in-flight requests may repopulate the old object if origin hasn't updated atomically.

**B. Versioned (fingerprinted) keys** — the file's name changes when its content changes: `app.a1b2c3d4.js`.
- The new HTML references the new filename. The old cached `app.<oldhash>.js` is simply never requested again.
- Zero invalidations, zero propagation wait, zero cost, no race.
- Set `Cache-Control: public, max-age=31536000, immutable` on fingerprinted assets — they can cache forever.
- Only the unversioned entry document (`index.html`) needs a short TTL (`max-age=60` or `no-cache`) and an occasional invalidation.

Build pipeline pattern:
```
dist/
  index.html                 ← references /assets/app.a1b2c3.js ; Cache-Control: no-cache
  assets/app.a1b2c3.js       ← Cache-Control: max-age=31536000, immutable
  assets/style.9f8e7d.css    ← Cache-Control: max-age=31536000, immutable
```
Vite, webpack (`[contenthash]`), esbuild, and most bundlers emit content hashes by default. Set the S3 `Cache-Control` per prefix (see SKILL.md deploy script).

## When you DO need invalidation

- Emergency content takedown (legal, security).
- Unversioned files that changed (`index.html`, `robots.txt`, `sitemap.xml`, `sw.js`).
- Origin config change that should drop the whole cache.

Make it idempotent — same finite path list every deploy, and wait for completion:
```bash
aws cloudfront create-invalidation --distribution-id E123 \
  --paths "/index.html" "/sw.js" "/robots.txt" \
  --query 'Invalidation.Id' --output text | \
  xargs -I{} aws cloudfront wait invalidation-completed --distribution-id E123 --id {}
```
Avoid `/*` except in genuine emergencies — it forces a full origin re-fetch storm.

## Compression

Set `compress = true` on the behavior and let CloudFront negotiate gzip/brotli — don't put `Accept-Encoding` in the cache key yourself (CloudFront normalizes it internally). Putting raw `Accept-Encoding` in the key fragments the cache by every browser variant.

## Measuring

```bash
aws cloudwatch get-metric-statistics --namespace AWS/CloudFront --metric-name CacheHitRate \
  --dimensions Name=DistributionId,Value=E123 Name=Region,Value=Global \
  --start-time "$(date -u -v-1d +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 3600 --statistics Average --region us-east-1
```
Target > 90% for static sites. Below that, audit the cache key first, TTLs second.
