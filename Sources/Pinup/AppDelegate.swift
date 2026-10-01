import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var historyController: HistoryWindowController?
    private var settingsController: SettingsWindowController?
    private var welcomeController: WelcomeWindowController?
    private var registered: (clipboard: HotKey?, screenshot: HotKey?)?
    /// Names of hot keys another app holds, for Settings to explain.
    private(set) var failedHotKeys: [String] = []

    private enum HotKeyID: UInt32 {
        case clipboard = 1
        case screenshot = 2
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        // `-appearance light` or `dark`, for checking the design in both.
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        let statusItem = StatusItemController(actions: self)
        self.statusItem = statusItem
        HUD.shared.anchor = { [weak statusItem] in statusItem?.screenFrame }
        HUD.shared.onClick = { [weak self] in self?.showHistory(nil) }
        Uploader.shared.openHostSettings = { [weak self] in
            self?.showSettings(nil)
            self?.settingsController?.showPane(titled: HostsSettingsPane.paneTitle)
        }

        Uploader.shared.restoreFailed()
        registerHotKeys()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: .settingsDidChange, object: nil)

        // `-show history` or `-show <settings pane>` opens a window at launch.
        switch UserDefaults.standard.string(forKey: "show")?.lowercased() {
        case "history":
            showHistory(nil)
        case "welcome":
            showWelcome()
        case let pane? where ["general", "hosts", "shortcuts"].contains(pane):
            showSettings(nil)
            settingsController?.showPane(titled: pane.capitalized)
        default:
            if !WelcomeWindowController.wasShown { showWelcome() }
        }
    }

    /// Files opened with Pinup or passed to `open -a Pinup`, and `pinup://` links.
    func application(_ application: NSApplication, open urls: [URL]) {
        Uploader.shared.upload(urls.filter(\.isFileURL).map { UploadSource(url: $0) })
        for url in urls where url.scheme == "pinup" { handle(url) }
    }

    /// `pinup://upload-clipboard`, `pinup://screenshot`, `pinup://upload?path=<file>`,
    /// `pinup://retry`, `pinup://history` and `pinup://settings[/hosts]`, for
    /// Shortcuts, Raycast and scripts.
    private func handle(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host?.lowercased() {
        case "upload-clipboard": uploadClipboard(nil)
        case "screenshot": captureScreenshot(nil)
        case "history": showHistory(nil)
        case "retry": Uploader.shared.retryFailed()
        case "upload":
            let paths = components?.queryItems?.filter { $0.name == "path" }.compactMap(\.value) ?? []
            Uploader.shared.upload(paths.map { UploadSource(url: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) })
        case "settings":
            showSettings(nil)
            let pane = url.pathComponents.dropFirst().first?.lowercased()
            if let pane, ["general", "hosts", "shortcuts"].contains(pane) {
                settingsController?.showPane(titled: pane.capitalized)
            }
        default:
            NSSound.beep()
        }
    }

    /// Opening Pinup again while it runs shows History.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showHistory(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Hot keys

    @objc private func settingsChanged() {
        registerHotKeys()
    }

    private func registerHotKeys() {
        let wanted = (clipboard: Settings.clipboardHotKey, screenshot: Settings.screenshotHotKey)
        if let registered, registered.clipboard == wanted.clipboard, registered.screenshot == wanted.screenshot { return }
        registered = wanted
        let center = HotKeyCenter.shared
        center.set(HotKeyID.clipboard.rawValue, wanted.clipboard) { [weak self] in self?.uploadClipboard(nil) }
        center.set(HotKeyID.screenshot.rawValue, wanted.screenshot) { [weak self] in self?.captureScreenshot(nil) }
        let failed = center.apply()
        failedHotKeys = []
        if failed.contains(HotKeyID.clipboard.rawValue) { failedHotKeys.append(wanted.clipboard?.displayString ?? "") }
        if failed.contains(HotKeyID.screenshot.rawValue) { failedHotKeys.append(wanted.screenshot?.displayString ?? "") }
    }

    // MARK: Actions

    @objc func uploadFiles(_ sender: Any?) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Upload Files"
        panel.prompt = "Upload"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .pdf, .data]
        panel.begin { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                Uploader.shared.upload(panel.urls.map { UploadSource(url: $0) })
            }
        }
    }

    @objc func uploadClipboard(_ sender: Any?) {
        Task {
            let sources = await Capture.clipboard()
            guard !sources.isEmpty else {
                HUD.shared.showMessage("Nothing to upload", "Copy an image or a file first.", symbol: "doc.on.clipboard")
                return
            }
            Uploader.shared.upload(sources)
        }
    }

    @objc func captureScreenshot(_ sender: Any?) {
        Task {
            guard let source = await Capture.screenshot() else { return }
            Uploader.shared.upload([source])
        }
    }

    @objc func showHistory(_ sender: Any?) {
        let controller = historyController ?? HistoryWindowController()
        historyController = controller
        // Rebuilt on next open; a closed window holds no thumbnails.
        controller.onClose = { [weak self] in self?.historyController = nil }
        NSApp.activate()
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    private func showWelcome() {
        let controller = welcomeController ?? WelcomeWindowController()
        welcomeController = controller
        controller.onClose = { [weak self] in self?.welcomeController = nil }
        controller.onSetUpHost = { [weak self] in
            self?.showSettings(nil)
            self?.settingsController?.showPane(titled: HostsSettingsPane.paneTitle)
        }
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate()
        let credits = NSMutableAttributedString(
            string: "Upload images from the menu bar and paste the link anywhere.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(
            string: "Native AppKit, no dependencies.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func showSettings(_ sender: Any?) {
        let controller = settingsController ?? SettingsWindowController()
        settingsController = controller
        NSApp.activate()
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }
}
