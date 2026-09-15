import SwiftUI

/// Every opening/closing gets a new request, even when the same view is reused.
/// Only the current request may settle the sheet or start a map adjustment.
struct TripTransition {
    enum Phase { case list, opening, detail, closing }
    struct Request: Equatable {
        let id: UUID
        let target: Double
    }
    private(set) var phase: Phase = .list
    private(set) var request: Request?

    mutating func open() { begin(.opening, target: 1) }
    mutating func close() { begin(.closing, target: 0) }
    private mutating func begin(_ phase: Phase, target: Double) {
        self.phase = phase
        request = Request(id: UUID(), target: target)
    }
    @discardableResult
    mutating func finish(_ id: UUID) -> Bool {
        guard let request, request.id == id else { return false }
        settle(detail: request.target == 1)
        return true
    }
    mutating func settle(detail: Bool) {
        request = nil
        phase = detail ? .detail : .list
    }
}

/// Runs inside the active tab's sheet host. It never waits for onAppear or
/// a geometry change to kick off a reused card's animation.
struct TripTransitionDriver: ViewModifier {
    let request: TripTransition.Request?
    @Binding var progress: Double
    let prepare: (UUID) -> Void
    let finish: (UUID) -> Void

    func body(content: Content) -> some View {
        content
            .task(id: request) {
                guard let request else { return }
                // Give the inserted detail one layout pass. Missing geometry
                // uses the overlay's fallback frame; it cannot strand the UI.
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard !Task.isCancelled else { return }
                prepare(request.id)
                withAnimation(ArcTheme.morph, completionCriteria: .removed) {
                    progress = request.target
                } completion: {
                    finish(request.id)
                }
                // UIKit hosting can discard an animation completion during a
                // view replacement. A cancelled/old request cannot finish a
                // newer transition; a live one always has a bounded lifetime.
                do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
                guard !Task.isCancelled else { return }
                finish(request.id)
            }
    }
}
