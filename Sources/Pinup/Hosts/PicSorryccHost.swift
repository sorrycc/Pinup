import Foundation

/// pic.sorrycc.com: a JSON body with the file in base64, Bearer token auth,
/// and `{"data": "<url>"}` back.
struct PicSorryccHost: UploadHost {
    static let endpoint = URL(string: "https://pic.sorrycc.com/api/upload")!

    let token: String
    var name: String { HostKind.picSorrycc.displayName }

    func request(for file: PreparedFile, scratch: URL) throws -> UploadRequest {
        guard !token.isEmpty else {
            throw UploadError.notConfigured("Add your pic.sorrycc.com token in Settings > Hosts.")
        }
        // The API takes the file inline as base64, encoded into the body file in chunks.
        let bodyURL = scratch.appendingPathComponent("body.json")
        var prefix = Data(#"{"fileName":"#.utf8)
        prefix.append(try BodyWriter.json(file.name))
        prefix.append(Data(#","file":""#.utf8))
        try BodyWriter.base64(to: bodyURL, prefix: prefix, file: file.url, suffix: Data(#""}"#.utf8))

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return UploadRequest(request: request, body: bodyURL)
    }

    func link(from data: Data, file: PreparedFile, request: UploadRequest) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let url = json["data"] as? String, !url.isEmpty
        else {
            throw UploadError.badResponse("pic.sorrycc.com answered without a link: \(Self.errorText(data))")
        }
        return url
    }
}
