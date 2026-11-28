import CoreGraphics
import Testing
@testable import MagicPics

@Test func catchesLocalDamageThatTheGlobalAverageWouldHide() throws {
    let base = Bitmap.photo(512, 512)
    let reference = try #require(Reference(try cgImage(base)))

    #expect(reference.isIndistinguishable(from: try cgImage(base)))

    // ±1 everywhere: far above both thresholds.
    var faint = base
    for i in faint.px.indices where i % 4 != 3 { faint.px[i] = UInt8(clamping: Int(faint.px[i]) + (i % 2 == 0 ? 1 : -1)) }
    #expect(reference.isIndistinguishable(from: try cgImage(faint)))

    // +40 red in a single 32×32 tile: ≈ 45 dB overall (would pass), ≈ 21 dB in that tile (must fail).
    var oneTile = base
    for y in 0..<32 {
        for x in 0..<32 { oneTile.px[(y * 512 + x) * 4] = UInt8(clamping: Int(oneTile.px[(y * 512 + x) * 4]) + 40) }
    }
    #expect(!reference.isIndistinguishable(from: try cgImage(oneTile)))

    // Transparency lost, or a different size, is never a match.
    var holed = base
    for i in 0..<(16 * 4) { holed.px[i] = 0 } // 16 fully transparent pixels
    let opaqueRef = try #require(Reference(try cgImage(base, hasAlpha: true)))
    #expect(!opaqueRef.isIndistinguishable(from: try cgImage(holed, hasAlpha: true)))
    #expect(!reference.isIndistinguishable(from: try cgImage(Bitmap.photo(512, 256))))
}

@Test func comparesWideGamutImagesInTheirOwnSpace() throws {
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let image = try cgImage(Bitmap.photo(256, 256), space: p3)
    let reference = try #require(Reference(image))
    #expect(reference.isIndistinguishable(from: image))
}
