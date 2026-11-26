import Foundation
import UniformTypeIdentifiers

/// Turns a typed or pasted path into a URL: trims whitespace and quotes, unescapes Terminal-style `\ `,
/// expands `~`. Nil if nothing exists there.
func parsePath(_ text: String) -> URL? {
    let cleaned = text
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        .replacingOccurrences(of: "\\ ", with: " ")
    let url = URL(filePath: (cleaned as NSString).expandingTildeInPath)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

/// Expands folders recursively into image files, without duplicates. Skips hidden files and packages
/// (e.g. a Photos library, whose internals must never be rewritten).
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
