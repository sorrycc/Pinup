# Hosts

Settings > Hosts picks where uploads go and holds each host's settings. Changes save as you type. Test Upload sends a small generated image and shows the link it got back, without adding it to History.

## pic.sorrycc.com

| Field | Meaning |
|---|---|
| Token | Sent as `Authorization: Bearer <token>` |

The file goes up as base64 inside a JSON body, and the server answers `{"data": "<url>"}`.

## S3-compatible

Pinup signs each upload with AWS Signature Version 4 and sends it as a single `PUT`.

| Field | Meaning |
|---|---|
| Endpoint | The service address, without the bucket |
| Region | The bucket's region. `auto` for R2 |
| Bucket | The bucket name |
| Path-style addressing | `endpoint/bucket/key` instead of `bucket.endpoint/key` |
| Access key, Secret key | An access key allowed to `PutObject` in the bucket |
| File path | Where files land in the bucket, from the placeholders below |
| Public URL | The address files are served from. Empty uses the object's own URL |

File path placeholders: `{year}` `{month}` `{day}` `{timestamp}` `{random}` `{name}` `{ext}`. The default is `{year}/{month}/{timestamp}-{random}.{ext}`. Put `{key}` in the public URL to place the path, as in `https://cdn.example.com/images/{key}`; otherwise the path is appended.

Pinup doesn't set object ACLs. Make the bucket, or a CDN in front of it, publicly readable for the links to work.

### Examples

| Service | Endpoint | Region | Path-style |
|---|---|---|---|
| Cloudflare R2 | `https://<account-id>.r2.cloudflarestorage.com` | `auto` | on |
| AWS S3 | `https://s3.<region>.amazonaws.com` | the bucket's region | off |
| Aliyun OSS | `https://oss-<region>.aliyuncs.com` | the region, like `oss-cn-hangzhou` | off |
| Tencent COS | `https://cos.<region>.myqcloud.com` | the region, like `ap-shanghai` | off |
| MinIO | `http://localhost:9000` | `us-east-1` | on |

For R2, set Public URL to the bucket's r2.dev address or your custom domain.

## Custom HTTP

For any upload API that takes a file in a request and returns a link.

| Field | Meaning |
|---|---|
| URL | Where to send the file. `{name}` is replaced by the file name |
| Request | `POST` or `PUT`, and how the file is sent |
| File field | The form field, or JSON key, that holds the file |
| Extra fields | More form fields or JSON keys, one `key=value` per line |
| Headers | Request headers, one `Name: value` per line |
| Link at | Where the link is in the JSON reply, like `data.url` or `data.0.src`. Empty takes the whole reply as text |
| Link prefix | Put before the value found, for APIs that return a path |

The three ways to send the file:

| Body | Request |
|---|---|
| Multipart Form | `multipart/form-data`, with the extra fields and the file |
| JSON with Base64 | A JSON object with the extra fields, the file in base64 under the file field, and `fileName` |
| Raw File | The file itself as the body, with its type as `Content-Type` |

### Example: an imgur-style API

| Field | Value |
|---|---|
| URL | `https://api.example.com/3/image` |
| Request | POST, Multipart Form |
| File field | `image` |
| Headers | `Authorization: Client-ID <your id>` |
| Link at | `data.link` |
