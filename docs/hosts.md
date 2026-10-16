# Hosts

A host is a named place uploads go, made from a provider: S3-compatible or Custom HTTP. Add as many as you like, such as two buckets or a bucket and an API, and switch between them.

In Settings > Hosts, the Upload to menu lists your hosts. **Add S3-Compatible…** and **Add Custom HTTP…** at its bottom create a new host, and **Remove** deletes the one shown along with its keys. The menu bar's Upload To menu switches hosts too. Each host's name appears in that menu and in History.

Changes save as you type. Test Upload sends a small generated image to the host shown and gives back the link it got, without adding it to History.

Addresses should be `https://`. Plain `http://` works too, for a MinIO or NAS on your own network, but sends your keys and files unencrypted.

## S3-compatible provider

Pinup signs each upload with AWS Signature Version 4 and sends it as a single `PUT`.

| Field | Meaning |
|---|---|
| Endpoint | The service address, without the bucket |
| Region | The bucket's region. `auto` for R2 |
| Bucket | The bucket name |
| Path-style addressing | `endpoint/bucket/key` instead of `bucket.endpoint/key` |
| Access key ID, Secret access key | An access key allowed to `PutObject` in the bucket |
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

## Custom HTTP provider

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

### Example: a token API with a JSON body

For an API that takes `{"fileName": …, "file": "<base64>"}` with a Bearer token and answers `{"data": "<url>"}`:

| Field | Value |
|---|---|
| URL | `https://images.example.com/api/upload` |
| Request | POST, JSON with Base64 |
| File field | `file` |
| Headers | `Authorization: Bearer <your token>` |
| Link at | `data` |
