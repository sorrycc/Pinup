// Package hosts sends prepared files to the places uploads go: an
// S3-compatible bucket or any HTTP upload API.
package hosts

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"strconv"
	"strings"
	"time"

	"pinup/internal/imageproc"
)

// ErrorKind says what went wrong with an upload.
type ErrorKind int

const (
	// NotConfigured is fixed in Settings rather than by trying again.
	NotConfigured ErrorKind = iota
	Processing
	HTTP
	BadResponse
)

// Error is an upload's failure, with a message to show.
type Error struct {
	Kind    ErrorKind
	Message string
	Status  int // for HTTP
}

func (e *Error) Error() string {
	if e.Kind == HTTP {
		if e.Message == "" {
			return fmt.Sprintf("The server answered %d %s.", e.Status, http.StatusText(e.Status))
		}
		msg := e.Message
		if r := []rune(msg); len(r) > 200 {
			msg = string(r[:200])
		}
		return fmt.Sprintf("The server answered %d: %s", e.Status, msg)
	}
	return e.Message
}

// NeedsSettings reports whether err is fixed in Settings rather than by
// trying again: a host not set up, or credentials refused.
func NeedsSettings(err error) bool {
	var e *Error
	if !errors.As(err, &e) {
		return false
	}
	return e.Kind == NotConfigured || e.Kind == HTTP && (e.Status == 401 || e.Status == 403)
}

func notConfigured(format string, args ...any) error {
	return &Error{Kind: NotConfigured, Message: fmt.Sprintf(format, args...)}
}

// Request is a request ready to send, with its body in a file so it
// streams from disk.
type Request struct {
	Method string
	URL    string
	Header http.Header
	// Body is the path of the file to send.
	Body string
	// Key is where the file lands on hosts that pick the path, like S3's
	// object key.
	Key string
}

// Host is somewhere files go. Hosts are values made from settings for
// each upload, then used off the main thread.
type Host interface {
	Name() string
	Request(file imageproc.File, scratch string) (*Request, error)
	// Link is the public link from the server's reply to a successful
	// request.
	Link(reply []byte, file imageproc.File, req *Request) (string, error)
}

// NoHost stands in when no host has been added, so an upload fails with a
// pointer to Settings.
type NoHost struct{}

func (NoHost) Name() string { return "No Host" }

func (NoHost) Request(imageproc.File, string) (*Request, error) {
	return nil, notConfigured("Add a host in Settings > Hosts.")
}

func (NoHost) Link([]byte, imageproc.File, *Request) (string, error) {
	return "", notConfigured("Add a host in Settings > Hosts.")
}

// ErrorText is the text of an error reply worth showing: JSON
// message/error/msg/detail, an S3 <Message>, or the start of the body.
func ErrorText(data []byte) string {
	var obj map[string]any
	if json.Unmarshal(data, &obj) == nil {
		for _, key := range []string{"message", "error", "msg", "detail"} {
			if s, ok := obj[key].(string); ok {
				return s
			}
			if nested, ok := obj[key].(map[string]any); ok {
				if s, ok := nested["message"].(string); ok {
					return s
				}
			}
		}
	}
	if len(data) > 2000 {
		data = data[:2000]
	}
	text := strings.ToValidUTF8(string(data), "�")
	if start := strings.Index(text, "<Message>"); start >= 0 {
		rest := text[start+len("<Message>"):]
		if end := strings.Index(rest, "</Message>"); end >= 0 {
			return rest[:end]
		}
	}
	return strings.TrimSpace(text)
}

// RenderPath fills {year}, {month}, {day}, {timestamp}, {random}, {name}
// (the file name without its extension) and {ext} in a path template.
func RenderPath(template, name string, now time.Time) string {
	ext := strings.TrimPrefix(path.Ext(name), ".")
	base := strings.TrimSuffix(name, path.Ext(name))
	var r [4]byte
	_, _ = rand.Read(r[:])
	local := now.Local()
	result := strings.NewReplacer(
		"{year}", fmt.Sprintf("%04d", local.Year()),
		"{month}", fmt.Sprintf("%02d", int(local.Month())),
		"{day}", fmt.Sprintf("%02d", local.Day()),
		"{timestamp}", strconv.FormatInt(now.Unix(), 10),
		"{random}", hex.EncodeToString(r[:]),
		"{name}", base,
		"{ext}", ext,
	).Replace(template)
	// A template without {ext} would lose the type.
	if !strings.Contains(template, "{ext}") && ext != "" &&
		!strings.HasSuffix(strings.ToLower(result), "."+strings.ToLower(ext)) {
		result += "." + ext
	}
	return strings.Trim(result, "/")
}

// writeBase64 writes prefix, then the file in base64, then suffix, without
// holding the file in memory.
func writeBase64(dst, prefix, file, suffix string) error {
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	in, err := os.Open(file)
	if err != nil {
		return err
	}
	defer in.Close()
	w := bufio.NewWriterSize(out, 1<<20)
	if _, err := w.WriteString(prefix); err != nil {
		return err
	}
	enc := base64.NewEncoder(base64.StdEncoding, w)
	if _, err := io.Copy(enc, in); err != nil {
		return err
	}
	if err := enc.Close(); err != nil {
		return err
	}
	if _, err := w.WriteString(suffix); err != nil {
		return err
	}
	if err := w.Flush(); err != nil {
		return err
	}
	return out.Close()
}

// escape percent-encodes every byte of s but ASCII letters, digits and
// the bytes in keep.
func escape(s, keep string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9' || strings.IndexByte(keep, c) >= 0 {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

func randomHex() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return strings.ToUpper(hex.EncodeToString(b[:]))
}
