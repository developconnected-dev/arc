import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Extracts the flights a pasted booking confirmation names — flight number
/// and local departure date — using the ON-DEVICE model where the device has
/// one, the Worker's `/parse-booking` where it doesn't.
///
/// The on-device path is Apple's Foundation Models framework: guided
/// generation into a typed structure, running entirely on the Neural Engine.
/// A booking pasted on a capable device never leaves it for the extraction
/// step, answers in about a second instead of a Worker round-trip, and costs
/// nothing per parse. Where the model is missing (older device, simulator,
/// Apple Intelligence off, model still downloading) or returns nothing
/// credible, the Worker path is exactly what it was — this is a fast lane,
/// not a new dependency.
///
/// Either lane's output goes through the same vetting: a small model asked
/// about free text can hallucinate, so nothing is believed that doesn't look
/// like a flight designator with a real date near today. Every surviving item
/// is then resolved against real schedule data by the caller, which is the
/// stronger check — vetting exists so obvious inventions don't burn schedule
/// lookups.
enum BookingExtractor {

    /// The full extraction: on-device first, Worker fallback. Returns the
    /// vetted items in travel order; empty when neither lane found a flight.
    static func extract(text: String) async -> [FlightAPIClient.ParsedFlightItem] {
        if let onDevice = await extractOnDevice(text: text), !onDevice.isEmpty {
            return onDevice
        }
        let remote = (try? await FlightAPIClient.shared.parseBooking(text: text)) ?? []
        return vetted(remote)
    }

    /// nil means "lane unavailable or failed" — fall back. An empty array
    /// after vetting also falls back (the caller treats it the same), because
    /// the ~3B on-device model missing a flight the Worker's model would
    /// catch is the expected failure shape, not proof the text names none.
    static func extractOnDevice(text: String) async -> [FlightAPIClient.ParsedFlightItem]? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        // A forwarded booking email drags in footers, legal text and the
        // airline's entire upsell catalogue; the flights are named in the
        // first screens of it. Cap what the small context window is fed.
        let clipped = String(text.prefix(6000))
        let session = LanguageModelSession(instructions: """
            Extract the flights from a booking confirmation or itinerary.
            List only flights the text actually names, in travel order.
            A flight number is an airline code and digits, like LX2146 or U2 8437.
            The date is the LOCAL departure date of that flight, from the text.
            If the text names no flights, return an empty list.
            """)
        do {
            let response = try await session.respond(
                to: clipped, generating: ExtractedBooking.self)
            return vetted(response.content.flights.map {
                FlightAPIClient.ParsedFlightItem(flightNumber: $0.flightNumber, date: $0.date)
            })
        } catch {
            // Guardrails, context overflow, model mid-download — the Worker
            // lane exists for exactly this.
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Believe only what looks like a flight: a real IATA designator shape,
    /// a date that parses and sits within a year of now (bookings are near
    /// futures or recent pasts; "2019-03-08" out of a small model is an
    /// invention, not an itinerary). Duplicates collapse — confirmations
    /// repeat each leg in the summary, the details and the fare table.
    static func vetted(_ items: [FlightAPIClient.ParsedFlightItem],
                       near today: Date = .now) -> [FlightAPIClient.ParsedFlightItem] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        var seen = Set<String>()
        var out: [FlightAPIClient.ParsedFlightItem] = []
        for item in items {
            let number = item.flightNumber.uppercased()
                .replacingOccurrences(of: " ", with: "")
            // Two-character designator (at least one letter — "U2" and "LX"
            // are designators, "12" is a row number), 1–4 digits, optional
            // operational suffix.
            guard number.range(of: #"^[A-Z0-9]{2}[0-9]{1,4}[A-Z]?$"#,
                               options: .regularExpression) != nil,
                  number.prefix(2).contains(where: \.isLetter),
                  let date = fmt.date(from: item.date),
                  abs(date.timeIntervalSince(today)) < 366 * 24 * 3600
            else { continue }
            let key = "\(number)|\(item.date)"
            guard seen.insert(key).inserted else { continue }
            out.append(.init(flightNumber: number, date: item.date))
        }
        return out
    }
}

#if canImport(FoundationModels)
/// The shape guided generation fills in — the framework constrains the
/// model's decoding to this structure, so the output can be malformed in
/// content but never in form.
@available(iOS 26.0, *)
@Generable
private struct ExtractedBooking {
    @Guide(description: "Every flight the text names, in travel order. Empty if none.")
    let flights: [ExtractedFlight]
}

@available(iOS 26.0, *)
@Generable
private struct ExtractedFlight {
    @Guide(description: "Airline code plus number, e.g. LX2146")
    let flightNumber: String
    @Guide(description: "Local departure date as yyyy-MM-dd")
    let date: String
}
#endif
