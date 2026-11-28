import CoreGraphics
import Foundation

// Calibration knobs: PSNR (dB) of the re-encode vs. the original, 8-bit RGB, drawn in the original's
// own space (sRGB for the calibration set; Display P3 would read ≈ 1 dB higher for the same encode).
// Measured: good photo re-encodes land at 41–48 dB overall and ≥ 35 dB in the worst 32×32 tile;
// chroma damage on coloured text drops the worst tile below 20 dB. Raise them to be stricter.
let minPSNR = 40.0
let minTilePSNR = 35.0

/// The original's pixels, drawn once so every candidate re-encode is compared against the same thing.
struct Reference {
    private let pixels: [UInt8]
    private let width: Int, height: Int
    private let space: CGColorSpace

    /// Draws in the image's own RGB colour space when possible: skipping the colour conversion saves
    /// ≈ 160 ms per 36 MP photo. Falls back to Display P3 (grey, CMYK, indexed, …).
    init?(_ image: CGImage) {
        let own = image.colorSpace?.model == .rgb ? image.colorSpace : nil
        for space in [own, CGColorSpace(name: CGColorSpace.displayP3)].compactMap({ $0 }) {
            guard let drawn = draw(image, in: space) else { continue }
            pixels = drawn
            self.space = space
            width = image.width
            height = image.height
            return
        }
        return nil
    }

    /// Same size and transparency, PSNR ≥ `minPSNR` overall and ≥ `minTilePSNR` in every 32×32 tile
    /// (a global average alone would hide local damage that shows when zoomed in).
    func isIndistinguishable(from image: CGImage) -> Bool {
        guard image.width == width, image.height == height, let other = draw(image, in: space) else { return false }
        return pixels.withUnsafeBufferPointer { a in
            other.withUnsafeBufferPointer { b in withinThresholds(a, b) }
        }
    }

    private func withinThresholds(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Bool {
        let tile = 32
        var total = 0
        for ty in stride(from: 0, to: height, by: tile) {
            let rows = ty..<min(ty + tile, height)
            for tx in stride(from: 0, to: width, by: tile) {
                let cols = tx..<min(tx + tile, width)
                var squaredError = 0
                for y in rows {
                    for x in cols {
                        let i = (y * width + x) * 4
                        if abs(Int(a[i + 3]) - Int(b[i + 3])) > 2 { return false } // transparency lost
                        for c in 0..<3 {
                            let d = Int(a[i + c]) - Int(b[i + c])
                            squaredError += d * d
                        }
                    }
                }
                if psnr(squaredError, samples: rows.count * cols.count * 3) < minTilePSNR { return false }
                total += squaredError
            }
        }
        return psnr(total, samples: width * height * 3) >= minPSNR
    }
}

/// 8-bit premultiplied RGBA in `space`; nil if `space` cannot back such a context.
private func draw(_ image: CGImage, in space: CGColorSpace) -> [UInt8]? {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
        guard let ctx = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return drawn ? data : nil
}

private func psnr(_ squaredError: Int, samples: Int) -> Double {
    squaredError == 0 ? .infinity : 10 * log10(255 * 255 * Double(samples) / Double(squaredError))
}
