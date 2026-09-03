import SwiftUI

/// The two ornaments modelled for the welcome cards. Shapes and lighting live
/// in `WelcomeIcons.metal`; these supply the clock.
///
/// Rocking rather than spinning, like the rest of the set — a folder turning
/// edge-on is a rectangle and a record turning edge-on is a line.

/// "How It Works" — a folder with a record rising out of it.
struct FolderRecordIcon: View {
    var side: CGFloat = 80
    var period: Double = 11

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Rectangle()
                .fill(.white)
                .frame(width: side, height: side)
                .colorEffect(
                    ShaderLibrary.welcomeFolder(
                        .float2(side, side),
                        .float(2 * .pi * elapsed / period)
                    )
                )
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// "All Set" — the album it arrives as.
struct RecordIcon: View {
    var side: CGFloat = 80
    var period: Double = 13

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Rectangle()
                .fill(.white)
                .frame(width: side, height: side)
                .colorEffect(
                    ShaderLibrary.welcomeRecord(
                        .float2(side, side),
                        .float(2 * .pi * elapsed / period)
                    )
                )
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Which object a welcome card shows.
///
/// Two of the four are ornaments the app already owns rather than new models:
/// the plasma orb is Addit's own mark, which is what "welcome" wants, and the
/// chrome chain is already the app's mark for a share link. Modelling
/// substitutes for either would have put two different objects in the app
/// meaning the same thing.
enum WelcomeOrnament {
    case orb
    case folderRecord
    case chain
    case record
}

struct WelcomeOrnamentView: View {
    let ornament: WelcomeOrnament
    var side: CGFloat = 80

    var body: some View {
        switch ornament {
        case .orb: SpinningPlasmaOrb(diameter: side)
        case .folderRecord: FolderRecordIcon(side: side)
        case .chain: ChainIcon(side: side)
        case .record: RecordIcon(side: side)
        }
    }
}
