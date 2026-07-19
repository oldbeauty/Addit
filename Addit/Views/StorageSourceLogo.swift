import SwiftUI

/// Compact brand mark for a storage source — the library selector's collapsed
/// label shows this instead of a text title. Google Drive and OneDrive use the
/// official product marks bundled in the asset catalog, cropped edge-to-edge,
/// so constraining height alone yields the mark's true width; local storage
/// stays a tinted SF Symbol. Heights are tuned per mark for visual balance in
/// the selector capsule (the wide OneDrive cloud reads bigger than its box).
struct StorageSourceLogo: View {
    let source: StorageSource

    var body: some View {
        switch source {
        case .googleDrive:
            Image("GoogleDriveLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 17)
        case .oneDrive:
            Image("OneDriveLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 14)
        case .localStorage:
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }
}
