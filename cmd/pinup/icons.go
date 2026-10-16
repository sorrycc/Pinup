package main

import (
	"bytes"
	_ "embed"
	"fmt"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

//go:embed assets/menubar.png
var menuBarPNG []byte

//go:embed assets/icon-256.png
var appIconPNG []byte

// lucide makes an icon of Lucide's paths, drawn in the color of the text.
func lucide(paths string) *ui.SVG {
	return ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">` + paths + `</svg>`))
}

var (
	iconCheck     = lucide(`<path d="M20 6 9 17l-5-5"/>`)
	iconAlert     = lucide(`<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>`)
	iconClipboard = lucide(`<rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/>`)
	iconFolder    = lucide(`<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>`)
	iconCopy      = lucide(`<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>`)
	iconOpen      = lucide(`<path d="M7 7h10v10"/><path d="M7 17 17 7"/>`)
	iconPlus      = lucide(`<path d="M5 12h14"/><path d="M12 5v14"/>`)
	iconPhotos    = lucide(`<path d="M18 22H4a2 2 0 0 1-2-2V6"/><path d="m22 13-1.296-1.296a2.41 2.41 0 0 0-3.408 0L11 18"/><circle cx="12" cy="8" r="2"/><rect width="16" height="16" x="6" y="2" rx="2"/>`)
	iconSearch    = lucide(`<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>`)
	iconPin       = lucide(`<path d="M12 17v5"/><path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z"/>`)
	iconKeyboard  = lucide(`<path d="M10 8h.01"/><path d="M12 12h.01"/><path d="M14 8h.01"/><path d="M16 12h.01"/><path d="M18 8h.01"/><path d="M6 8h.01"/><path d="M7 16h10"/><path d="M8 12h.01"/><rect width="20" height="16" x="2" y="4" rx="2"/>`)
	iconLink      = lucide(`<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>`)
	iconClear     = lucide(`<circle cx="12" cy="12" r="10"/><path d="m15 9-6 6"/><path d="m9 9 6 6"/>`)
	iconFile      = lucide(`<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/>`)
)

var appIcon = sync.OnceValue(func() *ui.Bitmap {
	b, _ := ui.DecodeBitmap(appIconPNG)
	return b
})

// MARK: Menu bar icons

// Looks of the menu bar icon other than the idle one, drawn as templates
// so that they match the menu bar in light and dark.
type look int

const (
	lookIdle look = iota
	lookDropTarget
	lookProgress
	lookDone
	lookFailed
)

var (
	iconCacheMu sync.Mutex
	iconCache   = map[[2]int][]byte{}
)

// trayImage is the PNG of a look, 18 points at twice that in pixels.
// Progress is cached in steps of 2%.
func trayImage(l look, progress float64) []byte {
	if l == lookIdle {
		return menuBarPNG
	}
	step := 0
	if l == lookProgress {
		step = int(math.Round(progress * 50))
	}
	key := [2]int{int(l), step}
	iconCacheMu.Lock()
	defer iconCacheMu.Unlock()
	if b, ok := iconCache[key]; ok {
		return b
	}
	img := ui.Render(func(c *ui.Context) {
		c.Root().Background(ui.Transparent)
		ui.Box(c).Size(18, 18).Draw(func(p *ui.Painter, r ui.Rect) {
			drawTrayIcon(p, r, l, float64(step)/50)
		})
	}, 18, 18, 2)
	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	iconCache[key] = buf.Bytes()
	return iconCache[key]
}

func drawTrayIcon(p *ui.Painter, r ui.Rect, l look, progress float64) {
	black := ui.RGB(0, 0, 0)
	cx, cy := r.X+9, r.Y+9
	circle := func(radius, width float32, c ui.Color) {
		p.StrokePath((&ui.Path{}).Circle(cx, cy, radius), width, c)
	}
	line := func(x0, y0, x1, y1, width float32) { p.Line(x0, y0, x1, y1, width, black) }
	dot := func(x, y, radius float32) { p.FillPath((&ui.Path{}).Circle(x, y, radius), black) }
	switch l {
	case lookProgress:
		// A ring that fills clockwise from the top, with an arrow inside.
		circle(7.5, 1.8, black.Alpha(0.25))
		end := max(0.04, progress)
		path := &ui.Path{}
		const steps = 64
		n := max(2, int(math.Ceil(end*steps)))
		for i := 0; i <= n; i++ {
			a := -math.Pi/2 + 2*math.Pi*end*float64(i)/float64(n)
			x, y := cx+7.5*float32(math.Cos(a)), cy+7.5*float32(math.Sin(a))
			if i == 0 {
				path.MoveTo(x, y)
			} else {
				path.LineTo(x, y)
			}
		}
		p.StrokePath(path, 1.8, black)
		// Round caps.
		for _, a := range []float64{-math.Pi / 2, -math.Pi/2 + 2*math.Pi*end} {
			dot(cx+7.5*float32(math.Cos(a)), cy+7.5*float32(math.Sin(a)), 0.9)
		}
		arrow(p, cx, cy, 3.3, 1.5)
	case lookDropTarget:
		// A painter draws nothing in the clear color, so where the system's
		// symbol cuts the arrow out of a disc this rings a bold arrow.
		circle(7.2, 1.6, black)
		arrow(p, cx, cy, 4, 2)
	case lookDone:
		circle(7.4, 1.5, black)
		path := (&ui.Path{}).MoveTo(cx-3.6, cy+0.2).LineTo(cx-1, cy+2.8).LineTo(cx+3.8, cy-2.6)
		p.StrokePath(path, 1.6, black)
	case lookFailed:
		path := (&ui.Path{}).MoveTo(cx, cy-7.2).LineTo(cx+8, cy+6.6).LineTo(cx-8, cy+6.6).Close()
		p.StrokePath(path, 1.5, black)
		line(cx, cy-2.4, cx, cy+2, 1.7)
		dot(cx, cy+4.4, 1)
	}
}

// arrow draws an upward arrow centered on cx, cy.
func arrow(p *ui.Painter, cx, cy, half, width float32) {
	black := ui.RGB(0, 0, 0)
	p.StrokePath((&ui.Path{}).MoveTo(cx, cy+half).LineTo(cx, cy-half), width, black)
	p.StrokePath((&ui.Path{}).MoveTo(cx-half*0.8, cy-half*0.2).LineTo(cx, cy-half).LineTo(cx+half*0.8, cy-half*0.2), width, black)
}

// MARK: Menu thumbnails

var (
	thumbMu    sync.Mutex
	menuThumbs = map[string][]byte{}
)

// menuThumbnail is a rounded 28-point thumbnail of an upload for its row
// of the menu, made the first time the menu shows it. Files without one
// get their type's icon at the same size, so every row's text starts at
// the same place.
func menuThumbnail(id, thumbPath, name string) []byte {
	thumbMu.Lock()
	defer thumbMu.Unlock()
	if b, ok := menuThumbs[id]; ok {
		return b
	}
	var out []byte
	if data, err := os.ReadFile(thumbPath); thumbPath != "" && err == nil {
		if bmp, err := ui.DecodeBitmap(data); err == nil {
			img := ui.Render(func(c *ui.Context) {
				c.Root().Background(ui.Transparent)
				ui.Box(c).Size(28, 28).Radius(6).Clip().Children(func() {
					ui.Image(c, bmp).Size(28, 28).Fit(ui.Cover)
				}).DrawOver(func(p *ui.Painter, r ui.Rect) {
					// A hairline inside the edge, so a white screenshot keeps
					// its shape on a light menu and a black one on a dark menu.
					p.Stroke(r, ui.RGBA(128, 128, 128, 0.35), 6, 1)
				})
			}, 28, 28, 2)
			var buf bytes.Buffer
			if png.Encode(&buf, img) == nil {
				out = buf.Bytes()
			}
		}
	}
	if out == nil {
		out = fileIcon(name, 56)
	}
	// The last few, so opening the menu again decodes nothing.
	if len(menuThumbs) > 24 {
		clear(menuThumbs)
	}
	menuThumbs[id] = out
	return out
}

var (
	fileIconMu sync.Mutex
	fileIcons  = map[string][]byte{}
)

// fileIcon is the system's icon for a file name's type, as a PNG of size
// pixels, for uploads that have no thumbnail: PDFs, movies, archives.
func fileIcon(name string, size int) []byte {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(name), "."))
	if !mygo.App.IsReady() {
		return nil // the system's icons need the app running
	}
	key := fmt.Sprintf("%s@%d", ext, size)
	fileIconMu.Lock()
	defer fileIconMu.Unlock()
	if b, ok := fileIcons[key]; ok {
		return b
	}
	// The icon is the type's, asked of an empty file of that extension.
	dir := filepath.Join(os.TempDir(), "Pinup-icons")
	_ = os.MkdirAll(dir, 0o755)
	stand := filepath.Join(dir, "file")
	if ext != "" {
		stand += "." + ext
	}
	if _, err := os.Stat(stand); err != nil {
		_ = os.WriteFile(stand, nil, 0o644)
	}
	b, err := mygo.Shell.FileIcon(stand, size)
	if err != nil {
		b = nil
	}
	fileIcons[key] = b
	return b
}

// fileIconBitmap is fileIcon as a bitmap for the views.
func fileIconBitmap(name string) *ui.Bitmap {
	ext := strings.ToLower(filepath.Ext(name))
	fileIconMu.Lock()
	if b, ok := iconBitmaps[ext]; ok {
		fileIconMu.Unlock()
		return b
	}
	fileIconMu.Unlock()
	data := fileIcon(name, 128)
	var bmp *ui.Bitmap
	if data != nil {
		bmp, _ = ui.DecodeBitmap(data)
	}
	fileIconMu.Lock()
	iconBitmaps[ext] = bmp
	fileIconMu.Unlock()
	return bmp
}

var iconBitmaps = map[string]*ui.Bitmap{}
