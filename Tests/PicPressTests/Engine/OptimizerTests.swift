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

    // Greyscale originals are compared in the Display P3 fallback space (an 8-bit RGBA context can't be grey).
    let grey = dir.appending(path: "grey.png")
    let rgb = Bitmap.photo(300, 300)
    var greyPx = [UInt8](repeating: 0, count: 300 * 300)
    for i in greyPx.indices { greyPx[i] = rgb.px[i * 4] }
    let greyImage = try greyPx.withUnsafeMutableBytes { buffer in
        try #require(CGContext(data: buffer.baseAddress, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 300,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage())
    }
    let greyDest = try #require(CGImageDestinationCreateWithURL(grey as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(greyDest, greyImage, nil)
    #expect(CGImageDestinationFinalize(greyDest))
    let greyOutcome = try optimize(grey, format: .heic, discard: discard)
    guard case .replaced = greyOutcome else {
        Issue.record("expected greyscale PNG → HEIC, got \(greyOutcome)"); return
    }

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

    // 16-bit masters keep precision an 8-bit check can't see: never re-encoded.
    let deep = dir.appending(path: "deep.png")
    let deepCtx = try #require(CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 16, bytesPerRow: 64 * 8,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
    ))
    let deepDest = try #require(CGImageDestinationCreateWithURL(deep as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(deepDest, try #require(deepCtx.makeImage()), nil)
    #expect(CGImageDestinationFinalize(deepDest))
    try expectSkip(deep, "16비트 이미지", mustNotDiscard)

    // A motion photo's video (bytes after the JPEG) would be dropped by a re-encode: left alone.
    let motion = dir.appending(path: "motion.jpg")
    try writeImage(to: motion, type: .jpeg, Bitmap.photo(300, 300))
    try (Data(contentsOf: motion) + Data(repeating: 7, count: 4096)).write(to: motion)
    try expectSkip(motion, "이미지 외 데이터 포함 (모션 포토·편집 이력 등)", mustNotDiscard)

    // Non-image, or a truncated photo, throws without touching anything.
    let bad = dir.appending(path: "bad.jpg")
    try Data("not an image".utf8).write(to: bad)
    #expect(throws: CompressError.unreadable) { try optimize(bad, format: .heic, discard: mustNotDiscard) }
    let cut = dir.appending(path: "cut.jpg")
    try writeImage(to: cut, type: .jpeg, Bitmap.photo(400, 400))
    let full = try Data(contentsOf: cut)
    try full.prefix(full.count / 2).write(to: cut)
    #expect(throws: CompressError.unreadable) { try optimize(cut, format: .heic, discard: mustNotDiscard) }
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
