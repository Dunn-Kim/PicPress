import Foundation
import UniformTypeIdentifiers

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
