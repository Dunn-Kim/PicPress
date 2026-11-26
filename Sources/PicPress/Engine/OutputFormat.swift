import UniformTypeIdentifiers

/// Output policy chosen in the UI.
enum OutputFormat: String, CaseIterable {
    case heic, jpeg

    var label: String { self == .heic ? "HEIC 우선 (더 작음)" : "JPEG만 (호환성)" }

    /// Encodings tried in order; the first one that is small enough and passes the quality check wins.
    var candidates: [(type: UTType, ext: String, quality: Double)] {
        self == .heic ? [(.heic, "heic", 0.8), (.jpeg, "jpg", 0.9)] : [(.jpeg, "jpg", 0.9)]
    }
}

/// Input formats worth re-encoding. RAW, PSD, EXR, GIF, … are left alone: replacing them would lose data.
let reencodableTypes: [UTType] = [.jpeg, .png, .heic, .heif, .tiff, .bmp, .webP] // public.heic ⊄ public.heif
