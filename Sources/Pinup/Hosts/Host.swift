import Foundation

enum UploadError: LocalizedError {
    case notConfigured(String)
    case processing(String)
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message), .processing(let message), .badResponse(let message): message
        case .http(let status, let body):
            body.isEmpty
                ? "The server answered \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))."
                : "The server answered \(status): \(body.prefix(200))"
        }
    }
}

/// A request ready to send, with its body in a file so it streams from disk.
struct UploadRequest: Sendable {
    var request: URLRequest
    var body: URL
    /// Where the file lands on hosts that pick the path, like S3's object key.
    var key: String?
}

/// Somewhere files go. Hosts are values made from settings on the main actor
/// for each upload, then used off it.
protocol UploadHost: Sendable {
    var name: String { get }
    func request(for file: PreparedFile, scratch: URL) throws -> UploadRequest
    /// The public link from the server's reply to a successful request.
    func link(from data: Data, file: PreparedFile, request: UploadRequest) throws -> String
}

extension UploadHost {
    /// Text from an error reply worth showing: JSON `message`/`error`/`msg`,
    /// an S3 `<Message>`, or the start of the body.
    static func errorText(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error", "msg", "detail"] {
                if let text = json[key] as? String { return text }
                if let nested = json[key] as? [String: Any], let text = nested["message"] as? String { return text }
            }
        }
        let text = String(decoding: data.prefix(2000), as: UTF8.self)
        if let start = text.range(of: "<Message>"), let end = text.range(of: "</Message>", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Fills `{year}`, `{month}`, `{day}`, `{timestamp}`, `{random}`, `{name}`
/// (the file name without its extension) and `{ext}` in a path template.
enum PathTemplate {
    static func render(_ template: String, file: PreparedFile, date: Date = Date()) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(in: .current, from: date)
        let ext = (file.name as NSString).pathExtension
        let base = (file.name as NSString).deletingPathExtension
        let random = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        let values: [String: String] = [
            "{year}": String(format: "%04d", parts.year ?? 0),
            "{month}": String(format: "%02d", parts.month ?? 0),
            "{day}": String(format: "%02d", parts.day ?? 0),
            "{timestamp}": String(Int(date.timeIntervalSince1970)),
            "{random}": random,
            "{name}": base,
            "{ext}": ext,
        ]
        var result = template
        for (key, value) in values { result = result.replacingOccurrences(of: key, with: value) }
        // A template without {ext} would lose the type.
        if !template.contains("{ext}"), !ext.isEmpty, !result.lowercased().hasSuffix("." + ext.lowercased()) {
            result += "." + ext
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// Writes request bodies to disk without holding the file in memory.
enum BodyWriter {
    /// `prefix`, then `file` in base64, then `suffix`. The file is read and
    /// encoded in chunks whose size is a multiple of three, so the pieces join
    /// into one valid base64 string.
    static func base64(to url: URL, prefix: Data, file: URL, suffix: Data) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try out.write(contentsOf: prefix)
        while let chunk = try input.read(upToCount: 3 << 18), !chunk.isEmpty {
            try out.write(contentsOf: chunk.base64EncodedData())
        }
        try out.write(contentsOf: suffix)
    }

    /// A string as a JSON literal, quotes included.
    static func json(_ string: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: string, options: .fragmentsAllowed)
    }
}
