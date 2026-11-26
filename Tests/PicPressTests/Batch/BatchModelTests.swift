import Foundation
import Testing
@testable import PicPress

@MainActor @Test func runsWholeBatchAndReportsEveryFile() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let trash = dir.appending(path: ".trash") // hidden, so the scan ignores it
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let model = BatchModel(discard: { url in
        let dest = trash.appending(path: url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    })

    try writeImage(to: dir.appending(path: "photo.png"), type: .png, Bitmap.photo(200, 200))
    var noise = Bitmap.photo(200, 200)
    for i in noise.px.indices where i % 4 != 3 { noise.px[i] = .random(in: 0...255) }
    try writeImage(to: dir.appending(path: "noise.png"), type: .png, noise)
    try Data("not an image".utf8).write(to: dir.appending(path: "notes.txt"))

    await model.scan(path: dir.path)
    #expect(model.confirming && model.pending.count == 2)
    model.confirming = false // what the dialog does on confirm

    await model.process(format: .heic)
    #expect(!model.running && model.pending.isEmpty)
    #expect(model.jobs.count == 2 && model.jobs.allSatisfy(\.status.isFinished))
    #expect(model.jobs.filter { $0.status.saved > 0 }.count == 1) // photo replaced, noise kept
    #expect(model.visibleJobs.count == 2)
    #expect(model.summary.hasPrefix("2/2 완료"))
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "photo.heic").path))
    #expect(FileManager.default.fileExists(atPath: trash.appending(path: "photo.png").path))

    await model.scan(path: dir.appending(path: "missing").path)
    #expect(model.notice?.hasPrefix("경로를 찾을 수 없습니다") == true)
}
