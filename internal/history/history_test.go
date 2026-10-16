package history

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pinup/internal/paths"
)

func TestMain(m *testing.M) {
	dir, _ := os.MkdirTemp("", "pinup-history-test")
	paths.SetRoot(dir)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

func reset(t *testing.T) {
	t.Helper()
	os.RemoveAll(paths.Root())
	os.MkdirAll(paths.Root(), 0o755)
	saveMu.Lock()
	lastSaved = 0
	saveMu.Unlock()
}

func TestSwiftFormat(t *testing.T) {
	reset(t)
	swift := `[{"id":"5C1E7E6B-1F2A-4C8B-9E3D-7A6B5C4D3E2F","url":"https://x/a.png","name":"a.png","host":"R2","size":48000,"width":800,"height":600,"date":"2026-10-01T12:30:45Z","thumbnail":"5C1E7E6B-1F2A-4C8B-9E3D-7A6B5C4D3E2F.jpg"},` +
		`{"id":"6D2F8F7C-2A3B-4D9C-8F4E-8B7C6D5E4F3A","url":"https://x/b.pdf","name":"b.pdf","host":"R2","size":10,"width":0,"height":0,"date":"2026-09-30T08:00:00Z"}]`
	os.WriteFile(paths.History(), []byte(swift), 0o644)
	var s Store
	entries := s.Entries()
	if len(entries) != 2 || entries[0].Date.Year() != 2026 || entries[1].Thumbnail != "" {
		t.Fatalf("read Swift history: %+v", entries)
	}
	data, _ := json.Marshal(entries[1])
	if !strings.Contains(string(data), `"date":"2026-09-30T08:00:00Z"`) || strings.Contains(string(data), "thumbnail") {
		t.Errorf("written as Swift did: %s", data)
	}
}

func TestUnreadableSetAside(t *testing.T) {
	reset(t)
	os.WriteFile(paths.History(), []byte("not json"), 0o644)
	var s Store
	if len(s.Entries()) != 0 {
		t.Error("unreadable history starts empty")
	}
	names, _ := filepath.Glob(filepath.Join(paths.Root(), "history-unreadable-*"))
	if _, err := os.Stat(paths.History()); len(names) != 1 || err == nil {
		t.Errorf("set aside: %v", names)
	}
}

func TestFlushAndUndo(t *testing.T) {
	reset(t)
	now := Time{time.Unix(1_790_000_000, 0)}
	thumb := paths.NewID() + ".jpg"
	thumbFile := filepath.Join(paths.Thumbnails(), thumb)
	os.WriteFile(thumbFile, []byte("thumb"), 0o644)
	staying := Entry{ID: paths.NewID(), URL: "https://x/kept.png", Name: "kept.png", Date: now}
	gone := Entry{ID: paths.NewID(), URL: "https://x/gone.png", Name: "gone.png", Date: now, Thumbnail: thumb}
	var s Store
	s.Add([]Entry{staying, gone})
	if s.Entries()[0].ID != gone.ID {
		t.Error("the last of a batch is newest")
	}
	removed := s.Remove(map[string]bool{gone.ID: true})
	s.Restore(removed)
	if len(s.Entries()) != 2 {
		t.Error("restore")
	}
	s.Remove(map[string]bool{gone.ID: true})
	s.Flush()
	data, _ := os.ReadFile(paths.History())
	var saved []Entry
	json.Unmarshal(data, &saved)
	if len(saved) != 1 || saved[0].ID != staying.ID {
		t.Errorf("flush saves at once: %s", data)
	}
	if _, err := os.Stat(thumbFile); err == nil {
		t.Error("flush deletes removed thumbnails")
	}
}

func TestLimit(t *testing.T) {
	reset(t)
	var s Store
	batch := make([]Entry, Limit+5)
	for i := range batch {
		batch[i] = Entry{ID: paths.NewID(), Date: Time{time.Unix(int64(i), 0)}}
	}
	s.Add(batch)
	if len(s.Entries()) != Limit || s.Entries()[0].ID != batch[len(batch)-1].ID {
		t.Error("limit keeps the newest")
	}
}
