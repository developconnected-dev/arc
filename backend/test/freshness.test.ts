import test from "node:test";
import assert from "node:assert/strict";
import { shouldWriteSharedRow, laterISO, CHECK_STAMP_INTERVAL_MS } from "../src/freshness.ts";

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
