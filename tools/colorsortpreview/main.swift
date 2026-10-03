// Lays a library of synthetic covers out with the shipping `ColorSort`, next
// to the naive alternative, and writes the result as a contact sheet.
// Development only — nothing here ships. Run through preview.sh, which
// compiles this against ../../Addit/Utilities/ColorSort.swift.
//
// The covers are generated, not real, but they're built to be the hard cases
// a real library is full of: dark sleeves with a small coloured mark, pale
// sleeves with one, two-tone splits, earthy and muted photos, greyscale
// photos, as well as the easy flat colour fields. Seeded, so a sheet only
// changes when the sort does.
//
//   usage: render <out.png> [seed] [count]   (preview.sh builds and runs it)

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Randomness

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Covers

typealias RGB = (r: Double, g: Double, b: Double)

func hsb(_ h: Double, _ s: Double, _ v: Double) -> RGB {
    let h6 = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
    let c = v * s, x = c * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
    let (r, g, b): (Double, Double, Double) = switch Int(h6) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
    }
    return (r + m, g + m, b + m)
}

func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
    (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
}

/// A cover as a function of position (0…1, 0…1) plus per-pixel noise.
func makeCover(side: Int, noise: Double, rng: inout SplitMix, _ scene: (Double, Double) -> RGB) -> CGImage {
    var pixels = [UInt8](repeating: 255, count: side * side * 4)
    for y in 0..<side {
        for x in 0..<side {
            let c = scene((Double(x) + 0.5) / Double(side), (Double(y) + 0.5) / Double(side))
            let n = noise * Double.random(in: -1...1, using: &rng)
            let i = (y * side + x) * 4
            pixels[i] = UInt8(max(0, min(1, c.r + n)) * 255)
            pixels[i + 1] = UInt8(max(0, min(1, c.g + n)) * 255)
            pixels[i + 2] = UInt8(max(0, min(1, c.b + n)) * 255)
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )!
}

/// One random cover, drawn from the kinds real libraries are made of.
func randomCover(rng: inout SplitMix) -> CGImage {
    let side = 96
    let hue = Double.random(in: 0..<1, using: &rng)
    let kind = Double.random(in: 0..<1, using: &rng)
    // A centred disc or a block, for the "mark" on a sleeve.
    let cx = Double.random(in: 0.3...0.7, using: &rng), cy = Double.random(in: 0.3...0.7, using: &rng)
    let radius = Double.random(in: 0.12...0.35, using: &rng)
    let inMark: (Double, Double) -> Bool = { x, y in hypot(x - cx, y - cy) < radius }

    switch kind {
    case ..<0.20: // Flat colour field with a small light or dark block.
        let field = hsb(hue, .random(in: 0.55...1, using: &rng), .random(in: 0.5...1, using: &rng))
        let block: RGB = Bool.random(using: &rng) ? (0.95, 0.95, 0.93) : (0.05, 0.05, 0.06)
        let top = Double.random(in: 0.6...0.8, using: &rng)
        return makeCover(side: side, noise: 0.02, rng: &rng) { _, y in y > top ? block : field }
    case ..<0.40: // Dark sleeve, coloured mark of any size.
        let dark = hsb(hue, .random(in: 0...0.3, using: &rng), .random(in: 0.03...0.14, using: &rng))
        let mark = hsb(.random(in: 0..<1, using: &rng), .random(in: 0.6...1, using: &rng), .random(in: 0.6...1, using: &rng))
        return makeCover(side: side, noise: 0.03, rng: &rng) { x, y in inMark(x, y) ? mark : dark }
    case ..<0.55: // Photo: a gradient between two neighbouring hues.
        let spread = Double.random(in: -0.1...0.1, using: &rng)
        let s = Double.random(in: 0.3...0.8, using: &rng)
        let a = hsb(hue, s, .random(in: 0.2...0.6, using: &rng))
        let b = hsb(hue + spread, s * 0.8, .random(in: 0.5...0.95, using: &rng))
        return makeCover(side: side, noise: 0.06, rng: &rng) { _, y in mix(a, b, y) }
    case ..<0.65: // Two-tone split, unrelated hues.
        let a = hsb(hue, .random(in: 0.5...1, using: &rng), .random(in: 0.4...1, using: &rng))
        let b = hsb(.random(in: 0..<1, using: &rng), .random(in: 0.5...1, using: &rng), .random(in: 0.4...1, using: &rng))
        let split = Double.random(in: 0.3...0.7, using: &rng)
        return makeCover(side: side, noise: 0.02, rng: &rng) { x, _ in x < split ? a : b }
    case ..<0.75: // Pale sleeve, coloured mark.
        let pale = hsb(.random(in: 0.08...0.15, using: &rng), .random(in: 0...0.1, using: &rng), .random(in: 0.88...1, using: &rng))
        let mark = hsb(hue, .random(in: 0.5...1, using: &rng), .random(in: 0.4...0.9, using: &rng))
        return makeCover(side: side, noise: 0.02, rng: &rng) { x, y in inMark(x, y) ? mark : pale }
    case ..<0.85: // Earthy and muted: browns, tans, olives.
        let earth = Double.random(in: 0.04...0.2, using: &rng)
        let a = hsb(earth, .random(in: 0.25...0.6, using: &rng), .random(in: 0.2...0.45, using: &rng))
        let b = hsb(earth + 0.03, .random(in: 0.2...0.5, using: &rng), .random(in: 0.45...0.75, using: &rng))
        return makeCover(side: side, noise: 0.07, rng: &rng) { x, y in mix(a, b, (x + y) / 2) }
    case ..<0.95: // Greyscale photo.
        let lo = Double.random(in: 0.05...0.5, using: &rng), hi = Double.random(in: 0.5...0.95, using: &rng)
        return makeCover(side: side, noise: 0.08, rng: &rng) { x, y in
            let v = lo + (hi - lo) * (0.5 + 0.5 * sin(x * 5 + y * 3))
            return (v, v, v)
        }
    default: // Pastel field.
        let field = hsb(hue, .random(in: 0.15...0.35, using: &rng), .random(in: 0.88...1, using: &rng))
        return makeCover(side: side, noise: 0.02, rng: &rng) { _, _ in field }
    }
}

// MARK: - Sheet

let tile = 64, gap = 6, padding = 28, heading = 34

/// Draws one grid of covers — `columns` wide, in the given order — at `origin`
/// (top-left, in a flipped-y sense handled by the caller's context).
func drawGrid(_ context: CGContext, covers: [CGImage], order: [Int], columns: Int, origin: CGPoint, sheetHeight: Int, title: String) {
    drawText(context, title, at: CGPoint(x: origin.x, y: CGFloat(sheetHeight) - origin.y - 22))
    for (slot, index) in order.enumerated() {
        let x = origin.x + CGFloat((slot % columns) * (tile + gap))
        let yTop = origin.y + CGFloat(heading) + CGFloat((slot / columns) * (tile + gap))
        let rect = CGRect(x: x, y: CGFloat(sheetHeight) - yTop - CGFloat(tile), width: CGFloat(tile), height: CGFloat(tile))
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.clip()
        context.draw(covers[index], in: rect)
        context.restoreGState()
    }
}

func drawText(_ context: CGContext, _ string: String, at point: CGPoint) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 15, nil)
    let white = CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1)
    let attributed = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = point
    CTLineDraw(line, context)
}

func gridSize(count: Int, columns: Int) -> CGSize {
    let rows = (count + columns - 1) / columns
    return CGSize(width: columns * (tile + gap) - gap, height: heading + rows * (tile + gap) - gap)
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: render <out.png> [seed] [count]")
    exit(1)
}
let seed = arguments.count > 2 ? UInt64(arguments[2]) ?? 7 : 7
let count = arguments.count > 3 ? Int(arguments[3]) ?? 60 : 60
var rng = SplitMix(state: seed)
let covers = (0..<count).map { _ in randomCover(rng: &rng) }
let tones = covers.map(CoverTone.measure)

// The naive version, for comparison: hue order poured into the grid in reading
// order, greys after — what "sort by colour" means without the grid in mind.
// Hue descending, the way `ColorSort` runs, so the two compare like for like.
let naive = tones.indices.sorted { a, b in
    switch (tones[a]?.hue, tones[b]?.hue) {
    case let (x?, y?): return (y, a) < (x, b)
    case (.some, nil): return true
    case (nil, .some): return false
    case (nil, nil): return ((tones[b]?.lightness ?? 0), a) < ((tones[a]?.lightness ?? 0), b)
    }
}

let panels: [(title: String, order: [Int], columns: Int)] = [
    ("Unsorted", Array(covers.indices), 2),
    ("Naive hue sort", naive, 2),
    ("ColorSort, phone", ColorSort.order(tones: tones, columns: 2), 2),
    ("Naive hue sort", naive, 5),
    ("ColorSort, iPad", ColorSort.order(tones: tones, columns: 5), 5),
]
let sizes = panels.map { gridSize(count: count, columns: $0.columns) }
let width = padding + sizes.reduce(0) { $0 + Int($1.width) + padding * 2 }
let height = padding * 2 + Int(sizes.map(\.height).max()!)

let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
var x = padding
for (panel, size) in zip(panels, sizes) {
    drawGrid(context, covers: covers, order: panel.order, columns: panel.columns,
             origin: CGPoint(x: x, y: padding), sheetHeight: height, title: panel.title)
    x += Int(size.width) + padding * 2
}

let url = URL(fileURLWithPath: arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
let colourful = tones.filter { $0?.hue != nil }.count
print("\(count) covers, \(colourful) sorted as colour, \(count - colourful) as neutral")
