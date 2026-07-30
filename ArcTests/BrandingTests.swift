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

    func testAircraftMapping() {
        XCTAssertEqual(AircraftImage.assetName(for: "Airbus A321neo"), "aircraft-a321")
        XCTAssertEqual(AircraftImage.assetName(for: "Boeing 737-800"), "aircraft-b737")
        XCTAssertEqual(AircraftImage.assetName(for: nil), "aircraft-generic")
        XCTAssertEqual(AircraftImage.assetName(for: "Unknown Type"), "aircraft-generic")
    }
}
