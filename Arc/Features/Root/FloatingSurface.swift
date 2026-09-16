import SwiftUI

/// A tab that floats over the globe.
///
/// My Trips was built this way first (docs/superpowers/specs/2026-09-15-floating-trips-design.md)
/// and Friends joins it (docs/superpowers/specs/2026-09-16-friends-floating-design.md),
/// so the geometry and the motion live here once: the map behind everything,
/// the cards in a fixed-frame list revealed by a bottom-anchored mask, the
/// row of round glass buttons that rides the stack's edge, the draggable
/// detail panel, the travelling card and the top row on the map.
///
/// Everything a tab differs in is passed in: its title and the flights the
/// top row speaks for, its cards, an optional row between the cards and the
/// buttons (Friends' chips), the bell, the panel's content, and the camera
/// hooks. Nothing in here knows about journeys, invites or friends.
struct FloatingSurface<Map: View, Content: View, ExtraRow: View, Panel: View, Hero: View, MenuExtras: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: The top row

    /// The centre pill's title while no live readout is showing.
    let title: String
    /// The flight the pill reads speed and altitude from, once its glide has
    /// landed; nil leaves the title.
    let liveFlight: Flight?
    /// The flight the share button offers. Nil is no share button at all
    /// (Friends shares nothing).
    let shareFlight: Flight?
    /// Items at the top of the "..." menu, above map style and weather.
    @ViewBuilder var menuExtras: () -> MenuExtras
    let controller: MapController

    // MARK: The map

    /// Built once behind the tabs and handed in, so switching tabs keeps the
    /// same view of the world.
    let map: Map

    // MARK: The cards

    /// Folded, the stack shows one card over the hidden list; unfolded, the
    /// list shows and scrolls.
    let folded: Bool
    /// The stack's own motion. Only leaf modifiers here read `liveRise`.
    let motion: JourneyStackMotion
    /// Everything above the stack in the folded overlay, with its gap.
    let chromeHeight: CGFloat
    /// Every card's height together: how tall an unfolded list grows.
    let contentHeight: CGFloat
    /// How many cards the stack is showing right now — journeys, invites or
    /// friends' flights. One card folded has nothing to unfold to.
    let stackCount: Int
    let foldIdentifier: String
    let onFold: (Bool) -> Void
    /// The tab's list and stack, built for the live layout (its top spacer
    /// comes from there).
    @ViewBuilder var content: (MyTripsLayout) -> Content

    // MARK: The row between the cards and the buttons

    /// Friends' chip row; 0 on My Trips, where nothing sits there and the
    /// buttons keep their place exactly.
    let extraRowHeight: CGFloat
    @ViewBuilder var extraRow: () -> ExtraRow

    // MARK: The buttons above the cards

    /// The bell that swaps the stack to what is waiting behind it; nil when
    /// there is nothing to answer.
    let bell: FloatingSurfaceBell?
    let showsRecenter: Bool
    let onRecenter: () -> Void

    // MARK: The detail panel

    /// The panel's settled top edge; nil opens it at its opening height.
    @Binding var panelTop: CGFloat?
    let panelHeaderHeight: CGFloat
    let onPanelRecenter: (() -> Void)?
    /// The open detail. Built only while one is open (`transition.detailOpen`)
    /// — or always, for a standing panel.
    @ViewBuilder var panel: () -> Panel
    /// The panel stands on its own, with no cards and no buttons under it:
    /// Friends' intro and profile setup before signing in. It is simply
    /// there, draggable, never gliding in or out.
    var standingPanel = false

    // MARK: The glide

    let transition: FloatingSurfaceTransition
    /// The travelling copy of the tapped card. Handed the panel's current top
    /// edge, for where the card aims before the panel has reported its header.
    @ViewBuilder var heroOverlay: (CGFloat) -> Hero

    // MARK: The root's share of the surface

    /// The last measured layout, kept by the root for its camera work.
    @Binding var measuredLayout: MyTripsLayout?
    /// A sheet is up over the tab: everything floating drops out of the way.
    let coveredBySheet: Bool
    let hooks: FloatingSurfaceHooks

    /// The folded overlay's height: what sits above the stack plus the
    /// current card at rest. Changes once per settle, not per frame.
    private var foldedHeight: CGFloat { chromeHeight + motion.settledHeight }

    /// The stack has reported its height and the list its content: before
    /// that, the buttons would sit in the wrong place for a frame.
    private var measured: Bool { motion.settledHeight > 0 && contentHeight > 0 }

    /// The list's side of the glide, on this surface only.
    private var listProgress: Double { transition.active ? transition.progress.wrappedValue : 0 }

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            // Nothing sits between the cards and the tab bar any more, so the
            // bottom inset IS the bar's reach — no guessing, nothing to learn.
            let live = MyTripsLayout(size: full, safeTop: insets.top, tabBarClearance: insets.bottom,
                                     extraRowHeight: extraRowHeight)
            layers(live)
                .frame(width: full.width, height: full.height, alignment: .topLeading)
                .offset(x: -insets.leading, y: -insets.top)
                .onChange(of: live, initial: true) { _, new in measuredLayout = new }
                .onChange(of: panelHeaderHeight) { _, header in
                    if let top = panelTop { panelTop = live.clampPanelTop(top, headerHeight: header) }
                }
        }
        .modifier(FloatingSurfaceHooksModifier(hooks: hooks,
                                               firstFrameReady: measuredLayout != nil && foldedHeight > 0))
    }

    @ViewBuilder
    private func layers(_ layout: MyTripsLayout) -> some View {
        let listTop = layout.listTop(folded: folded, foldedHeight: foldedHeight, contentHeight: contentHeight)
        ZStack(alignment: .topLeading) {
            map
            if !standingPanel {
                list(layout, listTop: listTop)
                // Gone while a detail is settled open: hidden and faded, its
                // buttons were still VoiceOver stops. Rebuilt as a close
                // begins, at the list's ~0 presence, so it still fades back in.
                if !(transition.detailOpen && transition.phase == .detail) {
                    buttonRow(layout, listTop: listTop)
                }
            }
            if transition.detailOpen || standingPanel {
                panelLayer(layout)
            }
            if transition.active {
                heroOverlay(panelTop ?? layout.panelOpeningTop(headerHeight: panelHeaderHeight))
            }
            MapTopBar(layout: layout, controller: controller, title: title,
                      liveFlight: liveFlight, shareFlight: shareFlight, menuExtras: menuExtras)
        }
        .environment(\.heroFrames, transition.frames)
        .environment(\.heroTravelling, transition.active ? transition.travellingKey : nil)
        .modifier(TripTransitionDriver(request: transition.active ? transition.request : nil,
                                       progress: transition.progress,
                                       prepare: transition.prepare,
                                       finish: transition.finish))
    }

    /// A fixed frame from the unfolded top to the bottom edge, revealed by a
    /// mask whose top edge is the only thing a fold or a swipe moves: render
    /// properties, never the scroll view's layout.
    private func list(_ layout: MyTripsLayout, listTop: CGFloat) -> some View {
        content(layout)
            // The rim's slack below the bottom edge, inside the frame, so the
            // bottom card's glass is never clipped.
            .frame(width: layout.size.width,
                   height: layout.listBottom - layout.unfoldedListTop + MyTripsLayout.rim, alignment: .top)
            .modifier(FloatingListReveal(motion: motion, visibleHeight: layout.listBottom - listTop,
                                         foldedHeight: foldedHeight,
                                         room: layout.listBottom - layout.unfoldedListTop))
            .offset(y: layout.unfoldedListTop)
            .modifier(SidePresence(side: .list, progress: listProgress))
            .modifier(UntilMeasured(measured: measured))
            .allowsHitTesting(!transition.detailOpen)
            // Hides, never un-hides: an explicit `false` out here would
            // outrank the list's and the stack's own hides.
            .accessibilityHidden(true, isEnabled: transition.detailOpen)
            .offset(y: coveredBySheet ? 1500 : 0)
            .animation(reduceMotion ? nil : .spring(duration: 0.45), value: coveredBySheet)
    }

    /// The fold toggle, the bell and recenter — and, under them, whatever the
    /// tab keeps directly above its cards. Both ride the stack's edge
    /// together, so a swipe moves them as one.
    private func buttonRow(_ layout: MyTripsLayout, listTop: CGFloat) -> some View {
        // The layout leaves room for the extra row, above the cards and
        // below the top row, however far the list unfolds.
        ZStack(alignment: .topLeading) {
            if extraRowHeight > 0 {
                extraRow()
                    .frame(width: layout.size.width, height: extraRowHeight)
                    .offset(y: layout.extraRowY(listTop: listTop))
            }
            buttons
                .frame(width: layout.size.width, height: MyTripsLayout.control)
                .offset(y: layout.pillRowY(listTop: listTop))
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .modifier(RidesStackEdge(motion: motion,
                                 clamp: (foldedHeight, layout.listBottom - layout.unfoldedListTop)))
        .modifier(SidePresence(side: .list, progress: listProgress))
        .modifier(UntilMeasured(measured: measured))
        .allowsHitTesting(!transition.detailOpen)
        .accessibilityHidden(transition.detailOpen)
        .offset(y: coveredBySheet ? 1500 : 0)
        .animation(reduceMotion ? nil : .spring(duration: 0.45), value: coveredBySheet)
    }

    private var buttons: some View {
        // Unfolded, the toggle is the only way back: it stays even where the
        // stack it belongs to has a single card (one invite behind the bell).
        let foldable = !folded || stackCount > 1
        return HStack {
            if foldable {
                Button {
                    // A turn later, not inside the tap: the button's press
                    // release animates its label in the tap's own update, so a
                    // fold started there slid the pill on that animation, over
                    // the first card and past the stack's edge, even with
                    // Reduce Motion on. Out of it, the pill rides the fold.
                    let target = !folded
                    DispatchQueue.main.async { onFold(target) }
                } label: {
                    Text(folded ? "Show More" : "Show Less")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.interpolate)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(foldIdentifier)
            }
            Spacer()
            HStack(spacing: 10) {
                if let bell { bellButton(bell) }
                if showsRecenter {
                    RecenterButton(action: onRecenter)
                }
            }
        }
        .padding(.horizontal, MyTripsLayout.margin)
    }

    /// The bell, immediately left of the recenter button and only there while
    /// something is waiting: it swaps the stack to those cards and back. A red
    /// dot rides it while any of them hasn't been on screen yet; the dot
    /// itself is decoration, and the count is in the bell's value so
    /// VoiceOver says it.
    private func bellButton(_ bell: FloatingSurfaceBell) -> some View {
        Button {
            // A turn later, like Show More: the button's press release
            // animates its label in the tap's own update, and a swap started
            // inside it would ride that animation instead of the fold's.
            DispatchQueue.main.async { bell.action() }
        } label: {
            Image(systemName: bell.showing ? "xmark" : "bell.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: MyTripsLayout.control, height: MyTripsLayout.control)
                // An icon button's hit area is the GLYPH's own shape, not the
                // circle it sits in: without this, taps inside the glass —
                // between the bell's strokes — did nothing at all.
                .contentShape(.rect)
                .glassEffect(.regular.interactive(), in: .circle)
                .overlay(alignment: .topTrailing) {
                    if !bell.showing, bell.unread > 0 {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(bell.identifier)
        .accessibilityLabel(bell.label)
        .accessibilityValue(!bell.showing && bell.unread > 0 ? "\(bell.unread) unread" : "")
    }

    private func panelLayer(_ layout: MyTripsLayout) -> some View {
        let settled = Binding<CGFloat>(get: { panelTop ?? layout.panelOpeningTop(headerHeight: panelHeaderHeight) },
                                       set: { panelTop = $0 })
        return FloatingPanel(layout: layout, headerHeight: panelHeaderHeight, top: settled,
                             onRecenter: onPanelRecenter, content: panel)
            .frame(width: layout.size.width, height: layout.panelBottom - layout.panelHighestTop, alignment: .top)
            .offset(y: layout.panelHighestTop)
            // A fading panel takes no touches: Terminal map or My plane tapped
            // just after the X would start a ground view for a closing detail.
            .allowsHitTesting(standingPanel || transition.phase != .closing)
            .modifier(PanelPresence(progress: standingPanel ? 1 : transition.progress.wrappedValue))
            .offset(y: coveredBySheet ? 1500 : 0)
    }
}

/// The bell above the cards: what it is showing, how much of it is unread,
/// and the swap it performs. The surface draws it; the tab owns the meaning.
struct FloatingSurfaceBell {
    /// The bell's own cards are the ones in the stack — so the bell is an X
    /// that swaps back.
    let showing: Bool
    let unread: Int
    let identifier: String
    let label: String
    let action: () -> Void
}

/// The root's glide state, handed to whichever surface is on screen. The
/// transition itself belongs to the root: both tabs share one open detail.
struct FloatingSurfaceTransition {
    /// This tab is on screen and owns the detail (open, opening or closing).
    let active: Bool
    /// ...and a detail really is open on it.
    let detailOpen: Bool
    let phase: TripTransition.Phase
    let request: TripTransition.Request?
    let progress: Binding<Double>
    let frames: HeroFrames
    let travellingKey: String?
    let prepare: (UUID) -> Void
    let finish: (UUID) -> Void
}

/// What the surface watches on the tab's behalf. `onFirstFrame` fires once:
/// one camera move at launch, not one per measurement.
struct FloatingSurfaceHooks {
    /// The cards the tab has in total (journeys, friends' flights).
    let itemCount: Int
    let onItemCount: (Int) -> Void
    /// What is waiting behind the bell, by id: for the read store's pruning
    /// and the auto-return when the last one is answered.
    let bellItems: [String]
    let onBellItems: ([String]) -> Void
    let detailID: UUID?
    let onDetailSettled: () async -> Void
    let onFirstFrame: () -> Void
}

/// Kept out of the surface's builders, which sit at the type checker's limit.
private struct FloatingSurfaceHooksModifier: ViewModifier {
    let hooks: FloatingSurfaceHooks
    /// The layout exists and the folded stack has reported its height.
    let firstFrameReady: Bool

    @State private var framed = false

    func body(content: Content) -> some View {
        content
            .onChange(of: hooks.itemCount) { _, count in hooks.onItemCount(count) }
            .onChange(of: hooks.bellItems) { _, ids in hooks.onBellItems(ids) }
            .task(id: hooks.detailID) {
                guard hooks.detailID != nil else { return }
                await hooks.onDetailSettled()
            }
            .onChange(of: firstFrameReady, initial: true) { _, ready in
                guard ready, !framed else { return }
                framed = true
                hooks.onFirstFrame()
            }
    }
}

/// The list's mask and hit area, opening from the bottom: its top edge sits
/// at `listTop` plus whatever the stack's live rise adds mid-swipe, with the
/// rim's slack above and below. Reads `liveRise` here, in a leaf, so a swipe
/// never re-evaluates the surface. The shape keeps the map above pannable and
/// the tab bar below tappable.
private struct FloatingListReveal: ViewModifier {
    let motion: JourneyStackMotion
    /// `listBottom - listTop`, at rest.
    let visibleHeight: CGFloat
    /// The folded height at rest, and the most the list can show: the mask
    /// opens no further than the top row, as the list itself stops there.
    let foldedHeight: CGFloat
    let room: CGFloat
    func body(content: Content) -> some View {
        let rise = JourneyStackPaging.edgeRise(liveRise: motion.liveRise, restHeight: foldedHeight, room: room)
        let h = max(0, visibleHeight + rise + 2 * MyTripsLayout.rim)
        content
            .mask(alignment: .bottom) { Rectangle().frame(height: h) }
            .contentShape(.interaction, BottomSlice(height: h))
    }
}

/// Hidden until the folded stack has reported its height: before that the
/// buttons sit in the wrong place for a frame. Appears at once, never fades.
private struct UntilMeasured: ViewModifier {
    let measured: Bool
    func body(content: Content) -> some View {
        content
            .opacity(measured ? 1 : 0)
            .animation(nil, value: measured)
    }
}

// MARK: - The tab's list

/// Where a floating list's cards sit in its content, for the unfold's scroll.
/// Written by layout, read by one action: not observed, so no measurement
/// re-evaluates the view. Each tab's list keeps one (`MyFlightsView`,
/// `FriendsFloatingList`).
@MainActor
final class FloatingListGeometry {
    /// Each card's bottom (rim included), in content coordinates, by row key
    /// — a journey's id as a string, an invite's id, a friend's flight's.
    var cardBottoms: [String: CGFloat] = [:]
    /// The same bottoms as the list shows them, scroll included.
    var shownBottoms: [String: CGFloat] = [:]
    var content: CGFloat = 0
    var viewport: CGFloat = 0

    /// What the unfold scrolls to before the mask moves: the list's top, its
    /// bottom, or the card itself on the frame's bottom edge.
    enum UnfoldScroll {
        case top, bottom, card
    }

    /// Unfolding: where to scroll the still-hidden list so the card `key`
    /// sits where the stack shows it, and how far below that the list starts
    /// where the scroll can't reach (too little above it, or below it) — it
    /// rises into place with the fold. Nil until the card and the frame have
    /// been measured.
    func unfoldPlacement(for key: String, topSpacer: CGFloat) -> (scroll: UnfoldScroll, shift: CGFloat)? {
        guard let measured = cardBottoms[key], viewport > 0 else { return nil }
        // Content coordinates start below the top margin.
        let bottom = measured + topSpacer
        let desired = bottom - viewport
        let reach = max(0, content + topSpacer - viewport)
        let actual = min(max(desired, 0), reach)
        let scroll: UnfoldScroll = desired <= 0 ? .top : desired >= reach ? .bottom : .card
        return (scroll, actual - desired)
    }

    /// How far the list must move for the card `key` to land where the stack
    /// shows it, as the fold closes. Clamped to one viewport, for a card
    /// scrolled far out of view.
    func foldShift(for key: String) -> CGFloat {
        guard viewport > 0, let bottom = shownBottoms[key] else { return 0 }
        return min(max(viewport - bottom, -viewport), viewport)
    }
}

/// A row of an unfolded list: the rim under it, its scroll id, and the two
/// measurements the fold's hand-off needs. One shape for every kind of card,
/// so an unfold lines any of them up with the stack it came from.
struct FloatingListRow: ViewModifier {
    let key: String
    let geometry: FloatingListGeometry
    nonisolated static let contentSpace = "floating-list-content"
    nonisolated static let viewportSpace = "floating-list-viewport"

    func body(content: Content) -> some View {
        content
            .padding(.bottom, MyTripsLayout.rim)
            .id(key)
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named(Self.contentSpace)).maxY
            } action: { geometry.cardBottoms[key] = $0 }
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named(Self.viewportSpace)).maxY
            } action: { geometry.shownBottoms[key] = $0 }
    }
}

/// The list's rise on unfold when its scroll can't hold the current card in
/// place: `shift` below at the fold's start, home when it ends, on the same
/// spring as the mask. Folding runs it backwards, the list sinking by the
/// shift that lands its card on the stack. The folded overlay (`overlay`)
/// rides the same travel from the other end: home while folded.
struct UnfoldRise: ViewModifier, Animatable {
    var progress: CGFloat
    let shift: CGFloat
    var overlay = false
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        content.offset(y: overlay ? -shift * p : shift * (1 - p))
    }
}
