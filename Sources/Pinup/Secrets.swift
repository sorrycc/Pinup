import Foundation

/// Host tokens and keys, in secrets.json in Pinup's folder, readable by your
/// user only. Not the keychain: an ad-hoc signed app loses keychain access
/// each time it is rebuilt, and macOS then asks for the login password.
@MainActor
enum Secrets {
    enum Item: String, CaseIterable {
        case picToken = "pic.sorrycc.token"
        case s3Secret = "s3.secretAccessKey"
        case customHeaders = "custom.headers"
    }

    private static let url = AppPaths.root.appendingPathComponent("secrets.json")
    private static var values: [String: String] = load()

    static func get(_ item: Item) -> String {
        values[item.rawValue] ?? ""
    }

    static func set(_ item: Item, _ value: String) {
        guard get(item) != value else { return }
        values[item.rawValue] = value.isEmpty ? nil : value
        save()
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func save() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        // Created with 0600 before any secret is written into it.
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: url, options: [.atomic])
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
