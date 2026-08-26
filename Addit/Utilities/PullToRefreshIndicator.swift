import SwiftUI
import UIKit

/// Puts the app's `LoadingIndicator` on the pull-to-refresh control.
///
/// `.refreshable` on a List is backed by a `UIRefreshControl`, and SwiftUI
/// offers no way to restyle its glyph — so pull-to-refresh was the one busy
/// state in the app still drawing a system spinner while everything else drew
/// the morphing infinity mark. This reaches the control the same way
/// `flatSlideNavigation()` reaches the navigation controller: an invisible
/// probe that introspects the UIKit hierarchy once it lands in a window.
///
/// The control itself is left in place and keeps owning the gesture, the pull
/// distance, the threshold and the release — only its spinner is hidden (by
/// clearing the tint) and the app's indicator hosted in its place. If the
/// control can't be found the system spinner simply stays, which is the whole
/// failure mode.
///
/// `isRefreshing` gates the indicator so it appears only once a pull has
/// actually triggered a refresh — a short pull that never reaches the
/// threshold shows nothing at all. Pass the same flag the `.refreshable`
/// closure sets.
///
/// Attach to the same view that carries `.refreshable`.
extension View {
    func additRefreshIndicator(tint: Color, isRefreshing: Bool) -> some View {
        background(RefreshIndicatorInstaller(tint: tint, isRefreshing: isRefreshing))
    }
}

private struct RefreshIndicatorInstaller: UIViewRepresentable {
    let tint: Color
    let isRefreshing: Bool

    func makeUIView(context: Context) -> RefreshIndicatorProbeView {
        RefreshIndicatorProbeView()
    }

    func updateUIView(_ view: RefreshIndicatorProbeView, context: Context) {
        view.tint = tint
        view.isRefreshing = isRefreshing
        view.installIfNeeded()
    }
}

/// Invisible view whose only job is to find the enclosing scroll view's
/// refresh control once both exist.
final class RefreshIndicatorProbeView: UIView {
    var tint: Color = .accentColor {
        didSet { host?.rootView = Self.indicator(tint: tint) }
    }

    /// Drives visibility. The control is on screen for the whole pull, but
    /// the indicator belongs only to the part of it that is actually a
    /// refresh — a short pull that springs back should show nothing.
    var isRefreshing: Bool = false {
        didSet { host?.view.isHidden = !isRefreshing }
    }

    private var host: UIHostingController<LoadingIndicator>?

    /// Twice the size the control's own spinner would have been.
    private static func indicator(tint: Color) -> LoadingIndicator {
        LoadingIndicator(size: .large, tint: tint)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installIfNeeded()
    }

    /// Retried here because the refresh control is created by SwiftUI on its
    /// own schedule — the probe frequently lands in the hierarchy first.
    override func layoutSubviews() {
        super.layoutSubviews()
        installIfNeeded()
    }

    func installIfNeeded() {
        guard host == nil, let control = findRefreshControl() else { return }

        // Hides the stock spinner without disturbing the control.
        control.tintColor = .clear

        // Behind the content, always. The control is a sibling of the rows
        // in the scroll view, and at rest it sits under the top of the
        // content — so without this the indicator can cross in front of the
        // cover as the list springs back. `zPosition` rather than subview
        // order because UIKit re-sorts the scroll view's subviews.
        control.layer.zPosition = -1
        control.superview?.sendSubviewToBack(control)

        let host = UIHostingController(rootView: Self.indicator(tint: tint))
        host.view.backgroundColor = .clear
        host.view.isHidden = !isRefreshing
        host.view.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: control.centerXAnchor),
            host.view.centerYAnchor.constraint(equalTo: control.centerYAnchor),
        ])
        self.host = host
    }

    /// The probe is a *sibling* of the List rather than a descendant — a
    /// SwiftUI `background` sits behind its content, not inside it — so this
    /// climbs to each ancestor in turn and searches that subtree, taking the
    /// first scroll view that actually owns a refresh control.
    private func findRefreshControl() -> UIRefreshControl? {
        var ancestor: UIView? = superview
        while let current = ancestor {
            if let found = Self.firstRefreshControl(in: current) { return found }
            ancestor = current.superview
        }
        return nil
    }

    private static func firstRefreshControl(in view: UIView) -> UIRefreshControl? {
        if let scroll = view as? UIScrollView, let control = scroll.refreshControl {
            return control
        }
        for subview in view.subviews {
            if let found = firstRefreshControl(in: subview) { return found }
        }
        return nil
    }
}
