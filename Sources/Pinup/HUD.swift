import AppKit

/// A small glass panel under the menu bar icon that confirms a copied link or
/// shows why an upload failed. It never takes focus, and a click on it opens
/// History.
@MainActor
final class HUD {
    static let shared = HUD()

    /// The menu bar icon's frame on screen, for placing the panel under it.
    var anchor: (() -> NSRect?)?
    var onClick: (() -> Void)?

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private static let width: CGFloat = 320

    func showSuccess(_ entry: HistoryEntry, count: Int, format: LinkFormat) {
        let image = entry.thumbnailURL.flatMap { NSImage(contentsOf: $0) }
        let title = count == 1 ? "Copied as \(format.displayName)" : "\(count) links copied as \(format.displayName)"
        show(
            image: image, symbol: "checkmark.circle.fill", tint: .systemGreen, title: title,
            subtitle: entry.url, wraps: false, duration: .seconds(2.4))
    }

    /// `hint` says what a click does, which `action` then runs.
    func showFailure(_ message: String, hint: String? = nil, action: (() -> Void)? = nil) {
        show(
            image: nil, symbol: "exclamationmark.triangle.fill", tint: .systemOrange, title: "Upload failed",
            subtitle: hint.map { message + " " + $0 } ?? message, wraps: true, duration: .seconds(6), action: action)
    }

    func showMessage(_ title: String, _ subtitle: String, symbol: String = "info.circle.fill") {
        show(image: nil, symbol: symbol, tint: .secondaryLabelColor, title: title, subtitle: subtitle, wraps: true, duration: .seconds(2.4))
    }

    private func show(
        image: NSImage?, symbol: String, tint: NSColor, title: String, subtitle: String, wraps: Bool, duration: Duration,
        action: (() -> Void)? = nil
    ) {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let content = HUDContent(image: image, symbol: symbol, tint: tint, title: title, subtitle: subtitle, wraps: wraps)
        content.onClick = { [weak self] in
            self?.hide()
            if let action { action() } else { self?.onClick?() }
        }
        let glass = NSGlassEffectView()
        glass.cornerRadius = 20
        glass.contentView = content
        panel.contentView = glass

        let size = content.fittingSize
        let height = max(64, size.height)
        let target = frame(height: height)
        let start = target.offsetBy(dx: 0, dy: 8)
        if !panel.isVisible {
            panel.setFrame(start, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        // VoiceOver users hear what sighted users see.
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: "\(title). \(subtitle)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: 6), display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private func frame(height: CGFloat) -> NSRect {
        let width = Self.width
        let anchorRect = anchor?() ?? .zero
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchorRect == .zero ? visible.maxX - width - 12 : anchorRect.midX - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        let y = visible.maxY - height - 8
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 64),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}

/// The HUD's row: a thumbnail or symbol, a title and one or two lines under it.
@MainActor
private final class HUDContent: NSView {
    var onClick: (() -> Void)?

    /// A link stays on one line, cut in the middle; messages wrap to three lines.
    init(image: NSImage?, symbol: String, tint: NSColor, title: String, subtitle: String, wraps: Bool) {
        super.init(frame: .zero)
        let leading: NSView
        if let image {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.cornerRadius = 9
            view.layer?.masksToBounds = true
            view.layer?.contentsGravity = .resizeAspectFill
            let badge = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            badge.symbolConfiguration = .init(pointSize: 15, weight: .bold).applying(.init(paletteColors: [.white, tint]))
            let box = NSView()
            for subview in [view, badge] {
                subview.translatesAutoresizingMaskIntoConstraints = false
                box.addSubview(subview)
            }
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                view.topAnchor.constraint(equalTo: box.topAnchor),
                view.widthAnchor.constraint(equalToConstant: 40),
                view.heightAnchor.constraint(equalToConstant: 40),
                box.widthAnchor.constraint(equalToConstant: 44),
                box.heightAnchor.constraint(equalToConstant: 44),
                badge.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                badge.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            ])
            leading = box
        } else {
            let view = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            view.symbolConfiguration = .init(pointSize: 26, weight: .semibold).applying(.init(hierarchicalColor: tint))
            view.widthAnchor.constraint(equalToConstant: 44).isActive = true
            leading = view
        }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = wraps ? 3 : 1
        subtitleLabel.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingMiddle
        subtitleLabel.cell?.truncatesLastVisibleLine = true
        subtitleLabel.preferredMaxLayoutWidth = 320 - 44 - 16 * 2 - 12
        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [leading, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 320),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
