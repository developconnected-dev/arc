import test from "node:test";
import assert from "node:assert/strict";
import {
  zonedNaiveToUTC, displayCode, dedupeStopTimes, mapRailTrip,
  railServiceKey, matchesService, mapFerryItinerary, positionSourceFor,
  disruptionNoteFor, isoCountryCode,
} from "../src/transit.ts";

// ── ferry time zones ──────────────────────────────────────────────────────
//
// Every payload below is what mcp.ferryhopper.com actually returned, `Z` and
// all. The `Z` is a lie: these are local wall clocks at their own port.

test("a Greek sailing is read in Athens time, not taken as UTC", () => {
  // Blue Star Delos leaves Piraeus at 07:25 local. Athens is UTC+3 in August,
  // so believing the `Z` would put it on the map three hours early.
  assert.equal(
    zonedNaiveToUTC("2026-08-12T07:25:00Z", "Europe/Athens"),
    "2026-08-12T04:25:00.000Z");
});

test("a crossing between two zones keeps its real duration", () => {
  // Algeciras (Spain, UTC+2) 00:01 → Tanger Med (Morocco, UTC+1) 00:31. Taken
  // at face value that is a 30-minute hop; the crossing is really 1h30. This is
  // the case that proves a single offset can't work — each end needs its own.
  const dep = zonedNaiveToUTC("2026-08-15T00:01:00Z", "Europe/Madrid");
  const arr = zonedNaiveToUTC("2026-08-15T00:31:00Z", "Africa/Casablanca");
  assert.equal((Date.parse(arr) - Date.parse(dep)) / 60_000, 90);
});

test("a winter sailing uses the winter offset", () => {
  // Athens is UTC+2 in January, +3 in August. A fixed offset gets one wrong.
  assert.equal(
    zonedNaiveToUTC("2026-01-12T07:25:00Z", "Europe/Athens"),
    "2026-01-12T05:25:00.000Z");
});

test("unparseable or zone-less times degrade instead of throwing", () => {
  assert.equal(zonedNaiveToUTC("", "Europe/Athens"), "");
  assert.equal(zonedNaiveToUTC(null, "Europe/Athens"), "");
  assert.equal(zonedNaiveToUTC("2026-08-12T07:25:00Z", ""), "2026-08-12T07:25:00.000Z");
});

// ── display codes ─────────────────────────────────────────────────────────
//
// These land in the fixed-width chips in the list row, the home widget and the
// Dynamic Island, so length is a hard constraint, not a preference.

test("station and port names collapse to three letters", () => {
  assert.equal(displayCode("PIRAEUS"), "PIR");
  assert.equal(displayCode("THIRA (SANTORINI)"), "THI");
  assert.equal(displayCode("Berlin Hbf"), "BER");
  assert.equal(displayCode("S+U Berlin Hauptbahnhof"), "BER");
  assert.equal(displayCode("Zürich HB"), "ZUR");
  assert.equal(displayCode("München Hbf"), "MUN");
  assert.equal(displayCode("Basel SBB"), "BAS");
  assert.equal(displayCode("Amsterdam Centraal"), "AMS");
  assert.equal(displayCode("Frankfurt (Main) Hauptbahnhof"), "FRA");
});

test("naming the kind of place doesn't change the code", () => {
  // Feeds disagree on how much station furniture to include in a name; a code
  // that moved with it would make one station look like two.
  assert.equal(displayCode("Berlin Hbf"), displayCode("Berlin Hauptbahnhof"));
  assert.equal(displayCode("Zürich HB"), displayCode("Zürich"));
  assert.equal(displayCode("PIRAEUS"), displayCode("PIRAEUS PORT"));
});

test("accents don't change the code", () => {
  assert.equal(displayCode("Zürich"), displayCode("Zurich"));
  assert.equal(displayCode("München"), displayCode("Munchen"));
});

// Not guaranteed, and deliberately so: an ASCII transliteration in the source
// ("Muenchen") yields MUE, not MUN. Codes are display-only and nothing is ever
// looked up by them, so the cost is cosmetic — whereas unpicking ue/oe/ae back
// into umlauts would mangle names that legitimately contain those letters.

test("a name too short to shorten borrows initials", () => {
  assert.equal(displayCode("AG.MARINA (LEROS)"), "AGM");
});

test("no name and no letters still yields something renderable", () => {
  assert.equal(displayCode(""), "");
  assert.equal(displayCode("!!!"), "!!!");
  assert.ok(displayCode("Порт").length <= 3);
});

test("every code fits the chip", () => {
  for (const n of ["PIRAEUS", "THIRA (SANTORINI)", "S+U Berlin Hauptbahnhof",
                   "Frankfurt (Main) Hauptbahnhof", "AG.MARINA (LEROS)",
                   "Lutherstadt Wittenberg Hbf", "AEGINA (ALL PORTS)"]) {
    assert.ok(displayCode(n).length <= 3, `${n} → ${displayCode(n)} too long for the row`);
  }
});

// ── overlapping feeds ─────────────────────────────────────────────────────

/// Berlin Hbf's real board: RE3 arrives twice, from de-DELFI and de-VBB. Only
/// the DELFI copy carries realtime.
const berlinBoard = [
  { routeShortName: "RE3 (3305)", headsign: "Lutherstadt Wittenberg Hbf", realTime: true,
    place: { scheduledDeparture: "2026-08-05T08:40:00Z", departure: "2026-08-05T08:38:00Z" } },
  { routeShortName: "RE3", headsign: "Lutherstadt Wittenberg Hbf", realTime: false,
    place: { scheduledDeparture: "2026-08-05T08:40:00Z", departure: "2026-08-05T08:40:00Z" } },
  { routeShortName: "ICE 507", headsign: "München Hbf", realTime: true,
    place: { scheduledDeparture: "2026-08-05T08:29:00Z", departure: "2026-08-05T08:45:00Z" } },
];

test("the same train from two feeds is offered once", () => {
  const rows = dedupeStopTimes(berlinBoard);
  assert.equal(rows.length, 2, "the user must not pick their train from a list containing it twice");
});

test("the copy that carries realtime is the one kept", () => {
  const re3 = dedupeStopTimes(berlinBoard).find(r => r.routeShortName.startsWith("RE3"));
  assert.equal(re3!.realTime, true);
  assert.equal(re3!.place.departure, "2026-08-05T08:38:00Z");
});

test("deduping an empty or missing board is not an error", () => {
  assert.deepEqual(dedupeStopTimes([]), []);
  assert.deepEqual(dedupeStopTimes(undefined as never), []);
});

// ── rail trips ────────────────────────────────────────────────────────────

/// ICE 373 as api.transitous.org returned it: Berlin → Chur, running 3 minutes
/// EARLY through the middle of the run.
const ice373 = {
  legs: [{
    mode: "HIGHSPEED_RAIL", routeShortName: "ICE 373", agencyName: "DB Fernverkehr AG",
    realTime: true, tripId: "20260805_10:37_de-DELFI_3322111449",
    from: { name: "S+U Berlin Hauptbahnhof", stopId: "de-DELFI_de:11000:900003201",
            scheduledDeparture: "2026-08-05T08:37:00Z", departure: "2026-08-05T08:38:00Z", track: "7" },
    intermediateStops: [
      { name: "Frankfurt (Main) Hauptbahnhof", stopId: "de-DELFI_ffm",
        scheduledArrival: "2026-08-05T12:44:00Z", arrival: "2026-08-05T12:41:00Z", track: "7" },
      { name: "Basel SBB", stopId: "ch-otd_basel",
        scheduledArrival: "2026-08-05T15:48:00Z", arrival: "2026-08-05T15:45:00Z" },
      { name: "Zürich HB", stopId: "ch-otd_zurich",
        scheduledArrival: "2026-08-05T17:00:00Z", arrival: "2026-08-05T17:00:00Z" },
    ],
    to: { name: "Chur", stopId: "ch-otd_chur",
          scheduledArrival: "2026-08-05T18:22:00Z", arrival: "2026-08-05T18:22:00Z" },
  }],
};

test("a ticket for part of the run produces that part, not the whole train", () => {
  // ICE 373 ends at Chur. Someone booked to Basel is on the same train and a
  // different leg — mapping the service's own endpoints would put Chur on their card.
  const leg = mapRailTrip(ice373, "de-DELFI_de:11000:900003201", "ch-otd_basel")!;
  assert.equal(leg.dep_iata, "BER");
  assert.equal(leg.arr_iata, "BAS");
  assert.equal(leg.arr_scheduled, "2026-08-05T15:48:00Z");
  assert.equal(leg.flight_number, "ICE 373");
  assert.equal(leg.airline_name, "DB Fernverkehr AG");
});

test("the opaque provider handle is kept apart from the chip text", () => {
  const leg = mapRailTrip(ice373, "de-DELFI_de:11000:900003201", "ch-otd_basel")!;
  assert.equal(leg.dep_stop_id, "de-DELFI_de:11000:900003201");
  assert.ok(String(leg.dep_iata).length <= 3, "the long id must never reach the chip");
});

test("stops can be named as well as identified", () => {
  const leg = mapRailTrip(ice373, "S+U Berlin Hauptbahnhof", "Zürich HB")!;
  assert.equal(leg.arr_iata, "ZUR");
});

test("with no endpoints given, the whole service is the leg", () => {
  const leg = mapRailTrip(ice373)!;
  assert.equal(leg.dep_iata, "BER");
  assert.equal(leg.arr_iata, "CHU");
});

test("a platform is carried in the gate field the widget already renders", () => {
  assert.equal(mapRailTrip(ice373, null, "ch-otd_basel")!.dep_gate, "7");
});

test("each end carries its own zone, so a border crossing reads right", () => {
  // Verified against the live feed: Berlin → Chur comes back Europe/Berlin →
  // Europe/Zurich. Without this the app would have to guess a station's zone
  // from a three-letter display code, which is exactly how ferries went wrong.
  const leg = mapRailTrip(
    { legs: [{ ...ice373.legs[0],
      from: { ...ice373.legs[0].from, tz: "Europe/Berlin" },
      to: { ...ice373.legs[0].to, tz: "Europe/Zurich" } }] })!;
  assert.equal(leg.dep_tz, "Europe/Berlin");
  assert.equal(leg.arr_tz, "Europe/Zurich");
});

test("a platform change is visible as a change, not just a number", () => {
  // `track` alone reads identically whether or not the platform moved. The gap
  // between advertised and current is the whole signal — and it is the thing a
  // traveller standing on the wrong platform most needs.
  const moved = { legs: [{ ...ice373.legs[0],
    from: { ...ice373.legs[0].from, scheduledTrack: "7", track: "12" } }] };
  const leg = mapRailTrip(moved)!;
  assert.equal(leg.dep_gate, "12");
  assert.equal(leg.dep_gate_scheduled, "7");
});

test("a cancelled call outranks every timing detail", () => {
  const killed = { legs: [{ ...ice373.legs[0],
    to: { ...ice373.legs[0].to, cancelled: true } }] };
  assert.equal(mapRailTrip(killed)!.status, "cancelled");
  assert.equal(mapRailTrip(ice373)!.status, "scheduled");
});

test("running early is a negative delay, not an absent one", () => {
  const leg = mapRailTrip(ice373, "de-DELFI_de:11000:900003201", "ch-otd_basel")!;
  assert.equal(leg.delay, 1);                       // left one minute late
  assert.equal(leg.arr_actual, "2026-08-05T15:45:00Z");  // arriving three early
  assert.equal(leg.data_tier, "live");
});

test("a schedule with no realtime is never dressed up as live", () => {
  // Boards more than a few days out come back realTime:false — those must not
  // present as a confirmed on-time running.
  const future = { legs: [{ ...ice373.legs[0], realTime: false }] };
  const leg = mapRailTrip(future)!;
  assert.equal(leg.data_tier, "scheduled");
  assert.equal(leg.delay, 0);
  assert.equal(leg.dep_actual, null);
  assert.equal(leg.arr_actual, null);
});

// ── stop ids move around ──────────────────────────────────────────────────
//
// These forms are exactly what api.transitous.org returned. Asking the board for
// Berlin Hbf as `…900003201` yields trips whose own stop is `…900003200:2:52` —
// a different station number AND a platform tail. Exact-id matching cannot work.

/// ICE 175 as the live trip endpoint returned it, platform tail and all.
const platformed = {
  legs: [{
    routeShortName: "ICE 175", agencyName: "DB Fernverkehr AG", realTime: true,
    from: { name: "S+U Berlin Hauptbahnhof", stopId: "de-DELFI_de:11000:900003200:2:52",
            scheduledDeparture: "2026-08-05T09:28:00Z", departure: "2026-08-05T09:28:00Z", track: "2" },
    intermediateStops: [
      { name: "S Südkreuz Bhf (Berlin)", stopId: "de-DELFI_de:11000:900058101:2:52",
        scheduledArrival: "2026-08-05T09:36:00Z" },
    ],
    to: { name: "Dresden Bahnhof Neustadt", stopId: "de-DELFI_de:14612:16:13:Gleis7",
          scheduledArrival: "2026-08-05T11:30:00Z" },
  }],
};

test("a re-platformed train is still the train you booked", () => {
  // The stored id ends :2:52. Re-platform it and the tail becomes :5:53 — if
  // that broke the match, tracking would die at exactly the moment a platform
  // change happens, which is the thing the user most needs told about.
  const leg = mapRailTrip(platformed, "de-DELFI_de:11000:900003200:5:53")!;
  assert.ok(leg, "a platform change must not orphan the booking");
  assert.equal(leg.dep_iata, "BER");
});

test("a station named rather than numbered still resolves", () => {
  const leg = mapRailTrip(platformed, "S+U Berlin Hauptbahnhof", "Dresden Bahnhof Neustadt")!;
  assert.equal(leg.dep_gate, "2");
  assert.equal(leg.arr_iata, "DRE");
});

test("a genuinely different station is still refused", () => {
  assert.equal(mapRailTrip(platformed, "de-DELFI_de:11000:900058101:2:52", "S+U Berlin Hauptbahnhof"),
    null, "Südkreuz comes after Berlin Hbf, so this leg runs backwards");
  assert.equal(mapRailTrip(platformed, "Hamburg Hbf"), null);
});

test("an alighting stop that is not after boarding is refused", () => {
  assert.equal(mapRailTrip(ice373, "ch-otd_basel", "de-DELFI_de:11000:900003201"), null);
  assert.equal(mapRailTrip({ legs: [] }), null);
});

// ── surviving a feed refresh ──────────────────────────────────────────────

test("a booked train is identified by what its ticket says", () => {
  const leg = mapRailTrip(ice373, "de-DELFI_de:11000:900003201", "ch-otd_basel")!;
  const key = railServiceKey(leg);
  // MOTIS trip ids embed a per-import sequence (…_3322111449) that a feed
  // rebuild renumbers. The key must not depend on it.
  assert.ok(!key.includes("3322111449"));
  assert.ok(key.includes("ICE373"));
});

test("the trip id can be recovered from the board after a refresh", () => {
  const leg = mapRailTrip(ice373, "de-DELFI_de:11000:900003201", "ch-otd_basel")!;
  const key = railServiceKey(leg);
  const board = [
    { routeShortName: "ICE 507", place: { scheduledDeparture: "2026-08-05T08:37:00Z" } },
    { routeShortName: "ICE 373", place: { scheduledDeparture: "2026-08-05T08:37:00Z" },
      tripId: "20260805_10:37_de-DELFI_9999999999" },
  ];
  const found = board.find(st => matchesService(st, key));
  assert.equal(found?.tripId, "20260805_10:37_de-DELFI_9999999999");
});

test("a run number in brackets doesn't defeat re-identification", () => {
  const key = ["db regio", "RE3", "stop", "2026-08-05T08:40"].join("|");
  assert.ok(matchesService(berlinBoard[0], key), "board says 'RE3 (3305)', ticket says 'RE3'");
});

test("a different train at the same minute is not mistaken for yours", () => {
  const key = ["db", "ICE373", "stop", "2026-08-05T08:37"].join("|");
  assert.equal(matchesService(
    { routeShortName: "ICE 507", place: { scheduledDeparture: "2026-08-05T08:37:00Z" } }, key),
    false);
});

// ── ferries ───────────────────────────────────────────────────────────────

/// Exactly what search_trips returned for Piraeus → Santorini.
const blueStar = {
  deepLink: "https://www.ferryhopper.com/en/booking/results?itinerary=PIR,JTR",
  segments: [{
    departurePort: { name: "PIRAEUS" }, arrivalPort: { name: "THIRA (SANTORINI)" },
    departureDateTime: "2026-08-12T07:25:00Z", arrivalDateTime: "2026-08-12T14:50:00Z",
    ownerCompany: { name: "BLUE STAR FERRIES" },
    marketingCompany: { name: "BLUE STAR FERRIES", iconURL: "https://images.ferryhopper.com/ATC-min.png" },
    vessel: { name: "BLUE STAR DELOS" },
  }],
};

const GREEK: Record<string, string> = { PIRAEUS: "Europe/Athens", "THIRA (SANTORINI)": "Europe/Athens" };
const zoneFor = (p: string) => GREEK[p] ?? "";

test("a sailing maps to one leg with the vessel as its identity", () => {
  const [leg] = mapFerryItinerary(blueStar, zoneFor);
  assert.equal(leg.flight_number, "BLUE STAR DELOS");
  assert.equal(leg.airline_name, "BLUE STAR FERRIES");
  assert.equal(leg.dep_iata, "PIR");
  assert.equal(leg.arr_iata, "THI");
  assert.equal(leg.mode, "sea");
});

test("sailing times are corrected before they ever reach the app", () => {
  const [leg] = mapFerryItinerary(blueStar, zoneFor);
  assert.equal(leg.dep_scheduled, "2026-08-12T04:25:00.000Z");
  assert.equal(leg.arr_scheduled, "2026-08-12T11:50:00.000Z");
});

test("the searchable port name survives, because codes don't search", () => {
  // Verified against the live service: "PIR" → no route found; "Piraeus" → 7
  // sailings. The name is the only key that can re-find this crossing.
  const [leg] = mapFerryItinerary(blueStar, zoneFor);
  assert.equal(leg.dep_stop_id, "PIRAEUS");
  assert.equal(leg.arr_stop_id, "THIRA (SANTORINI)");
});

test("a ferry never claims to be on time", () => {
  const [leg] = mapFerryItinerary(blueStar, zoneFor);
  assert.equal(leg.data_tier, "scheduled");
  assert.equal(leg.delay, 0);
  assert.equal(leg.dep_actual, null);
  assert.equal(leg.arr_actual, null);
});

test("an island hop with a change becomes two legs", () => {
  const hop = { segments: [blueStar.segments[0], { ...blueStar.segments[0],
    departurePort: { name: "THIRA (SANTORINI)" }, arrivalPort: { name: "MILOS" },
    vessel: { name: "WORLD CHAMPION JET" } }] };
  const legs = mapFerryItinerary(hop, () => "Europe/Athens");
  assert.equal(legs.length, 2);
  assert.equal(legs[1].flight_number, "WORLD CHAMPION JET");
});

// ── live position routing ─────────────────────────────────────────────────

test("a vessel's MMSI is never sent to the aircraft tracker", () => {
  // Nine digits where OpenSky wants six hex: it would answer for something else
  // or nothing at all, with no error to notice. Dispatch is on mode, never on
  // whichever id happens to be populated.
  const ferry = { mode: "sea", vessel_mmsi: "237012345", aircraft_icao24: "4b1234" };
  assert.deepEqual(positionSourceFor(ferry), { source: "ais", id: "237012345" });
});

test("a flight still tracks by ICAO24", () => {
  assert.deepEqual(positionSourceFor({ mode: "air", aircraft_icao24: "4b1815" }),
    { source: "opensky", id: "4b1815" });
});

test("nothing is tracked when there is nothing to track", () => {
  assert.equal(positionSourceFor({ mode: "rail", flight_number: "ICE 373" }), null);
  assert.equal(positionSourceFor({ mode: "air" }), null);
  assert.equal(positionSourceFor({ mode: "sea", vessel_mmsi: "abc" }), null);
  assert.equal(positionSourceFor({}), null);
});

// ── ferry positions ───────────────────────────────────────────────────────

test("a sailing carries its ports' coordinates when they are known", () => {
  const coords: Record<string, { lat: number; lon: number }> = {
    "PIRAEUS": { lat: 37.94877, lon: 23.63722 },
    "THIRA (SANTORINI)": { lat: 36.39167, lon: 25.42611 },
  };
  const [leg] = mapFerryItinerary(blueStar, zoneFor, undefined, n => coords[n] ?? null);
  assert.equal(leg.dep_lat, 37.94877);
  assert.equal(leg.arr_lon, 25.42611);
});

test("an unresolved port leaves the leg unplottable rather than wrong", () => {
  // The map skips any leg with a zero/absent endpoint. A missing arc is a small
  // gap; a line drawn to a place the ship never visits is a defect the user has
  // to spot for themselves.
  const [leg] = mapFerryItinerary(blueStar, zoneFor, undefined, () => null);
  assert.equal(leg.dep_lat, null);
  assert.equal(leg.arr_lat, null);
});

test("a ferry never claims a routed path", () => {
  // No provider publishes sailing geometry, so the map draws the straight line
  // between ports — and the leg must not pretend otherwise.
  const [leg] = mapFerryItinerary(blueStar, zoneFor);
  assert.equal(leg.route_path, null);
});

// ── ferry disruptions ─────────────────────────────────────────────────────

test("a notice naming the vessel attaches to the sailing", () => {
  const sailing = { flight_number: "BLUE STAR DELOS", airline_name: "Blue Star Ferries",
                    dep_city: "Piraeus", arr_city: "Thira (Santorini)" };
  const note = disruptionNoteFor(sailing, [
    { title: "Sailings of Blue Star Delos delayed due to weather" },
    { title: "Port of Rafina closed to traffic" },
  ]);
  assert.equal(note, "Sailings of Blue Star Delos delayed due to weather");
});

test("a notice naming either port attaches; unrelated notices do not", () => {
  const sailing = { flight_number: "CHAMPION JET 2", airline_name: "SeaJets",
                    dep_city: "Piraeus", arr_city: "Mykonos" };
  const note = disruptionNoteFor(sailing, [
    { message: "Departures from Piraeus suspended until 14:00" },
    { message: "Corfu routes operate normally" },
  ]);
  assert.equal(note, "Departures from Piraeus suspended until 14:00");
});

test("no relevant notice means null, not an empty string", () => {
  const sailing = { flight_number: "X", airline_name: "Y", dep_city: "Naxos", arr_city: "Paros" };
  assert.equal(disruptionNoteFor(sailing, [{ title: "Rhodes port works" }]), null);
  assert.equal(disruptionNoteFor(sailing, []), null);
});

test("country names from the port table resolve to ISO codes", () => {
  assert.equal(isoCountryCode("Greece"), "GR");
  assert.equal(isoCountryCode("United Kingdom (UK)"), "GB");
  assert.equal(isoCountryCode("Atlantis"), null);
});
