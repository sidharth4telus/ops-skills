# Signed URLs/cookies, OAC, and edge compute

Reference for access control (signed URLs, signed cookies, OAC) and edge compute (CloudFront Functions vs Lambda@Edge), with copy-pasteable IaC and signing code.

## Origin Access Control (OAC) — the modern S3 lock

OAC replaces the legacy OAI. It signs origin requests with SigV4 so only your distribution can read the bucket.

### Terraform
```hcl
resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "assets-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "AllowCloudFrontOAC"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.assets.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}
resource "aws_s3_bucket_policy" "assets" {
  bucket = aws_s3_bucket.assets.id
  policy = data.aws_iam_policy_document.bucket.json
}
```

### SSE-KMS buckets
Add to the KMS key policy so CloudFront can decrypt:
```json
{
  "Sid": "AllowCloudFrontDecrypt",
  "Effect": "Allow",
  "Principal": { "Service": "cloudfront.amazonaws.com" },
  "Action": ["kms:Decrypt", "kms:GenerateDataKey*"],
  "Resource": "*",
  "Condition": { "StringEquals": {
    "AWS:SourceArn": "arn:aws:cloudfront::111122223333:distribution/E123"
  }}
}
```

## Signed URLs (modern Key Group flow)

1. Generate an RSA key pair:
   ```bash
   openssl genrsa -out private_key.pem 2048
   openssl rsa -pubout -in private_key.pem -out public_key.pem
   ```
2. Upload the public key to CloudFront and put it in a **Key Group**:
   ```hcl
   resource "aws_cloudfront_public_key" "signer" {
     name        = "signer-key"
     encoded_key = file("public_key.pem")
   }
   resource "aws_cloudfront_key_group" "signers" {
     name  = "signers"
     items = [aws_cloudfront_public_key.signer.id]
   }
   ```
3. Reference the key group on the behavior:
   ```hcl
   default_cache_behavior {
     # ...
     trusted_key_groups = [aws_cloudfront_key_group.signers.id]
   }
   ```
4. Sign URLs server-side (Python, canned policy):
   ```python
   from datetime import datetime, timedelta, timezone
   from botocore.signers import CloudFrontSigner
   from cryptography.hazmat.primitives import hashes, serialization
   from cryptography.hazmat.primitives.asymmetric import padding

   def rsa_signer(message: bytes) -> bytes:
       with open("private_key.pem", "rb") as f:
           key = serialization.load_pem_private_key(f.read(), password=None)
       return key.sign(message, padding.PKCS1v15(), hashes.SHA1())

   signer = CloudFrontSigner("K2JCJMDEHXQW5F", rsa_signer)  # Key-Pair-Id = public key ID
   url = signer.generate_presigned_url(
       "https://dXXX.cloudfront.net/private/video.mp4",
       date_less_than=datetime.now(timezone.utc) + timedelta(hours=1),
   )
   ```

### Signed-URL failure quick map
| Error | Cause | Fix |
|---|---|---|
| `Missing Key-Pair-Id` | unsigned request to a protected behavior | sign it; verify Key Group attached |
| `AccessDenied` immediately | wrong private key / corrupt signature | re-sign with key paired to uploaded public key |
| works then 403 early | expired / clock skew | NTP-sync signer; recompute future `Expires` |
| custom policy ignored | passed `Expires=` not `Policy=` | use base64 `Policy=` + `Signature=` for custom policies |

## Signed cookies
Same key group, but you set three cookies (`CloudFront-Policy`, `CloudFront-Signature`, `CloudFront-Key-Pair-Id`) scoped to the distribution domain over HTTPS. Use for protecting many objects under a path prefix without re-signing each URL. The cookie `Domain`/`Path` must cover the requested objects, and `Secure` is required.

## CloudFront Functions vs Lambda@Edge

| Dimension | CloudFront Functions | Lambda@Edge |
|---|---|---|
| Events | viewer-request, viewer-response | viewer + origin request/response (4) |
| Language | JS (cloudfront-js-2.0, ~ES5.1 + some ES) | Node.js / Python full runtime |
| Max duration | < 1 ms | 5s (viewer), 30s (origin) |
| Package / code size | 10 KB | 1 MB (viewer) / 50 MB (origin) |
| Memory | fixed (2 MB) | 128 MB (viewer) up to 10 GB (origin) |
| Network / disk I/O | none | yes (origin events only) |
| Access request body | no | yes |
| Scale | millions/s, no cold start | cold starts, regional replication |
| Cost | ~1/6 of L@E per invocation | higher |
| Logging | KVS + CloudWatch (us-east-1 publish) | CloudWatch in the edge POP's region |

**Rule of thumb:** URL rewrites, header injection, simple auth-token checks, redirects, A/B routing → **CloudFront Functions**. Anything needing the request body, an external call, secrets, heavy logic, or origin manipulation → **Lambda@Edge**.

### CloudFront Function example (URL rewrite + security headers)
```javascript
// viewer-request: append index.html to "directory" paths
function handler(event) {
  var req = event.request;
  var uri = req.uri;
  if (uri.endsWith('/')) {
    req.uri = uri + 'index.html';
  } else if (!uri.includes('.')) {
    req.uri = uri + '/index.html';
  }
  return req;
}
```
```javascript
// viewer-response: add security headers cheaply at the edge
function handler(event) {
  var res = event.response;
  res.headers['strict-transport-security'] = { value: 'max-age=63072000; includeSubDomains; preload' };
  res.headers['x-content-type-options']    = { value: 'nosniff' };
  res.headers['x-frame-options']           = { value: 'DENY' };
  return res;
}
```
Deploy:
```bash
aws cloudfront create-function --name url-rewrite --function-config '{"Comment":"rewrite","Runtime":"cloudfront-js-2.0"}' \
  --function-code fileb://rewrite.js
aws cloudfront test-function --name url-rewrite --if-match <ETag> \
  --event-object fileb://test-event.json   # ALWAYS test before publish
aws cloudfront publish-function --name url-rewrite --if-match <ETag>
```

### Lambda@Edge gotchas
- Logs go to the **region of the executing edge POP**, log group `/aws/lambda/<region>.<function-name>`. Search multiple regions.
- The function must be in **us-east-1** to associate; CloudFront replicates it.
- You cannot delete a function version still associated with a distribution — disassociate, deploy, wait for replicas to drain (can take ~1 hour), then delete.
- Viewer events can't do network/disk I/O or see the body; only origin events can.
- Exceeding memory/time → `5xx` with `LambdaExecutionError` in logs.

## Response Headers Policy (set CORS/security headers without code)
```hcl
resource "aws_cloudfront_response_headers_policy" "sec" {
  name = "sec-and-cors"
  cors_config {
    access_control_allow_credentials = false
    access_control_allow_headers { items = ["*"] }
    access_control_allow_methods { items = ["GET", "HEAD", "OPTIONS"] }
    access_control_allow_origins { items = ["https://app.example.com"] }
    origin_override = true
  }
  security_headers_config {
    strict_transport_security { access_control_max_age_sec = 63072000 include_subdomains = true preload = true override = true }
    content_type_options { override = true }
    frame_options { frame_option = "DENY" override = true }
  }
}
```
Prefer this over a CloudFront Function/L@E when all you need is static headers — no code, no cold start.
