// Package imageproc prepares files for upload: it converts images to JPEG
// or HEIC, removes their location and makes History's thumbnails, all
// through ImageIO, so nothing is decoded that doesn't need to be. It runs
// off the main thread.
package imageproc

import (
	"bytes"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"mime"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"pinup/internal/macos"
)

// Conversion is what an image is converted to before it is uploaded.
type Conversion string

const (
	Original Conversion = "original"
	JPEG     Conversion = "jpeg"
	HEIC     Conversion = "heic"
)

// Conversions lists them in the order Settings shows them.
var Conversions = []Conversion{Original, JPEG, HEIC}

// DisplayName is the conversion's name in Settings.
func (c Conversion) DisplayName() string {
	switch c {
	case JPEG:
		return "JPEG"
	case HEIC:
		return "HEIC"
	}
	return "Keep Original"
}

// Options says what to do to an image before upload.
type Options struct {
	Conversion    Conversion
	Quality       float64 // 0.1 to 1, for JPEG and HEIC
	StripLocation bool
}

// File is a file ready to upload, after any conversion.
type File struct {
	Path string
	// Name is the name to upload under, with the extension of the final
	// format.
	Name     string
	MIMEType string
	Size     int64
	// Width and Height are the pixel size, or zero for files that aren't
	// images.
	Width, Height int
	// Thumbnail is a small JPEG or PNG for History, nil for files that
	// aren't images.
	Thumbnail []byte
}

// ProcessingError is a conversion that failed.
type ProcessingError struct{ Message string }

func (e *ProcessingError) Error() string { return e.Message }

// ThumbnailPixels is enough for the widest History tile on a Retina
// display.
const ThumbnailPixels = 480

const (
	utiJPEG = "public.jpeg"
	utiPNG  = "public.png"
	utiHEIC = "public.heic"
)

var writable = sync.OnceValue(func() map[string]bool {
	m := map[string]bool{}
	for _, t := range macos.WritableTypes() {
		m[t] = true
	}
	return m
})

// Prepare converts src as options ask into a folder of scratch, and
// returns the file to upload, which may be src itself.
func Prepare(src, name string, opts Options, scratch string) (File, error) {
	source := macos.ImageSourceFile(src)
	if source == 0 {
		return passThrough(src, name)
	}
	defer macos.Release(source)
	kind := macos.SourceType(source)
	count := macos.SourceCount(source)
	if kind == "" || count == 0 {
		return passThrough(src, name)
	}
	props := macos.SourceProperties(source, 0)
	width, _ := macos.IntValue(macos.Get(props, macos.KeyPixelWidth))
	height, _ := macos.IntValue(macos.Get(props, macos.KeyPixelHeight))
	hasAlpha, _ := macos.BoolValue(macos.Get(props, macos.KeyHasAlpha))
	hasGPS := macos.Get(props, macos.KeyGPS) != 0
	macos.Release(props)
	thumbnail := makeThumbnail(source, hasAlpha)
	animated := count > 1

	target := targetType(opts.Conversion, kind, hasAlpha, animated)
	// ImageIO can't write WebP or camera RAW, so removing their location
	// means converting them: PNG keeps transparency, JPEG suits photos.
	if target == "" && opts.StripLocation && hasGPS && !writable()[kind] {
		target = utiJPEG
		if hasAlpha {
			target = utiPNG
		}
	}
	// A file with no extension gets the one its contents call for.
	if filepath.Ext(name) == "" {
		if ext := extensionFor(kind); ext != "" {
			name += "." + ext
		}
	}
	base := strings.TrimSuffix(name, filepath.Ext(name))
	// Outputs get their own folder, so one can never overwrite its source.
	outDir := filepath.Join(scratch, "out")
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return File{}, err
	}
	output, outputName := src, name

	switch {
	case target != "":
		// Re-encode: a new format, at the chosen quality, without GPS when asked.
		ext := extensionFor(target)
		outputName = base + "." + ext
		output = filepath.Join(outDir, outputName)
		dst := macos.DestinationFile(output, target)
		if dst == 0 {
			return File{}, &ProcessingError{fmt.Sprintf("Can't write %s images.", strings.ToUpper(ext))}
		}
		defer macos.Release(dst)
		quality := macos.Float(opts.Quality)
		defer macos.Release(quality)
		add := map[macos.Ref]macos.Ref{macos.KeyLossyQuality: quality}
		if opts.StripLocation && hasGPS {
			add[macos.KeyGPS] = macos.Null()
		}
		dict := macos.Dict(add)
		defer macos.Release(dict)
		macos.AddFromSource(dst, source, 0, dict)
		if !macos.Finalize(dst) {
			return File{}, &ProcessingError{fmt.Sprintf("Couldn't convert %s to %s.", name, strings.ToUpper(ext))}
		}
	case opts.StripLocation && hasGPS:
		// Same format, without GPS. JPEG metadata can be rewritten leaving
		// the pixels as they are; other formats are written again at full
		// quality, which is lossless for PNG and TIFF.
		output = filepath.Join(outDir, name)
		dst := macos.DestinationFile(output, kind)
		if dst == 0 {
			return passThrough(src, name)
		}
		defer macos.Release(dst)
		failed := &ProcessingError{fmt.Sprintf("Couldn't remove the location from %s.", name)}
		if kind == utiJPEG {
			dict := macos.Dict(map[macos.Ref]macos.Ref{macos.KeyExcludeGPS: macos.True()})
			defer macos.Release(dict)
			if !macos.CopySource(dst, source, dict) {
				return File{}, failed
			}
		} else {
			one := macos.Float(1)
			defer macos.Release(one)
			dict := macos.Dict(map[macos.Ref]macos.Ref{macos.KeyGPS: macos.Null(), macos.KeyLossyQuality: one})
			defer macos.Release(dict)
			macos.AddFromSource(dst, source, 0, dict)
			if !macos.Finalize(dst) {
				return File{}, failed
			}
		}
	}

	info, err := os.Stat(output)
	if err != nil {
		return File{}, err
	}
	return File{
		Path: output, Name: outputName, MIMEType: MIMEType(outputName), Size: info.Size(),
		Width: int(width), Height: int(height), Thumbnail: thumbnail,
	}, nil
}

// targetType is the type to convert to, or "" to keep the file's own.
// Transparent images stay out of JPEG, and animations stay as they are.
func targetType(c Conversion, current string, hasAlpha, animated bool) string {
	if animated {
		return ""
	}
	switch c {
	case JPEG:
		if hasAlpha || current == utiJPEG {
			return ""
		}
		return utiJPEG
	case HEIC:
		if current == utiHEIC {
			return ""
		}
		return utiHEIC
	}
	return ""
}

func passThrough(src, name string) (File, error) {
	info, err := os.Stat(src)
	if err != nil {
		return File{}, err
	}
	return File{Path: src, Name: name, MIMEType: MIMEType(name), Size: info.Size()}, nil
}

func makeThumbnail(source macos.Ref, hasAlpha bool) []byte {
	thumb := macos.Thumbnail(source, ThumbnailPixels)
	if thumb == 0 {
		return nil
	}
	defer macos.Release(thumb)
	kind := utiJPEG
	if hasAlpha {
		kind = utiPNG
	}
	return encode(thumb, kind, 0.8)
}

// encode writes a CGImage as kind.
func encode(img macos.Ref, kind string, quality float64) []byte {
	data := macos.MutableData()
	defer macos.Release(data)
	dst := macos.DestinationData(data, kind)
	if dst == 0 {
		return nil
	}
	defer macos.Release(dst)
	q := macos.Float(quality)
	defer macos.Release(q)
	props := macos.Dict(map[macos.Ref]macos.Ref{macos.KeyLossyQuality: q})
	defer macos.Release(props)
	macos.AddImage(dst, img, props)
	if !macos.Finalize(dst) {
		return nil
	}
	return macos.Bytes(data)
}

// PNG converts image data of any format ImageIO reads, such as the TIFF a
// pasteboard holds, to PNG.
func PNG(data []byte) ([]byte, error) {
	src := macos.ImageSourceData(data)
	if src == 0 {
		return nil, errors.New("not an image")
	}
	defer macos.Release(src)
	img := macos.SourceImage(src)
	if img == 0 {
		return nil, errors.New("not an image")
	}
	defer macos.Release(img)
	out := encode(img, utiPNG, 1)
	if out == nil {
		return nil, errors.New("couldn't encode PNG")
	}
	return out, nil
}

// TestImage is a 64-pixel PNG with a gradient, for testing a host.
func TestImage() []byte {
	const size = 64
	img := image.NewNRGBA(image.Rect(0, 0, size, size))
	from := [3]float64{255, 107, 92}
	to := [3]float64{250, 69, 140}
	for y := range size {
		for x := range size {
			t := float64(x+y) / float64(2*(size-1))
			img.Set(x, y, color.NRGBA{
				uint8(from[0] + (to[0]-from[0])*t), uint8(from[1] + (to[1]-from[1])*t),
				uint8(from[2] + (to[2]-from[2])*t), 255,
			})
		}
	}
	var b bytes.Buffer
	_ = png.Encode(&b, img)
	return b.Bytes()
}

var utiExtensions = map[string]string{
	"public.jpeg": "jpg", "public.png": "png", "com.compuserve.gif": "gif", "public.heic": "heic",
	"public.heif": "heif", "org.webmproject.webp": "webp", "public.tiff": "tiff", "com.microsoft.bmp": "bmp",
	"public.avif": "avif", "com.microsoft.ico": "ico", "com.apple.icns": "icns", "public.jpeg-2000": "jp2",
	"com.adobe.photoshop-image": "psd", "com.adobe.pdf": "pdf", "public.svg-image": "svg",
	"com.canon.cr2-raw-image": "cr2", "com.canon.cr3-raw-image": "cr3", "com.nikon.raw-image": "nef",
	"com.sony.arw-raw-image": "arw", "com.adobe.raw-image": "dng", "com.fuji.raw-image": "raf",
	"com.olympus.raw-image": "orf", "com.panasonic.rw2-raw-image": "rw2",
}

func extensionFor(uti string) string { return utiExtensions[uti] }

var mimeTypes = map[string]string{
	".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".gif": "image/gif",
	".heic": "image/heic", ".heif": "image/heif", ".webp": "image/webp", ".tif": "image/tiff",
	".tiff": "image/tiff", ".bmp": "image/bmp", ".avif": "image/avif", ".svg": "image/svg+xml",
	".ico": "image/vnd.microsoft.icon", ".psd": "image/vnd.adobe.photoshop", ".pdf": "application/pdf",
	".mp4": "video/mp4", ".m4v": "video/x-m4v", ".mov": "video/quicktime", ".webm": "video/webm",
	".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".wav": "audio/wav", ".zip": "application/zip",
	".json": "application/json", ".txt": "text/plain", ".md": "text/markdown", ".html": "text/html",
	".css": "text/css", ".js": "text/javascript", ".csv": "text/csv", ".xml": "application/xml",
	".dng": "image/x-adobe-dng", ".cr2": "image/x-canon-cr2", ".nef": "image/x-nikon-nef",
	".arw": "image/x-sony-arw",
}

// MIMEType is the type of a file name's extension, or
// application/octet-stream.
func MIMEType(name string) string {
	ext := strings.ToLower(filepath.Ext(name))
	if t, ok := mimeTypes[ext]; ok {
		return t
	}
	if t := mime.TypeByExtension(ext); t != "" {
		if mt, _, err := mime.ParseMediaType(t); err == nil {
			return mt
		}
		return t
	}
	return "application/octet-stream"
}
