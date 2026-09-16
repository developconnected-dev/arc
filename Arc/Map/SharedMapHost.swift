import SwiftUI
import UIKit

/// The one map behind every tab.
///
/// iOS gives a `TabView` opaque tab backgrounds that SwiftUI can't clear
/// (`containerBackground(for: .tabView)` is unavailable on iOS), so the map
/// used to be built inside each tab — and every tab got a map view of its
/// own. A tab switch then cut between two different maps: their own cameras,
/// their own routes re-added a beat late, and on a tab's first visit a map
/// that hadn't drawn a single tile. On the phone that read as the whole
/// screen flashing. Moving one map view between the tabs doesn't work
/// either: MapKit drops every tile it has drawn whenever its view changes
/// superview.
///
/// So the map is built once and never moves: it sits in the window, beneath
/// the whole app. Each tab keeps a `MapSlot` where its map used to be, which
/// clears the backgrounds between itself and the window (so the map shows
/// through) and hands every touch that reaches it to the map (so the map
/// still pans, under everything the tab puts over it). A tab switch changes
/// what lies over the map, never the map.
@MainActor
final class SharedMapHost {
    private let hosting = UIHostingController(rootView: AnyView(EmptyView()))

    init() {
        hosting.view.backgroundColor = .clear
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    var mapView: UIView { hosting.view }

    /// The map's content, from the root's latest pass.
    func update(_ content: AnyView) {
        hosting.rootView = content
    }

    /// Under everything in `window`, once.
    func attach(to window: UIWindow) {
        guard mapView.superview !== window else { return }
        mapView.frame = window.bounds
        window.insertSubview(mapView, at: 0)
    }
}

/// A tab's window onto the shared map.
final class MapSlotView: UIView {
    weak var host: SharedMapHost?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }
        host?.attach(to: window)
        clearAncestors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clearAncestors()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        clearAncestors()
    }

    /// The tab's hosting view, the tab controller's containers and the app's
    /// root all paint a background; the map is behind all of them.
    private func clearAncestors() {
        var view = superview
        while let current = view, !(current is UIWindow) {
            if current.backgroundColor != .clear { current.backgroundColor = .clear }
            current.isOpaque = false
            view = current.superview
        }
    }

    /// Whatever the tab leaves uncovered here is the map's: the touch goes
    /// to the map, wherever in the window it lives.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let map = host?.mapView, map.window != nil, map.window === window,
              self.point(inside: point, with: event) else { return nil }
        return map.hitTest(convert(point, to: map), with: event)
    }
}

/// Where a tab's map goes (`SharedMapHost`). Every slot passes the root's
/// latest map content on; they are the same value.
struct MapSlot<Content: View>: UIViewRepresentable {
    let host: SharedMapHost
    let content: Content

    func makeUIView(context: Context) -> MapSlotView {
        let view = MapSlotView()
        view.backgroundColor = .clear
        view.host = host
        host.update(AnyView(content))
        return view
    }

    func updateUIView(_ view: MapSlotView, context: Context) {
        host.update(AnyView(content))
    }
}
