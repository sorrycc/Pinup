import AppKit
import ServiceManagement

/// The Settings window (Cmd+,). Every change is saved as it is made.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init() {
        tabs.tabStyle = .toolbar
        let panes: [(NSViewController, String)] = [
            (GeneralSettingsPane(), "gearshape"),
            (HostsSettingsPane(), "server.rack"),
            (ShortcutsSettingsPane(), "keyboard"),
        ]
        for (pane, symbol) in panes {
            let item = NSTabViewItem(viewController: pane)
            item.label = pane.title ?? ""
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showPane(titled title: String) {
        if let index = tabs.tabViewItems.firstIndex(where: { $0.viewController?.title == title }) {
            tabs.selectedTabViewItemIndex = index
        }
    }
}

// MARK: - Form building blocks

/// A pane is a column of grouped sections, like System Settings: each
/// section is a rounded card of rows, with an optional note under it.
@MainActor
class SettingsPane: NSViewController {
    static let width: CGFloat = 560
    static let margin: CGFloat = 20
    static let cardWidth = width - margin * 2
    static let fieldWidth: CGFloat = 280

    let stack = NSStackView()

    init(title: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The cards scroll when the screen is too short to show them all,
        // which a small display is for S3 and Custom HTTP.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // Cards that all fit stay put under a swipe.
        scroll.verticalScrollElasticity = .none
        // Over the content, so a scroller never narrows the cards.
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalToConstant: Self.width),
            // The document is as tall as its cards, never the window, so
            // cards keep their height while the window animates.
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Self.margin),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Self.margin),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.margin),
            stack.widthAnchor.constraint(equalToConstant: Self.cardWidth),
        ])
        self.view = view
        buildSections()
        preferredContentSize = fittingSize
    }

    /// The screen may have changed since the pane was last shown.
    override func viewWillAppear() {
        super.viewWillAppear()
        preferredContentSize = fittingSize
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        keepOnScreen()
    }

    /// The size that shows every visible card with the margins around them,
    /// or as much of that as the screen has room for.
    var fittingSize: NSSize {
        view.layoutSubtreeIfNeeded()
        let wanted = stack.fittingSize.height + Self.margin * 2
        return NSSize(width: Self.width, height: min(wanted, maximumHeight))
    }

    /// The tallest the pane can be with its whole window on screen.
    private var maximumHeight: CGFloat {
        let window = view.window
        guard let screen = window?.screen ?? NSScreen.main else { return .greatestFiniteMagnitude }
        // What the window adds above the pane: its title bar and toolbar.
        let chrome = window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 90
        return max(240, screen.visibleFrame.height - chrome)
    }

    /// Slides the window up when its bottom edge has gone under the Dock or
    /// off the screen, as it can after growing downwards.
    private func keepOnScreen() {
        guard let window = view.window, window.isVisible, let visible = window.screen?.visibleFrame else { return }
        var frame = window.frame
        guard frame.minY < visible.minY else { return }
        frame.origin.y = visible.minY
        window.setFrame(frame, display: true, animate: true)
    }

    func buildSections() {}

    /// Adds a card of rows, and a note under it when `footer` is given.
    @discardableResult
    func addSection(_ rows: [NSView], footer: String? = nil) -> FormSection {
        let section = FormSection(rows: rows)
        stack.addArrangedSubview(section)
        // Sized by their own constraints, which survive being hidden: the
        // stack detaches hidden views, dropping any constraint to itself.
        section.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true
        if let footer {
            let note = addFooter(footer)
            section.footer = note
            stack.setCustomSpacing(7, after: section)
        }
        return section
    }

    @discardableResult
    func addFooter(_ text: String) -> FormFooter {
        let footer = FormFooter(text)
        stack.addArrangedSubview(footer)
        return footer
    }

    /// Resizes the pane, and its window when showing, keeping the top edge
    /// still, after rows appear or disappear.
    func fitWindow() {
        let size = fittingSize
        preferredContentSize = size
        guard let window = view.window, window.isVisible else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let delta = size.height - content.height
        guard abs(delta) > 0.5 else { return }
        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta
        if let visible = window.screen?.visibleFrame { frame.origin.y = max(frame.origin.y, visible.minY) }
        window.setFrame(frame, display: true, animate: true)
    }

    /// Where tokens and keys are kept, for the notes that say so.
    static var secretsNote: String {
        "Saved in secrets.json in \((AppPaths.root.path as NSString).abbreviatingWithTildeInPath), readable only by you."
    }

    static func note(_ text: String = "") -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = cardWidth - 32
        return label
    }

    static func field(_ value: String, placeholder: String = "", secure: Bool = false) -> NSTextField {
        let field = secure ? NSSecureTextField() : NSTextField()
        field.stringValue = value
        field.placeholderString = placeholder
        field.controlSize = .regular
        field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        return field
    }

    /// A monospaced text area with a placeholder, in a rounded box like a text field.
    static func textArea(_ value: String, placeholder: String, lines: Int = 3) -> (NSView, NSTextView) {
        let scroll = NSScrollView()
        let text = NSTextView()
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.string = value
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isRichText = false
        text.drawsBackground = false
        // With the container's own padding, text starts where a text field's does.
        text.textContainerInset = NSSize(width: 1, height: 6)
        text.setValue(
            NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.placeholderTextColor,
            ]), forKey: "placeholderAttributedString")
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let box = TextAreaBox()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            box.widthAnchor.constraint(equalToConstant: fieldWidth),
            box.heightAnchor.constraint(equalToConstant: CGFloat(lines) * 16 + 14),
        ])
        return (box, text)
    }

    static func popUp<T: RawRepresentable<String> & Equatable>(
        _ cases: [T], title: (T) -> String, selected: T, target: AnyObject, action: Selector
    ) -> NSPopUpButton {
        let button = NSPopUpButton()
        for value in cases {
            button.addItem(withTitle: title(value))
            button.lastItem?.representedObject = value.rawValue
        }
        button.selectItem(at: cases.firstIndex(of: selected) ?? 0)
        button.target = target
        button.action = action
        return button
    }

    static func toggle(_ on: Bool, target: AnyObject, action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.state = on ? .on : .off
        toggle.target = target
        toggle.action = action
        return toggle
    }
}

extension NSColor {
    /// The fill the system's text fields have on a card: white in light,
    /// and a well a shade darker than the card in dark. For the custom
    /// controls that sit beside them.
    static func fieldFill(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.black.withAlphaComponent(0.24)
            : .textBackgroundColor
    }
}

/// Lays out from the top, as a scrolling column of cards should.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The note under a card, inset a little from its edges.
@MainActor
final class FormFooter: NSView {
    let label: NSTextField

    init(_ text: String) {
        label = SettingsPane.note(text)
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SettingsPane.cardWidth),
            // In line with the rows' text above.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A rounded card holding rows separated by hairlines.
@MainActor
final class FormSection: NSView {
    /// The note under the card, hidden and shown with it.
    weak var footer: FormFooter?

    private let column = NSStackView()

    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = HairlineView()
                column.addArrangedSubview(line)
                NSLayoutConstraint.activate([
                    line.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 16),
                    line.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -16),
                ])
            }
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHidden: Bool {
        didSet { footer?.isHidden = isHidden }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Light cards sit a little brighter than the window; dark ones a little lighter.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = dark
            ? NSColor.white.withAlphaComponent(0.055).cgColor
            : NSColor.white.withAlphaComponent(0.62).cgColor
        layer?.borderColor = dark
            ? NSColor.white.withAlphaComponent(0.09).cgColor
            : NSColor.black.withAlphaComponent(0.07).cgColor
    }
}

/// A one-point line in the system separator colour.
@MainActor
final class HairlineView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

/// One row of a card: a title, an optional line of detail under it, and a
/// control on the trailing edge.
@MainActor
final class FormRow: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let control: NSView
    private let text = NSStackView()

    /// `top` puts the text level with the top of a tall control, like a text area.
    init(_ title: String, detail: String? = nil, control: NSView, top: Bool = false) {
        self.control = control
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.stringValue = detail ?? ""
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isHidden = detail == nil
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.addArrangedSubview(titleLabel)
        text.addArrangedSubview(detailLabel)
        for view in [text, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        var constraints = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            control.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ]
        if top {
            constraints += [
                control.topAnchor.constraint(equalTo: topAnchor, constant: 9),
                titleLabel.firstBaselineAnchor.constraint(equalTo: control.topAnchor, constant: 15),
            ]
        } else {
            constraints += [
                text.centerYAnchor.constraint(equalTo: centerYAnchor),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError() }

    var detail: String? {
        get { detailLabel.isHidden ? nil : detailLabel.stringValue }
        set {
            detailLabel.stringValue = newValue ?? ""
            detailLabel.isHidden = newValue == nil
        }
    }

    /// The detail wraps to whatever width is left beside the control.
    override func layout() {
        super.layout()
        let width = max(40, control.frame.minX - 16 - 16)
        if abs(detailLabel.preferredMaxLayoutWidth - width) > 0.5 {
            detailLabel.preferredMaxLayoutWidth = width
            detailLabel.invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
}

// MARK: - General

final class GeneralSettingsPane: SettingsPane {
    private var formatPopUp: NSPopUpButton?
    private var conversionPopUp: NSPopUpButton?
    private let quality = NSSlider(value: 0.85, minValue: 0.3, maxValue: 1, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "")
    private var qualityRow: FormRow?
    private var launchAtLogin: NSSwitch?
    private var historyRow: FormRow?

    init() { super.init(title: "General") }
    required init?(coder: NSCoder) { fatalError() }

    override func buildSections() {
        let formatPopUp = Self.popUp(
            LinkFormat.allCases, title: { $0.displayName }, selected: Settings.linkFormat, target: self,
            action: #selector(formatChanged(_:)))
        self.formatPopUp = formatPopUp
        addSection(
            [FormRow("Copy links as", control: formatPopUp)],
            footer: "Markdown is ![name](url) and HTML is an <img> tag. The menu bar's Copy As menu changes this too.")

        let conversionPopUp = Self.popUp(
            ImageConversion.allCases, title: { $0.displayName }, selected: Settings.conversion, target: self,
            action: #selector(conversionChanged(_:)))
        self.conversionPopUp = conversionPopUp
        quality.doubleValue = Settings.quality
        quality.target = self
        quality.action = #selector(qualityChanged(_:))
        quality.isContinuous = true
        quality.widthAnchor.constraint(equalToConstant: 180).isActive = true
        qualityLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        qualityLabel.textColor = .secondaryLabelColor
        qualityLabel.alignment = .right
        qualityLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let qualityControls = NSStackView(views: [quality, qualityLabel])
        qualityControls.spacing = 8
        let qualityRow = FormRow("Quality", detail: "For JPEG and HEIC.", control: qualityControls)
        self.qualityRow = qualityRow
        addSection(
            [FormRow("Convert images to", control: conversionPopUp), qualityRow],
            footer: "Transparent images stay out of JPEG, and animations are never converted.")
        updateQuality()

        let strip = Self.toggle(Settings.stripLocation, target: self, action: #selector(stripChanged(_:)))
        let sound = Self.toggle(Settings.playSound, target: self, action: #selector(soundChanged(_:)))
        let launch = Self.toggle(SMAppService.mainApp.status == .enabled, target: self, action: #selector(launchChanged(_:)))
        launchAtLogin = launch
        addSection([
            FormRow(
                "Remove location from photos",
                detail: "Drops GPS data before upload. JPEG pixels stay untouched; other formats are rewritten at full quality.",
                control: strip),
            FormRow("Play a sound when links are copied", control: sound),
            FormRow("Open Pinup at login", control: launch),
        ])

        let clear = NSButton(title: "Clear History…", target: self, action: #selector(clearHistory(_:)))
        let historyRow = FormRow("Upload history", detail: "", control: clear)
        self.historyRow = historyRow
        addSection([historyRow], footer: "Clearing removes the list and its thumbnails. The uploaded files stay on their host.")
        updateHistory()

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .settingsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateHistory), name: .historyDidChange, object: nil)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    /// Shows changes made elsewhere, such as the menu bar's Copy As menu.
    @objc private func refresh() {
        formatPopUp?.selectItem(at: LinkFormat.allCases.firstIndex(of: Settings.linkFormat) ?? 0)
        conversionPopUp?.selectItem(at: ImageConversion.allCases.firstIndex(of: Settings.conversion) ?? 0)
        launchAtLogin?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateQuality()
    }

    @objc private func updateHistory() {
        let entries = History.shared.entries
        let bytes = entries.reduce(0) { $0 + $1.size }
        historyRow?.detail = entries.isEmpty
            ? "No uploads yet."
            : "\(entries.count) upload\(entries.count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) in all."
        (historyRow?.control as? NSButton)?.isEnabled = !entries.isEmpty
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        if let raw = sender.selectedItem?.representedObject as? String, let value = LinkFormat(rawValue: raw) {
            Settings.linkFormat = value
        }
    }

    @objc private func conversionChanged(_ sender: NSPopUpButton) {
        if let raw = sender.selectedItem?.representedObject as? String, let value = ImageConversion(rawValue: raw) {
            Settings.conversion = value
        }
        updateQuality()
    }

    /// The label follows the drag; the setting is saved when the mouse goes up.
    @objc private func qualityChanged(_ sender: NSSlider) {
        if NSApp.currentEvent?.type == .leftMouseDragged {
            qualityLabel.stringValue = Self.percent(sender.doubleValue)
            return
        }
        Settings.quality = sender.doubleValue
        updateQuality()
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func updateQuality() {
        qualityLabel.stringValue = Self.percent(Settings.quality)
        let enabled = Settings.conversion != .original
        quality.isEnabled = enabled
        qualityRow?.titleLabel.textColor = enabled ? .labelColor : .tertiaryLabelColor
        qualityRow?.detailLabel.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
        qualityLabel.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
    }

    @objc private func stripChanged(_ sender: NSSwitch) { Settings.stripLocation = sender.state == .on }
    @objc private func soundChanged(_ sender: NSSwitch) { Settings.playSound = sender.state == .on }

    @objc private func launchChanged(_ sender: NSSwitch) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            NSAlert(error: error).runModal()
        }
    }

    @objc private func clearHistory(_ sender: Any?) {
        let count = History.shared.entries.count
        let alert = NSAlert()
        alert.messageText = "Clear upload history?"
        alert.informativeText = "This removes \(count) upload\(count == 1 ? "" : "s") and \(count == 1 ? "its" : "their") thumbnails from the list. The files stay on their hosts."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { History.shared.clear() }
        }
    }
}

// MARK: - Hosts

final class HostsSettingsPane: SettingsPane, NSTextFieldDelegate, NSTextViewDelegate {
    static let paneTitle = "Hosts"

    private var sections: [Provider: [FormSection]] = [:]
    private let hostPopUp = NSPopUpButton()
    private var nameSection: FormSection?
    private var emptyFooter: FormFooter?
    private var testSection: FormSection?
    /// The host the form shows, nil when there are none.
    private var shownHost: HostConfig?
    private let testButton = NSButton(title: "Test Upload", target: nil, action: nil)
    private let testSpinner = NSProgressIndicator()
    private var testRow: FormRow?
    private static let testHint = "Uploads a small image to check the host."

    private let hostName = SettingsPane.field("", placeholder: "My Images")
    // S3
    private let s3Endpoint = SettingsPane.field("", placeholder: "https://<account>.r2.cloudflarestorage.com")
    private let s3Region = SettingsPane.field("", placeholder: "us-east-1, or auto for R2")
    private let s3Bucket = SettingsPane.field("", placeholder: "my-images")
    private let s3AccessKey = SettingsPane.field("", placeholder: "Access key ID")
    private let s3Secret = SettingsPane.field("", placeholder: "Secret access key", secure: true)
    private var s3PathStyle: NSSwitch!
    private let s3Key = SettingsPane.field("", placeholder: "{year}/{month}/{timestamp}-{random}.{ext}")
    private let s3Public = SettingsPane.field("", placeholder: "https://img.example.com")
    // Custom
    private let customURL = SettingsPane.field("", placeholder: "https://example.com/api/upload")
    private let customMethod = NSPopUpButton()
    private var customBody: NSPopUpButton!
    private let customField = SettingsPane.field("", placeholder: "file")
    private var customFields: NSTextView!
    private var customHeaders: NSTextView!
    private let customPath = SettingsPane.field("", placeholder: "data.url")
    private let customPrefix = SettingsPane.field("", placeholder: "Optional, put before the value")

    init() { super.init(title: Self.paneTitle) }
    required init?(coder: NSCoder) { fatalError() }

    override func buildSections() {
        hostPopUp.target = self
        hostPopUp.action = #selector(hostChanged(_:))
        hostPopUp.autoenablesItems = false
        addSection(
            [FormRow("Upload to", control: hostPopUp)],
            footer: "Add a host for each place you upload to: an S3-compatible bucket, or any HTTP upload API.")

        hostName.delegate = self
        nameSection = addSection([FormRow("Name", detail: "Shown in the Upload To menu and History.", control: hostName)])
        emptyFooter = addFooter("No hosts yet. Choose Add S3-Compatible or Add Custom HTTP above.")

        sections[.s3] = s3Sections()
        sections[.custom] = customSections()

        testButton.target = self
        testButton.action = #selector(test(_:))
        testSpinner.style = .spinning
        testSpinner.controlSize = .small
        testSpinner.isDisplayedWhenStopped = false
        let testControls = NSStackView(views: [testSpinner, testButton])
        testControls.spacing = 8
        let testRow = FormRow("Test the connection", detail: Self.testHint, control: testControls)
        testRow.detailLabel.isSelectable = true
        self.testRow = testRow
        testSection = addSection([testRow])

        showSelectedHost()
        NotificationCenter.default.addObserver(self, selector: #selector(hostMayHaveChanged), name: .settingsDidChange, object: nil)
    }

    /// Follows the menu bar's Upload To menu.
    @objc private func hostMayHaveChanged() {
        guard Settings.selectedHost?.id != shownHost?.id else { return }
        showSelectedHost()
    }

    /// Hosts, then the actions that add and remove them.
    private func rebuildPopUp() {
        hostPopUp.removeAllItems()
        let menu = hostPopUp.menu!
        for host in Settings.hosts {
            let item = NSMenuItem(title: host.name, action: nil, keyEquivalent: "")
            item.representedObject = host.id
            item.image = NSImage(systemSymbolName: host.provider.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "No Hosts", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        for provider in Provider.allCases {
            let item = NSMenuItem(title: "Add \(provider.displayName)…", action: nil, keyEquivalent: "")
            item.representedObject = provider
            menu.addItem(item)
        }
        if let shownHost {
            let item = NSMenuItem(title: "Remove “\(shownHost.name)”…", action: nil, keyEquivalent: "")
            item.representedObject = "remove"
            menu.addItem(item)
        }
        hostPopUp.selectItem(at: 0)
        if let id = shownHost?.id {
            hostPopUp.selectItem(at: hostPopUp.indexOfItem(withRepresentedObject: id))
        }
    }

    private func s3Sections() -> [FormSection] {
        for field in [s3Endpoint, s3Region, s3Bucket, s3AccessKey, s3Secret, s3Key, s3Public] { field.delegate = self }
        s3PathStyle = Self.toggle(true, target: self, action: #selector(save))
        return [
            addSection(
                [
                    FormRow("Endpoint", control: s3Endpoint),
                    FormRow("Region", control: s3Region),
                    FormRow("Bucket", control: s3Bucket),
                    FormRow("Path-style addressing", detail: "endpoint/bucket/key. R2 and MinIO need it.", control: s3PathStyle),
                ],
                footer: "Works with AWS S3, Cloudflare R2, Aliyun OSS, Tencent COS, MinIO and other S3-compatible services."),
            addSection(
                [
                    FormRow("Access key ID", control: s3AccessKey),
                    FormRow("Secret access key", control: s3Secret),
                ],
                footer: Self.secretsNote),
            addSection(
                [
                    FormRow("File path", control: s3Key),
                    FormRow("Public URL", control: s3Public),
                ],
                footer: "The file path can use {year}, {month}, {day}, {timestamp}, {random}, {name} and {ext}. The public URL is your CDN or public bucket domain: use {key} to place the path, or leave it empty for the object's own URL."),
        ]
    }

    private func customSections() -> [FormSection] {
        customURL.delegate = self
        customMethod.addItems(withTitles: ["POST", "PUT"])
        customMethod.target = self
        customMethod.action = #selector(save)
        customBody = Self.popUp(
            CustomConfig.Body.allCases, title: { $0.displayName }, selected: .multipart, target: self,
            action: #selector(save))
        let request = NSStackView(views: [customMethod, customBody])
        request.spacing = 8
        customField.delegate = self
        let (fieldsBox, fields) = Self.textArea("", placeholder: "key=value", lines: 2)
        customFields = fields
        fields.delegate = self
        let (headersBox, headers) = Self.textArea("", placeholder: "Authorization: Bearer …", lines: 2)
        customHeaders = headers
        headers.delegate = self
        customPath.delegate = self
        customPrefix.delegate = self
        return [
            addSection(
                [
                    FormRow("URL", detail: "{name} becomes the file's name.", control: customURL),
                    FormRow("Request", control: request),
                ],
                footer: "Multipart sends a form; JSON sends the file in base64; Raw File sends it as the body."),
            addSection(
                [
                    FormRow("File field", detail: "The form field or JSON key.", control: customField),
                    FormRow("Extra fields", detail: "One key=value per line.", control: fieldsBox, top: true),
                    FormRow("Headers", detail: "One Name: value per line.", control: headersBox, top: true),
                ],
                footer: "Headers usually carry the token. " + Self.secretsNote),
            addSection(
                [
                    FormRow("Link at", control: customPath),
                    FormRow("Link prefix", control: customPrefix),
                ],
                footer: "A path into the JSON reply, like data.url or data.0.src. Empty takes the whole reply. The prefix goes before the value, for APIs that return a path."),
        ]
    }

    /// Fills the form from the selected host and shows its provider's sections.
    private func showSelectedHost() {
        shownHost = Settings.selectedHost
        rebuildPopUp()
        if let host = shownHost {
            hostName.stringValue = host.name
            let secret = Secrets.get(host.secretKey)
            switch host.provider {
            case .s3:
                let s3 = host.s3 ?? S3Config()
                s3Endpoint.stringValue = s3.endpoint
                s3Region.stringValue = s3.region
                s3Bucket.stringValue = s3.bucket
                s3AccessKey.stringValue = s3.accessKeyID
                s3Secret.stringValue = secret
                s3PathStyle.state = s3.pathStyle ? .on : .off
                s3Key.stringValue = s3.keyTemplate
                s3Public.stringValue = s3.publicURL
            case .custom:
                let custom = host.custom ?? CustomConfig()
                customURL.stringValue = custom.url
                customMethod.selectItem(withTitle: custom.method)
                customBody.selectItem(at: customBody.indexOfItem(withRepresentedObject: custom.body.rawValue))
                customField.stringValue = custom.fileField
                customFields.string = custom.fields
                customHeaders.string = secret
                customPath.stringValue = custom.urlPath
                customPrefix.stringValue = custom.urlPrefix
            }
        }
        nameSection?.isHidden = shownHost == nil
        emptyFooter?.isHidden = shownHost != nil
        testSection?.isHidden = shownHost == nil
        for (provider, list) in sections {
            for section in list { section.isHidden = provider != shownHost?.provider }
        }
        showTestResult(Self.testHint)
        fitWindow()
    }

    @objc private func hostChanged(_ sender: NSPopUpButton) {
        switch sender.selectedItem?.representedObject {
        case let id as UUID:
            Settings.selectedHostID = id
            showSelectedHost()
        case let provider as Provider:
            Settings.addHost(provider)
            showSelectedHost()
            view.window?.makeFirstResponder(hostName)
        case let action as String where action == "remove":
            rebuildPopUp()
            confirmRemove()
        default:
            rebuildPopUp()
        }
    }

    private func confirmRemove() {
        guard let host = shownHost, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(host.name)”?"
        alert.informativeText = "Its settings and keys are deleted. Files already uploaded stay on the host and in History."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Settings.removeHost(host)
            self?.showSelectedHost()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        save()
    }

    func textDidChange(_ notification: Notification) {
        save()
    }

    /// Writes the form into the shown host.
    @objc private func save() {
        guard var host = shownHost else { return }
        let name = hostName.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != host.name {
            host.name = name
            if let item = hostPopUp.selectedItem { item.title = name }
            hostPopUp.lastItem?.title = "Remove “\(name)”…"
        }
        switch host.provider {
        case .s3:
            var s3 = host.s3 ?? S3Config()
            s3.endpoint = s3Endpoint.stringValue.trimmingCharacters(in: .whitespaces)
            s3.region = s3Region.stringValue.trimmingCharacters(in: .whitespaces)
            s3.bucket = s3Bucket.stringValue.trimmingCharacters(in: .whitespaces)
            s3.accessKeyID = s3AccessKey.stringValue.trimmingCharacters(in: .whitespaces)
            s3.pathStyle = s3PathStyle.state == .on
            s3.keyTemplate = s3Key.stringValue.isEmpty ? S3Config().keyTemplate : s3Key.stringValue
            s3.publicURL = s3Public.stringValue.trimmingCharacters(in: .whitespaces)
            host.s3 = s3
            Secrets.set(host.secretKey, s3Secret.stringValue.trimmingCharacters(in: .whitespaces))
        case .custom:
            var custom = host.custom ?? CustomConfig()
            custom.url = customURL.stringValue.trimmingCharacters(in: .whitespaces)
            custom.method = customMethod.titleOfSelectedItem ?? "POST"
            if let raw = customBody.selectedItem?.representedObject as? String, let body = CustomConfig.Body(rawValue: raw) {
                custom.body = body
            }
            custom.fileField = customField.stringValue.trimmingCharacters(in: .whitespaces)
            custom.fields = customFields.string
            custom.urlPath = customPath.stringValue.trimmingCharacters(in: .whitespaces)
            custom.urlPrefix = customPrefix.stringValue.trimmingCharacters(in: .whitespaces)
            host.custom = custom
            Secrets.set(host.secretKey, customHeaders.string)
        }
        shownHost = host
        Settings.update(host)
    }

    @objc private func test(_ sender: Any?) {
        save()
        testButton.isEnabled = false
        testSpinner.startAnimation(nil)
        showTestResult("Uploading a small test image…")
        let host = Uploader.currentHost()
        let id = shownHost?.id
        Task {
            let result = await Uploader.shared.test(host)
            testButton.isEnabled = true
            testSpinner.stopAnimation(nil)
            // The form may have changed to another host meanwhile.
            guard id == shownHost?.id else { return }
            switch result {
            case .success(let url): showTestResult("Works. \(url)", color: .systemGreen)
            case .failure(let error): showTestResult(error.localizedDescription, color: .systemRed)
            }
        }
    }

    private func showTestResult(_ text: String, color: NSColor = .secondaryLabelColor) {
        testRow?.detail = text
        testRow?.detailLabel.textColor = color
        fitWindow()
    }
}

// MARK: - Shortcuts

final class ShortcutsSettingsPane: SettingsPane {
    private let clipboard = HotKeyRecorder()
    private let screenshot = HotKeyRecorder()
    private var status: FormFooter?

    init() { super.init(title: "Shortcuts") }
    required init?(coder: NSCoder) { fatalError() }

    override func buildSections() {
        clipboard.hotKey = Settings.clipboardHotKey
        clipboard.onRecord = { [weak self] hotKey in
            guard let self, self.accept(hotKey, other: Settings.screenshotHotKey, otherName: "Capture screenshot") else { return }
            Settings.clipboardHotKey = hotKey
            self.clipboard.hotKey = hotKey
            self.check()
        }
        screenshot.hotKey = Settings.screenshotHotKey
        screenshot.onRecord = { [weak self] hotKey in
            guard let self, self.accept(hotKey, other: Settings.clipboardHotKey, otherName: "Upload clipboard") else { return }
            Settings.screenshotHotKey = hotKey
            self.screenshot.hotKey = hotKey
            self.check()
        }
        addSection(
            [
                FormRow("Upload clipboard", detail: "Copied files, or the image on the clipboard.", control: clipboard),
                FormRow("Capture screenshot", detail: "Pick an area or a window, like ⇧⌘4.", control: screenshot),
            ],
            footer: "Both work from any app. Click a shortcut, then press a combination with ⌘, ⌃ or ⌥. Press Delete to clear it.")
        let status = addFooter("")
        status.label.textColor = .systemRed
        status.isHidden = true
        self.status = status
        check()
    }

    /// Refuses a combination the other action already uses.
    private func accept(_ hotKey: HotKey?, other: HotKey?, otherName: String) -> Bool {
        guard let hotKey, hotKey == other else { return true }
        NSSound.beep()
        show("\(hotKey.displayString) is already used for \(otherName).")
        return false
    }

    /// Says when another app already holds a combination.
    private func check() {
        let failed = (NSApp.delegate as? AppDelegate)?.failedHotKeys ?? []
        show(failed.isEmpty ? nil : "\(failed.joined(separator: " and ")) is taken by another app. Pick another combination.")
    }

    private func show(_ message: String?) {
        status?.label.stringValue = message ?? ""
        status?.isHidden = message == nil
        fitWindow()
    }
}

/// The rounded box around a text area, drawn like the system's text fields.
@MainActor
final class TextAreaBox: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.fieldFill(for: effectiveAppearance).cgColor
    }
}
