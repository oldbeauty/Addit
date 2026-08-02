import SwiftUI
import UIKit

/// Picks one representative colour out of album art, for UI that should take on
/// the record's character instead of the app's accent.
///
/// This looks for the *vibrant* swatch, not the average and not the most
/// common one. Averaging a cover gives mud — opposing hues cancel, and every
/// busy sleeve converges on the same grey-brown. The most common colour is
/// usually the background: black, white, or a near-grey that no amount of
/// correction turns back into an accent. So pixels are binned by hue and each
/// bin scored on population *and* colourfulness, which is what lets the small
/// saturated area of a cover beat the large dull one.
///
/// `nonisolated` and free of state: it's a pure pass over pixels, and the
/// project's default `MainActor` isolation would otherwise pin it to the main
/// thread for no reason.
nonisolated enum CoverColor {
    /// Side length the cover is resampled to before counting. 32×32 is 1024
    /// pixels — enough for the histogram to be stable, few enough that the
    /// whole pass costs well under a millisecond and can sit inline with the
    /// artwork load.
    private static let sampleSide = 32

    /// Hue bins. 24 gives 15° each: fine enough to keep a red apart from an
    /// orange, coarse enough that dithering and JPEG ringing don't split one
    /// region of the cover across two neighbouring bins.
    private static let hueBins = 24

    /// Pixels this dark, this bright, or this colourless are dropped before
    /// counting. They make up the background of most covers, and none of them
    /// survives being pushed to a legible luminance with its hue intact.
    private static let minBrightness: CGFloat = 0.15
    private static let maxBrightness: CGFloat = 0.95
    private static let minSaturation: CGFloat = 0.20

    /// The cover's accent, or `nil` when the art has no usable colour in it at
    /// all — a monochrome sleeve, a scan of plain card. Callers should keep
    /// whatever they were using rather than render the grey that a
    /// "closest match" would hand back.
    static func accent(from image: UIImage) -> Color? {
        guard let cgImage = image.cgImage else { return nil }

        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)

        // `withUnsafeMutableBytes`, not `&pixels`: an inout-to-pointer
        // conversion is only valid for the duration of the call it's passed
        // to, and `CGContext` keeps the buffer well past its own initializer.
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: side,
                      height: side,
                      bitsPerComponent: 8,
                      bytesPerRow: side * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      // Alpha ignored rather than premultiplied: cover art is
                      // opaque in practice, and any transparent region lands on
                      // the zeroed (black) buffer, where the brightness floor
                      // discards it anyway.
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  )
            else { return false }

            // Averages each source cell into one sample, so the downscale
            // itself does the first round of noise reduction.
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var counts = [Int](repeating: 0, count: hueBins)
        var hueTotals = [CGFloat](repeating: 0, count: hueBins)
        var saturationTotals = [CGFloat](repeating: 0, count: hueBins)
        var brightnessTotals = [CGFloat](repeating: 0, count: hueBins)

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let (hue, saturation, brightness) = hsb(
                red: CGFloat(pixels[offset]) / 255,
                green: CGFloat(pixels[offset + 1]) / 255,
                blue: CGFloat(pixels[offset + 2]) / 255
            )
            guard brightness >= minBrightness,
                  brightness <= maxBrightness,
                  saturation >= minSaturation else { continue }

            let bin = min(hueBins - 1, Int(hue * CGFloat(hueBins)))
            counts[bin] += 1
            hueTotals[bin] += hue
            saturationTotals[bin] += saturation
            brightnessTotals[bin] += brightness
        }

        var bestBin: Int?
        var bestScore: CGFloat = 0
        for bin in 0..<hueBins where counts[bin] > 0 {
            let n = CGFloat(counts[bin])
            let saturation = saturationTotals[bin] / n
            // Population picks the region, saturation breaks the tie between
            // regions of similar size. The square root is the important part:
            // against a raw count, a washed-out sky covering half the sleeve
            // outvotes everything, and every cover with a sky returns blue.
            let score = sqrt(n) * (0.35 + saturation)
            if score > bestScore {
                bestScore = score
                bestBin = bin
            }
        }

        guard let bin = bestBin else { return nil }
        let n = CGFloat(counts[bin])
        // Averaging hue is only safe because it happens *within* one bin —
        // there's no wraparound to fall foul of inside a 15° window.
        return Color(
            hue: Double(hueTotals[bin] / n),
            saturation: Double(saturationTotals[bin] / n),
            brightness: Double(brightnessTotals[bin] / n)
        )
    }

    /// Inline RGB→HSB. `UIColor.getHue` would allocate an object per pixel.
    private static func hsb(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let delta = high - low

        var hue: CGFloat = 0
        if delta > 0 {
            if high == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if high == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }

        return (hue, high == 0 ? 0 : delta / high, high)
    }
}
