package hosts

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"pinup/internal/imageproc"
)

// S3Config is an S3-compatible bucket: AWS S3, Cloudflare R2, Aliyun OSS,
// Tencent COS, MinIO and the like. The secret key is in the secrets.
type S3Config struct {
	// Endpoint is like https://s3.us-east-1.amazonaws.com or
	// https://<account>.r2.cloudflarestorage.com.
	Endpoint string `json:"endpoint"`
	// Region is "auto" for R2.
	Region      string `json:"region"`
	Bucket      string `json:"bucket"`
	AccessKeyID string `json:"accessKeyID"`
	// PathStyle is endpoint/bucket/key instead of bucket.endpoint/key. R2
	// and MinIO need it.
	PathStyle   bool   `json:"pathStyle"`
	KeyTemplate string `json:"keyTemplate"`
	// PublicURL is the address files are public at, such as a CDN domain.
	// Empty uses the object's own URL. {key} places the key; without it
	// the key is appended.
	PublicURL string `json:"publicURL"`
}

// DefaultS3 is a new S3 host's settings.
func DefaultS3() S3Config {
	return S3Config{Region: "us-east-1", PathStyle: true, KeyTemplate: "{year}/{month}/{timestamp}-{random}.{ext}"}
}

// S3 uploads with a single PUT signed with AWS Signature Version 4.
type S3 struct {
	HostName string
	Config   S3Config
	Secret   string
}

func (h S3) Name() string { return h.HostName }

func (h S3) Request(file imageproc.File, scratch string) (*Request, error) {
	return h.Sign(file, RenderPath(h.Config.KeyTemplate, file.Name, time.Now()), time.Now())
}

// Sign signs a PUT of file to key as of now.
func (h S3) Sign(file imageproc.File, key string, now time.Time) (*Request, error) {
	c := h.Config
	u, err := url.Parse(strings.TrimSpace(c.Endpoint))
	if err != nil || u.Scheme == "" || u.Hostname() == "" || c.Bucket == "" || c.AccessKeyID == "" || h.Secret == "" {
		return nil, notConfigured("Fill in the endpoint, bucket and keys for %s in Settings > Hosts.", h.HostName)
	}
	parts := strings.Split(key, "/")
	for i, p := range parts {
		parts[i] = uriEncode(p)
	}
	encodedKey := strings.Join(parts, "/")
	prefix := ""
	if base := strings.Trim(u.Path, "/"); base != "" {
		prefix = "/" + base
	}
	host := u.Hostname()
	var encodedPath string
	if c.PathStyle {
		encodedPath = prefix + "/" + uriEncode(c.Bucket) + "/" + encodedKey
	} else {
		host = c.Bucket + "." + host
		encodedPath = prefix + "/" + encodedKey
	}
	hostHeader := host
	if port := u.Port(); port != "" {
		hostHeader += ":" + port
	}
	target := u.Scheme + "://" + hostHeader + encodedPath

	amzDate := now.UTC().Format("20060102T150405Z")
	day := now.UTC().Format("20060102")
	region := c.Region
	if region == "" {
		region = "us-east-1"
	}
	payloadHash, err := sha256File(file.Path)
	if err != nil {
		return nil, err
	}
	headers := [][2]string{
		{"content-type", file.MIMEType},
		{"host", hostHeader},
		{"x-amz-content-sha256", payloadHash},
		{"x-amz-date", amzDate},
	}
	var names []string
	var canonicalHeaders strings.Builder
	for _, kv := range headers {
		names = append(names, kv[0])
		canonicalHeaders.WriteString(kv[0] + ":" + kv[1] + "\n")
	}
	signedHeaders := strings.Join(names, ";")
	canonicalRequest := strings.Join([]string{
		"PUT", encodedPath, "", canonicalHeaders.String(), signedHeaders, payloadHash,
	}, "\n")
	scope := day + "/" + region + "/s3/aws4_request"
	sum := sha256.Sum256([]byte(canonicalRequest))
	stringToSign := strings.Join([]string{"AWS4-HMAC-SHA256", amzDate, scope, hex.EncodeToString(sum[:])}, "\n")
	signingKey := []byte("AWS4" + h.Secret)
	for _, part := range []string{day, region, "s3", "aws4_request"} {
		signingKey = hmacSHA256(signingKey, part)
	}
	signature := hex.EncodeToString(hmacSHA256(signingKey, stringToSign))

	header := http.Header{}
	header.Set("Content-Type", file.MIMEType)
	header.Set("x-amz-content-sha256", payloadHash)
	header.Set("x-amz-date", amzDate)
	header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+c.AccessKeyID+"/"+scope+
		", SignedHeaders="+signedHeaders+", Signature="+signature)
	return &Request{Method: "PUT", URL: target, Header: header, Body: file.Path, Key: key}, nil
}

func (h S3) Link(reply []byte, file imageproc.File, req *Request) (string, error) {
	base := strings.TrimSpace(h.Config.PublicURL)
	if base == "" {
		return req.URL, nil
	}
	var parts []string
	for _, p := range strings.Split(req.Key, "/") {
		if p != "" {
			parts = append(parts, uriEncode(p))
		}
	}
	encodedKey := strings.Join(parts, "/")
	if strings.Contains(base, "{key}") {
		return strings.ReplaceAll(base, "{key}", encodedKey), nil
	}
	if strings.HasSuffix(base, "/") {
		return base + encodedKey, nil
	}
	return base + "/" + encodedKey, nil
}

// uriEncode is AWS's URI encoding: everything but unreserved characters.
func uriEncode(s string) string { return escape(s, "-._~") }

func hmacSHA256(key []byte, data string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(data))
	return m.Sum(nil)
}

// sha256File hashes a file without holding it in memory.
func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
