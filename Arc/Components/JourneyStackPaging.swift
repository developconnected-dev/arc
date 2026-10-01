import CoreGraphics
import Foundation

/// The Smart-Stack rules for My Trips' folded journeys, pure so the geometry
/// that must land pixel-identically is tested, not eyeballed.
///
/// The stack's bottom edge is fixed. Swiping up, the next card rises from
/// just below it until its bottom reaches the edge; swiping down, the
/// previous card, parked directly above, slides down until its top reaches
/// the frame's top. The frame's height blends between the two cards.
enum JourneyStackPaging {
    static let gap: CGFloat = 10
    /// A release past this share of the travel commits.
    static let commitShare: CGFloat = 0.34
    /// A flick whose predicted end passes this share commits even if short.
    static let flickShare: CGFloat = 0.5
    static let rubberBandCoefficient: CGFloat = 0.55

    enum Direction { case next, previous }

    static func travel(direction: Direction, current: CGFloat, neighbour: CGFloat) -> CGFloat {
        (direction == .next ? neighbour : current) + gap
    }

    static func progress(drag: CGFloat, travel: CGFloat) -> CGFloat {
        guard travel > 0 else { return 0 }
        return min(max(abs(drag) / travel, 0), 1)
    }

    static func liveHeight(current: CGFloat, neighbour: CGFloat, progress: CGFloat) -> CGFloat {
        current + (neighbour - current) * progress
    }

    struct Offsets: Equatable {
        /// Card tops relative to the frame's top edge.
        var current: CGFloat
        var next: CGFloat
        var previous: CGFloat
        var frameHeight: CGFloat
    }

    /// `drag` < 0 moves toward the next card, > 0 toward the previous.
    static func offsets(drag: CGFloat, current h0: CGFloat, next hN: CGFloat, previous hP: CGFloat) -> Offsets {
        let direction: Direction = drag < 0 ? .next : .previous
        let neighbour = direction == .next ? hN : hP
        let t = progress(drag: drag, travel: travel(direction: direction, current: h0, neighbour: neighbour))
        let live = liveHeight(current: h0, neighbour: neighbour, progress: t)
        return Offsets(current: live - h0 + drag,
                       next: live + gap + drag,
                       previous: live - h0 - gap - hP + drag,
                       frameHeight: live)
    }

    /// One page at most per release, never past either end.
    static func target(page: Int, count: Int, drag: CGFloat, predictedEnd: CGFloat, travel: CGFloat) -> Int {
        guard count > 1, travel > 0 else { return min(max(page, 0), max(count - 1, 0)) }
        // A flick back before release cancels: the neighbour in the opposite
        // direction was never in view during the drag, so there's nowhere for
        // the reversal to land. (Smart Stack behaves this way.)
        let reversed = drag != 0 && predictedEnd != 0 && (drag < 0) != (predictedEnd < 0)
        guard !reversed else { return page }
        let committed = abs(drag) > travel * commitShare || abs(predictedEnd) > travel * flickShare
        let moving = abs(predictedEnd) > abs(drag) * 0.5 ? predictedEnd : drag
        guard committed, moving != 0 else { return page }
        let step = moving < 0 ? 1 : -1
        return min(max(page + step, 0), count - 1)
    }

    /// UIScrollView's rubber band: resistance grows with distance, sign kept.
    static func rubberBanded(_ x: CGFloat, dimension: CGFloat) -> CGFloat {
        guard dimension > 0, x != 0 else { return 0 }
        let c = rubberBandCoefficient
        let damped = (1 - 1 / (abs(x) * c / dimension + 1)) * dimension
        return x < 0 ? -damped : damped
    }

    /// How far what sits on the stack's edge (the Show More row, the list's
    /// mask) moves for a live rise, when the folded stack can be no taller
    /// than `room`, the list's unfolded height: the stack's top stops under
    /// the top row like the list's does.
    static func edgeRise(liveRise: CGFloat, restHeight: CGFloat, room: CGFloat) -> CGFloat {
        guard liveRise != 0 else { return 0 }
        return min(room, restHeight + liveRise) - min(room, restHeight)
    }

    /// The page to show once the list (journeys, friends' flights) changes
    /// under the stack: the card it was on, wherever that went.
    static func page<ID: Equatable>(after old: [ID], now: [ID], was page: Int) -> Int {
        guard !now.isEmpty else { return 0 }
        if old.indices.contains(page), let moved = now.firstIndex(of: old[page]) { return moved }
        return min(max(page, 0), now.count - 1)
    }
}
