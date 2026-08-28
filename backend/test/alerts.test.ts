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

// ── the provider's cancellation guess ──

test("a may-be-cancelled flag is one hedged heads-up, not rebooking advice", () => {
  const news = flightNews({ ...base, cancelUncertain: true });
  assert.ok(news);
  assert.match(news!.title, /may be cancelled/);
  assert.doesNotMatch(news!.body, /Rebooking/);
  // Said once: the same guess an hour later is not news again.
  assert.equal(flightNews({ ...base, cancelUncertain: true, prior: news!.state }), null);
});

test("the guess does not latch: delay and gate news keep flowing after it", () => {
  const said = flightNews({ ...base, cancelUncertain: true })!.state;
  const delay = flightNews({ ...base, cancelUncertain: true, delayMinutes: 40, prior: said });
  assert.match(delay!.title, /40m late/);
  const gate = flightNews({
    ...base, cancelUncertain: true, delayMinutes: 40, departureGate: "A64",
    scheduledDeparture: NOW + 2 * 3600_000, prior: delay!.state,
  });
  assert.match(gate!.title, /gate A64/);
});

test("a guess that hardens into the fact is announced as the fact, replacing the hedge", () => {
  const said = flightNews({ ...base, cancelUncertain: true })!;
  const hard = flightNews({ ...base, status: "cancelled", prior: said.state });
  assert.match(hard!.title, /is cancelled/);
  assert.equal(hard!.collapseId, said.collapseId);
});

test("a guess that clears is worth one line — whoever saw it is still wondering", () => {
  const said = flightNews({ ...base, cancelUncertain: true })!;
  const cleared = flightNews({ ...base, cancelUncertain: false, prior: said.state });
  assert.match(cleared!.title, /operating/);
  assert.equal(cleared!.collapseId, said.collapseId);
  // And silence after that.
  assert.equal(flightNews({ ...base, cancelUncertain: false, prior: cleared!.state }), null);
});

test("a confirmed cancellation still latches everything behind it", () => {
  const hard = flightNews({ ...base, status: "cancelled" })!;
  assert.equal(flightNews({ ...base, delayMinutes: 60, prior: hard.state }), null);
});

// ── the Live Activity update banner ──

import { laAlert } from "../src/alerts.ts";

test("a gate change banners, with the delay alongside", () => {
  const a = laAlert({ flightNumber: "LX2146", priorGate: "A22", gate: "A64", priorDelay: 25, delay: 25 });
  assert.equal(a!.body, "Gate A64 · 25m late");
});

test("an unrelated change does not re-banner the same gate", () => {
  // Status flipped, belt appeared, aircraft seen taxiing — the gate and
  // delay are what the banner SAYS, and neither moved.
  assert.equal(laAlert({ flightNumber: "LX2146", priorGate: "A64", gate: "A64", priorDelay: 25, delay: 25 }), null);
});

test("a delay that moves materially banners without a gate change", () => {
  const a = laAlert({ flightNumber: "LX2146", priorGate: "A64", gate: "A64", priorDelay: 10, delay: 25 });
  assert.equal(a!.body, "25m late");
});

test("small delay churn is not news", () => {
  assert.equal(laAlert({ flightNumber: "LX2146", priorGate: "A64", gate: "A64", priorDelay: 20, delay: 25 }), null);
  assert.equal(laAlert({ flightNumber: "LX2146", priorGate: null, gate: null, priorDelay: 0, delay: 9 }), null);
});

test("a delay that clears from a real one says so", () => {
  const a = laAlert({ flightNumber: "LX2146", priorGate: "A64", gate: "A64", priorDelay: 25, delay: 0 });
  assert.equal(a!.body, "back on schedule");
});

test("the first gate is a banner; a gate going null is not a gate change", () => {
  const first = laAlert({ flightNumber: "LX2146", priorGate: null, gate: "A64", priorDelay: 0, delay: 0 });
  assert.equal(first!.body, "Gate A64");
  assert.equal(laAlert({ flightNumber: "LX2146", priorGate: "A64", gate: null, priorDelay: 30, delay: 30 }), null);
});
