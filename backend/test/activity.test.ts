import test from "node:test";
import assert from "node:assert/strict";
import { contentState, liveActivityClock, sanitizeLiveActivityLocal, heroArrivalMs } from "../src/activity.ts";

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

// VY8462 on the lock screen vs Dynamic Island: same flight, two writers.
// The Worker used to count arrival as scheduled + *departure* delay and
// ignore arr_estimated, so a push replaced a 35-minute-early ETA with
// "5m Late" and the Island counted down to a time 40 minutes later.
const VY_DEP = Date.parse("2026-09-02T17:45:00Z"); // 19:45 BCN (UTC+2)
const VY_ARR = Date.parse("2026-09-02T20:35:00Z"); // 21:35 LIS (UTC+1)
const VY_EST = "2026-09-02T20:00:00.000Z";         // 21:00 LIS — 35m early
const VY_WHEELS = "2026-09-02T17:41:00.000Z";      // 19:41 BCN wheels-up

test("the Live Activity clock uses the provider's arrival estimate, not departure delay", () => {
  const clock = liveActivityClock({
    schedDepMs: VY_DEP,
    schedArrMs: VY_ARR,
    delay: 5,
    arrEstimated: VY_EST,
  });
  assert.equal(clock.depMs, VY_DEP + 5 * 60_000);
  assert.equal(clock.arrMs, Date.parse(VY_EST));
  assert.equal(clock.delay, 5);
  assert.equal(clock.arrDelay, -35);
  // Gate time stays the taxi origin even when wheels-up is known later.
  assert.equal(clock.offBlockMs, VY_DEP + 5 * 60_000);
});

test("wheels-up is evidence, not the displayed clock — tags and until-gate stay one snapshot", () => {
  // Mira: stale-but-matching over half-updated. Putting 19:41 (wheels-up)
  // next to "5m Late" (gate delay) is a card that disagrees with itself;
  // lock then showed 19:50 and the Island 19:41.
  const clock = liveActivityClock({
    schedDepMs: VY_DEP,
    schedArrMs: VY_ARR,
    delay: 5,
    depActual: VY_WHEELS,
    arrEstimated: VY_EST,
  });
  assert.equal(clock.depMs, VY_DEP + 5 * 60_000);
  assert.equal(clock.arrMs, Date.parse(VY_EST));
  assert.equal(clock.delay, 5);
  assert.equal(clock.arrDelay, -35);
  assert.equal(clock.offBlockMs, VY_DEP + 5 * 60_000);
});

test("a device-witnessed takeoff does not move the displayed departure", () => {
  const clock = liveActivityClock({
    schedDepMs: VY_DEP,
    schedArrMs: VY_ARR,
    delay: 5,
    deviceActualDeparture: VY_WHEELS,
    arrEstimated: VY_EST,
  });
  assert.equal(clock.depMs, VY_DEP + 5 * 60_000);
  assert.equal(clock.arrMs, Date.parse(VY_EST));
});

test("an estimate at or before departure is another operation and is dropped", () => {
  const clock = liveActivityClock({
    schedDepMs: VY_DEP,
    schedArrMs: VY_ARR,
    delay: 5,
    arrEstimated: "2026-09-02T17:40:00.000Z",
  });
  assert.equal(clock.arrMs, VY_ARR + 5 * 60_000);
  assert.equal(clock.arrDelay, 5);
});

test("a push without arr_estimated restates the device hero ETA instead of schedule-plus-delay", () => {
  // ActivityKit REPLACES the whole content state. Local makeState had 21:00
  // (estimatedArrival). A Worker tick whose cached leg omitted arr_estimated
  // used to write 21:40 and take until-gate / Arc ✦ / progress with it.
  const clock = liveActivityClock({
    schedDepMs: VY_DEP,
    schedArrMs: VY_ARR,
    delay: 5,
    deviceEstimatedArrival: VY_EST,
  });
  assert.equal(clock.arrMs, Date.parse(VY_EST));
  assert.equal(clock.arrDelay, -35);
  assert.equal(clock.depMs, VY_DEP + 5 * 60_000);
});

test("the provider's own estimate wins over a stale device echo", () => {
  const newer = "2026-09-02T20:05:00.000Z";
  const clock = liveActivityClock({
    schedDepMs: VY_DEP,
    schedArrMs: VY_ARR,
    delay: 5,
    arrEstimated: newer,
    deviceEstimatedArrival: VY_EST,
  });
  assert.equal(clock.arrMs, Date.parse(newer));
  assert.equal(clock.arrDelay, -30);
});

test("a device actual_departure survives the content-state replace", () => {
  const s = contentState("active", VY_DEP + 5 * 60_000, Date.parse(VY_EST), 5, -35,
                         null, null, {
                           offBlockMs: VY_DEP + 5 * 60_000,
                           taxiPrior: 20,
                           local: { actual_departure: VY_WHEELS },
                         });
  assert.equal(s.actualDeparture, Date.parse(VY_WHEELS) / 1000 - APPLE_EPOCH);
});

test("the APNs payload restates the same clock local makeState would write", () => {
  // sendLiveActivityPush JSON.stringifies this object. ActivityKit replaces
  // the whole state with it — lock and Island both read these fields.
  const clock = liveActivityClock({
    schedDepMs: VY_DEP,
    schedArrMs: VY_ARR,
    delay: 5,
    deviceActualDeparture: VY_WHEELS,
    deviceEstimatedArrival: VY_EST,
  });
  const s = contentState("active", clock.depMs, clock.arrMs, clock.delay, clock.arrDelay,
                         null, null, {
                           offBlockMs: clock.offBlockMs,
                           taxiPrior: 20,
                           local: { actual_departure: VY_WHEELS, estimated_arrival: VY_EST },
                         });
  assert.equal(s.departureTime, (VY_DEP + 5 * 60_000) / 1000 - APPLE_EPOCH);
  assert.equal(s.arrivalTime, Date.parse(VY_EST) / 1000 - APPLE_EPOCH);
  assert.equal(s.delayMinutes, 5);
  assert.equal(s.arrivalDelayMinutes, -35);
  assert.equal(s.actualDeparture, Date.parse(VY_WHEELS) / 1000 - APPLE_EPOCH);
});

test("register keeps the device hero ETA and wheels-up for the next replace", () => {
  // /la/register used to persist only boarding / companions / seat. The
  // extras the device echoed never reached prior.local, so the next APNs
  // push invented schedule+delay and ActivityKit wrote that over 21:00.
  const local = sanitizeLiveActivityLocal({
    boarding_lead_minutes: 40,
    seat: "14C",
    actual_departure: VY_WHEELS,
    estimated_arrival: VY_EST,
    companions: [{ name: "Victoria" }],
  });
  assert.equal(local.estimated_arrival, VY_EST);
  assert.equal(local.actual_departure, VY_WHEELS);
  assert.equal(local.boarding_lead_minutes, 40);
  assert.equal(local.seat, "14C");
  assert.deepEqual(local.companions, [{ name: "Victoria" }]);
});

test("register drops unparseable extras rather than parking them for a push", () => {
  const local = sanitizeLiveActivityLocal({
    estimated_arrival: "not a date",
    actual_departure: "",
    boarding_lead_minutes: 999,
  });
  assert.equal(local.estimated_arrival, undefined);
  assert.equal(local.actual_departure, undefined);
  assert.equal(local.boarding_lead_minutes, undefined);
});

// ── Bug 2b: VY8462 BCN→LIS until-landing jump ──
//
// Scheduled 19:25 BCN / 20:35 LIS. Airline departure delay 25m. Provider
// arrival revision 20:00 LIS. At 20:30 CEST (18:30Z):
//   local card (arr_estimated) → 30m remaining
//   Worker push (schedule + departure delay) → 90m remaining
// That is the ±1 hour flip. It looks like CEST vs WEST; it is two instants.

const VY_SCHED_ARR = Date.parse("2026-09-02T19:35:00.000Z"); // 20:35 LIS (WEST)
const VY_EST_ARR = "2026-09-02T19:00:00.000Z";               // 20:00 LIS
const VY_NOW = Date.parse("2026-09-02T18:30:00.000Z");       // 20:30 CEST / 19:30 WEST

test("until-landing uses arr_estimated, not schedule plus departure delay", () => {
  const hero = heroArrivalMs({
    schedArrMs: VY_SCHED_ARR,
    delayMinutes: 25,
    arrEstimated: VY_EST_ARR,
  });
  assert.equal(hero, Date.parse(VY_EST_ARR));
  assert.equal((hero - VY_NOW) / 60_000, 30);
  // The formula the Worker used to push: 20:35 LIS + 25m = 21:00 LIS = 90m.
  const invented = VY_SCHED_ARR + 25 * 60_000;
  assert.equal((invented - VY_NOW) / 60_000, 90);
  assert.notEqual(hero, invented);
});

test("until-landing remaining is the epoch gap — display TZ does not move it", () => {
  const eta = Date.parse("2026-09-02T19:18:00.000Z"); // 20:18 LIS / 21:18 CEST
  const now = Date.parse("2026-09-02T19:02:00.000Z"); // 20:02 WEST / 21:02 CEST
  assert.equal((eta - now) / 60_000, 16);

  const hhmm = (ms: number, tz: string) =>
    new Intl.DateTimeFormat("en-GB", { timeZone: tz, hour: "2-digit", minute: "2-digit", hour12: false })
      .format(new Date(ms));
  assert.equal(hhmm(eta, "Europe/Lisbon"), "20:18");
  assert.equal(hhmm(eta, "Europe/Madrid"), "21:18");
  // Relabeling the same instant in CEST vs WEST must not change remaining.
  assert.equal((eta - now) / 60_000, 16);
});

test("heroArrivalMs falls back to schedule plus delay only when no estimate exists", () => {
  assert.equal(
    heroArrivalMs({ schedArrMs: VY_SCHED_ARR, delayMinutes: 25 }),
    VY_SCHED_ARR + 25 * 60_000,
  );
});

test("a confirmed landing beats both the estimate and the delay fallback", () => {
  const actual = "2026-09-02T19:22:00.000Z";
  assert.equal(
    heroArrivalMs({
      schedArrMs: VY_SCHED_ARR,
      delayMinutes: 25,
      arrEstimated: VY_EST_ARR,
      arrActual: actual,
    }),
    Date.parse(actual),
  );
});
