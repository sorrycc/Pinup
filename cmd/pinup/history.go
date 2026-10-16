package main

import (
	"fmt"
	"math"
	"os"
	"strings"
	"time"
	"unicode"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"
	"golang.org/x/text/runes"
	"golang.org/x/text/transform"
	"golang.org/x/text/unicode/norm"

	"pinup/internal/history"
	"pinup/internal/settings"
)

// historyWindow shows past uploads as a grid of thumbnails grouped by
// day. A click copies the link in the current format, a double click
// opens it, and files dropped on the window upload.
type historyWindow struct {
	a   *app
	win *mygo.Window

	query  string
	search ui.Handle
	grid   ui.Handle
	list   ui.ListState
	// selected are the chosen uploads by ID, anchor the one Shift-click
	// chooses from.
	selected map[string]bool
	anchor   string
	// flashes say "Copied …" over a tile for a moment.
	flashes map[string]flash
	// undo and redo hold removals, for ⌘Z and ⇧⌘Z. Undo ends with the
	// window, and the removed uploads' thumbnails go then.
	undo [][]history.Removed
	redo [][]history.Removed

	thumbs  map[string]*ui.Bitmap
	loading map[string]bool

	// rows are the list's rows, worked out again when the entries, the
	// search or the width change.
	rows    []historyRow
	rowsKey [3]any
	cols    int
	tileW   float32
	tileH   float32
}

type flash struct {
	text  string
	until time.Time
}

// historyRow is a day's header, or a row of tiles.
type historyRow struct {
	header  bool
	day     time.Time
	count   int
	entries []history.Entry
}

const (
	minTileWidth = 176
	maxTileWidth = 240
	tileGap      = 16
	rowGap       = 20
	sideInset    = 24
	// Tiles are 4:3, with two lines of text under them.
	tileTextHeight = 44
)

func (h *historyWindow) window() *mygo.Window {
	if h == nil {
		return nil
	}
	return h.win
}

func (a *app) showHistory() {
	mygo.App.Focus()
	if a.history != nil {
		a.history.win.Show()
		a.history.win.Focus()
		return
	}
	h := &historyWindow{a: a, selected: map[string]bool{}, flashes: map[string]flash{},
		thumbs: map[string]*ui.Bitmap{}, loading: map[string]bool{}}
	a.history = h
	h.win = mygo.NewWindow(mygo.WindowOptions{
		Title: "History", Width: 820, Height: 600, MinWidth: 440, MinHeight: 360, StateKey: "history",
		TitleBarStyle: mygo.TitleBarHidden, Content: ui.View(h.view),
	})
	h.win.OnClosed(func() {
		// Undo ends with the window, so removed uploads' thumbnails can go,
		// and a closed window holds no thumbnails.
		a.hist.PruneThumbnails()
		a.history = nil
		a.windowClosed()
	})
}

func (a *app) find() {
	if a.history != nil {
		a.history.search.Focus()
	}
}

func (h *historyWindow) view(c *ui.Context) {
	h.a.theme(c)
	t := c.Theme()
	w, _ := c.Size()
	h.layout(w)
	bar := c.TitleBar()

	ui.Column(c).Fill().Children(func() {
		// The toolbar, under the window controls.
		ui.Row(c).Height(max(bar.Height, 52)).Padding(0, bar.Right+16, 0, bar.Left+16).Gap(10).DragWindow().Children(func() {
			ui.Text(c, "History").Bold().FontSize(15)
			ui.Spacer(c)
			if iconButton(c, iconPlus, "Upload Files…").Clicked() {
				h.a.uploadFiles()
			}
			if ui.SearchField(c, &h.query).Placeholder("Search uploads").Label("Search uploads").Width(220).Bind(&h.search).Changed() {
				h.list.ScrollTo(0, ui.Start)
			}
		})
		ui.Divider(c)

		content := ui.Box(c).Grow(1).Focusable().FocusRing(false).Bind(&h.grid)
		if files := content.DroppedFiles(); files != nil {
			h.a.uploadPaths(files)
		}
		dragOver := content.FileDragOver()
		content.HandleInput(h.input)
		content.Children(func() {
			if len(h.rows) == 0 {
				h.emptyState(c)
			} else {
				h.list.Key = func(i int) any {
					if i >= len(h.rows) {
						return i
					}
					r := h.rows[i]
					if r.header {
						return "day " + r.day.Format(time.DateOnly)
					}
					return r.entries[0].ID
				}
				h.list.Header = func(i int) bool { return i < len(h.rows) && h.rows[i].header }
				ui.List(c, &h.list, len(h.rows), func(i int) { h.row(c, i) }).Fill()
			}
			if dragOver {
				// A glowing outline while files hover.
				ui.Box(c).Absolute().Top(8).Left(8).Right(8).Bottom(8).Radius(14).Border(3, t.Accent).
					Background(t.Accent.Alpha(0.08)).PassThrough()
			}
		})
	})
	// Flashes fade on their own.
	for id, f := range h.flashes {
		if left := time.Until(f.until); left <= 0 {
			delete(h.flashes, id)
		} else {
			c.After(left)
		}
	}
}

// layout works out the columns for a width, and the rows for them.
func (h *historyWindow) layout(width float32) {
	available := width - 2*sideInset
	fit := int((available + tileGap) / (minTileWidth + tileGap))
	needed := int(math.Ceil(float64((available + tileGap) / (maxTileWidth + tileGap))))
	cols := max(1, max(fit, needed))
	h.tileW = max(80, float32(math.Floor(float64((available-tileGap*float32(cols-1))/float32(cols)))))
	h.tileH = float32(math.Round(float64(h.tileW * 0.75)))
	key := [3]any{h.a.hist.Generation(), h.query, cols}
	if key == h.rowsKey && h.rows != nil {
		return
	}
	h.rowsKey, h.cols = key, cols
	h.rows = h.rows[:0]
	query := fold(strings.TrimSpace(h.query))
	var day []history.Entry
	var dayStart time.Time
	flush := func() {
		if len(day) == 0 {
			return
		}
		h.rows = append(h.rows, historyRow{header: true, day: dayStart, count: len(day)})
		for i := 0; i < len(day); i += cols {
			h.rows = append(h.rows, historyRow{entries: day[i:min(i+cols, len(day))]})
		}
		day = nil
	}
	for _, e := range h.a.hist.Entries() {
		if query != "" && !strings.Contains(fold(e.Name), query) && !strings.Contains(fold(e.URL), query) {
			continue
		}
		start := startOfDay(e.Date.Time)
		if !start.Equal(dayStart) {
			flush()
			dayStart = start
		}
		day = append(day, e)
	}
	flush()
}

// fold lowers text and takes its accents off, for search.
func fold(s string) string {
	t := transform.Chain(norm.NFD, runes.Remove(runes.In(unicode.Mn)), norm.NFC)
	out, _, err := transform.String(t, s)
	if err != nil {
		out = s
	}
	return strings.ToLower(out)
}

func (h *historyWindow) row(c *ui.Context, i int) {
	t := c.Theme()
	r := h.rows[i]
	if r.header {
		ui.Row(c).Height(40).Padding(0, sideInset+2).Gap(8).AlignItems(ui.End).PaddingY(10).Background(t.Background).Children(func() {
			ui.Text(c, dayTitle(r.day, time.Now())).Bold().FontSize(15)
			ui.Text(c, itoa(r.count)).TextColor(t.TextMuted).FontSize(13)
		})
		return
	}
	ui.Row(c).Padding(4, sideInset, rowGap-4, sideInset).Gap(tileGap).AlignItems(ui.Start).Children(func() {
		for _, e := range r.entries {
			h.tile(c, e)
		}
	})
}

// dayTitle names a day as Finder does: Today, Yesterday, the weekday and
// date this year, and the full date before.
func dayTitle(day, now time.Time) string {
	today := startOfDay(now)
	switch {
	case day.Equal(today):
		return "Today"
	case day.Equal(today.AddDate(0, 0, -1)):
		return "Yesterday"
	case day.Year() == now.Year():
		return day.Format("Monday, January 2")
	}
	return day.Format("January 2, 2006")
}

// tile is one upload: a rounded thumbnail with hover buttons, its name,
// and its size and time.
func (h *historyWindow) tile(c *ui.Context, e history.Entry) {
	t := c.Theme()
	id := e.ID
	tile := ui.Column(c.Key(id)).Width(h.tileW).Gap(6).Label(e.Name).Description("Copies the link. Press Return to open it.")
	hovered := tile.Hovered()
	if tile.Clicked() {
		h.grid.Focus()
		mods := tile.ClickModifiers()
		switch {
		case mods&ui.Cmd != 0:
			if h.selected[id] {
				delete(h.selected, id)
			} else {
				h.selected[id] = true
			}
			h.anchor = id
		case mods&ui.Shift != 0 && h.anchor != "":
			h.selectRange(h.anchor, id)
		default:
			clear(h.selected)
			h.selected[id] = true
			h.anchor = id
			h.copy([]string{id}, h.a.s.LinkFormat)
		}
	}
	if tile.DoubleClicked() {
		h.a.open(e.URL)
	}
	tile.DragData(dragLink(e, h.a.s.LinkFormat))
	tile.ContextMenu(func(m *ui.Menu) { h.menu(m, id) })
	tile.Children(func() {
		box := ui.Box(c).Width(h.tileW).Height(h.tileH).Radius(10).Clip().Background(t.Surface)
		if h.selected[id] {
			box.Border(3, t.Accent)
		} else {
			box.Border(1, t.Border.Alpha(0.6))
		}
		box.Children(func() {
			if bmp := h.thumbnail(e); bmp != nil {
				img := ui.Image(c, bmp).Fill().Fit(ui.Cover)
				img.Opacity(img.Animate("in", 1, 180*time.Millisecond))
			} else if e.Thumbnail == "" {
				if icon := fileIconBitmap(e.Name); icon != nil {
					ui.Box(c).Fill().Center().Children(func() {
						ui.Image(c, icon).Size(64, 64)
					})
				} else {
					ui.Box(c).Fill().Center().Children(func() {
						ui.Icon(c, iconFile).FontSize(40).TextColor(t.TextMuted)
					})
				}
			}
			if hovered {
				ui.Row(c).Absolute().Top(8).Right(8).Gap(6).Children(func() {
					if overlayButton(c, iconCopy, "Copy Link").Clicked() {
						h.copy([]string{id}, h.a.s.LinkFormat)
					}
					if overlayButton(c, iconOpen, "Open in Browser").Clicked() {
						h.a.open(e.URL)
					}
				})
			}
			if f, ok := h.flashes[id]; ok {
				ui.Box(c).Fill().Center().PassThrough().Children(func() {
					pill := ui.Row(c).Padding(6, 12).Radius(14).Background(ui.RGBA(0, 0, 0, 0.66)).Gap(6)
					pill.Opacity(pill.Animate("flash", 1, 120*time.Millisecond))
					pill.Children(func() {
						ui.Icon(c, iconCheck).FontSize(13).TextColor(ui.RGB(255, 255, 255))
						ui.Text(c, f.text).FontSize(12).Bold().TextColor(ui.RGB(255, 255, 255)).SingleLine()
					})
				})
			}
		})
		ui.Column(c).Height(tileTextHeight - 6).Gap(2).Children(func() {
			ui.Text(c, e.Name).FontSize(12).FontWeight(500).SingleLine().Ellipsis("…").Tooltip(e.URL)
			meta := []string{byteCount(e.Size)}
			if e.Width > 0 {
				meta = append(meta, fmt.Sprintf("%d×%d", e.Width, e.Height))
			}
			meta = append(meta, e.Date.Local().Format("3:04 PM"))
			ui.Text(c, strings.Join(meta, " · ")).FontSize(11).TextColor(t.TextMuted).SingleLine().Ellipsis("…")
		})
	})
}

// dragLink is what a tile drags out: its link, in the current format, and
// as a URL.
func dragLink(e history.Entry, format settings.LinkFormat) transfer.Data {
	return transfer.New(transfer.NewItem(
		transfer.Bytes(transfer.Text, []byte(format.Format(e.URL, e.Name))),
		transfer.Bytes(transfer.URIList, []byte(e.URL)),
	))
}

func (h *historyWindow) menu(m *ui.Menu, id string) {
	ids := []string{id}
	if h.selected[id] && len(h.selected) > 1 {
		ids = h.selectedIDs()
	}
	suffix := ""
	if len(ids) > 1 {
		suffix = fmt.Sprintf(" (%d)", len(ids))
	}
	for _, f := range settings.LinkFormats {
		if m.Item("Copy as " + f.DisplayName() + suffix).Chosen() {
			h.copy(ids, f)
		}
	}
	m.Separator()
	if m.Item("Open in Browser").Chosen() {
		for _, e := range h.entries(ids) {
			h.a.open(e.URL)
		}
	}
	m.Separator()
	if m.Item("Remove from History").Chosen() {
		h.remove(ids)
	}
}

// input takes the keys and edit commands of the grid.
func (h *historyWindow) input(ev ui.InputEvent) bool {
	switch ev.Kind {
	case ui.InputCommand:
		switch ev.Text {
		case "copy":
			h.copy(h.selectedIDs(), h.a.s.LinkFormat)
		case "delete":
			h.remove(h.selectedIDs())
		case "selectAll":
			for _, e := range h.visible() {
				h.selected[e.ID] = true
			}
		case "undo":
			h.undoRemove()
		case "redo":
			h.redoRemove()
		default:
			return false
		}
		return true
	case ui.InputKeyDown:
		switch {
		case ev.Mods == 0 && (ev.Key == ui.KeyBackspace || ev.Key == ui.KeyDelete):
			h.remove(h.selectedIDs())
		case ev.Mods == 0 && ev.Key == ui.KeyEnter:
			for _, e := range h.entries(h.selectedIDs()) {
				h.a.open(e.URL)
			}
		case ev.Mods == 0 && ev.Key == ui.KeyEscape && len(h.selected) > 0:
			clear(h.selected)
		case ev.Mods == ui.Cmd && ev.Key == ui.KeyC:
			h.copy(h.selectedIDs(), h.a.s.LinkFormat)
		case ev.Mods == ui.Cmd && ev.Key == ui.KeyA:
			for _, e := range h.visible() {
				h.selected[e.ID] = true
			}
		case ev.Mods == ui.Cmd && ev.Key == ui.KeyZ:
			h.undoRemove()
		case ev.Mods == ui.Cmd|ui.Shift && ev.Key == ui.KeyZ:
			h.redoRemove()
		default:
			return false
		}
		return true
	}
	return false
}

// visible are the uploads the search shows, in order.
func (h *historyWindow) visible() []history.Entry {
	var out []history.Entry
	for _, r := range h.rows {
		out = append(out, r.entries...)
	}
	return out
}

func (h *historyWindow) selectedIDs() []string {
	var ids []string
	for _, e := range h.visible() {
		if h.selected[e.ID] {
			ids = append(ids, e.ID)
		}
	}
	return ids
}

func (h *historyWindow) selectRange(from, to string) {
	list := h.visible()
	a, b := -1, -1
	for i, e := range list {
		if e.ID == from {
			a = i
		}
		if e.ID == to {
			b = i
		}
	}
	if a < 0 || b < 0 {
		return
	}
	clear(h.selected)
	for i := min(a, b); i <= max(a, b); i++ {
		h.selected[list[i].ID] = true
	}
}

func (h *historyWindow) entries(ids []string) []history.Entry {
	var out []history.Entry
	for _, id := range ids {
		if e, ok := h.a.hist.Find(id); ok {
			out = append(out, e)
		}
	}
	return out
}

// copy copies links, one per line, and says so over their tiles.
func (h *historyWindow) copy(ids []string, format settings.LinkFormat) {
	entries := h.entries(ids)
	if len(entries) == 0 {
		return
	}
	h.a.copyEntries(entries, format)
	until := time.Now().Add(1200 * time.Millisecond)
	for _, id := range ids {
		h.flashes[id] = flash{"Copied " + format.DisplayName(), until}
	}
}

// remove takes uploads out of History, with undo. The files stay on their
// host.
func (h *historyWindow) remove(ids []string) {
	if len(ids) == 0 {
		return
	}
	set := map[string]bool{}
	for _, id := range ids {
		set[id] = true
		delete(h.selected, id)
	}
	removed := h.a.hist.Remove(set)
	if len(removed) == 0 {
		return
	}
	h.undo = append(h.undo, removed)
	h.redo = nil
}

func (h *historyWindow) undoRemove() {
	if len(h.undo) == 0 {
		return
	}
	removed := h.undo[len(h.undo)-1]
	h.undo = h.undo[:len(h.undo)-1]
	h.a.hist.Restore(removed)
	h.redo = append(h.redo, removed)
}

func (h *historyWindow) redoRemove() {
	if len(h.redo) == 0 {
		return
	}
	removed := h.redo[len(h.redo)-1]
	h.redo = h.redo[:len(h.redo)-1]
	set := map[string]bool{}
	for _, r := range removed {
		set[r.Entry.ID] = true
	}
	if again := h.a.hist.Remove(set); len(again) > 0 {
		h.undo = append(h.undo, again)
	}
}

// thumbnail is an upload's decoded thumbnail, or nil while it is decoded
// off the main thread.
func (h *historyWindow) thumbnail(e history.Entry) *ui.Bitmap {
	if bmp, ok := h.thumbs[e.ID]; ok {
		return bmp
	}
	path := e.ThumbnailPath()
	if path == "" || h.loading[e.ID] {
		return nil
	}
	h.loading[e.ID] = true
	id := e.ID
	go func() {
		var bmp *ui.Bitmap
		if data, err := os.ReadFile(path); err == nil {
			bmp, _ = ui.DecodeBitmap(data)
		}
		h.a.post(func() {
			delete(h.loading, id)
			h.thumbs[id] = bmp
		})
	}()
	return nil
}

func (h *historyWindow) emptyState(c *ui.Context) {
	t := c.Theme()
	searching := strings.TrimSpace(h.query) != "" && len(h.a.hist.Entries()) > 0
	ui.Column(c).Fill().Center().Gap(8).Padding(24).Children(func() {
		icon, title, detail := iconPhotos, "No Uploads Yet", "Drop images here or on the menu bar pin"
		if searching {
			icon, title, detail = iconSearch, "No Results", "No upload's name or link has that text."
		} else if sc := h.a.s.ClipboardShortcut; sc != "" {
			detail += ", or press " + settings.ShortcutDisplay(sc) + " to upload what's on the clipboard."
		} else {
			detail += "."
		}
		ui.Icon(c, icon).FontSize(44).TextColor(t.TextMuted.Alpha(0.6)).Margin(0, 0, 6, 0)
		ui.Text(c, title).FontSize(17).Bold()
		ui.Text(c, detail).TextColor(t.TextMuted).TextAlign(ui.Center).MaxWidth(340)
		if !searching {
			if ui.Button(c, "Upload Files…").Margin(10, 0, 0, 0).Clicked() {
				h.a.uploadFiles()
			}
		}
	})
}

// iconButton is a toolbar button showing only an icon.
func iconButton(c *ui.Context, icon *ui.SVG, label string) ui.Element {
	b := ui.Button(c, "").Label(label).Tooltip(label).Padding(4, 8)
	b.Children(func() { ui.Icon(c, icon).FontSize(16) })
	return b
}

// overlayButton is a small round button over a thumbnail.
func overlayButton(c *ui.Context, icon *ui.SVG, label string) ui.Element {
	b := ui.Box(c).Size(26, 26).Radius(13).Center().Background(ui.RGBA(0, 0, 0, 0.55)).Cursor(ui.CursorPointer).
		Label(label).Tooltip(label).Role(ui.RoleButton)
	if b.Hovered() {
		b.Background(ui.RGBA(0, 0, 0, 0.75))
	}
	b.Children(func() { ui.Icon(c, icon).FontSize(14).TextColor(ui.RGB(255, 255, 255)) })
	return b
}
