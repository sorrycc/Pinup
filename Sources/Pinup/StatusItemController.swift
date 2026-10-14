import AppKit

/// The menu bar icon. Files dropped on it upload; while uploads run it shows
/// their combined progress as a ring; its menu is built each time it opens.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private enum Look: Equatable {
        case idle
        case dropTarget
        case progress(Double)
        case done
        case failed
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var actions: AppDelegate?
    private var look = Look.idle { didSet { if look != oldValue { redraw() } } }
    private var doneTask: Task<Void, Never>?

    init(actions: AppDelegate) {
        self.actions = actions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "Pinup: drop files to upload"
        // The status bar window forwards drags to its delegate.
        item.button?.window?.registerForDraggedTypes([.fileURL])
        item.button?.window?.delegate = self
        redraw()

        Uploader.shared.onProgress = { [weak self] progress in
            self?.showProgress(progress)
        }
        Uploader.shared.onFinish = { [weak self] success in
            self?.showOutcome(success)
        }
    }

    /// The icon's frame on screen, for the HUD. Nil while macOS keeps the icon
    /// out of a full menu bar: its window is then parked, unseen, below the
    /// screen's bottom corner. A menu bar that hides itself only lifts the
    /// icon above the screen's top edge, which still says where the HUD belongs.
    var screenFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        if window.occlusionState.contains(.visible) { return rect }
        let lifted = NSScreen.screens.contains {
            ($0.frame.minX...$0.frame.maxX).contains(rect.midX) && rect.minY >= $0.frame.maxY - 1
        }
        return lifted ? rect : nil
    }

    /// Opens the menu as a click would, for `-show menu`.
    func openMenu() {
        item.button?.performClick(nil)
    }

    /// The ring stays up until the batch reports how it went.
    private func showProgress(_ progress: Double?) {
        guard let progress else { return }
        doneTask?.cancel()
        look = .progress(progress)
    }

    /// A check or a warning for a moment, unless another batch is still going.
    private func showOutcome(_ success: Bool) {
        guard !Uploader.shared.isBusy else { return }
        doneTask?.cancel()
        look = success ? .done : .failed
        doneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(success ? 1.4 : 3))
            guard !Task.isCancelled else { return }
            self?.look = .idle
        }
    }

    // MARK: Icon

    private func redraw() {
        item.button?.image = Self.icon(look)
        let value: String
        switch look {
        case .idle: value = "Ready"
        case .dropTarget: value = "Drop to upload"
        case .progress(let progress): value = "Uploading, \(Int(progress * 100)) percent"
        case .done: value = "Upload finished"
        case .failed: value = "Upload failed"
        }
        item.button?.setAccessibilityValue(value)
    }

    private static func icon(_ look: Look) -> NSImage {
        let symbol: String
        switch look {
        case .idle:
            // A pinned photo with an upload badge, at 1x and 2x.
            if let image = Bundle.main.image(forResource: "MenuBarIcon") {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                image.accessibilityDescription = "Pinup"
                return image
            }
            symbol = "pin"
        case .dropTarget: symbol = "arrow.up.circle.fill"
        case .done: symbol = "checkmark.circle"
        case .failed: symbol = "exclamationmark.triangle"
        case .progress(let value): return ring(value)
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pinup")!
            .withSymbolConfiguration(config)!
        image.isTemplate = true
        return image
    }

    /// A progress ring with an upward arrow inside, drawn as a template so it
    /// matches the menu bar in light and dark.
    private static func ring(_ progress: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 7.5
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.8
            NSColor.black.withAlphaComponent(0.25).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            let end = 90 - 360 * max(0.04, progress)
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: end, clockwise: true)
            arc.lineWidth = 1.8
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()

            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: center.x, y: center.y - 3.2))
            arrow.line(to: NSPoint(x: center.x, y: center.y + 3.2))
            arrow.move(to: NSPoint(x: center.x - 2.6, y: center.y + 0.8))
            arrow.line(to: NSPoint(x: center.x, y: center.y + 3.4))
            arrow.line(to: NSPoint(x: center.x + 2.6, y: center.y + 0.8))
            arrow.lineWidth = 1.5
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Drop

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !Capture.files(from: sender.draggingPasteboard).isEmpty else { return [] }
        if !Uploader.shared.isBusy {
            doneTask?.cancel()
            look = .dropTarget
        }
        return .copy
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if look == .dropTarget { look = .idle }
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let sources = Capture.files(from: sender.draggingPasteboard)
        if look == .dropTarget { look = .idle }
        guard !sources.isEmpty else { return false }
        Uploader.shared.upload(sources)
        return true
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let actions else { return }

        let uploader = Uploader.shared
        if uploader.isBusy {
            // The last file may be done a moment before its batch is.
            let count = max(1, uploader.activeCount)
            let row = item(
                "Uploading \(count) file\(count == 1 ? "" : "s")… \(Int(uploader.progress * 100))%", "arrow.up.circle", nil,
                target: nil)
            row.isEnabled = false
            menu.addItem(row)
            menu.addItem(.separator())
        } else if let error = uploader.lastError {
            let row = item("Last upload failed", "exclamationmark.triangle", nil, target: nil)
            row.subtitle = error
            row.toolTip = error
            row.isEnabled = false
            menu.addItem(row)
        }
        // Failed files stay reachable even after later uploads succeed.
        if !uploader.isBusy, !uploader.failed.isEmpty {
            let count = uploader.failed.count
            menu.addItem(ClosureMenuItem("Retry \(count) Failed Upload\(count == 1 ? "" : "s")", symbol: "arrow.clockwise") {
                Uploader.shared.retryFailed()
            })
            menu.addItem(ClosureMenuItem("Discard Failed Uploads", symbol: "trash") { Uploader.shared.discardFailed() })
        }
        if !uploader.isBusy, uploader.lastError != nil || !uploader.failed.isEmpty {
            menu.addItem(.separator())
        }

        menu.addItem(item("Upload Files…", "folder", #selector(AppDelegate.uploadFiles(_:)), target: actions, key: "o"))
        let clipboard = item("Upload from Clipboard", "doc.on.clipboard", #selector(AppDelegate.uploadClipboard(_:)), target: actions)
        show(Settings.clipboardHotKey, on: clipboard)
        menu.addItem(clipboard)
        let screenshot = item("Capture Screenshot", "camera.viewfinder", #selector(AppDelegate.captureScreenshot(_:)), target: actions)
        show(Settings.screenshotHotKey, on: screenshot)
        menu.addItem(screenshot)

        let recent = History.shared.entries.prefix(5)
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Recent"))
            let format = Settings.linkFormat.displayName
            for entry in recent {
                let title = Self.menuTitle(entry.name)
                let row = NSMenuItem(title: title, action: #selector(copyRecent(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = entry.url
                row.subtitle = Self.menuSubtitle(entry)
                row.image = Self.menuThumbnail(entry)
                row.toolTip = "\(entry.url)\nClick to copy as \(format). Option-click to open."
                menu.addItem(row)
                let open = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = entry.url
                open.subtitle = "Open in Browser"
                open.image = row.image
                open.isAlternate = true
                open.keyEquivalentModifierMask = .option
                menu.addItem(open)
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Show History", "clock.arrow.circlepath", #selector(AppDelegate.showHistory(_:)), target: actions, key: "y"))

        menu.addItem(.separator())
        let hosts = NSMenu()
        let selected = Settings.selectedHost?.id
        for host in Settings.hosts {
            let row = NSMenuItem(title: host.name, action: #selector(pickHost(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = host.id
            row.state = host.id == selected ? .on : .off
            hosts.addItem(row)
        }
        if hosts.items.isEmpty {
            let none = NSMenuItem(title: "No Hosts", action: nil, keyEquivalent: "")
            none.isEnabled = false
            hosts.addItem(none)
        }
        hosts.addItem(.separator())
        hosts.addItem(item("Add Host…", nil, #selector(addHost(_:)), target: self))
        let hostItem = item("Upload To", "server.rack", nil, target: nil)
        hostItem.submenu = hosts
        menu.addItem(hostItem)
        let formats = NSMenu()
        for format in LinkFormat.allCases {
            let row = NSMenuItem(title: format.displayName, action: #selector(pickFormat(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = format.rawValue
            row.state = format == Settings.linkFormat ? .on : .off
            formats.addItem(row)
        }
        let formatItem = item("Copy As", "link", nil, target: nil)
        formatItem.submenu = formats
        menu.addItem(formatItem)

        menu.addItem(.separator())
        menu.addItem(item("Settings…", "gearshape", #selector(AppDelegate.showSettings(_:)), target: actions, key: ","))
        menu.addItem(item("Quit Pinup", nil, #selector(NSApplication.terminate(_:)), target: NSApp, key: "q"))
    }

    private func item(_ title: String, _ symbol: String?, _ action: Selector?, target: AnyObject?, key: String = "") -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: key)
        row.target = target
        if let symbol { row.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return row
    }

    private func show(_ hotKey: HotKey?, on row: NSMenuItem) {
        guard let hotKey, let key = hotKey.menuKeyEquivalent else { return }
        row.keyEquivalent = key
        row.keyEquivalentModifierMask = hotKey.modifiers
    }

    /// A name short enough to keep the menu narrow, cut in the middle so the
    /// extension stays.
    static func menuTitle(_ name: String, limit: Int = 34) -> String {
        guard name.count > limit else { return name }
        let tail = (limit - 1) / 2
        return name.prefix(limit - 1 - tail) + "…" + name.suffix(tail)
    }

    /// When and how big, on one line: "5 minutes ago · 48 KB".
    static func menuSubtitle(_ entry: HistoryEntry, now: Date = Date()) -> String {
        let age = now.timeIntervalSince(entry.date)
        let when = age < 60 ? "Just now" : relativeFormatter.localizedString(for: entry.date, relativeTo: now)
        return "\(when) · \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// The last few menu thumbnails, so opening the menu again decodes nothing.
    private static let menuThumbnails: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 12
        return cache
    }()

    /// A rounded 28-point thumbnail, drawn the first time the menu shows it.
    /// Files without one get their type's icon at the same size, so every
    /// row's text starts at the same place.
    private static func menuThumbnail(_ entry: HistoryEntry) -> NSImage? {
        if let cached = menuThumbnails.object(forKey: entry.id as NSUUID) { return cached }
        let side: CGFloat = 28
        guard let url = entry.thumbnailURL, let source = NSImage(contentsOf: url) else {
            return FileIcon.image(forName: entry.name, side: side)
        }
        // Drawn once into a small 2x bitmap, so the cache holds a few kilobytes
        // per entry rather than the source image and a drawing block.
        let pixels = Int(side * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        outline.addClip()
        let size = source.size
        let scale = max(side / max(size.width, 1), side / max(size.height, 1))
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        source.draw(in: NSRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        // A hairline inside the edge, so a white screenshot keeps its shape
        // on a light menu and a black one on a dark menu.
        NSColor.gray.withAlphaComponent(0.35).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        menuThumbnails.setObject(image, forKey: entry.id as NSUUID)
        return image
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String,
            let entry = History.shared.entries.first(where: { $0.url == url })
        else { return }
        let format = Settings.linkFormat
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(format.format(entry.url, name: entry.name), forType: .string)
        HUD.shared.showSuccess(entry, count: 1, format: format)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let url = URL(string: text) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func pickHost(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        Settings.selectedHostID = id
    }

    @objc private func addHost(_ sender: NSMenuItem) {
        Uploader.shared.openHostSettings?()
    }

    @objc private func pickFormat(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let format = LinkFormat(rawValue: raw) else { return }
        Settings.linkFormat = format
    }
}
