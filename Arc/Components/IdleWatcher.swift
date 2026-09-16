import SwiftUI
import UIKit

/// "How long since the user last touched anything", app-wide.
///
/// A window-level gesture recogniser rather than SwiftUI gestures: the map is
/// a UIKit view and swallows its own pans, so a `simultaneousGesture` in the
/// view tree would miss exactly the interaction (panning the globe) that most
/// clearly means the user is busy. It never consumes or delays touches —
/// `gestureRecognizerShouldBegin` returns false, so the recogniser stays in
/// `.possible` forever and only its delegate's `shouldReceive` is used, as a
/// report that a finger came down somewhere in the window.
@MainActor @Observable
final class IdleWatcher {
    static let shared = IdleWatcher()

    /// Bumped on every touch anywhere; observers restart their timers on it.
    private(set) var lastTouch = Date.now

    @ObservationIgnored private var recogniser: UIGestureRecognizer?
    /// A gesture holds its target and delegate weakly; this is their owner.
    @ObservationIgnored private var target: Target?

    /// Attaches to the key window, once. Safe to call again: a scene that was
    /// rebuilt (its window gone) gets a new recogniser.
    func start() {
        if let recogniser, recogniser.view != nil { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }
        let target = Target { [weak self] in self?.lastTouch = .now }
        let gesture = UIPanGestureRecognizer(target: target, action: #selector(Target.touched))
        gesture.minimumNumberOfTouches = 1
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = target
        window.addGestureRecognizer(gesture)
        self.target = target
        recogniser = gesture
    }

    private final class Target: NSObject, UIGestureRecognizerDelegate {
        let onTouch: () -> Void
        init(onTouch: @escaping () -> Void) { self.onTouch = onTouch }
        @objc func touched() { onTouch() }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// Every touch that reaches the window passes through here.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool { onTouch(); return true }

        /// Never begins, so it can neither consume a touch nor make another
        /// recogniser wait for it.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { false }
    }
}
