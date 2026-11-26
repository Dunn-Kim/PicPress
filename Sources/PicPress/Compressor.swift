import Foundation
import ImageIO
import UniformTypeIdentifiers

enum OutputFormat: String, CaseIterable, Identifiable {
    case heic, jpeg

    var id: Self { self }
    var label: String { self == .heic ? "HEIC 우선 (더 작음)" : "JPEG만 (호환성)" }
    /// Encodings tried in order; the first one that is smaller and passes the quality check wins.
    var candidates: [(type: UTType, quality: Double)] {
        self == .heic ? [(.heic, 0.8), (.jpeg, 0.9)] : [(.jpeg, 0.9)]
    }
}

enum Outcome {
    case replaced(URL, before: Int, after: Int)
    case skipped(String)
}

enum CompressError: LocalizedError {
    case unreadable, replaceFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "이미지를 읽을 수 없습니다"
        case .replaceFailed: "교체 실패 — 원본은 제자리 또는 휴지통에 있습니다"
        }
    }
}

// Calibration knobs: PSNR (dB) of the re-encode vs. the original, 8-bit RGB.
// Measured: good photo re-encodes land at 41–48 dB overall and ≥ 35 dB in the worst 32×32 tile;
// chroma damage on coloured text drops the worst tile below 20 dB. Raise them to be stricter.
let minPSNR = 40.0
let minTilePSNR = 35.0
/// Re-encoding is lossy, so it must pay for itself. Also stops repeated runs from compounding loss
/// on volumes where the "already processed" xattr cannot be stored (exFAT, some SMB shares).
let minSavings = 0.10

/// Formats worth re-encoding. RAW, PSD, EXR, GIF, … are left alone: replacing them would lose data.
private let inputTypes: [UTType] = [.jpeg, .png, .heic, .heif, .tiff, .bmp, .webP] // public.heic ⊄ public.heif
private let marker = "app.picpress.optimized"

/// Moves `url` to the Trash and returns where it went (so a failed replacement can be rolled back).
func moveToTrash(_ url: URL) throws -> URL? {
    var trashed: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
    return trashed as URL?
}

/// Re-encodes `src` at full resolution, keeping all metadata (EXIF, GPS, orientation, colour profile, HDR gain map),
/// file dates and permissions. The original is replaced — and handed to `discard` — only when the result is
/// at least `minSavings` smaller and visually indistinguishable; otherwise nothing on disk changes.
func optimize(_ src: URL, format: OutputFormat, discard: (URL) throws -> URL? = moveToTrash) throws -> Outcome {
    if (try? src.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return .skipped("심볼릭 링크") }
    if getxattr(src.path, marker, nil, 0, 0, 0) >= 0 { return .skipped("이미 처리됨") }
    guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
          let typeID = CGImageSourceGetType(source), let type = UTType(typeID as String)
    else { throw CompressError.unreadable }
    guard inputTypes.contains(where: type.conforms(to:)) else { return .skipped("지원하지 않는 형식") }
    guard CGImageSourceGetCount(source) == 1 else { return .skipped("여러 장이 든 파일") }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let reference = pixels(image)
    else { throw CompressError.unreadable }

    let before = fileSize(src)
    let attributes = try FileManager.default.attributesOfItem(atPath: src.path)
        .filter { [.creationDate, .modificationDate, .posixPermissions].contains($0.key) }
    // Same volume as `src`, so the final rename is atomic.
    let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: src, create: true)
    defer { try? FileManager.default.removeItem(at: work) }

    for (outType, quality) in format.candidates {
        let tmp = work.appending(path: UUID().uuidString)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, outType.identifier as CFString, 1, nil) else { continue }
        CGImageDestinationAddImageFromSource(dest, source, 0, [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationPreserveGainMap: true,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest), Double(fileSize(tmp)) <= Double(before) * (1 - minSavings),
              let outSource = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              let out = CGImageSourceCreateImageAtIndex(outSource, 0, nil),
              out.width == image.width, out.height == image.height,
              let outPixels = pixels(out),
              indistinguishable(reference, outPixels, width: image.width, height: image.height)
        else { continue }

        let after = fileSize(tmp)
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: tmp.path)
        _ = setxattr(tmp.path, marker, "1", 1, 0, 0)

        if type.conforms(to: outType) {
            // Same name: original out of the way first, then put the new file in; undo if that fails.
            let trashed = try discard(src)
            guard renamex_np(tmp.path, src.path, UInt32(RENAME_EXCL)) == 0 else {
                if let trashed { try? FileManager.default.moveItem(at: trashed, to: src) }
                throw CompressError.replaceFailed
            }
            return .replaced(src, before: before, after: after)
        }
        // New extension: claim the name atomically (parallel jobs may race for it), then discard the original.
        let target = src.deletingPathExtension().appendingPathExtension(outType == .heic ? "heic" : "jpg")
        guard renamex_np(tmp.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { return .skipped("\(target.lastPathComponent) 파일이 이미 있음") }
            throw CompressError.replaceFailed
        }
        do { _ = try discard(src) } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return .replaced(target, before: before, after: after)
    }
    return .skipped("화질을 유지하며 충분히 줄일 수 없음")
}

/// Expands folders recursively into image files, without duplicates. Skips hidden files and packages
/// (e.g. a Photos library).
func imageFiles(in urls: [URL]) -> [URL] {
    let isImage = { (url: URL) in UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }
    var seen = Set<String>()
    return urls.flatMap { url -> [URL] in
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isPackage == true { return [] }
        guard values?.isDirectory == true else { return isImage(url) ? [url] : [] }
        let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        return (walker?.allObjects as? [URL] ?? []).filter {
            isImage($0) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
    .filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
}

func fileSize(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

/// 8-bit RGBA in one shared colour space, so original and re-encode compare like for like.
private func pixels(_ image: CGImage) -> [UInt8]? {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
        guard let ctx = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return drawn ? data : nil
}

/// Same transparency, and PSNR above `minPSNR` overall and `minTilePSNR` in every 32×32 tile
/// (a global average alone would hide local damage that shows when zoomed in).
private func indistinguishable(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> Bool {
    let tile = 32
    var total = 0.0
    for ty in stride(from: 0, to: height, by: tile) {
        for tx in stride(from: 0, to: width, by: tile) {
            var se = 0.0, n = 0.0
            for y in ty..<min(ty + tile, height) {
                for x in tx..<min(tx + tile, width) {
                    let i = (y * width + x) * 4
                    if abs(Int(a[i + 3]) - Int(b[i + 3])) > 2 { return false } // transparency lost
                    for c in 0..<3 {
                        let d = Double(a[i + c]) - Double(b[i + c])
                        se += d * d
                    }
                    n += 3
                }
            }
            if psnr(se / n) < minTilePSNR { return false }
            total += se
        }
    }
    return psnr(total / Double(width * height * 3)) >= minPSNR
}

private func psnr(_ mse: Double) -> Double {
    mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
}
