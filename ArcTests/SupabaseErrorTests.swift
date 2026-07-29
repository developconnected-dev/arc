import XCTest
@testable import Arc

/// The bug these guard against: an expired token made PostgREST answer with a
/// JSON *object*, which the app fed to a `[Row]` decoder — so "your session
/// expired" surfaced as "the data couldn't be read because it isn't in the
/// correct format", and a failed write looked exactly like a successful one.
@MainActor
final class SupabaseErrorTests: XCTestCase {
    private func json(_ raw: String) -> Data { Data(raw.utf8) }

    func testExtractsPostgRESTMessage() {
        let data = json(#"{"code":"PGRST301","message":"JWT expired"}"#)
        XCTAssertEqual(ArcSupabase.errorMessage(data), "JWT expired")
    }

    func testExtractsGoTrueDescription() {
        let data = json(#"{"error":"invalid_grant","error_description":"Refresh Token Not Found"}"#)
        XCTAssertEqual(ArcSupabase.errorMessage(data), "Refresh Token Not Found")
    }

    func testIgnoresEmptyFieldsAndFallsThrough() {
        let data = json(#"{"message":"","msg":"Email not confirmed"}"#)
        XCTAssertEqual(ArcSupabase.errorMessage(data), "Email not confirmed")
    }

    /// A successful list response is an array, not an object — no message to
    /// lift, and the caller decodes it normally.
    func testReturnsNilForNonObjectPayloads() {
        XCTAssertNil(ArcSupabase.errorMessage(json("[]")))
        XCTAssertNil(ArcSupabase.errorMessage(json("not json at all")))
    }
}
