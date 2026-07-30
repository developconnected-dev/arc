import XCTest
@testable import Arc

/// Type strings arrive in wildly different shapes depending on the source:
/// ICAO designators from the live feeds, marketing names from schedules, and
/// whatever a user typed by hand.
final class AircraftProfileTests: XCTestCase {
    private func p(_ s: String?) -> AircraftProfile { AircraftImage.profile(for: s) }

    func testICAODesignators() {
        XCTAssertEqual(p("A20N"), .narrowbody)
        XCTAssertEqual(p("A21N"), .narrowbodyStretched)
        XCTAssertEqual(p("B38M"), .narrowbody)
        XCTAssertEqual(p("B77W"), .widebody)
        XCTAssertEqual(p("B789"), .widebody)
        XCTAssertEqual(p("B748"), .jumbo)
        XCTAssertEqual(p("A388"), .superjumbo)
        XCTAssertEqual(p("A346"), .widebodyQuad)
    }

    /// The exact strings the brief called out.
    func testMarketingNames() {
        XCTAssertEqual(p("Airbus A320neo"), .narrowbody)
        XCTAssertEqual(p("787-9 Dreamliner"), .widebody)
        XCTAssertEqual(p("B738"), .narrowbody)
        XCTAssertEqual(p("Boeing 777-300ER"), .widebody)
    }

    /// Spaces and hyphens must not change the answer.
    func testPunctuationAndCaseAreIrrelevant() {
        XCTAssertEqual(p("boeing 737-800"), p("B738"))
        XCTAssertEqual(p("Airbus A-350-900"), .widebody)
        XCTAssertEqual(p("airbus a380-800"), .superjumbo)
    }

    /// A321 must not be swallowed by the A320 rule, nor 777 by 737.
    func testMoreSpecificFamilyWins() {
        XCTAssertEqual(p("A321"), .narrowbodyStretched)
        XCTAssertNotEqual(p("A321"), p("A320"))
        XCTAssertEqual(p("Boeing 777"), .widebody)
        XCTAssertEqual(p("Boeing 737"), .narrowbody)
    }

    func testRegionalsAndTurboprops() {
        XCTAssertEqual(p("E190"), .regionalUnderwing)
        XCTAssertEqual(p("A220-300"), .regionalUnderwing)
        XCTAssertEqual(p("CRJ900"), .regionalJet)
        XCTAssertEqual(p("E175"), .regionalJet)
        XCTAssertEqual(p("ATR 72-600"), .turboprop)
        XCTAssertEqual(p("DH8D"), .turboprop)
    }

    /// Unknown or missing types fall back to a narrowbody twin — by far the
    /// most likely aircraft — rather than a generic blob.
    func testFallbacks() {
        XCTAssertEqual(p(nil), .narrowbody)
        XCTAssertEqual(p(""), .narrowbody)
        XCTAssertEqual(p("Unidentified Flying Object"), .narrowbody)
    }

    func testIsWideMatchesTheProfile() {
        XCTAssertTrue(AircraftImage.isWide("B77W"))
        XCTAssertTrue(AircraftImage.isWide("A388"))
        XCTAssertTrue(AircraftImage.isWide("787-9 Dreamliner"))
        XCTAssertFalse(AircraftImage.isWide("A320"))
        XCTAssertFalse(AircraftImage.isWide("CRJ900"))
        XCTAssertFalse(AircraftImage.isWide("ATR 72"))
    }

    /// Distinct families must not collapse onto one shape — the point of the
    /// upgrade is that a 747 doesn't look like an A320.
    func testFamiliesAreVisuallyDistinct() {
        let families: [AircraftProfile] = [
            .narrowbody, .narrowbodyStretched, .widebody, .widebodyQuad,
            .jumbo, .superjumbo, .regionalJet, .regionalUnderwing, .turboprop,
        ]
        for (i, a) in families.enumerated() {
            for b in families[(i + 1)...] {
                XCTAssertNotEqual(a, b, "two families share identical geometry")
            }
        }
    }
}
