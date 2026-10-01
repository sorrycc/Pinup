import AppKit

/// Past uploads as a grid of thumbnails grouped by day. A click copies the
/// link in the current format, a double click opens it, and files dropped on
/// the window upload.
@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate,
    NSCollectionViewDelegate
{
    private typealias DataSource = NSCollectionViewDiffableDataSource<Date, UUID>

    private let collectionView = HistoryCollectionView()
    private var dataSource: DataSource!
    private let emptyState = EmptyStateView()
    private var query = ""
    private var byID: [UUID: HistoryEntry] = [:]
    private var sections: [Date: [UUID]] = [:]

    private static let searchItem = NSToolbarItem.Identifier("search")
    private static let uploadItem = NSToolbarItem.Identifier("upload")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.title = "History"
        window.minSize = NSSize(width: 440, height: 360)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("History")
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "History")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        buildContent()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged), name: .historyDidChange, object: nil)
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Called when the window closes, so a menu bar app goes back to its
    /// idle footprint.
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        // Undo ends with the window, so removed uploads' thumbnails can go.
        window?.undoManager?.removeAllActions()
        History.shared.pruneThumbnails()
        ThumbnailCache.shared.removeAll()
        onClose?()
    }

    // MARK: Layout

    private func buildContent() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: HistoryItem.width, height: HistoryItem.height)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 4, left: 24, bottom: 24, right: 24)
        layout.headerReferenceSize = NSSize(width: 0, height: 40)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = self
        // Tiles drag out as their link, in the current format.
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.register(HistoryItem.self, forItemWithIdentifier: HistoryItem.identifier)
        collectionView.register(
            SectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: SectionHeader.identifier)
        collectionView.owner = self

        dataSource = DataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            let item = collectionView.makeItem(withIdentifier: HistoryItem.identifier, for: indexPath) as! HistoryItem
            if let entry = self?.byID[id] { item.show(entry) }
            item.onCopy = { [weak self] in self?.copy(ids: [id]) }
            item.onOpen = { [weak self] in self?.open(ids: [id]) }
            return item
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let header = collectionView.makeSupplementaryView(
                ofKind: kind, withIdentifier: SectionHeader.identifier, for: indexPath) as! SectionHeader
            if let self, let day = self.dataSource.snapshot().sectionIdentifiers[safe: indexPath.section] {
                header.show(day: day, count: self.sections[day]?.count ?? 0)
            }
            return header
        }

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let container = DropView()
        container.onDrop = { Uploader.shared.upload($0) }
        for view in [scroll, emptyState] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyState.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -48),
        ])
        container.overlayInsetTop = 52
        window?.contentView = container
    }

    // MARK: Data

    @objc private func historyChanged() {
        reload(animated: true)
    }

    private func reload(animated: Bool = false) {
        let all = History.shared.entries
        let needle = query.lowercased()
        let shown = needle.isEmpty ? all : all.filter {
            $0.name.lowercased().contains(needle) || $0.url.lowercased().contains(needle)
        }
        byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let calendar = Calendar.current
        var snapshot = NSDiffableDataSourceSnapshot<Date, UUID>()
        sections = [:]
        for entry in shown {
            let day = calendar.startOfDay(for: entry.date)
            if sections[day] == nil { snapshot.appendSections([day]) }
            sections[day, default: []].append(entry.id)
        }
        for day in snapshot.sectionIdentifiers { snapshot.appendItems(sections[day] ?? [], toSection: day) }
        dataSource.apply(snapshot, animatingDifferences: animated && window?.isVisible == true)
        // Only the visible headers' counts can be stale; tiles stay as they are.
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: NSCollectionView.elementKindSectionHeader) {
            guard let header = collectionView.supplementaryView(
                forElementKind: NSCollectionView.elementKindSectionHeader, at: indexPath) as? SectionHeader,
                let day = snapshot.sectionIdentifiers[safe: indexPath.section]
            else { continue }
            header.show(day: day, count: sections[day]?.count ?? 0)
        }

        emptyState.isHidden = !shown.isEmpty
        emptyState.show(searching: !needle.isEmpty, hasHistory: !all.isEmpty)
        let bytes = all.reduce(0) { $0 + $1.size }
        window?.subtitle = all.isEmpty
            ? ""
            : "\(all.count) upload\(all.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }

    private func entries(for ids: [UUID]) -> [HistoryEntry] {
        ids.compactMap { byID[$0] }
    }

    fileprivate var selectedIDs: [UUID] {
        collectionView.selectionIndexPaths.sorted().compactMap { dataSource.itemIdentifier(for: $0) }
    }

    fileprivate func ids(at indexPath: IndexPath) -> [UUID] {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return [] }
        if collectionView.selectionIndexPaths.contains(indexPath) { return selectedIDs }
        collectionView.deselectAll(nil)
        collectionView.selectItems(at: [indexPath], scrollPosition: [])
        return [id]
    }

    // MARK: Actions

    fileprivate func copy(ids: [UUID], format: LinkFormat? = nil) {
        let chosen = entries(for: ids)
        guard !chosen.isEmpty else { return }
        let format = format ?? Settings.linkFormat
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chosen.map { format.format($0.url, name: $0.name) }.joined(separator: "\n"), forType: .string)
        for id in ids {
            guard let indexPath = dataSource.indexPath(for: id),
                let item = collectionView.item(at: indexPath) as? HistoryItem
            else { continue }
            item.flash(format.displayName)
        }
    }

    fileprivate func open(ids: [UUID]) {
        for entry in entries(for: ids) {
            if let url = URL(string: entry.url) { NSWorkspace.shared.open(url) }
        }
    }

    /// Removes uploads from History, with Undo. The files stay on their host.
    fileprivate func delete(ids: [UUID]) {
        let removed = History.shared.remove(Set(ids))
        guard !removed.isEmpty, let undo = window?.undoManager else { return }
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { controller.restore(removed) }
        }
        undo.setActionName(removed.count == 1 ? "Remove Upload" : "Remove \(removed.count) Uploads")
    }

    private func restore(_ removed: [(index: Int, entry: HistoryEntry)]) {
        History.shared.restore(removed)
        let ids = removed.map(\.entry.id)
        window?.undoManager?.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { controller.delete(ids: ids) }
        }
        window?.undoManager?.setActionName(removed.count == 1 ? "Remove Upload" : "Remove \(removed.count) Uploads")
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        window?.toolbar?.items.first { $0.itemIdentifier == Self.searchItem }
            .flatMap { ($0 as? NSSearchToolbarItem) }?.beginSearchInteraction()
    }

    @objc private func uploadFiles(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.uploadFiles(sender)
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let entry = byID[id] else { return nil }
        let item = NSPasteboardItem()
        item.setString(Settings.linkFormat.format(entry.url, name: entry.name), forType: .string)
        if let url = URL(string: entry.url) { item.setString(url.absoluteString, forType: .URL) }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.uploadItem, Self.searchItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Search uploads"
            item.searchField.delegate = self
            item.preferredWidthForSearchField = 220
            return item
        case Self.uploadItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Upload Files")
            item.label = "Upload"
            item.toolTip = "Upload Files…"
            item.target = self
            item.action = #selector(uploadFiles(_:))
            return item
        default:
            return nil
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        query = field.stringValue.trimmingCharacters(in: .whitespaces)
        reload()
    }
}

// MARK: - Collection view

/// Adds copy, delete and a context menu to the grid.
@MainActor
private final class HistoryCollectionView: NSCollectionView, NSMenuItemValidation {
    weak var owner: HistoryWindowController?

    @objc func copy(_ sender: Any?) {
        guard let owner else { return }
        owner.copy(ids: owner.selectedIDs)
    }

    @objc func delete(_ sender: Any?) {
        guard let owner else { return }
        owner.delete(ids: owner.selectedIDs)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 51, 117:  // Delete, Forward Delete
            delete(nil)
        case 36, 76:  // Return, Enter
            owner?.open(ids: owner?.selectedIDs ?? [])
        default:
            super.keyDown(with: event)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) || item.action == #selector(delete(_:)) {
            return !selectionIndexPaths.isEmpty
        }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let owner, let indexPath = indexPathForItem(at: point) else { return nil }
        let ids = owner.ids(at: indexPath)
        let plural = ids.count > 1 ? " (\(ids.count))" : ""
        let menu = NSMenu()
        for format in LinkFormat.allCases {
            menu.addItem(ClosureMenuItem("Copy as \(format.displayName)\(plural)", symbol: "doc.on.doc") {
                owner.copy(ids: ids, format: format)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Open in Browser", symbol: "safari") { owner.open(ids: ids) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Remove from History", symbol: "trash") { owner.delete(ids: ids) })
        return menu
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

// MARK: - Item

/// One upload: a rounded thumbnail with hover buttons, its name, and its size and time.
@MainActor
private final class HistoryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("HistoryItem")
    static let width: CGFloat = 176
    static let height: CGFloat = 176
    static let tileHeight: CGFloat = 132

    var onCopy: (() -> Void)?
    var onOpen: (() -> Void)?

    private let tile = TileView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let actions = NSGlassEffectView()
    private let flashView = NSGlassEffectView()
    private let flashLabel = NSTextField(labelWithString: "")
    private var entryID: UUID?

    override func loadView() {
        let root = ItemRootView()
        root.onHover = { [weak self] inside in self?.hover(inside) }
        root.onClick = { [weak self] count in
            guard let self else { return }
            if count == 2 { self.onOpen?() } else { self.onCopy?() }
        }

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail

        let copyButton = Self.iconButton("doc.on.doc", "Copy Link", target: self, action: #selector(copyClicked))
        let openButton = Self.iconButton("arrow.up.right", "Open in Browser", target: self, action: #selector(openClicked))
        let buttons = NSStackView(views: [copyButton, openButton])
        buttons.spacing = 2
        buttons.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        actions.contentView = buttons
        actions.cornerRadius = 14
        actions.alphaValue = 0

        flashLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        flashLabel.alignment = .center
        let flashBox = NSStackView(views: [flashLabel])
        flashBox.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        flashView.contentView = flashBox
        flashView.cornerRadius = 15
        flashView.alphaValue = 0

        for view in [tile, nameLabel, metaLabel, actions, flashView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: root.topAnchor),
            tile.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tile.heightAnchor.constraint(equalToConstant: Self.tileHeight),
            nameLabel.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            actions.topAnchor.constraint(equalTo: tile.topAnchor, constant: 8),
            actions.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -8),
            flashView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            flashView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        view = root
    }

    private static func iconButton(_ symbol: String, _ label: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))!
        let button = NSButton(image: image, target: target, action: action)
        button.isBordered = false
        button.toolTip = label
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    func show(_ entry: HistoryEntry) {
        nameLabel.stringValue = entry.name
        nameLabel.toolTip = entry.url
        var meta = [ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)]
        if entry.width > 0 { meta.append("\(entry.width)×\(entry.height)") }
        meta.append(entry.date.formatted(date: .omitted, time: .shortened))
        metaLabel.stringValue = meta.joined(separator: " · ")
        let sameEntry = entryID == entry.id && tile.image != nil
        entryID = entry.id
        tile.placeholder = (entry.name as NSString).pathExtension.uppercased()
        if sameEntry { return }
        tile.image = nil
        let id = entry.id
        ThumbnailCache.shared.image(for: entry) { [weak self] image in
            guard let self, self.entryID == id else { return }
            self.tile.image = image
        }
    }

    override var isSelected: Bool {
        didSet { tile.isSelected = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        actions.alphaValue = 0
        flashView.alphaValue = 0
        tile.isHovered = false
    }

    private func hover(_ inside: Bool) {
        tile.isHovered = inside
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            actions.animator().alphaValue = inside ? 1 : 0
        }
    }

    func flash(_ format: String) {
        flashLabel.stringValue = "Copied \(format)"
        flashView.alphaValue = 1
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.9
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.7, 0, 0.84, 0)
            flashView.animator().alphaValue = 0
        })
    }

    @objc private func copyClicked() { onCopy?() }
    @objc private func openClicked() { onOpen?() }
}

/// Tracks hover over an item and reports clicks before the collection view
/// selects.
@MainActor
private final class ItemRootView: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: ((Int) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        let start = NSEvent.mouseLocation
        // The collection view tracks the click, or a drag, until the mouse goes up.
        super.mouseDown(with: event)
        let end = NSEvent.mouseLocation
        let dragged = hypot(end.x - start.x, end.y - start.y) > 4
        if !dragged, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift) {
            onClick?(event.clickCount)
        }
    }
}

/// The thumbnail: drawn by its layer with aspect fill, on a soft fill, with
/// a ring when selected.
@MainActor
private final class TileView: NSView {
    var image: CGImage? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(image == nil)
            imageLayer.contents = image
            CATransaction.commit()
            placeholderLabel.isHidden = image != nil
        }
    }
    var placeholder = "" { didSet { placeholderLabel.stringValue = placeholder } }
    var isSelected = false { didSet { updateBorder() } }
    var isHovered = false { didSet { updateBorder() } }

    private let imageLayer = CALayer()
    private let placeholderLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.actions = ["contents": CATransition()]
        layer?.addSublayer(imageLayer)
        placeholderLabel.font = .systemFont(ofSize: 15, weight: .bold)
        placeholderLabel.textColor = .tertiaryLabelColor
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        updateBorder()
    }

    override var wantsUpdateLayer: Bool { true }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isSelected {
                layer?.borderWidth = 3
                layer?.borderColor = NSColor.controlAccentColor.cgColor
            } else {
                layer?.borderWidth = 1
                layer?.borderColor = NSColor.separatorColor.withAlphaComponent(isHovered ? 0.9 : 0.4).cgColor
            }
        }
    }
}

// MARK: - Header, empty state, drop

@MainActor
private final class SectionHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("SectionHeader")
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .secondaryLabelColor
        let row = NSStackView(views: [title, count])
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(day: Date, count: Int) {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) {
            title.stringValue = "Today"
        } else if calendar.isDateInYesterday(day) {
            title.stringValue = "Yesterday"
        } else if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            title.stringValue = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        } else {
            title.stringValue = day.formatted(date: .long, time: .omitted)
        }
        self.count.stringValue = "\(count)"
    }
}

@MainActor
private final class EmptyStateView: NSStackView {
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 8
        symbol.symbolConfiguration = .init(pointSize: 44, weight: .light).applying(.init(hierarchicalColor: .tertiaryLabelColor))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 340
        addArrangedSubview(symbol)
        setCustomSpacing(14, after: symbol)
        addArrangedSubview(title)
        addArrangedSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(searching: Bool, hasHistory: Bool) {
        if searching, hasHistory {
            symbol.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            title.stringValue = "No Matches"
            detail.stringValue = "No upload's name or link has that text."
        } else {
            symbol.image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: nil)
            title.stringValue = "No Uploads Yet"
            let clipboard = Settings.clipboardHotKey.map { " or press \($0.displayString) to upload the clipboard" } ?? ""
            detail.stringValue = "Drop images here or on the menu bar pin\(clipboard)."
        }
    }
}

/// The window's content: takes file drops and shows a glowing outline while
/// one hovers.
@MainActor
private final class DropView: NSView {
    var onDrop: (([UploadSource]) -> Void)?
    var overlayInsetTop: CGFloat = 0
    private let highlight = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 16
        highlight.layer?.cornerCurve = .continuous
        highlight.layer?.borderWidth = 2.5
        highlight.isHidden = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight, positioned: .above, relativeTo: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard highlight.constraints.isEmpty, superview != nil else { return }
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    private func setHighlighted(_ on: Bool) {
        addSubview(highlight, positioned: .above, relativeTo: nil)
        highlight.layer?.borderColor = NSColor.controlAccentColor.cgColor
        highlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        highlight.isHidden = !on
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !Capture.files(from: sender.draggingPasteboard).isEmpty else { return [] }
        setHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setHighlighted(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setHighlighted(false)
        let sources = Capture.files(from: sender.draggingPasteboard)
        guard !sources.isEmpty else { return false }
        onDrop?(sources)
        return true
    }
}

// MARK: - Thumbnails

/// Decoded thumbnails, made off the main thread and kept while memory allows.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSUUID, CGImageBox>()
    /// Bumped by `removeAll`, so decodes still running then don't refill the cache.
    private var generation = 0

    init() {
        // A decoded 360-pixel thumbnail is about 0.4 MB.
        cache.totalCostLimit = 48 << 20
        cache.countLimit = 200
    }

    /// Frees every decoded thumbnail, for when History closes.
    func removeAll() {
        generation += 1
        cache.removeAllObjects()
    }

    func image(for entry: HistoryEntry, completion: @escaping (CGImage?) -> Void) {
        if let box = cache.object(forKey: entry.id as NSUUID) {
            completion(box.image)
            return
        }
        guard let url = entry.thumbnailURL else { return completion(nil) }
        let id = entry.id
        let generation = self.generation
        Task {
            let image = await Task.detached(priority: .userInitiated) { ImageProcessing.decodeThumbnail(at: url) }.value
            guard generation == self.generation else { return }
            if let image {
                cache.setObject(CGImageBox(image), forKey: id as NSUUID, cost: image.bytesPerRow * image.height)
            }
            completion(image)
        }
    }
}

final class CGImageBox: Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
