import AppKit
import os

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
    /// Something changed since launch, so `flush` has a file to write.
    private var hasChanges = false
    /// Counts the changes, so an older save can never land on a newer one.
    private var generation = 0
    private nonisolated static let lastSaved = OSAllocatedUnfairLock(initialState: 0)
    /// Set when history.json is there but can't be read or moved aside.
    /// Nothing is saved then, so the file is never overwritten.
    private var savingDisabled = false
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
        hasChanges = true
        generation += 1
        saveTask?.cancel()
        guard !savingDisabled else { return }
        let snapshot = entries
        let generation = generation
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            Self.write(snapshot, generation: generation)
        }
    }

    /// Saves now and deletes the thumbnails of removed uploads, for when
    /// Pinup quits: the delayed save and the History window's cleanup would
    /// never get to run.
    func flush() {
        saveTask?.cancel()
        guard hasChanges else { return }
        if !savingDisabled { Self.write(entries, generation: generation) }
        let used = Set(entries.compactMap(\.thumbnail))
        for name in removedThumbnails.subtracting(used) {
            try? FileManager.default.removeItem(at: AppPaths.thumbnails.appendingPathComponent(name))
        }
        removedThumbnails = []
    }

    /// One save at a time, and never one older than what is on disk: a
    /// delayed save still encoding when Pinup quits must not undo the flush.
    private nonisolated static func write(_ entries: [HistoryEntry], generation: Int) {
        lastSaved.withLock { last in
            guard generation > last else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(entries), (try? data.write(to: AppPaths.history, options: .atomic)) != nil {
                last = generation
            }
        }
    }

    private func load() -> [HistoryEntry] {
        let data: Data
        do {
            data = try Data(contentsOf: AppPaths.history)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            setAsideUnreadable()
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            setAsideUnreadable()
            return []
        }
    }

    /// Never let the next save overwrite a file that couldn't be read: it is
    /// moved aside, and if even that fails, saving is off until Pinup restarts.
    private func setAsideUnreadable() {
        let backup = AppPaths.root.appendingPathComponent("history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try FileManager.default.moveItem(at: AppPaths.history, to: backup)
        } catch {
            savingDisabled = true
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
