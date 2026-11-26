import CoreGraphics
import Foundation

// Calibration knobs: PSNR (dB) of the re-encode vs. the original, 8-bit RGB.
// Measured: good photo re-encodes land at 41–48 dB overall and ≥ 35 dB in the worst 32×32 tile;
// chroma damage on coloured text drops the worst tile below 20 dB. Raise them to be stricter.
let minPSNR = 40.0
let minTilePSNR = 35.0

/// The original's pixels, drawn once so every candidate re-encode is compared against the same thing.
struct Reference {
    private let pixels: [UInt8]
    private let width: Int, height: Int
    private let space = CGColorSpace(name: CGColorSpace.displayP3)!

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        guard let drawn = draw(image, in: space) else { return nil }
        pixels = drawn
    }

    /// Same size and transparency, PSNR ≥ `minPSNR` overall and ≥ `minTilePSNR` in every 32×32 tile
    /// (a global average alone would hide local damage that shows when zoomed in).
    func isIndistinguishable(from image: CGImage) -> Bool {
        guard image.width == width, image.height == height, let other = draw(image, in: space) else { return false }
        let tile = 32
        var total = 0.0
        for ty in stride(from: 0, to: height, by: tile) {
            for tx in stride(from: 0, to: width, by: tile) {
                var se = 0.0, n = 0.0
                for y in ty..<min(ty + tile, height) {
                    for x in tx..<min(tx + tile, width) {
                        let i = (y * width + x) * 4
                        if abs(Int(pixels[i + 3]) - Int(other[i + 3])) > 2 { return false } // transparency lost
                        for c in 0..<3 {
                            let d = Double(pixels[i + c]) - Double(other[i + c])
                            se += d * d
                        }
                        n += 3
                    }
                }
                if psnr(se / n) < minTilePSNR { return false }
                total += se
            }
        }
        return psnr(total / Double(width * height * 3)) >= minPSNR
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

private func psnr(_ mse: Double) -> Double {
    mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
}
