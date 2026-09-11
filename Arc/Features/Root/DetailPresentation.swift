import Foundation

/// The sheet's height around a flight detail: opening raises it to large
/// and remembers the height it had, closing restores that height. Replacing
/// one open detail with another keeps the first memory, so a crossfade
/// between two flights still closes back to where the user started.
struct DetailPresentation: Equatable {
    private(set) var detentBefore: SheetDetent?

    mutating func open(from current: SheetDetent) -> SheetDetent {
        if detentBefore == nil { detentBefore = current }
        return .large
    }

    mutating func close() -> SheetDetent? {
        defer { detentBefore = nil }
        return detentBefore
    }
}
