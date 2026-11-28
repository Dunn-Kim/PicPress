// Draws the Magic Pics app icon — a photo being squeezed by a square frame — and builds AppIcon.icns.
// Usage: swift Icon/make-icon.swift [preview.png]   (run from the repo root; needs macOS `iconutil`)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// All geometry is on Apple's 1024-pt icon grid (824-pt body, 100-pt margin), y pointing down.
let center: CGFloat = 512
let frameHalf: CGFloat = 210, frameStroke: CGFloat = 40, frameRadius: CGFloat = 44
let photoHalf: CGFloat = 268   // rounded photo corners squeeze out past the frame…
let photoSide: CGFloat = 206   // …while the middle of each side is pressed in under it
let earRadius: CGFloat = 30

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// macOS icon body: 824 pt rounded square on the 1024 grid.
func bodyPath() -> CGPath {
    CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
}

/// Photo outline with every side bowed inward — the squeeze — and its corners rounded into soft "ears":
/// a pinched core grown by `earRadius` (union with its own round-joined stroke).
let photoPath: CGPath = {
    let half = photoHalf - earRadius, side = photoSide - earRadius
    let lo = center - half, hi = center + half
    let control = 2 * (half - side) // quadratic: the curve's midpoint sits at half the control offset
    let core = CGMutablePath()
    core.move(to: CGPoint(x: lo, y: lo))
    core.addQuadCurve(to: CGPoint(x: hi, y: lo), control: CGPoint(x: center, y: lo + control))
    core.addQuadCurve(to: CGPoint(x: hi, y: hi), control: CGPoint(x: hi - control, y: center))
    core.addQuadCurve(to: CGPoint(x: lo, y: hi), control: CGPoint(x: center, y: hi - control))
    core.addQuadCurve(to: CGPoint(x: lo, y: lo), control: CGPoint(x: lo + control, y: center))
    core.closeSubpath()
    return core.union(core.copy(strokingWithWidth: 2 * earRadius, lineCap: .round, lineJoin: .round, miterLimit: 10))
}()

func drawPhotoContents(_ ctx: CGContext) {
    let lo = center - photoHalf, hi = center + photoHalf
    linearGradient(ctx, [rgb(0x4FA9E6), rgb(0xBFE4F6)], from: CGPoint(x: 0, y: lo), to: CGPoint(x: 0, y: 600))
    ctx.setFillColor(rgb(0xFFCC3D))
    ctx.fillEllipse(in: CGRect(x: 585, y: 345, width: 104, height: 104))
    let far = CGMutablePath() // distant ridge
    far.addLines(between: [CGPoint(x: lo, y: 600), CGPoint(x: 360, y: 470), CGPoint(x: 450, y: 545),
                           CGPoint(x: 560, y: 440), CGPoint(x: hi, y: 590), CGPoint(x: hi, y: hi), CGPoint(x: lo, y: hi)])
    ctx.addPath(far)
    ctx.setFillColor(rgb(0x6DB892))
    ctx.fillPath()
    let near = CGMutablePath() // foreground hill
    near.addLines(between: [CGPoint(x: lo, y: 690), CGPoint(x: 420, y: 560), CGPoint(x: 520, y: 640),
                            CGPoint(x: 640, y: 545), CGPoint(x: hi, y: 680), CGPoint(x: hi, y: hi), CGPoint(x: lo, y: hi)])
    ctx.addPath(near)
    ctx.setFillColor(rgb(0x2B7A57))
    ctx.fillPath()
}

/// Inward-pointing chevron above the frame's top side; rotated for the other three sides.
func drawChevrons(_ ctx: CGContext) {
    for quarter in 0..<4 {
        ctx.saveGState()
        ctx.translateBy(x: center, y: center)
        ctx.rotate(by: CGFloat(quarter) * .pi / 2)
        ctx.translateBy(x: -center, y: -center)
        ctx.move(to: CGPoint(x: center - 62, y: 158))
        ctx.addLine(to: CGPoint(x: center, y: 214))
        ctx.addLine(to: CGPoint(x: center + 62, y: 158))
        ctx.setLineWidth(30)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(rgb(0xFFA31A))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

func drawIcon(_ ctx: CGContext, scale: CGFloat) {
    // Body with a soft drop shadow (shadow offsets are in device space: y up, unscaled).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: rgb(0x000000, 0.35))
    ctx.addPath(bodyPath())
    ctx.setFillColor(rgb(0x24272D))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath())
    ctx.clip()
    linearGradient(ctx, [rgb(0x3A3F48), rgb(0x15171B)], from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 924))

    if scale * 1024 > 32 { drawChevrons(ctx) } // at 16–32 px they only blur the frame

    // Photo: shadow, contents clipped to the squeezed outline, white print border.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 20 * scale, color: rgb(0x000000, 0.45))
    ctx.addPath(photoPath)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(photoPath)
    ctx.clip()
    drawPhotoContents(ctx)
    ctx.restoreGState()
    ctx.addPath(photoPath)
    ctx.setLineWidth(26)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(rgb(0xF7F7F5))
    ctx.strokePath()

    // The pressing frame, over the photo.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 14 * scale, color: rgb(0x000000, 0.4))
    let frame = CGRect(x: center - frameHalf, y: center - frameHalf, width: 2 * frameHalf, height: 2 * frameHalf)
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: frameRadius, cornerHeight: frameRadius, transform: nil))
    ctx.setLineWidth(frameStroke)
    ctx.setStrokeColor(rgb(0xFFA31A))
    ctx.strokePath()
    ctx.restoreGState()
    ctx.restoreGState()
}

func render(_ pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale) // 1024 grid, y down
    drawIcon(ctx, scale: scale)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "could not write \(url.path)")
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appending(path: "MagicPics-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    writePNG(render(points), to: iconset.appending(path: "icon_\(points)x\(points).png"))
    writePNG(render(points * 2), to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
writePNG(render(256), to: URL(filePath: "Icon/AppIcon.png")) // for the README (GitHub can't show .icns)
if CommandLine.arguments.count > 1 { writePNG(render(1024), to: URL(filePath: CommandLine.arguments[1])) }

let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Icon/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
print("wrote Icon/AppIcon.icns and Icon/AppIcon.png")
