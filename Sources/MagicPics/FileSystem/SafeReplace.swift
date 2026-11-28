import Foundation

enum ReplaceError: LocalizedError {
    case failed

    var errorDescription: String? { "교체 실패 — 원본은 제자리 또는 휴지통에 있습니다" }
}

private let processedMark = "app.picpress.optimized"

/// True if the app already wrote this file (extended attribute), so reruns skip it.
/// The name predates the rename to Magic Pics; keep it, or files processed before would be re-encoded.
func isMarkedProcessed(_ url: URL) -> Bool {
    getxattr(url.path, processedMark, nil, 0, 0, 0) >= 0
}

func fileSize(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

/// Moves `url` to the Trash and returns where it went (so a failed replacement can be rolled back).
func moveToTrash(_ url: URL) throws -> URL? {
    var trashed: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
    return trashed as URL?
}

/// Puts `newFile` (same volume) at `target` — `original`'s own path, or a new name beside it — and hands
/// `original` to `discard`. The new file inherits the original's dates and permissions and is marked processed.
/// Returns false, touching nothing, if `target` is a different file that already exists. On failure the
/// original is restored (or left where `discard` put it) and no new file is left behind.
func replace(_ original: URL, with newFile: URL, at target: URL, discard: (URL) throws -> URL?) throws -> Bool {
    let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        .filter { [.creationDate, .modificationDate, .posixPermissions].contains($0.key) }
    try? FileManager.default.setAttributes(attributes, ofItemAtPath: newFile.path)
    _ = setxattr(newFile.path, processedMark, "1", 1, 0, 0)

    if target == original {
        // Original out of the way first, then the new file in; undo if that fails.
        let trashed = try discard(original)
        guard renamex_np(newFile.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            if let trashed { try? FileManager.default.moveItem(at: trashed, to: original) }
            throw ReplaceError.failed
        }
        return true
    }
    // New name: claim it atomically (parallel jobs may race for it), then discard the original.
    guard renamex_np(newFile.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
        if errno == EEXIST { return false }
        throw ReplaceError.failed
    }
    do {
        _ = try discard(original)
    } catch {
        try? FileManager.default.removeItem(at: target)
        throw error
    }
    return true
}
