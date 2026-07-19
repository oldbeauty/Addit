import SwiftUI
import UIKit

/// Replaces the stock UINavigationController push/pop animation (incoming page
/// sliding *on top* of the outgoing one, which only creeps ~30% left under a
/// dimming shadow — a depth/stacking illusion) with a flat lateral slide: both
/// pages travel full-width in tandem, so navigating reads as panning between
/// adjacent regions of one continuous surface. Sheet presentations
/// (NowPlayingView etc.) are untouched — this only hooks push/pop.
///
/// SwiftUI has no public API for custom NavigationStack push transitions, so
/// this introspects the backing UINavigationController and installs a
/// transition delegate. The system interactive-pop gesture can't drive custom
/// animators, so an equivalent edge-swipe is re-created with a
/// percent-driven transition.
///
/// Usage: attach `.flatSlideNavigation()` to the *root content* of a
/// NavigationStack (it must sit inside the stack to find its nav controller).
extension View {
    func flatSlideNavigation() -> some View {
        background(FlatSlideIntrospector())
    }
}

// MARK: - Introspection

private struct FlatSlideIntrospector: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> FlatSlideProbeViewController {
        FlatSlideProbeViewController()
    }

    func updateUIViewController(_ controller: FlatSlideProbeViewController, context: Context) {
        controller.installIfNeeded()
    }
}

/// Invisible child controller whose only job is to reach the enclosing
/// UINavigationController once it lands in the hierarchy.
final class FlatSlideProbeViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        installIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installIfNeeded()
    }

    func installIfNeeded() {
        guard let nav = navigationController else { return }
        FlatSlideCoordinator.install(on: nav)
    }
}

// MARK: - Coordinator (delegate + edge-swipe)

private var flatSlideCoordinatorKey: UInt8 = 0

final class FlatSlideCoordinator: NSObject, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
    private weak var navigationController: UINavigationController?
    /// SwiftUI's internal delegate — it syncs the NavigationStack path with
    /// UIKit's transitions, so every callback we don't consume must still
    /// reach it (see forwarding overrides below).
    private weak var originalDelegate: UINavigationControllerDelegate?
    private var interactionController: UIPercentDrivenInteractiveTransition?

    /// Idempotent: retained via associated object on the nav controller, so
    /// multiple screens in the same stack calling `.flatSlideNavigation()`
    /// share one coordinator. Re-asserts delegate ownership on every call —
    /// SwiftUI may re-stamp the delegate during updates, which would silently
    /// restore the stock stacking transition.
    static func install(on nav: UINavigationController) {
        _ = flatSlideSwizzlesInstalled
        if let existing = objc_getAssociatedObject(nav, &flatSlideCoordinatorKey) as? FlatSlideCoordinator {
            existing.reassertDelegateIfNeeded()
            return
        }
        let coordinator = FlatSlideCoordinator(navigationController: nav)
        objc_setAssociatedObject(nav, &flatSlideCoordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func reassertDelegateIfNeeded() {
        guard let nav = navigationController, nav.delegate !== self else { return }
        originalDelegate = nav.delegate
        nav.delegate = self
    }

    private init(navigationController nav: UINavigationController) {
        self.navigationController = nav
        self.originalDelegate = nav.delegate
        super.init()
        nav.delegate = self

        // The system interactive-pop recognizer bypasses custom animators and
        // glitches when one is installed; replace it with our own edge pan
        // driving a percent transition through the same flat-slide animator.
        nav.interactivePopGestureRecognizer?.isEnabled = false
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        edge.edges = .left
        edge.delegate = self
        nav.view.addGestureRecognizer(edge)
    }

    // MARK: Delegate forwarding

    // Everything not implemented here flows through to SwiftUI's original
    // delegate untouched — breaking that link desyncs the NavigationStack path.
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original = originalDelegate, original.responds(to: aSelector) {
            return original
        }
        return super.forwardingTarget(for: aSelector)
    }

    // MARK: Transitions

    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        guard operation != .none else { return nil }
        return FlatSlideAnimator(operation: operation)
    }

    func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning
    ) -> (any UIViewControllerInteractiveTransitioning)? {
        interactionController
    }

    // MARK: Edge swipe → percent-driven pop

    @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard let nav = navigationController, let view = nav.view else { return }
        let progress = max(0, min(1, gesture.translation(in: view).x / view.bounds.width))

        switch gesture.state {
        case .began:
            guard nav.viewControllers.count > 1, interactionController == nil else { return }
            let controller = UIPercentDrivenInteractiveTransition()
            controller.completionCurve = .easeOut
            interactionController = controller
            nav.popViewController(animated: true)
        case .changed:
            interactionController?.update(progress)
        case .ended, .cancelled:
            let flungBack = gesture.velocity(in: view).x > 500
            if gesture.state == .ended && (progress > 0.35 || flungBack) {
                interactionController?.finish()
            } else {
                interactionController?.cancel()
            }
            interactionController = nil
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = navigationController else { return false }
        return nav.viewControllers.count > 1
            && nav.transitionCoordinator == nil
            && interactionController == nil
    }
}

// MARK: - Forcing animated transitions

/// SwiftUI's NavigationStack drives path-change pushes through
/// UINavigationController with `animated: false` and runs its *own* transition
/// animation at the SwiftUI layer — an animation that dies when the navigation
/// delegate is replaced, leaving pushes instant. (Pops from the back button or
/// edge swipe go through UIKit with `animated: true`, which is why only pushes
/// broke.) The fix — same one swiftui-navigation-transitions uses — is to
/// swizzle the stack-mutation methods and force `animated: true`, routing the
/// transition through UIKit's machinery and therefore our animator. Scoped:
/// only navigation controllers carrying a FlatSlideCoordinator are affected.
private let flatSlideSwizzlesInstalled: Void = {
    func exchange(_ original: Selector, _ swizzled: Selector) {
        guard
            let originalMethod = class_getInstanceMethod(UINavigationController.self, original),
            let swizzledMethod = class_getInstanceMethod(UINavigationController.self, swizzled)
        else {
            assertionFailure("FlatSlideNavigation: failed to swizzle \(original)")
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
    exchange(#selector(UINavigationController.pushViewController(_:animated:)),
             #selector(UINavigationController.flatSlide_pushViewController(_:animated:)))
    exchange(#selector(UINavigationController.setViewControllers(_:animated:)),
             #selector(UINavigationController.flatSlide_setViewControllers(_:animated:)))
    exchange(#selector(UINavigationController.popViewController(animated:)),
             #selector(UINavigationController.flatSlide_popViewController(animated:)))
    exchange(#selector(UINavigationController.popToViewController(_:animated:)),
             #selector(UINavigationController.flatSlide_popToViewController(_:animated:)))
    exchange(#selector(UINavigationController.popToRootViewController(animated:)),
             #selector(UINavigationController.flatSlide_popToRootViewController(animated:)))
}()

extension UINavigationController {
    /// Only force animation for on-screen stacks that opted into flat-slide.
    fileprivate var flatSlideForcesAnimation: Bool {
        objc_getAssociatedObject(self, &flatSlideCoordinatorKey) != nil
            && viewIfLoaded?.window != nil
    }

    // NOTE: bodies calling their own selector are not recursion — after
    // method_exchangeImplementations that call lands on UIKit's original.

    @objc fileprivate func flatSlide_pushViewController(_ viewController: UIViewController, animated: Bool) {
        flatSlide_pushViewController(viewController, animated: animated || flatSlideForcesAnimation)
    }

    @objc fileprivate func flatSlide_setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        // SwiftUI calls this on plain body updates too; only a change of the
        // top controller on an already-populated stack is a real navigation.
        let isNavigation = !self.viewControllers.isEmpty
            && viewControllers.last !== self.viewControllers.last
        flatSlide_setViewControllers(viewControllers, animated: animated || (isNavigation && flatSlideForcesAnimation))
    }

    @objc fileprivate func flatSlide_popViewController(animated: Bool) -> UIViewController? {
        flatSlide_popViewController(animated: animated || flatSlideForcesAnimation)
    }

    @objc fileprivate func flatSlide_popToViewController(_ viewController: UIViewController, animated: Bool) -> [UIViewController]? {
        flatSlide_popToViewController(viewController, animated: animated || flatSlideForcesAnimation)
    }

    @objc fileprivate func flatSlide_popToRootViewController(animated: Bool) -> [UIViewController]? {
        flatSlide_popToRootViewController(animated: animated || flatSlideForcesAnimation)
    }
}

// MARK: - Animator

/// Both views translate a full container-width in lockstep — outgoing exits
/// completely as incoming enters, no parallax, no dimming, no shadow.
final class FlatSlideAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let operation: UINavigationController.Operation
    private var propertyAnimator: UIViewPropertyAnimator?

    init(operation: UINavigationController.Operation) {
        self.operation = operation
    }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        0.2
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: context).startAnimation()
    }

    func interruptibleAnimator(
        using context: any UIViewControllerContextTransitioning
    ) -> any UIViewImplicitlyAnimating {
        if let propertyAnimator { return propertyAnimator }

        let container = context.containerView
        let width = container.bounds.width
        let push = operation == .push

        guard
            let fromView = context.view(forKey: .from),
            let toView = context.view(forKey: .to),
            let toVC = context.viewController(forKey: .to)
        else {
            // Degenerate context: complete immediately with a no-op animator.
            let animator = UIViewPropertyAnimator(duration: 0, curve: .linear) {}
            animator.addCompletion { _ in context.completeTransition(true) }
            propertyAnimator = animator
            return animator
        }

        toView.frame = context.finalFrame(for: toVC)
        container.addSubview(toView)
        // Incoming page starts one full width off to the side it enters from.
        toView.transform = CGAffineTransform(translationX: push ? width : -width, y: 0)

        // Swallow taps while pages are in flight.
        fromView.isUserInteractionEnabled = false
        toView.isUserInteractionEnabled = false

        // Linear while a finger is scrubbing so the pages track it 1:1.
        // Tap-triggered transitions use easeOut in BOTH directions — easeInOut
        // spikes to ~2x average velocity mid-flight, which made pushes read
        // way faster than pops even at identical durations. Push and pop must
        // share one duration + one curve so the two directions feel the same.
        let curve: UIView.AnimationCurve = context.isInteractive ? .linear : .easeOut
        let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), curve: curve) {
            fromView.transform = CGAffineTransform(translationX: push ? -width : width, y: 0)
            toView.transform = .identity
        }
        animator.addCompletion { _ in
            fromView.transform = .identity
            toView.transform = .identity
            fromView.isUserInteractionEnabled = true
            toView.isUserInteractionEnabled = true
            context.completeTransition(!context.transitionWasCancelled)
        }
        propertyAnimator = animator
        return animator
    }
}
