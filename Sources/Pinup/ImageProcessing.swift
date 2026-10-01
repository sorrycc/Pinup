import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file ready to upload, after any conversion.
struct PreparedFile: Sendable {
    let url: URL
    /// The name to upload under, with the extension of the final format.
    let name: String
    let mimeType: String
    let size: Int
    /// Pixel size, or zero for files that aren't images.
    let width: Int
    let height: Int
    /// A small JPEG or PNG for history, nil for files that aren't images.
    let thumbnail: Data?
}

/// What to do to an image before upload, read from settings on the main actor.
struct ProcessingOptions: Sendable {
    var conversion: ImageConversion
    var quality: Double
    var stripLocation: Bool
}

/// Image work, all through ImageIO so nothing is decoded that doesn't need to be.
/// Runs off the main thread.
enum ImageProcessing {
    static let thumbnailPixels = 360

    static func prepare(_ source: URL, name: String, options: ProcessingOptions, scratch: URL) throws -> PreparedFile {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
            let type = CGImageSourceGetType(image) as String?,
            CGImageSourceGetCount(image) > 0
        else {
            return try passThrough(source, name: name)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let hasGPS = properties[kCGImagePropertyGPSDictionary] != nil
        let thumbnail = makeThumbnail(image, hasAlpha: hasAlpha)
        let animated = CGImageSourceGetCount(image) > 1

        var target = targetType(for: options.conversion, current: type, hasAlpha: hasAlpha, animated: animated)
        // ImageIO can't write WebP or camera RAW, so removing their location
        // means converting them: PNG keeps transparency, JPEG suits photos.
        if target == nil, options.stripLocation, hasGPS, !writableTypes.contains(type) {
            target = hasAlpha ? UTType.png.identifier : UTType.jpeg.identifier
        }
        // A file with no extension gets the one its contents call for.
        var name = name
        if (name as NSString).pathExtension.isEmpty, let ext = UTType(type)?.preferredFilenameExtension {
            name += "." + ext
        }
        let base = (name as NSString).deletingPathExtension
        // Outputs get their own folder, so one can never overwrite its source.
        let outFolder = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        var output = source
        var outputName = name

        if let target {
            // Re-encode: a new format, at the chosen quality, without GPS when asked.
            let ext = target == UTType.jpeg.identifier ? "jpg" : UTType(target)?.preferredFilenameExtension ?? "jpg"
            outputName = base + "." + ext
            output = outFolder.appendingPathComponent(outputName)
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, target as CFString, 1, nil) else {
                throw UploadError.processing("Can't write \(ext.uppercased()) images.")
            }
            var add: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: options.quality]
            if options.stripLocation, hasGPS { add[kCGImagePropertyGPSDictionary] = kCFNull! }
            CGImageDestinationAddImageFromSource(destination, image, 0, add as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw UploadError.processing("Couldn't convert \(name) to \(ext.uppercased()).")
            }
        } else if options.stripLocation, hasGPS {
            // Same format, without GPS. JPEG metadata can be rewritten leaving
            // the pixels as they are; other formats are written again at full
            // quality, which is lossless for PNG and TIFF.
            output = outFolder.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else {
                return try passThrough(source, name: name)
            }
            if type == UTType.jpeg.identifier {
                let copy: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
                var error: Unmanaged<CFError>?
                guard CGImageDestinationCopyImageSource(destination, image, copy as CFDictionary, &error) else {
                    throw UploadError.processing("Couldn't remove the location from \(name).")
                }
            } else {
                let add: [CFString: Any] = [kCGImagePropertyGPSDictionary: kCFNull!, kCGImageDestinationLossyCompressionQuality: 1.0]
                CGImageDestinationAddImageFromSource(destination, image, 0, add as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw UploadError.processing("Couldn't remove the location from \(name).")
                }
            }
        }

        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return PreparedFile(
            url: output, name: outputName, mimeType: mimeType(for: outputName), size: size,
            width: width, height: height, thumbnail: thumbnail)
    }

    private static let writableTypes = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])

    /// The type to convert to, or nil to keep the file's own. Transparent
    /// images stay out of JPEG, and animations stay as they are.
    private static func targetType(for conversion: ImageConversion, current: String, hasAlpha: Bool, animated: Bool) -> String? {
        guard !animated else { return nil }
        switch conversion {
        case .original:
            return nil
        case .jpeg:
            return hasAlpha || current == UTType.jpeg.identifier ? nil : UTType.jpeg.identifier
        case .heic:
            return current == UTType.heic.identifier ? nil : UTType.heic.identifier
        }
    }

    private static func passThrough(_ source: URL, name: String) throws -> PreparedFile {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return PreparedFile(
            url: source, name: name, mimeType: mimeType(for: name), size: size, width: 0, height: 0, thumbnail: nil)
    }

    static func mimeType(for name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func makeThumbnail(_ image: CGImageSource, hasAlpha: Bool) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        let type = hasAlpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumb, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Decodes a stored thumbnail now, off the main thread, so drawing it is free.
    static func decodeThumbnail(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// PNG data for a TIFF or other pasteboard image, for upload.
    static func png(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
