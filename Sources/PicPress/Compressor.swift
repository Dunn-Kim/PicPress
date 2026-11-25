import Foundation
import ImageIO
import UniformTypeIdentifiers

enum OutputFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case heic = "HEIC"

    var id: Self { self }
    var type: UTType { self == .jpeg ? .jpeg : .heic }
    var ext: String { self == .jpeg ? "jpg" : "heic" }
}

enum CompressError: LocalizedError {
    case unreadable, encodeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "이미지를 읽을 수 없습니다"
        case .encodeFailed: "인코딩에 실패했습니다"
        }
    }
}

/// Writes a compressed copy of `src` next to it as `name-picpress.ext` and returns its URL.
/// The original is never touched. EXIF/GPS metadata is dropped; orientation is baked into the pixels.
func compress(_ src: URL, quality: Double, maxPixel: Int?, format: OutputFormat) throws -> URL {
    guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int,
          let height = props[kCGImagePropertyPixelHeight] as? Int
    else { throw CompressError.unreadable }

    let longest = max(width, height)
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true, // apply EXIF orientation
        kCGImageSourceThumbnailMaxPixelSize: min(maxPixel ?? longest, longest), // never upscale
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { throw CompressError.unreadable }

    let dst = try reserveOutputURL(for: src, ext: format.ext)
    if let dest = CGImageDestinationCreateWithURL(dst as CFURL, format.type.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        if CGImageDestinationFinalize(dest) { return dst }
    }
    try? FileManager.default.removeItem(at: dst)
    throw CompressError.encodeFailed
}

/// Atomically claims `name-picpress[-n].ext` so parallel jobs never clobber each other or existing files.
private func reserveOutputURL(for src: URL, ext: String) throws -> URL {
    let dir = src.deletingLastPathComponent()
    let base = src.deletingPathExtension().lastPathComponent + "-picpress"
    var n = 1
    while true {
        let url = dir.appending(path: n == 1 ? base : "\(base)-\(n)").appendingPathExtension(ext)
        do {
            try Data().write(to: url, options: .withoutOverwriting)
            return url
        } catch CocoaError.fileWriteFileExists {
            n += 1
        }
    }
}
