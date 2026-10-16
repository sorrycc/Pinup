// Package history keeps past uploads, newest first, in history.json, with
// a small thumbnail of each. It is loaded the first time something asks,
// and written a moment after changes, off the main thread.
package history

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"

	"pinup/internal/paths"
)

// Limit is how many uploads History keeps.
const Limit = 2000

// Time is a time written as Swift's ISO 8601 strategy wrote it, in UTC
// and to the second, so files of either version read in the other.
type Time struct{ time.Time }

func (t Time) MarshalJSON() ([]byte, error) {
	return json.Marshal(t.UTC().Format(time.RFC3339))
}

func (t *Time) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	parsed, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return err
	}
	t.Time = parsed
	return nil
}

// Entry is one finished upload.
type Entry struct {
	ID     string `json:"id"`
	URL    string `json:"url"`
	Name   string `json:"name"`
	Host   string `json:"host"`
	Size   int64  `json:"size"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
	Date   Time   `json:"date"`
	// Thumbnail is the file name in the thumbnails folder.
	Thumbnail string `json:"thumbnail,omitempty"`
}

// ThumbnailPath is the entry's thumbnail file, or "".
func (e Entry) ThumbnailPath() string {
	if e.Thumbnail == "" {
		return ""
	}
	return filepath.Join(paths.Thumbnails(), e.Thumbnail)
}

// Removed is an entry taken out, with its position, for Restore.
type Removed struct {
	Index int
	Entry Entry
}

// Store is the list of past uploads. Its methods are called on the main
// thread; it saves off it.
type Store struct {
	// OnChange is called after every change.
	OnChange func()

	loaded  bool
	entries []Entry
	timer   *time.Timer
	// changed says something changed since launch, so Flush has a file to
	// write.
	changed bool
	// generation counts the changes, so an older save never lands on a
	// newer one.
	generation int
	// savingDisabled is set when history.json is there but can't be read
	// or moved aside. Nothing is saved then, so the file is never
	// overwritten.
	savingDisabled bool
	// removedThumbnails are those of removed entries, deleted by
	// PruneThumbnails once undo is over.
	removedThumbnails map[string]bool
}

var (
	saveMu    sync.Mutex
	lastSaved int
)

// Entries are the uploads, newest first. The slice is the store's own.
func (s *Store) Entries() []Entry {
	if !s.loaded {
		s.loaded = true
		s.entries = s.load()
	}
	return s.entries
}

// Find returns the entry with the id.
func (s *Store) Find(id string) (Entry, bool) {
	for _, e := range s.Entries() {
		if e.ID == id {
			return e, true
		}
	}
	return Entry{}, false
}

// Add puts a batch of uploads, in the order they were given, on top.
func (s *Store) Add(batch []Entry) {
	if len(batch) == 0 {
		return
	}
	add := slices.Clone(batch)
	slices.Reverse(add)
	s.entries = append(add, s.Entries()...)
	s.trim()
	s.didChange()
}

// Remove takes entries out but keeps their thumbnails, so the removal can
// be undone; PruneThumbnails deletes them once undo is gone.
func (s *Store) Remove(ids map[string]bool) []Removed {
	var removed []Removed
	kept := make([]Entry, 0, len(s.Entries()))
	for i, e := range s.entries {
		if ids[e.ID] {
			removed = append(removed, Removed{i, e})
			if e.Thumbnail != "" {
				if s.removedThumbnails == nil {
					s.removedThumbnails = map[string]bool{}
				}
				s.removedThumbnails[e.Thumbnail] = true
			}
		} else {
			kept = append(kept, e)
		}
	}
	if len(removed) == 0 {
		return nil
	}
	s.entries = kept
	s.didChange()
	return removed
}

// Restore puts removed entries back in date order, newest first, so
// uploads made since stay on top.
func (s *Store) Restore(removed []Removed) {
	if len(removed) == 0 {
		return
	}
	present := map[string]bool{}
	for _, e := range s.Entries() {
		present[e.ID] = true
	}
	for _, r := range removed {
		if present[r.Entry.ID] {
			continue
		}
		i := slices.IndexFunc(s.entries, func(e Entry) bool { return e.Date.Before(r.Entry.Date.Time) })
		if i < 0 {
			i = len(s.entries)
		}
		s.entries = slices.Insert(s.entries, i, r.Entry)
		delete(s.removedThumbnails, r.Entry.Thumbnail)
	}
	s.trim()
	s.didChange()
}

// PruneThumbnails deletes the thumbnails of removed entries, once their
// removal can no longer be undone. Only those: never files an upload in
// progress wrote.
func (s *Store) PruneThumbnails() {
	doomed := s.doomedThumbnails()
	s.removedThumbnails = nil
	if len(doomed) > 0 {
		go removeThumbnails(doomed)
	}
}

// Clear removes every entry and its thumbnail.
func (s *Store) Clear() {
	var names []string
	for _, e := range s.Entries() {
		if e.Thumbnail != "" {
			names = append(names, e.Thumbnail)
		}
	}
	go removeThumbnails(names)
	s.entries = nil
	s.didChange()
}

// Flush saves now and deletes the thumbnails of removed uploads, for when
// Pinup quits: the delayed save and History's cleanup would never run.
func (s *Store) Flush() {
	if s.timer != nil {
		s.timer.Stop()
	}
	if !s.changed {
		return
	}
	if !s.savingDisabled {
		write(slices.Clone(s.entries), s.generation)
	}
	removeThumbnails(s.doomedThumbnails())
	s.removedThumbnails = nil
}

func (s *Store) doomedThumbnails() []string {
	used := map[string]bool{}
	for _, e := range s.Entries() {
		used[e.Thumbnail] = true
	}
	var doomed []string
	for name := range s.removedThumbnails {
		if !used[name] {
			doomed = append(doomed, name)
		}
	}
	return doomed
}

func (s *Store) trim() {
	if len(s.entries) <= Limit {
		return
	}
	var names []string
	for _, e := range s.entries[Limit:] {
		if e.Thumbnail != "" {
			names = append(names, e.Thumbnail)
		}
	}
	go removeThumbnails(names)
	s.entries = s.entries[:Limit:Limit]
}

func (s *Store) didChange() {
	s.changed = true
	s.generation++
	if s.timer != nil {
		s.timer.Stop()
	}
	if !s.savingDisabled {
		snapshot, generation := slices.Clone(s.entries), s.generation
		s.timer = time.AfterFunc(300*time.Millisecond, func() { write(snapshot, generation) })
	}
	if s.OnChange != nil {
		s.OnChange()
	}
}

// write saves one snapshot at a time, and never one older than what is on
// disk: a delayed save still encoding when Pinup quits must not undo the
// flush.
func write(entries []Entry, generation int) {
	saveMu.Lock()
	defer saveMu.Unlock()
	if generation <= lastSaved {
		return
	}
	if entries == nil {
		entries = []Entry{}
	}
	data, err := json.Marshal(entries)
	if err != nil {
		return
	}
	if paths.WriteAtomic(paths.History(), data, 0o644) == nil {
		lastSaved = generation
	}
}

func (s *Store) load() []Entry {
	data, err := os.ReadFile(paths.History())
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		s.setAsideUnreadable()
		return nil
	}
	var entries []Entry
	if err := json.Unmarshal(data, &entries); err != nil {
		s.setAsideUnreadable()
		return nil
	}
	return entries
}

// setAsideUnreadable never lets the next save overwrite a file that
// couldn't be read: it is moved aside, and if even that fails, saving is
// off until Pinup restarts.
func (s *Store) setAsideUnreadable() {
	backup := filepath.Join(paths.Root(), fmt.Sprintf("history-unreadable-%d.json", time.Now().Unix()))
	if os.Rename(paths.History(), backup) != nil {
		s.savingDisabled = true
	}
}

func removeThumbnails(names []string) {
	for _, name := range names {
		os.Remove(filepath.Join(paths.Thumbnails(), name))
	}
}

// Generation counts the changes, for views that keep what they worked out
// of the entries.
func (s *Store) Generation() int { return s.generation }
