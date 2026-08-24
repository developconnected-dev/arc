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
