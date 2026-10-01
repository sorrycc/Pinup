import AppKit

/// One finished upload.
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let url: String
    let name: String
    let host: String
    let size: Int
    let width: Int
    let height: Int
    let date: Date
    /// File name in the thumbnails folder.
    let thumbnail: String?

    var thumbnailURL: URL? { thumbnail.map { AppPaths.thumbnails.appendingPathComponent($0) } }
}

extension Notification.Name {
    static let historyDidChange = Notification.Name("PinupHistoryDidChange")
}

/// Past uploads, newest first, in history.json. Loaded the first time
/// something asks, and written a moment after changes, off the main thread.
@MainActor
final class History {
    static let shared = History()
    static let limit = 2000

    private(set) lazy var entries: [HistoryEntry] = load()
    private var saveTask: Task<Void, Never>?
    /// Thumbnails of removed entries, deleted by `pruneThumbnails` once undo is over.
    private var removedThumbnails: Set<String> = []

    func add(_ new: [HistoryEntry]) {
        guard !new.isEmpty else { return }
        entries.insert(contentsOf: new.reversed(), at: 0)
        if entries.count > Self.limit {
            removeThumbnails(of: Array(entries[Self.limit...]))
            entries.removeLast(entries.count - Self.limit)
        }
        changed()
    }

    /// Removes entries but keeps their thumbnails, so the removal can be
    /// undone. `pruneThumbnails` deletes them once undo is gone. Returns what
    /// was removed, with positions, for `restore`.
    @discardableResult
    func remove(_ ids: Set<UUID>) -> [(index: Int, entry: HistoryEntry)] {
        let removed = entries.enumerated().filter { ids.contains($0.element.id) }.map { (index: $0.offset, entry: $0.element) }
        guard !removed.isEmpty else { return [] }
        entries.removeAll { ids.contains($0.id) }
        removedThumbnails.formUnion(removed.compactMap(\.entry.thumbnail))
        changed()
        return removed
    }

    /// Puts removed entries back in date order, newest first, so uploads
    /// made since stay on top.
    func restore(_ removed: [(index: Int, entry: HistoryEntry)]) {
        guard !removed.isEmpty else { return }
        let present = Set(entries.map(\.id))
        let back = removed.map(\.entry).filter { !present.contains($0.id) }
        for entry in back {
            let index = entries.firstIndex { $0.date < entry.date } ?? entries.count
            entries.insert(entry, at: index)
        }
        removedThumbnails.subtract(back.compactMap(\.thumbnail))
        if entries.count > Self.limit {
            removeThumbnails(of: Array(entries[Self.limit...]))
            entries.removeLast(entries.count - Self.limit)
        }
        changed()
    }

    /// Deletes the thumbnails of removed entries, once their removal can no
    /// longer be undone. Only those: never files an upload in progress wrote.
    func pruneThumbnails() {
        let used = Set(entries.compactMap(\.thumbnail))
        let doomed = removedThumbnails.subtracting(used)
        removedThumbnails = []
        guard !doomed.isEmpty else { return }
        Task.detached(priority: .utility) {
            for name in doomed { try? FileManager.default.removeItem(at: AppPaths.thumbnails.appendingPathComponent(name)) }
        }
    }

    func clear() {
        removeThumbnails(of: entries)
        entries.removeAll()
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: .historyDidChange, object: nil)
        saveTask?.cancel()
        let snapshot = entries
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: AppPaths.history, options: .atomic)
            }
        }
    }

    private func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: AppPaths.history) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            // Never let the next save overwrite a file that couldn't be read.
            let backup = AppPaths.root.appendingPathComponent("history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: AppPaths.history, to: backup)
            return []
        }
    }

    private func removeThumbnails(of removed: [HistoryEntry]) {
        let urls = removed.compactMap(\.thumbnailURL)
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }
}
