import test from "node:test";
import assert from "node:assert/strict";
import { flightNews, type WatchState } from "../src/alerts.ts";

const NOW = Date.parse("2026-08-24T09:00:00Z");
const base = {
  flightNumber: "LX318",
  arrivalCity: "Zurich",
  status: "scheduled",
  delayMinutes: 0,
  departureGate: null as string | null,
  scheduledDeparture: NOW + 5 * 3600_000,
  now: NOW,
  prior: {} as WatchState,
};

test("a quiet flight is not news", () => {
  assert.equal(flightNews(base), null);
});

test("a small delay is not worth a banner", () => {
  assert.equal(flightNews({ ...base, delayMinutes: 8 }), null);
});

test("a delay worth re-planning around is announced once", () => {
  const first = flightNews({ ...base, delayMinutes: 40 });
  assert.ok(first);
  assert.match(first!.title, /40m late/);
  // Same delay an hour later: already said.
  assert.equal(flightNews({ ...base, delayMinutes: 40, prior: first!.state }), null);
});

test("a delay that grows materially is restated", () => {
  const first = flightNews({ ...base, delayMinutes: 20 })!;
  assert.equal(flightNews({ ...base, delayMinutes: 25, prior: first.state }), null);
  const worse = flightNews({ ...base, delayMinutes: 55, prior: first.state });
  assert.match(worse!.title, /55m late/);
});

test("restatements replace the earlier banner rather than stacking", () => {
  const first = flightNews({ ...base, delayMinutes: 20 })!;
  const worse = flightNews({ ...base, delayMinutes: 55, prior: first.state })!;
  assert.equal(first.collapseId, worse.collapseId);
});

test("a cleared delay is said once, then goes quiet", () => {
  const late = flightNews({ ...base, delayMinutes: 35 })!;
  const cleared = flightNews({ ...base, delayMinutes: 0, prior: late.state });
  assert.match(cleared!.title, /back on schedule/);
  assert.equal(flightNews({ ...base, delayMinutes: 0, prior: cleared!.state }), null);
});

test("a cancellation is announced once and outranks a delay", () => {
  const c = flightNews({ ...base, status: "cancelled", delayMinutes: 90 })!;
  assert.match(c.title, /cancelled/);
  assert.equal(flightNews({ ...base, status: "cancelled", prior: c.state }), null);
});

test("a provider flip-flop does not un-cancel a flight with a banner", () => {
  const c = flightNews({ ...base, status: "cancelled" })!;
  assert.equal(flightNews({ ...base, status: "scheduled", delayMinutes: 60, prior: c.state }), null);
});

test("a gate published far out is not announced", () => {
  assert.equal(flightNews({
    ...base, departureGate: "A12", scheduledDeparture: NOW + 20 * 3600_000,
  }), null);
});

test("a gate published near departure is announced, and a move says what moved", () => {
  const first = flightNews({ ...base, departureGate: "A12" })!;
  assert.match(first.title, /gate A12/);
  assert.equal(flightNews({ ...base, departureGate: "A12", prior: first.state }), null);
  const moved = flightNews({ ...base, departureGate: "B44", prior: first.state })!;
  assert.match(moved.title, /moved to gate B44/);
  assert.match(moved.body, /from gate A12/);
});
