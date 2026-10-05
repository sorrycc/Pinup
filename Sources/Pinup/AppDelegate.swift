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
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)

        // `-show history` or `-show <settings pane>` opens a window at launch.
        switch UserDefaults.standard.string(forKey: "show")?.lowercased() {
        case "history":
            showHistory(nil)
        case "welcome":
            showWelcome()
        case let debug? where ["menu", "hud", "hud-failure"].contains(debug):
            // Once the status item has its place in the menu bar.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showForDesign(debug) }
        case let pane? where ["general", "hosts", "shortcuts"].contains(pane):
            showSettings(nil)
            settingsController?.showPane(titled: pane.capitalized)
        default:
            if !WelcomeWindowController.wasShown { showWelcome() }
        }
    }

    /// `-show menu`, `hud` or `hud-failure`: the surfaces no window holds, for
    /// checking the design.
    private func showForDesign(_ what: String) {
        switch what {
        case "menu":
            statusItem?.openMenu()
        case "hud":
            if let entry = History.shared.entries.first {
                HUD.shared.showSuccess(entry, count: 1, format: Settings.linkFormat)
            } else {
                HUD.shared.showMessage("Nothing to upload", "Copy an image or a file first.", symbol: "doc.on.clipboard")
            }
        default:
            HUD.shared.showFailure(
                "Screenshot.png: The server answered 401 Unauthorized.", hint: "Click to open Settings.")
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

    /// Quitting while files upload asks first, so no screenshot or finished
    /// link is lost without a word.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let uploader = Uploader.shared
        guard uploader.isBusy else { return .terminateNow }
        // Asked again while already waiting for the uploads: still waiting.
        if uploader.onIdle != nil { return .terminateLater }
        NSApp.activate()
        let count = max(1, uploader.activeCount)
        let alert = NSAlert()
        alert.messageText = count == 1 ? "An upload is still in progress." : "\(count) uploads are still in progress."
        alert.informativeText = "Pinup can quit as soon as \(count == 1 ? "it finishes" : "they finish"). Quitting now stops \(count == 1 ? "it" : "them"), and keeps screenshots and pasted images to try again next time."
        alert.addButton(withTitle: "Quit When Finished")
        alert.addButton(withTitle: "Quit Now")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // They may have finished while the question was up.
            guard uploader.isBusy else { return .terminateNow }
            uploader.onIdle = { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        case .alertSecondButtonReturn:
            uploader.abandon()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        History.shared.flush()
    }

    /// Closing the last window hands the menu bar back to the previous app.
    /// Otherwise an accessory app stays active with nothing on screen, and
    /// its menus linger over the desktop.
    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing.styleMask.contains(.titled) else { return }
        DispatchQueue.main.async {
            let stillOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
            if !stillOpen { NSApp.hide(nil) }
        }
    }

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
