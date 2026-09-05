import XCTest
import CoreLocation
import MapKit
@testable import Arc

/// The add / import moment: a route that draws itself onto the map over about
/// a second, in the geometry its own mode actually travels.
@MainActor
final class RouteRevealTests: XCTestCase {
    private let zrh = CLLocationCoordinate2D(latitude: 47.4647, longitude: 8.5492)
    private let jfk = CLLocationCoordinate2D(latitude: 40.6413, longitude: -73.7781)
    private let piraeus = CLLocationCoordinate2D(latitude: 37.9475, longitude: 23.6296)
    private let santorini = CLLocationCoordinate2D(latitude: 36.3932, longitude: 25.4615)
    // Deliberately absurd as a train, and deliberately long: a great circle
    // and a rhumb line between these two disagree by degrees, so a test can
    // tell which one was drawn.
    private let lisbon = CLLocationCoordinate2D(latitude: 38.7742, longitude: -9.1342)
    private let moscow = CLLocationCoordinate2D(latitude: 55.9726, longitude: 37.4146)

    private func trip(_ mode: TripMode,
                      from dep: CLLocationCoordinate2D,
                      to arr: CLLocationCoordinate2D,
                      routePath: [[Double]]? = nil) -> Flight {
        let departure = Date.now.addingTimeInterval(3600)
        let flight = Flight(flightNumber: "TEST1", date: departure)
        flight.mode = mode
        flight.scheduledDeparture = departure
        flight.scheduledArrival = departure.addingTimeInterval(2 * 3600)
        flight.departureLat = dep.latitude; flight.departureLon = dep.longitude
        flight.arrivalLat = arr.latitude; flight.arrivalLon = arr.longitude
        if let routePath { flight.routePathData = try? JSONEncoder().encode(routePath) }
        return flight
    }

    /// Wait for the draw to begin. It starts on the next turn of the main
    /// actor, or after a rail leg's hold — polled rather than slept through,
    /// so a loaded machine doesn't sleep straight past the one second the
    /// reveal exists for.
    private func awaitReveals(_ controller: MapController,
                              count: Int = 1,
                              polls: Int = 70) async -> [RouteReveal] {
        for _ in 0..<polls {
            if controller.routeReveals.count >= count { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return controller.routeReveals
    }

    // MARK: - Geometry per mode

    func testAirDrawsTheGreatCircleItFlies() {
        let path = RouteReveal.geometry(for: trip(.air, from: zrh, to: jfk))
        let expected = GeoMath.greatCircle(from: zrh, to: jfk)
        XCTAssertEqual(path.count, expected.count)
        XCTAssertEqual(path[path.count / 2].latitude,
                       expected[expected.count / 2].latitude, accuracy: 0.001)
        // And it really is an arc: the midpoint bows well north of the
        // straight-line average of the two endpoint latitudes (~44).
        XCTAssertGreaterThan(path[path.count / 2].latitude, 47)
    }

    func testSeaDrawsTheRhumbLineAChartDraws() {
        let path = RouteReveal.geometry(for: trip(.sea, from: piraeus, to: santorini))
        let expected = GeoMath.rhumbLine(from: piraeus, to: santorini)
        XCTAssertEqual(path.count, expected.count)
        XCTAssertEqual(path[path.count / 2].longitude,
                       expected[expected.count / 2].longitude, accuracy: 0.001)
    }

    /// The rule the whole feature hangs on: on this map an arc means "flight",
    /// so a train that lost its routed path gets a straight ground segment and
    /// never borrows a flight's geometry.
    func testRailWithoutARoutedPathNeverDrawsAFlightArc() {
        let path = RouteReveal.geometry(for: trip(.rail, from: lisbon, to: moscow))
        let ground = GeoMath.rhumbLine(from: lisbon, to: moscow)
        let arc = GeoMath.greatCircle(from: lisbon, to: moscow)
        XCTAssertEqual(path.count, ground.count)
        XCTAssertEqual(path[path.count / 2].latitude,
                       ground[ground.count / 2].latitude, accuracy: 0.001)
        XCTAssertEqual(path[path.count / 2].longitude,
                       ground[ground.count / 2].longitude, accuracy: 0.001)
        // Not merely "resampled differently" — a different line entirely.
        XCTAssertGreaterThan(abs(path[path.count / 2].longitude - arc[arc.count / 2].longitude), 1)
    }

    /// `RouteStyle` is where the settled map gets the same answer, so the
    /// static line and the reveal can't disagree about what a train is.
    func testRouteStyleKeepsTheArcForAirAlone() {
        for mode in [TripMode.rail, .sea] {
            let planned = ArcMapView.RouteStyle(mode: mode).path(from: lisbon, to: moscow)
            let ground = GeoMath.rhumbLine(from: lisbon, to: moscow)
            XCTAssertEqual(planned.count, ground.count, "\(mode) borrowed a flight's geometry")
            XCTAssertEqual(planned[planned.count / 2].longitude,
                           ground[ground.count / 2].longitude, accuracy: 0.001)
        }
        let air = ArcMapView.RouteStyle(mode: .air).path(from: lisbon, to: moscow)
        XCTAssertEqual(air.count, GeoMath.greatCircle(from: lisbon, to: moscow).count)
    }

    func testRailWithARoutedPathDrawsTheRealRails() {
        let rails: [[Double]] = [[48.14, 11.56], [49.45, 11.08], [50.11, 8.68],
                                 [52.52, 13.40], [53.55, 10.00]]
        let path = RouteReveal.geometry(for: trip(.rail, from: lisbon, to: moscow, routePath: rails))
        XCTAssertEqual(path.count, rails.count)
        XCTAssertEqual(path[3].latitude, 52.52, accuracy: 0.0001)
        XCTAssertEqual(path[3].longitude, 13.40, accuracy: 0.0001)
    }

    func testATripWithNoCoordinatesIsNotDrawable() {
        // A hand-typed train: no station table to resolve, so no coordinates.
        let typed = trip(.rail, from: .init(latitude: 0, longitude: 0),
                         to: .init(latitude: 0, longitude: 0))
        XCTAssertFalse(RouteReveal.isDrawable(typed))
        XCTAssertTrue(RouteReveal.geometry(for: typed).isEmpty)
    }

    // MARK: - The hold

    func testOnlyARailLegMissingItsRailsHolds() {
        XCTAssertEqual(RouteReveal.hold(for: trip(.rail, from: lisbon, to: moscow)),
                       RouteReveal.railHold, accuracy: 0.0001)
        XCTAssertEqual(RouteReveal.hold(for: trip(.air, from: zrh, to: jfk)), 0)
        XCTAssertEqual(RouteReveal.hold(for: trip(.sea, from: piraeus, to: santorini)), 0)
        let routed = trip(.rail, from: lisbon, to: moscow,
                          routePath: [[48.14, 11.56], [50.11, 8.68], [53.55, 10.00]])
        XCTAssertEqual(RouteReveal.hold(for: routed), 0)
    }

    // MARK: - Growing the line

    func testTheLineGrowsFromNothingToTheWholeRoute() {
        let path = GeoMath.greatCircle(from: zrh, to: jfk)
        XCTAssertLessThan(RouteReveal.drawn(path, to: 0).count, 2, "nothing is drawn at rest")
        XCTAssertEqual(RouteReveal.drawn(path, to: 1).count, path.count)
        XCTAssertEqual(RouteReveal.drawn(path, to: 2).count, path.count, "clamped past the end")

        var previous = 0
        for step in 0...20 {
            let drawn = RouteReveal.drawn(path, to: Double(step) / 20)
            XCTAssertGreaterThanOrEqual(drawn.count, previous, "the line shrank mid-draw")
            previous = drawn.count
        }
    }

    /// Every point behind the tip is the route's own, so the growing line lies
    /// exactly on the finished one rather than approximating it.
    func testWhatIsDrawnSitsOnTheFinishedRoute() {
        let path = GeoMath.greatCircle(from: zrh, to: jfk)
        // Halfway INTO a sample interval, so there is a tip to check at all.
        let sample = 1.0 / Double(path.count - 1)
        let drawn = RouteReveal.drawn(path, to: sample * 32.5)
        XCTAssertGreaterThan(drawn.count, 2)
        for (index, point) in drawn.dropLast().enumerated() {
            XCTAssertEqual(point.latitude, path[index].latitude, accuracy: 0.0001)
            XCTAssertEqual(point.longitude, path[index].longitude, accuracy: 0.0001)
        }
        // The tip is between two samples, not snapped to one of them.
        let tip = drawn[drawn.count - 1]
        XCTAssertGreaterThan(tip.longitude, path[drawn.count - 1].longitude)
        XCTAssertLessThan(tip.longitude, path[drawn.count - 2].longitude)
    }

    /// A 64-sample arc over a second is barely one sample per frame, so
    /// without an interpolated tip the head visibly steps. Two progresses
    /// inside the same sample interval must still move it.
    func testTheTipMovesBetweenSamples() {
        let path = GeoMath.greatCircle(from: zrh, to: jfk)
        let sample = 1.0 / Double(path.count - 1)
        let early = RouteReveal.drawn(path, to: sample * 10.2)
        let late = RouteReveal.drawn(path, to: sample * 10.8)
        XCTAssertEqual(early.count, late.count, "these should share a sample interval")
        XCTAssertNotEqual(early[early.count - 1].longitude,
                          late[late.count - 1].longitude,
                          "the tip snapped to a sample — the draw would step")
    }

    /// A route crossing the date line must grow ACROSS it, not unwind the
    /// whole globe for a frame.
    func testTheTipTakesTheShortWayRoundTheDateLine() {
        let path = [CLLocationCoordinate2D(latitude: 0, longitude: 179.5),
                    CLLocationCoordinate2D(latitude: 0, longitude: -179.5)]
        let tip = RouteReveal.drawn(path, to: 0.5)[1]
        XCTAssertEqual(abs(tip.longitude), 180, accuracy: 0.0001)
    }

    func testEasingIsClampedAndCoversTheWholeRoute() {
        XCTAssertEqual(RouteReveal.eased(0), 0, accuracy: 0.0001)
        XCTAssertEqual(RouteReveal.eased(1), 1, accuracy: 0.0001)
        XCTAssertEqual(RouteReveal.eased(0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(RouteReveal.eased(-3), 0, accuracy: 0.0001)
        XCTAssertEqual(RouteReveal.eased(9), 1, accuracy: 0.0001)
        var previous = -1.0
        for step in 0...20 {
            let value = RouteReveal.eased(Double(step) / 20)
            XCTAssertGreaterThan(value, previous - 0.0001)
            previous = value
        }
    }

    // MARK: - The beat itself

    func testAddingATripFitsTheCameraAndDrawsTheRoute() async {
        let controller = MapController()
        controller.revealRoutes(for: [trip(.air, from: zrh, to: jfk)])

        guard let reveal = await awaitReveals(controller).first else {
            return XCTFail("nothing started drawing")
        }
        XCTAssertFalse(reveal.isComplete, "the whole route was already drawn")

        guard let region = controller.position.region else { return XCTFail("camera didn't move") }
        // The whole route is framed, and above the sheet that owns the bottom
        // half of every page.
        XCTAssertGreaterThanOrEqual(region.span.longitudeDelta,
                                    abs(jfk.longitude - zrh.longitude))
        XCTAssertLessThan(region.center.latitude, min(zrh.latitude, jfk.latitude))

        try? await Task.sleep(for: .milliseconds(80))
        // A cleared list means it reached the end, which is the growth this
        // is asking about — what would fail here is a line that sat still.
        XCTAssertGreaterThan(controller.routeReveals.first?.progress ?? 1, reveal.progress,
                             "the line stopped growing")

        // Handed back to the settled map when it's done, which is what keeps
        // the reveal from owning the line — and the camera — for the rest of
        // the session.
        try? await Task.sleep(for: .seconds(RouteReveal.drawDuration + 0.5))
        XCTAssertTrue(controller.routeReveals.isEmpty)
        XCTAssertFalse(controller.isRevealingRoutes)
    }

    func testABatchGetsOneCoordinatedMoment() async {
        let controller = MapController()
        controller.revealRoutes(for: [trip(.air, from: zrh, to: jfk),
                                      trip(.sea, from: piraeus, to: santorini)])

        let reveals = await awaitReveals(controller, count: 2)
        XCTAssertEqual(reveals.count, 2)
        // Both legs draw at the same progress: one beat, not two races.
        XCTAssertEqual(reveals[0].progress, reveals[1].progress, accuracy: 0.0001)
        // …and one camera move that frames both of them.
        guard let region = controller.position.region else { return XCTFail("camera didn't move") }
        XCTAssertGreaterThanOrEqual(region.span.longitudeDelta,
                                    abs(jfk.longitude - santorini.longitude))
    }

    /// The rail hold, end to end: nothing is drawn for the first beat, and
    /// what follows is a ground segment.
    func testARailLegWithoutRailsWaitsABeatThenDrawsTheGround() async {
        let controller = MapController()
        controller.revealRoutes(for: [trip(.rail, from: lisbon, to: moscow)])

        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(controller.routeReveals.isEmpty, "the train drew before its hold was up")
        // …but the camera is already claimed, so the refit that the same save
        // triggers can't take the frame during the hold.
        XCTAssertTrue(controller.isRevealingRoutes)

        guard let reveal = await awaitReveals(controller).first else {
            return XCTFail("the train never drew at all")
        }
        let ground = GeoMath.rhumbLine(from: lisbon, to: moscow)
        XCTAssertEqual(reveal.path.count, ground.count)
        XCTAssertEqual(reveal.path[reveal.path.count / 2].longitude,
                       ground[ground.count / 2].longitude, accuracy: 0.001)
    }

    func testATripTheMapWontDrawGetsNoReveal() async {
        let controller = MapController()
        controller.revealRoutes(for: [trip(.rail, from: .init(latitude: 0, longitude: 0),
                                           to: .init(latitude: 0, longitude: 0))])
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(controller.routeReveals.isEmpty)
        // Nothing to draw also means nothing to hold the camera for: the
        // normal refit must still get to frame the list.
        XCTAssertFalse(controller.isRevealingRoutes)
    }

    /// A second add mid-draw belongs to the newer trip — and the older one
    /// goes straight back to the settled map rather than freezing part-drawn.
    func testASecondAddTakesOverTheMoment() async {
        let controller = MapController()
        let first = trip(.air, from: zrh, to: jfk)
        controller.revealRoutes(for: [first])
        let started = await awaitReveals(controller)
        XCTAssertEqual(started.first?.id, first.id)

        let second = trip(.sea, from: piraeus, to: santorini)
        controller.revealRoutes(for: [second])
        XCTAssertTrue(controller.routeReveals.isEmpty, "the first route stayed part-drawn")

        let reveals = await awaitReveals(controller)
        XCTAssertEqual(reveals.count, 1)
        XCTAssertEqual(reveals.first?.id, second.id)
    }
}
