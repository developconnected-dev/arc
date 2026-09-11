import XCTest
@testable import Arc

/// Every row tags the same five elements, so the ids must carry the flight:
/// two rows must never share a geometry group.
@MainActor
final class MorphTests: XCTestCase {
    func testIdsAreDistinctPerFlightAndPerElement() {
        let a = Flight(flightNumber: "LX14", date: .now)
        let b = Flight(flightNumber: "LX14", date: .now)
        XCTAssertNotEqual(MorphElement.logo.id(for: a), MorphElement.logo.id(for: b))
        XCTAssertNotEqual(MorphElement.logo.id(for: a), MorphElement.cities.id(for: a))
        XCTAssertEqual(MorphElement.route.id(for: a), MorphElement.route.id(for: a))
    }
}
