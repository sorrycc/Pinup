import Foundation

/// Where Pinup keeps its files: ~/Library/Application Support/Pinup.
enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Pinup", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let history = root.appendingPathComponent("history.json")

    static let thumbnails: URL = {
        let url = root.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Screenshots and pasted images whose upload failed, kept for a retry.
    static let failed: URL = root.appendingPathComponent("Failed", isDirectory: true)

    /// A fresh folder for one upload's intermediate files, removed after it.
    static func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pinup-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
