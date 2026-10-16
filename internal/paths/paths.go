// Package paths says where Pinup keeps its files: ~/Library/Application
// Support/Pinup, or the folder in PINUP_HOME, so tests and screenshots can
// use their own.
package paths

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

var (
	rootOnce sync.Once
	root     string
)

// Root is Pinup's folder, created the first time it is asked for.
func Root() string {
	rootOnce.Do(func() {
		if home := os.Getenv("PINUP_HOME"); home != "" {
			root = expandTilde(home)
		} else {
			dir, err := os.UserConfigDir() // ~/Library/Application Support
			if err != nil {
				dir = filepath.Join(os.TempDir(), "Library", "Application Support")
			}
			root = filepath.Join(dir, "Pinup")
		}
		_ = os.MkdirAll(root, 0o755)
	})
	return root
}

// SetRoot points Pinup at another folder, for tests.
func SetRoot(dir string) {
	rootOnce.Do(func() {})
	root = dir
	_ = os.MkdirAll(root, 0o755)
}

// History is the file of past uploads.
func History() string { return filepath.Join(Root(), "history.json") }

// Settings is the file of preferences.
func Settings() string { return filepath.Join(Root(), "settings.json") }

// Secrets is the file of tokens and keys, readable by the user only.
func Secrets() string { return filepath.Join(Root(), "secrets.json") }

// Thumbnails is the folder of History's thumbnails.
func Thumbnails() string {
	dir := filepath.Join(Root(), "Thumbnails")
	_ = os.MkdirAll(dir, 0o755)
	return dir
}

// Failed is the folder of screenshots and pasted images whose upload
// failed, kept for a retry.
func Failed() string { return filepath.Join(Root(), "Failed") }

// ScratchPrefix starts the name of every scratch folder.
const ScratchPrefix = "Pinup-"

// Scratch makes a fresh folder for one upload's intermediate files, or for
// a pasted image or a screenshot, removed after it.
func Scratch() string {
	dir := filepath.Join(os.TempDir(), ScratchPrefix+NewID())
	_ = os.MkdirAll(dir, 0o755)
	return dir
}

// NewID returns a random UUID, in upper case as Swift's UUID wrote them.
func NewID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := strings.ToUpper(hex.EncodeToString(b[:]))
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}

func expandTilde(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, p[1:])
		}
	}
	return p
}

// ExpandTilde replaces a leading ~ with the home folder.
func ExpandTilde(p string) string { return expandTilde(p) }

// WriteAtomic writes data to a file beside path, then moves it over path,
// so a reader never sees half a file.
func WriteAtomic(path string, data []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+"-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
