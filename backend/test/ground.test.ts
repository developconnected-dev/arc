import test from "node:test";
import assert from "node:assert/strict";
import { classifyGround, taxiPriorMinutes, expectedWheelsUp, DEFAULT_TAXI_PRIOR } from "../src/ground.ts";

/// What one ADS-B sample says about the aircraft. Velocity in m/s, altitude
/// in metres — the units /position already speaks.
test("classifyGround: stationary on the deck is at the gate, rolling is taxiing, off the deck is airborne", () => {
  assert.equal(classifyGround({ on_ground: true, velocity: 0.5 }), "at_gate");
  assert.equal(classifyGround({ on_ground: true, velocity: 6 }), "taxiing");
  assert.equal(classifyGround({ on_ground: false, altitude: 400, velocity: 80 }), "airborne");
  // Not flagged on-ground but no altitude and no speed: a stale or broken
  // sample, not a take-off.
  assert.equal(classifyGround({ on_ground: false, altitude: 0, velocity: 0 }), "unknown");
  assert.equal(classifyGround(null), "unknown");
});

test("taxiPriorMinutes is the p85 of same-hour-ish samples, widening before it gives up", () => {
  const obs = [10, 12, 14, 15, 18, 22, 30].map(m => ({ taxi_minutes: m, hour_utc: 7 }));
  assert.equal(taxiPriorMinutes(obs, 7), 22);
  assert.equal(taxiPriorMinutes(obs, 20), 22);                                  // no same-hour samples → all
  assert.equal(taxiPriorMinutes([{ taxi_minutes: 9, hour_utc: 7 }], 7), DEFAULT_TAXI_PRIOR); // too few
  assert.equal(taxiPriorMinutes([], 7), DEFAULT_TAXI_PRIOR);
  // Hour distance wraps around midnight.
  const night = [5, 6, 7].map(m => ({ taxi_minutes: m, hour_utc: 23 }));
  assert.equal(taxiPriorMinutes(night, 1), 6);
});

test("expectedWheelsUp is the latest of estimate, off-block+prior, last-on-ground+prior", () => {
  const t = (m: number) => Date.UTC(2026, 8, 18, 10, m);
  assert.equal(expectedWheelsUp({ offBlock: t(0), priorMinutes: 20 }), t(20));
  assert.equal(expectedWheelsUp({ offBlock: t(0), priorMinutes: 20, estimate: t(25) }), t(25));
  assert.equal(expectedWheelsUp({ offBlock: t(0), priorMinutes: 20, estimate: t(5) }), t(20));
  assert.equal(expectedWheelsUp({ offBlock: t(0), priorMinutes: 20, lastOnGround: t(30) }), t(50));
});
