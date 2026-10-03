import QuartzCore
import SwiftUI

extension TimelineSchedule where Self == AnimationTimelineSchedule {
    /// Every frame, but never more than 60 a second.
    ///
    /// The app opts into ProMotion's 120 Hz (`CADisableMinimumFrameDurationOnPhone`
    /// in Info.plist) for motion that answers a touch — a folder opening, a card
    /// following the finger, the grid making room for it — which at 60 read as
    /// choppy beside scroll views running at 120. A timeline on its own clock is
    /// another matter: it runs for as long as it's on screen, and most of these
    /// drive a shader — a raymarch, the launch screen's full-screen field. At 120
    /// each would cost twice what it does, for motion already smooth at 60,
    /// which is what every one of them ran at before the opt-in. So they keep it.
    static var sixtyHertz: AnimationTimelineSchedule {
        .animation(minimumInterval: 1.0 / 60.0)
    }

    static func sixtyHertz(paused: Bool) -> AnimationTimelineSchedule {
        .animation(minimumInterval: 1.0 / 60.0, paused: paused)
    }
}

extension CAFrameRateRange {
    /// A display link's 60 a second, kept since the app opted into 120
    /// (see `TimelineSchedule.sixtyHertz`): before that, every link the app
    /// ran got 60 without asking, and some count frames rather than time — a
    /// link left at its default now runs twice as often, and anything paced
    /// per tick, twice as fast.
    static let sixtyHertz = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
}
