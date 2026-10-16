package hosts

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"pinup/internal/imageproc"
)

// Body is how the custom provider sends the file.
type Body string

const (
	Multipart Body = "multipart"
	JSON      Body = "json"
	Binary    Body = "binary"
)

// Bodies lists the ways to send the file, in the order Settings shows them.
var Bodies = []Body{Multipart, JSON, Binary}

// DisplayName is the body's name in Settings.
func (b Body) DisplayName() string {
	switch b {
	case JSON:
		return "JSON with Base64"
	case Binary:
		return "Raw File"
	}
	return "Multipart Form"
}

// CustomConfig is any HTTP upload API, described in settings. Headers,
// which usually carry the token, are in the secrets.
type CustomConfig struct {
	// URL is where to send the file; {name} is replaced by the file's name.
	URL    string `json:"url"`
	Method string `json:"method"`
	Body   Body   `json:"body"`
	// FileField is the form field or JSON key that holds the file.
	FileField string `json:"fileField"`
	// Fields are extra form fields or JSON keys, one key=value per line.
	Fields string `json:"fields"`
	// URLPath is where the link is in a JSON reply, like data.url or
	// data.links.0. Empty takes the whole reply as the link.
	URLPath string `json:"urlPath"`
	// URLPrefix goes before the value found, for APIs that return a path.
	URLPrefix string `json:"urlPrefix"`
}

// DefaultCustom is a new custom host's settings.
func DefaultCustom() CustomConfig {
	return CustomConfig{Method: "POST", Body: Multipart, FileField: "file", URLPath: "data.url"}
}

// Custom uploads to an HTTP API described by a CustomConfig.
type Custom struct {
	HostName string
	Config   CustomConfig
	// Headers are one "Name: value" per line.
	Headers string
}

func (h Custom) Name() string { return h.HostName }

// urlPathAllowed is what Foundation's urlPathAllowed leaves unescaped,
// besides letters and digits.
const urlPathAllowed = "!$&'()*+,-./:;=@_~"

func (h Custom) Request(file imageproc.File, scratch string) (*Request, error) {
	c := h.Config
	address := strings.ReplaceAll(strings.TrimSpace(c.URL), "{name}", escape(file.Name, urlPathAllowed))
	u, err := url.Parse(address)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return nil, notConfigured("Set the upload URL for %s in Settings > Hosts.", h.HostName)
	}
	method := strings.ToUpper(c.Method)
	if method == "" {
		method = "POST"
	}
	header := http.Header{}
	for _, line := range lines(h.Headers) {
		name, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		if name = strings.TrimSpace(name); name != "" {
			header.Set(name, strings.TrimSpace(value))
		}
	}
	fields := Pairs(c.Fields)
	field := c.FileField
	if field == "" {
		field = "file"
	}
	req := &Request{Method: method, URL: address, Header: header}
	switch c.Body {
	case Binary:
		header.Set("Content-Type", file.MIMEType)
		req.Body = file.Path
	case JSON:
		object := map[string]string{}
		for _, kv := range fields {
			if kv[0] != field {
				object[kv[0]] = kv[1]
			}
		}
		if _, ok := object["fileName"]; field != "fileName" && !ok {
			object["fileName"] = file.Name
		}
		// The other keys as JSON, then the file's key and its base64
		// streamed in last.
		prefix, err := marshal(object)
		if err != nil {
			return nil, err
		}
		prefix = prefix[:len(prefix)-1] // the closing brace
		if len(object) > 0 {
			prefix += ","
		}
		key, err := marshal(field)
		if err != nil {
			return nil, err
		}
		prefix += key + `:"`
		req.Body = filepath.Join(scratch, "body.json")
		if err := writeBase64(req.Body, prefix, file.Path, `"}`); err != nil {
			return nil, err
		}
		header.Set("Content-Type", "application/json")
	default:
		boundary := "Pinup-" + randomHex()
		req.Body = filepath.Join(scratch, "body.multipart")
		if err := writeMultipart(req.Body, boundary, fields, field, file); err != nil {
			return nil, err
		}
		header.Set("Content-Type", "multipart/form-data; boundary="+boundary)
	}
	return req, nil
}

func (h Custom) Link(reply []byte, file imageproc.File, req *Request) (string, error) {
	p := strings.TrimSpace(h.Config.URLPath)
	var found string
	if p == "" {
		found = strings.TrimSpace(string(reply))
	} else {
		dec := json.NewDecoder(bytes.NewReader(reply))
		dec.UseNumber()
		var v any
		if dec.Decode(&v) == nil {
			found = ValueAt(p, v)
		}
	}
	if found == "" {
		return "", &Error{Kind: BadResponse, Message: `No link at "` + p + `" in the reply: ` + ErrorText(reply)}
	}
	return h.Config.URLPrefix + found, nil
}

// ValueAt follows a dotted path through objects and arrays to a string
// or a number.
func ValueAt(p string, v any) string {
	for _, part := range strings.Split(p, ".") {
		if part == "" {
			continue
		}
		switch node := v.(type) {
		case map[string]any:
			v = node[part]
		case []any:
			i, err := strconv.Atoi(part)
			if err != nil || i < 0 || i >= len(node) {
				return ""
			}
			v = node[i]
		default:
			return ""
		}
	}
	switch value := v.(type) {
	case string:
		return value
	case json.Number:
		return value.String()
	case float64:
		return strconv.FormatFloat(value, 'f', -1, 64)
	case bool:
		if value {
			return "1"
		}
		return "0"
	}
	return ""
}

// Pairs reads one key=value per line, skipping lines without a key.
func Pairs(text string) [][2]string {
	var pairs [][2]string
	for _, line := range lines(text) {
		key, value, ok := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		if !ok || key == "" {
			continue
		}
		pairs = append(pairs, [2]string{key, strings.TrimSpace(value)})
	}
	return pairs
}

func lines(text string) []string {
	return strings.FieldsFunc(text, func(r rune) bool { return r == '\n' || r == '\r' })
}

func marshal(v any) (string, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return "", err
	}
	return strings.TrimSuffix(b.String(), "\n"), nil
}

// writeMultipart writes the form to disk, copying the file in.
func writeMultipart(dst, boundary string, fields [][2]string, field string, file imageproc.File) error {
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	w := bufio.NewWriterSize(out, 1<<20)
	for _, kv := range fields {
		w.WriteString("--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + kv[0] + "\"\r\n\r\n" + kv[1] + "\r\n")
	}
	quoted := strings.ReplaceAll(file.Name, `"`, "%22")
	w.WriteString("--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + field + "\"; filename=\"" + quoted + "\"\r\n")
	w.WriteString("Content-Type: " + file.MIMEType + "\r\n\r\n")
	in, err := os.Open(file.Path)
	if err != nil {
		return err
	}
	defer in.Close()
	if _, err := io.Copy(w, in); err != nil {
		return err
	}
	w.WriteString("\r\n--" + boundary + "--\r\n")
	if err := w.Flush(); err != nil {
		return err
	}
	return out.Close()
}
