package imageproc

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"pinup/internal/macos"
)

// fixture writes an 800x600 image of kind, with GPS data when asked, by
// re-encoding a generated PNG through ImageIO.
func fixture(t *testing.T, path, kind string, gps, alpha bool) {
	t.Helper()
	src := macos.ImageSourceData(testPNG(800, 600, alpha))
	defer macos.Release(src)
	dst := macos.DestinationFile(path, kind)
	defer macos.Release(dst)
	props := map[macos.Ref]macos.Ref{}
	if gps {
		lat, lon := macos.Float(30.27), macos.Float(120.15)
		n, e := macos.String("N"), macos.String("E")
		kLat, kLatRef, kLon, kLonRef := macos.String("Latitude"), macos.String("LatitudeRef"), macos.String("Longitude"), macos.String("LongitudeRef")
		g := macos.Dict(map[macos.Ref]macos.Ref{kLat: lat, kLatRef: n, kLon: lon, kLonRef: e})
		props[macos.KeyGPS] = g
	}
	d := macos.Dict(props)
	macos.AddFromSource(dst, src, 0, d)
	if !macos.Finalize(dst) {
		t.Fatal("fixture")
	}
	if gps && !hasGPS(path) {
		t.Logf("note: %s didn't keep GPS in the fixture", kind)
	}
}

func hasGPS(path string) bool {
	src := macos.ImageSourceFile(path)
	if src == 0 {
		return false
	}
	defer macos.Release(src)
	props := macos.SourceProperties(src, 0)
	defer macos.Release(props)
	return macos.Get(props, macos.KeyGPS) != 0
}

func TestPrepare(t *testing.T) {
	dir := t.TempDir()
	png := filepath.Join(dir, "photo.png")
	fixture(t, png, utiPNG, true, false)
	opts := Options{Conversion: Original, Quality: 0.8, StripLocation: true}

	stripped, err := Prepare(png, "photo.png", opts, filepath.Join(dir, "s1"))
	if err != nil {
		t.Fatal(err)
	}
	if stripped.Path == png || hasGPS(stripped.Path) || stripped.Name != "photo.png" {
		t.Errorf("strip GPS keeps format: %+v gps=%v", stripped.Path, hasGPS(stripped.Path))
	}
	if stripped.Thumbnail == nil || stripped.Width != 800 || stripped.Height != 600 {
		t.Errorf("thumbnail and size: %d×%d", stripped.Width, stripped.Height)
	}

	opts.Conversion = JPEG
	jpeg, err := Prepare(png, "photo.png", opts, filepath.Join(dir, "s2"))
	if err != nil || jpeg.Name != "photo.jpg" || jpeg.MIMEType != "image/jpeg" || hasGPS(jpeg.Path) {
		t.Errorf("convert to JPEG: %+v %v", jpeg.Name, err)
	}

	opts.Conversion = HEIC
	heic, err := Prepare(png, "photo.png", opts, filepath.Join(dir, "s3"))
	if err != nil || heic.Name != "photo.heic" || heic.Size == 0 {
		t.Errorf("convert to HEIC: %+v %v", heic.Name, err)
	}

	jpegFile := filepath.Join(dir, "gps.jpg")
	fixture(t, jpegFile, utiJPEG, true, false)
	opts.Conversion = Original
	clean, err := Prepare(jpegFile, "gps.jpg", opts, filepath.Join(dir, "s4"))
	if err != nil || hasGPS(clean.Path) || clean.Name != "gps.jpg" {
		t.Errorf("strip GPS from JPEG: %v gps=%v", err, hasGPS(clean.Path))
	}

	alpha := filepath.Join(dir, "alpha.png")
	fixture(t, alpha, utiPNG, false, true)
	opts.Conversion = JPEG
	kept, _ := Prepare(alpha, "alpha.png", opts, filepath.Join(dir, "s5"))
	if kept.Path != alpha || kept.Name != "alpha.png" {
		t.Errorf("transparent stays PNG: %+v", kept.Name)
	}

	bare := filepath.Join(dir, "noext")
	data, _ := os.ReadFile(png)
	os.WriteFile(bare, data, 0o644)
	opts.Conversion = Original
	named, _ := Prepare(bare, "noext", opts, filepath.Join(dir, "s6"))
	if named.Name != "noext.png" || named.MIMEType != "image/png" {
		t.Errorf("missing extension added: %q", named.Name)
	}

	text := filepath.Join(dir, "notes.txt")
	os.WriteFile(text, []byte("hi"), 0o644)
	opts.Conversion = JPEG
	plain, _ := Prepare(text, "notes.txt", opts, filepath.Join(dir, "s7"))
	if plain.Path != text || plain.MIMEType != "text/plain" || plain.Thumbnail != nil {
		t.Errorf("non-image passes through: %+v", plain)
	}
}

func TestPNGFromTIFF(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.tiff")
	fixture(t, path, "public.tiff", false, false)
	data, _ := os.ReadFile(path)
	out, err := PNG(data)
	if err != nil || len(out) < 8 || string(out[1:4]) != "PNG" {
		t.Errorf("PNG from TIFF: %v", err)
	}
}

func TestTestImage(t *testing.T) {
	if b := TestImage(); string(b[1:4]) != "PNG" {
		t.Error("test image is a PNG")
	}
}

func testPNG(w, h int, alpha bool) []byte {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	a := uint8(255)
	if alpha {
		a = 128
	}
	for y := range h {
		for x := range w {
			img.Set(x, y, color.NRGBA{51, 128, 230, a})
		}
	}
	var b bytes.Buffer
	png.Encode(&b, img)
	return b.Bytes()
}
