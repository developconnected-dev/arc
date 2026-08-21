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
