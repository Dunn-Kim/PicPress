import Foundation
import UniformTypeIdentifiers

enum Container {
    case clean
    /// Bytes beyond the image that a re-encode would silently drop: motion-photo video (Samsung, Google),
    /// Samsung Gallery edit history, appended previews or HDR gain-map images.
    case extraData
    /// Cut off or corrupt. ImageIO still decodes such files (grey fill) and reports them complete.
    case truncated
}

/// Walks the file's container structure — JPEG markers or HEIF (ISO BMFF) top-level boxes — without decoding.
/// Other formats report `.clean`.
func inspectContainer(_ data: Data, type: UTType) -> Container {
    if type.conforms(to: .jpeg) { return data.withUnsafeBytes(jpegContainer) }
    if type.conforms(to: .heic) || type.conforms(to: .heif) { return isoContainer(data) }
    return .clean
}

private func jpegContainer(_ b: UnsafeRawBufferPointer) -> Container {
    let n = b.count
    guard n >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return .truncated }
    var i = 2
    while i + 1 < n {
        guard b[i] == 0xFF else { return .truncated } // lost sync
        let marker = b[i + 1]
        switch marker {
        case 0xFF: // fill byte
            i += 1
        case 0xD9: // end of image: anything after it but padding is extra data
            return b[(i + 2)...].allSatisfy { $0 == 0x00 || $0 == 0xFF } ? .clean : .extraData
        case 0x01, 0xD0...0xD7: // markers without a length
            i += 2
        default:
            guard i + 3 < n else { return .truncated }
            i += 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3]))
            if marker == 0xDA { // scan data runs to the next real marker (FF 00 is a stuffed byte, FF Dn a restart)
                while i + 1 < n, !(b[i] == 0xFF && b[i + 1] != 0x00 && !(0xD0...0xD7).contains(b[i + 1])) { i += 1 }
            }
        }
    }
    return .truncated
}

/// HEIF stills keep everything in these; anything else at the top level (e.g. Samsung's `mpvd` video) is extra.
private let heifBoxes: Set<String> = ["ftyp", "meta", "mdat", "idat", "free", "skip"]

private func isoContainer(_ data: Data) -> Container {
    let n = data.count
    let int = { (range: Range<Int>) in data[range].reduce(0) { $0 << 8 | Int($1) } }
    var i = 0
    var sawImageData = false
    while i < n {
        guard i + 8 <= n else { return .truncated }
        var size = int(i..<(i + 4))
        let type = String(decoding: data[(i + 4)..<(i + 8)], as: UTF8.self)
        if size == 1 { // 64-bit size follows
            guard i + 16 <= n else { return .truncated }
            size = int((i + 8)..<(i + 16))
        } else if size == 0 { // box runs to end of file
            size = n - i
        }
        guard size >= 8, size <= n - i else { return .truncated } // `n - i`: a huge 64-bit size can't overflow
        if i == 0, type != "ftyp" { return .truncated }
        guard heifBoxes.contains(type) else { return .extraData }
        sawImageData = sawImageData || type == "mdat"
        i += size
    }
    // A cut exactly on a box boundary leaves a well-formed prefix: require the image data box.
    return sawImageData ? .clean : .truncated
}
