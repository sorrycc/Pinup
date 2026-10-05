import AppKit
import UniformTypeIdentifiers

/// The system's document icon for a file name's type, for uploads that have
/// no thumbnail: PDFs, movies, archives.
@MainActor
enum FileIcon {
    private static var icons: [String: NSImage] = [:]

    /// The icon at `side` points. Drawn once into a small 2x bitmap and kept:
    /// the system's icon carries sizes up to 1024 pixels, and an image view
    /// showing it would decode several megabytes for each tile.
    static func image(forName name: String, side: CGFloat) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        let key = "\(ext)@\(Int(side))"
        if let icon = icons[key] { return icon }
        let source = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        let pixels = Int(side * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return source }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let icon = NSImage(size: rep.size)
        icon.addRepresentation(rep)
        icons[key] = icon
        return icon
    }
}
