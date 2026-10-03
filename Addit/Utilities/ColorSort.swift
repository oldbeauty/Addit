import CoreGraphics
import Foundation

/// What a cover looks like from across the room — the measure the library's
/// "Sort by Color" sorts on.
///
/// Not `CoverColor`, on purpose. That one is for tinting UI and hunts for the
/// cover's most *vibrant* swatch, so a black sleeve with a small red logo comes
/// back red. Sorted by that, the red end of the wall fills with black covers.
/// This asks what the tile reads as at thumbnail size: the hue carrying the
/// most colour across the cover, how much of the cover carries it, and how
/// light the whole thing is.
///
/// Measured in OKLab, where equal steps look like equal steps. In HSB, a dark
/// navy and a bright sky blue are "the same hue at the same saturation", and
/// yellow's hue band is a sliver next to green's.
///
/// CoreGraphics only, no UIKit, so `tools/colorsortpreview` can compile this
/// file as it ships and lay a set of covers out on a Mac.
nonisolated struct CoverTone: Sendable {
    /// How light the cover looks, 0…1: the average of each pixel's OKLab
    /// lightness. Not the lightness of the average colour, which is the
    /// physically honest blur but not what an eye reports — mixed in linear
    /// light, a small bright mark on a black sleeve lifts the mean as far as
    /// a whole sleeve of mid-tan, and the black sleeve sorts as a light one.
    let lightness: Double
    /// OKLab hue in degrees, or nil when too little of the cover carries any
    /// colour for its hue to mean anything (black, white, grey, a faded scan).
    let hue: Double?

    /// Resampled to this before measuring: plenty for proportions, and the
    /// downscale averages away texture and JPEG noise first.
    private static let side = 32
    private static let hueBins = 36
    /// Chroma below this is noise — the tint in a "grey" JPEG, a scanner's
    /// colour cast — and counts for nothing.
    private static let chromaFloor = 0.02
    /// How much colour a cover needs to be sorted as a colour at all: roughly
    /// a tenth of the sleeve in something strong, or a whole sleeve muted.
    private static let minStrength = 0.015

    static func measure(_ cgImage: CGImage) -> CoverTone? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = side
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base, width: side, height: side,
                      bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var lightnessSum = 0.0
        var histogram = [Double](repeating: 0, count: hueBins)
        var samples: [(hue: Double, weight: Double)] = []
        samples.reserveCapacity(side * side)

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let lab = oklab(
                linear[Int(pixels[offset])],
                linear[Int(pixels[offset + 1])],
                linear[Int(pixels[offset + 2])]
            )
            lightnessSum += lab.l
            let weight = hypot(lab.a, lab.b) - chromaFloor
            guard weight > 0 else { continue }
            let hue = degrees(atan2(lab.b, lab.a))
            histogram[min(hueBins - 1, Int(hue / 360 * Double(hueBins)))] += weight
            samples.append((hue, weight))
        }

        let count = Double(side * side)
        let lightness = lightnessSum / count

        // The peak of the hue histogram, smoothed round the circle so a colour
        // straddling two bins isn't outvoted by a smaller one that sits in one.
        let kernel = [1.0, 2.0, 3.0, 2.0, 1.0]
        var peak = 0
        var peakValue = -1.0
        for bin in 0..<hueBins {
            var value = 0.0
            for (k, w) in kernel.enumerated() {
                value += w * histogram[(bin + k - 2 + hueBins) % hueBins]
            }
            if value > peakValue { peakValue = value; peak = bin }
        }

        // Everything within 30° of the peak is that colour. Its weight is how
        // much of the cover is coloured with it; its mean is the hue. Summing
        // vectors rather than angles is what makes 355° and 5° average to 0°.
        let peakHue = (Double(peak) + 0.5) * 360 / Double(hueBins)
        var strength = 0.0
        var vector = (x: 0.0, y: 0.0)
        for sample in samples where angularDistance(sample.hue, peakHue) <= 30 {
            strength += sample.weight
            vector.x += sample.weight * cos(radians(sample.hue))
            vector.y += sample.weight * sin(radians(sample.hue))
        }
        strength /= count

        return CoverTone(
            lightness: lightness,
            hue: strength >= minStrength ? degrees(atan2(vector.y, vector.x)) : nil
        )
    }

    /// sRGB byte → linear light, once per byte value rather than once per pixel.
    private static let linear: [Double] = (0...255).map { byte in
        let c = Double(byte) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Linear sRGB → OKLab (Björn Ottosson's matrices).
    private static func oklab(_ r: Double, _ g: Double, _ b: Double) -> (l: Double, a: Double, b: Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    fileprivate static func degrees(_ radians: Double) -> Double {
        let d = radians * 180 / .pi
        return d < 0 ? d + 360 : d
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    fileprivate static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

/// Lays covers out as a rainbow on a grid.
///
/// Sorting by hue and pouring the result into the grid in reading order would
/// be a rainbow only along the reading line. Every row would run its own
/// little gradient and then snap back to the left edge, and the columns would
/// carry no meaning at all. Here the grid's two directions each carry one:
///
/// - **Down the rows, hue.** Consecutive runs of the hue order, one row's
///   worth each, so every row is a band of neighbouring colours and the bands
///   step through the spectrum top to bottom: pink and violet first, down
///   through blue, green and yellow, to orange and red.
/// - **Across a row, lightness**, lightest on the left. Each column becomes a
///   shade, so the left edge runs pale and the right edge deep — a paint-chip
///   wall, not a strip that wraps.
///
/// Covers with no colour to speak of follow the spectrum, white through grey
/// to black, and covers with no art at all come last.
nonisolated enum ColorSort {
    /// `tones[i]` belongs to item `i`; nil is an item with no art. Returns the
    /// items' indices in their new order. `firstColumn` is how many slots of
    /// the first row are already taken by whatever sits ahead of these items,
    /// so the rows here line up with the grid's real ones.
    static func order(tones: [CoverTone?], columns: Int, firstColumn: Int = 0) -> [Int] {
        let columns = max(columns, 1)
        var chromatic: [(index: Int, hue: Double, lightness: Double)] = []
        var neutral: [(index: Int, lightness: Double)] = []
        var unknown: [Int] = []
        for (index, tone) in tones.enumerated() {
            if let tone, let hue = tone.hue {
                chromatic.append((index, hue, tone.lightness))
            } else if let tone {
                neutral.append((index, tone.lightness))
            } else {
                unknown.append(index)
            }
        }

        let cut = spectrumStart(hues: chromatic.map(\.hue))
        // Backwards round the circle from the cut: OKLab hue rises from red
        // through yellow, green and blue to pink, and the wall runs pink to
        // red. (It ran red to pink until 2026-10-01; reversed by request.)
        let spectrum = chromatic.sorted {
            let a = ($0.hue - cut + 360).truncatingRemainder(dividingBy: 360)
            let b = ($1.hue - cut + 360).truncatingRemainder(dividingBy: 360)
            return (b, $0.index) < (a, $1.index)
        }
        let greys = neutral.sorted { ($1.lightness, $0.index) < ($0.lightness, $1.index) }

        // One sequence, cut into the grid's real rows, then each row re-laid
        // light to dark. Colours stay ahead of greys within the row they share.
        typealias Entry = (index: Int, rank: Int, lightness: Double)
        let sequence: [Entry] =
            spectrum.map { ($0.index, 0, $0.lightness) }
            + greys.map { ($0.index, 1, $0.lightness) }
            + unknown.map { ($0, 2, 0) }

        var result: [Int] = []
        result.reserveCapacity(sequence.count)
        var start = 0
        var rowLength = columns - (firstColumn % columns)
        while start < sequence.count {
            let row = sequence[start..<min(start + rowLength, sequence.count)]
            result += row.enumerated().sorted { a, b in
                if a.element.rank != b.element.rank { return a.element.rank < b.element.rank }
                // No-art covers keep the order they came in.
                if a.element.rank == 2 { return a.offset < b.offset }
                return (b.element.lightness, a.offset) < (a.element.lightness, b.offset)
            }.map(\.element.index)
            start += rowLength
            rowLength = columns
        }
        return result
    }

    /// Where the circle of hues is cut open into a line: somewhere between
    /// pink and red, as a rainbow runs, but at whichever point there is
    /// farthest from any cover, so a cluster of reds isn't split between the
    /// first row and the last.
    private static func spectrumStart(hues: [Double]) -> Double {
        guard !hues.isEmpty else { return 5 }
        var best = 5.0
        var bestClearance = -1.0
        // OKLab hue: pinks run up to about 355°, reds start near 15°.
        for step in 0...40 {
            let candidate = (345.0 + Double(step)).truncatingRemainder(dividingBy: 360)
            let clearance = hues.map { CoverTone.angularDistance($0, candidate) }.min() ?? 0
            let preferred = clearance > bestClearance + 0.5
                || (abs(clearance - bestClearance) <= 0.5
                    && CoverTone.angularDistance(candidate, 5) < CoverTone.angularDistance(best, 5))
            if preferred {
                best = candidate
                bestClearance = clearance
            }
        }
        return best
    }
}
