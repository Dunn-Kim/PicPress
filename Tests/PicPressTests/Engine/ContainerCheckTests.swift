import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PicPress

@Test func findsDataARecodeWouldDropAndCutOffFiles() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    func variants(_ type: UTType, ext: String, trailer: Data) throws -> (clean: URL, padded: URL, extra: URL, cut: URL) {
        let clean = dir.appending(path: "clean.\(ext)")
        try writeImage(to: clean, type: type, Bitmap.photo(300, 200))
        let bytes = try Data(contentsOf: clean)
        let urls = (clean, dir.appending(path: "padded.\(ext)"), dir.appending(path: "extra.\(ext)"), dir.appending(path: "cut.\(ext)"))
        try (bytes + Data(count: 64)).write(to: urls.1)
        try (bytes + trailer).write(to: urls.2)
        try bytes.prefix(bytes.count * 2 / 3).write(to: urls.3)
        return urls
    }

    // JPEG: Samsung-style motion photo (video + marker appended after the end-of-image marker).
    let jpeg = try variants(.jpeg, ext: "jpg", trailer: Data(repeating: 0x42, count: 5000) + Data("MotionPhoto_Data".utf8))
    #expect(try inspectContainer(jpeg.clean, type: .jpeg) == .clean)
    #expect(try inspectContainer(jpeg.padded, type: .jpeg) == .clean)
    #expect(try inspectContainer(jpeg.extra, type: .jpeg) == .extraData)
    #expect(try inspectContainer(jpeg.cut, type: .jpeg) == .truncated)

    // HEIC: Samsung `mpvd` box after the image boxes.
    var mpvd = Data([0, 0, 0x10, 0x08]) + Data("mpvd".utf8)
    mpvd += Data(count: 0x1000)
    let heic = try variants(.heic, ext: "heic", trailer: mpvd)
    #expect(try inspectContainer(heic.clean, type: .heic) == .clean)
    #expect(try inspectContainer(heic.extra, type: .heic) == .extraData)
    #expect(try inspectContainer(heic.cut, type: .heic) == .truncated)

    // Real Apple-made HEIC and JPEG files pass, if present on this Mac.
    for path in ["/System/Library/Desktop Pictures/iMac Blue.heic", "/System/Library/Wallpapers/.default/DefaultAerial.jpg"] {
        let url = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: path) else { continue }
        #expect(try inspectContainer(url, type: path.hasSuffix("heic") ? .heic : .jpeg) == .clean, "\(path)")
    }
}
