import test from "node:test";
import assert from "node:assert/strict";
import { repairLegForRoute, departureFromBoardTime, cachedRowFresh } from "../src/legs.ts";

const ATH_MUC = { dep: "ATH", arr: "MUC" };

/// The real thing: what `mapLeg` produces from AeroDataBox's answer for
/// LH1751 on 2026-09-18 — the flight operating codeshare A31653. The provider
/// serves the departure side as {"airport":{"name":"Athens"},"quality":[]},
/// so there is no IATA code and no departure time.
const degradedDeparture = {
  flight_number: "LH1751",
  dep_iata: "",
  arr_iata: "MUC",
  dep_scheduled: "",
  arr_scheduled: "2026-09-18T12:30:00.000Z",
};

test("keeps a leg whose departure side the provider hollowed out", () => {
  const leg = repairLegForRoute(degradedDeparture, ATH_MUC, null, "2026-09-18");
  assert.ok(leg, "the user's flight must survive verification");
  assert.equal(leg!["dep_iata"], "ATH");
  assert.equal(leg!["arr_iata"], "MUC");
});

test("keeps a leg whose arrival side was hollowed out", () => {
  const leg = repairLegForRoute(
    { flight_number: "LH1757", dep_iata: "ATH", arr_iata: "",
      dep_scheduled: "2026-09-18T03:00:00.000Z", arr_scheduled: "" },
    ATH_MUC, null, "2026-09-18");
  assert.ok(leg);
  assert.equal(leg!["arr_iata"], "MUC");
});

test("still rejects a leg that genuinely flies another route", () => {
  assert.equal(
    repairLegForRoute({ dep_iata: "FRA", arr_iata: "MUC" }, ATH_MUC, null, "2026-09-18"),
    null);
  assert.equal(
    repairLegForRoute({ dep_iata: "ATH", arr_iata: "LHR" }, ATH_MUC, null, "2026-09-18"),
    null);
});

test("rejects a leg with nothing to anchor it to the route", () => {
  assert.equal(
    repairLegForRoute({ dep_iata: "", arr_iata: "" }, ATH_MUC, null, "2026-09-18"),
    null);
});

test("leaves a complete leg untouched, and passes everything through with no route", () => {
  const complete = { dep_iata: "ATH", arr_iata: "MUC", dep_scheduled: "2026-09-18T09:45:00.000Z" };
  assert.deepEqual(repairLegForRoute(complete, ATH_MUC, null, "2026-09-18"), complete);
  assert.deepEqual(repairLegForRoute(degradedDeparture, null, null, "2026-09-18"), degradedDeparture);
});

test("fills a missing departure time from the route's departure board", () => {
  const leg = repairLegForRoute(degradedDeparture, ATH_MUC, "2026-08-07 09:45Z", "2026-09-18");
  assert.equal(leg!["dep_scheduled"], "2026-09-18T09:45:00.000Z");
});

test("board time never lands a departure after its own arrival", () => {
  // Overnight: board says 23:30, arrival is 02:00 the next UTC day.
  assert.equal(
    departureFromBoardTime("2026-08-07 23:30Z", "2026-09-19T02:00:00.000Z", "2026-09-18"),
    "2026-09-18T23:30:00.000Z");
});

test("board time falls back to the queried date when there is no arrival", () => {
  assert.equal(
    departureFromBoardTime("2026-08-07 09:45Z", "", "2026-09-18"),
    "2026-09-18T09:45:00.000Z");
  assert.equal(departureFromBoardTime("", "", "2026-09-18"), "");
});

// ── negative caching ──────────────────────────────────────────────────────
//
// AeroDataBox answers 204/empty for flights it demonstrably has: LH1753 on
// 2026-09-18 came back complete and then, minutes later, empty. So an empty
// answer is a snapshot of the provider's mood, not a fact about the flight,
// and it must expire fast. It used to be held for 48 h on any date more than
// a week out — long enough to hide a real flight for two days.

const ago = (ms: number) => new Date(Date.now() - ms).toISOString();
const farFuture = new Date(Date.now() + 45 * 86_400_000).toISOString();

test("an empty answer goes stale in minutes, even for a far-future date", () => {
  assert.equal(cachedRowFresh({ payload: [], fetched_at: ago(60_000) }), true,
    "still fresh at a minute — that's what collapses a burst");
  assert.equal(cachedRowFresh({ payload: [], fetched_at: ago(6 * 60_000) }), false,
    "a 45-day-out empty answer must NOT outlive its 5-minute window");
});

test("a real far-future schedule is still cached for days", () => {
  const row = {
    payload: [{ dep_scheduled: farFuture, arr_scheduled: farFuture, delay: 0 }],
    fetched_at: ago(6 * 3600_000),
  };
  assert.equal(cachedRowFresh(row), true);
});

test("a missing or payload-less row is never fresh", () => {
  assert.equal(cachedRowFresh(null), false);
  assert.equal(cachedRowFresh(undefined), false);
  assert.equal(cachedRowFresh({ fetched_at: ago(0) }), false);
});

import { shiftLegToDay, completeLeg, isCompleteLeg } from "../src/legs.ts";

// ── weekly schedule inference ──
const sep11 = {
  flight_number: "LH1751", dep_iata: "ATH", arr_iata: "MUC",
  dep_scheduled: "2026-09-11T09:45:00.000Z", arr_scheduled: "2026-09-11T12:30:00.000Z",
  status: "scheduled", delay: 0, dep_gate: "B7", aircraft_registration: "D-AIEA",
  aircraft_icao24: "3C6F00", dep_actual: null, arr_actual: null,
};

test("weekly: shifts a neighbour's leg by whole days and strips everything live", () => {
  const out = shiftLegToDay(sep11, "2026-09-11", "2026-09-18")!;
  assert.equal(out.dep_scheduled, "2026-09-18T09:45:00.000Z");
  assert.equal(out.arr_scheduled, "2026-09-18T12:30:00.000Z");
  assert.equal(out.dep_iata, "ATH"); assert.equal(out.arr_iata, "MUC");
  assert.equal(out.data_tier, "scheduled");
  assert.equal(out.status, "scheduled");
  assert.equal(out.dep_gate, null);
  assert.equal(out.aircraft_registration, null);
  assert.equal(out.schedule_inferred_from, "2026-09-11");
});

test("weekly: shifts backwards too", () => {
  const out = shiftLegToDay(sep11, "2026-09-11", "2026-09-04")!;
  assert.equal(out.dep_scheduled, "2026-09-04T09:45:00.000Z");
});

test("weekly: refuses a hollow template", () => {
  assert.equal(shiftLegToDay({ ...sep11, arr_iata: "" }, "2026-09-11", "2026-09-18"), null);
  assert.equal(isCompleteLeg({ ...sep11, arr_scheduled: "" }), false);
});

test("weekly: completes a hollow day from the shifted neighbour, the day's own fields winning", () => {
  const template = shiftLegToDay(sep11, "2026-09-11", "2026-09-17")!;
  const hollow = { flight_number: "LH1751", dep_iata: "ATH", arr_iata: "",
                   dep_scheduled: "2026-09-17T09:50:00.000Z", arr_scheduled: "", dep_gate: "A12" };
  const out = completeLeg(hollow, template);
  assert.equal(out.arr_iata, "MUC");
  assert.equal(out.arr_scheduled, "2026-09-17T12:30:00.000Z");
  assert.equal(out.dep_scheduled, "2026-09-17T09:50:00.000Z");
  assert.equal(out.dep_gate, "A12");
  assert.equal(out.data_tier, "scheduled");
});

/// AeroDataBox documents `runwayTime` as "Actual / estimated time on the
/// runway" — the same field carries a projection for a flight still at the
/// gate and the wheels-up fact once it moved. The provider's status string is
/// the only thing that tells them apart, so *_actual must be gated on it.
import { confirmedRunwayTime } from "../src/legs.ts";

const NOW = new Date("2026-09-18T10:00:00Z");

test("a delayed flight's projected runway time is not an actual departure", () => {
  assert.equal(confirmedRunwayTime("2026-09-18T10:30:00Z", "Delayed", "dep", NOW), null);
  assert.equal(confirmedRunwayTime("2026-09-18T09:30:00Z", "Boarding", "dep", NOW), null);
  assert.equal(confirmedRunwayTime("2026-09-18T09:30:00Z", "GateClosed", "dep", NOW), null);
  assert.equal(confirmedRunwayTime("2026-09-18T09:30:00Z", "Expected", "dep", NOW), null);
});

test("a departed or en-route flight's runway time is the wheels-up fact", () => {
  for (const s of ["Departed", "EnRoute", "Approaching", "Arrived", "Diverted"]) {
    assert.equal(confirmedRunwayTime("2026-09-18T09:30:00Z", s, "dep", NOW), "2026-09-18T09:30:00.000Z", s);
  }
});

test("arrival runway time only counts once the flight has actually arrived", () => {
  assert.equal(confirmedRunwayTime("2026-09-18T09:50:00Z", "EnRoute", "arr", NOW), null);
  assert.equal(confirmedRunwayTime("2026-09-18T09:50:00Z", "Approaching", "arr", NOW), null);
  assert.equal(confirmedRunwayTime("2026-09-18T09:50:00Z", "Arrived", "arr", NOW), "2026-09-18T09:50:00.000Z");
  assert.equal(confirmedRunwayTime("2026-09-18T09:50:00Z", "Diverted", "arr", NOW), "2026-09-18T09:50:00.000Z");
});

test("unknown status trusts a runway time only once it is safely in the past", () => {
  assert.equal(confirmedRunwayTime("2026-09-18T10:20:00Z", "Unknown", "dep", NOW), null);
  assert.equal(confirmedRunwayTime("2026-09-18T09:55:00Z", "Unknown", "dep", NOW), null, "inside the grace window");
  assert.equal(confirmedRunwayTime("2026-09-18T09:30:00Z", "Unknown", "dep", NOW), "2026-09-18T09:30:00.000Z");
  assert.equal(confirmedRunwayTime("2026-09-18T09:30:00Z", undefined, "arr", NOW), "2026-09-18T09:30:00.000Z");
});

test("no runway time, no actual", () => {
  assert.equal(confirmedRunwayTime(null, "Departed", "dep", NOW), null);
  assert.equal(confirmedRunwayTime("", "Departed", "dep", NOW), null);
});

/// AeroDataBox flips status to Departed at off-block, while runwayTime can
/// still be a projection for the taxi ahead. A take-off time that has not
/// happened yet is an estimate by definition.
test("a departure runway time still in the future is an estimate even when the status says Departed", () => {
  assert.equal(confirmedRunwayTime("2026-09-18T10:20:00Z", "Departed", "dep", NOW), null);
  assert.equal(confirmedRunwayTime("2026-09-18T09:58:00Z", "Departed", "dep", NOW), "2026-09-18T09:58:00.000Z");
});

import { movementIsLive } from "../src/legs.ts";

test("movementIsLive reads AeroDataBox's quality array", () => {
  assert.equal(movementIsLive(["Basic", "Live"]), true);
  assert.equal(movementIsLive(["Basic", "Approximate"]), false);
  assert.equal(movementIsLive(undefined), false);
});

// ── The date a flight departs on is a LOCAL date, and only the provider knows it ──
//
// `/flights/number/LX2146/2026-08-25` answers with TWO legs, and the provider's
// own spec says why: `dateLocalRole` defaults to `Both`, so a date matches a
// flight that DEPARTS on it *or* ARRIVES on it. LX2146 lands at 00:05, so the
// 24th's operation arrives on the 25th and comes back alongside the 25th's.
//
// Arc asks the question a traveller asks — "the flight I am taking on the
// 25th" — so the answer has to be narrowed to departures. Unnarrowed, a search
// for the 25th listed yesterday's operation FIRST, identical in every visible
// respect (same number, same 22:00 → 00:05, same route), and tapping it added
// a flight for the wrong day.
//
// The comparison has to happen in the departure airport's own timezone: a
// 23:30 departure from Los Angeles carries a UTC timestamp on the following
// day, and judging it by that would move the flight off the date its own
// traveller is standing at the airport on.
import { localDay, departsOnLocalDate } from "../src/legs.ts";

test("the local departure date is read off the provider's own local timestamp", () => {
  assert.equal(localDay("2026-08-24 22:00+02:00"), "2026-08-24");
  assert.equal(localDay("2026-08-25T00:05:00+02:00"), "2026-08-25");
  assert.equal(localDay(undefined), null);
  assert.equal(localDay("not a time"), null);
});

test("the leg that departs the day before is not an answer about this day", () => {
  const yesterdays = { dep_scheduled: "2026-08-24T20:00:00.000Z", dep_local_date: "2026-08-24" };
  const todays = { dep_scheduled: "2026-08-25T20:00:00.000Z", dep_local_date: "2026-08-25" };
  assert.equal(departsOnLocalDate(yesterdays, "2026-08-25"), false);
  assert.equal(departsOnLocalDate(todays, "2026-08-25"), true);
});

test("a late-evening departure keeps its own local date, not its UTC one", () => {
  // 23:30 in Los Angeles on the 25th is 06:30Z on the 26th. By the UTC stamp
  // this leg belongs to the 26th; its traveller is at the airport on the 25th.
  const leg = { dep_scheduled: "2026-08-26T06:30:00.000Z", dep_local_date: "2026-08-25" };
  assert.equal(departsOnLocalDate(leg, "2026-08-25"), true);
  assert.equal(departsOnLocalDate(leg, "2026-08-26"), false);
});

test("a leg cached before local dates were kept is not hidden", () => {
  // Payloads written by the previous version carry no local date at all, and
  // they stay readable for as long as their TTL. Filtering them out would blank
  // real flights out of search; keeping them is exactly the old behaviour.
  assert.equal(departsOnLocalDate({ dep_scheduled: "2026-08-24T20:00:00.000Z" }, "2026-08-25"), true);
});

test("weekly: an inferred neighbour carries the local date it was shifted TO", () => {
  // Otherwise the timetable Arc infers for a provider hole is filtered out by
  // the very date it was inferred for.
  const neighbour = {
    flight_number: "LH1751", dep_iata: "ATH", arr_iata: "MUC",
    dep_scheduled: "2026-09-25T09:45:00.000Z", arr_scheduled: "2026-09-25T11:30:00.000Z",
    dep_local_date: "2026-09-25",
  };
  const shifted = shiftLegToDay(neighbour, "2026-09-25", "2026-09-18")!;
  assert.equal(shifted["dep_local_date"], "2026-09-18");
  assert.equal(departsOnLocalDate(shifted, "2026-09-18"), true);
});

test("weekly: a neighbour that never carried a local date does not acquire one", () => {
  const neighbour = {
    flight_number: "LH1751", dep_iata: "ATH", arr_iata: "MUC",
    dep_scheduled: "2026-09-25T09:45:00.000Z", arr_scheduled: "2026-09-25T11:30:00.000Z",
  };
  const shifted = shiftLegToDay(neighbour, "2026-09-25", "2026-09-18")!;
  assert.equal(shifted["dep_local_date"], null);
});
