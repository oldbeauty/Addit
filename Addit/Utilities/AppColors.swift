import SwiftUI
import UIKit

extension Color {
    /// App-wide window/background color. Light mode keeps the standard system
    /// background (white); dark mode uses a warm charcoal instead of iOS's
    /// pure-black `systemBackground`, so large dark surfaces read softer —
    /// closer to editor/terminal UIs than an OLED void.
    ///
    /// Tweak the dark value here (single source of truth). Everything else
    /// paints this via the `.appBackground()` modifier.
    static let appBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255, alpha: 1) // #121212 (Spotify's base dark)
            : .systemBackground
    })
}

extension Color {
    /// Black or white, whichever stays legible on top of this color. Used so
    /// an icon over an accent-filled control never vanishes at the light/dark
    /// extremes of the accent palette.
    var legibleForeground: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.6 ? .black : .white
    }

    /// This color, darkened only as far as it takes for a **white** label to
    /// stay readable on top of it. Returns itself when it is already dark
    /// enough.
    ///
    /// For controls we draw ourselves, `legibleForeground` is the better tool —
    /// it keeps the accent exact and flips the text instead. This exists for
    /// system-drawn chrome where the label color isn't ours to set: a
    /// `.swipeActions` button template-renders its icon and title white — in
    /// *both* schemes, verified on iOS 26 — and ignores `foregroundStyle`, a
    /// `colorScheme` override, and per-component styling inside the `Label`
    /// alike. The tint is the only lever left, so a pale accent from the
    /// palette (`F1E9DB`, `FFFFFF`) has to give way here or the glyph vanishes
    /// into its own pill. Note this is not a dark-mode-only problem even though
    /// that's where it shows up: accents are stored per scheme, so it surfaces
    /// in whichever scheme the pale color was picked for.
    ///
    /// The one escape hatch, if you ever want the accent shown at its exact
    /// value: a `UIImage` carrying `.alwaysOriginal` keeps its own color, but
    /// *only* as the button's entire label. Give it a `Label` with title text
    /// alongside and the white template pass comes back for both.
    ///
    /// Scaling every channel by one factor is exactly a reduction in HSB
    /// brightness: hue and saturation come through untouched, so the pill still
    /// reads as the user's accent, just deeper.
    var legibleUnderWhiteLabel: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        // Sits under `legibleForeground`'s 0.6 flip point with a little margin,
        // so the two helpers can never disagree about the same color.
        let ceiling: CGFloat = 0.55
        guard luminance > ceiling else { return self }
        let factor = ceiling / luminance
        return Color(red: r * factor, green: g * factor, blue: b * factor, opacity: a)
    }

    /// This color, moved just far enough to read *against* `Color.appBackground`
    /// in the given scheme, and returned untouched when it already does.
    ///
    /// The two helpers above protect a label drawn **on top of** this color.
    /// This one is for color used as ink — waveform bars, marks on the window
    /// background — where the same color has to survive both a near-black
    /// (`#121212`) and a white backdrop. A cover accent can't be trusted to do
    /// that on its own: a pale yellow sleeve is invisible in light mode, a deep
    /// navy one invisible in dark.
    ///
    /// The two directions are not the same operation:
    ///
    /// - **Darkening** is one scale factor across all three channels, which is
    ///   exactly a drop in HSB brightness — hue and saturation come through
    ///   untouched.
    /// - **Brightening** can't be. Scaling up clips whichever channel is
    ///   already highest and drags the hue with it, so this blends toward white
    ///   instead: hue survives, and the light is paid for in saturation. That's
    ///   the right trade for a color that only has to stay recognisable as the
    ///   cover's, not stay exact.
    ///
    /// Both branches land on their target luminance exactly. Luminance is a
    /// linear combination of the channels whose weights sum to 1, so scaling
    /// every channel by `k` scales luminance by `k`, and blending every channel
    /// toward 1 by `t` moves luminance to `lum + (1 - lum)·t`.
    func legibleOnAppBackground(_ scheme: ColorScheme) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b

        if scheme == .dark {
            let floor: CGFloat = 0.42
            guard luminance < floor else { return self }
            let t = (floor - luminance) / max(0.0001, 1 - luminance)
            return Color(
                red: r + (1 - r) * t,
                green: g + (1 - g) * t,
                blue: b + (1 - b) * t,
                opacity: a
            )
        } else {
            // Same ceiling as `legibleUnderWhiteLabel`, for the same reason:
            // one flip point for the whole file.
            let ceiling: CGFloat = 0.55
            guard luminance > ceiling else { return self }
            let factor = ceiling / luminance
            return Color(red: r * factor, green: g * factor, blue: b * factor, opacity: a)
        }
    }

    /// The page, taken over by this colour — the record's own hue, run as hard
    /// as a page you still have to read can carry it.
    ///
    /// Deliberately **not** a blend toward the accent, which is the obvious
    /// implementation and the one that doesn't work. Mixing a vibrant swatch
    /// into the base at a fixed fraction lands somewhere different for every
    /// cover: a neon yellow lifts the page well clear of the base, a near-black
    /// navy barely moves it at all, and the same screen reads as a different
    /// brightness album to album. What carries over from the accent is only its
    /// **hue**, taken to full saturation; every album then tints the page by
    /// the same amount and only the direction changes.
    ///
    /// The knob that holds that invariant is **luminance, not HSB brightness**,
    /// and the difference only bites once the effect is strong. HSB brightness
    /// is the largest channel, which is not what the eye reads: at brightness
    /// 0.3 a yellow is `(0.3, 0.3, 0)` and a blue is `(0, 0, 0.3)`, and the
    /// yellow is roughly seven times the luminance. Faint, nobody could tell.
    /// At this strength that same pair is a bright olive page and a nearly
    /// black one, which is exactly the album-to-album lurch the hue-only rule
    /// exists to prevent. So the two constants below are luminances, each hue
    /// is driven onto its target, and what varies between them is saturation —
    /// yellow arrives deep and fully saturated, blue arrives lightened,
    /// because that is what those hues cost to reach one common weight.
    ///
    /// Those two constants are the whole intensity control, and they are set
    /// at the legibility ceiling rather than at the maximum: dark has to keep
    /// white and `.secondary` labels off it, light has to keep black ones. Turn
    /// them toward the base (0.07 dark, 1 light) to calm the page down; there
    /// is not much room left in the other direction.
    ///
    /// Returns the plain background for a colour with no hue worth taking —
    /// the caller gets the untinted page rather than a grey cast.
    /// Target luminance for a tinted page in dark mode. The base charcoal is
    /// 0.07, so this is a little over double it — a page that is plainly the
    /// record's colour, with white body copy still well clear of it.
    private var darkTintLuminance: CGFloat { 0.17 }

    /// Target luminance for a tinted page in light mode, down from white's 1.
    /// Lower than this and black labels start working for their contrast on
    /// the hues that have to arrive saturated to reach it.
    private var lightTintLuminance: CGFloat { 0.80 }

    func asAppBackgroundTint(_ scheme: ColorScheme) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a),
              s > 0.05
        else { return .appBackground }

        // The hue at its fullest: the most colour there is to be had in this
        // direction, before the luminance pin takes back whatever it must.
        var r: CGFloat = 0, g: CGFloat = 0, blue: CGFloat = 0
        UIColor(hue: h, saturation: 1, brightness: 1, alpha: 1)
            .getRed(&r, green: &g, blue: &blue, alpha: &a)

        let target = scheme == .dark ? darkTintLuminance : lightTintLuminance
        let luminance = 0.299 * r + 0.587 * g + 0.114 * blue

        // The same two moves, and the same asymmetry, as
        // `legibleOnAppBackground`: scaling down is a pure drop in HSB
        // brightness and costs nothing, while lifting has to blend toward
        // white and is paid for in saturation. Every hue lands on `target`
        // exactly — scaling all three channels by `k` scales luminance by `k`,
        // and blending them toward 1 by `t` moves it to `lum + (1 - lum)·t`.
        if luminance > target {
            let k = target / luminance
            return Color(red: r * k, green: g * k, blue: blue * k)
        } else {
            let t = (target - luminance) / max(0.0001, 1 - luminance)
            return Color(
                red: r + (1 - r) * t,
                green: g + (1 - g) * t,
                blue: blue + (1 - blue) * t
            )
        }
    }
}

extension View {
    /// Paint `Color.appBackground` behind a scrollable surface, hiding the
    /// scroll view / List's own opaque background so the charcoal shows
    /// through. Apply to each screen's root scrollable container.
    /// Pass a `tint` (see `asAppBackgroundTint`) to have the page take on the
    /// current artwork's hue instead of the flat base. It crossfades, because
    /// the value arrives when the cover resolves — which on a cold album is
    /// after the page is already on screen, and a hard cut there reads as a
    /// glitch rather than as the art landing.
    func appBackground(tint: Color? = nil) -> some View {
        appBackground(tint: tint, fadingOver: nil)
    }

    /// As above, but the tint dissolves into the plain background across
    /// `fadingOver` — a top-down span given in fractions of the screen's
    /// height. Album detail hands it the cover's own top and bottom edges, so
    /// the wash is at full strength where the art begins and gone by where it
    /// ends.
    ///
    /// The tint is painted as a *mask* over the ordinary background rather than
    /// as a two-colour gradient, for two reasons. Interpolating between two
    /// `Color`s means unpacking them to components, and — more importantly — a
    /// straight ramp has a corner where it leaves the flat region, which the eye
    /// picks up as a band even when the colours are close. Alpha stops are easy
    /// to shape, so the ramp follows a smoothstep and starts and ends on a
    /// tangent instead of a corner.
    func appBackground(tint: Color?, fadingOver span: ClosedRange<CGFloat>?) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background {
                Group {
                    if let tint, let span, span.upperBound > span.lowerBound {
                        Color.appBackground.overlay {
                            tint.mask(
                                LinearGradient(
                                    stops: appWashStops(from: span.lowerBound,
                                                        to: span.upperBound),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        }
                    } else {
                        tint ?? .appBackground
                    }
                }
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: tint)
            }
    }


    /// Replace iOS 26's adaptive top scroll edge effect with Addit's own top
    /// edge: a progressive blur over the status bar (after Cosmos's), a faint
    /// darkness over it, and a fade in the page's colour that runs down to
    /// the bottom of the toolbar buttons — all three eased so that no edge
    /// can be found. The system effect samples the content scrolling under
    /// the top bar and flips between light and dark treatments on its own —
    /// the status-bar clock/wifi text flips with it — regardless of the
    /// app's scheme; this hides it and pins the bar scheme so nothing up
    /// there reacts to what scrolls underneath. Apply to a screen's root
    /// scrollable container, alongside `.appBackground()`, with the same
    /// `tint` (the fade is the page's colour, continued over the bar; a
    /// tinted page under an untinted fade shows the join). Taps pass through.
    func statusBarBlur(tint: Color? = nil) -> some View {
        modifier(StatusBarBlurModifier(tint: tint))
    }
}

private struct StatusBarBlurModifier: ViewModifier {
    var tint: Color?

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectHidden(true, for: .top)
            .overlay(alignment: .top) {
                // Taller than any status bar and toolbar; the view draws only
                // what it measures from its window and nav bar.
                StatusBarBlurStrip(dark: colorScheme == .dark,
                                   page: UIColor(tint ?? .appBackground))
                    .frame(height: 220)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
            .toolbarColorScheme(colorScheme, for: .navigationBar)
    }
}

private struct StatusBarBlurStrip: UIViewRepresentable {
    var dark: Bool
    var page: UIColor

    func makeUIView(context: Context) -> StatusBarBlurView { StatusBarBlurView() }

    func updateUIView(_ view: StatusBarBlurView, context: Context) {
        view.dark = dark
        view.page = page
    }
}

/// The top edge, in three layers:
///
/// 1. **A progressive blur** over the status bar, after Cosmos's: the blur
///    *radius* eases from full strength under the clock down to nothing,
///    rather than a uniform blur faded out by opacity (a half-transparent
///    blur is a sharp image under a blurred one, so it shows where it
///    stops). Built on the backdrop of a `UIVisualEffectView`, whose own
///    gaussian filter is swapped for Core Animation's `variableBlur`, which
///    reads the radius per pixel from a mask image. That filter is private
///    API (in use in shipping apps, but private all the same); if it can't
///    be made, there's no blur and the two fades still draw.
/// 2. **A faint darkness**, black, over the blur's strip.
/// 3. **A fade in the page's colour**, from the top of the screen to just
///    past the bottom of the toolbar buttons.
///
/// What makes a fade's end invisible: the eye finds a gradient's edge where
/// its *slope* jumps (Mach bands), not where it reaches zero, and in dark
/// tones it finds 8-bit steps. So every curve here leaves both ends flat
/// (smootherstep-based: they leave the top like t³ and meet zero like
/// (1−t)³ or flatter), the curves are evaluated per pixel row rather
/// than as a `CAGradientLayer`'s straight segments between stops (each stop
/// is a slope jump), and the two fades are one image dithered with
/// triangular noise of about one level, which turns banding into grain too
/// fine to see.
final class StatusBarBlurView: UIView {
    /// Blur radius under the top of the status bar, in points. Strong
    /// enough to obscure, not just soften: a small radius over the
    /// backdrop's sampled copy only looks pixelated.
    private static let maxRadius: CGFloat = 24
    /// How far down the status bar the blur holds full strength.
    private static let hold: CGFloat = 0.2
    /// How far past the status bar the blur runs before it has thinned out.
    private static let tail: CGFloat = 20
    /// Peak opacity of the black shade at the very top, per scheme. Kept
    /// low: it should be felt, not seen.
    private static let shadeDark: CGFloat = 0.32
    private static let shadeLight: CGFloat = 0.08
    /// Peak opacity of the page-colour fade at the very top.
    private static let fadePeak: CGFloat = 0.75
    /// How far past the bottom of the toolbar buttons the fade's curve runs
    /// to zero. Sized so the fade is down to about 1% (the faintest a shade
    /// change registers) right at the buttons' bottom; the rest of the way
    /// it goes to nothing on a flat tangent.
    private static let fadeOvershoot: CGFloat = 16
    /// Toolbar height when no navigation bar can be found.
    private static let fallbackBar: CGFloat = 44
    /// Width of the dithered run, in pixels; each row repeats its own run
    /// across the full width.
    private static let tileWidth = 256

    var dark = false {
        didSet { if dark != oldValue { setNeedsLayout() } }
    }
    var page: UIColor = .clear {
        didSet { if page != oldValue { setNeedsLayout() } }
    }

    private let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let fades = CALayer()
    private var blurKey: (height: CGFloat, inset: CGFloat)?
    private var fadeKey: String?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        effectView.isUserInteractionEnabled = false
        addSubview(effectView)
        layer.addSublayer(fades)
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) {
            (self: StatusBarBlurView, _: UITraitCollection) in
            self.blurKey = nil
            self.fadeKey = nil
            self.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // UIKit rebuilds the backdrop's filters when the view lands in a
        // window or the traits change; put ours back each time.
        blurKey = nil
        setNeedsLayout()
        // The nav bar may settle after this view does.
        DispatchQueue.main.async { [weak self] in self?.setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = window?.safeAreaInsets.top ?? 0
        let blurHeight = inset > 0 ? inset + Self.tail : 0
        effectView.isHidden = blurHeight == 0
        effectView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: blurHeight)
        if blurHeight > 0, blurKey.map({ $0 != (blurHeight, inset) }) ?? true {
            blurKey = (blurHeight, inset)
            applyFilter(height: blurHeight, inset: inset)
        }

        let fadeHeight = inset > 0 ? barBottom(inset: inset) + Self.fadeOvershoot : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fades.frame = CGRect(x: 0, y: 0, width: bounds.width, height: fadeHeight)
        fades.isHidden = fadeHeight == 0
        CATransaction.commit()
        guard fadeHeight > 0 else { return }
        let base = page.resolvedColor(with: traitCollection)
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let key = "\(bounds.width)|\(fadeHeight)|\(blurHeight)|\(dark)|\(base)|\(scale)"
        guard key != fadeKey else { return }
        fadeKey = key
        // As the layer's contents, not a pattern colour: Core Animation draws
        // a pattern from the bottom row up, which turns the fade upside down.
        // Contents draw the image's first row at the layer's top.
        let image = Self.fadeImage(width: bounds.width, height: fadeHeight,
                                   shadeHeight: blurHeight,
                                   shadePeak: dark ? Self.shadeDark : Self.shadeLight,
                                   base: base, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fades.contentsScale = scale
        fades.contents = image
        CATransaction.commit()
    }

    /// The bottom of the toolbar buttons, in this view's coordinates (it
    /// sits at the top of the screen): the navigation bar's lower edge,
    /// since the buttons fill its height.
    private func barBottom(inset: CGFloat) -> CGFloat {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController,
               let navigation = controller.navigationController ?? (controller as? UINavigationController),
               !navigation.isNavigationBarHidden {
                let bar = navigation.navigationBar
                let bottom = bar.convert(bar.bounds, to: self).maxY
                if bottom > inset { return bottom }
            }
            responder = next
        }
        return inset + Self.fallbackBar
    }

    private func applyFilter(height: CGFloat, inset: CGFloat) {
        // The backdrop is the first subview; the rest are the tint and
        // overlay layers, hidden so nothing is painted over the content.
        guard let backdrop = effectView.subviews.first else { return }
        for overlay in effectView.subviews.dropFirst() { overlay.isHidden = true }
        // The backdrop samples the screen at a fraction of its resolution;
        // at the thin end of the blur that reads as pixels. Full scale.
        backdrop.layer.setValue(1.0, forKey: "scale")
        guard let filter = Self.variableBlur(mask: Self.maskImage(height: height, inset: inset)) else {
            backdrop.layer.filters = nil
            return
        }
        backdrop.layer.filters = [filter]
    }

    private static func variableBlur(mask: CGImage?) -> NSObject? {
        guard let mask,
              let type = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let make = NSSelectorFromString("filterWithType:")
        guard type.responds(to: make),
              let filter = type.perform(make, with: "variableBlur")?.takeUnretainedValue() as? NSObject
        else { return nil }
        filter.setValue(maxRadius, forKey: "inputRadius")
        filter.setValue(mask, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        return filter
    }

    /// Strength at `t` (0 at the top of the fall, 1 at the bottom): a
    /// smootherstep fall, squared — flat leaving the top, and meeting zero
    /// so flatly that the last stretch can't be told from nothing.
    private static func falloff(_ t: CGFloat) -> CGFloat {
        let t = max(0, min(1, t))
        let s = 1 - t * t * t * (t * (t * 6 - 15) + 10)
        return s * s
    }

    /// The page fade's curve: a plain smootherstep fall, flat at both ends
    /// (it meets zero like (1−t)³). Not squared like `falloff`: that one is
    /// below 1% for its last third, so a fade on it looks finished well
    /// before the buttons. This one is still visible, barely, at the end.
    private static func fadeCurve(_ t: CGFloat) -> CGFloat {
        let t = max(0, min(1, t))
        return 1 - t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// The radius map: opaque (full radius) for the top `hold` of the status
    /// bar, then `falloff` down to clear at the bottom.
    private static func maskImage(height: CGFloat, inset: CGFloat) -> CGImage? {
        let rows = max(Int(height.rounded(.up)), 2)
        let start = min(inset * hold / height, 0.99)
        var pixels = [UInt8](repeating: 0, count: rows * 4)
        for row in 0..<rows {
            let y = CGFloat(row) / CGFloat(rows - 1)
            let a = UInt8(falloff((y - start) / (1 - start)) * 255)
            // Premultiplied black: only the alpha carries the map.
            pixels[row * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: 1, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// The darkness and the page fade as one premultiplied, dithered image
    /// at the layer's full pixel size, the page colour over the black. Row 0
    /// is the top of the screen. Each row's colour is the exact curve at that
    /// row; each pixel adds triangular noise of ±1 level before rounding,
    /// over a `tileWidth` run that the row then repeats across.
    private static func fadeImage(width: CGFloat, height: CGFloat, shadeHeight: CGFloat,
                                  shadePeak: CGFloat, base: UIColor, scale: CGFloat) -> CGImage? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard width > 0, base.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        // Extended-sRGB components can stray outside 0…1.
        r = min(max(r, 0), 1); g = min(max(g, 0), 1); b = min(max(b, 0), 1); a = min(max(a, 0), 1)
        let rows = max(Int((height * scale).rounded(.up)), 2)
        let columns = max(Int((width * scale).rounded(.up)), 1)
        let run = min(tileWidth, columns)
        let rowBytes = columns * 4
        var pixels = [UInt8](repeating: 0, count: rows * rowBytes)
        var seed: UInt32 = 0x9E37_79B9
        func noise() -> Float {
            // xorshift32, two uniforms summed: triangular on (−1, 1).
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let u1 = Float(seed & 0xFFFF) / 65535
            let u2 = Float(seed >> 16) / 65535
            return u1 + u2 - 1
        }
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let start = buffer.baseAddress else { return }
            for row in 0..<rows {
                // Row 0 is the top: both curves are at full strength there.
                let y = (CGFloat(row) + 0.5) / scale
                let shade = y < shadeHeight ? shadePeak * falloff(y / shadeHeight) : 0
                let fade = fadePeak * a * fadeCurve(y / height)
                let alpha = Float(fade + shade * (1 - fade)) * 255
                let red = Float(r * fade) * 255
                let green = Float(g * fade) * 255
                let blue = Float(b * fade) * 255
                let rowStart = start + row * rowBytes
                for column in 0..<run {
                    let pixel = rowStart + column * 4
                    let ao = min(max(alpha + noise(), 0), 255).rounded()
                    pixel[3] = UInt8(ao)
                    pixel[0] = UInt8(min(max(red + noise(), 0), ao).rounded())
                    pixel[1] = UInt8(min(max(green + noise(), 0), ao).rounded())
                    pixel[2] = UInt8(min(max(blue + noise(), 0), ao).rounded())
                }
                // Repeat the run across the row, doubling what's filled each
                // pass; source and destination never overlap.
                var filled = run
                while filled < columns {
                    let count = min(filled, columns - filled)
                    (rowStart + filled * 4).update(from: rowStart, count: count * 4)
                    filled += count
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

/// Alpha stops tracing `1 - smoothstep` across the span. The interior
/// values are the curve sampled at quarters; the flat runs either side are
/// what make the start and end of the fade impossible to locate.
private func appWashStops(from start: CGFloat, to end: CGFloat) -> [Gradient.Stop] {
    let span = end - start
    let curve: [(CGFloat, Double)] = [
        (0.00, 1.000),
        (0.25, 0.844),
        (0.50, 0.500),
        (0.75, 0.156),
        (1.00, 0.000),
    ]
    var stops: [Gradient.Stop] = [.init(color: .white, location: 0)]
    stops += curve.map { .init(color: .white.opacity($0.1), location: start + span * $0.0) }
    stops.append(.init(color: .clear, location: 1))
    return stops
}
