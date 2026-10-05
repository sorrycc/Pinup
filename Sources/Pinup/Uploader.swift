import AppKit
import os

private let log = Logger(subsystem: "dev.sorrycc.pinup", category: "upload")

/// A file to upload. Temporary ones, like a pasted image or a screenshot,
/// sit in a folder of their own, which is deleted once they upload.
struct UploadSource: Sendable {
    let url: URL
    let name: String
    let isTemporary: Bool

    init(url: URL, name: String? = nil, isTemporary: Bool = false) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isTemporary = isTemporary
    }
}

/// An upload that failed, with the source to retry it from.
struct UploadFailure: Error {
    let source: UploadSource
    let error: Error

    /// Fixed in Settings rather than by trying again.
    var needsSettings: Bool {
        switch error as? UploadError {
        case .notConfigured: true
        case .http(let status, _): status == 401 || status == 403
        default: false
        }
    }
}

/// Reports bytes sent for one upload, at most 30 times a second and always
/// at the end. URLSession calls in for every chunk it writes, far more often
/// than the icon can show.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (Int64, Int64) -> Void
    private let lastReport = OSAllocatedUnfairLock(initialState: CFAbsoluteTime(0))

    init(_ onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let finished = totalBytesSent >= totalBytesExpectedToSend
        let due = lastReport.withLock { last in
            guard finished || now - last > 1.0 / 30 else { return false }
            last = now
            return true
        }
        if due { onProgress(totalBytesSent, totalBytesExpectedToSend) }
    }
}

/// Runs uploads: up to three at a time across every batch, each prepared and
/// sent off the main thread, with combined progress for the menu bar icon.
/// When a batch ends its links go to the clipboard together and a HUD
/// confirms it.
@MainActor
final class Uploader {
    static let shared = Uploader()
    static let concurrency = 3

    /// Combined progress from 0 to 1 while anything uploads, nil when idle.
    var onProgress: ((Double?) -> Void)?
    /// Called after each batch with whether every file in it uploaded.
    var onFinish: ((Bool) -> Void)?
    /// Opens Settings > Hosts, for failures a retry can't fix.
    var openHostSettings: (() -> Void)?
    /// Called once, the next time nothing is uploading. For a quit that waits.
    var onIdle: (() -> Void)?

    /// One file of the batches in flight. Finished files stay until every
    /// file is done, so the ring only moves forward as they finish.
    private struct Tracked {
        /// The file's size, which is how much of the ring it gets.
        var weight: Int64
        var fraction = 0.0
        var finished = false
    }

    /// A batch in flight: what is still on its way and what has arrived, so
    /// a quit in the middle of it loses neither.
    private struct Batch {
        var waiting: [UUID: UploadSource]
        var uploaded: [(index: Int, entry: HistoryEntry)] = []
    }

    private var tracked: [UUID: Tracked] = [:]
    private var batches: [UUID: Batch] = [:]
    private var lastReport = Date.distantPast
    /// Upload slots not in use, and the uploads waiting for one, first come
    /// first served.
    private var freeSlots = concurrency
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    var isBusy: Bool { !tracked.isEmpty || !batches.isEmpty }
    /// Files still uploading or waiting their turn.
    var activeCount: Int { tracked.values.count(where: { !$0.finished }) }
    private(set) var progress: Double = 0
    /// Why the last batch failed, until a later upload succeeds. The menu
    /// shows it, for a HUD that went unseen.
    private(set) var lastError: String?
    /// Files whose last upload failed, ready for Retry.
    private(set) var failed: [UploadSource] = []

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // A minute of silence ends an upload. There is no limit on the whole
        // transfer: a large file on a slow line takes as long as it takes.
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = concurrency
        return URLSession(configuration: configuration)
    }()

    /// The host settings point at, with its secrets.
    static func currentHost() -> any UploadHost {
        switch Settings.host {
        case .picSorrycc: PicSorryccHost(token: Secrets.get(.picToken))
        case .s3: S3Host(config: Settings.s3, secret: Secrets.get(.s3Secret))
        case .custom: CustomHost(config: Settings.custom, headers: Secrets.get(.customHeaders))
        }
    }

    func upload(_ sources: [UploadSource]) {
        // Folders can't upload, however they got here: `open -a Pinup`, a
        // pinup:// link or a retry.
        let files = sources.filter { (try? $0.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        if files.isEmpty, !sources.isEmpty {
            HUD.shared.showMessage("Folders can't be uploaded", "Choose the files inside instead.", symbol: "folder.fill")
        }
        let sources = files
        guard !sources.isEmpty else { return }
        log.info("uploading \(sources.count, privacy: .public) file(s)")
        let host = Self.currentHost()
        let options = ProcessingOptions(
            conversion: Settings.conversion, quality: Settings.quality, stripLocation: Settings.stripLocation)
        let format = Settings.linkFormat
        Task { await run(sources, host: host, options: options, format: format) }
    }

    /// Picks up screenshots and pasted images that failed before Pinup last quit.
    func restoreFailed() {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(
            at: AppPaths.failed, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let files = folders.compactMap { folder -> URL? in
            let file = (try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))?
                .first { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            if file == nil { try? manager.removeItem(at: folder) }
            return file
        }
        guard !files.isEmpty else { return }
        failed = files.map { UploadSource(url: $0, isTemporary: true) }
        lastError = "\(files.count) screenshot\(files.count == 1 ? "" : "s") or pasted image\(files.count == 1 ? "" : "s") didn't upload before Pinup quit."
    }

    /// Forgets failed uploads, deleting kept screenshots and pasted images.
    func discardFailed() {
        let sources = failed
        failed = []
        lastError = nil
        Task.detached(priority: .utility) {
            for source in sources where source.isTemporary { Self.removeTemporary(source.url) }
        }
    }

    func retryFailed() {
        let sources = failed
        failed = []
        upload(sources)
    }

    /// Uploads a small generated image to `host` without touching history or
    /// the menu bar icon, for the Test button in Settings.
    func test(_ host: any UploadHost) async -> Result<String, Error> {
        let scratch = AppPaths.scratch()
        let file = scratch.appendingPathComponent("pinup-test.png")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try Self.testImage().write(to: file)
        } catch {
            return .failure(error)
        }
        let result = await Self.perform(
            UploadSource(url: file), id: UUID(), host: host,
            options: ProcessingOptions(conversion: .original, quality: 1, stripLocation: false), keepThumbnail: false,
            progress: { _, _ in })
        return result.map(\.url).mapError(\.error)
    }

    private func run(_ sources: [UploadSource], host: any UploadHost, options: ProcessingOptions, format: LinkFormat) async {
        var results: [(Int, Result<HistoryEntry, UploadFailure>)] = []
        let ids = sources.map { _ in UUID() }
        let batch = UUID()
        batches[batch] = Batch(waiting: Dictionary(uniqueKeysWithValues: zip(ids, sources)))
        begin(ids, sources)
        await withTaskGroup(of: (Int, Result<HistoryEntry, UploadFailure>).self) { group in
            for (index, source) in sources.enumerated() {
                // In order, and before anything is read, converted or signed.
                await takeSlot()
                let id = ids[index]
                let progress = Self.reporter(id)
                group.addTask {
                    let result = await Self.perform(
                        source, id: id, host: host, options: options, keepThumbnail: true, progress: progress)
                    await MainActor.run { Uploader.shared.finished(id, index: index, result: result, batch: batch) }
                    return (index, result)
                }
            }
            for await done in group { results.append(done) }
        }
        // Nil when a quit took the batch over, which has recorded it already.
        guard batches.removeValue(forKey: batch) != nil else { return }
        results.sort { $0.0 < $1.0 }
        finish(results.map(\.1), format: format)
    }

    /// One file is done: its slot goes to the next in line, and its batch
    /// notes the outcome right away, in case a quit comes before the rest.
    private func finished(_ id: UUID, index: Int, result: Result<HistoryEntry, UploadFailure>, batch: UUID) {
        returnSlot()
        let source = batches[batch]?.waiting.removeValue(forKey: id)
        if case .success(let entry) = result {
            batches[batch]?.uploaded.append((index, entry))
            // Only now that the upload is on record does its screenshot or
            // pasted image go.
            if let source, source.isTemporary {
                Task.detached(priority: .utility) { Self.removeTemporary(source.url) }
            }
        }
        end(id)
    }

    /// Waits for one of the three upload slots, shared by every batch.
    private func takeSlot() async {
        if freeSlots > 0 {
            freeSlots -= 1
            return
        }
        await withCheckedContinuation { slotWaiters.append($0) }
    }

    /// Hands the slot to the upload that has waited longest, if any.
    private func returnSlot() {
        if slotWaiters.isEmpty {
            freeSlots += 1
        } else {
            slotWaiters.removeFirst().resume()
        }
    }

    /// For a quit in the middle of uploads. Files that already arrived go
    /// into History, and screenshots and pasted images still on their way
    /// move to the Failed folder, where the next launch offers them again.
    func abandon() {
        for batch in batches.values {
            History.shared.add(batch.uploaded.sorted { $0.index < $1.index }.map(\.entry))
            for source in batch.waiting.values where source.isTemporary { _ = Self.keep(source) }
        }
        batches = [:]
    }

    private func finish(_ results: [Result<HistoryEntry, UploadFailure>], format: LinkFormat) {
        var entries: [HistoryEntry] = []
        var failures: [UploadFailure] = []
        for result in results {
            switch result {
            case .success(let entry): entries.append(entry)
            case .failure(let failure): failures.append(failure)
            }
        }
        for failure in failures {
            log.error("\(failure.source.name, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
        }
        History.shared.add(entries)
        failed.append(contentsOf: failures.map(\.source))
        if !entries.isEmpty {
            let text = entries.map { format.format($0.url, name: $0.name) }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if Settings.playSound { NSSound(named: "Pop")?.play() }
        }

        if let first = failures.first {
            var message = "\(first.source.name): \(first.error.localizedDescription)"
            if failures.count > 1 { message += " And \(failures.count - 1) more." }
            lastError = message
            if !entries.isEmpty { message = "\(entries.count) of \(results.count) uploaded, links copied. " + message }
            if first.needsSettings {
                HUD.shared.showFailure(message, hint: "Click to open Settings.") { [weak self] in self?.openHostSettings?() }
            } else {
                HUD.shared.showFailure(message, hint: "Click to try again.") { [weak self] in self?.retryFailed() }
            }
        } else if let last = entries.last {
            lastError = nil
            HUD.shared.showSuccess(last, count: entries.count, format: format)
        }
        onFinish?(failures.isEmpty)
        if !isBusy, let idle = onIdle {
            onIdle = nil
            idle()
        }
    }

    // MARK: Progress

    /// Starts tracking a batch, each file weighed by its size.
    private func begin(_ ids: [UUID], _ sources: [UploadSource]) {
        for (id, source) in zip(ids, sources) {
            let size = (try? source.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            tracked[id] = Tracked(weight: Int64(max(size, 1)))
        }
        report(force: true)
    }

    private func end(_ id: UUID) {
        tracked[id]?.fraction = 1
        tracked[id]?.finished = true
        if tracked.values.allSatisfy(\.finished) { tracked = [:] }
        report(force: true)
    }

    private static func reporter(_ id: UUID) -> @Sendable (Int64, Int64) -> Void {
        { sent, total in
            Task { @MainActor in Uploader.shared.progressed(id, sent: sent, total: total) }
        }
    }

    private func progressed(_ id: UUID, sent: Int64, total: Int64) {
        guard let file = tracked[id], !file.finished, total > 0 else { return }
        tracked[id]?.fraction = min(1, Double(sent) / Double(total))
        report(force: false)
    }

    /// At most 30 reports a second, which is all the icon can show.
    private func report(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 1.0 / 30 else { return }
        lastReport = now
        guard !tracked.isEmpty else {
            onProgress?(nil)
            return
        }
        progress = Self.combinedProgress(tracked.values.map { ($0.weight, $0.fraction) })
        onProgress?(progress)
    }

    /// Each file's fraction, weighed by its size.
    nonisolated static func combinedProgress(_ files: [(weight: Int64, fraction: Double)]) -> Double {
        let total = files.reduce(Int64(0)) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        let done = files.reduce(0.0) { $0 + Double($1.weight) * $1.fraction }
        return min(1, max(0, done / Double(total)))
    }

    // MARK: Work off the main thread

    private nonisolated static func perform(
        _ source: UploadSource, id: UUID, host: any UploadHost, options: ProcessingOptions, keepThumbnail: Bool,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> Result<HistoryEntry, UploadFailure> {
        let scratch = AppPaths.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let file = try ImageProcessing.prepare(source.url, name: source.name, options: options, scratch: scratch)
            let request = try host.request(for: file, scratch: scratch)
            let data = try await send(request, host: host, progress: progress)
            let link = try host.link(from: data, file: file, request: request)
            var thumbnail: String?
            if keepThumbnail, let data = file.thumbnail {
                let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
                let name = id.uuidString + (isPNG ? ".png" : ".jpg")
                if (try? data.write(to: AppPaths.thumbnails.appendingPathComponent(name))) != nil { thumbnail = name }
            }
            return .success(HistoryEntry(
                id: id, url: link, name: file.name, host: host.name, size: file.size, width: file.width,
                height: file.height, date: Date(), thumbnail: thumbnail))
        } catch {
            return .failure(UploadFailure(source: source.isTemporary ? keep(source) : source, error: error))
        }
    }

    /// Deletes a temporary file and the folder Pinup made for it.
    private nonisolated static func removeTemporary(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        let manager = FileManager.default
        if folder.lastPathComponent.hasPrefix("Pinup-") || folder.deletingLastPathComponent() == AppPaths.failed {
            try? manager.removeItem(at: folder)
        } else {
            try? manager.removeItem(at: url)
        }
    }

    /// Moves a failed screenshot or pasted image out of the temporary folder,
    /// so a retry still has it.
    private nonisolated static func keep(_ source: UploadSource) -> UploadSource {
        if source.url.deletingLastPathComponent().deletingLastPathComponent() == AppPaths.failed { return source }
        let folder = AppPaths.failed.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(source.url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source.url, to: destination)
            removeTemporary(source.url)
            return UploadSource(url: destination, name: source.name, isTemporary: true)
        } catch {
            return source
        }
    }

    /// Sends the request, trying once more after a dropped connection, a
    /// timeout or a server error. S3 signatures stay valid for minutes, so the
    /// same request can be sent again.
    private nonisolated static func send(
        _ request: UploadRequest, host: any UploadHost, progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.upload(
                    for: request.request, fromFile: request.body, delegate: ProgressDelegate(progress))
                guard let http = response as? HTTPURLResponse else {
                    throw UploadError.badResponse("The server's reply wasn't HTTP.")
                }
                if http.statusCode >= 500, attempt == 1 {
                    log.error("HTTP \(http.statusCode, privacy: .public), retrying")
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw UploadError.http(http.statusCode, type(of: host).errorText(data))
                }
                return data
            } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
                let name = request.request.url?.host ?? "this server"
                throw UploadError.notConfigured(
                    "macOS blocks plain http:// to \(name). Use https://, or the server's IP address.")
            } catch let error as URLError where attempt == 1 && retryable.contains(error.code) {
                log.error("\(error.localizedDescription, privacy: .public), retrying")
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    private nonisolated static let retryable: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed,
        .secureConnectionFailed,
    ]

    /// A 64-pixel PNG with a gradient, for testing a host.
    private nonisolated static func testImage() throws -> Data {
        let size = 64
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [CGColor(srgbRed: 1, green: 0.42, blue: 0.36, alpha: 1), CGColor(srgbRed: 0.98, green: 0.27, blue: 0.55, alpha: 1)] as CFArray,
                locations: [0, 1])
        else { throw UploadError.processing("Couldn't draw the test image.") }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
        guard let image = context.makeImage(),
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw UploadError.processing("Couldn't encode the test image.") }
        return png
    }
}
