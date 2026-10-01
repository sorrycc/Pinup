import AppKit
import Carbon.HIToolbox

/// A system-wide key combination, such as ⌥⇧⌘U. Kept as the virtual key
/// code, since that is what Carbon registers, plus the key's name for display.
struct HotKey: Equatable, Sendable {
    static let allowedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags
    let key: String

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.allowedModifiers)
        self.key = key
    }

    /// The combination `event` types, or nil without Cmd, Ctrl or Option,
    /// which every global shortcut needs so it doesn't swallow typing.
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.allowedModifiers)
        guard !modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        let name = Self.specialKeys[Int(event.keyCode)]
            ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: name)
    }

    /// As stored in user defaults: `32:1179648:U`.
    var text: String { "\(keyCode):\(modifiers.rawValue):\(key)" }

    /// The same physical keys, whatever keyboard layout named them.
    static func == (a: HotKey, b: HotKey) -> Bool {
        a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }

    init?(text: String) {
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let code = UInt32(parts[0]), let raw = UInt(parts[1]), !parts[2].isEmpty else { return nil }
        self.init(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: raw), key: String(parts[2]))
    }

    /// As menus show it: ⌥⇧⌘U.
    var displayString: String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + key
    }

    var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.control) { flags |= controlKey }
        return UInt32(flags)
    }

    /// For a menu item showing the combination. Nil for keys a menu can't show.
    var menuKeyEquivalent: String? {
        key.count == 1 ? key.lowercased() : nil
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// Registers hot keys with Carbon, which still owns system-wide shortcuts,
/// and calls their handlers on the main thread. All of Pinup's keys are
/// registered together, so two of them can trade combinations, and they can
/// be paused while a new one is recorded.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var wanted: [UInt32: (hotKey: HotKey?, handler: () -> Void)] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false
    /// Recorders currently recording; keys stay unregistered while any is.
    private var suspensions = 0
    private var suspended: Bool { suspensions > 0 }
    /// Ids whose combination another app holds, as of the last `apply`.
    private(set) var failed: Set<UInt32> = []

    /// Sets what `id` should be. Takes effect on `apply`.
    func set(_ id: UInt32, _ hotKey: HotKey?, handler: @escaping () -> Void) {
        wanted[id] = (hotKey, handler)
    }

    /// Unregisters every key, then registers each wanted one.
    @discardableResult
    func apply() -> Set<UInt32> {
        installHandler()
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
        failed = []
        guard !suspended else { return failed }
        for (id, entry) in wanted {
            guard let hotKey = entry.hotKey else { continue }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x504E_5550), id: id)  // "PNUP"
            let status = RegisterEventHotKey(
                hotKey.keyCode, hotKey.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs[id] = ref } else { failed.insert(id) }
        }
        return failed
    }

    /// Lets a recorder see combinations Pinup itself holds.
    func suspend() {
        suspensions += 1
        if suspensions == 1 { apply() }
    }

    func resume() {
        guard suspensions > 0 else { return }
        suspensions -= 1
        if suspensions == 0 { apply() }
    }

    fileprivate func fire(_ id: UInt32) {
        wanted[id]?.handler()
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            // Carbon calls application event handlers on the main thread.
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// A field that records a hot key: click it, then press the combination.
/// Escape cancels, Delete or the clear button removes it.
@MainActor
final class HotKeyRecorder: NSButton {
    var hotKey: HotKey? { didSet { update() } }
    /// Called with the combination pressed, or nil when cleared.
    var onRecord: ((HotKey?) -> Void)?

    private let clearButton = NSButton()
    private var hasFocus = false

    private var isRecording = false {
        didSet {
            update()
            guard isRecording != oldValue else { return }
            if isRecording { HotKeyCenter.shared.suspend() } else { HotKeyCenter.shared.resume() }
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        target = self
        action = #selector(clicked(_:))
        setAccessibilityLabel("Keyboard shortcut")

        let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear shortcut")!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold).applying(.init(hierarchicalColor: .tertiaryLabelColor)))
        clearButton.image = image
        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.toolTip = "Clear shortcut"
        clearButton.target = self
        clearButton.action = #selector(clearClicked(_:))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 168),
            heightAnchor.constraint(equalToConstant: 28),
            clearButton.widthAnchor.constraint(equalToConstant: 20),
            clearButton.heightAnchor.constraint(equalToConstant: 20),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        hasFocus = accepted
        update()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        hasFocus = false
        isRecording = false
        update()
        return super.resignFirstResponder()
    }

    /// Recording ends when the window closes or another app comes forward,
    /// so Pinup's shortcuts are never left switched off.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else {
            isRecording = false
            return
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(stopRecording), name: name, object: window)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    @objc private func stopRecording() {
        isRecording = false
    }

    @objc private func clicked(_ sender: Any?) {
        isRecording.toggle()
        if isRecording { window?.makeFirstResponder(self) }
    }

    @objc private func clearClicked(_ sender: Any?) {
        isRecording = false
        onRecord?(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(HotKey.allowedModifiers)
        if modifiers.isEmpty, Int(event.keyCode) == kVK_Escape {
            isRecording = false
            return
        }
        if modifiers.isEmpty, Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete {
            isRecording = false
            onRecord?(nil)
            return
        }
        guard let hotKey = HotKey(event: event) else {
            NSSound.beep()
            return
        }
        isRecording = false
        onRecord?(hotKey)
    }

    /// The field looks like a text field, with the combination in the
    /// middle. While recording its border takes the accent colour.
    private func update() {
        let text: String
        let color: NSColor
        if isRecording {
            text = "Type shortcut…"
            color = .controlAccentColor
        } else if let hotKey {
            text = hotKey.displayString
            color = .labelColor
        } else {
            text = "Click to record"
            color = .placeholderTextColor
        }
        let showsClear = hotKey != nil && !isRecording
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        // Centred in the space beside the clear button, never under it.
        style.headIndent = showsClear ? 26 : 0
        style.firstLineHeadIndent = style.headIndent
        style.tailIndent = showsClear ? -26 : 0
        let title = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: showsClear ? .medium : .regular),
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
        attributedTitle = title
        // The same while pressed, so the text never blinks away.
        attributedAlternateTitle = title
        clearButton.isHidden = !showsClear
        setAccessibilityValue(hotKey?.displayString ?? "None")
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.backgroundColor = dark
                ? NSColor.white.withAlphaComponent(0.06).cgColor
                : NSColor.textBackgroundColor.cgColor
            let focused = isRecording || hasFocus
            layer?.borderWidth = focused ? 2 : 1
            layer?.borderColor = focused ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
        }
    }
}
