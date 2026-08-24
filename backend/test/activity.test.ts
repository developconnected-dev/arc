import test from "node:test";
import assert from "node:assert/strict";
import { contentState } from "../src/activity.ts";

/// Seconds between the unix epoch and Apple's reference date (2001-01-01).
/// ActivityKit decodes remote content-state with a default JSONDecoder, whose
/// Date strategy is timeIntervalSinceReferenceDate — not unix epoch, not ISO.
const APPLE_EPOCH = 978307200;
const iso = (ms: number) => new Date(ms).toISOString();

const DEP = Date.parse("2026-08-24T09:00:00Z");
const ARR = Date.parse("2026-08-24T11:30:00Z");

/// Every field `FlightActivityAttributes.ContentState` declares. A push that
/// omits one does not error — ActivityKit decodes the missing key into nil
/// and the lock screen silently loses whatever it showed.
const CONTRACT = [
  "status", "departureTime", "arrivalTime", "boardingTime", "delayMinutes",
  "arrivalDelayMinutes", "insight", "companions", "updatedAt",
  "departureGate", "departureTerminal", "arrivalGate", "arrivalTerminal",
  "baggageClaim", "progress", "offBlock", "estimatedTakeoff", "actualDeparture",
  "groundState", "groundObservedAt", "taxiStartedAt", "lastSeenOnGround",
  "taxiPriorMinutes",
];

test("every field of the Swift content-state contract is emitted", () => {
  const s = contentState("scheduled", DEP, ARR, 0, 0, null);
  for (const key of CONTRACT) {
    assert.ok(key in s, `content-state is missing "${key}" — the app decodes it as nil`);
  }
});

test("dates are Apple reference-date seconds, not unix epoch", () => {
  const s = contentState("scheduled", DEP, ARR, 0, 0, null);
  assert.equal(s.departureTime, DEP / 1000 - APPLE_EPOCH);
  assert.equal(s.arrivalTime, ARR / 1000 - APPLE_EPOCH);
});

test("taxi evidence survives the push instead of resetting to a clock guess", () => {
  const seen = iso(DEP - 5 * 60_000);
  const taxiFrom = iso(DEP + 2 * 60_000);
  const s = contentState("scheduled", DEP, ARR, 0, 0, null, null, {
    offBlockMs: DEP,
    taxiPrior: 27,
    evidence: {
      ground_state: "taxiing",
      ground_observed_at: taxiFrom,
      taxi_started_at: taxiFrom,
      last_seen_on_ground: seen,
    },
  });
  assert.equal(s.groundState, "taxiing");
  assert.equal(s.taxiStartedAt, Date.parse(taxiFrom) / 1000 - APPLE_EPOCH);
  assert.equal(s.groundObservedAt, Date.parse(taxiFrom) / 1000 - APPLE_EPOCH);
  assert.equal(s.lastSeenOnGround, Date.parse(seen) / 1000 - APPLE_EPOCH);
  // The learned taxi-out, not the 20-minute bootstrap constant.
  assert.equal(s.taxiPriorMinutes, 27);
});

test("no sighting means no claim — never a fabricated one", () => {
  const s = contentState("scheduled", DEP, ARR, 0, 0, null, null,
                         { offBlockMs: DEP, taxiPrior: 20 });
  assert.equal(s.groundState, null);
  assert.equal(s.groundObservedAt, null);
  assert.equal(s.taxiStartedAt, null);
  assert.equal(s.lastSeenOnGround, null);
});

test("an unparseable evidence stamp is dropped, not passed through as NaN", () => {
  const s = contentState("scheduled", DEP, ARR, 0, 0, null, null, {
    offBlockMs: DEP, taxiPrior: 20,
    evidence: { ground_state: "taxiing", ground_observed_at: "not a date" },
  });
  assert.equal(s.groundObservedAt, null);
});

test("device-only facts are echoed back, not blanked", () => {
  const companions = [{ name: "Mia", seat: "14C", avatarFile: "la-avatars/mia.png" }];
  const s = contentState("scheduled", DEP, ARR, 0, 0, null, null, {
    offBlockMs: DEP, taxiPrior: 20,
    local: { boarding_lead_minutes: 35, companions },
  });
  assert.deepEqual(s.companions, companions);
  // Boarding travels as a LEAD so it keeps tracking the delay-adjusted
  // off-block time rather than going stale at the original schedule.
  assert.equal(s.boardingTime, (DEP - 35 * 60_000) / 1000 - APPLE_EPOCH);
});

test("a delayed departure carries boarding with it", () => {
  const delayed = DEP + 40 * 60_000;
  const s = contentState("scheduled", delayed, ARR, 40, 40, null, null, {
    offBlockMs: delayed, taxiPrior: 20, local: { boarding_lead_minutes: 35 },
  });
  assert.equal(s.boardingTime, (delayed - 35 * 60_000) / 1000 - APPLE_EPOCH);
});

test("a confirmed take-off is reported; an estimate is not promoted to one", () => {
  const est = "2026-08-24T09:22:00Z";
  const s = contentState("scheduled", DEP, ARR, 0, 0,
                         { dep_runway_estimated: est }, null,
                         { offBlockMs: DEP, taxiPrior: 20 });
  assert.equal(s.estimatedTakeoff, Date.parse(est) / 1000 - APPLE_EPOCH);
  assert.equal(s.actualDeparture, null);
});

test("progress is clamped and never runs past the arrival", () => {
  const past = contentState("landed", DEP - 86400_000, ARR - 86400_000, 0, 0, null);
  assert.equal(past.progress, 1);
  const future = contentState("scheduled", Date.now() + 3600_000, Date.now() + 7200_000, 0, 0, null);
  assert.equal(future.progress, 0);
});
