import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

// Synthetic test images and temp folders shared by all test suites.

struct Bitmap {
    let width: Int, height: Int
    var px: [UInt8]

    /// Smooth opaque RGBA gradient.
    static func gradient(_ width: Int, _ height: Int) -> Bitmap {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                px[i] = UInt8(x * 255 / width)
                px[i + 1] = UInt8(y * 255 / height)
                px[i + 2] = 128
            }
        }
        return Bitmap(width: width, height: height, px: px)
    }

    /// Gradient plus mild grain, so it compresses like a photo rather than like flat artwork.
    /// ±2 re-encodes to HEIC at ≈ 43 dB (sRGB), clear of the 40 dB bar; ±4 sits right on it (≈ 39–40 dB).
    static func photo(_ width: Int, _ height: Int) -> Bitmap {
        var bitmap = gradient(width, height)
        for i in bitmap.px.indices where i % 4 != 3 {
            bitmap.px[i] = UInt8(clamping: Int(bitmap.px[i]) + .random(in: -2...2))
        }
        return bitmap
    }
}

func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func writeImage(to url: URL, type: UTType, _ bitmap: Bitmap, orientation: Int = 1,
                        gps: Bool = false, hasAlpha: Bool = false) throws {
    var px = bitmap.px
    let image = try px.withUnsafeMutableBytes { buffer in
        let ctx = try #require(CGContext(
            data: buffer.baseAddress, width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
            bytesPerRow: bitmap.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: (hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        ))
        return try #require(ctx.makeImage())
    }
    var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1.0]
    if gps {
        props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.5, kCGImagePropertyGPSLatitudeRef: "N"]
        props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2020:09:13 21:26:40"]
    }
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

func properties(_ url: URL) -> [CFString: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
}
