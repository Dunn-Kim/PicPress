import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Outcome {
    case replaced(URL, before: Int, after: Int)
    case skipped(String)
}

enum CompressError: LocalizedError {
    case unreadable

    var errorDescription: String? { "이미지를 읽을 수 없습니다" }
}

/// Re-encoding is lossy, so it must pay for itself. Also stops repeated runs from compounding loss
/// on volumes where the "already processed" mark cannot be stored (exFAT, some SMB shares).
let minSavings = 0.10

/// Input formats worth re-encoding. RAW, PSD, EXR, GIF, … are left alone: replacing them would lose data.
private let reencodableTypes: [UTType] = [.jpeg, .png, .heic, .heif, .tiff, .bmp, .webP] // public.heic ⊄ public.heif

/// Re-encodes `src` at full resolution and replaces it — original handed to `discard` (default: Trash) —
/// only when the result is at least `minSavings` smaller and visually indistinguishable.
/// Otherwise nothing on disk changes.
func optimize(_ src: URL, format: OutputFormat, discard: (URL) throws -> URL? = moveToTrash) throws -> Outcome {
    if (try? src.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return .skipped("심볼릭 링크") }
    if isMarkedProcessed(src) { return .skipped("이미 처리됨") }
    // Read once: the bytes checked below are exactly the bytes decoded and re-encoded.
    // ponytail: whole file in memory (≤ workers × file size); map it if huge TIFFs become common.
    let data = try Data(contentsOf: src)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let typeID = CGImageSourceGetType(source), let type = UTType(typeID as String)
    else { throw CompressError.unreadable }
    guard reencodableTypes.contains(where: type.conforms(to:)) else { return .skipped("지원하지 않는 형식") }
    guard CGImageSourceGetCount(source) == 1 else { return .skipped("여러 장이 든 파일") }
    switch inspectContainer(data, type: type) {
    case .clean: break
    case .extraData: return .skipped("이미지 외 데이터 포함 (모션 포토·편집 이력 등)")
    case .truncated: throw CompressError.unreadable
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) // lazy: pixels not decoded yet
    else { throw CompressError.unreadable }
    // An 8-bit comparison can't see lost precision: 16-bit masters are never touched, and a 9–10-bit
    // source (e.g. 10-bit HEIC) is only replaced by an encode that keeps its bit depth (checked below).
    let depth = bitDepth(source)
    guard depth <= 10 else { return .skipped("16비트 이미지") }
    guard !(image.colorSpace.map(CGColorSpaceUsesITUR_2100TF) ?? false) else { return .skipped("HDR 이미지") }

    let before = data.count
    // Decoded only once a candidate is small enough: already-compressed files never pay for it.
    lazy var reference = Reference(image)
    // Same volume as `src`, so the final rename is atomic.
    let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: src, create: true)
    defer { try? FileManager.default.removeItem(at: work) }

    for (outType, ext, quality) in format.candidates {
        let tmp = work.appending(path: UUID().uuidString)
        guard encode(source, as: outType, quality: quality, to: tmp) else { continue }
        let after = fileSize(tmp)
        guard Double(after) <= Double(before) * (1 - minSavings) else { continue }
        guard let reference else { throw CompressError.unreadable }
        guard let outSource = CGImageSourceCreateWithURL(tmp as CFURL, nil), bitDepth(outSource) >= depth,
              let out = CGImageSourceCreateImageAtIndex(outSource, 0, nil),
              reference.isIndistinguishable(from: out)
        else { continue }

        let target = type.conforms(to: outType) ? src : src.deletingPathExtension().appendingPathExtension(ext)
        guard try replace(src, with: tmp, at: target, discard: discard) else {
            return .skipped("\(target.lastPathComponent) 파일이 이미 있음")
        }
        return .replaced(target, before: before, after: after)
    }
    return .skipped("화질을 유지하며 충분히 줄일 수 없음")
}

private func bitDepth(_ source: CGImageSource) -> Int {
    (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyDepth] as? Int ?? 8
}

/// Full-resolution re-encode that carries over metadata (EXIF, GPS, orientation, ICC profile) and the HDR gain map.
private func encode(_ source: CGImageSource, as type: UTType, quality: Double, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImageFromSource(dest, source, 0, [
        kCGImageDestinationLossyCompressionQuality: quality,
        kCGImageDestinationPreserveGainMap: true,
    ] as CFDictionary)
    return CGImageDestinationFinalize(dest)
}
