import Foundation

/// Any HTTP upload API, described in settings. Headers, which usually carry
/// the token, are in `Secrets`.
struct CustomConfig: Codable, Equatable, Sendable {
    enum Body: String, Codable, CaseIterable, Sendable {
        case multipart
        case json
        case binary

        var displayName: String {
            switch self {
            case .multipart: "Multipart Form"
            case .json: "JSON with Base64"
            case .binary: "Raw File"
            }
        }
    }

    /// `{name}` is replaced by the file's name, for APIs that take it in the path.
    var url = ""
    var method = "POST"
    var body = Body.multipart
    /// The form field or JSON key that holds the file.
    var fileField = "file"
    /// Extra form fields or JSON keys, one `key=value` per line.
    var fields = ""
    /// Where the link is in a JSON reply, like `data.url` or `data.links.0`.
    /// Empty takes the whole reply as the link.
    var urlPath = "data.url"
    /// Put before the value found, for APIs that return a path.
    var urlPrefix = ""
}

struct CustomHost: UploadHost {
    let config: CustomConfig
    /// One `Name: value` per line.
    let headers: String
    var name: String { HostKind.custom.displayName }

    func request(for file: PreparedFile, scratch: URL) throws -> UploadRequest {
        let address = config.url.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "{name}", with: file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.name)
        guard let url = URL(string: address), url.scheme == "http" || url.scheme == "https" else {
            throw UploadError.notConfigured("Set the upload URL for Custom HTTP in Settings > Hosts.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = config.method.isEmpty ? "POST" : config.method.uppercased()
        for line in headers.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { request.setValue(value, forHTTPHeaderField: name) }
        }
        let fields = Self.pairs(config.fields)
        let field = config.fileField.isEmpty ? "file" : config.fileField

        switch config.body {
        case .binary:
            request.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
            return UploadRequest(request: request, body: file.url)

        case .json:
            var object: [String: Any] = [:]
            for (key, value) in fields where key != field { object[key] = value }
            if field != "fileName", object["fileName"] == nil { object["fileName"] = file.name }
            // The other keys as JSON, then the file's key and its base64 streamed in last.
            var prefix = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            prefix.removeLast()  // the closing brace
            prefix.append(Data(",".utf8))
            prefix.append(try BodyWriter.json(field))
            prefix.append(Data(#":""#.utf8))
            let bodyURL = scratch.appendingPathComponent("body.json")
            try BodyWriter.base64(to: bodyURL, prefix: prefix, file: file.url, suffix: Data(#""}"#.utf8))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return UploadRequest(request: request, body: bodyURL)

        case .multipart:
            let boundary = "Pinup-" + UUID().uuidString
            let bodyURL = scratch.appendingPathComponent("body.multipart")
            try Self.writeMultipart(to: bodyURL, boundary: boundary, fields: fields, field: field, file: file)
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            return UploadRequest(request: request, body: bodyURL)
        }
    }

    func link(from data: Data, file: PreparedFile, request: UploadRequest) throws -> String {
        let path = config.urlPath.trimmingCharacters(in: .whitespaces)
        var found: String?
        if path.isEmpty {
            found = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let json = try? JSONSerialization.jsonObject(with: data) {
            found = Self.value(at: path, in: json)
        }
        guard let found, !found.isEmpty else {
            throw UploadError.badResponse("No link at \"\(path)\" in the reply: \(Self.errorText(data))")
        }
        return config.urlPrefix + found
    }

    /// Follows a dotted path through dictionaries and arrays.
    static func value(at path: String, in json: Any) -> String? {
        var current: Any? = json
        for part in path.split(separator: ".") {
            if let dict = current as? [String: Any] {
                current = dict[String(part)]
            } else if let array = current as? [Any], let index = Int(part), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        if let string = current as? String { return string }
        if let number = current as? NSNumber { return number.stringValue }
        return nil
    }

    static func pairs(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : (key, line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Writes the form to disk, copying the file in chunks.
    private static func writeMultipart(to url: URL, boundary: String, fields: [(String, String)], field: String, file: PreparedFile) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        func write(_ text: String) throws { try out.write(contentsOf: Data(text.utf8)) }
        for (key, value) in fields {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        let quotedName = file.name.replacingOccurrences(of: "\"", with: "%22")
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(quotedName)\"\r\n")
        try write("Content-Type: \(file.mimeType)\r\n\r\n")
        let input = try FileHandle(forReadingFrom: file.url)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
    }
}
