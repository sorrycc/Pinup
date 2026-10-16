// Package capture turns the clipboard or a screenshot into files to
// upload. Each temporary file gets a folder of its own, so two quick
// captures never share a path.
package capture

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/transfer"

	"pinup/internal/paths"
	"pinup/internal/upload"
)

// Clipboard returns the files copied in Finder, or else the image on the
// clipboard written to a temporary file. Empty when it has neither. Call
// it off the main thread: a large image takes a while to cross from the
// app that copied it.
func Clipboard() []upload.Source {
	if files := Files(mustFiles()); len(files) > 0 {
		return files
	}
	native := mygo.Clipboard.AvailableFormats()
	// Formats worth keeping as they are, before TIFF, which MyGo reads as
	// PNG.
	type candidate struct {
		uti    string
		format transfer.Format
		ext    string
	}
	var candidates []candidate
	for _, c := range []candidate{
		{"public.png", transfer.PNG, "png"}, {"public.jpeg", "image/jpeg", "jpg"}, {"com.compuserve.gif", "image/gif", "gif"},
		{"public.heic", "image/heic", "heic"}, {"org.webmproject.webp", "image/webp", "webp"}, {"public.tiff", transfer.PNG, "png"},
	} {
		if slices.Contains(native, c.uti) {
			candidates = append(candidates, c)
		}
	}
	stamp := Stamp(time.Now())
	for _, c := range candidates {
		data, err := mygo.Clipboard.ReadFormat(c.format)
		if err != nil || len(data) == 0 {
			continue
		}
		path := filepath.Join(paths.Scratch(), "Pasted Image "+stamp+"."+c.ext)
		if os.WriteFile(path, data, 0o644) != nil {
			return nil
		}
		return []upload.Source{{Path: path, Name: filepath.Base(path), Temporary: true}}
	}
	return nil
}

func mustFiles() []string {
	files, _ := mygo.Clipboard.ReadFiles()
	return files
}

// Files are the paths given as sources, without folders.
func Files(list []string) []upload.Source {
	var out []upload.Source
	for _, p := range list {
		if info, err := os.Stat(p); err == nil && !info.IsDir() {
			out = append(out, upload.NewSource(p))
		}
	}
	return out
}

// Screenshot runs the system's interactive capture: drag for an area,
// Space for a window, Escape to cancel, which returns false. It blocks
// until the user is done.
func Screenshot() (upload.Source, bool) {
	dir := paths.Scratch()
	path := filepath.Join(dir, "Screenshot "+Stamp(time.Now())+".png")
	err := exec.Command("/usr/sbin/screencapture", "-i", "-x", path).Run()
	if _, statErr := os.Stat(path); err != nil || statErr != nil {
		os.RemoveAll(dir)
		return upload.Source{}, false
	}
	return upload.Source{Path: path, Name: filepath.Base(path), Temporary: true}, true
}

// Stamp is the time in a file name, as macOS names screenshots.
func Stamp(t time.Time) string { return t.Format("2006-01-02 at 15.04.05") }
