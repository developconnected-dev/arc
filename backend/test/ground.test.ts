import test from "node:test";
import assert from "node:assert/strict";
import { classifyGround, taxiPriorMinutes, DEFAULT_TAXI_PRIOR } from "../src/ground.ts";

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


import { adbPositionToSample, ADB_GROUND_CEILING_M } from "../src/ground.ts";

/// AeroDataBox returns a position on the same call the cron already makes
/// (`withLocation=true`), for aircraft ON THE GROUND as well as airborne —
/// which is what lets the server witness a take-off with nobody's app open,
/// using the key we already pay for instead of an IP-rate-limited aggregator.
test("adbPositionToSample normalises AeroDataBox's location block", () => {
  const airborne = adbPositionToSample({
    pressureAltitude: { meter: 7658.1, feet: 25125 },
    groundSpeed: { meterPerSecond: 184, kt: 358 },
    vsiFpm: -1344, reportedAtUtc: "2026-08-23 11:43", lat: 47.93, lon: 8.5,
  });
  assert.equal(airborne?.on_ground, false);
  assert.equal(airborne?.altitude, 7658.1);
  assert.equal(airborne?.velocity, 184);
  assert.equal(airborne?.reportedAt, "2026-08-23T11:43:00.000Z");
  assert.equal(classifyGround(airborne), "airborne");
});

test("a take-off roll is still on the ground", () => {
  // The real shape seen from LX64 at ZRH: 0 ft, 93 kt.
  const roll = adbPositionToSample({
    pressureAltitude: { meter: 0, feet: 0 },
    groundSpeed: { meterPerSecond: 47.8, kt: 93 },
    reportedAtUtc: "2026-08-23 11:44", lat: 47.45, lon: 8.55,
  });
  assert.equal(roll?.on_ground, true);
  assert.equal(classifyGround(roll), "taxiing");
});

test("parked at the stand reads as at_gate", () => {
  const parked = adbPositionToSample({
    pressureAltitude: { meter: 0, feet: 0 },
    groundSpeed: { meterPerSecond: 0.4, kt: 0.8 },
    reportedAtUtc: "2026-08-23 11:44", lat: 47.45, lon: 8.55,
  });
  assert.equal(classifyGround(parked), "at_gate");
});

test("a low-but-climbing aircraft is not called airborne until it is clearly up", () => {
  // Below the ceiling the altitude cannot be told apart from ground noise,
  // so the speed decides — and a wrong 'airborne' is the costly mistake.
  const justOff = adbPositionToSample({
    pressureAltitude: { meter: ADB_GROUND_CEILING_M - 10, feet: 400 },
    groundSpeed: { meterPerSecond: 80, kt: 155 },
    reportedAtUtc: "2026-08-23 11:44", lat: 47.45, lon: 8.55,
  });
  assert.equal(justOff?.on_ground, true);
});

test("no location, or one without a timestamp, is not a sample", () => {
  assert.equal(adbPositionToSample(null), null);
  assert.equal(adbPositionToSample(undefined), null);
  assert.equal(adbPositionToSample({ pressureAltitude: { meter: 100 } }), null);
});


import { landedSighting, LANDING_RADIUS_KM } from "../src/ground.ts";

/// The other end of the flight. A status string that says "Arrived" can lag
/// touchdown by an hour, and nothing else ever confirmed a landing — so the
/// lock screen kept counting down to an arrival that had already happened.
/// An aircraft seen ON THE GROUND at its destination, after it left, has
/// landed: that is evidence, not a clock.
test("landedSighting: on the ground at the destination after departure is a landing", () => {
  const jfk = { lat: 40.6413, lon: -73.7781 };
  const departed = Date.parse("2026-09-06T11:30:00Z");
  const now = Date.parse("2026-09-06T19:40:00Z");
  const onStand = { on_ground: true, velocity: 0.4, altitude: 0, lat: 40.6455, lon: -73.7830,
                    reportedAt: "2026-09-06T19:35:00Z" };
  assert.equal(landedSighting(onStand, jfk, departed, now), true);
  // Rolling out on the runway counts too — the wheels are down.
  const rollingOut = { ...onStand, velocity: 30, lat: 40.6300, lon: -73.7700 };
  assert.equal(landedSighting(rollingOut, jfk, departed, now), true);
});

test("landedSighting: still flying, far away, stale, or before it left is not a landing", () => {
  const jfk = { lat: 40.6413, lon: -73.7781 };
  const departed = Date.parse("2026-09-06T11:30:00Z");
  const now = Date.parse("2026-09-06T19:40:00Z");
  const base = { on_ground: true, velocity: 0.4, altitude: 0, lat: 40.6455, lon: -73.7830,
                 reportedAt: "2026-09-06T19:35:00Z" };
  // On approach: off the ground, so not landed yet.
  assert.equal(landedSighting({ ...base, on_ground: false, altitude: 600, velocity: 80 }, jfk, departed, now), false);
  // On the ground at some OTHER airport (Newark, 33 km away): a diversion or
  // another aircraft's sample, not this landing.
  assert.equal(landedSighting({ ...base, lat: 40.6895, lon: -74.1745 }, jfk, departed, now), false);
  // A sighting older than the fresh window says nothing about now.
  assert.equal(landedSighting({ ...base, reportedAt: "2026-09-06T19:10:00Z" }, jfk, departed, now), false);
  // Parked at the destination BEFORE this flight departed: the tail's
  // previous rotation, not this arrival.
  assert.equal(landedSighting({ ...base, reportedAt: "2026-09-06T11:20:00Z" }, jfk, departed,
                              Date.parse("2026-09-06T11:25:00Z")), false);
  // No coordinates in the sample: nothing to place.
  assert.equal(landedSighting({ ...base, lat: null, lon: null }, jfk, departed, now), false);
  assert.equal(landedSighting(null, jfk, departed, now), false);
  assert.ok(LANDING_RADIUS_KM >= 5 && LANDING_RADIUS_KM <= 15, "a big hub's stands and runways span several km");
});

// ── The hedge window by kind of leg ──
//
// Mirrors DepartureEvidence.init(mode:) on the device: a train leaves at its
// minute, a ferry takes about ten to clear the harbour, and only an air leg
// gets the airport's learned taxi.
import { taxiPriorForMode } from "../src/ground.ts";

test("a ferry clears the harbour in ten minutes; a train leaves at its minute", () => {
  assert.equal(taxiPriorForMode("sea", 35), 10);
  assert.equal(taxiPriorForMode("rail", 35), 0);
});

test("an air leg keeps the airport's learned taxi", () => {
  assert.equal(taxiPriorForMode("air", 35), 35);
  assert.equal(taxiPriorForMode(null, 35), 35);
});
