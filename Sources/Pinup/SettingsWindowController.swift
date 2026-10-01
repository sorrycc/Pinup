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

/// A two-column form: right-aligned labels, controls on the right, and short
/// notes under some controls.
@MainActor
class SettingsPane: NSViewController {
    let grid = NSGridView()
    static let controlWidth: CGFloat = 340

    init(title: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView()
        Self.style(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -22),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        self.view = view
        buildRows()
        grid.column(at: 0).xPlacement = .trailing
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    static func style(_ grid: NSGridView) {
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
    }

    func buildRows() {}

    @discardableResult
    func addRow(_ label: String, _ control: NSView, to grid: NSGridView? = nil) -> NSGridRow {
        (grid ?? self.grid).addRow(with: [NSTextField(labelWithString: label), control])
    }

    func addNote(_ text: String, to grid: NSGridView? = nil) {
        let note = Self.note(text)
        let row = (grid ?? self.grid).addRow(with: [NSGridCell.emptyContentView, note])
        row.topPadding = -5
        row.bottomPadding = 6
    }

    func addSeparator(to grid: NSGridView? = nil) {
        let grid = grid ?? self.grid
        let row = grid.addRow(with: [NSGridCell.emptyContentView])
        row.height = 8
    }

    static func note(_ text: String = "") -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = controlWidth
        return label
    }

    static func field(_ value: String, placeholder: String = "", secure: Bool = false) -> NSTextField {
        let field = secure ? NSSecureTextField() : NSTextField()
        field.stringValue = value
        field.placeholderString = placeholder
        field.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
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
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isRichText = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.setValue(
            NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
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
            box.widthAnchor.constraint(equalToConstant: controlWidth),
            box.heightAnchor.constraint(equalToConstant: CGFloat(lines) * 15 + 14),
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
}

// MARK: General

final class GeneralSettingsPane: SettingsPane {
    private var formatPopUp: NSPopUpButton?
    private var conversionPopUp: NSPopUpButton?
    private let quality = NSSlider(value: 0.85, minValue: 0.3, maxValue: 1, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "")
    private let launchAtLogin = NSButton(checkboxWithTitle: "Open Pinup at login", target: nil, action: nil)

    init() { super.init(title: "General") }
    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        let formatPopUp = Self.popUp(
            LinkFormat.allCases, title: { $0.displayName }, selected: Settings.linkFormat, target: self,
            action: #selector(formatChanged(_:)))
        self.formatPopUp = formatPopUp
        addRow("Copy links as:", formatPopUp)
        addNote("Markdown is ![name](url) and HTML is an <img> tag.")

        let conversionPopUp = Self.popUp(
            ImageConversion.allCases, title: { $0.displayName }, selected: Settings.conversion, target: self,
            action: #selector(conversionChanged(_:)))
        self.conversionPopUp = conversionPopUp
        addRow("Convert images to:", conversionPopUp)
        quality.doubleValue = Settings.quality
        quality.target = self
        quality.action = #selector(qualityChanged(_:))
        quality.widthAnchor.constraint(equalToConstant: 200).isActive = true
        qualityLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        qualityLabel.textColor = .secondaryLabelColor
        let qualityRow = NSStackView(views: [quality, qualityLabel])
        qualityRow.spacing = 8
        addRow("Quality:", qualityRow)
        addNote("Transparent images stay out of JPEG and animations are never converted.")
        updateQuality()

        let strip = NSButton(checkboxWithTitle: "Remove location from photos", target: self, action: #selector(stripChanged(_:)))
        strip.state = Settings.stripLocation ? .on : .off
        addRow("Privacy:", strip)
        addNote("Drops GPS data. JPEG pixels stay untouched; other formats are rewritten at full quality.")

        let sound = NSButton(checkboxWithTitle: "Play a sound when links are copied", target: self, action: #selector(soundChanged(_:)))
        sound.state = Settings.playSound ? .on : .off
        addRow("Feedback:", sound)

        launchAtLogin.target = self
        launchAtLogin.action = #selector(launchChanged(_:))
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        addRow("Startup:", launchAtLogin)

        addSeparator()
        let clear = NSButton(title: "Clear History…", target: self, action: #selector(clearHistory(_:)))
        addRow("History:", clear)
        addNote("Removes the list and thumbnails. Uploaded files stay on their host.")
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .settingsDidChange, object: nil)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    /// Shows changes made elsewhere, such as the menu bar's Copy As menu.
    @objc private func refresh() {
        formatPopUp?.selectItem(at: LinkFormat.allCases.firstIndex(of: Settings.linkFormat) ?? 0)
        conversionPopUp?.selectItem(at: ImageConversion.allCases.firstIndex(of: Settings.conversion) ?? 0)
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateQuality()
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

    @objc private func qualityChanged(_ sender: NSSlider) {
        Settings.quality = sender.doubleValue
        updateQuality()
    }

    private func updateQuality() {
        qualityLabel.stringValue = "\(Int((Settings.quality * 100).rounded()))%"
        quality.isEnabled = Settings.conversion != .original
    }

    @objc private func stripChanged(_ sender: NSButton) { Settings.stripLocation = sender.state == .on }
    @objc private func soundChanged(_ sender: NSButton) { Settings.playSound = sender.state == .on }

    @objc private func launchChanged(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            NSAlert(error: error).runModal()
        }
    }

    @objc private func clearHistory(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear upload history?"
        alert.informativeText = "This removes \(History.shared.entries.count) entries and their thumbnails. The files stay on their hosts."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { History.shared.clear() }
        }
    }
}

// MARK: Hosts

final class HostsSettingsPane: SettingsPane, NSTextFieldDelegate, NSTextViewDelegate {
    static let paneTitle = "Hosts"
    static let labelWidth: CGFloat = 112

    private var forms: [HostKind: NSGridView] = [:]
    private var hostPopUp: NSPopUpButton?
    private var shownHost: HostKind?
    private let formBox = NSView()
    private let testButton = NSButton(title: "Test Upload", target: nil, action: nil)
    private let testSpinner = NSProgressIndicator()
    private let testResult = SettingsPane.note()

    // pic.sorrycc.com
    private let picToken = SettingsPane.field("", placeholder: "Token", secure: true)
    // S3
    private let s3Endpoint = SettingsPane.field("", placeholder: "https://<account>.r2.cloudflarestorage.com")
    private let s3Region = SettingsPane.field("", placeholder: "us-east-1, or auto for R2")
    private let s3Bucket = SettingsPane.field("", placeholder: "my-images")
    private let s3AccessKey = SettingsPane.field("", placeholder: "Access key ID")
    private let s3Secret = SettingsPane.field("", placeholder: "Secret access key", secure: true)
    private let s3PathStyle = NSButton(checkboxWithTitle: "Path-style addressing (R2, MinIO)", target: nil, action: nil)
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

    override func buildRows() {
        let host = Self.popUp(
            HostKind.allCases, title: { $0.displayName }, selected: Settings.host, target: self,
            action: #selector(hostChanged(_:)))
        for (index, kind) in HostKind.allCases.enumerated() {
            host.item(at: index)?.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
        }
        hostPopUp = host
        addRow("Upload to:", host)
        addSeparator()

        forms[.picSorrycc] = picForm()
        forms[.s3] = s3Form()
        forms[.custom] = customForm()
        // Every form sits in one box, which takes the height of the one
        // shown; the window grows or shrinks to fit when the host changes.
        for form in forms.values {
            form.translatesAutoresizingMaskIntoConstraints = false
            formBox.addSubview(form)
            NSLayoutConstraint.activate([
                form.topAnchor.constraint(equalTo: formBox.topAnchor),
                form.leadingAnchor.constraint(equalTo: formBox.leadingAnchor),
                form.trailingAnchor.constraint(lessThanOrEqualTo: formBox.trailingAnchor),
            ])
        }
        let formRow = grid.addRow(with: [formBox])
        formRow.mergeCells(in: NSRange(location: 0, length: 2))
        formRow.cell(at: 0).xPlacement = .fill

        testButton.target = self
        testButton.action = #selector(test(_:))
        testSpinner.style = .spinning
        testSpinner.controlSize = .small
        testSpinner.isDisplayedWhenStopped = false
        let testRow = NSStackView(views: [testButton, testSpinner])
        testRow.spacing = 8
        addRow("", testRow)
        testResult.isSelectable = true
        let note = grid.addRow(with: [NSGridCell.emptyContentView, testResult])
        note.topPadding = -4
        testResult.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

        // The same width as the forms' labels, so every control lines up.
        grid.column(at: 0).width = Self.labelWidth
        load()
        showForm()
        NotificationCenter.default.addObserver(self, selector: #selector(hostMayHaveChanged), name: .settingsDidChange, object: nil)
    }

    /// Follows the menu bar's Upload To menu.
    @objc private func hostMayHaveChanged() {
        guard Settings.host != shownHost else { return }
        hostPopUp?.selectItem(at: HostKind.allCases.firstIndex(of: Settings.host) ?? 0)
        showForm()
    }

    private func form() -> NSGridView {
        let form = NSGridView(numberOfColumns: 2, rows: 0)
        Self.style(form)
        return form
    }

    /// Labels in every form share one width so the controls line up with
    /// "Upload to:" above.
    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        return label
    }

    private func row(_ form: NSGridView, _ text: String, _ control: NSView) {
        let row = form.addRow(with: [label(text), control])
        // A text area's label sits level with its first line.
        if control is TextAreaBox, let label = row.cell(at: 0).contentView {
            row.rowAlignment = .none
            row.cell(at: 1).yPlacement = .top
            let cell = row.cell(at: 0)
            cell.yPlacement = .none
            cell.customPlacementConstraints = [label.topAnchor.constraint(equalTo: control.topAnchor, constant: 5)]
        }
    }

    private func note(_ form: NSGridView, _ text: String) {
        let row = form.addRow(with: [NSGridCell.emptyContentView, Self.note(text)])
        row.topPadding = -5
        row.bottomPadding = 4
    }

    private func picForm() -> NSGridView {
        let form = form()
        picToken.delegate = self
        row(form, "Token:", picToken)
        note(form, "Sent as a Bearer token. Tokens and keys are saved in secrets.json in ~/Library/Application Support/Pinup, readable only by you.")
        return form
    }

    private func s3Form() -> NSGridView {
        let form = form()
        for field in [s3Endpoint, s3Region, s3Bucket, s3AccessKey, s3Secret, s3Key, s3Public] { field.delegate = self }
        row(form, "Endpoint:", s3Endpoint)
        row(form, "Region:", s3Region)
        row(form, "Bucket:", s3Bucket)
        s3PathStyle.target = self
        s3PathStyle.action = #selector(saveS3)
        row(form, "", s3PathStyle)
        row(form, "Access key:", s3AccessKey)
        row(form, "Secret key:", s3Secret)
        row(form, "File path:", s3Key)
        note(form, "{year} {month} {day} {timestamp} {random} {name} {ext}")
        row(form, "Public URL:", s3Public)
        note(form, "Your CDN or public bucket domain. Use {key} to place the path, or leave empty for the object's own URL.")
        return form
    }

    private func customForm() -> NSGridView {
        let form = form()
        customURL.delegate = self
        customMethod.addItems(withTitles: ["POST", "PUT"])
        customMethod.target = self
        customMethod.action = #selector(saveCustom)
        customBody = Self.popUp(
            CustomConfig.Body.allCases, title: { $0.displayName }, selected: Settings.custom.body, target: self,
            action: #selector(saveCustom))
        let request = NSStackView(views: [customMethod, customBody])
        request.spacing = 8
        row(form, "URL:", customURL)
        note(form, "{name} is replaced by the file's name.")
        row(form, "Request:", request)
        note(form, "Multipart sends a form; JSON sends the file in base64; Raw File sends it as the body.")
        customField.delegate = self
        row(form, "File field:", customField)
        let (fieldsScroll, fields) = Self.textArea("", placeholder: "key=value", lines: 2)
        customFields = fields
        fields.delegate = self
        row(form, "Extra fields:", fieldsScroll)
        note(form, "One key=value per line.")
        let (headersScroll, headers) = Self.textArea("", placeholder: "Authorization: Bearer …", lines: 2)
        customHeaders = headers
        headers.delegate = self
        row(form, "Headers:", headersScroll)
        note(form, "One Name: value per line.")
        customPath.delegate = self
        row(form, "Link at:", customPath)
        note(form, "A path into the JSON reply, like data.url or data.0.src. Empty takes the whole reply.")
        customPrefix.delegate = self
        row(form, "Link prefix:", customPrefix)
        return form
    }

    private func load() {
        picToken.stringValue = Secrets.get(.picToken)
        let s3 = Settings.s3
        s3Endpoint.stringValue = s3.endpoint
        s3Region.stringValue = s3.region
        s3Bucket.stringValue = s3.bucket
        s3AccessKey.stringValue = s3.accessKeyID
        s3Secret.stringValue = Secrets.get(.s3Secret)
        s3PathStyle.state = s3.pathStyle ? .on : .off
        s3Key.stringValue = s3.keyTemplate
        s3Public.stringValue = s3.publicURL
        let custom = Settings.custom
        customURL.stringValue = custom.url
        customMethod.selectItem(withTitle: custom.method)
        customField.stringValue = custom.fileField
        customFields.string = custom.fields
        customHeaders.string = Secrets.get(.customHeaders)
        customPath.stringValue = custom.urlPath
        customPrefix.stringValue = custom.urlPrefix
    }

    private var formHeight: NSLayoutConstraint?

    private func showForm() {
        shownHost = Settings.host
        for (kind, form) in forms { form.isHidden = kind != Settings.host }
        testResult.stringValue = ""
        formHeight?.isActive = false
        if let form = forms[Settings.host] {
            formHeight = formBox.bottomAnchor.constraint(equalTo: form.bottomAnchor)
            formHeight?.isActive = true
        }
        fitWindow()
    }

    /// Resizes the pane, and its window when showing, keeping the top edge still.
    private func fitWindow() {
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        preferredContentSize = size
        guard let window = view.window, window.isVisible else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let delta = size.height - content.height
        guard abs(delta) > 0.5 else { return }
        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: true)
    }

    @objc private func hostChanged(_ sender: NSPopUpButton) {
        if let raw = sender.selectedItem?.representedObject as? String, let kind = HostKind(rawValue: raw) {
            Settings.host = kind
        }
        showForm()
    }

    func controlTextDidChange(_ obj: Notification) {
        save()
    }

    func textDidChange(_ notification: Notification) {
        save()
    }

    private func save() {
        Secrets.set(.picToken, picToken.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        saveS3()
        saveCustom()
    }

    @objc private func saveS3() {
        var s3 = Settings.s3
        s3.endpoint = s3Endpoint.stringValue.trimmingCharacters(in: .whitespaces)
        s3.region = s3Region.stringValue.trimmingCharacters(in: .whitespaces)
        s3.bucket = s3Bucket.stringValue.trimmingCharacters(in: .whitespaces)
        s3.accessKeyID = s3AccessKey.stringValue.trimmingCharacters(in: .whitespaces)
        s3.pathStyle = s3PathStyle.state == .on
        s3.keyTemplate = s3Key.stringValue.isEmpty ? S3Config().keyTemplate : s3Key.stringValue
        s3.publicURL = s3Public.stringValue.trimmingCharacters(in: .whitespaces)
        if s3 != Settings.s3 { Settings.s3 = s3 }
        Secrets.set(.s3Secret, s3Secret.stringValue.trimmingCharacters(in: .whitespaces))
    }

    @objc private func saveCustom() {
        var custom = Settings.custom
        custom.url = customURL.stringValue.trimmingCharacters(in: .whitespaces)
        custom.method = customMethod.titleOfSelectedItem ?? "POST"
        if let raw = customBody.selectedItem?.representedObject as? String, let body = CustomConfig.Body(rawValue: raw) {
            custom.body = body
        }
        custom.fileField = customField.stringValue.trimmingCharacters(in: .whitespaces)
        custom.fields = customFields.string
        custom.urlPath = customPath.stringValue.trimmingCharacters(in: .whitespaces)
        custom.urlPrefix = customPrefix.stringValue.trimmingCharacters(in: .whitespaces)
        if custom != Settings.custom { Settings.custom = custom }
        Secrets.set(.customHeaders, customHeaders.string)
    }

    @objc private func test(_ sender: Any?) {
        save()
        testButton.isEnabled = false
        testSpinner.startAnimation(nil)
        Self.show("Uploading a small test image…", in: testResult)
        let host = Uploader.currentHost()
        Task {
            let result = await Uploader.shared.test(host)
            testButton.isEnabled = true
            testSpinner.stopAnimation(nil)
            switch result {
            case .success(let url): Self.show("Works: \(url)", in: testResult, color: .systemGreen)
            case .failure(let error): Self.show(error.localizedDescription, in: testResult, color: .systemRed)
            }
        }
    }

    private static func show(_ text: String, in label: NSTextField, color: NSColor = .secondaryLabelColor) {
        label.stringValue = text
        label.textColor = color
    }
}

// MARK: Shortcuts

final class ShortcutsSettingsPane: SettingsPane {
    private let clipboard = HotKeyRecorder()
    private let screenshot = HotKeyRecorder()
    private let status = SettingsPane.note()

    init() { super.init(title: "Shortcuts") }
    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
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
        addRow("Upload clipboard:", clipboard)
        addRow("Capture screenshot:", screenshot)
        addNote("Work from any app. Click one, then press a combination with ⌘, ⌃ or ⌥. Delete clears it.")
        addRow("", status)
        check()
    }

    /// Refuses a combination the other action already uses.
    private func accept(_ hotKey: HotKey?, other: HotKey?, otherName: String) -> Bool {
        guard let hotKey, hotKey == other else { return true }
        NSSound.beep()
        status.stringValue = "\(hotKey.displayString) is already used for \(otherName)."
        status.textColor = .systemRed
        return false
    }

    /// Says when another app already holds a combination.
    private func check() {
        let failed = (NSApp.delegate as? AppDelegate)?.failedHotKeys ?? []
        if failed.isEmpty {
            status.stringValue = ""
        } else {
            status.stringValue = "\(failed.joined(separator: " and ")) is taken by another app. Pick another combination."
            status.textColor = .systemRed
        }
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
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        // Light fields are white; dark ones are nearly see-through.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = dark ? NSColor.white.withAlphaComponent(0.04).cgColor : NSColor.textBackgroundColor.cgColor
    }
}
