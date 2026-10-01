import CryptoKit
import Foundation

/// An S3-compatible bucket: AWS S3, Cloudflare R2, Aliyun OSS, Tencent COS,
/// MinIO and the like. The secret key is in `Secrets`.
struct S3Config: Codable, Equatable, Sendable {
    /// Like `https://s3.us-east-1.amazonaws.com` or `https://<account>.r2.cloudflarestorage.com`.
    var endpoint = ""
    /// `auto` for R2.
    var region = "us-east-1"
    var bucket = ""
    var accessKeyID = ""
    /// `endpoint/bucket/key` instead of `bucket.endpoint/key`. R2 and MinIO need it.
    var pathStyle = true
    var keyTemplate = "{year}/{month}/{timestamp}-{random}.{ext}"
    /// The address files are public at, such as a CDN domain. Empty uses the
    /// object's own URL. `{key}` places the key; without it the key is appended.
    var publicURL = ""
}

struct S3Host: UploadHost {
    let config: S3Config
    let secret: String
    var name: String { HostKind.s3.displayName }

    func request(for file: PreparedFile, scratch: URL) throws -> UploadRequest {
        try request(for: file, key: PathTemplate.render(config.keyTemplate, file: file), date: Date())
    }

    /// Signs a PUT of `file` to `key` as of `date`.
    func request(for file: PreparedFile, key: String, date now: Date) throws -> UploadRequest {
        let endpoint = config.endpoint.trimmingCharacters(in: .whitespaces)
        guard var components = URLComponents(string: endpoint), components.scheme != nil, let host = components.host,
            !config.bucket.isEmpty, !config.accessKeyID.isEmpty, !secret.isEmpty
        else {
            throw UploadError.notConfigured("Fill in the endpoint, bucket and keys for S3 in Settings > Hosts.")
        }
        let encodedKey = key.split(separator: "/", omittingEmptySubsequences: false).map { Self.uriEncode(String($0)) }
            .joined(separator: "/")
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = basePath.isEmpty ? "" : "/" + basePath
        if config.pathStyle {
            components.percentEncodedPath = "\(prefix)/\(Self.uriEncode(config.bucket))/\(encodedKey)"
        } else {
            components.host = "\(config.bucket).\(host)"
            components.percentEncodedPath = "\(prefix)/\(encodedKey)"
        }
        guard let url = components.url, let signedHost = components.host else {
            throw UploadError.notConfigured("The S3 endpoint isn't a valid URL.")
        }
        let hostHeader = components.port.map { "\(signedHost):\($0)" } ?? signedHost

        let amzDate = Self.format(now, "yyyyMMdd'T'HHmmss'Z'")
        let day = Self.format(now, "yyyyMMdd")
        let region = config.region.isEmpty ? "us-east-1" : config.region
        let payloadHash = try Self.sha256Hex(of: file.url)

        let headers: [(String, String)] = [
            ("content-type", file.mimeType),
            ("host", hostHeader),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", amzDate),
        ]
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalRequest = [
            "PUT",
            components.percentEncodedPath,
            "",
            headers.map { "\($0.0):\($0.1)\n" }.joined(),
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope,
            SHA256.hash(data: Data(canonicalRequest.utf8)).hex,
        ].joined(separator: "\n")
        var signingKey = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for part in [day, region, "s3", "aws4_request"] {
            signingKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: signingKey)))
        }
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey)).hex

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(config.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
        return UploadRequest(request: request, body: file.url, key: key)
    }

    func link(from data: Data, file: PreparedFile, request: UploadRequest) throws -> String {
        let key = request.key ?? ""
        let base = config.publicURL.trimmingCharacters(in: .whitespaces)
        let encodedKey = key.split(separator: "/").map { Self.uriEncode(String($0)) }.joined(separator: "/")
        if base.isEmpty { return request.request.url?.absoluteString ?? "" }
        if base.contains("{key}") { return base.replacingOccurrences(of: "{key}", with: encodedKey) }
        return base.hasSuffix("/") ? base + encodedKey : base + "/" + encodedKey
    }

    /// AWS's URI encoding: everything but unreserved characters.
    static func uriEncode(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// Hashes the file in 1 MB chunks so large files never sit in memory.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().hex
    }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
