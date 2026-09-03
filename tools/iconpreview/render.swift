// Offscreen contact sheet for the menu ornaments — a development tool, not
// part of the app.
//
// The shipping app renders these icons on the GPU at launch and caches them in
// memory (see `MenuIconRenderer.swift`). That is invisible while you are still
// deciding whether an object looks like a pencil, so this runs the *same*
// kernel on macOS and writes a PNG you can actually look at.
//
//   cd tools/iconpreview && ./preview.sh
//
// Renders every icon large, on both a dark and a light ground, plus a strip at
// true menu size — which is the only size that matters and the one that finds
// every model that turned out to be too fussy.

import Metal
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let libraryPath = args.count > 1 ? args[1] : "MenuIcons.metallib"
let outputPath = args.count > 2 ? args[2] : "icons.png"
// Icon count and the kernel name both differ between the two metallibs this
// script is pointed at (the menu ornaments and the three brand marks).
let iconCount = args.count > 3 ? Int(args[3])! : 10
let kernelName = args.count > 4 ? args[4] : "menuIconKernel"

guard let device = MTLCreateSystemDefaultDevice() else {
    fatalError("no Metal device")
}
let queue = device.makeCommandQueue()!
let library = try! device.makeLibrary(URL: URL(fileURLWithPath: libraryPath))
let function = library.makeFunction(name: kernelName)!
let pipeline = try! device.makeComputePipelineState(function: function)

/// Run the kernel for one icon at one size, returning premultiplied BGRA rows.
func render(icon: Int, side: Int) -> [UInt8] {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: false)
    descriptor.usage = [.shaderWrite, .shaderRead]
    let texture = device.makeTexture(descriptor: descriptor)!

    let buffer = queue.makeCommandBuffer()!
    let encoder = buffer.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(texture, index: 0)
    var which = Int32(icon)
    encoder.setBytes(&which, length: MemoryLayout<Int32>.size, index: 0)
    let group = MTLSize(width: 8, height: 8, depth: 1)
    encoder.dispatchThreadgroups(
        MTLSize(width: (side + 7) / 8, height: (side + 7) / 8, depth: 1),
        threadsPerThreadgroup: group)
    encoder.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()

    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    pixels.withUnsafeMutableBytes { raw in
        texture.getBytes(raw.baseAddress!, bytesPerRow: side * 4,
                         from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
    }
    return pixels
}

// Sheet layout: one big cell per icon on dark, the same again on light, then a
// row at the true delivered size — which is the row that decides whether a
// model works, since it is the only one a user ever sees.
let big = 128
// Exactly what ships: `MenuIconRenderer` renders 40pt at a 3× display scale.
// Drawn 1:1 below — at this size the real pixel grid needs no help to be read.
let small = 120
let pad = 16
let cols = iconCount
let sheetW = cols * (big + pad) + pad
let sheetH = pad + big + pad + big + pad + small + pad

let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: sheetW, height: sheetH,
                        bitsPerComponent: 8, bytesPerRow: sheetW * 4,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Row backgrounds: the app's charcoal, then a light sheet, so a model that
// only works against one ground gives itself away here.
context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1))
context.fill(CGRect(x: 0, y: CGFloat(pad + small + pad), width: CGFloat(sheetW), height: CGFloat(big + pad)))

func draw(icon: Int, side: Int, at point: CGPoint, scale: Int = 1) {
    let pixels = render(icon: icon, side: side)
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: side, height: side, bitsPerComponent: 8,
                        bitsPerPixel: 32, bytesPerRow: side * 4,
                        space: colorSpace,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false,
                        intent: .defaultIntent)!
    let drawn = CGFloat(side * scale)
    // No flip. The kernel already writes the model's +y into row 0, and both
    // `CGImage` and `CGContext.draw` treat row 0 as the top — the same path the
    // app takes to build a `UIImage`, so what this sheet shows is what ships.
    context.draw(image, in: CGRect(x: point.x, y: point.y, width: drawn, height: drawn))
}

for icon in 0..<iconCount {
    let x = CGFloat(pad + icon * (big + pad))
    draw(icon: icon, side: big, at: CGPoint(x: x, y: CGFloat(pad + small + pad + big + pad)))
    draw(icon: icon, side: big, at: CGPoint(x: x, y: CGFloat(pad + small + pad)))
    // True size, 1:1 — this row is the real pixel grid, unresampled.
    draw(icon: icon, side: small, at: CGPoint(x: x, y: CGFloat(pad)))
}

let image = context.makeImage()!
let url = URL(fileURLWithPath: outputPath)
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("wrote \(outputPath)  \(sheetW)×\(sheetH)")
