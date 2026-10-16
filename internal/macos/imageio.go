//go:build darwin

package macos

import "github.com/ebitengine/purego"

var (
	cgImageSourceCreateWithURL           func(url, opts Ref) Ref
	cgImageSourceCreateWithData          func(data, opts Ref) Ref
	cgImageSourceGetType                 func(Ref) Ref
	cgImageSourceGetCount                func(Ref) int
	cgImageSourceCopyPropertiesAtIndex   func(src Ref, i int, opts Ref) Ref
	cgImageSourceCreateThumbnailAtIndex  func(src Ref, i int, opts Ref) Ref
	cgImageSourceCreateImageAtIndex      func(src Ref, i int, opts Ref) Ref
	cgImageDestinationCreateWithURL      func(url, kind Ref, count int, opts Ref) Ref
	cgImageDestinationCreateWithData     func(data, kind Ref, count int, opts Ref) Ref
	cgImageDestinationAddImageFromSource func(dst, src Ref, i int, props Ref)
	cgImageDestinationAddImage           func(dst, img, props Ref)
	cgImageDestinationFinalize           func(Ref) bool
	cgImageDestinationCopyImageSource    func(dst, src, opts Ref, err *Ref) bool
	cgImageDestinationCopyTypeIDs        func() Ref

	// Keys of ImageIO's dictionaries.
	KeyPixelWidth, KeyPixelHeight, KeyHasAlpha, KeyGPS          Ref
	KeyLossyQuality, KeyExcludeGPS                              Ref
	KeyThumbnailAlways, KeyThumbnailTransform, KeyThumbnailSize Ref
	KeyCacheImmediately                                         Ref
)

func loadImageIO() {
	reg := func(fn any, name string) { purego.RegisterLibFunc(fn, ioLib, name) }
	reg(&cgImageSourceCreateWithURL, "CGImageSourceCreateWithURL")
	reg(&cgImageSourceCreateWithData, "CGImageSourceCreateWithData")
	reg(&cgImageSourceGetType, "CGImageSourceGetType")
	reg(&cgImageSourceGetCount, "CGImageSourceGetCount")
	reg(&cgImageSourceCopyPropertiesAtIndex, "CGImageSourceCopyPropertiesAtIndex")
	reg(&cgImageSourceCreateThumbnailAtIndex, "CGImageSourceCreateThumbnailAtIndex")
	reg(&cgImageSourceCreateImageAtIndex, "CGImageSourceCreateImageAtIndex")
	reg(&cgImageDestinationCreateWithURL, "CGImageDestinationCreateWithURL")
	reg(&cgImageDestinationCreateWithData, "CGImageDestinationCreateWithData")
	reg(&cgImageDestinationAddImageFromSource, "CGImageDestinationAddImageFromSource")
	reg(&cgImageDestinationAddImage, "CGImageDestinationAddImage")
	reg(&cgImageDestinationFinalize, "CGImageDestinationFinalize")
	reg(&cgImageDestinationCopyImageSource, "CGImageDestinationCopyImageSource")
	reg(&cgImageDestinationCopyTypeIDs, "CGImageDestinationCopyTypeIdentifiers")
	KeyPixelWidth = constant(ioLib, "kCGImagePropertyPixelWidth")
	KeyPixelHeight = constant(ioLib, "kCGImagePropertyPixelHeight")
	KeyHasAlpha = constant(ioLib, "kCGImagePropertyHasAlpha")
	KeyGPS = constant(ioLib, "kCGImagePropertyGPSDictionary")
	KeyLossyQuality = constant(ioLib, "kCGImageDestinationLossyCompressionQuality")
	KeyExcludeGPS = constant(ioLib, "kCGImageMetadataShouldExcludeGPS")
	KeyThumbnailAlways = constant(ioLib, "kCGImageSourceCreateThumbnailFromImageAlways")
	KeyThumbnailTransform = constant(ioLib, "kCGImageSourceCreateThumbnailWithTransform")
	KeyThumbnailSize = constant(ioLib, "kCGImageSourceThumbnailMaxPixelSize")
	KeyCacheImmediately = constant(ioLib, "kCGImageSourceShouldCacheImmediately")
}

// ImageSourceFile opens an image file, or returns 0 for a file that isn't
// one. The caller releases it.
func ImageSourceFile(path string) Ref {
	load()
	url := FileURL(path)
	if url == 0 {
		return 0
	}
	defer Release(url)
	return cgImageSourceCreateWithURL(url, 0)
}

// ImageSourceData opens image data. The caller releases it.
func ImageSourceData(b []byte) Ref {
	load()
	d := Data(b)
	defer Release(d)
	return cgImageSourceCreateWithData(d, 0)
}

// SourceType is the source's uniform type identifier, like public.jpeg.
func SourceType(src Ref) string { return GoString(cgImageSourceGetType(src)) }

// SourceCount is the number of images in the source, more than one for an
// animation.
func SourceCount(src Ref) int { return cgImageSourceGetCount(src) }

// SourceProperties are the properties of an image of the source, which
// the caller releases.
func SourceProperties(src Ref, i int) Ref { return cgImageSourceCopyPropertiesAtIndex(src, i, 0) }

// Thumbnail makes a CGImage of at most maxPixels on its longer side, the
// right way up, which the caller releases.
func Thumbnail(src Ref, maxPixels int) Ref {
	size := Int(int64(maxPixels))
	defer Release(size)
	opts := Dict(map[Ref]Ref{KeyThumbnailAlways: True(), KeyThumbnailTransform: True(), KeyThumbnailSize: size})
	defer Release(opts)
	return cgImageSourceCreateThumbnailAtIndex(src, 0, opts)
}

// SourceImage decodes the first image of the source, which the caller
// releases.
func SourceImage(src Ref) Ref {
	opts := Dict(map[Ref]Ref{KeyCacheImmediately: True()})
	defer Release(opts)
	return cgImageSourceCreateImageAtIndex(src, 0, opts)
}

// WritableTypes are the types ImageIO can write.
func WritableTypes() []string {
	load()
	a := cgImageDestinationCopyTypeIDs()
	defer Release(a)
	return Strings(a)
}

// DestinationFile starts writing one image of type kind to path. The
// caller releases it.
func DestinationFile(path, kind string) Ref {
	load()
	url := FileURL(path)
	if url == 0 {
		return 0
	}
	defer Release(url)
	k := String(kind)
	defer Release(k)
	return cgImageDestinationCreateWithURL(url, k, 1, 0)
}

// DestinationData starts writing one image of type kind into data, a
// CFMutableData. The caller releases it.
func DestinationData(data Ref, kind string) Ref {
	k := String(kind)
	defer Release(k)
	return cgImageDestinationCreateWithData(data, k, 1, 0)
}

// AddFromSource adds the image at i of src, with props.
func AddFromSource(dst, src Ref, i int, props Ref) {
	cgImageDestinationAddImageFromSource(dst, src, i, props)
}

// AddImage adds a CGImage, with props.
func AddImage(dst, img, props Ref) { cgImageDestinationAddImage(dst, img, props) }

// Finalize writes the destination.
func Finalize(dst Ref) bool { return cgImageDestinationFinalize(dst) }

// CopySource writes src to dst with the metadata changes in opts, leaving
// the pixels as they are. The destination needs no Finalize then.
func CopySource(dst, src, opts Ref) bool {
	var err Ref
	ok := cgImageDestinationCopyImageSource(dst, src, opts, &err)
	Release(err)
	return ok
}
