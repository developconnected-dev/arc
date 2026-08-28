import test from "node:test";
import assert from "node:assert/strict";
import { pickLeg, MAX_LEG_DRIFT_MS, plausibleActualDeparture } from "../src/legmatch.ts";

/// The real answer AeroDataBox gave for LX2146 on 2026-08-24, captured while
/// reproducing the bug. TWO legs come back for ONE date, because the flight
/// lands at 00:05 LOCAL: the provider windows by local date, so yesterday's
/// departure ARRIVES on today's date and is returned alongside today's.
const LX2146 = [
  { dep_iata: "ZRH", arr_iata: "VLC", dep_scheduled: "2026-08-23T19:55:00.000Z",
    status: "landed", dep_actual: "2026-08-23T20:07:00.000Z", dep_gate: "A82" },
  { dep_iata: "ZRH", arr_iata: "VLC", dep_scheduled: "2026-08-24T20:00:00.000Z",
    status: "scheduled", dep_actual: null, dep_gate: null },
];
const TODAY = Date.parse("2026-08-24T20:00:00.000Z");
const YESTERDAY = Date.parse("2026-08-23T19:55:00.000Z");

/// THE regression, and it reached a friend's lock screen.
///
/// Selection matched on ROUTE ONLY — `find(dep_iata && arr_iata) ?? legs[0]` —
/// and both legs of a daily route are the same pair of airports. `find`
/// therefore returned the FIRST, which is yesterday's, already landed. A
/// friend's flight still four hours from pushback showed "Landed", wore
/// yesterday's gate A82, and reported its departure as "23h 53m Early" —
/// which is exactly 24h minus the 7 minutes yesterday's aircraft was late.
test("today's leg is chosen, not yesterday's identical-route sibling", () => {
  const leg = pickLeg(LX2146, { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: TODAY });
  assert.equal(leg?.dep_scheduled, "2026-08-24T20:00:00.000Z");
  assert.equal(leg?.status, "scheduled");
  assert.equal(leg?.dep_gate, null, "yesterday's gate must not be inherited");
});

test("...and yesterday's row still gets yesterday's leg", () => {
  const leg = pickLeg(LX2146, { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: YESTERDAY });
  assert.equal(leg?.dep_scheduled, "2026-08-23T19:55:00.000Z");
  assert.equal(leg?.status, "landed");
});

/// Order must not decide the answer. The provider does not promise one.
test("the answer does not depend on the order they arrive in", () => {
  const leg = pickLeg([...LX2146].reverse(), { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: TODAY });
  assert.equal(leg?.dep_scheduled, "2026-08-24T20:00:00.000Z");
});

/// A small delay must not push the row onto the neighbouring day's leg.
test("a scheduled time that has drifted by an hour still picks its own day", () => {
  const leg = pickLeg(LX2146, {
    depIata: "ZRH", arrIata: "VLC",
    scheduledDepMs: TODAY + 60 * 60_000,
  });
  assert.equal(leg?.dep_scheduled, "2026-08-24T20:00:00.000Z");
});

/// Route still filters first — a number that flies two different pairs in a
/// day must not be matched by time alone.
test("the route still decides between genuinely different legs", () => {
  const legs = [
    { dep_iata: "ZRH", arr_iata: "LHR", dep_scheduled: "2026-08-24T20:05:00.000Z" },
    { dep_iata: "ZRH", arr_iata: "VLC", dep_scheduled: "2026-08-24T20:00:00.000Z" },
  ];
  const leg = pickLeg(legs, { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: TODAY });
  assert.equal(leg?.arr_iata, "VLC");
});

/// Nothing plausible is better than something wrong. Every caller already
/// treats a null leg as "the provider had nothing to say", which is the
/// truthful answer when the only candidate is a different day's operation.
test("a leg a whole day away is refused rather than accepted", () => {
  const onlyYesterday = [LX2146[0]];
  assert.equal(pickLeg(onlyYesterday, { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: TODAY }), null);
});

test("...and the tolerance is wide enough for a real schedule move", () => {
  const legs = [{ dep_iata: "ZRH", arr_iata: "VLC", dep_scheduled: "2026-08-24T20:00:00.000Z" }];
  const shifted = TODAY + MAX_LEG_DRIFT_MS - 60_000;
  assert.ok(pickLeg(legs, { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: shifted }));
});

test("no legs, or none on the route, is null", () => {
  assert.equal(pickLeg([], { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: TODAY }), null);
  assert.equal(pickLeg(null, { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: TODAY }), null);
  const other = [{ dep_iata: "GVA", arr_iata: "LHR", dep_scheduled: "2026-08-24T20:00:00.000Z" }];
  assert.equal(pickLeg(other, { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: TODAY }), null);
});

/// A leg carrying no usable scheduled time cannot be date-checked. It is only
/// worth taking when it is the sole candidate on the right route — the old
/// behaviour, kept for the one case where it was never the problem.
test("a leg without a scheduled time is a last resort, never a preference", () => {
  const legs = [
    { dep_iata: "ZRH", arr_iata: "VLC", dep_scheduled: null },
    { dep_iata: "ZRH", arr_iata: "VLC", dep_scheduled: "2026-08-24T20:00:00.000Z" },
  ];
  assert.equal(pickLeg(legs, { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: TODAY })?.dep_scheduled,
               "2026-08-24T20:00:00.000Z");
  assert.ok(pickLeg([legs[0]], { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: TODAY }));
});

/// Rows written before the route was known still have to resolve.
test("with no route given, the nearest scheduled leg wins", () => {
  const leg = pickLeg(LX2146, { depIata: null, arrIata: null, scheduledDepMs: TODAY });
  assert.equal(leg?.dep_scheduled, "2026-08-24T20:00:00.000Z");
});

/// Healing what the wrong leg already wrote.
///
/// Fixing selection stops NEW contamination but cannot undo the old: the row
/// write deliberately carries `row.actual_departure` forward when the provider
/// reports none, so a friend's device-reported departure is never erased by a
/// provider null. That same clause pins yesterday's 20:07 in place for ever,
/// and because a carried departure forces the status to "active", the row goes
/// on claiming a flight that has not left.
///
/// A departure cannot precede its own schedule by hours. Treating that as
/// contamination rather than data lets the next tick clear it by itself.
test("a departure hours BEFORE its schedule is contamination, not a departure", () => {
  const sched = Date.parse("2026-08-24T20:00:00.000Z");
  assert.equal(plausibleActualDeparture("2026-08-23T20:07:00.000Z", sched), null);
});

test("...while a normal early pushback is kept", () => {
  const sched = Date.parse("2026-08-24T20:00:00.000Z");
  const early = "2026-08-24T19:48:00.000Z";
  assert.equal(plausibleActualDeparture(early, sched), early);
});

test("a late departure is always plausible — delays have no ceiling worth setting here", () => {
  const sched = Date.parse("2026-08-24T20:00:00.000Z");
  const late = "2026-08-25T04:30:00.000Z";
  assert.equal(plausibleActualDeparture(late, sched), late);
});

test("absent or unparseable stays absent", () => {
  const sched = Date.parse("2026-08-24T20:00:00.000Z");
  assert.equal(plausibleActualDeparture(null, sched), null);
  assert.equal(plausibleActualDeparture(undefined, sched), null);
  assert.equal(plausibleActualDeparture("not a date", sched), null);
});

// ── a reschedule filed as two rows ──
//
// The pattern the LX2146 report pointed at: the original operation marked
// cancelled and its replacement filed as a SECOND leg, minutes away on the
// same route. Closest-by-drift alone returns the cancelled one — the stored
// time IS the original's — and every surface then asserts a cancellation
// for a flight that operates.

const REFILED = [
  { dep_iata: "ZRH", arr_iata: "VLC", dep_scheduled: "2026-08-25T20:00:00.000Z",
    status: "cancelled", delay: 0 },
  { dep_iata: "ZRH", arr_iata: "VLC", dep_scheduled: "2026-08-25T20:25:00.000Z",
    status: "scheduled", delay: 0 },
];
const STORED = Date.parse("2026-08-25T20:00:00.000Z");

test("a cancelled row with its re-filing 25 minutes away yields the re-filing", () => {
  const leg = pickLeg(REFILED, { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: STORED });
  assert.equal(leg?.status, "scheduled");
  assert.equal(leg?.dep_scheduled, "2026-08-25T20:25:00.000Z");
});

test("...and not because of the order the provider returned them in", () => {
  const leg = pickLeg([...REFILED].reverse(), { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: STORED });
  assert.equal(leg?.status, "scheduled");
});

test("a shuttle's other rotation hours away does not un-cancel the flight", () => {
  // The 07:00 is genuinely cancelled; the 17:00 is a different operation
  // with its own passengers. The truth is "your 07:00 is cancelled".
  const shuttle = [
    { dep_iata: "ZRH", arr_iata: "LHR", dep_scheduled: "2026-08-25T06:00:00.000Z", status: "cancelled" },
    { dep_iata: "ZRH", arr_iata: "LHR", dep_scheduled: "2026-08-25T16:00:00.000Z", status: "scheduled" },
  ];
  const leg = pickLeg(shuttle, {
    depIata: "ZRH", arrIata: "LHR", scheduledDepMs: Date.parse("2026-08-25T06:00:00.000Z"),
  });
  assert.equal(leg?.status, "cancelled");
});

test("with every row cancelled, cancelled is the answer", () => {
  const all = REFILED.map(l => ({ ...l, status: "cancelled" }));
  const leg = pickLeg(all, { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: STORED });
  assert.equal(leg?.status, "cancelled");
  assert.equal(leg?.dep_scheduled, "2026-08-25T20:00:00.000Z");
});

test("the provider's cancellation guess steps aside for a clean sibling too", () => {
  const flagged = [
    { dep_iata: "ZRH", arr_iata: "VLC", dep_scheduled: "2026-08-25T20:00:00.000Z",
      status: "scheduled", cancel_uncertain: true },
    { dep_iata: "ZRH", arr_iata: "VLC", dep_scheduled: "2026-08-25T20:25:00.000Z",
      status: "scheduled", cancel_uncertain: false },
  ];
  const leg = pickLeg(flagged, { depIata: "ZRH", arrIata: "VLC", scheduledDepMs: STORED });
  assert.equal(leg?.dep_scheduled, "2026-08-25T20:25:00.000Z");
});

// ── effectiveDelayMinutes ──

import { effectiveDelayMinutes } from "../src/legmatch.ts";

test("a leg on the stored schedule reports its own delay unchanged", () => {
  const leg = { dep_scheduled: "2026-08-25T20:00:00.000Z", delay: 25 };
  assert.equal(effectiveDelayMinutes(leg, STORED), 25);
});

test("a retimed schedule counts as lateness against the stored one", () => {
  // The row holds 22:00; the leg's own schedule says 22:25, on time. For the
  // person who planned around 22:00 that is a 25-minute delay — and with a
  // delay of its own on top, the two add.
  const moved = { dep_scheduled: "2026-08-25T20:25:00.000Z", delay: 0 };
  assert.equal(effectiveDelayMinutes(moved, STORED), 25);
  const movedAndLate = { dep_scheduled: "2026-08-25T20:25:00.000Z", delay: 10 };
  assert.equal(effectiveDelayMinutes(movedAndLate, STORED), 35);
});

test("a flight moved earlier clamps to zero, the safe direction", () => {
  const earlier = { dep_scheduled: "2026-08-25T19:40:00.000Z", delay: 0 };
  assert.equal(effectiveDelayMinutes(earlier, STORED), 0);
});

test("no readable schedule falls back to the raw delay", () => {
  assert.equal(effectiveDelayMinutes({ delay: 15 }, STORED), 15);
  assert.equal(effectiveDelayMinutes(null, STORED), 0);
});

// ── plausibleEstimatedArrival ──
//
// The row write keeps `row.estimated_arrival` when the provider reports
// none, so yesterday's arrival — written by the old route-only leg match —
// was pinned on a row for ever, and a friend's flight an hour from pushback
// read "Arrival not yet confirmed".

import { plausibleEstimatedArrival } from "../src/legmatch.ts";

const EFF_DEP = Date.parse("2026-08-25T20:00:00.000Z");

test("an estimate after the departure passes through", () => {
  assert.equal(
    plausibleEstimatedArrival("2026-08-25T22:05:00.000Z", EFF_DEP),
    "2026-08-25T22:05:00.000Z");
});

test("no flight arrives before it leaves — yesterday's estimate is dropped", () => {
  assert.equal(plausibleEstimatedArrival("2026-08-24T22:05:00.000Z", EFF_DEP), null);
  assert.equal(plausibleEstimatedArrival("2026-08-25T20:00:00.000Z", EFF_DEP), null);
});

test("nothing, or nothing readable, is null — and a broken anchor keeps the estimate", () => {
  assert.equal(plausibleEstimatedArrival(null, EFF_DEP), null);
  assert.equal(plausibleEstimatedArrival("not a date", EFF_DEP), null);
  assert.equal(plausibleEstimatedArrival("2026-08-25T22:05:00.000Z", NaN), "2026-08-25T22:05:00.000Z");
});
