// Builds Resources/Pinup.icns from the 1024x1024 master in Resources/Pinup-1024.png.
// Usage: swift scripts/make-icon.swift
//
// The master is pixel art on a transparent field, clipped to the 824-point
// squircle of Apple's icon grid (corner radius 184). macOS 26 draws an icon at
// full size only when its silhouette fills that squircle and its PNGs are 8-bit;
// otherwise it shrinks the icon inside the legacy glass frame. The master was
// made from the generated render with ImageMagick:
//
//   magick art.png -resize 850x850 -background none -gravity center -extent 1024x1024 \
//     \( -size 1024x1024 xc:none -fill white -draw 'roundrectangle 100,100 923,923 184,184' \) \
//     -compose DstIn -composite -depth 8 Resources/Pinup-1024.png
//
// Every size below is written at 8 bits per sample for the same reason.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let masterURL = resources.appendingPathComponent("Pinup-1024.png")

guard let master = NSImage(contentsOf: masterURL) else {
    FileHandle.standardError.write(Data("missing \(masterURL.path)\n".utf8))
    exit(1)
}

func render(_ side: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let s = CGFloat(side)
    master.draw(in: NSRect(x: 0, y: 0, width: s, height: s), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Pinup.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("Pinup.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote Resources/Pinup.icns")
