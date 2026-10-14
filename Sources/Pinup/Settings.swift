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

/// A kind of host: how files are sent. Each host the user adds is one of these.
enum Provider: String, Codable, CaseIterable, Sendable {
    case s3
    case custom

    var displayName: String {
        switch self {
        case .s3: "S3-Compatible"
        case .custom: "Custom HTTP"
        }
    }

    var symbol: String {
        switch self {
        case .s3: "externaldrive.connected.to.line.below"
        case .custom: "network"
        }
    }
}

/// A host the user added: a name, its provider and that provider's settings.
/// Its secret, the S3 secret key or the custom headers, is in `Secrets`
/// under `secretKey`.
struct HostConfig: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var provider: Provider
    var s3: S3Config?
    var custom: CustomConfig?

    init(name: String, provider: Provider) {
        self.name = name
        self.provider = provider
        switch provider {
        case .s3: s3 = S3Config()
        case .custom: custom = CustomConfig()
        }
    }

    var secretKey: String {
        "\(id.uuidString).\(provider == .s3 ? "secretAccessKey" : "headers")"
    }

    /// Hosts made from the single S3 and custom configs of earlier versions.
    /// Configs left at their defaults with no secret are dropped. Each is
    /// named after its bucket or address.
    static func migrated(s3: S3Config?, s3Secret: String, custom: CustomConfig?, headers: String) -> [HostConfig] {
        var hosts: [HostConfig] = []
        if let s3, s3 != S3Config() || !s3Secret.isEmpty {
            let name = s3.bucket.isEmpty ? URL(string: s3.endpoint)?.host() : s3.bucket
            var host = HostConfig(name: name ?? Provider.s3.displayName, provider: .s3)
            host.s3 = s3
            hosts.append(host)
        }
        if let custom, custom != CustomConfig() || !headers.isEmpty {
            let name = URL(string: custom.url.replacingOccurrences(of: "{name}", with: "x"))?.host()
            var host = HostConfig(name: name ?? Provider.custom.displayName, provider: .custom)
            host.custom = custom
            hosts.append(host)
        }
        return hosts
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

    static var hosts: [HostConfig] {
        get { decode("hosts") ?? [] }
        set { encode("hosts", newValue) }
    }

    static var selectedHostID: UUID? {
        get { defaults.string(forKey: "selectedHost").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "selectedHost"); changed() }
    }

    /// Where uploads go: the chosen host, or the first if that one is gone.
    static var selectedHost: HostConfig? {
        let hosts = hosts
        return hosts.first { $0.id == selectedHostID } ?? hosts.first
    }

    /// Saves changes to a host already in the list.
    static func update(_ host: HostConfig) {
        var list = hosts
        guard let index = list.firstIndex(where: { $0.id == host.id }), list[index] != host else { return }
        list[index] = host
        hosts = list
    }

    /// Adds a host named after its provider, numbered when the name is taken,
    /// and selects it.
    @discardableResult
    static func addHost(_ provider: Provider) -> HostConfig {
        var list = hosts
        let names = Set(list.map(\.name))
        var name = provider.displayName
        var number = 2
        while names.contains(name) {
            name = "\(provider.displayName) \(number)"
            number += 1
        }
        let host = HostConfig(name: name, provider: provider)
        list.append(host)
        hosts = list
        selectedHostID = host.id
        return host
    }

    /// Removes a host and its secret.
    static func removeHost(_ host: HostConfig) {
        Secrets.set(host.secretKey, "")
        hosts.removeAll { $0.id == host.id }
        if selectedHostID == host.id { selectedHostID = hosts.first?.id }
    }

    /// Turns the single S3 and custom configs of earlier versions into hosts,
    /// once. Their secrets move to the new hosts' keys.
    static func migrateHosts() {
        guard defaults.object(forKey: "hosts") == nil else { return }
        let oldSelection = defaults.string(forKey: "host")
        let migrated = HostConfig.migrated(
            s3: decode("s3"), s3Secret: Secrets.get("s3.secretAccessKey"),
            custom: decode("custom"), headers: Secrets.get("custom.headers"))
        for host in migrated {
            Secrets.set(host.secretKey, Secrets.get(host.provider == .s3 ? "s3.secretAccessKey" : "custom.headers"))
        }
        Secrets.set("s3.secretAccessKey", "")
        Secrets.set("custom.headers", "")
        hosts = migrated
        selectedHostID = (migrated.first { $0.provider.rawValue == oldSelection } ?? migrated.first)?.id
        for key in ["host", "s3", "custom"] { defaults.removeObject(forKey: key) }
    }

    private static func decode<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func encode<T: Encodable>(_ key: String, _ value: T) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
        changed()
    }
}
