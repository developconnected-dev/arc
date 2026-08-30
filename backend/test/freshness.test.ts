import test from "node:test";
import assert from "node:assert/strict";
import { shouldWriteSharedRow, laterISO, CHECK_STAMP_INTERVAL_MS, providerAnswered } from "../src/freshness.ts";

const NOW = Date.parse("2026-08-24T12:00:00Z");
const ago = (ms: number) => new Date(NOW - ms).toISOString();

test("a real change is always written", () => {
  assert.equal(shouldWriteSharedRow({ changed: true, checkedAt: ago(1000), now: NOW }), true);
});

/// THE regression. A cruising flight matches the provider on every tick, so
/// nothing was ever written and the friend's screen said "Updated 9h ago"
/// about a row verified sixty seconds earlier.
test("an unchanged row is still stamped once it goes stale", () => {
  assert.equal(shouldWriteSharedRow({ changed: false, checkedAt: ago(9 * 3600_000), now: NOW }), true);
});

test("...but not on every tick — a stable row is not a write per minute", () => {
  assert.equal(shouldWriteSharedRow({ changed: false, checkedAt: ago(60_000), now: NOW }), false);
});

test("the stamp lands well inside the window the app calls Live", () => {
  // The app stops saying "Live" at ten minutes; stamping later than that would
  // mean a verified row still reads as stale.
  assert.ok(CHECK_STAMP_INTERVAL_MS < 10 * 60_000);
});

test("a row never checked is written immediately", () => {
  assert.equal(shouldWriteSharedRow({ changed: false, checkedAt: null, now: NOW }), true);
  assert.equal(shouldWriteSharedRow({ changed: false, now: NOW }), true);
});

test("an unparseable stamp is treated as no stamp, not as fresh", () => {
  assert.equal(shouldWriteSharedRow({ changed: false, checkedAt: "not a date", now: NOW }), true);
});

test("readers take the later of the two stamps", () => {
  const older = ago(9 * 3600_000), newer = ago(60_000);
  assert.equal(laterISO(older, newer), newer);
  assert.equal(laterISO(newer, older), newer);
});

test("either stamp may be missing", () => {
  const t = ago(60_000);
  assert.equal(laterISO(null, t), t);
  assert.equal(laterISO(t, null), t);
  assert.equal(laterISO(null, null), null);
  assert.equal(laterISO("nonsense", t), t);
});

// ── How far ahead the server watches a shared flight ────────────────────────

import { sharedRowIsDue, sharedRowCheckInterval } from "../src/freshness.ts";

const HOUR = 3600_000;
const dep = (h: number) => NOW + h * HOUR;

test("a flight in its live window is due on every tick", () => {
  assert.equal(sharedRowCheckInterval({ depMs: dep(2), arrMs: dep(4), now: NOW }), 0);
});

/// Regression: an in-flight row scored against its own DEPARTURE looked like
/// a flight long past its arrival grace, so the most urgent row in the list
/// sorted last.
test("an aircraft currently in the air is in scope, not past its grace", () => {
  assert.equal(sharedRowCheckInterval({ depMs: dep(-1), arrMs: dep(2), now: NOW }), 0);
});

/// The gap this closes: before, nothing but the traveller's own phone wrote
/// these rows until four hours before departure.
test("a flight later today is watched hourly instead of not at all", () => {
  assert.equal(sharedRowCheckInterval({ depMs: dep(20), arrMs: dep(23), now: NOW }), HOUR);
  assert.equal(sharedRowIsDue({ depMs: dep(20), arrMs: dep(23), checkedAt: ago(90 * 60_000), now: NOW }), true);
  assert.equal(sharedRowIsDue({ depMs: dep(20), arrMs: dep(23), checkedAt: ago(10 * 60_000), now: NOW }), false);
});

test("it tightens as departure approaches", () => {
  const far = sharedRowCheckInterval({ depMs: dep(20), arrMs: dep(23), now: NOW })!;
  const near = sharedRowCheckInterval({ depMs: dep(8), arrMs: dep(11), now: NOW })!;
  const live = sharedRowCheckInterval({ depMs: dep(2), arrMs: dep(5), now: NOW })!;
  assert.ok(far > near && near > live);
});

test("a flight two days out is not watched at all", () => {
  assert.equal(sharedRowCheckInterval({ depMs: dep(48), arrMs: dep(51), now: NOW }), null);
  assert.equal(sharedRowIsDue({ depMs: dep(48), arrMs: dep(51), checkedAt: null, now: NOW }), false);
});

test("a landed flight falls out of scope once its grace expires", () => {
  assert.equal(sharedRowCheckInterval({ depMs: dep(-5), arrMs: dep(-3), now: NOW }), null);
  // ...but is still watched during the grace, when the belt is published.
  assert.equal(sharedRowCheckInterval({ depMs: dep(-3), arrMs: NOW - 10 * 60_000, now: NOW }), 0);
});

test("a row never checked is due immediately, whatever the tier", () => {
  assert.equal(sharedRowIsDue({ depMs: dep(20), arrMs: dep(23), checkedAt: null, now: NOW }), true);
});

/// A consultation that produced no leg is still a consultation — but only if
/// we actually reached the provider.
///
/// `refreshOneSharedRow` returned early on `!leg` without stamping anything,
/// and for a flight far enough out that the provider has no schedule for it
/// yet, that is EVERY consultation. Two things broke at once. The friend's
/// screen had nothing newer than `updated_at` to read, so it went on counting
/// up from the traveller's last write for ever; and `/shared/refresh`
/// deduplicates on `checked_at`, so with the column never written the
/// once-a-minute guard never engaged and every single open reached the
/// provider again.
///
/// The distinction that matters is whether we got a current answer at all: a
/// budget-blocked or malformed fetch serves stale legs and must NOT claim the
/// row was verified.
test("reaching the provider counts as having looked, even with nothing to show", () => {
  assert.equal(providerAnswered("miss"), true);
  assert.equal(providerAnswered("hit"), true);
});

test("...but a fetch that never landed must not claim the row was verified", () => {
  assert.equal(providerAnswered("stale"), false);
  assert.equal(providerAnswered("none"), false);
});

// ── How long a flight outside the Live Activity window may go unwatched ──
//
// The alert watcher covers the gap between "too far out for a Live Activity"
// (3h) and a day and a half out — which is exactly where a cancellation gets
// filed. It used ONE interval for that whole span: 55 minutes, whether the
// flight left in three hours or in thirty-six.
//
// That is wrong at both ends. At the near end a cancellation could sit for
// most of an hour while the traveller is deciding whether to leave for the
// airport. At the far end it re-asked every 55 minutes about a schedule the
// shared cache was holding for six hours, so most of those checks could not
// have found anything new — they cost a read and returned the same bytes.
//
// The interval now tracks the cache: check when there is a chance of news.
import { watchIntervalMs, WATCH_MIN_INTERVAL_MS } from "../src/freshness.ts";

const h = (n: number) => n * 3600_000;
const WATCH_NOW = Date.parse("2026-08-25T12:00:00.000Z");

test("the hours before a Live Activity takes over are watched closely", () => {
  assert.equal(watchIntervalMs(WATCH_NOW + h(4), WATCH_NOW), 15 * 60_000);
  assert.equal(watchIntervalMs(WATCH_NOW + h(7.9), WATCH_NOW), 15 * 60_000);
});

test("the night before is watched at the rate the cache can actually answer", () => {
  assert.equal(watchIntervalMs(WATCH_NOW + h(9), WATCH_NOW), 30 * 60_000);
  assert.equal(watchIntervalMs(WATCH_NOW + h(23), WATCH_NOW), 30 * 60_000);
});

/// Deliberately LOOSER than the 55 minutes it replaces. A schedule more than a
/// day out is cached for six hours, so asking every 55 minutes could not find
/// anything new — it is what paid for tightening the near bands.
test("a day and a half out is checked far less often, not more", () => {
  assert.equal(watchIntervalMs(WATCH_NOW + h(30), WATCH_NOW), 3 * 3600_000);
  assert.ok(watchIntervalMs(WATCH_NOW + h(30), WATCH_NOW) > 55 * 60_000);
});

/// The SQL prefilter uses one interval for every row, so it has to be the
/// TIGHTEST — anything longer would leave a due flight unselected and the
/// per-row curve would never get to see it.
test("the query's floor is the tightest interval any row can want", () => {
  for (const hours of [3.1, 5, 8, 12, 20, 24, 30, 36]) {
    assert.ok(watchIntervalMs(WATCH_NOW + h(hours), WATCH_NOW) >= WATCH_MIN_INTERVAL_MS,
              `${hours}h out wants less than the query floor`);
  }
});

/// A departure already behind us is not something to keep watching.
test("a flight whose time has passed is not watched more eagerly", () => {
  assert.equal(watchIntervalMs(WATCH_NOW - h(1), WATCH_NOW), 15 * 60_000);
});

test("an unreadable departure time falls back rather than dividing by nothing", () => {
  assert.equal(watchIntervalMs(NaN, WATCH_NOW), 30 * 60_000);
});

// ── the AeroDataBox budget gate ──

import { adbGate, resetAtFromHeader, ADB_MONTHLY_UNITS, ADB_UNITS_PER_CALL } from "../src/freshness.ts";

test("the plan is counted in units, not calls — the mix that blew the month", () => {
  // 1,000 calls with 4,000 units reported left: the plan is 6,000 units
  // (1,000 × 2 spent + 4,000 left) — NOT the 5,000 the old calls-plus-units
  // addition produced.
  const g = adbGate("interactive", 0, 1000, 4000);
  assert.equal(g.estUnitsUsed, 2000);
  assert.equal(g.planUnits, 6000);
  assert.equal(g.blocked, false);
});

test("the cron stands down while a quarter of the plan is left; searches run to zero", () => {
  // 2,000 calls ≈ 4,000 units spent, 1,300 left → observed plan 5,300 and a
  // reserve of 1,325: inside it the cron yields, the search still runs.
  assert.equal(adbGate("cron", 500, 2000, 1300).blocked, true);
  assert.equal(adbGate("interactive", 500, 2000, 1300).blocked, false);
  assert.equal(adbGate("interactive", 500, 2000, 0).blocked, true);
});

test("the bootstrap month is bounded by the plan's units at the measured rate", () => {
  const calls = ADB_MONTHLY_UNITS / ADB_UNITS_PER_CALL;   // exactly the plan
  assert.equal(adbGate("interactive", 0, calls, null).blocked, true);
  assert.equal(adbGate("interactive", 0, calls - 1, null).blocked, false);
  // The cron's bootstrap share, on the same basis.
  assert.equal(adbGate("cron", calls * 0.6, calls * 0.6, null).blocked, true);
  assert.equal(adbGate("cron", calls * 0.5, calls * 0.5, null).blocked, false);
});

test("the reset header becomes a date, and garbage becomes nothing", () => {
  const now = Date.parse("2026-08-29T12:00:00Z");
  assert.equal(resetAtFromHeader("86400", now), "2026-08-30T12:00:00.000Z");
  assert.equal(resetAtFromHeader("0", now), null);
  assert.equal(resetAtFromHeader("-5", now), null);
  assert.equal(resetAtFromHeader(String(90 * 86_400), now), null);
  assert.equal(resetAtFromHeader("not a number", now), null);
  assert.equal(resetAtFromHeader(null, now), null);
});

// ── the cron's takeoff clocks ──

import { cronRefreshIntervalMs, takeoffWatchDue, TAKEOFF_HARD_CAP_MS } from "../src/freshness.ts";

const DEP = Date.parse("2026-08-30T20:00:00Z");
const ARR = DEP + 5 * 3600_000;

test("an unconfirmed departure holds the five-minute clock through the taxi", () => {
  const midTaxi = DEP + 30 * 60_000;
  assert.equal(cronRefreshIntervalMs(DEP, ARR, midTaxi, false), 5 * 60_000);
  // Confirmed at the same moment: cruise — the flip already happened.
  assert.equal(cronRefreshIntervalMs(DEP, ARR, midTaxi, true), 30 * 60_000);
});

test("past the hard cap the presumption has spoken and cruise cadence returns", () => {
  const past = DEP + TAKEOFF_HARD_CAP_MS + 60_000;
  assert.equal(cronRefreshIntervalMs(DEP, ARR, past, false), 30 * 60_000);
});

test("the other bands are untouched", () => {
  assert.equal(cronRefreshIntervalMs(DEP, ARR, DEP - 2 * 3600_000, false), 10 * 60_000);
  assert.equal(cronRefreshIntervalMs(DEP, ARR, DEP + 10 * 60_000, false), 5 * 60_000);
  assert.equal(cronRefreshIntervalMs(DEP, ARR, ARR - 10 * 60_000, true), 10 * 60_000);
});

test("the ADS-B look spends only inside the takeoff window", () => {
  // Before the window, after the cap, once confirmed, once seen flying: no.
  assert.equal(takeoffWatchDue(DEP, DEP - 30 * 60_000, false, null), false);
  assert.equal(takeoffWatchDue(DEP, DEP + TAKEOFF_HARD_CAP_MS + 1, false, null), false);
  assert.equal(takeoffWatchDue(DEP, DEP + 10 * 60_000, true, null), false);
  assert.equal(takeoffWatchDue(DEP, DEP + 10 * 60_000, false, "airborne"), false);
  // Rolling up to the gate time and through the taxi: yes.
  assert.equal(takeoffWatchDue(DEP, DEP - 10 * 60_000, false, null), true);
  assert.equal(takeoffWatchDue(DEP, DEP + 25 * 60_000, false, "taxiing"), true);
});
