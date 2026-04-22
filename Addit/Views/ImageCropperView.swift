import SwiftUI
import UIKit

struct ImageCropperView: View {
    let image: UIImage
    let onCropped: (UIImage) -> Void
    let onCancelled: () -> Void

    @State private var normalizedImage: UIImage?

    // Committed transform from previous gestures
    @State private var steadyOffset: CGSize = .zero
    @State private var steadyScale: CGFloat = 1.0

    // Live delta from current in-progress gesture
    @State private var gestureOffset: CGSize = .zero
    @State private var gestureScale: CGFloat = 1.0

    private var currentScale: CGFloat {
        steadyScale * gestureScale
    }

    private var currentOffset: CGSize {
        CGSize(
            width: steadyOffset.width + gestureOffset.width,
            height: steadyOffset.height + gestureOffset.height
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let cropSide = min(geometry.size.width, geometry.size.height) - 48
            let img = normalizedImage ?? image
            let baseSize = baseImageSize(for: cropSide, image: img)

            ZStack {
                Color.black.ignoresSafeArea()

                // The scaled image lives inside a flexible `Color.clear`
                // layer that sizes to the ZStack's bounds. The overlaid
                // `Image` can grow/shrink via `.frame(...).offset(...)`
                // without propagating its size up to the ZStack, and
                // `.clipped()` keeps the drawing inside the screen. This
                // is what keeps the crop cutout locked and the Cancel /
                // Save buttons on-screen no matter how wide or tall the
                // source photo is.
                Color.clear
                    .overlay {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: baseSize.width * currentScale,
                                height: baseSize.height * currentScale
                            )
                            .offset(currentOffset)
                            .animation(.interactiveSpring, value: steadyOffset)
                            .animation(.interactiveSpring, value: steadyScale)
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(combinedGesture(cropSide: cropSide, baseSize: baseSize))

                // Dimming overlay with square cutout
                CropOverlay(cropSide: cropSide)
                    .allowsHitTesting(false)

                // Cancel / Save buttons
                VStack {
                    Spacer()
                    HStack {
                        Button("Cancel") { onCancelled() }
                            .foregroundStyle(.white)
                        Spacer()
                        Button("Save") {
                            let cropped = performCrop(
                                cropSide: cropSide,
                                baseSize: baseSize,
                                image: img
                            )
                            onCropped(cropped)
                        }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
            .onAppear {
                normalizedImage = normalizeOrientation(image)
            }
        }
        .statusBarHidden()
    }

    // MARK: - Sizing

    /// Base displayed size so the image aspect-fills the crop square at scale 1.0.
    private func baseImageSize(for cropSide: CGFloat, image: UIImage) -> CGSize {
        let imgW = image.size.width
        let imgH = image.size.height
        guard imgW > 0, imgH > 0 else { return CGSize(width: cropSide, height: cropSide) }
        let scale = max(cropSide / imgW, cropSide / imgH)
        return CGSize(width: imgW * scale, height: imgH * scale)
    }

    // MARK: - Gestures

    private func combinedGesture(cropSide: CGFloat, baseSize: CGSize) -> some Gesture {
        let drag = DragGesture()
            .onChanged { value in
                gestureOffset = value.translation
            }
            .onEnded { value in
                steadyOffset = clampedOffset(
                    raw: CGSize(
                        width: steadyOffset.width + value.translation.width,
                        height: steadyOffset.height + value.translation.height
                    ),
                    scale: steadyScale * gestureScale,
                    cropSide: cropSide,
                    baseSize: baseSize
                )
                gestureOffset = .zero
            }

        let magnify = MagnifyGesture()
            .onChanged { value in
                gestureScale = value.magnification
            }
            .onEnded { value in
                let newScale = min(5.0, max(1.0, steadyScale * value.magnification))
                steadyScale = newScale
                gestureScale = 1.0
                steadyOffset = clampedOffset(
                    raw: steadyOffset,
                    scale: newScale,
                    cropSide: cropSide,
                    baseSize: baseSize
                )
            }

        return drag.simultaneously(with: magnify)
    }

    // MARK: - Clamping

    /// Clamp offset so the image always fully covers the crop square.
    private func clampedOffset(
        raw: CGSize,
        scale: CGFloat,
        cropSide: CGFloat,
        baseSize: CGSize
    ) -> CGSize {
        let displayedWidth = baseSize.width * scale
        let displayedHeight = baseSize.height * scale
        let maxX = max(0, (displayedWidth - cropSide) / 2)
        let maxY = max(0, (displayedHeight - cropSide) / 2)
        return CGSize(
            width: min(maxX, max(-maxX, raw.width)),
            height: min(maxY, max(-maxY, raw.height))
        )
    }

    // MARK: - Crop

    private func performCrop(cropSide: CGFloat, baseSize: CGSize, image: UIImage) -> UIImage {
        let scale = currentScale
        let offset = currentOffset

        let displayedWidth = baseSize.width * scale
        let displayedHeight = baseSize.height * scale

        // Crop square center in the image's local coordinate space
        let cropCenterX = displayedWidth / 2 - offset.width
        let cropCenterY = displayedHeight / 2 - offset.height

        // Crop rect in displayed points
        let cropRectPts = CGRect(
            x: cropCenterX - cropSide / 2,
            y: cropCenterY - cropSide / 2,
            width: cropSide,
            height: cropSide
        )

        // Convert to original image pixel coordinates
        let pointsToOriginal = image.size.width / displayedWidth
        let pixelRect = CGRect(
            x: cropRectPts.origin.x * pointsToOriginal,
            y: cropRectPts.origin.y * pointsToOriginal,
            width: cropRectPts.width * pointsToOriginal,
            height: cropRectPts.height * pointsToOriginal
        )

        // Account for UIImage.scale (@2x, @3x)
        let imgScale = image.scale
        let cgPixelRect = CGRect(
            x: pixelRect.origin.x * imgScale,
            y: pixelRect.origin.y * imgScale,
            width: pixelRect.width * imgScale,
            height: pixelRect.height * imgScale
        )

        guard let cgImage = image.cgImage,
              let croppedCG = cgImage.cropping(to: cgPixelRect) else {
            return image
        }

        return UIImage(cgImage: croppedCG, scale: imgScale, orientation: .up)
    }

    // MARK: - Orientation

    /// Re-draw the image with `.up` orientation so CGImage pixel layout matches display.
    private func normalizeOrientation(_ img: UIImage) -> UIImage {
        guard img.imageOrientation != .up else { return img }
        UIGraphicsBeginImageContextWithOptions(img.size, false, img.scale)
        img.draw(in: CGRect(origin: .zero, size: img.size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext() ?? img
        UIGraphicsEndImageContext()
        return normalized
    }
}

// MARK: - Crop Overlay

private struct CropOverlay: View {
    let cropSide: CGFloat

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .reverseMask {
                    RoundedRectangle(cornerRadius: 2)
                        .frame(width: cropSide, height: cropSide)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                        .frame(width: cropSide, height: cropSide)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
        }
    }
}

// MARK: - Reverse Mask

private extension View {
    func reverseMask<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .center) {
                    content()
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}
