//go:build darwin

// Package macos calls the C APIs of CoreFoundation, ImageIO and the
// preferences system through purego, without cgo.
package macos

import (
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
)

// Ref is a CoreFoundation object: a CFTypeRef.
type Ref = uintptr

var (
	loadOnce sync.Once
	cfLib    uintptr
	ioLib    uintptr

	cfRelease                       func(Ref)
	cfRetain                        func(Ref) Ref
	cfGetTypeID                     func(Ref) uintptr
	cfStringGetTypeID               func() uintptr
	cfNumberGetTypeID               func() uintptr
	cfBooleanGetTypeID              func() uintptr
	cfDataGetTypeID                 func() uintptr
	cfStringCreateWithBytes         func(alloc Ref, bytes *byte, n int, encoding uint32, external bool) Ref
	cfStringGetLength               func(Ref) int
	cfStringGetMaximumSizeForEncode func(n int, encoding uint32) int
	cfStringGetCString              func(s Ref, buf *byte, size int, encoding uint32) bool
	cfNumberCreate                  func(alloc Ref, kind int, value unsafe.Pointer) Ref
	cfNumberGetValue                func(n Ref, kind int, value unsafe.Pointer) bool
	cfBooleanGetValue               func(Ref) bool
	cfDataCreate                    func(alloc Ref, bytes *byte, n int) Ref
	cfDataCreateMutable             func(alloc Ref, capacity int) Ref
	cfDataGetLength                 func(Ref) int
	cfDataGetBytePtr                func(Ref) *byte
	cfDictionaryCreate              func(alloc Ref, keys, values unsafe.Pointer, n int, keyCB, valueCB uintptr) Ref
	cfDictionaryGetValue            func(d, key Ref) Ref
	cfArrayGetCount                 func(Ref) int
	cfArrayGetValueAtIndex          func(a Ref, i int) Ref
	cfURLCreateFromFSRep            func(alloc Ref, path *byte, n int, isDir bool) Ref
	cfPreferencesCopyAppValue       func(key, app Ref) Ref
	cfPreferencesAppSynchronize     func(app Ref) bool

	kCFBooleanTrue, kCFBooleanFalse, kCFNull Ref
	dictKeyCallBacks, dictValueCallBacks     uintptr
)

const (
	utf8Encoding  = 0x08000100
	numberSInt64  = 4
	numberFloat64 = 13
)

func load() {
	loadOnce.Do(func() {
		var err error
		cfLib, err = purego.Dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err != nil {
			panic(err)
		}
		ioLib, err = purego.Dlopen("/System/Library/Frameworks/ImageIO.framework/ImageIO", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err != nil {
			panic(err)
		}
		reg := func(fn any, name string) { purego.RegisterLibFunc(fn, cfLib, name) }
		reg(&cfRelease, "CFRelease")
		reg(&cfRetain, "CFRetain")
		reg(&cfGetTypeID, "CFGetTypeID")
		reg(&cfStringGetTypeID, "CFStringGetTypeID")
		reg(&cfNumberGetTypeID, "CFNumberGetTypeID")
		reg(&cfBooleanGetTypeID, "CFBooleanGetTypeID")
		reg(&cfDataGetTypeID, "CFDataGetTypeID")
		reg(&cfStringCreateWithBytes, "CFStringCreateWithBytes")
		reg(&cfStringGetLength, "CFStringGetLength")
		reg(&cfStringGetMaximumSizeForEncode, "CFStringGetMaximumSizeForEncoding")
		reg(&cfStringGetCString, "CFStringGetCString")
		reg(&cfNumberCreate, "CFNumberCreate")
		reg(&cfNumberGetValue, "CFNumberGetValue")
		reg(&cfBooleanGetValue, "CFBooleanGetValue")
		reg(&cfDataCreate, "CFDataCreate")
		reg(&cfDataCreateMutable, "CFDataCreateMutable")
		reg(&cfDataGetLength, "CFDataGetLength")
		reg(&cfDataGetBytePtr, "CFDataGetBytePtr")
		reg(&cfDictionaryCreate, "CFDictionaryCreate")
		reg(&cfDictionaryGetValue, "CFDictionaryGetValue")
		reg(&cfArrayGetCount, "CFArrayGetCount")
		reg(&cfArrayGetValueAtIndex, "CFArrayGetValueAtIndex")
		reg(&cfURLCreateFromFSRep, "CFURLCreateFromFileSystemRepresentation")
		reg(&cfPreferencesCopyAppValue, "CFPreferencesCopyAppValue")
		reg(&cfPreferencesAppSynchronize, "CFPreferencesAppSynchronize")
		kCFBooleanTrue = constant(cfLib, "kCFBooleanTrue")
		kCFBooleanFalse = constant(cfLib, "kCFBooleanFalse")
		kCFNull = constant(cfLib, "kCFNull")
		dictKeyCallBacks = symbol(cfLib, "kCFTypeDictionaryKeyCallBacks")
		dictValueCallBacks = symbol(cfLib, "kCFTypeDictionaryValueCallBacks")
		loadImageIO()
	})
}

// symbol is the address of a global of a library.
func symbol(lib uintptr, name string) uintptr {
	addr, err := purego.Dlsym(lib, name)
	if err != nil {
		panic(err)
	}
	return addr
}

// constant is the value of a global CFTypeRef of a library, such as a
// CFStringRef key.
func constant(lib uintptr, name string) Ref {
	return *(*Ref)(unsafe.Add(nil, symbol(lib, name)))
}

// Release releases a CoreFoundation object; 0 is ignored.
func Release(r Ref) {
	if r != 0 {
		cfRelease(r)
	}
}

// String makes a CFString, which the caller releases.
func String(s string) Ref {
	load()
	b := []byte(s)
	if len(b) == 0 {
		b = []byte{0}
		return cfStringCreateWithBytes(0, &b[0], 0, utf8Encoding, false)
	}
	return cfStringCreateWithBytes(0, &b[0], len(b), utf8Encoding, false)
}

// IsString reports whether r is a CFString.
func IsString(r Ref) bool { return r != 0 && cfGetTypeID(r) == cfStringGetTypeID() }

// GoString reads a CFString, or "" for anything else.
func GoString(r Ref) string {
	if r == 0 || cfGetTypeID(r) != cfStringGetTypeID() {
		return ""
	}
	size := cfStringGetMaximumSizeForEncode(cfStringGetLength(r), utf8Encoding) + 1
	buf := make([]byte, size)
	if !cfStringGetCString(r, &buf[0], size, utf8Encoding) {
		return ""
	}
	for i, c := range buf {
		if c == 0 {
			return string(buf[:i])
		}
	}
	return string(buf)
}

// Float makes a CFNumber, which the caller releases.
func Float(v float64) Ref {
	load()
	return cfNumberCreate(0, numberFloat64, unsafe.Pointer(&v))
}

// Int makes a CFNumber, which the caller releases.
func Int(v int64) Ref {
	load()
	return cfNumberCreate(0, numberSInt64, unsafe.Pointer(&v))
}

// IntValue reads a CFNumber as an integer.
func IntValue(r Ref) (int64, bool) {
	if r == 0 || cfGetTypeID(r) != cfNumberGetTypeID() {
		return 0, false
	}
	var v int64
	cfNumberGetValue(r, numberSInt64, unsafe.Pointer(&v))
	return v, true
}

// FloatValue reads a CFNumber as a float.
func FloatValue(r Ref) (float64, bool) {
	if r == 0 || cfGetTypeID(r) != cfNumberGetTypeID() {
		return 0, false
	}
	var v float64
	cfNumberGetValue(r, numberFloat64, unsafe.Pointer(&v))
	return v, true
}

// BoolValue reads a CFBoolean, or a CFNumber as nonzero.
func BoolValue(r Ref) (bool, bool) {
	if r == 0 {
		return false, false
	}
	if cfGetTypeID(r) == cfBooleanGetTypeID() {
		return cfBooleanGetValue(r), true
	}
	if v, ok := IntValue(r); ok {
		return v != 0, true
	}
	return false, false
}

// True and Null are the CFBoolean true and kCFNull.
func True() Ref { load(); return kCFBooleanTrue }
func Null() Ref { load(); return kCFNull }

// Data makes a CFData of a copy of b, which the caller releases.
func Data(b []byte) Ref {
	load()
	if len(b) == 0 {
		return cfDataCreate(0, nil, 0)
	}
	return cfDataCreate(0, &b[0], len(b))
}

// MutableData makes an empty CFMutableData, which the caller releases.
func MutableData() Ref {
	load()
	return cfDataCreateMutable(0, 0)
}

// Bytes copies the bytes of a CFData, or nil for anything else.
func Bytes(r Ref) []byte {
	if r == 0 || cfGetTypeID(r) != cfDataGetTypeID() {
		return nil
	}
	n := cfDataGetLength(r)
	if n == 0 {
		return []byte{}
	}
	return append([]byte(nil), unsafe.Slice(cfDataGetBytePtr(r), n)...)
}

// Dict makes a CFDictionary of keys and values, which the caller releases.
// The dictionary retains them.
func Dict(pairs map[Ref]Ref) Ref {
	load()
	keys := make([]Ref, 0, len(pairs))
	values := make([]Ref, 0, len(pairs))
	for k, v := range pairs {
		keys = append(keys, k)
		values = append(values, v)
	}
	if len(keys) == 0 {
		return cfDictionaryCreate(0, nil, nil, 0, dictKeyCallBacks, dictValueCallBacks)
	}
	return cfDictionaryCreate(0, unsafe.Pointer(&keys[0]), unsafe.Pointer(&values[0]), len(keys), dictKeyCallBacks, dictValueCallBacks)
}

// Get is the value of key in a dictionary, not retained, or 0.
func Get(d, key Ref) Ref {
	if d == 0 {
		return 0
	}
	return cfDictionaryGetValue(d, key)
}

// Strings reads a CFArray of CFStrings.
func Strings(a Ref) []string {
	if a == 0 {
		return nil
	}
	n := cfArrayGetCount(a)
	out := make([]string, 0, n)
	for i := range n {
		out = append(out, GoString(cfArrayGetValueAtIndex(a, i)))
	}
	return out
}

// FileURL makes a CFURL of a path, which the caller releases.
func FileURL(path string) Ref {
	load()
	b := []byte(path)
	if len(b) == 0 {
		return 0
	}
	return cfURLCreateFromFSRep(0, &b[0], len(b), false)
}

// Pref is the value of key in the preferences of the app with the
// identifier app, which the caller releases, or 0.
func Pref(app, key string) Ref {
	load()
	a, k := String(app), String(key)
	defer Release(a)
	defer Release(k)
	return cfPreferencesCopyAppValue(k, a)
}

// SyncPrefs reads the app's preferences from disk again.
func SyncPrefs(app string) {
	load()
	a := String(app)
	defer Release(a)
	cfPreferencesAppSynchronize(a)
}
