// Draws Resources/Pinup-1024.png and Resources/Pinup.icns: a warm gradient
// squircle with a white pin. Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")

func render(_ side: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(side)
    // Apple's icon grid: an 824 body inside 1024, with a soft shadow.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 0.55, blue: 0.33, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.30, blue: 0.47, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.25, blue: 0.86, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: body, angle: -60)
    // A soft highlight across the top.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The pin, tilted like one pushed into a board.
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.translateBy(x: s / 2, y: s / 2)
    context.rotate(by: -.pi / 9)
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    glyphShadow.shadowBlurRadius = s * 0.02
    glyphShadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    glyphShadow.set()
    let size = pin.size
    pin.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
    context.restoreGState()

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
try render(1024).write(to: resources.appendingPathComponent("Pinup-1024.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("Pinup.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("wrote Resources/Pinup.icns")
