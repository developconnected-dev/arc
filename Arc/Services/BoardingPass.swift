import Foundation

/// One leg off an IATA Bar-Coded Boarding Pass (Resolution 792 — the
/// PDF417/Aztec/QR payload every printed and mobile pass carries).
/// Pure string arithmetic, unit-tested; no Vision, no camera.
///
/// The mandatory block is FIXED-WIDTH, which is what makes this parser
/// deterministic where the AI paste-parser is probabilistic:
///
///   M1DESMARAIS/LUC       EABC123 YULFRAAC 0834 326J001A0025 100
///   ^^^                    ^      ^  ^  ^  ^    ^  ^^   ^
///   |  name (20)           PNR(7) |  |  |  |    |  |seat(4)
///   format+legs                 from to carrier flt julian compartment
///
/// Only the first leg is decoded: connecting legs live past a variable-
/// width block and the add flow resolves one flight at a time anyway —
/// the second boarding pass scans just as easily.
struct BoardingPass: Equatable {
    let passengerName: String     // "DESMARAIS/LUC"
    let bookingCode: String?      // operating carrier PNR, e.g. "ABC123"
    let departureIATA: String
    let arrivalIATA: String
    let airlineCode: String       // "AC", "LX" — trimmed designator
    let flightNumber: String      // "AC834" — designator + de-padded number
    let julianDay: Int            // 1…366, day-of-year of the flight
    let seat: String?             // "12A" — de-padded, nil for e.g. jump seats

    /// The flight's calendar date: the pass only carries a day-of-year, so
    /// the year is the one that puts that day NEAREST `today` — a pass
    /// scanned in January for day 360 belongs to the year that just ended,
    /// one scanned in December for day 004 to the year about to start.
    func flightDate(near today: Date = .now, calendar: Calendar = .current) -> Date? {
        let thisYear = calendar.component(.year, from: today)
        var best: Date?
        var bestGap = TimeInterval.greatestFiniteMagnitude
        for year in (thisYear - 1)...(thisYear + 1) {
            var comps = DateComponents()
            comps.year = year
            comps.day = julianDay
            guard let d = calendar.date(from: comps),
                  calendar.ordinality(of: .day, in: .year, for: d) == julianDay else { continue }
            let gap = abs(d.timeIntervalSince(today))
            if gap < bestGap { best = d; bestGap = gap }
        }
        return best
    }

    /// nil when the payload is not a BCBP — a URL QR, a luggage tag, a
    /// half-read scan. Every reject reason is a malformed MANDATORY field;
    /// the variable tail is never touched.
    static func parse(_ raw: String) -> BoardingPass? {
        let s = Array(raw)
        // Format "M" + leg count, and the mandatory block's full width.
        guard s.count >= 58, s[0] == "M", ("1"..."9").contains(String(s[1])) else { return nil }
        func field(_ range: ClosedRange<Int>) -> String {
            String(s[range.lowerBound...range.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        let name = field(2...21)
        let pnr = field(23...29)
        let dep = field(30...32).uppercased()
        let arr = field(33...35).uppercased()
        let carrier = field(36...38).uppercased()
        let number = field(39...43)
        let julian = field(44...46)
        let seatRaw = field(48...51)

        guard dep.count == 3, arr.count == 3,
              dep.allSatisfy(\.isLetter), arr.allSatisfy(\.isLetter),
              !carrier.isEmpty, !number.isEmpty,
              let day = Int(julian), (1...366).contains(day) else { return nil }

        // "0834" → "834"; an operational suffix ("834A") survives de-padding.
        let dePadded = String(number.drop(while: { $0 == "0" }))
        guard !dePadded.isEmpty else { return nil }

        // "001A" → "1A". A non-seat marker (GATE, empty) becomes nil rather
        // than a fake seat.
        let seat = String(seatRaw.drop(while: { $0 == "0" }))
        let seatValid = seat.count >= 2 && seat.dropLast().allSatisfy(\.isNumber)
            && (seat.last?.isLetter ?? false)

        return BoardingPass(
            passengerName: name,
            bookingCode: pnr.isEmpty ? nil : pnr,
            departureIATA: dep,
            arrivalIATA: arr,
            airlineCode: carrier,
            flightNumber: carrier + dePadded,
            julianDay: day,
            seat: seatValid ? seat : nil)
    }
}
