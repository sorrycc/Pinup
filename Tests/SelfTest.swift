// Checks Pinup's logic without the UI. Run with scripts/selftest.sh.
import AppKit
import ImageIO

@MainActor var failures = 0

@MainActor func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name) \(detail())")
    }
}

@main
struct SelfTest {
    @MainActor static func main() async throws {
        let scratch = AppPaths.scratch()

        // Link formats
        check(LinkFormat.markdown.format("https://x/a.png", name: "My [shot].png") == "![My shot](https://x/a.png)", "markdown")
        check(LinkFormat.html.format("https://x/a.png", name: "a.png") == "<img src=\"https://x/a.png\" alt=\"a\">", "html")

        // Path templates
        let fake = PreparedFile(url: scratch, name: "Cat Pic.png", mimeType: "image/png", size: 1, width: 1, height: 1, thumbnail: nil)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let rendered = PathTemplate.render("{year}/{month}/{name}.{ext}", file: fake, date: date)
        check(rendered.hasSuffix("/Cat Pic.png") && rendered.split(separator: "/").count == 3, "template", rendered)
        check(PathTemplate.render("img/{random}", file: fake).hasSuffix(".png"), "template adds extension")

        let dotted = PreparedFile(url: scratch, name: "Pasted Image 2026-10-01 at 12.30.45.png", mimeType: "image/png", size: 1, width: 1, height: 1, thumbnail: nil)
        let dottedKey = PathTemplate.render("{year}/{name}", file: dotted, date: date)
        check(dottedKey.hasSuffix("12.30.45.png"), "template keeps extension for dotted names", dottedKey)

        // Streamed base64 bodies match one-shot encoding, across chunk edges
        for count in [0, 1, 2, 3, 786_431, 786_432, 786_433, 2_000_001] {
            let blob = scratch.appendingPathComponent("blob-\(count)")
            let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            try bytes.write(to: blob)
            let out = scratch.appendingPathComponent("blob-\(count).b64")
            try BodyWriter.base64(to: out, prefix: Data("<".utf8), file: blob, suffix: Data(">".utf8))
            let expected = "<" + bytes.base64EncodedString() + ">"
            check(try String(contentsOf: out, encoding: .utf8) == expected, "base64 stream \(count) bytes")
        }
        // Custom JSON body is valid JSON with fields, fileName and the file
        let customFile = scratch.appendingPathComponent("c.png")
        try Data("hello".utf8).write(to: customFile)
        var custom = CustomConfig()
        custom.url = "https://example.com/up"
        custom.body = .json
        custom.fileField = "image"
        custom.fields = "album=cats\nimage=ignored"
        let customPrepared = PreparedFile(url: customFile, name: "c \"q\".png", mimeType: "image/png", size: 5, width: 0, height: 0, thumbnail: nil)
        let customRequest = try CustomHost(config: custom, headers: "Authorization: Bearer x").request(for: customPrepared, scratch: scratch)
        let customBody = try JSONSerialization.jsonObject(with: Data(contentsOf: customRequest.body)) as? [String: String]
        check(customBody == ["album": "cats", "fileName": "c \"q\".png", "image": Data("hello".utf8).base64EncodedString()], "custom JSON body", "\(String(describing: customBody))")
        check(customRequest.request.value(forHTTPHeaderField: "Authorization") == "Bearer x", "custom headers")
        // A token API's JSON shape: the file under "file", the name beside it,
        // and the whole link as "data" in the reply
        var token = CustomConfig()
        token.url = "https://example.com/api/upload"
        token.body = .json
        token.urlPath = "data"
        let tokenRequest = try CustomHost(config: token, headers: "Authorization: Bearer t").request(for: customPrepared, scratch: scratch)
        let tokenBody = try JSONSerialization.jsonObject(with: Data(contentsOf: tokenRequest.body)) as? [String: String]
        check(tokenBody == ["file": Data("hello".utf8).base64EncodedString(), "fileName": "c \"q\".png"], "token JSON body", "\(String(describing: tokenBody))")
        let tokenLink = try CustomHost(config: token, headers: "").link(from: Data(#"{"data":"https://x/a.png"}"#.utf8), file: customPrepared, request: tokenRequest)
        check(tokenLink == "https://x/a.png", "link at top-level key", tokenLink)

        // Hosts: Codable round trip, and the move from single configs
        var s3Host = HostConfig(name: "Mine", provider: .s3)
        s3Host.s3?.bucket = "b"
        let decodedHosts = try JSONDecoder().decode([HostConfig].self, from: JSONEncoder().encode([s3Host]))
        check(decodedHosts == [s3Host] && decodedHosts[0].custom == nil, "host round trip")
        check(s3Host.secretKey != HostConfig(name: "Mine", provider: .s3).secretKey, "secret keys per host")
        var oldS3 = S3Config()
        oldS3.endpoint = "https://acc.r2.cloudflarestorage.com"
        var oldCustom = CustomConfig()
        oldCustom.url = "https://up.example.com/{name}"
        let moved = HostConfig.migrated(s3: oldS3, s3Secret: "k", custom: oldCustom, headers: "")
        check(moved.map(\.name) == ["acc.r2.cloudflarestorage.com", "up.example.com"] && moved.map(\.provider) == [.s3, .custom], "migrated names", "\(moved.map(\.name))")
        oldS3.bucket = "pics"
        check(HostConfig.migrated(s3: oldS3, s3Secret: "", custom: nil, headers: "").map(\.name) == ["pics"], "migrated S3 named by bucket")
        check(HostConfig.migrated(s3: S3Config(), s3Secret: "", custom: CustomConfig(), headers: "").isEmpty, "untouched configs not migrated")
        check(HostConfig.migrated(s3: nil, s3Secret: "", custom: CustomConfig(), headers: "X: y").count == 1, "custom with only headers migrated")

        custom.fileField = "fileName"
        let nameFieldRequest = try CustomHost(config: custom, headers: "").request(for: customPrepared, scratch: scratch)
        let nameFieldBody = String(decoding: try Data(contentsOf: nameFieldRequest.body), as: UTF8.self)
        check(nameFieldBody.components(separatedBy: "\"fileName\"").count == 2, "no duplicate fileName key", nameFieldBody)

        custom.fields = ""
        let bareRequest = try CustomHost(config: custom, headers: "").request(for: customPrepared, scratch: scratch)
        let bareBody = try? JSONSerialization.jsonObject(with: Data(contentsOf: bareRequest.body)) as? [String: String]
        check(bareBody == ["fileName": Data("hello".utf8).base64EncodedString()], "JSON body with only the file", "\(String(describing: bareBody))")

        // Hot keys match by physical key, whatever the layout called it
        check(HotKey(keyCode: 1, modifiers: [.command, .option], key: "S") == HotKey(keyCode: 1, modifiers: [.command, .option], key: "Ы"), "hot key equality by key code")

        // JSON paths
        let json: Any = ["data": ["links": ["https://a", "https://b"], "id": 7]]
        check(CustomHost.value(at: "data.links.1", in: json) == "https://b", "json path array")
        check(CustomHost.value(at: "data.id", in: json) == "7", "json path number")
        check(CustomHost.value(at: "data.nope", in: json) == nil, "json path missing")

        // Hot key text round trip
        let hotKey = HotKey(keyCode: 32, modifiers: [.option, .shift, .command], key: "U")
        check(HotKey(text: hotKey.text) == hotKey && hotKey.displayString == "⌥⇧⌘U", "hot key")

        // Image processing: a PNG with GPS, converted and stripped
        let png = scratch.appendingPathComponent("photo.png")
        try makeImage(png, type: "public.png", gps: true, alpha: false)
        var options = ProcessingOptions(conversion: .original, quality: 0.8, stripLocation: true)
        let stripped = try ImageProcessing.prepare(png, name: "photo.png", options: options, scratch: scratch)
        check(stripped.url != png && !hasGPS(stripped.url) && stripped.name == "photo.png", "strip GPS keeps format",
              "url changed: \(stripped.url != png), gps: \(hasGPS(stripped.url)), name: \(stripped.name)")
        check(stripped.thumbnail != nil && stripped.width == 800, "thumbnail and size")
        options.conversion = .jpeg
        let jpeg = try ImageProcessing.prepare(png, name: "photo.png", options: options, scratch: scratch)
        check(jpeg.name == "photo.jpg" && jpeg.mimeType == "image/jpeg" && !hasGPS(jpeg.url), "convert to JPEG", jpeg.name)
        options.conversion = .heic
        let heic = try ImageProcessing.prepare(png, name: "photo.png", options: options, scratch: scratch)
        check(heic.name == "photo.heic" && heic.size > 0, "convert to HEIC")
        let alpha = scratch.appendingPathComponent("alpha.png")
        try makeImage(alpha, type: "public.png", gps: false, alpha: true)
        options.conversion = .jpeg
        let kept = try ImageProcessing.prepare(alpha, name: "alpha.png", options: options, scratch: scratch)
        check(kept.url == alpha && kept.name == "alpha.png", "transparent stays PNG")
        let bare = scratch.appendingPathComponent("noext")
        try FileManager.default.copyItem(at: png, to: bare)
        options.conversion = .original
        let named = try ImageProcessing.prepare(bare, name: "noext", options: options, scratch: scratch)
        check(named.name == "noext.png" && named.mimeType == "image/png", "missing extension added", named.name)
        options.conversion = .jpeg
        let text = scratch.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: text)
        let plain = try ImageProcessing.prepare(text, name: "notes.txt", options: options, scratch: scratch)
        check(plain.url == text && plain.mimeType == "text/plain" && plain.thumbnail == nil, "non-image passes through")

        // S3 signature, printed for comparison with botocore
        let body = scratch.appendingPathComponent("s3.png")
        try Data("pinup-s3-body".utf8).write(to: body)
        let s3File = PreparedFile(url: body, name: "s3.png", mimeType: "image/png", size: 13, width: 0, height: 0, thumbnail: nil)
        for (pathStyle, key) in [(true, "2026/10/hello.png"), (false, "2026/10/hello world+中.png")] {
            var config = S3Config()
            config.endpoint = "https://s3.example.com:9000"
            config.region = "auto"
            config.bucket = "pics"
            config.accessKeyID = "AKIDEXAMPLE"
            config.pathStyle = pathStyle
            let host = S3Host(config: config, secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
            let request = try host.request(for: s3File, key: key, date: Date(timeIntervalSince1970: 1_790_000_000))
            print("S3 \(request.request.url!.absoluteString) \(request.request.value(forHTTPHeaderField: "Authorization")!)")
            config.publicURL = "https://img.example.com/{key}"
            let link = try S3Host(config: config, secret: "x").link(from: Data(), file: s3File, request: request)
            check(link.hasPrefix("https://img.example.com/2026/10/hello"), "s3 public link", link)
        }

        // Menu rows: names cut in the middle, and one line of when and how big
        let longName = "Screenshot 2026-10-04 at 09.12.44 (annotated copy).png"
        let shortened = StatusItemController.menuTitle(longName)
        check(shortened.count == 34 && shortened.hasPrefix("Screenshot") && shortened.hasSuffix(".png") && shortened.contains("…"),
              "menu title cut in the middle", shortened)
        check(StatusItemController.menuTitle("a.png") == "a.png", "short menu title kept")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func entry(age: TimeInterval) -> HistoryEntry {
            HistoryEntry(
                id: UUID(), url: "https://x/a.png", name: "a.png", host: "x", size: 48_000, width: 1, height: 1,
                date: now.addingTimeInterval(-age), thumbnail: nil)
        }
        check(StatusItemController.menuSubtitle(entry(age: 5), now: now).hasPrefix("Just now · "), "menu subtitle just now")
        let hourAgo = StatusItemController.menuSubtitle(entry(age: 3600), now: now)
        check(hourAgo.contains(" · ") && !hourAgo.hasPrefix("Just now") && !hourAgo.contains("\n"), "menu subtitle one line", hourAgo)

        // Progress: weighed by size, and a finished file keeps its share
        check(Uploader.combinedProgress([]) == 0, "progress of nothing")
        check(Uploader.combinedProgress([(weight: 100, fraction: 1), (weight: 300, fraction: 0)]) == 0.25, "progress weighed by size")
        check(Uploader.combinedProgress([(weight: 1, fraction: 1), (weight: 1, fraction: 0.5)]) == 0.75, "finished file keeps its share")

        // History: a file that won't decode is set aside, never overwritten
        try Data("not json".utf8).write(to: AppPaths.history)
        check(History.shared.entries.isEmpty, "unreadable history starts empty")
        let aside = try FileManager.default.contentsOfDirectory(atPath: AppPaths.root.path).filter { $0.hasPrefix("history-unreadable-") }
        check(aside.count == 1 && !FileManager.default.fileExists(atPath: AppPaths.history.path), "unreadable history set aside", "\(aside)")

        // History: quitting saves at once and deletes removed uploads' thumbnails
        let thumbnailName = "\(UUID().uuidString).jpg"
        let thumbnailFile = AppPaths.thumbnails.appendingPathComponent(thumbnailName)
        try Data("thumb".utf8).write(to: thumbnailFile)
        let staying = HistoryEntry(id: UUID(), url: "https://x/kept.png", name: "kept.png", host: "x", size: 1, width: 1, height: 1, date: now, thumbnail: nil)
        let gone = HistoryEntry(id: UUID(), url: "https://x/gone.png", name: "gone.png", host: "x", size: 1, width: 1, height: 1, date: now, thumbnail: thumbnailName)
        History.shared.add([staying, gone])
        History.shared.remove([gone.id])
        History.shared.flush()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try? decoder.decode([HistoryEntry].self, from: Data(contentsOf: AppPaths.history))
        check(saved?.map(\.id) == [staying.id], "flush saves history at once", "\(String(describing: saved?.map(\.name)))")
        check(!FileManager.default.fileExists(atPath: thumbnailFile.path), "flush deletes removed thumbnails")

        // Every pane and window loads without throwing.
        _ = NSApplication.shared
        for pane in [GeneralSettingsPane(), HostsSettingsPane(), ShortcutsSettingsPane()] as [SettingsPane] {
            _ = pane.view
            let size = pane.preferredContentSize
            check(size.width > 300 && size.height > 100, "\(pane.title ?? "") pane loads", "\(size)")
        }
        let history = HistoryWindowController()
        check(history.window?.contentView != nil, "history window loads")

        try? FileManager.default.removeItem(at: scratch)
        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func makeImage(_ url: URL, type: String, gps: Bool, alpha: Bool) throws {
        let context = CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 30.27, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 120.15, kCGImagePropertyGPSLongitudeRef: "E",
            ]
        }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw UploadError.processing("test image") }
        if gps, !hasGPS(url) { print("note: \(type) didn't keep GPS in the fixture") }
    }

    static func hasGPS(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        return properties[kCGImagePropertyGPSDictionary] != nil
    }
}
