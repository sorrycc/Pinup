import AppKit

/// Shown on first launch: what Pinup does, where it lives, and a way to set
/// up a host.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static var wasShown: Bool {
        get { UserDefaults.standard.bool(forKey: "welcomed") }
        set { UserDefaults.standard.set(newValue, forKey: "welcomed") }
    }

    var onSetUpHost: (() -> Void)?
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// However it closes, it has been seen.
    func windowWillClose(_ notification: Notification) {
        Self.wasShown = true
        onClose?()
    }

    private func makeContent() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let title = NSTextField(labelWithString: "Welcome to Pinup")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Upload images from the menu bar and paste the link anywhere.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let shortcuts: String
        switch (Settings.clipboardHotKey, Settings.screenshotHotKey) {
        case let (clipboard?, screenshot?):
            shortcuts = "\(clipboard.displayString) uploads the clipboard, \(screenshot.displayString) a screenshot."
        case let (clipboard?, nil):
            shortcuts = "\(clipboard.displayString) uploads the clipboard. Add a screenshot shortcut in Settings."
        case let (nil, screenshot?):
            shortcuts = "\(screenshot.displayString) captures part of the screen. Add a clipboard shortcut in Settings."
        case (nil, nil):
            shortcuts = "Set shortcuts in Settings to upload the clipboard or capture part of the screen."
        }
        let features = NSStackView(views: [
            feature("pin.fill", .systemPink, "Lives in the menu bar",
                    "Drop files on the pin, or click it for recent uploads."),
            feature("keyboard.fill", .systemOrange, "Upload from any app",
                    shortcuts),
            feature("link", .systemPurple, "Links ready to paste",
                    "Copied as Markdown, a plain URL or an HTML tag."),
        ])
        features.orientation = .vertical
        features.alignment = .leading
        features.spacing = 18

        let notch = NSTextField(wrappingLabelWithString:
            "Don't see the pin? A full menu bar hides icons behind the camera housing. Hold ⌘ and drag other icons away to make room.")
        notch.font = .systemFont(ofSize: 11)
        notch.textColor = .secondaryLabelColor
        notch.alignment = .center
        notch.preferredMaxLayoutWidth = 380

        let needsHost = Settings.hosts.isEmpty
        let primary = NSButton(title: needsHost ? "Set Up a Host…" : "Get Started", target: self, action: #selector(primaryClicked))
        primary.keyEquivalent = "\r"
        primary.controlSize = .large
        primary.bezelColor = .controlAccentColor
        primary.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        var buttons: [NSView] = [primary]
        if needsHost {
            let later = NSButton(title: "Later", target: self, action: #selector(laterClicked))
            later.controlSize = .large
            buttons.insert(later, at: 0)
        }
        let buttonRow = NSStackView(views: buttons)
        buttonRow.spacing = 10

        let stack = NSStackView(views: [icon, title, subtitle, features, buttonRow, notch])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(30, after: subtitle)
        stack.setCustomSpacing(34, after: features)
        stack.setCustomSpacing(18, after: buttonRow)
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 48, bottom: 28, right: 48)

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        return background
    }

    private func feature(_ symbol: String, _ color: NSColor, _ title: String, _ detail: String) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        image.symbolConfiguration = .init(pointSize: 17, weight: .semibold).applying(.init(paletteColors: [.white]))
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = color.cgColor
        badge.layer?.cornerRadius = 10
        badge.layer?.cornerCurve = .continuous
        image.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(image)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 40),
            badge.heightAnchor.constraint(equalToConstant: 40),
            image.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 330
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        // One width for all three, so they wrap alike and share a right edge.
        text.widthAnchor.constraint(equalToConstant: 330).isActive = true

        let row = NSStackView(views: [badge, text])
        row.alignment = .centerY
        row.spacing = 14
        return row
    }

    @objc private func primaryClicked() {
        Self.wasShown = true
        close()
        if Settings.hosts.isEmpty { onSetUpHost?() }
    }

    @objc private func laterClicked() {
        Self.wasShown = true
        close()
    }
}
