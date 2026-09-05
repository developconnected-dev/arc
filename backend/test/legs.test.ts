import test from "node:test";
import assert from "node:assert/strict";
import { repairLegForRoute, departureFromBoardTime, cachedRowFresh, cacheTTLms } from "../src/legs.ts";

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

// ── Inferring a timetable from a neighbouring week, from the RIGHT leg ──
//
// `legsWithWeeklyFallback` fills a provider hole by asking for the same
// number a week either side and shifting that answer by whole days. It took
// the first complete leg it got back — and the week-either-side answer has
// the SAME two-legs-for-one-date problem as every other date query, because
// `dateLocalRole` defaults to `Both`. On a route that lands after midnight,
// the first leg returned for the neighbour day is the day BEFORE it.
//
// So the inferred timetable could be built from an operation two days off the
// one it was inferred for, and — once legs started carrying their own local
// date — be filtered straight back out by the endpoint that asked for it.
// Whichever way it fell, a real flight went missing from a search.
import { templatesFromNeighbour } from "../src/legs.ts";

/// What AeroDataBox answers for a neighbour day on an after-midnight route.
const NEIGHBOUR = [
  { flight_number: "LX2146", dep_iata: "ZRH", arr_iata: "VLC",
    dep_scheduled: "2026-09-24T20:00:00.000Z", arr_scheduled: "2026-09-24T22:05:00.000Z",
    dep_local_date: "2026-09-24" },
  { flight_number: "LX2146", dep_iata: "ZRH", arr_iata: "VLC",
    dep_scheduled: "2026-09-25T20:00:00.000Z", arr_scheduled: "2026-09-25T22:05:00.000Z",
    dep_local_date: "2026-09-25" },
];

test("the neighbour's OWN day is the template, not the sibling it arrived with", () => {
  const out = templatesFromNeighbour(NEIGHBOUR, "2026-09-25", "2026-09-18");
  assert.equal(out.length, 1, "the day-before sibling is not a second timetable");
  assert.equal(out[0]!["dep_scheduled"], "2026-09-18T20:00:00.000Z");
  assert.equal(out[0]!["dep_local_date"], "2026-09-18");
});

test("...and the shifted template is an answer about the day it was inferred for", () => {
  const out = templatesFromNeighbour(NEIGHBOUR, "2026-09-25", "2026-09-18");
  assert.equal(departsOnLocalDate(out[0]!, "2026-09-18"), true);
});

test("everything live is still stripped — it is a timetable, not a status", () => {
  const live = [{ ...NEIGHBOUR[1], status: "landed", dep_actual: "2026-09-25T20:07:00.000Z",
                  dep_gate: "A82", aircraft_registration: "HB-JDH" }];
  const out = templatesFromNeighbour(live, "2026-09-25", "2026-09-18");
  assert.equal(out[0]!["status"], "scheduled");
  assert.equal(out[0]!["dep_actual"], null);
  assert.equal(out[0]!["dep_gate"], null);
  assert.equal(out[0]!["data_tier"], "scheduled");
});

test("a hollow neighbour is no template at all", () => {
  const hollow = [{ dep_iata: "", arr_iata: "VLC", dep_scheduled: "", arr_scheduled: "2026-09-25T22:05:00.000Z" }];
  assert.deepEqual(templatesFromNeighbour(hollow, "2026-09-25", "2026-09-18"), []);
});

test("legs cached before local dates are still usable as templates", () => {
  // Same tolerance the endpoints keep: no local date means the old behaviour,
  // not exclusion — otherwise the weekly inference would go dark for as long
  // as any pre-existing cache row lived.
  const old = [{ flight_number: "LX2146", dep_iata: "ZRH", arr_iata: "VLC",
                 dep_scheduled: "2026-09-25T20:00:00.000Z", arr_scheduled: "2026-09-25T22:05:00.000Z" }];
  assert.equal(templatesFromNeighbour(old, "2026-09-25", "2026-09-18").length, 1);
});

// ── An answer about the wrong day is not a reason to go asking elsewhere ──
import { answerForDay } from "../src/legs.ts";

const TWO_DAYS = [
  { flight_number: "LX2146", dep_scheduled: "2026-08-24T20:00:00.000Z", dep_local_date: "2026-08-24" },
  { flight_number: "LX2146", dep_scheduled: "2026-08-25T20:00:00.000Z", dep_local_date: "2026-08-25" },
];

test("a dated query gets the day it asked for, and only that", () => {
  const out = answerForDay(TWO_DAYS, "2026-08-25");
  assert.equal(out.length, 1);
  assert.equal(out[0]!["dep_local_date"], "2026-08-25");
});

test("a DATELESS query is a live lookup and keeps everything", () => {
  assert.equal(answerForDay(TWO_DAYS, null).length, 2);
  assert.equal(answerForDay(TWO_DAYS, undefined).length, 2);
});

/// Pinned deliberately, because it is the line most likely to be "fixed" back.
///
/// A provider that answers with the neighbouring day's operation is not
/// silent: it is saying it holds this number's schedule and nothing on it
/// departs that day. Handing that on to AirLabs — real-time only, dating legs
/// by their UTC stamp, and caching its reply under this date's key — would put
/// the date question to the source least able to answer it. Empty is the
/// truthful answer, and the app already words it ("No schedule published yet").
test("an answer that is entirely the wrong day is EMPTY, not the nearest leg", () => {
  const yesterdayOnly = [TWO_DAYS[0]!];
  assert.deepEqual(answerForDay(yesterdayOnly, "2026-08-25"), []);
});

test("legs cached before local dates were kept are never narrowed away", () => {
  const legacy = [{ flight_number: "LX2146", dep_scheduled: "2026-08-24T20:00:00.000Z" }];
  assert.equal(answerForDay(legacy, "2026-08-25").length, 1);
});

// ── The cache and the watcher have to agree about what "soon" means ──
//
// The alert watcher now checks a flight every 15 minutes once it is inside
// eight hours of departure. Held at a flat 30-minute TTL, three of every four
// of those checks would have re-read the same bytes — the CACHE would have
// been the latency, and tightening the watcher would have bought nothing.
test("inside eight hours, the answer is held for a quarter of an hour", () => {
  const dep = Date.now() + 5 * 3600_000;
  const leg = { dep_scheduled: new Date(dep).toISOString(),
                arr_scheduled: new Date(dep + 2 * 3600_000).toISOString() };
  assert.equal(cacheTTLms([leg]), 15 * 60_000);
});

test("the night before is still held for half an hour", () => {
  const dep = Date.now() + 12 * 3600_000;
  const leg = { dep_scheduled: new Date(dep).toISOString(),
                arr_scheduled: new Date(dep + 2 * 3600_000).toISOString() };
  assert.equal(cacheTTLms([leg]), 30 * 60_000);
});

test("a day and a half out is unchanged — nothing there moves in fifteen minutes", () => {
  const dep = Date.now() + 30 * 3600_000;
  const leg = { dep_scheduled: new Date(dep).toISOString(),
                arr_scheduled: new Date(dep + 2 * 3600_000).toISOString() };
  assert.equal(cacheTTLms([leg]), 6 * 3600_000);
});

// ── normalizeStatus / isCancelUncertain ──

import { normalizeStatus, isCancelUncertain } from "../src/legs.ts";

test("the provider's cancellation guess is NOT a cancellation", () => {
  // canceledUncertain is documented as "likely cancelled" — rescheduled
  // flights that go on to operate carry it. Hardening it into "cancelled"
  // put a red "Flight Cancelled" and a rebooking push on a flight that was
  // delayed 25 minutes and holding a gate.
  assert.equal(normalizeStatus("CanceledUncertain"), "scheduled");
  assert.equal(isCancelUncertain("CanceledUncertain"), true);
});

test("a confirmed cancellation still lands loud, in every spelling", () => {
  assert.equal(normalizeStatus("Canceled"), "cancelled");
  assert.equal(normalizeStatus("Cancelled"), "cancelled");
  assert.equal(isCancelUncertain("Canceled"), false);
});

test("a delay is a scheduled flight — the delay field says the rest", () => {
  assert.equal(normalizeStatus("Delayed"), "scheduled");
});

test("movement statuses keep their buckets", () => {
  assert.equal(normalizeStatus("EnRoute"), "active");
  assert.equal(normalizeStatus("Departed"), "active");
  assert.equal(normalizeStatus("Arrived"), "landed");
  assert.equal(normalizeStatus("Diverted"), "diverted");
  assert.equal(normalizeStatus("Boarding"), "boarding");
  assert.equal(normalizeStatus("GateClosed"), "gateClosed");
});

test("a status nobody has heard of asserts nothing", () => {
  assert.equal(normalizeStatus("SomeFutureValue"), "scheduled");
  assert.equal(normalizeStatus(null), "scheduled");
  assert.equal(isCancelUncertain(undefined), false);
});

/// Twenty minutes past the gate with NO confirmed take-off, the answer is
/// still moving — the runway estimate and the actual are what the card's
/// flip to In Air waits on. The old curve dropped to the cruise hold here,
/// so a 35-minute taxi had its confirmation on a fifteen-minute clock.
test("an unconfirmed departure holds the tight TTL through the taxi", () => {
  const dep = Date.now() - 30 * 60_000;   // half an hour past the gate
  const unconfirmed = { dep_scheduled: new Date(dep).toISOString(),
                        arr_scheduled: new Date(dep + 5 * 3600_000).toISOString() };
  assert.equal(cacheTTLms([unconfirmed]), 5 * 60_000);
  // A departure CONFIRMED half an hour ago is cruising: cruise hold.
  const confirmed = { ...unconfirmed, dep_actual: new Date(dep).toISOString() };
  assert.equal(cacheTTLms([confirmed]), 15 * 60_000);
  // And the hedge's hard cap bounds it — past 90 minutes the presumption
  // has spoken, nothing minute-fresh is left to learn.
  const long = { dep_scheduled: new Date(Date.now() - 100 * 60_000).toISOString(),
                 arr_scheduled: new Date(Date.now() + 4 * 3600_000).toISOString() };
  assert.equal(cacheTTLms([long]), 15 * 60_000);
});

// ── arrival estimate from the AeroDataBox movement we already fetch ──
//
// Mira: provider/airline arr_estimated always wins the hero. ADB's own
// predictedTime is a projection — stuffing it into arr_estimated would
// paint Flighty-chasing 20:18 as an airline fact. We do not know that
// feed; honesty first.

import { pickEstimatedArrival, adbDateTime } from "../src/legs.ts";

const VY_ARR_SCHED = { utc: "2026-09-02 19:35Z", local: "2026-09-02 20:35+01:00" };
const VY_ARR_REVISED = { utc: "2026-09-02 19:00Z", local: "2026-09-02 20:00+01:00" };
const VY_ARR_PREDICTED = { utc: "2026-09-02 19:18Z", local: "2026-09-02 20:18+01:00" };

test("adbDateTime prefers the UTC instant over the airport-local wall clock", () => {
  assert.equal(adbDateTime(VY_ARR_SCHED), "2026-09-02T19:35:00.000Z");
  assert.equal(adbDateTime({ local: "2026-09-02 20:35+01:00" }), "2026-09-02T19:35:00.000Z");
  assert.equal(adbDateTime(null), "");
});

test("pickEstimatedArrival uses the airline revision, not AeroDataBox predictedTime", () => {
  assert.equal(
    pickEstimatedArrival({
      scheduledTime: VY_ARR_SCHED,
      revisedTime: VY_ARR_REVISED,
      predictedTime: VY_ARR_PREDICTED,
    }),
    "2026-09-02T19:00:00.000Z",
  );
});

test("pickEstimatedArrival ignores predictedTime when the airline has not revised", () => {
  assert.equal(
    pickEstimatedArrival({
      scheduledTime: VY_ARR_SCHED,
      predictedTime: VY_ARR_PREDICTED,
    }),
    null,
  );
});

test("pickEstimatedArrival is silent when the only stamp restates the schedule", () => {
  assert.equal(
    pickEstimatedArrival({
      scheduledTime: VY_ARR_SCHED,
      revisedTime: VY_ARR_SCHED,
      predictedTime: VY_ARR_SCHED,
    }),
    null,
  );
});
