import AppKit
import UniformTypeIdentifiers

/// Turns the clipboard or a screenshot into files to upload. Each temporary
/// file gets a folder of its own, so two quick captures never share a path.
@MainActor
enum Capture {
    /// Copied files, or else image data on the clipboard written to a
    /// temporary file. Empty when the clipboard has neither. Conversion and
    /// writing happen off the main thread.
    static func clipboard() async -> [UploadSource] {
        let pasteboard = NSPasteboard.general
        let files = Self.files(from: pasteboard)
        if !files.isEmpty { return files }
        // Formats worth keeping as they are, before TIFF, which is converted.
        let direct: [(UTType, String)] = [(.png, "png"), (.jpeg, "jpg"), (.gif, "gif"), (.heic, "heic"), (.webP, "webp")]
        let types = Set(pasteboard.types ?? [])
        var candidates = direct.map { (type: NSPasteboard.PasteboardType($0.0.identifier), ext: $0.1, convert: false) }
        candidates.append((.tiff, "png", true))
        candidates.removeAll { !types.contains($0.type) }
        guard !candidates.isEmpty else { return [] }
        let stamp = stamp()
        let change = pasteboard.changeCount
        // The image itself is fetched off the main thread: a large one takes
        // a while to cross from the app that copied it.
        let source = await Task.detached(priority: .userInitiated) { () -> UploadSource? in
            let pasteboard = NSPasteboard.general
            for candidate in candidates {
                guard pasteboard.changeCount == change else { return nil }
                guard let found = pasteboard.data(forType: candidate.type),
                    let data = candidate.convert ? ImageProcessing.png(from: found) : found
                else { continue }
                let url = AppPaths.scratch().appendingPathComponent("Pasted Image \(stamp).\(candidate.ext)")
                guard (try? data.write(to: url)) != nil else { return nil }
                return UploadSource(url: url, isTemporary: true)
            }
            return nil
        }.value
        return source.map { [$0] } ?? []
    }

    /// Runs the system's interactive capture: drag for an area, Space for a
    /// window, Escape to cancel, which returns nil.
    static func screenshot() async -> UploadSource? {
        let folder = AppPaths.scratch()
        let url = folder.appendingPathComponent("Screenshot \(stamp()).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        let finished: Bool = await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume(returning: true) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
        guard finished, FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return UploadSource(url: url, isTemporary: true)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }

    /// File URLs from a drag or the clipboard, without folders.
    static func files(from pasteboard: NSPasteboard) -> [UploadSource] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { !$0.hasDirectoryPath }.map { UploadSource(url: $0) }
    }
}
