import XCTest
import SwiftUI
@testable import Arc

final class BrandingTests: XCTestCase {
    func testTailColorIsDeterministic() {
        XCTAssertEqual(AirlineBranding.tailColor(iata: "LX"), AirlineBranding.tailColor(iata: "lx"))
    }

    func testInitials() {
        XCTAssertEqual(AirlineBranding.initials(iata: "u2"), "U2")
    }

    /// Types now resolve to a drawn profile rather than an asset name — see
    /// AircraftProfileTests for the full matrix.
    func testAircraftMapping() {
        XCTAssertEqual(AircraftImage.profile(for: "Airbus A321neo"), .narrowbodyStretched)
        XCTAssertEqual(AircraftImage.profile(for: "Boeing 737-800"), .narrowbody)
        XCTAssertEqual(AircraftImage.profile(for: nil), .narrowbody)
        XCTAssertEqual(AircraftImage.profile(for: "Unknown Type"), .narrowbody)
    }
}
