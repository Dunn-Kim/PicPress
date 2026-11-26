import Foundation
import Testing
@testable import PicPress

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
