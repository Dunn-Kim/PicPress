import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PicPress

@Test func compressResizesRotatesAndNeverOverwrites() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Resize + smaller than source.
    let png = dir.appending(path: "photo.png")
    try writeNoise(to: png, type: .png, width: 600, height: 400)
    let a = try compress(png, quality: 0.6, maxPixel: 300, format: .jpeg)
    #expect(a.lastPathComponent == "photo-picpress.jpg")
    #expect(pixelSize(a).width == 300)
    #expect(try fileBytes(a) < fileBytes(png))

    // Never upscale; HEIC works.
    let b = try compress(png, quality: 0.6, maxPixel: 5000, format: .heic)
    #expect(b.lastPathComponent == "photo-picpress.heic")
    #expect(pixelSize(b).width == 600)

    // Existing output is kept, new one gets a suffix.
    let aBytes = try fileBytes(a)
    let c = try compress(png, quality: 0.6, maxPixel: 300, format: .jpeg)
    #expect(c.lastPathComponent == "photo-picpress-2.jpg")
    #expect(try fileBytes(a) == aBytes)

    // EXIF orientation 6 (rotated 90°) is baked into the pixels.
    let rotated = dir.appending(path: "rotated.jpg")
    try writeNoise(to: rotated, type: .jpeg, width: 600, height: 400, orientation: 6)
    let d = try compress(rotated, quality: 0.6, maxPixel: nil, format: .jpeg)
    #expect(pixelSize(d).width == 400 && pixelSize(d).height == 600)

    // Transparent PNG → JPEG is flattened onto white, not black.
    let clear = dir.appending(path: "clear.png")
    let clearCtx = try #require(CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let clearDest = try #require(CGImageDestinationCreateWithURL(clear as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(clearDest, try #require(clearCtx.makeImage()), nil)
    #expect(CGImageDestinationFinalize(clearDest))
    let e = try compress(clear, quality: 0.9, maxPixel: nil, format: .jpeg)
    #expect(try firstPixelBrightness(e) > 250)

    // Non-image fails cleanly and leaves no placeholder behind.
    let bad = dir.appending(path: "bad.png")
    try Data("not an image".utf8).write(to: bad)
    #expect(throws: CompressError.unreadable) { try compress(bad, quality: 0.6, maxPixel: nil, format: .jpeg) }
    #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "bad-picpress.jpg").path))
}

private func writeNoise(to url: URL, type: UTType, width: Int, height: Int, orientation: Int = 1) throws {
    let ctx = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    let count = ctx.bytesPerRow * height
    let pixels = try #require(ctx.data).bindMemory(to: UInt8.self, capacity: count)
    for i in 0..<count { pixels[i] = .random(in: 0...255) }
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

private func pixelSize(_ url: URL) -> (width: Int, height: Int) {
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    return (props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int)
}

private func firstPixelBrightness(_ url: URL) throws -> UInt8 {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = try #require(CGContext(
        data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return px[0]
}

private func fileBytes(_ url: URL) throws -> Int {
    try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
}
