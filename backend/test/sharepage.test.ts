import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

/// The share page answers "has it left the ground?" for a FRIEND watching in a
/// browser — a third implementation of the rule that `Shared/DepartureEvidence.swift`
/// states for the app and the widget. It cannot import the Swift, and it is
/// plain browser JS embedded in a template literal, so nothing type-checks it
/// and nothing ran it.
///
/// It had drifted: no 90-minute cap (so the hedge re-anchored on every row
/// update and "Presumed airborne" was effectively unreachable), no freshness
/// gate on an airborne sighting, a taxi that flickered back to "Departing" on
/// every hold, and a departure "confirmed" by a timestamp in the future.
///
/// This lifts the real functions out of the real page and runs them, so the
/// next drift fails here instead of on a friend's phone. Cases mirror
/// ArcTests/DepartureEvidenceTests.swift.
const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "../src/index.ts"), "utf8");

const start = source.indexOf("var PRE=[");
const end = source.indexOf("function phase(){");
assert.ok(start > 0 && end > start,
  "share-page phase block not found — the markers moved, fix this test rather than deleting it");
const block = source.slice(start, end);
assert.ok(block.includes("function depPhase()"), "depPhase missing from the extracted block");

// `Date` arrives as a PARAMETER so the frozen clock shadows the global without
// a `const Date = Date` in the same scope — which is its own temporal dead
// zone, and exactly the bug this suite exists to catch.
const build = new Function("D", "Date", `
  function P(s){return s?Date.parse(s):null}
  ${block}
  return { depPhase, wheelsUpT, offBlockT };
`) as (D: unknown, clock: unknown) => { depPhase: () => string };

const harness = (D: unknown, now: number) =>
  build(D, { now: () => now, parse: (s: string) => Date.parse(s) });

const MIN = 60_000;
const OFF = Date.parse("2026-08-24T09:00:00Z");
const iso = (ms: number) => new Date(ms).toISOString();

function make(over: Record<string, any> = {}, ground: Record<string, any> = {}) {
  return {
    flight: {
      status: "scheduled",
      delay: 0,
      taxiPrior: 20,
      updated: null,
      dep: { scheduled: iso(OFF), actual: null, estTakeoff: null },
      arr: { scheduled: iso(OFF + 120 * MIN), actual: null, estimated: null },
      ...over,
      ground: { state: null, observedAt: null, taxiStartedAt: null, ...ground },
    },
  };
}

const phaseAt = (D: unknown, now: number) => harness(D, now).depPhase();

test("before off-block it has not left", () => {
  assert.equal(phaseAt(make(), OFF - 5 * MIN), "before");
});

test("inside the taxi prior it is departing, not flying", () => {
  assert.equal(phaseAt(make(), OFF + 10 * MIN), "departing");
});

test("past expected wheels-up with no evidence it only PRESUMES", () => {
  assert.equal(phaseAt(make(), OFF + 25 * MIN), "presumed");
});

test("a fresh taxiing sighting outranks the clock", () => {
  const D = make({}, { state: "taxiing", observedAt: iso(OFF + 24 * MIN) });
  assert.equal(phaseAt(D, OFF + 25 * MIN), "taxiing");
});

test("a sighting older than the fresh window says nothing about now", () => {
  const D = make({}, { state: "taxiing", observedAt: iso(OFF - 20 * MIN) });
  assert.equal(phaseAt(D, OFF + 25 * MIN), "presumed");
});

/// Regression. `lastOnGroundT` re-anchors on the row's updated_at, so without
/// the cap every refresh pushed expected wheels-up another taxi-prior into the
/// future and this page could never say "Presumed airborne" at all.
test("the hedge stops 90 minutes after off-block, however often the row updates", () => {
  const now = OFF + 100 * MIN;
  const D = make({ updated: iso(now - MIN) });   // a row updated seconds ago
  assert.equal(phaseAt(D, now), "presumed");
});

test("...and still hedges before that cap is reached", () => {
  const now = OFF + 80 * MIN;
  const D = make({ updated: iso(now - MIN) });
  assert.equal(phaseAt(D, now), "departing");
});

/// Regression: most of a 35-minute taxi at a hub is spent stopped, and
/// flickering Taxiing → Departing on every hold is worse than either.
test("a pause once rolling is still the taxi", () => {
  const D = make({}, {
    state: "at_gate", observedAt: iso(OFF + 18 * MIN), taxiStartedAt: iso(OFF + 3 * MIN),
  });
  assert.equal(phaseAt(D, OFF + 19 * MIN), "taxiing");
});

test("the wheels-up clock ends taxiing when nothing slides it", () => {
  const D = make({}, { state: "taxiing", taxiStartedAt: iso(OFF + 3 * MIN) });
  assert.equal(phaseAt(D, OFF + 25 * MIN), "presumed");
});

test("at the gate having never moved is departing, not taxiing", () => {
  const D = make({}, { state: "at_gate", observedAt: iso(OFF + 24 * MIN) });
  assert.equal(phaseAt(D, OFF + 25 * MIN), "departing");
});

/// Regression: a runway time filed for later is a plan, not a departure.
test("a confirmation dated in the future is a filing, not a fact", () => {
  const D = make({ dep: { scheduled: iso(OFF), actual: iso(OFF + 40 * MIN), estTakeoff: null } });
  assert.equal(phaseAt(D, OFF + 10 * MIN), "departing");
  assert.equal(phaseAt(D, OFF + 45 * MIN), "airborne");
});

test("a fresh airborne sighting is a take-off", () => {
  const D = make({}, { state: "airborne", observedAt: iso(OFF + 24 * MIN) });
  assert.equal(phaseAt(D, OFF + 25 * MIN), "airborne");
});

/// Regression: an airborne sighting used to be trusted at any age, so a
/// report from an hour ago outranked everything the clock knew since.
test("a STALE airborne sighting is not a take-off", () => {
  const D = make({}, { state: "airborne", observedAt: iso(OFF - 40 * MIN) });
  assert.equal(phaseAt(D, OFF + 10 * MIN), "departing");
});

test("the provider's own wheels-up estimate extends the hedge past the prior", () => {
  const D = make({ dep: { scheduled: iso(OFF), actual: null, estTakeoff: iso(OFF + 40 * MIN) } });
  assert.equal(phaseAt(D, OFF + 30 * MIN), "departing");
  assert.equal(phaseAt(D, OFF + 45 * MIN), "presumed");
});
