package imageproc

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"os"
	"slices"
)

// paletteSize is how many colors a compressed PNG keeps.
const paletteSize = 256

// compressPNG writes the PNG at src again with at most 256 colors, keeping
// its transparency and the chunks that say how to show its colors. Its
// other metadata, the location among it, is left out.
func compressPNG(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	img, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return err
	}
	var out bytes.Buffer
	enc := png.Encoder{CompressionLevel: png.BestCompression}
	if err := enc.Encode(&out, quantize(img)); err != nil {
		return err
	}
	return os.WriteFile(dst, withChunks(out.Bytes(), colorChunks(data)), 0o644)
}

// quantize reduces img to at most 256 colors. An image with that few keeps
// them exactly; any other gets a median-cut palette and Floyd–Steinberg
// dithering.
func quantize(img image.Image) *image.Paletted {
	b := img.Bounds()
	nrgba := image.NewNRGBA(b)
	draw.Draw(nrgba, b, img, b.Min, draw.Src)
	// Invisible pixels are all one color, whatever their RGB.
	for i := 0; i < len(nrgba.Pix); i += 4 {
		if nrgba.Pix[i+3] == 0 {
			clear(nrgba.Pix[i : i+4])
		}
	}
	if pal := exactColors(nrgba.Pix); pal != nil {
		return mapExact(nrgba, pal)
	}
	return dither(nrgba, medianCut(nrgba.Pix))
}

// pixel packs the RGBA, not premultiplied, at p[i:].
func pixel(p []uint8, i int) uint32 {
	return uint32(p[i])<<24 | uint32(p[i+1])<<16 | uint32(p[i+2])<<8 | uint32(p[i+3])
}

func unpack(c uint32) color.NRGBA {
	return color.NRGBA{uint8(c >> 24), uint8(c >> 16), uint8(c >> 8), uint8(c)}
}

// exactColors are the image's colors when there are 256 or fewer, or nil.
func exactColors(p []uint8) []uint32 {
	seen := map[uint32]bool{}
	var colors []uint32
	for i := 0; i < len(p); i += 4 {
		c := pixel(p, i)
		if seen[c] {
			continue
		}
		if len(colors) == paletteSize {
			return nil
		}
		seen[c] = true
		colors = append(colors, c)
	}
	return colors
}

func mapExact(img *image.NRGBA, colors []uint32) *image.Paletted {
	pal := make(color.Palette, len(colors))
	index := make(map[uint32]uint8, len(colors))
	for i, c := range colors {
		pal[i] = unpack(c)
		index[c] = uint8(i)
	}
	out := image.NewPaletted(img.Rect, pal)
	for i := 0; i < len(img.Pix); i += 4 {
		out.Pix[i/4] = index[pixel(img.Pix, i)]
	}
	return out
}

// bucket is the pixels whose colors share their top five bits on every
// channel.
type bucket struct {
	sum [4]uint64
	n   uint64
	// mode is a majority vote on the exact color, so a flat area keeps its
	// own color in the palette rather than its bucket's average.
	mode  uint32
	votes uint64
}

func (b *bucket) mean(ch int) uint64 { return b.sum[ch] / b.n }

func bucketKey(c uint32) uint32 {
	return (c>>27)<<15 | (c>>19&31)<<10 | (c>>11&31)<<5 | c>>3&31
}

// medianCut splits the image's colors into up to 256 boxes, each time
// halving the box with the widest spread by pixel count, and returns a
// color for each box.
func medianCut(p []uint8) []uint32 {
	index := map[uint32]int{}
	var buckets []*bucket
	for i := 0; i < len(p); i += 4 {
		c := pixel(p, i)
		k := bucketKey(c)
		j, ok := index[k]
		if !ok {
			j = len(buckets)
			index[k] = j
			buckets = append(buckets, &bucket{})
		}
		bk := buckets[j]
		for ch := range 4 {
			bk.sum[ch] += uint64(p[i+ch])
		}
		bk.n++
		switch {
		case bk.mode == c:
			bk.votes++
		case bk.votes == 0:
			bk.mode, bk.votes = c, 1
		default:
			bk.votes--
		}
	}

	boxes := []box{newBox(buckets)}
	for len(boxes) < paletteSize {
		best := -1
		for i, b := range boxes {
			if b.score > 0 && (best < 0 || b.score > boxes[best].score) {
				best = i
			}
		}
		if best < 0 {
			break
		}
		b := boxes[best]
		slices.SortFunc(b.buckets, func(x, y *bucket) int { return int(x.mean(b.ch)) - int(y.mean(b.ch)) })
		half, split := b.n/2, 1
		for acc := uint64(0); split < len(b.buckets)-1; split++ {
			if acc += b.buckets[split-1].n; acc >= half {
				break
			}
		}
		boxes[best] = newBox(b.buckets[:split:split])
		boxes = append(boxes, newBox(b.buckets[split:]))
	}

	colors := make([]uint32, len(boxes))
	for i, b := range boxes {
		colors[i] = representative(b.buckets)
	}
	return colors
}

// box is a run of buckets, with the channel it spreads most along and
// that spread times its pixel count, zero when it can't be split.
type box struct {
	buckets []*bucket
	n       uint64
	ch      int
	score   uint64
}

func newBox(buckets []*bucket) box {
	b := box{buckets: buckets}
	for _, bk := range buckets {
		b.n += bk.n
	}
	if len(buckets) < 2 {
		return b
	}
	var spread uint64
	for ch := range 4 {
		lo, hi := uint64(255), uint64(0)
		for _, bk := range buckets {
			m := bk.mean(ch)
			lo, hi = min(lo, m), max(hi, m)
		}
		if hi-lo > spread {
			b.ch, spread = ch, hi-lo
		}
	}
	b.score = spread * b.n
	return b
}

// representative is the box's average color, or the exact color of its
// heaviest bucket when that bucket holds most of the box's pixels.
func representative(box []*bucket) uint32 {
	var sum [4]uint64
	var n uint64
	heaviest := box[0]
	for _, b := range box {
		for ch := range 4 {
			sum[ch] += b.sum[ch]
		}
		n += b.n
		if b.n > heaviest.n {
			heaviest = b
		}
	}
	if heaviest.n*2 > n && heaviest.votes > 0 {
		return heaviest.mode
	}
	var c uint32
	for ch := range 4 {
		c = c<<8 | uint32((sum[ch]+n/2)/n)
	}
	return c
}

// dither maps every pixel to its nearest palette color, spreading the
// difference to the pixels after it. A pixel whose color is in the palette
// is kept exactly, so flat areas stay clean.
func dither(img *image.NRGBA, colors []uint32) *image.Paletted {
	pal := make(color.Palette, len(colors))
	exact := make(map[uint32]uint8, len(colors))
	for i, c := range colors {
		pal[i] = unpack(c)
		exact[c] = uint8(i)
	}
	// nearest remembers the palette index for each bucket of colors.
	nearest := make([]int16, 1<<20)
	for i := range nearest {
		nearest[i] = -1
	}
	lookup := func(c [4]int32) uint8 {
		k := bucketKey(uint32(c[0])<<24 | uint32(c[1])<<16 | uint32(c[2])<<8 | uint32(c[3]))
		if j := nearest[k]; j >= 0 {
			return uint8(j)
		}
		best, bestDist := 0, int32(1<<31-1)
		for i, p := range colors {
			var d int32
			for ch := range 4 {
				v := c[ch] - int32(p>>(24-8*ch)&255)
				d += v * v
			}
			if d < bestDist {
				best, bestDist = i, d
			}
		}
		nearest[k] = int16(best)
		return uint8(best)
	}

	b := img.Rect
	w := b.Dx()
	out := image.NewPaletted(b, pal)
	// Errors for this row and the next, with a pixel of margin each side.
	cur, next := make([][4]int32, w+2), make([][4]int32, w+2)
	for y := range b.Dy() {
		for x := range w {
			i := y*img.Stride + x*4
			orig := pixel(img.Pix, i)
			if j, ok := exact[orig]; ok {
				out.Pix[y*out.Stride+x] = j
				continue
			}
			var c [4]int32
			for ch := range 4 {
				c[ch] = min(255, max(0, int32(img.Pix[i+ch])+cur[x+1][ch]/16))
			}
			j := lookup(c)
			out.Pix[y*out.Stride+x] = j
			p := colors[j]
			for ch := range 4 {
				e := c[ch] - int32(p>>(24-8*ch)&255)
				cur[x+2][ch] += e * 7
				next[x][ch] += e * 3
				next[x+1][ch] += e * 5
				next[x+2][ch] += e
			}
		}
		cur, next = next, cur
		clear(next)
	}
	return out
}

// colorChunks are the chunks of a PNG that say how to show its colors and
// at what size: its color profile, gamma, chromaticities and resolution.
func colorChunks(data []byte) [][]byte {
	keep := map[string]bool{"iCCP": true, "sRGB": true, "gAMA": true, "cHRM": true, "pHYs": true}
	var chunks [][]byte
	for i := 8; i+12 <= len(data); {
		n := int(binary.BigEndian.Uint32(data[i:]))
		end := i + 12 + n
		if n < 0 || end > len(data) {
			break
		}
		kind := string(data[i+4 : i+8])
		if kind == "IDAT" || kind == "IEND" {
			break
		}
		if keep[kind] {
			chunks = append(chunks, data[i:end])
		}
		i = end
	}
	return chunks
}

// withChunks puts chunks into a PNG right after its header, where they
// must come before the palette and the pixels.
func withChunks(data []byte, chunks [][]byte) []byte {
	const afterIHDR = 8 + 12 + 13
	if len(chunks) == 0 || len(data) < afterIHDR {
		return data
	}
	out := slices.Clone(data[:afterIHDR])
	for _, c := range chunks {
		out = append(out, c...)
	}
	return append(out, data[afterIHDR:]...)
}
