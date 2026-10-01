import AppKit

/// How a link is written to the clipboard after an upload.
enum LinkFormat: String, CaseIterable, Sendable {
    case url
    case markdown
    case html

    var displayName: String {
        switch self {
        case .url: "URL"
        case .markdown: "Markdown"
        case .html: "HTML"
        }
    }

    func format(_ url: String, name: String) -> String {
        switch self {
        case .url: url
        case .markdown: "![\(Self.alt(name))](\(url))"
        case .html: "<img src=\"\(url)\" alt=\"\(Self.alt(name))\">"
        }
    }

    /// The file name without its extension, with characters that would break
    /// the markup removed.
    private static func alt(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.filter { !"[]<>\"".contains($0) }
    }
}

/// What an image is converted to before it is uploaded.
enum ImageConversion: String, CaseIterable, Sendable {
    case original
    case jpeg
    case heic

    var displayName: String {
        switch self {
        case .original: "Keep Original"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }
}

/// Which host uploads go to.
enum HostKind: String, CaseIterable, Sendable {
    case picSorrycc
    case s3
    case custom

    var displayName: String {
        switch self {
        case .picSorrycc: "pic.sorrycc.com"
        case .s3: "S3-Compatible"
        case .custom: "Custom HTTP"
        }
    }

    var symbol: String {
        switch self {
        case .picSorrycc: "photo.on.rectangle"
        case .s3: "externaldrive.connected.to.line.below"
        case .custom: "network"
        }
    }
}

extension Notification.Name {
    /// Posted on the main thread whenever a setting changes.
    static let settingsDidChange = Notification.Name("PinupSettingsDidChange")
}

/// Every setting, stored in user defaults. Secrets live in secrets.json
/// instead, see `Secrets`.
@MainActor
enum Settings {
    private static let defaults = UserDefaults.standard

    private static func changed() {
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    private static func get<T: RawRepresentable<String>>(_ key: String, _ fallback: T) -> T {
        defaults.string(forKey: key).flatMap { T(rawValue: $0) } ?? fallback
    }

    private static func set<T: RawRepresentable<String>>(_ key: String, _ value: T) {
        defaults.set(value.rawValue, forKey: key)
        changed()
    }

    static var host: HostKind {
        get { get("host", .picSorrycc) }
        set { set("host", newValue) }
    }

    static var linkFormat: LinkFormat {
        get { get("linkFormat", .markdown) }
        set { set("linkFormat", newValue) }
    }

    static var conversion: ImageConversion {
        get { get("conversion", .original) }
        set { set("conversion", newValue) }
    }

    /// 0.1 to 1, for JPEG and HEIC conversion.
    static var quality: Double {
        get { defaults.object(forKey: "quality") as? Double ?? 0.85 }
        set { defaults.set(min(1, max(0.1, newValue)), forKey: "quality"); changed() }
    }

    /// Drops GPS data from photos before they leave the Mac.
    static var stripLocation: Bool {
        get { defaults.object(forKey: "stripLocation") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stripLocation"); changed() }
    }

    static var playSound: Bool {
        get { defaults.object(forKey: "playSound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "playSound"); changed() }
    }

    static var clipboardHotKey: HotKey? {
        get { hotKey("clipboardHotKey", fallback: HotKey(keyCode: 32, modifiers: [.option, .shift, .command], key: "U")) }
        set { setHotKey("clipboardHotKey", newValue) }
    }

    static var screenshotHotKey: HotKey? {
        get { hotKey("screenshotHotKey", fallback: HotKey(keyCode: 1, modifiers: [.option, .shift, .command], key: "S")) }
        set { setHotKey("screenshotHotKey", newValue) }
    }

    /// An empty string stored means the user cleared it.
    private static func hotKey(_ key: String, fallback: HotKey) -> HotKey? {
        guard let text = defaults.string(forKey: key) else { return fallback }
        return HotKey(text: text)
    }

    private static func setHotKey(_ key: String, _ value: HotKey?) {
        defaults.set(value?.text ?? "", forKey: key)
        changed()
    }

    // MARK: Host configuration

    static var s3: S3Config {
        get { decode("s3") ?? S3Config() }
        set { encode("s3", newValue) }
    }

    static var custom: CustomConfig {
        get { decode("custom") ?? CustomConfig() }
        set { encode("custom", newValue) }
    }

    private static func decode<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func encode<T: Encodable>(_ key: String, _ value: T) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
        changed()
    }
}
