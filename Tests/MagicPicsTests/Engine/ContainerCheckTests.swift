import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MagicPics

@Test func findsDataARecodeWouldDropAndCutOffFiles() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    func encoded(_ type: UTType, ext: String) throws -> Data {
        let url = dir.appending(path: "clean.\(ext)")
        try writeImage(to: url, type: type, Bitmap.photo(300, 200))
        return try Data(contentsOf: url)
    }

    // JPEG: Samsung-style motion photo (video + marker appended after the end-of-image marker).
    let jpeg = try encoded(.jpeg, ext: "jpg")
    #expect(inspectContainer(jpeg, type: .jpeg) == .clean)
    #expect(inspectContainer(jpeg + Data(count: 64), type: .jpeg) == .clean) // zero padding is fine
    #expect(inspectContainer(jpeg + Data(repeating: 0x42, count: 5000) + Data("MotionPhoto_Data".utf8), type: .jpeg) == .extraData)
    #expect(inspectContainer(jpeg.prefix(jpeg.count * 2 / 3), type: .jpeg) == .truncated)

    // HEIC: Samsung `mpvd` box after the image boxes; cut mid-box; cut exactly before `mdat`.
    let heic = try encoded(.heic, ext: "heic")
    let mpvd = Data([0, 0, 0x10, 0x08]) + Data("mpvd".utf8) + Data(count: 0x1000)
    #expect(inspectContainer(heic, type: .heic) == .clean)
    #expect(inspectContainer(heic + mpvd, type: .heic) == .extraData)
    #expect(inspectContainer(heic.prefix(heic.count * 2 / 3), type: .heic) == .truncated)
    let mdat = try #require(heic.range(of: Data("mdat".utf8))).lowerBound - 4
    #expect(inspectContainer(heic.prefix(mdat), type: .heic) == .truncated)

    // A 64-bit box size near Int.max must not overflow (it would trap and kill the batch).
    let huge = heic + Data([0, 0, 0, 1]) + Data("free".utf8) + Data([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0])
    #expect(inspectContainer(huge, type: .heic) == .truncated)

    // Real Apple-made HEIC and JPEG files pass, if present on this Mac.
    for path in ["/System/Library/Desktop Pictures/iMac Blue.heic", "/System/Library/Wallpapers/.default/DefaultAerial.jpg"] {
        guard let data = FileManager.default.contents(atPath: path) else { continue }
        #expect(inspectContainer(data, type: path.hasSuffix("heic") ? .heic : .jpeg) == .clean, "\(path)")
    }
}
