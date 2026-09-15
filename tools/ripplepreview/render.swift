// Contact sheet of the launch screen's colorways — a development tool, not
// part of the app.
//
// The splash is up for 2.4 seconds on a cold launch, which is not long enough
// to decide anything about a palette and far too long to keep rebuilding the
// app for. This runs the shipping shaders (see Preview.metal) on macOS at the
// phone's own size and writes every colorway in `Colorways.h` side by side.
//
// The water and the mark, and *not* the glass plaque the mark stands on: that
// is SwiftUI's own Liquid Glass, it samples a live backdrop, and there is no
// honest way to fake it here. Anything about how the plaque sits on the field
// has to be checked in the simulator.
//
//   cd tools/ripplepreview && ./preview.sh [time]
//
// `time` is seconds into the fill: the field starts empty and every drop slot
// has fired by 2.4, so ~2.1 is the fullest the screen ever gets and is what
// the sheet shows by default. Early frames are a different judgement — one
// ring on near-black — and worth a look at 0.8 before settling on anything.

import Metal
import Foundation
import simd
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let libraryPath = args.count > 1 ? args[1] : "Preview.metallib"
let time = args.count > 2 ? Double(args[2])! : 2.1
let outputDir = args.count > 3 ? args[3] : "."

/// Colorway names, in table order. Only labels for the sheets — the shader
/// knows these by index, so keep the lists in step by hand.
let names = ["aqua", "readout", "inferno", "oil-slick", "phosphor", "sodium",
             "ultraviolet", "coral", "arcade"]
/// `kMarkPalettes` in Wordmark.metal, same deal.
let markNames = ["signal", "plasma-zones", "plasma-lit", "chrome",
                 "gold", "ice", "film", "field"]
/// What ships, so each sheet varies one axis against the other's real value:
/// `kMarkColorway` and `kColorway`. Shader constants aren't readable from
/// Swift, so these are copies and have to be kept in step.
let shippingMark = 7
let shippingColorway = 1

/// The phone, in points: iPhone 17. Both shaders work in points, so this is
/// the only size that makes the halftone grid land where it lands on device.
let screen = CGSize(width: 402, height: 874)
/// What `LoadingSplashView` asks for: `AdditWordmark(size: 46, lift: 0.30)`.
let markCap: CGFloat = 46
let markLift: Float = 0.30
/// `kViewUnits` from Wordmark.metal. Duplicated, and it has to match.
let markUnits = CGSize(width: 6.40, height: 2.40)
/// `PixelRippleField.pixelSize`.
let pixelTarget: CGFloat = 12

/// `PixelRippleField.fittedCell` — the cell nearest `target` that divides the
/// width evenly. Reimplemented rather than approximated: the dots' alignment
/// with the screen edge is the first thing that looks wrong if it drifts.
func fittedCell(target: CGFloat, width: CGFloat) -> CGFloat {
    let columns = max(1, (width / target).rounded())
    return width / columns
}

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
let queue = device.makeCommandQueue()!
let library = try! device.makeLibrary(URL: URL(fileURLWithPath: libraryPath))
let pipeline = try! device.makeComputePipelineState(
    function: library.makeFunction(name: "ripplePreviewKernel")!)

/// Mirrors `PreviewArgs` in Preview.metal — and the vectors are `simd_float2`
/// rather than `(Float, Float)` for a reason worth the line: MSL aligns
/// `float2` to 8 bytes and a Swift tuple of floats to 4, so tuples put every
/// field after the first vector at the wrong offset. It fails silently, which
/// is the bad part — the first run of this tool rendered all seven colorways
/// identically, because `way` was reading the bytes of `markLift`.
struct PreviewArgs {
    var size: simd_float2
    var cell: Float
    var time: Float
    var scale: Float
    var markCanvas: simd_float2
    var markLift: Float
    var way: Int32
    var markWay: Int32
    var origin: simd_float2
}

/// One colorway at one instant, as premultiplied RGBA rows.
///
/// `window` is the part of the screen to draw, in points; the shaders are
/// always told about the whole screen, so a cropped window is the same picture
/// with the edges left off rather than a smaller phone.
func render(way: Int, markWay: Int, scale: Int,
            window: CGRect? = nil) -> (pixels: [UInt8], width: Int, height: Int) {
    let frame = window ?? CGRect(origin: .zero, size: screen)
    let width = Int(frame.width) * scale
    let height = Int(frame.height) * scale

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderWrite, .shaderRead]
    let texture = device.makeTexture(descriptor: descriptor)!

    var uniforms = PreviewArgs(
        size: simd_float2(Float(screen.width), Float(screen.height)),
        cell: Float(fittedCell(target: pixelTarget, width: screen.width)),
        time: Float(time),
        scale: Float(scale),
        markCanvas: simd_float2(Float(markCap * markUnits.width),
                                Float(markCap * markUnits.height)),
        markLift: markLift,
        way: Int32(way),
        markWay: Int32(markWay),
        origin: simd_float2(Float(frame.minX), Float(frame.minY)))

    let buffer = queue.makeCommandBuffer()!
    let encoder = buffer.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(texture, index: 0)
    encoder.setBytes(&uniforms, length: MemoryLayout<PreviewArgs>.stride, index: 0)
    encoder.dispatchThreadgroups(
        MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    encoder.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { raw in
        texture.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    return (pixels, width, height)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()

func image(_ rendered: (pixels: [UInt8], width: Int, height: Int)) -> CGImage {
    let provider = CGDataProvider(data: Data(rendered.pixels) as CFData)!
    return CGImage(width: rendered.width, height: rendered.height,
                   bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: rendered.width * 4, space: colorSpace,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

func write(_ cgImage: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cgImage, nil)
    CGImageDestinationFinalize(destination)
}

// Each colorway on its own, at 2× — the size you actually judge a palette at.
// Every soft edge in both shaders is measured in points, so this is the device
// drawing enlarged rather than a different drawing.
for (way, name) in names.enumerated() {
    write(image(render(way: way, markWay: shippingMark, scale: 2)),
          to: "\(outputDir)/colorway-\(way)-\(name).png")
}

// The mark's own palettes, each on the shipping water, full screen.
for (markWay, name) in markNames.enumerated() {
    write(image(render(way: shippingColorway, markWay: markWay, scale: 2)),
          to: "\(outputDir)/mark-\(markWay)-\(name).png")
}

// The sheet: all of them at 1:1, which is small but is the only way to see
// them together — and seeing them together is the whole question. Labelled,
// because by the fourth one you have lost track of which is which.
let scale = 1
let cellW = Int(screen.width) * scale
let cellH = Int(screen.height) * scale
let pad = 12
let labelH = 34
let sheetW = names.count * (cellW + pad) + pad
let sheetH = cellH + labelH + pad * 2

let context = CGContext(data: nil, width: sheetW, height: sheetH,
                        bitsPerComponent: 8, bytesPerRow: sheetW * 4,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

let font = CTFontCreateWithName("Menlo-Bold" as CFString, 20, nil)

/// Draws `text` with its baseline at `point`.
func label(_ text: String, at point: CGPoint, in ctx: CGContext) {
    // CoreText's own attribute keys, not AppKit's — this script links neither
    // AppKit nor UIKit, and `.font` is an AppKit extension.
    let attributed = NSAttributedString(string: text, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key:
            CGColor(red: 0.85, green: 0.85, blue: 0.87, alpha: 1),
    ])
    ctx.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
}
for (way, name) in names.enumerated() {
    let x = pad + way * (cellW + pad)
    context.draw(image(render(way: way, markWay: shippingMark, scale: scale)),
                 in: CGRect(x: x, y: pad + labelH, width: cellW, height: cellH))

    label("\(way) · \(name)", at: CGPoint(x: CGFloat(x), y: CGFloat(pad + 8)),
          in: context)
}

write(context.makeImage()!, to: "\(outputDir)/colorways.png")
print("wrote colorways.png  \(sheetW)×\(sheetH)  at t=\(time)s")

// The mark sheet. Cropped to a band around the letters and drawn at 2×, which
// is the only way the *surface* of a 46pt cap height is legible on a sheet —
// and the surface is the whole question here. Two columns so the tiles stay
// wide enough to read the lettering rather than the palette alone.
//
// No plaque behind it, the same caveat as everywhere in this tool: the mark
// ships standing on Liquid Glass, so a colorway chosen here still has to be
// looked at on device before it's believed.
let markWindow = CGRect(x: 31, y: 362, width: 340, height: 150)
let markScale = 2
let tileW = Int(markWindow.width) * markScale
let tileH = Int(markWindow.height) * markScale
let cols = 2
let rows = (markNames.count + cols - 1) / cols
let markSheetW = cols * (tileW + pad) + pad
let markSheetH = rows * (tileH + labelH) + pad

let markContext = CGContext(data: nil, width: markSheetW, height: markSheetH,
                            bitsPerComponent: 8, bytesPerRow: markSheetW * 4,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
markContext.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1))
markContext.fill(CGRect(x: 0, y: 0, width: markSheetW, height: markSheetH))

for (markWay, name) in markNames.enumerated() {
    let col = markWay % cols
    // Top row first, so reading order matches the table's order.
    let row = rows - 1 - markWay / cols
    let x = pad + col * (tileW + pad)
    let y = pad + row * (tileH + labelH)
    markContext.draw(image(render(way: shippingColorway, markWay: markWay,
                                  scale: markScale, window: markWindow)),
                     in: CGRect(x: x, y: y + labelH, width: tileW, height: tileH))
    label("\(markWay) · \(name)", at: CGPoint(x: CGFloat(x), y: CGFloat(y + 8)),
          in: markContext)
}

write(markContext.makeImage()!, to: "\(outputDir)/marks.png")
print("wrote marks.png  \(markSheetW)×\(markSheetH)")
