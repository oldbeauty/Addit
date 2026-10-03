import Foundation

/// Whether the device is in Low Power Mode, as something a view can read.
///
/// A UI-lifecycle singleton rather than an injected service, for the same
/// reason `MotionShine` is one: it holds no app state, it's a tap on a system
/// signal. Views read `PowerState.shared.isLowPower` in `body` and `@Observable`
/// does the rest — the flag changes at most a handful of times in a session.
///
/// What it's for: Low Power Mode caps the display at 60 Hz *and* drops the CPU
/// and GPU clocks, so per-frame work that fits comfortably at full speed can
/// stop fitting.
///
/// `GlassRim`'s travelling specular consults it, and the line between that and
/// everything else is *how many of them are on screen*. One rim is nothing; a
/// library of folders is a dozen, all redrawing together on every gyro tick,
/// which is the cost worth dropping when the clocks come down. The
/// toolbar ornaments deliberately keep moving: there are two of them, they're
/// the app's signature, and `ScrollOffsetBox` already made them cheap enough
/// that Low Power Mode isn't the place to take them away.
@Observable
final class PowerState {
    static let shared = PowerState()

    private(set) var isLowPower: Bool

    private init() {
        isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        // `.main` queue rather than the default: this drives view invalidation,
        // and the notification is posted on an arbitrary thread.
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.isLowPowerModeEnabled
                if now != self?.isLowPower { self?.isLowPower = now }
            }
        }
    }
}
