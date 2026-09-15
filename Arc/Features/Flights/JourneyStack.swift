import SwiftUI

/// What the folded journey stack is doing right now, for the leaf modifiers
/// that must move with it (the list's mask, the Show More row, the invites
/// above the stack). Split by frequency so observation keeps per-frame work
/// out of the root: the root reads `settledHeight` (once per settle), never
/// `liveRise`.
@MainActor @Observable
final class JourneyStackMotion {
    /// The current journey's card height: the stack at rest.
    var settledHeight: CGFloat = 0
    /// How far the stack's top edge is above its resting position (negative:
    /// below). Zero at rest.
    var liveRise: CGFloat = 0

    /// Set by the stack while it is on screen.
    @ObservationIgnored fileprivate var restHandler: (() -> Void)?

    /// Brings the stack to rest in this very turn: a settle lands where it
    /// was heading, a held swipe is dropped with nothing committed, a flip
    /// still waiting for its card is abandoned. Show More calls this before
    /// it unfolds, so the list aligns to the page the stack really shows and
    /// nothing is still rising under the mask.
    func comeToRest() { restHandler?() }

    @ObservationIgnored fileprivate var restProbe: (() -> Bool)?

    /// No finger on the stack, no settle running, no flip waiting for its
    /// card. Read once, by the map's debounce, never in a body.
    var isAtRest: Bool { restProbe?() ?? true }
}

/// What sits on the stack's top edge (the invites above it, the Show More
/// row) moves with it mid-swipe. Reads `liveRise` in this leaf only, so a
/// swipe never re-evaluates the views around it.
struct RidesStackEdge: ViewModifier {
    let motion: JourneyStackMotion
    /// For what sits on the list's edge rather than the stack's own (the
    /// Show More row): the folded height at rest and the list's unfolded
    /// height, past which the edge stops under the top row. Nil rides the
    /// whole rise.
    var clamp: (restHeight: CGFloat, room: CGFloat)? = nil
    func body(content: Content) -> some View {
        let rise = clamp.map {
            JourneyStackPaging.edgeRise(liveRise: motion.liveRise, restHeight: $0.restHeight, room: $0.room)
        } ?? motion.liveRise
        content.offset(y: -rise)
    }
}

/// My Trips' folded journeys as a Smart Stack: one card at a time, swipe up
/// for the next journey and down for the previous, the frame's height
/// following the cards, a light tick when a new journey settles
/// (docs/superpowers/specs/2026-09-15-journey-stack-design.md).
///
/// Every per-frame value lives here. Cards are measured once and only moved
/// (offset, scale); the frame's live height grows from the bottom edge while
/// the layout keeps the resting card's height. A page change and the drag's
/// reset land in one non-animated transaction, where the offsets make the
/// swap pixel-identical.
struct JourneyStack: View {
    let journeys: [TripJourney]
    @Binding var page: Int
    let motion: JourneyStackMotion
    /// A flip asked for by the app (a trip just added) rather than a finger.
    var flipRequest: Int?
    var onFlipRequestHandled: () -> Void = {}
    /// The stack itself landed on another journey (a swipe, a flip the app
    /// asked for, VoiceOver's adjust) — not a clamp after the list changed.
    var onSettled: (UUID) -> Void = { _ in }
    var onSelect: (Flight) -> Void
    var onDelete: (Flight) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.heroReports) private var heroReports
    @State private var heights: [UUID: CGFloat] = [:]
    /// The last height published as settled: what the stack keeps while a
    /// page it lands on hasn't been measured, rather than collapsing.
    @State private var lastSettledHeight: CGFloat = 0
    /// Displayed translation (already rubber-banded at the ends).
    @State private var drag: CGFloat = 0
    /// The finger's translation when the swipe took over, so the card doesn't
    /// jump by the distance it took to recognise the drag.
    @State private var dragOrigin: CGFloat = 0
    /// nil until a gesture has moved far enough to tell; false for one the
    /// stack ignores for the rest of its life (horizontal, or abandoned).
    @State private var isVertical: Bool?
    /// A vertical swipe is under the finger.
    @State private var holding = false
    @State private var chromeShown = false
    @State private var chromeGeneration = 0
    /// Where an animated settle is heading; nil at rest.
    @State private var settleTarget: Int?
    /// Orphans a settle's completion once something else has landed it.
    @State private var settleGeneration = 0
    /// A programmatic flip may target a page that isn't a neighbour.
    @State private var flipTarget: Int?
    /// The flip's target card was just built and hasn't been measured yet.
    @State private var flipAwaitsMeasure = false
    /// Bumped when that card's measurement arrives; the flip starts in the
    /// update that applies it, once the card is parked at its real height.
    @State private var flipMeasured = 0
    /// A flip asked for while the finger is down runs once the swipe lands.
    @State private var queuedFlip: Int?
    /// Counts journeys this stack settled on; changes from outside (a clamp
    /// after the list changed) don't tick.
    @State private var pageTicks = 0
    /// The page `commit` just wrote, so its own `onChange` isn't mistaken
    /// for a change from outside (which would abandon a swipe or flip that
    /// began in the same turn).
    @State private var committedPage: Int?
    @State private var edgeBumps = 0
    @State private var bumpedThisDrag = false
    /// True for the gesture's lifetime, including a system cancellation that
    /// skips `onEnded`.
    @GestureState private var touching = false

    private static let snap: Animation = .spring(response: 0.34, dampingFraction: 1)
    private static let crossfade: Animation = .easeInOut(duration: 0.15)

    private var settling: Bool { settleTarget != nil }

    var body: some View {
        let h0 = height(page, fallback: lastSettledHeight)
        let n = neighbours
        let o = offsets(drag: drag)
        ZStack(alignment: .top) {
            ForEach(slots(n)) { slot in
                JourneyCard(journey: slot.journey, onSelect: onSelect, onDelete: onDelete)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        measured(slot.journey.id, height: h)
                    }
                    .scaleEffect(holding && !reduceMotion ? 0.95 : 1)
                    // Reduce Motion stacks every card at the frame's top, so
                    // the one leaving fades out where it was while the new
                    // one fades in. Parked off-frame, it vanished at once and
                    // the empty frame blinked before the new card.
                    .offset(y: reduceMotion ? 0 : slot.index == page ? o.current : slot.index == n.next ? o.next : o.previous)
                    .allowsHitTesting(slot.index == page && !holding && !settling)
                    .accessibilityHidden(true, isEnabled: slot.index != page)
                    // Neighbours parked off-frame neither report hero frames
                    // nor reach VoiceOver through their rows.
                    .environment(\.heroReports, heroReports && slot.index == page)
                    // Reduce Motion still builds the neighbours, invisible, so
                    // they are measured before they land; a page change is a
                    // crossfade and nothing slides.
                    .animation(reduceMotion ? Self.crossfade : nil) {
                        $0.opacity(reduceMotion && slot.index != page ? 0 : 1)
                    }
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(o.frameHeight, 1), alignment: .top)
        .clipShape(.rect(cornerRadius: ArcTheme.cardCorner))
        .overlay {
            RoundedRectangle(cornerRadius: ArcTheme.cardCorner, style: .continuous)
                .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                .opacity(chromeShown ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) { dots }
        // Layout keeps the resting card's height; the live frame grows or
        // shrinks from the bottom edge without re-laying out anything above.
        .frame(height: max(h0, 1), alignment: .bottom)
        .contentShape(.rect)
        .highPriorityGesture(swipe, including: journeys.count > 1 ? .all : .subviews)
        .sensoryFeedback(.selection, trigger: pageTicks)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: edgeBumps)
        .background { accessibilityPager }
        .onChange(of: touching) { _, isTouching in
            if !isTouching { gestureFinished() }
        }
        .onChange(of: page) { _, now in
            if now == committedPage {
                committedPage = nil
            } else {
                committedPage = nil
                stateChangedOutside()
            }
        }
        .onChange(of: journeys.map(\.id)) { _, _ in
            stateChangedOutside()
            // The handler holds this view's values; keep its journeys current.
            motion.restHandler = { comeToRest() }
            motion.restProbe = { !holding && !settling && flipTarget == nil }
        }
        .onAppear {
            motion.restHandler = { comeToRest() }
            motion.restProbe = { !holding && !settling && flipTarget == nil }
        }
        .onDisappear {
            motion.restHandler = nil
            motion.restProbe = nil
            publishLiveRise(0)
        }
        // Runs after the update that laid the card out at its measured
        // height, so the settle starts from where that height parks it.
        .onChange(of: flipMeasured) { _, _ in
            if let flipTarget { startFlip(to: flipTarget) }
        }
        .onChange(of: flipRequest, initial: true) { _, request in
            guard let request else { return }
            onFlipRequestHandled()
            flip(to: request)
        }
    }

    // MARK: Geometry

    private struct Slot: Identifiable {
        let index: Int
        let journey: TripJourney
        var id: UUID { journey.id }
    }

    /// Keyed by journey, so a card keeps its identity (and measurement) as
    /// it moves from neighbour to current.
    private func slots(_ n: (next: Int, previous: Int)) -> [Slot] {
        [n.previous, page, n.next].filter(journeys.indices.contains).map { Slot(index: $0, journey: journeys[$0]) }
    }

    private var neighbours: (next: Int, previous: Int) {
        guard let flipTarget else { return (page + 1, page - 1) }
        return (flipTarget > page ? flipTarget : page + 1, flipTarget < page ? flipTarget : page - 1)
    }

    private func height(_ index: Int, fallback: CGFloat = 0) -> CGFloat {
        guard journeys.indices.contains(index) else { return fallback }
        return heights[journeys[index].id] ?? fallback
    }

    /// The one place offsets come from: what the body draws and what
    /// `liveRise` publishes can't disagree.
    private func offsets(drag: CGFloat) -> JourneyStackPaging.Offsets {
        let h0 = height(page, fallback: lastSettledHeight)
        let n = neighbours
        return JourneyStackPaging.offsets(drag: drag, current: h0,
                                          next: height(n.next, fallback: h0),
                                          previous: height(n.previous, fallback: h0))
    }

    private func measured(_ id: UUID, height h: CGFloat) {
        if heights[id] != h { heights[id] = h }
        let isCurrent = journeys.indices.contains(page) && journeys[page].id == id
        // Mid-swipe or mid-settle the resting height is the one the swipe
        // started from; landing publishes the new one.
        if isCurrent, !holding, !settling { publishSettledHeight(h) }
        if flipAwaitsMeasure, let flipTarget, journeys.indices.contains(flipTarget), journeys[flipTarget].id == id {
            flipAwaitsMeasure = false
            flipMeasured += 1
        }
    }

    private func publishSettledHeight(_ h: CGFloat) {
        if lastSettledHeight != h { lastSettledHeight = h }
        if motion.settledHeight != h { motion.settledHeight = h }
    }

    private func publishLiveRise(_ rise: CGFloat) {
        if motion.liveRise != rise { motion.liveRise = rise }
    }

    // MARK: Gesture

    /// Attached with `highPriorityGesture`: as a plain `.gesture` the rows'
    /// buttons won every drag (a swipe opened the trip, verified on the
    /// simulator). The minimum distance keeps taps and long presses theirs;
    /// only a clearly vertical drag becomes a swipe.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in swipeChanged(value) }
            .onEnded { value in
                guard isVertical == true, holding else { isVertical = nil; return }
                release(translation: value.translation.height - dragOrigin,
                        predictedEnd: value.predictedEndTranslation.height - dragOrigin)
            }
    }

    private func swipeChanged(_ value: DragGesture.Value) {
        if isVertical == nil {
            let vertical = abs(value.translation.height) > abs(value.translation.width)
            isVertical = vertical
            guard vertical else { return }
            beginSwipe(at: value.translation.height)
        }
        guard isVertical == true, holding else { return }
        let raw = value.translation.height - dragOrigin
        let atEnd = (raw < 0 && page >= journeys.count - 1) || (raw > 0 && page <= 0)
        if atEnd, !bumpedThisDrag {
            bumpedThisDrag = true
            edgeBumps += 1
        }
        guard !reduceMotion else { return }
        let h0 = height(page, fallback: lastSettledHeight)
        let next = atEnd ? JourneyStackPaging.rubberBanded(raw, dimension: h0) : raw
        drag = next
        publishLiveRise(offsets(drag: next).frameHeight - h0)
    }

    private func beginSwipe(at translation: CGFloat) {
        // A touch during a settle lands it where it was heading and carries on.
        if settling { land(runQueued: false) }
        // A flip still waiting for its card yields to the finger.
        if flipTarget != nil {
            flipTarget = nil
            flipAwaitsMeasure = false
        }
        dragOrigin = translation
        bumpedThisDrag = false
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) { holding = true }
        showChrome()
    }

    /// `onEnded` runs before the gesture state resets, so by the next turn a
    /// normal release has already settled with its flick. Anything still
    /// holding then was cancelled by the system, which skips `onEnded`.
    private func gestureFinished() {
        DispatchQueue.main.async {
            if holding { release(translation: drag, predictedEnd: drag) }
            isVertical = nil
        }
    }

    private func release(translation: CGFloat, predictedEnd: CGFloat) {
        guard holding else { return }
        isVertical = nil
        let moved = reduceMotion ? translation : drag
        let direction: JourneyStackPaging.Direction = (moved == 0 ? predictedEnd : moved) < 0 ? .next : .previous
        let h0 = height(page, fallback: lastSettledHeight)
        let neighbour = direction == .next ? page + 1 : page - 1
        let travel = JourneyStackPaging.travel(direction: direction, current: h0,
                                               neighbour: height(neighbour, fallback: h0))
        let target = JourneyStackPaging.target(page: page, count: journeys.count, drag: moved,
                                               predictedEnd: predictedEnd, travel: travel)
        if reduceMotion {
            holding = false
            commit(target)
            scheduleChromeHide()
            runQueuedFlip()
            return
        }
        settle(to: target)
    }

    // MARK: Settling

    /// Animate to the landing position, then swap the page in one
    /// non-animated transaction, where offsets make the swap pixel-identical.
    private func settle(to target: Int) {
        let h0 = height(page, fallback: lastSettledHeight)
        let landing: CGFloat = if target > page {
            -(height(target, fallback: h0) + JourneyStackPaging.gap)
        } else if target < page {
            h0 + JourneyStackPaging.gap
        } else {
            0
        }
        settleTarget = target
        settleGeneration += 1
        let generation = settleGeneration
        withAnimation(Self.snap, completionCriteria: .logicallyComplete) {
            drag = landing
            holding = false
            publishLiveRise(offsets(drag: landing).frameHeight - h0)
        } completion: {
            guard generation == settleGeneration else { return }
            land(runQueued: true)
        }
    }

    private func land(runQueued: Bool) {
        guard let target = settleTarget else { return }
        settleGeneration += 1
        instantly { commit(target) }
        scheduleChromeHide()
        if runQueued { runQueuedFlip() }
    }

    private func commit(_ target: Int) {
        let target = journeys.isEmpty ? page : min(max(target, 0), journeys.count - 1)
        if target != page {
            committedPage = target
            page = target
            pageTicks += 1
            if journeys.indices.contains(target) { onSettled(journeys[target].id) }
        }
        drag = 0
        settleTarget = nil
        flipTarget = nil
        flipAwaitsMeasure = false
        publishLiveRise(0)
        if journeys.indices.contains(target), let h = heights[journeys[target].id] {
            publishSettledHeight(h)
        }
    }

    /// The page or the journeys changed under the stack (a clamp after a
    /// delete, Show Less landing on another card): a swipe or flip heading
    /// for an index that now means something else is dropped where it stands.
    private func comeToRest() {
        queuedFlip = nil
        if holding {
            // The finger may still be down; this gesture is ignored until it lifts.
            settleGeneration += 1
            instantly {
                holding = false
                isVertical = false
                drag = 0
                publishLiveRise(0)
            }
            scheduleChromeHide()
        }
        if settling { land(runQueued: false) }
        if flipTarget != nil || drag != 0 {
            instantly {
                flipTarget = nil
                flipAwaitsMeasure = false
                drag = 0
                publishLiveRise(0)
            }
        }
    }

    private func stateChangedOutside() {
        if holding || settling || flipTarget != nil || drag != 0 {
            settleGeneration += 1
            instantly {
                if holding {
                    holding = false
                    isVertical = false
                }
                drag = 0
                settleTarget = nil
                flipTarget = nil
                flipAwaitsMeasure = false
                publishLiveRise(0)
            }
            scheduleChromeHide()
        }
        // A flip queued behind the finger meant an index that may now name
        // another journey.
        queuedFlip = nil
        if journeys.indices.contains(page), let h = heights[journeys[page].id] {
            publishSettledHeight(h)
        }
    }

    private func instantly(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    // MARK: Programmatic flips

    /// A flip the app asked for: the same motion a swipe settles with.
    private func flip(to request: Int) {
        guard !journeys.isEmpty else { return }
        let target = min(max(request, 0), journeys.count - 1)
        if holding {
            queuedFlip = target
            return
        }
        if settling { land(runQueued: false) }
        guard target != page else { return }
        if reduceMotion {
            commit(target)
            return
        }
        showChrome()
        let built = slots(neighbours).contains { $0.index == target }
        flipTarget = target
        if built, heights[journeys[target].id] != nil {
            settle(to: target)
        } else {
            // Built by this update; `measured` starts the flip.
            flipAwaitsMeasure = true
        }
    }

    private func startFlip(to target: Int) {
        guard flipTarget == target, !holding, !settling,
              journeys.indices.contains(target), target != page else { return }
        settle(to: target)
    }

    private func runQueuedFlip() {
        guard let queued = queuedFlip else { return }
        queuedFlip = nil
        flip(to: queued)
    }

    // MARK: Chrome

    private func showChrome() {
        chromeGeneration += 1
        withAnimation(.easeOut(duration: 0.15)) { chromeShown = true }
    }

    private func scheduleChromeHide() {
        chromeGeneration += 1
        let generation = chromeGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard generation == chromeGeneration, !holding, !settling else { return }
            withAnimation(.easeOut(duration: 0.3)) { chromeShown = false }
        }
    }

    /// At most this many dots, so they never spill past a short card.
    private static let maxDots = 8

    @ViewBuilder
    private var dots: some View {
        if journeys.count > 1 {
            // A window of dots that keeps the current one in view.
            let shown = min(journeys.count, Self.maxDots)
            let first = min(max(page - shown / 2, 0), journeys.count - shown)
            VStack(spacing: 5) {
                ForEach(first..<(first + shown), id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(index == page ? 1 : 0.4))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.trailing, 5)
            .opacity(chromeShown ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// VoiceOver: one adjustable element; the current card's rows stay
    /// reachable. The label stays put and the value carries the page, so a
    /// flip is announced as the value changing.
    @ViewBuilder
    private var accessibilityPager: some View {
        if journeys.count > 1, journeys.indices.contains(page) {
            let legs = journeys[page].legs
            let route = [legs.first?.departureCity, legs.last?.arrivalCity].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " to ")
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("trips-stack")
                .accessibilityLabel("Journeys")
                .accessibilityValue("Journey \(page + 1) of \(journeys.count), \(route)")
                .accessibilityAdjustableAction { direction in
                    flipImmediately(to: direction == .increment ? page + 1 : page - 1)
                }
        }
    }

    /// An adjustable-action flip lands at once: VoiceOver reads the new value
    /// straight after the action, and a spring would still be on the old page.
    private func flipImmediately(to target: Int) {
        guard journeys.indices.contains(target), !holding else { return }
        if settling { land(runQueued: false) }
        instantly {
            flipTarget = nil
            flipAwaitsMeasure = false
            commit(target)
        }
    }
}
