import Metal
import SwiftUI
import UIKit

/// The album menu's ornaments, rendered on the GPU once and kept as images.
///
/// A `Menu` is drawn by UIKit as a `UIMenu`, and a `UIMenu` item's icon is a
/// `UIImage` — there is no SwiftUI host inside one to run a `colorEffect`. So
/// unlike the Access sheet's icons, which are live shader views, these are
/// rendered offscreen by `MenuIcons.metal` and `GlassLogo.metal` and handed
/// over as still images. The models and the room are the same; only the
/// delivery differs.
///
/// Everything renders in **one** command buffer on first use. Encoding
/// thirteen dispatches and waiting once costs a single round trip to the GPU,
/// where thirteen separate renders would each pay that latency inside a view
/// body — which is exactly where this gets called from.
@MainActor
enum MenuIconRenderer {

    /// Rendered size, and the only knob that sets how large these appear.
    ///
    /// Twice the height an SF Symbol comes out at in a menu row, which is a
    /// deliberate break rather than an oversight: these are modelled objects,
    /// and at symbol size the pencil's ferrule and the eye's pupil were
    /// spending a pixel each. The row grows to fit them, so the album menu is
    /// taller than a stock one — that is the trade being made.
    private static let pointSize: CGFloat = 40

    private static var cache: [MenuIcon: UIImage] = [:]
    /// Set once a render has been attempted, successful or not. Without it a
    /// device that can't render (no Metal, no library) would retry the whole
    /// set on every menu build.
    private static var attempted = false

    /// The ornament for `icon`, or `nil` if this device couldn't render it —
    /// in which case callers fall back to the SF Symbol they replaced.
    static func image(_ icon: MenuIcon) -> UIImage? {
        if !attempted {
            attempted = true
            renderAll()
        }
        return cache[icon]
    }

    private static func renderAll() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder()
        else { return }

        // One pipeline per kernel, built once for the whole set.
        var pipelines: [MenuIconKernel: MTLComputePipelineState] = [:]
        for kernel in MenuIconKernel.allCases {
            guard let function = library.makeFunction(name: kernel.functionName),
                  let pipeline = try? device.makeComputePipelineState(function: function)
            else { continue }
            pipelines[kernel] = pipeline
        }

        // `UITraitCollection.current` reports a scale of 0 when asked outside a
        // view's update — which is survivable everywhere else and fatal here,
        // since it would size every texture to a single pixel and cache
        // thirteen coloured dots. 3 is the floor for every device this ships to.
        let reported = UITraitCollection.current.displayScale
        let scale = reported > 0 ? reported : 3
        let side = max(1, Int((pointSize * scale).rounded()))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]

        var textures: [(MenuIcon, MTLTexture)] = []
        for icon in MenuIcon.allCases {
            let source = icon.source
            guard let pipeline = pipelines[source.kernel],
                  let texture = device.makeTexture(descriptor: descriptor)
            else { continue }

            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture, index: 0)
            var index = source.index
            encoder.setBytes(&index, length: MemoryLayout<Int32>.size, index: 0)

            let group = MTLSize(width: 8, height: 8, depth: 1)
            encoder.dispatchThreadgroups(
                MTLSize(width: (side + 7) / 8, height: (side + 7) / 8, depth: 1),
                threadsPerThreadgroup: group)

            textures.append((icon, texture))
        }

        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        for (icon, texture) in textures {
            if let image = makeImage(from: texture, side: side, scale: scale) {
                cache[icon] = image
            }
        }
    }

    private static func makeImage(from texture: MTLTexture, side: Int, scale: CGFloat) -> UIImage? {
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * side)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  // The kernels return premultiplied RGBA, which is also what
                  // lets their supersampler average edge pixels correctly.
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { return nil }

        // `.alwaysOriginal` is not optional here: a menu item image defaults to
        // template rendering, which would flatten every one of these to a flat
        // tint of the menu's label colour — chrome, yellow barrel and all.
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
            .withRenderingMode(.alwaysOriginal)
    }
}

/// Which shader draws an ornament. Two, because the storage-provider marks are
/// the real brand geometry and live with the rest of it in `GlassLogo.metal`.
enum MenuIconKernel: CaseIterable {
    case menuIcons
    case glassLogo

    var functionName: String {
        switch self {
        case .menuIcons: "menuIconKernel"
        case .glassLogo: "glassLogoKernel"
        }
    }
}

/// One ornament. The indices are the `k*` constants in the two shaders — keep
/// them in step or the menu quietly shows the wrong object.
enum MenuIcon: CaseIterable {
    case access
    case shareLink
    case chat
    case edit
    case download
    case removeDownload
    case eye
    case eyeSlash
    case export
    case duplicate
    case driveMark
    case cloudMark
    case slabMark

    var source: (kernel: MenuIconKernel, index: Int32) {
        switch self {
        case .access:         (.menuIcons, 0)
        case .shareLink:      (.menuIcons, 1)
        case .chat:           (.menuIcons, 2)
        case .edit:           (.menuIcons, 3)
        case .download:       (.menuIcons, 4)
        case .removeDownload: (.menuIcons, 5)
        case .eye:            (.menuIcons, 6)
        case .eyeSlash:       (.menuIcons, 7)
        case .export:         (.menuIcons, 8)
        case .duplicate:      (.menuIcons, 9)
        case .driveMark:      (.glassLogo, 0)
        case .cloudMark:      (.glassLogo, 1)
        case .slabMark:       (.glassLogo, 2)
        }
    }

    /// A menu row's label carrying this ornament.
    ///
    /// Returns the concrete `Label<Text, Image>` rather than `some View` on
    /// purpose. SwiftUI reads a menu item's label to build the `UIAction`
    /// behind it, and it finds the title and the icon by looking for exactly
    /// this shape — wrapping the branch in an `AnyView` or a custom `View`
    /// hands `UIMenu` something it can't take apart, and the row comes out
    /// with no icon at all.
    ///
    /// `fallback` is the SF Symbol this ornament replaced, used verbatim if
    /// the render didn't happen.
    func label(_ title: String, fallback: String) -> Label<Text, Image> {
        if let image = MenuIconRenderer.image(self) {
            return Label { Text(title) } icon: { Image(uiImage: image) }
        }
        return Label { Text(title) } icon: { Image(systemName: fallback) }
    }
}
