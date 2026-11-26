import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PicPress

@Test func replacesOnlyWhenSmallerAndIndistinguishable() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let trash = dir.appending(path: "trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let discard = { (url: URL) -> URL? in
        let dest = trash.appending(path: url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    // Smooth photo-like JPEG with orientation + EXIF/GPS + old date + private perms → HEIC; all of it kept.
    let photo = dir.appending(path: "photo.jpg")
    try writeImage(to: photo, type: .jpeg, Bitmap.gradient(600, 400), orientation: 6, gps: true)
    let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes([.modificationDate: oldDate, .posixPermissions: 0o600], ofItemAtPath: photo.path)
    let before = fileSize(photo)

    guard case let .replaced(out, b, a) = try optimize(photo, format: .heic, discard: discard) else {
        Issue.record("expected replacement"); return
    }
    #expect(out.lastPathComponent == "photo.heic")
    #expect(b == before && a < b && fileSize(out) == a)
    #expect(!FileManager.default.fileExists(atPath: photo.path))
    #expect(FileManager.default.fileExists(atPath: trash.appending(path: "photo.jpg").path))
    let props = properties(out)
    #expect(props[kCGImagePropertyPixelWidth] as? Int == 600 && props[kCGImagePropertyPixelHeight] as? Int == 400)
    #expect(props[kCGImagePropertyOrientation] as? Int == 6)
    #expect((props[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude] as? Double == 37.5)
    #expect((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String == "2020:09:13 21:26:40")
    let attrs = try FileManager.default.attributesOfItem(atPath: out.path)
    #expect(attrs[.modificationDate] as? Date == oldDate)
    #expect(attrs[.posixPermissions] as? Int == 0o600)

    // Second run leaves it alone.
    guard case .skipped("이미 처리됨") = try optimize(out, format: .heic, discard: discard) else {
        Issue.record("expected already-processed skip"); return
    }

    // HEIC input is re-encoded in place, keeping its name.
    let heic = dir.appending(path: "phone.heic")
    try writeImage(to: heic, type: .heic, Bitmap.photo(300, 300))
    let heicOutcome = try optimize(heic, format: .heic, discard: discard)
    guard case let .replaced(heicOut, _, _) = heicOutcome else {
        Issue.record("expected HEIC re-encode, got \(heicOutcome)"); return
    }
    #expect(heicOut == heic)

    // JPEG-only mode: photo-like PNG becomes .jpg.
    let png = dir.appending(path: "flat.png")
    try writeImage(to: png, type: .png, Bitmap.photo(300, 300))
    let pngOutcome = try optimize(png, format: .jpeg, discard: discard)
    guard case let .replaced(jpg, _, _) = pngOutcome else {
        Issue.record("expected PNG → JPEG, got \(pngOutcome)"); return
    }
    #expect(jpg.lastPathComponent == "flat.jpg")
}

@Test func keepsOriginalWhenQualityOrDataWouldBeLost() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mustNotDiscard = { (url: URL) -> URL? in Issue.record("discarded \(url.lastPathComponent)"); return nil }
    let delete = { (url: URL) -> URL? in try FileManager.default.removeItem(at: url); return nil }

    // Control: an opaque photo-like PNG *is* replaced, so the skips below are for the stated reason.
    let control = dir.appending(path: "control.png")
    try writeImage(to: control, type: .png, Bitmap.photo(200, 200))
    guard case .replaced = try optimize(control, format: .heic, discard: delete) else {
        Issue.record("control PNG should be replaced"); return
    }

    // Random noise cannot be re-encoded without visible loss.
    let noise = dir.appending(path: "noise.png")
    var noisy = Bitmap.photo(200, 200)
    for i in noisy.px.indices where i % 4 != 3 { noisy.px[i] = .random(in: 0...255) }
    try writeImage(to: noise, type: .png, noisy)
    let noiseBytes = try Data(contentsOf: noise)
    try expectSkip(noise, "화질을 유지하며 충분히 줄일 수 없음", mustNotDiscard)
    #expect(try Data(contentsOf: noise) == noiseBytes)

    // JPEG cannot hold transparency (it would turn white), so a transparent PNG stays put.
    let clear = dir.appending(path: "clear.png")
    var transparent = Bitmap.photo(200, 200)
    for i in 0..<(transparent.px.count / 2) { transparent.px[i] = 0 } // top half fully transparent
    try writeImage(to: clear, type: .png, transparent, hasAlpha: true)
    try expectSkip(clear, "화질을 유지하며 충분히 줄일 수 없음", format: .jpeg, mustNotDiscard)
    // …while HEIC keeps the alpha channel, so it may replace it.
    guard case let .replaced(clearHEIC, _, _) = try optimize(clear, format: .heic, discard: delete) else {
        Issue.record("transparent PNG → HEIC should be replaced"); return
    }
    #expect(properties(clearHEIC)[kCGImagePropertyHasAlpha] as? Bool == true)

    // Name clash with an existing file.
    let clash = dir.appending(path: "clash.png")
    try writeImage(to: clash, type: .png, Bitmap.photo(200, 200))
    try Data("keep me".utf8).write(to: dir.appending(path: "clash.heic"))
    try expectSkip(clash, "clash.heic 파일이 이미 있음", mustNotDiscard)
    #expect(try Data(contentsOf: dir.appending(path: "clash.heic")) == Data("keep me".utf8))

    // If the original cannot be discarded (e.g. no Trash on that volume), nothing changes.
    struct NoTrash: Error {}
    let stuck = dir.appending(path: "stuck.png")
    try writeImage(to: stuck, type: .png, Bitmap.photo(200, 200))
    let stuckBytes = try Data(contentsOf: stuck)
    #expect(throws: NoTrash.self) { try optimize(stuck, format: .heic, discard: { _ in throw NoTrash() }) }
    #expect(try Data(contentsOf: stuck) == stuckBytes)
    #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "stuck.heic").path))
    let stuckHEIC = dir.appending(path: "stuck2.heic")
    try writeImage(to: stuckHEIC, type: .heic, Bitmap.photo(300, 300))
    let stuckHEICBytes = try Data(contentsOf: stuckHEIC)
    #expect(throws: NoTrash.self) { try optimize(stuckHEIC, format: .heic, discard: { _ in throw NoTrash() }) }
    #expect(try Data(contentsOf: stuckHEIC) == stuckHEICBytes)

    // Symlinks are not followed (trashing the link would leave the real file behind).
    let link = dir.appending(path: "link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: noise)
    try expectSkip(link, "심볼릭 링크", mustNotDiscard)

    // Formats where replacing could lose data (animation, layers, RAW) are not touched.
    let gif = dir.appending(path: "anim.gif")
    try writeImage(to: gif, type: .gif, Bitmap.photo(50, 50))
    try expectSkip(gif, "지원하지 않는 형식", mustNotDiscard)

    // Non-image throws.
    let bad = dir.appending(path: "bad.jpg")
    try Data("not an image".utf8).write(to: bad)
    #expect(throws: CompressError.unreadable) { try optimize(bad, format: .heic, discard: mustNotDiscard) }
}

@Test func findsImagesRecursivelySkippingHiddenAndPackages() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["a.jpg", "sub/deeper/b.PNG", "sub/notes.txt", ".hidden.jpg", "Some.app/c.jpg"] {
        let url = dir.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
    #expect(imageFiles(in: [dir]).map(\.lastPathComponent).sorted() == ["a.jpg", "b.PNG"])
    #expect(imageFiles(in: [dir.appending(path: "a.jpg"), dir.appending(path: "Some.app")]).count == 1)
    #expect(imageFiles(in: [dir, dir.appending(path: "a.jpg"), dir]).count == 2) // no duplicates
}

// MARK: - helpers

private struct Bitmap {
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
    static func photo(_ width: Int, _ height: Int) -> Bitmap {
        var bitmap = gradient(width, height)
        for i in bitmap.px.indices where i % 4 != 3 {
            bitmap.px[i] = UInt8(clamping: Int(bitmap.px[i]) + .random(in: -4...4))
        }
        return bitmap
    }
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func expectSkip(_ url: URL, _ reason: String, format: OutputFormat = .heic, _ discard: (URL) throws -> URL?,
                        sourceLocation: SourceLocation = #_sourceLocation) throws {
    let outcome = try optimize(url, format: format, discard: discard)
    guard case .skipped(reason) = outcome else {
        Issue.record("\(url.lastPathComponent): expected skip '\(reason)', got \(outcome)", sourceLocation: sourceLocation)
        return
    }
    #expect(FileManager.default.fileExists(atPath: url.path), sourceLocation: sourceLocation)
}

private func writeImage(to url: URL, type: UTType, _ bitmap: Bitmap, orientation: Int = 1,
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

private func properties(_ url: URL) -> [CFString: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
}
