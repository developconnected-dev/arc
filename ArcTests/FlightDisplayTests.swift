import XCTest
@testable import Arc

@MainActor
final class FlightDisplayTests: XCTestCase {
    private func makeFlight(delay: Int = 0, status: FlightStatus = .scheduled) -> Flight {
        let dep = Date(timeIntervalSince1970: 1_800_000_000)   // fixed instant
        let f = Flight(flightNumber: "LX1413", date: dep)
        f.scheduledDeparture = dep
        f.scheduledArrival = dep.addingTimeInterval(2 * 3600)
        f.delayMinutes = delay
        f.status = status
        return f
    }

    func testEffectiveDepartureFallsBackToScheduledWhenNoDelay() {
        let f = makeFlight(delay: 0)
        XCTAssertEqual(f.effectiveDeparture, f.scheduledDeparture)
    }

    /// Regression: a flight coming back from live search only ever sets
    /// `delayMinutes`, never `actualDeparture` — effectiveDeparture must still
    /// reflect the delay, or the whole Detail screen silently reads "On Time".
    func testEffectiveDepartureDerivesFromDelayMinutesWhenNoActualTimeSet() {
        let f = makeFlight(delay: 45)
        XCTAssertNil(f.actualDeparture)
        XCTAssertEqual(f.effectiveDeparture, f.scheduledDeparture.addingTimeInterval(45 * 60))
        XCTAssertTrue(f.departureChanged)
    }

    func testEffectiveDeparturePrefersExplicitActualTimeOverDelayMinutes() {
        let f = makeFlight(delay: 45)
        let explicit = f.scheduledDeparture.addingTimeInterval(50 * 60)
        f.actualDeparture = explicit
        XCTAssertEqual(f.effectiveDeparture, explicit)
    }

    func testEffectiveArrivalDerivesFromDelayMinutesWhenNoActualOrEstimatedTimeSet() {
        let f = makeFlight(delay: 20)
        XCTAssertEqual(f.effectiveArrival, f.scheduledArrival.addingTimeInterval(20 * 60))
    }

    func testDepartureStatusTextReflectsDelay() {
        let f = makeFlight(delay: 65)
        XCTAssertEqual(f.departureStatusText, "1h 5m Late")
    }

    func testDepartureStatusTextOnTimeWhenNoDelay() {
        let f = makeFlight(delay: 0)
        XCTAssertEqual(f.departureStatusText, "On Time")
    }

    func testBannerColorIsLateWhenDelayed() {
        let f = makeFlight(delay: 30)
        XCTAssertEqual(f.bannerColor, ArcTheme.late)
    }

    func testBannerColorIsOnTimeWhenNotDelayed() {
        let f = makeFlight(delay: 0)
        XCTAssertEqual(f.bannerColor, ArcTheme.onTime)
    }

    // MARK: isRecentlyLanded — uses relative Date.now offsets, not the fixed
    // `makeFlight` instant above (which is a fixed future date, not "recent").

    private func landedFlight(minutesAgo: Double) -> Flight {
        let f = Flight(flightNumber: "LX1413", date: .now)
        f.scheduledDeparture = .now.addingTimeInterval(-3 * 3600)
        f.scheduledArrival = .now.addingTimeInterval(-minutesAgo * 60)
        f.actualArrival = f.scheduledArrival
        f.status = .landed
        return f
    }

    func testRecentlyLandedTrueJustAfterLanding() {
        XCTAssertTrue(landedFlight(minutesAgo: 5).isRecentlyLanded)
    }

    func testRecentlyLandedFalseAfter30Minutes() {
        XCTAssertFalse(landedFlight(minutesAgo: 31).isRecentlyLanded)
    }

    func testRecentlyLandedFalseForNonLandedStatus() {
        let f = landedFlight(minutesAgo: 5)
        f.status = .active
        XCTAssertFalse(f.isRecentlyLanded)
    }

    func testMyFlightsCardShowsLandedLabelDuringGracePeriod() {
        let f = landedFlight(minutesAgo: 5)
        XCTAssertEqual(f.cardTopRight, "Landed")
        XCTAssertEqual(f.cardTopRightColor, f.accentColor)
    }

    func testLiveActivityInsightNilWithoutPrediction() {
        XCTAssertNil(makeFlight().liveActivityInsight)
    }

    func testLiveActivityInsightIncludesMinutesAndReason() {
        let f = makeFlight()
        f.predictedDelayMinutes = 32
        f.predictionReason = "Inbound is 42m late"
        XCTAssertEqual(f.liveActivityInsight, "Arc predicts +32m — Inbound is 42m late")
    }

    /// The reason InboundMonitor actually writes is longer than the Live
    /// Activity's ~70 character budget, so the real-world path is the truncating
    /// one — it must still end cleanly rather than being clipped by the OS.
    func testLiveActivityInsightTruncatesTheReasonArcActuallyWrites() throws {
        let f = makeFlight()
        f.predictedDelayMinutes = 32
        f.predictionReason = "Inbound aircraft lands too late for a 30-min turnaround"
        let s = try XCTUnwrap(f.liveActivityInsight)
        XCTAssertEqual(s.count, 70)
        XCTAssertTrue(s.hasPrefix("Arc predicts +32m — Inbound aircraft lands"))
        XCTAssertTrue(s.hasSuffix("…"))
    }

    func testLiveActivityInsightFallsBackToTheNumberAloneWhenThereIsNoReason() {
        let f = makeFlight()
        f.predictedDelayMinutes = 45
        XCTAssertEqual(f.liveActivityInsight, "Arc predicts +45m")
    }

    func testDepartureReminderUsesEffectiveDeparture() {
        let f = makeFlight(delay: 45)
        let now = f.scheduledDeparture.addingTimeInterval(-5 * 3600)
        XCTAssertEqual(
            ArcNotifications.departureReminderDate(for: f, now: now),
            f.effectiveDeparture.addingTimeInterval(-2 * 3600))
    }

    func testDepartureReminderSkippedOnceTheWindowHasPassed() {
        let f = makeFlight(delay: 0)
        XCTAssertNil(ArcNotifications.departureReminderDate(for: f, now: f.scheduledDeparture))
    }
}

final class DateHelpersTests: XCTestCase {
    /// Regression: entering "16:22" for a flight departing some other city must
    /// record 16:22 in THAT city's timezone, not 16:22 in the device's timezone.
    ///
    /// A real DatePicker writes its bound Date using the device's own
    /// `Calendar.current` — so "what the user typed" is modelled here the same
    /// way: build the instant with `Calendar.current` (whatever zone this test
    /// happens to run in), not a hardcoded zone, so the test is honest about
    /// what the function actually receives and stays valid on any machine.
    func testReinterpretWallClockPreservesClockDigitsInTargetZone() {
        let typed = Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 20, hour: 16, minute: 22))!

        let zurich = TimeZone(identifier: "Europe/Zurich")!
        let result = DateHelpers.reinterpretWallClock(typed, asLocalTo: zurich)

        var zurichCal = Calendar(identifier: .gregorian)
        zurichCal.timeZone = zurich
        let comps = zurichCal.dateComponents([.hour, .minute], from: result)
        XCTAssertEqual(comps.hour, 16)
        XCTAssertEqual(comps.minute, 22)
    }

    func testReinterpretWallClockNoOpWhenTimeZoneNil() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(DateHelpers.reinterpretWallClock(now, asLocalTo: nil), now)
    }

    /// Regression: AeroDataBox timestamps always include fractional seconds
    /// (the Worker's `toISO()` round-trips through JS `Date.toISOString()`,
    /// which always produces ".sssZ"). A formatter built with only
    /// `.withInternetDateTime` silently fails on this — the earlier
    /// InboundSelection/AddFlightView tests all used clean non-fractional
    /// fixtures and passed despite the real bug, which is exactly why this
    /// needs a realistic fixture, not a convenient one.
    func testParseAPIDateHandlesRealAeroDataBoxFormat() {
        let d = DateHelpers.parseAPIDate("2026-07-20T11:05:00.000Z")
        XCTAssertNotNil(d)
        XCTAssertEqual(d, ISO8601DateFormatter().date(from: "2026-07-20T11:05:00Z"))
    }

    func testParseAPIDateStillHandlesPlainFormat() {
        XCTAssertNotNil(DateHelpers.parseAPIDate("2026-07-20T11:05:00Z"))
    }

    func testParseAPIDateNilForEmptyOrNil() {
        XCTAssertNil(DateHelpers.parseAPIDate(""))
        XCTAssertNil(DateHelpers.parseAPIDate(nil))
    }
}

final class FlightStatusHealTests: XCTestCase {
    func testHealPassesThroughKnownRawValue() {
        XCTAssertEqual(FlightStatus.heal(rawValue: "landed", scheduledArrival: .now), .landed)
    }

    /// Regression: before the Worker normalized AeroDataBox's vocabulary,
    /// `statusRaw` could be "expected"/"arrived"/etc. — neither `isUpcoming`
    /// nor `isCompleted` matches those, so the flight vanished from every
    /// list while still rendering on the Passport globe (route rendering
    /// doesn't filter by status). heal() is the safety net for exactly that.
    func testHealFallsBackToScheduledForFutureUnknownStatus() {
        let future = Date.now.addingTimeInterval(3600)
        XCTAssertEqual(FlightStatus.heal(rawValue: "expected", scheduledArrival: future), .scheduled)
    }

    /// Comfortably past its arrival → history. Just past it → NOT asserted
    /// landed: an unknown status string can't be turned into an arrival by
    /// the clock alone.
    func testHealFallsBackToLandedOnlyWellPastArrival() {
        let longAgo = Date.now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(FlightStatus.heal(rawValue: "arrived", scheduledArrival: longAgo), .landed)
        let justNow = Date.now.addingTimeInterval(-3600)
        XCTAssertEqual(FlightStatus.heal(rawValue: "weird", scheduledArrival: justNow), .scheduled)
    }
}

@MainActor
final class FlightUpcomingTests: XCTestCase {
    private func flight(status: FlightStatus, departureOffset: TimeInterval) -> Flight {
        let f = Flight(flightNumber: "LX1413", date: .now.addingTimeInterval(departureOffset))
        f.scheduledDeparture = .now.addingTimeInterval(departureOffset)
        f.status = status
        return f
    }

    func testUpcomingTrueForScheduledFlightInTheFuture() {
        XCTAssertTrue(flight(status: .scheduled, departureOffset: 3600).isUpcoming)
    }

    /// Regression: a flight still marked .scheduled after its own scheduled
    /// departure time has passed — the overwhelmingly common case for any
    /// delayed flight, since the real airline hasn't reported "departed" yet
    /// even though the original schedule instant has ticked over — must stay
    /// isUpcoming. Previously isUpcoming also required scheduledDeparture in
    /// the future, so this flight satisfied neither isUpcoming nor isActive:
    /// FlightTracker's relevant-to-poll filter excluded it, so it could never
    /// be checked again to learn it eventually went active, and the same
    /// condition gated My Flights/map visibility — the flight vanishing "the
    /// moment it takes off" for any flight with even a few minutes of delay.
    func testUpcomingStaysTrueForScheduledFlightPastItsOwnDepartureTime() {
        XCTAssertTrue(flight(status: .scheduled, departureOffset: -900).isUpcoming)
    }

    func testUpcomingFalseOnceActive() {
        XCTAssertFalse(flight(status: .active, departureOffset: -900).isUpcoming)
    }

    func testUpcomingFalseOnceLanded() {
        XCTAssertFalse(flight(status: .landed, departureOffset: -3 * 3600).isUpcoming)
    }

    func testUpcomingIncludesBoardingAndGateClosed() {
        XCTAssertTrue(flight(status: .boarding, departureOffset: 900).isUpcoming)
        XCTAssertTrue(flight(status: .gateClosed, departureOffset: 300).isUpcoming)
    }
}

@MainActor
final class BoardingDisplayTests: XCTestCase {
    private func flight(status: FlightStatus) -> Flight {
        let f = Flight(flightNumber: "LX1413", date: .now.addingTimeInterval(1800))
        f.scheduledDeparture = .now.addingTimeInterval(1800)
        f.scheduledArrival = .now.addingTimeInterval(1800 + 2 * 3600)
        f.status = status
        return f
    }

    /// Regression: boarding fell through statusText's default branch, so the
    /// card read "Departs On Time" while passengers were already boarding.
    func testBoardingShowsAsStandaloneLabel() {
        XCTAssertEqual(flight(status: .boarding).statusText, "Boarding")
        XCTAssertEqual(flight(status: .boarding).cardTopRight, "Boarding")
    }

    func testGateClosedShowsAsStandaloneLabelInUrgentColor() {
        let f = flight(status: .gateClosed)
        XCTAssertEqual(f.cardTopRight, "Gate Closed")
        XCTAssertEqual(f.cardTopRightColor, ArcTheme.late)
    }
}

@MainActor
final class FlightTrackPointTests: XCTestCase {
    private func makeFlight() -> Flight {
        Flight(flightNumber: "LX14", date: .now)
    }

    func testAppendStoresAndRoundTripsPoints() {
        let f = makeFlight()
        f.appendTrackPoint(lat: 47.46, lon: 8.55, altitude: 3000)
        f.appendTrackPoint(lat: 48.30, lon: 7.20, altitude: 10600)
        XCTAssertEqual(f.trackPoints.count, 2)
        XCTAssertEqual(f.trackPoints[1].lat, 48.30, accuracy: 0.0001)
        XCTAssertEqual(f.trackPoints[1].altitude, 10600)
    }

    /// A position within 2 km of the last breadcrumb must be dropped —
    /// otherwise a plane holding/taxiing spams hundreds of near-identical
    /// points into storage.
    func testAppendDeduplicatesNearbyPoints() {
        let f = makeFlight()
        f.appendTrackPoint(lat: 47.4600, lon: 8.5500, altitude: nil)
        f.appendTrackPoint(lat: 47.4601, lon: 8.5502, altitude: nil)   // ~15 m away
        XCTAssertEqual(f.trackPoints.count, 1)
    }
}

final class WidgetFlightTests: XCTestCase {
    private func widgetFlight(status: String, depOffset: TimeInterval, delay: Int = 0) -> WidgetFlight {
        WidgetFlight(
            id: "t", flightNumber: "LX1413", airline: "Swiss",
            departureIATA: "BEG", arrivalIATA: "ZRH",
            departureCity: "Belgrade", arrivalCity: "Zurich",
            scheduledDeparture: .now.addingTimeInterval(depOffset),
            scheduledArrival: .now.addingTimeInterval(depOffset + 2 * 3600),
            status: status, delayMinutes: delay, departureGate: nil, progress: 0)
    }

    /// Regression: the widget's isUpcoming had the same dead zone the app
    /// model did — a delayed flight past its original scheduled time (not yet
    /// confirmed departed) vanished from the widget right at boarding time.
    func testWidgetUpcomingSurvivesPassingScheduledTime() {
        XCTAssertTrue(widgetFlight(status: "scheduled", depOffset: -900, delay: 20).isUpcoming)
    }

    func testWidgetUpcomingIncludesBoarding() {
        XCTAssertTrue(widgetFlight(status: "boarding", depOffset: 600).isUpcoming)
    }

    func testWidgetEffectiveDepartureReflectsDelay() {
        let f = widgetFlight(status: "scheduled", depOffset: 3600, delay: 30)
        XCTAssertEqual(f.effectiveDeparture.timeIntervalSince(f.scheduledDeparture), 1800, accuracy: 1)
    }

    // MARK: - phase(at:) — the clock-based logic that flips the widget's
    // layout pre → during → after WITHOUT the app running (the stored status
    // string can't change while the app is closed, so the phase must come
    // from the timeline entry's own date).

    func testPhaseUpcomingBeforeDeparture() {
        let f = widgetFlight(status: "scheduled", depOffset: 3600)
        XCTAssertEqual(f.phase(at: .now), .upcoming)
    }

    func testPhaseFlipsToInFlightAtDepartureDespiteStaleStatus() {
        let f = widgetFlight(status: "scheduled", depOffset: 3600)
        XCTAssertEqual(f.phase(at: f.effectiveDeparture.addingTimeInterval(60)), .inFlight)
    }

    func testPhaseFlipsToLandedAtArrivalDespiteStaleStatus() {
        let f = widgetFlight(status: "scheduled", depOffset: 3600)
        XCTAssertEqual(f.phase(at: f.effectiveArrival.addingTimeInterval(60)), .landed)
    }

    func testPhaseDelayShiftsTheFlipMoment() {
        let f = widgetFlight(status: "scheduled", depOffset: 3600, delay: 30)
        // At scheduled departure the delayed flight hasn't left yet.
        XCTAssertEqual(f.phase(at: f.scheduledDeparture.addingTimeInterval(60)), .upcoming)
        XCTAssertEqual(f.phase(at: f.effectiveDeparture.addingTimeInterval(60)), .inFlight)
    }

    func testPhaseTrustsExplicitActiveStatus() {
        let f = widgetFlight(status: "active", depOffset: 600)   // departed early per API
        XCTAssertEqual(f.phase(at: .now), .inFlight)
    }

    func testPhaseTrustsExplicitLandedStatus() {
        let f = widgetFlight(status: "landed", depOffset: -3600)
        XCTAssertEqual(f.phase(at: .now), .landed)
    }

    func testStatusTextShowsArcPredictionWhenAheadOfAirline() {
        var f = widgetFlight(status: "scheduled", depOffset: 3600)
        f.predictedDelayMinutes = 32
        XCTAssertEqual(f.statusText(phase: .upcoming), "Arc +32m")
        XCTAssertTrue(f.showsPrediction)
    }

    func testStatusTextKeepsAirlineDelayWhenPredictionIsNotMeaningfullyAhead() {
        var f = widgetFlight(status: "scheduled", depOffset: 3600, delay: 20)
        f.predictedDelayMinutes = 25
        XCTAssertEqual(f.statusText(phase: .upcoming), "Delayed 20m")
        XCTAssertFalse(f.showsPrediction)
    }

    /// Regression: `phase(at:)` routes a cancelled flight to `.landed` (there is
    /// no arrival to count down to), so every label had to be taught about it —
    /// the widget used to tell you a cancelled flight was "Arriving soon".
    func testCancelledFlightNeverReadsAsArriving() {
        let f = widgetFlight(status: "cancelled", depOffset: 3600)
        XCTAssertEqual(f.phase(at: .now), .landed)
        XCTAssertTrue(f.isDisrupted)
        XCTAssertEqual(f.statusText(phase: f.phase(at: .now)), "Cancelled")
        XCTAssertEqual(f.terminalLabel, "Cancelled")
    }

    func testDivertedFlightSaysSo() {
        let f = widgetFlight(status: "diverted", depOffset: -3600)
        XCTAssertEqual(f.statusText(phase: f.phase(at: .now)), "Diverted")
        XCTAssertEqual(f.terminalLabel, "Diverted")
    }

    /// The medium widget builds its rows from "live" plus "just landed". Those
    /// sets overlap — the stored status only changes when the app runs — so the
    /// rows must be deduped by id or ForEach gets two rows claiming one identity.
    func testLiveAndJustLandedRowSetsOverlap() {
        let overdue = widgetFlight(status: "active", depOffset: -5 * 3600)
        XCTAssertTrue(overdue.isActive)
        XCTAssertEqual(overdue.phase(at: .now), .landed)

        let stale = widgetFlight(status: "scheduled", depOffset: -6 * 3600)
        XCTAssertTrue(stale.isUpcoming)
        XCTAssertEqual(stale.phase(at: .now), .landed)
    }

    func testTerminalLabelDistinguishesLandedFromStillArriving() {
        XCTAssertEqual(widgetFlight(status: "landed", depOffset: -3600).terminalLabel, "Landed")
        XCTAssertEqual(widgetFlight(status: "active", depOffset: -3600).terminalLabel, "Arriving")
        XCTAssertFalse(widgetFlight(status: "active", depOffset: -3600).isDisrupted)
    }

    func testDecodesSnapshotWrittenBeforePredictedDelayMinutesExisted() throws {
        let original = widgetFlight(status: "scheduled", depOffset: 3600)
        let data = try JSONEncoder().encode(original)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "predictedDelayMinutes")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(WidgetFlight.self, from: stripped)
        XCTAssertEqual(decoded.predictedDelayMinutes, 0)
        XCTAssertFalse(decoded.showsPrediction)
        XCTAssertEqual(decoded.flightNumber, "LX1413")
    }

    /// A snapshot that fails to decode isn't a missing field — it's a blank
    /// widget the user can't fix, so every added key needs this.
    func testDecodesSnapshotWrittenBeforeModeAndTierExisted() throws {
        let data = try JSONEncoder().encode(widgetFlight(status: "scheduled", depOffset: 3600))
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "mode")
        obj.removeValue(forKey: "dataTier")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(WidgetFlight.self, from: stripped)
        XCTAssertEqual(decoded.mode, .air)
        XCTAssertEqual(decoded.dataTier, .live)
        XCTAssertTrue(decoded.reportsPunctuality)
        XCTAssertEqual(decoded.statusText(phase: .upcoming), "On Time")
    }

    func testModeAndTierSurviveTheRoundTrip() throws {
        var sailing = widgetFlight(status: "scheduled", depOffset: 3600)
        sailing.mode = .sea
        sailing.dataTier = .scheduled
        let decoded = try JSONDecoder().decode(
            WidgetFlight.self, from: JSONEncoder().encode(sailing))
        XCTAssertEqual(decoded.mode, .sea)
        XCTAssertEqual(decoded.dataTier, .scheduled)
        XCTAssertEqual(decoded.statusText(phase: .upcoming), "Timetable")
    }
}

// MARK: - Tense honesty (what WAS, what IS, what WILL BE)

@MainActor
final class FlightTenseTests: XCTestCase {
    private func flight(depIn: TimeInterval, durationH: Double = 2, delay: Int = 0,
                        status: FlightStatus = .scheduled, tier: DataTier = .live) -> Flight {
        let f = Flight(flightNumber: "LX1413", date: .now.addingTimeInterval(depIn))
        f.scheduledArrival = f.scheduledDeparture.addingTimeInterval(durationH * 3600)
        f.delayMinutes = delay
        f.status = status
        f.dataTier = tier
        f.departureIATA = "BEG"; f.arrivalIATA = "ZRH"
        return f
    }

    /// A delayed flight counts down to when it actually leaves, and keeps its
    /// status label past the printed time instead of falling to a bare date.
    func testDelayedFlightCountsDownToEffectiveDeparture() {
        let f = flight(depIn: -30 * 60, delay: 90)   // printed 30m ago, leaves in 60m
        XCTAssertNotNil(f.countdown)
        XCTAssertEqual(f.countdown?.unit, "MIN")
        XCTAssertTrue(f.isSoon)
        XCTAssertEqual(f.cardTopRight, "Departs Delayed 90m")
    }

    /// Past its (delayed) departure and still "scheduled": nobody confirmed
    /// it left, so Arc doesn't either — no countdown, no date, no green.
    func testUnconfirmedDepartureSaysSo() {
        let f = flight(depIn: -25 * 60)
        XCTAssertTrue(f.isDepartureUnconfirmed)
        XCTAssertNil(f.countdown)
        XCTAssertEqual(f.cardTopRight, "Not yet departed")
        XCTAssertEqual(f.bannerHeadline, "Departure not yet confirmed")
        XCTAssertNotEqual(f.bannerColor, ArcTheme.onTime)
        XCTAssertFalse(f.departureRelText.hasSuffix(" ago"))
    }

    /// Flipped to active by the clock a few minutes ago: "Departing", not
    /// "In Air" on faith. Once the source reports a real departure, In Air.
    func testFreshlyActiveHedgesThenCommits() {
        let f = flight(depIn: -5 * 60, status: .active)
        XCTAssertEqual(f.statusText, "Departing")
        XCTAssertEqual(f.bannerHeadline, "Departing")
        f.actualDeparture = f.scheduledDeparture
        XCTAssertEqual(f.statusText, "In Air")
        let later = flight(depIn: -40 * 60, status: .active)
        XCTAssertEqual(later.statusText, "In Air")
    }

    /// The hedge speaks with ONE voice. While the banner says "Departing"
    /// (clock-flipped, unconfirmed) the endpoint row must not simultaneously
    /// assert "Departed 15m ago" in on-time green — the exact contradiction
    /// a lock screen saying "Waiting for takeoff confirmation" sat next to.
    func testDepartingHedgeDoesNotClaimDepartedAsFact() {
        let f = flight(depIn: -15 * 60, status: .active)
        XCTAssertTrue(f.isDepartingUnconfirmed)
        XCTAssertFalse(f.departureRelText.hasSuffix(" ago"))
        XCTAssertTrue(f.departureRelText.hasSuffix("past schedule"))
        XCTAssertNotEqual(f.bannerColor, ArcTheme.onTime)
        XCTAssertNotEqual(f.cardTopRightColor, ArcTheme.onTime)
        // A reported take-off ends the hedge: now "Departed … ago" is a fact.
        f.actualDeparture = f.scheduledDeparture
        XCTAssertFalse(f.isDepartingUnconfirmed)
        XCTAssertTrue(f.departureRelText.hasSuffix(" ago"))
        // And so does the hedge window simply running out.
        let committed = flight(depIn: -40 * 60, status: .active)
        XCTAssertFalse(committed.isDepartingUnconfirmed)
        XCTAssertTrue(committed.departureRelText.hasSuffix(" ago"))
    }

    /// An active flight past its ETA is not "Arrived" until the source says so.
    func testArrivalNotClaimedFromClock() {
        let f = flight(depIn: -4 * 3600, status: .active)   // ETA was 2h ago
        XCTAssertEqual(f.arrivalRelText, "Arrival not yet confirmed")
        XCTAssertEqual(f.bannerHeadline, "Arrival not yet confirmed")
        f.status = .landed
        XCTAssertEqual(f.arrivalRelText, "Arrived")
    }

    /// A habit is not an assignment: the usual-gate guess shows only while
    /// the airline hasn't gated the flight, and a filed gate replaces it.
    func testPredictedGateYieldsToRealGate() {
        let f = flight(depIn: 5 * 3600)
        f.predictedDepartureGate = "B39"
        XCTAssertTrue(f.showsPredictedGate)
        f.departureGate = "A54"
        XCTAssertFalse(f.showsPredictedGate)
        f.departureGate = nil
        f.status = .active
        XCTAssertFalse(f.showsPredictedGate, "once underway there is no walk to plan")
        f.status = .scheduled
        f.mode = .rail
        XCTAssertFalse(f.showsPredictedGate, "the flywheel only knows airports")
    }

    /// What happened beats what was predicted.
    func testActualArrivalBeatsStaleEstimate() {
        let f = flight(depIn: -4 * 3600, status: .landed)
        f.estimatedArrival = f.scheduledArrival.addingTimeInterval(40 * 60)
        f.actualArrival = f.scheduledArrival.addingTimeInterval(5 * 60)
        XCTAssertEqual(f.effectiveArrival, f.actualArrival)
    }

    /// The 30-minute grace measures from the arrival the app believes in —
    /// a delayed landing marked by the clock (no actualArrival) still gets it.
    func testRecentlyLandedGraceSurvivesDelayAndEarlyArrival() {
        let late = flight(depIn: -3 * 3600, delay: 45, status: .landed)   // eff. arrival 15m ago
        XCTAssertTrue(late.isRecentlyLanded)
        let early = flight(depIn: -110 * 60, status: .landed)             // scheduled arrival in 10m
        early.estimatedArrival = Date.now.addingTimeInterval(-5 * 60)
        XCTAssertTrue(early.isRecentlyLanded)
    }

    func testCancelledAndDivertedNeverReadOnTime() {
        for status in [FlightStatus.cancelled, .diverted] {
            let f = flight(depIn: 3600, status: status)
            XCTAssertNotEqual(f.departureStatusText, "On Time", "\(status)")
            XCTAssertNotEqual(f.arrivalStatusText, "On Time", "\(status)")
            XCTAssertEqual(f.bannerColor, ArcTheme.late, "\(status)")
        }
        XCTAssertEqual(flight(depIn: 3600, status: .diverted).bannerHeadline, "Diverted")
    }

    /// The freshness pill says "Live" only for a source that is.
    func testFreshnessNeverSaysLiveForATimetable() {
        let ferry = flight(depIn: 3600, tier: .scheduled)
        ferry.lastStatusUpdate = .now
        XCTAssertFalse(ferry.dataFreshnessText.hasPrefix("Live"))
        XCTAssertNotEqual(ferry.dataFreshnessShort, "Live")
        let live = flight(depIn: 3600, tier: .live)
        live.lastStatusUpdate = .now
        XCTAssertTrue(live.dataFreshnessText.hasPrefix("Live"))
    }
}

// MARK: - Gate prediction confidence

final class GatePredictionTests: XCTestCase {
    private typealias P = FlightAPIClient.GatePrediction

    /// The one confidence bar every consumer shares: three sightings and half
    /// agreement, or the "usual gate" is noise dressed as knowledge.
    func testConfidenceBar() {
        XCTAssertTrue(P(gate: "B39", terminal: "1", agreeing: 3, samples: 4, confidence: 0.75).isConfident)
        XCTAssertFalse(P(gate: "B39", terminal: nil, agreeing: 2, samples: 2, confidence: 1.0).isConfident,
                       "two sightings prove nothing, however unanimous")
        XCTAssertFalse(P(gate: "B39", terminal: nil, agreeing: 2, samples: 5, confidence: 0.4).isConfident,
                       "a gate seen twice in five is not a pattern")
        XCTAssertFalse(P(gate: nil, terminal: "1", agreeing: 0, samples: 0, confidence: 0).isConfident)
        XCTAssertFalse(P(gate: "", terminal: nil, agreeing: 3, samples: 3, confidence: 1.0).isConfident)
    }
}
