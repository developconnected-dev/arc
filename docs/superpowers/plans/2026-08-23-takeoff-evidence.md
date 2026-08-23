# Takeoff Evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Arc surface (flyer app/widget/Live Activity, friends feed/map/detail, share page) says whether a flight has *actually* taken off based on evidence — ADS-B from the server, sensors on the flyer's phone — and hedges honestly when it has none, instead of asserting "In Air" 20 minutes after a timetable number.

**Architecture:** One pure function, `DepartureEvidence.phase(...)` (in `Shared/`, so app + widget share it; ported to JS for the share page), turns the facts a surface has — off-block time, estimated wheels-up, last ADS-B ground observation, confirmed departure, learned taxi-out prior — into a `DeparturePhase` (`beforeDeparture / departing / taxiing / presumedAirborne / airborne`). The Worker cron becomes an ADS-B witness for shared flights (ground state, taxi start, wheels-up, live position) and records taxi-out times per airport so the grace is learned, not hard-coded. An opt-in on-device takeoff sensor (barometer + motion, kept alive by a bounded background-location session) confirms takeoff for the flyer even in airplane mode.

**Tech Stack:** Swift 6 / SwiftUI / SwiftData / WidgetKit / ActivityKit / CoreMotion / CoreLocation; Cloudflare Worker (TypeScript, node:test); Supabase (Postgres migrations via `supabase db push`); airplanes.live ADS-B; AeroDataBox.

**Why this shape (from the incident):** flyer boarded on time, then 30+ min taxi/ATC hold; her widget committed to "In Air" at scheduled+20m on the clock. Fix: (1) friends' surfaces get truth from ADS-B ("Taxiing · 24m") regardless of her phone; (2) her offline surfaces hedge against *expected wheels-up* (estimated runway time or the airport's learned taxi-out p85), anchored on the last moment a source saw the aircraft on the ground, and fall to a muted "Presumed airborne" rather than a green fact; (3) her phone can feel the climb itself.

---

## File map

**Backend (`backend/`)**
- Modify `src/legs.ts` — `confirmedRunwayTime` requires a *departure* runway time to be ≤ now; new `movementIsLive(quality)`.
- Modify `src/index.ts` `mapLeg` — emit `dep_runway_estimated`, `dep_live`.
- Create `src/ground.ts` — pure: `classifyGround(sample)`, `GroundState`, `taxiPriorMinutes(observations, hourUTC)`, `expectedWheelsUp(...)`.
- Modify `src/index.ts` — cron: `watchAircraft(env)` (ADS-B poll for shared_flights in the takeoff window, writes ground_state/taxi_started_at/airborne, live position, taxi observation); `GET /taxi/prior`; share payload + page JS use the evidence.
- Create `supabase/migrations/016_ground_evidence.sql` — `shared_flights` + `aircraft_registration, aircraft_icao24, ground_state, ground_observed_at, taxi_started_at, est_takeoff, live_source`; new `taxi_observations`.
- Tests: `test/ground.test.ts`, extend `test/legs.test.ts`.

**Shared (`Shared/`, compiled into app + widget)**
- Create `Shared/DepartureEvidence.swift` — `DeparturePhase`, `DepartureEvidence` struct + `phase(at:)` + `expectedWheelsUp`.
- Modify `Shared/WidgetData.swift` — carry evidence fields; `isDepartingUnconfirmed(at:)` and `statusText` use `DepartureEvidence`.
- Modify `Shared/FlightActivityAttributes.swift` — ContentState gains optional evidence fields.

**App (`Arc/`)**
- Modify `Arc/Models/Flight.swift` — new optional stored fields; `departureEvidence` accessor.
- Modify `Arc/Models/Flight+Display.swift` — `statusText`, `bannerHeadline`, `bannerColor`, `cardTopRight*`, `isDepartingUnconfirmed` from the phase.
- Modify `Arc/Services/FlightAPIClient.swift` — decode `dep_runway_estimated`, `dep_live`; `taxiPrior(iata:)`.
- Modify `Arc/Services/FlightTracker.swift` — apply the new leg fields; poll position from gate-closed/T−15 (not only `isActive`); derive ground state on-device from `on_ground`/velocity; taxi prior once per session.
- Modify `Arc/Services/SupabaseClient.swift` — `SharedFlight` decodes evidence columns; `shareFlight` writes registration/icao24/ground evidence.
- Modify `Arc/Services/FriendsStore.swift` — `transientFlight` carries evidence; `FriendFlightMath.isAirborne/chip` use `DepartureEvidence`; periodic refresh while the Friends tab is up.
- Modify `Arc/Features/Friends/FriendsView.swift` — row `statusMini/contextLine` use the phase (TAXIING / DEPARTING / PRESUMED).
- Modify `Arc/Services/LiveActivityManager.swift` — state carries evidence; `staleDate` = expected wheels-up.
- Modify `Arc/Services/WidgetSync.swift` — snapshot carries evidence.
- Modify `ArcWidget/WidgetRefresh.swift` — `Leg` decodes `dep_actual`, `dep_runway_estimated`; `apply` preserves `actualDeparture`.
- Modify `ArcWidget/NextFlightWidget.swift` — timeline flip at expected wheels-up; "Taxiing/Presumed airborne" labels.
- Modify `ArcWidget/FlightLiveActivity.swift` — `effectivePhase` from `DepartureEvidence`; taxiing layout (Flighty-style "Taxiing · 13m · takeoff ~22:21").
- Create `Arc/Services/TakeoffSensor.swift` — barometer/motion detector + background-location keepalive; `Arc/Features/Settings/SettingsView.swift` toggle; `project.yml` Info keys.
- Modify `Arc/Features/Root/DemoSeed.swift` — `-laDemoTaxi`, `-simulateTakeoff` harnesses.
- Tests: `ArcTests/DepartureEvidenceTests.swift`, extend `FlightDisplayTests`, `FriendsFeedTests`, `FriendFlightMathTests`, new `TakeoffSensorTests.swift`.

---

## Phase 1 — Server: ADS-B witness, taxi state, learned taxi prior

### Task 1: Departure runway time must be in the past; expose estimate + live quality

**Files:** `backend/src/legs.ts`, `backend/src/index.ts:66-117`, `backend/test/legs.test.ts`

- [ ] Test (append to `test/legs.test.ts`):
```ts
test("a departure runway time still in the future is an estimate even when the status says Departed", () => {
  assert.equal(confirmedRunwayTime("2026-09-18T10:20:00Z", "Departed", "dep", NOW), null);
  assert.equal(confirmedRunwayTime("2026-09-18T09:58:00Z", "Departed", "dep", NOW), "2026-09-18T09:58:00.000Z");
});
test("movementIsLive reads AeroDataBox's quality array", () => {
  assert.equal(movementIsLive(["Basic", "Live"]), true);
  assert.equal(movementIsLive(["Basic", "Approximate"]), false);
  assert.equal(movementIsLive(undefined), false);
});
```
- [ ] Run `npm test` → 2 failures. Implement in `legs.ts`: in `confirmedRunwayTime`, after `confirmed.has(key)`, `return side === "dep" && new Date(iso).getTime() > now.getTime() ? null : iso;`. Add `export function movementIsLive(q: unknown): boolean { return Array.isArray(q) && q.some(x => String(x).toLowerCase() === "live"); }`.
- [ ] In `mapLeg` add `dep_runway_estimated: depRunway ? null : toISO(dep.runwayTime?.utc ?? dep.runwayTime?.local) || null` and `dep_live: movementIsLive(dep.quality)`.
- [ ] `npm test` green → commit `backend: a departure runway time in the future is an estimate, and say whether the leg is live`.

### Task 2: `ground.ts` — classify ADS-B samples, learn taxi-out

**Files:** create `backend/src/ground.ts`, `backend/test/ground.test.ts`

- [ ] Tests:
```ts
import { classifyGround, taxiPriorMinutes, expectedWheelsUp } from "../src/ground.ts";
test("classifyGround", () => {
  assert.equal(classifyGround({ on_ground: true, velocity: 0.5 }), "at_gate");
  assert.equal(classifyGround({ on_ground: true, velocity: 6 }), "taxiing");
  assert.equal(classifyGround({ on_ground: false, altitude: 400, velocity: 80 }), "airborne");
  assert.equal(classifyGround({ on_ground: false, altitude: 0, velocity: 0 }), "unknown");
  assert.equal(classifyGround(null), "unknown");
});
test("taxiPriorMinutes is the p85 of same-hour-ish samples, falling back by breadth then default", () => {
  const obs = [10,12,14,15,18,22,30].map(m => ({ taxi_minutes: m, hour_utc: 7 }));
  assert.equal(taxiPriorMinutes(obs, 7), 22);
  assert.equal(taxiPriorMinutes(obs, 20), 22);          // no same-hour samples → all samples
  assert.equal(taxiPriorMinutes([{taxi_minutes: 9, hour_utc: 7}], 7), 20); // < 3 samples → default
  assert.equal(taxiPriorMinutes([], 7), 20);
});
test("expectedWheelsUp takes the latest of estimate, off-block+prior, last-on-ground+prior", () => {
  const t = (m: number) => new Date(Date.UTC(2026, 8, 18, 10, m)).getTime();
  assert.equal(expectedWheelsUp({ offBlock: t(0), priorMinutes: 20 }), t(20));
  assert.equal(expectedWheelsUp({ offBlock: t(0), priorMinutes: 20, estimate: t(25) }), t(25));
  assert.equal(expectedWheelsUp({ offBlock: t(0), priorMinutes: 20, lastOnGround: t(30) }), t(50));
});
```
- [ ] Implement:
```ts
export type GroundState = "at_gate" | "taxiing" | "airborne" | "unknown";
export function classifyGround(p: { on_ground?: boolean; velocity?: number; altitude?: number } | null | undefined): GroundState {
  if (!p) return "unknown";
  const v = p.velocity ?? 0, alt = p.altitude ?? 0;
  if (p.on_ground) return v >= 3 ? "taxiing" : "at_gate";   // 3 m/s ≈ 6 kt: pushback reads as taxiing
  return alt > 30 || v > 40 ? "airborne" : "unknown";
}
export const DEFAULT_TAXI_PRIOR = 20;
export function taxiPriorMinutes(obs: { taxi_minutes: number; hour_utc: number }[], hourUTC: number): number {
  const near = obs.filter(o => Math.min(Math.abs(o.hour_utc - hourUTC), 24 - Math.abs(o.hour_utc - hourUTC)) <= 2);
  const pool = near.length >= 3 ? near : obs;
  if (pool.length < 3) return DEFAULT_TAXI_PRIOR;
  const s = pool.map(o => o.taxi_minutes).sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(0.85 * (s.length - 1)))];
}
export function expectedWheelsUp(a: { offBlock: number; priorMinutes: number; estimate?: number | null; lastOnGround?: number | null }): number {
  const prior = a.priorMinutes * 60_000;
  return Math.max(a.offBlock + prior, a.estimate ?? 0, (a.lastOnGround ?? 0) + (a.lastOnGround ? prior : 0));
}
```
- [ ] Green → commit `backend: ground.ts — what an ADS-B sample says, and how long this airport taxis`.

### Task 3: Migration 016 + cron ADS-B watcher + `/taxi/prior`

**Files:** `supabase/migrations/016_ground_evidence.sql`, `backend/src/index.ts`

- [ ] Migration:
```sql
alter table public.shared_flights
  add column if not exists aircraft_registration text,
  add column if not exists aircraft_icao24 text,
  add column if not exists ground_state text,          -- at_gate | taxiing | airborne
  add column if not exists ground_observed_at timestamptz,
  add column if not exists taxi_started_at timestamptz,
  add column if not exists est_takeoff timestamptz,     -- provider's estimated wheels-up
  add column if not exists live_source text;            -- 'device' | 'adsb'
create table if not exists public.taxi_observations (
  id uuid primary key default gen_random_uuid(),
  departure_iata text not null,
  flight_number text not null,
  flight_date date not null,
  hour_utc int not null,
  taxi_minutes int not null,
  observed_at timestamptz not null default now(),
  unique (flight_number, departure_iata, flight_date)
);
alter table public.taxi_observations enable row level security;
create index if not exists idx_taxi_obs_airport on public.taxi_observations(departure_iata, observed_at desc);
```
- [ ] `watchAircraft(env)` in index.ts, called from `runLiveActivityCron` every tick: select shared_flights where mode=air, status not in (landed,cancelled), `actual_departure is null`, `scheduled_departure` in [now−3h, now+45m] (covers delays) and `now ≥ scheduled+delay−20m`; for each (cap 10/tick, shuffled), resolve identifier: `aircraft_icao24 ?? aircraft_registration` (if both null, fetch leg via `fetchLegsCached(..., "cron")` once and PATCH them in). Fetch airplanes.live (factor the inline fetch into `fetchADSB(kind, value)`), `classifyGround`. Write: `ground_state`, `ground_observed_at = now`, `live_lat/lon/altitude/speed` + `live_source='adsb'` (only if row.updated_at older than 3 min or live_source='adsb'); `taxi_started_at` on first `taxiing` (keep existing); on `airborne`: `actual_departure = now` (only if null), `status='active'`, and upsert a `taxi_observations` row with `taxi_minutes = round((now − (taxi_started_at ?? scheduled+delay))/60000)` and `hour_utc`. Also `est_takeoff` from the leg's `dep_runway_estimated` when the leg was fetched.
- [ ] `GET /taxi/prior?iata=ZRH&hour=7` → `{ minutes, samples }` from the last 60 observations at that airport.
- [ ] `refreshSharedFlights` PATCH also writes `est_takeoff: leg.dep_runway_estimated ?? row.est_takeoff` and never overwrites `actual_departure` set by ADS-B (already coalesces).
- [ ] `npm test`, `npx wrangler deploy --dry-run`, `supabase db push`, `npx wrangler deploy`. Verify with a real flight: pick one taxiing now from airplanes.live, share it from the simulator, watch the row. Commit `backend: the cron watches the aircraft — taxi, wheels-up and position from ADS-B, taxi-out learned per airport`.

### Task 4: Share page uses the evidence

- [ ] `loadSharePayload` adds `ground: { state, observedAt, taxiStartedAt }`, `dep.estTakeoff`, `taxiPrior` (from `/taxi/prior` logic inline, default 20).
- [ ] Page JS: port `DepartureEvidence.phase` — `phase()` returns `'pre' | 'departing' | 'taxiing' | 'presumed' | 'air' | 'landing' | 'landed' | 'cancelled'`; chip text: "Departing", "Taxiing · Nm", "Presumed airborne" (ghost class), "In air" (only with `dep.actual`). Verify in the in-app browser. Commit.

## Phase 2 — Shared model + flyer surfaces

### Task 5: `Shared/DepartureEvidence.swift`

- [ ] Tests `ArcTests/DepartureEvidenceTests.swift` covering: before departure; departing inside the window; taxiing when a fresh ground observation says so even past the window; presumedAirborne after expected wheels-up with no fresh evidence; airborne when confirmed; expectedWheelsUp = max(offBlock+prior, estimate, lastOnGround+prior); fresh "on ground" observation older than 15 min no longer blocks; hard cap (expected+90m → presumed even with stale evidence); non-air modes use prior 0.
- [ ] Implement:
```swift
public enum DeparturePhase: Equatable { case beforeDeparture, departing, taxiing(since: Date?), presumedAirborne, airborne }
public struct DepartureEvidence {
    public var offBlock: Date                // scheduled + delay (gate departure)
    public var estimatedTakeoff: Date?       // provider's estimated runway time
    public var actualDeparture: Date?        // a reported fact (provider, ADS-B or sensor)
    public var groundState: String?          // at_gate | taxiing | airborne
    public var groundObservedAt: Date?
    public var taxiStartedAt: Date?
    public var lastSeenOnGround: Date?       // last successful refresh that still showed no departure
    public var taxiPriorMinutes: Int = 20
    public var isLiveCovered: Bool = true
    public static let freshWindow: TimeInterval = 15 * 60
    public static let hardCap: TimeInterval = 90 * 60
    public var expectedWheelsUp: Date { ... }
    public func phase(at now: Date) -> DeparturePhase { ... }
}
```
- [ ] Commit `shared: one answer to "has it left?" — DepartureEvidence`.

### Task 6: Flight model + API + tracker

- [ ] `Flight`: `var estimatedTakeoff: Date?`, `groundStateRaw: String?`, `groundObservedAt: Date?`, `taxiStartedAt: Date?`, `taxiPriorMinutes: Int?`, `departureLiveCovered: Bool?`, `lastSeenOnGround: Date?`. `var departureEvidence: DepartureEvidence`, `var departurePhase: DeparturePhase`.
- [ ] `FlightSearchResult`: `var dep_runway_estimated: String? = nil`, `var dep_live: Bool? = nil`. `FlightAPIClient.taxiPrior(iata:hour:)`.
- [ ] `refreshAirLeg`: apply both; set `lastSeenOnGround = .now` when the leg has no `dep_actual` and status is pre-departure. Position poll from `offBlock − 15 min` while `actualDeparture == nil` (not just `isActive`), 60 s cadence in that window; on sample: `groundStateRaw = classify`, `groundObservedAt = .now`, `taxiStartedAt` on first taxiing, and on airborne set `actualDeparture = .now`, status active. Taxi prior fetched once per session for air legs < 48h.
- [ ] Clock-healing block: flip to active at `expectedWheelsUp` instead of `depTime`.
- [ ] Tests in `FlightDisplayTests`; commit.

### Task 7: Flyer display — three states

- [ ] `Flight+Display`: `isDepartingUnconfirmed` → `departurePhase` is `.departing/.taxiing`; `statusText`: "Departing", "Taxiing · 12m", "Presumed airborne", "In Air" only for `.airborne`; `bannerHeadline` mirrors; colours: muted for departing/taxiing/presumed. `FlightDetailView` tracking subtitle "No takeoff confirmation yet · as of HH:mm" for presumed.
- [ ] Widget: `WidgetFlight` gains `estimatedTakeoff, groundState, groundObservedAt, taxiStartedAt, lastSeenOnGround, taxiPriorMinutes` (decodeIfPresent); `evidence(at:)`; `statusText` "Taxiing"/"Presumed airborne"; timeline flips at `expectedWheelsUp` (+ hardCap); colour rules. `WidgetRefresh.Leg` decodes `dep_actual`, `dep_runway_estimated`; `apply` preserves/updates them and stamps `lastSeenOnGround`.
- [ ] Live Activity: ContentState `var estimatedTakeoff: Date? = nil`, `groundState: String? = nil`, `groundObservedAt`, `taxiStartedAt`, `lastSeenOnGround`, `taxiPriorMinutes: Int? = nil`. `effectivePhase` → `DepartureEvidence`; new `taxiingView` ("Taxiing · 13m", "Takeoff ~22:21"); `presumed` flavour of inFlight (muted, "not yet confirmed"); `staleDate` = `expectedWheelsUp`, then `expectedWheelsUp + hardCap`, then arrival. Worker push mirrors (`stale-date`).
- [ ] Simulator: `-laDemoTaxi` harness; real flight end-to-end. Commit per surface.

## Phase 3 — Friends

### Task 8: SharedFlight evidence → friends' surfaces
- [ ] `SharedFlight` decodes new columns (defaults nil). `shareFlight` writes `aircraft_registration`, `aircraft_icao24`, `ground_state`, `ground_observed_at`, `taxi_started_at`, `est_takeoff`, `live_source: "device"`.
- [ ] `FriendFlightMath.evidence(f) -> DepartureEvidence`; `isAirborne` = phase ∈ {presumed, airborne}; `chip`: TAXIING / DEPARTING / PRESUMED; `FriendsView` row `statusMini` + `contextLine` ("Taxiing for 14m", "Takeoff not yet confirmed"); `transientFlight` carries evidence so the sheet agrees.
- [ ] `FriendsStore`: while Friends tab foreground and any friend leg within [dep−30m, expectedWheelsUp+30m], refresh every 60 s (ADS-B cron cadence).
- [ ] Two-simulator test: flyer shares a real flight from sim A; sim B (friend) sees Taxiing → In air as the cron observes it. Commit.

## Phase 4 — On-device takeoff sensor (opt-in)

### Task 9: `TakeoffSensor`
- [ ] Pure detector `TakeoffDetector` (testable): feed `(t, relativeAltitudeM, forwardAccelG?)`; fires when relative altitude rises ≥ 150 m within 6 min *or* a sustained ≥ 0.25 g for ≥ 25 s followed by altitude rise ≥ 60 m; never fires on ground noise (±20 m drift). Tests with synthetic traces (taxi hold 40 min flat → no fire; climb → fires within 3 min of rotation).
- [ ] `TakeoffSensor` (MainActor service): arms when a flight's `departurePhase` is `.departing/.taxiing` or offBlock−15m ≤ now ≤ expectedWheelsUp+hardCap and the Settings toggle is on; starts `CMAltimeter.startRelativeAltitudeUpdates`, `CMMotionManager` (deviceMotion, 10 Hz), and a `CLLocationManager` (`allowsBackgroundLocationUpdates`, `desiredAccuracy = kCLLocationAccuracyKilometer`, `pausesLocationUpdatesAutomatically = false`) as keepalive; on detection: `flight.actualDeparture = detectedAt`, status active, `groundStateRaw = "airborne"`, update LA + widget, queue `shareFlight` (runs on reconnect). Disarms on detection/cap/landing.
- [ ] `project.yml`: `UIBackgroundModes: [fetch, location]`, `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSMotionUsageDescription`. Settings toggle "Detect takeoff with motion sensors" (off by default) with explanation.
- [ ] Simulator: `-simulateTakeoff` launch arg feeds a synthetic climb trace into the detector; verify LA/widget/share flip without network (simctl: disable network via `xcrun simctl ... ` not available → set backend URL to an unreachable host for the test).
- [ ] Commit `flyer: the phone feels the climb — opt-in takeoff detection from barometer and motion`.

## Phase 5 — Verification matrix (real flights, both perspectives)
- [ ] Flyer: add a real flight departing in ≤30 min on sim A; watch detail/widget/LA through gate→taxi→airborne.
- [ ] Friend: sim B linked via invite; feed chip/map/detail + share page in browser; confirm Taxiing and the confirmed In air arrive from the cron without sim A running (kill the app on A after sharing).
- [ ] Offline flyer: A backend URL unreachable after boarding → surfaces hold "Departing/Taxiing" until expected wheels-up, then "Presumed airborne"; with `-simulateTakeoff` → "In Air".
