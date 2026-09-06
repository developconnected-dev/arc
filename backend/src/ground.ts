// What the aircraft is doing, from evidence — pure, no network, unit-tested.
//
// Airlines publish gate (off-block) times; nobody publishes the taxi. A
// flight that pushed back on time and then sat 35 minutes at the hold point
// looks, in every airline feed, exactly like one that took off — which is
// why Arc stopped trusting the clock and started watching the aircraft.

export type GroundState = "at_gate" | "taxiing" | "airborne" | "unknown";

/// One ADS-B sample (units as /position returns them: m/s, metres).
export function classifyGround(
  p: { on_ground?: boolean; velocity?: number; altitude?: number } | null | undefined,
): GroundState {
  if (!p) return "unknown";
  const v = p.velocity ?? 0;
  const alt = p.altitude ?? 0;
  // 3 m/s ≈ 6 kt: a pushback already reads as taxiing, which is what a
  // friend wants to know ("they're moving").
  if (p.on_ground) return v >= 3 ? "taxiing" : "at_gate";
  return alt > 30 || v > 40 ? "airborne" : "unknown";
}

/// The grace Arc gives a departure before assuming wheels-up, when the
/// airport has not yet taught it better.
export const DEFAULT_TAXI_PRIOR = 20;

/// p85 taxi-out at an airport for this hour of the day, from observed
/// (taxi start → wheels-up) durations. Same-hour-ish samples first; all of
/// the airport's samples when the hour is thin; the default when the airport
/// itself is thin. p85 rather than the median because the cost of asserting
/// "airborne" while the aircraft is still on the ground is the whole point.
export function taxiPriorMinutes(
  obs: { taxi_minutes: number; hour_utc: number }[], hourUTC: number,
): number {
  const dist = (h: number) => Math.min(Math.abs(h - hourUTC), 24 - Math.abs(h - hourUTC));
  const near = obs.filter(o => dist(o.hour_utc) <= 2);
  const pool = near.length >= 3 ? near : obs;
  if (pool.length < 3) return DEFAULT_TAXI_PRIOR;
  const s = pool.map(o => o.taxi_minutes).sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(0.85 * (s.length - 1)))];
}

/// Below this height a report cannot be told apart from ground noise, so the
/// aircraft is treated as still on the ground and its speed decides whether
/// it is parked, taxiing or rolling. AeroDataBox reports 0 for aircraft on
/// the deck (seen at ZRH, field elevation 1400 ft, reporting 0 ft), so this
/// is a margin rather than a threshold — and erring low here is what keeps a
/// take-off roll from being announced as flight.
export const ADB_GROUND_CEILING_M = 150;

/// AeroDataBox's `location` block (returned by `withLocation=true`, which the
/// leg fetch already asks for) in the units the rest of Arc speaks.
///
/// This is the server's witness: same call, same key, no IP rate limit — the
/// community ADS-B aggregators all refuse Cloudflare's shared egress, and
/// this needs nobody to whitelist anything.
export function adbPositionToSample(loc: Record<string, any> | null | undefined): {
  on_ground: boolean; velocity: number; altitude: number;
  lat: number | null; lon: number | null; reportedAt: string;
} | null {
  if (!loc || !loc.reportedAtUtc) return null;
  const altitude = Number(loc.pressureAltitude?.meter ?? 0);
  const velocity = Number(loc.groundSpeed?.meterPerSecond ?? 0);
  if (!Number.isFinite(altitude) || !Number.isFinite(velocity)) return null;
  // "2026-08-23 11:43" — minutes only and no zone marker, but the field is
  // named ...Utc, so fill in the seconds and say so explicitly.
  let stamp = String(loc.reportedAtUtc).trim().replace(" ", "T");
  if (/T\d{2}:\d{2}$/.test(stamp)) stamp += ":00";
  if (!/[Zz]|[+-]\d{2}:?\d{2}$/.test(stamp)) stamp += "Z";
  const reportedAt = new Date(stamp);
  if (isNaN(reportedAt.getTime())) return null;
  return {
    on_ground: altitude < ADB_GROUND_CEILING_M,
    velocity, altitude,
    lat: typeof loc.lat === "number" ? loc.lat : null,
    lon: typeof loc.lon === "number" ? loc.lon : null,
    reportedAt: reportedAt.toISOString(),
  };
}

/// How far from the arrival airport's reference point an aircraft on the
/// ground still counts as "at" it. A big hub's runways and stands span
/// several kilometres from the point the provider calls the airport.
export const LANDING_RADIUS_KM = 8;

function haversineKm(a: { lat: number; lon: number }, b: { lat: number; lon: number }): number {
  const R = 6371;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat), dLon = toRad(b.lon - a.lon);
  const h = Math.sin(dLat / 2) ** 2
    + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

/// The other end of the flight, from the same evidence that confirms the
/// first: an aircraft seen ON THE GROUND at its destination, after it left,
/// has landed. A status string saying "Arrived" can lag touchdown by an
/// hour, and until now nothing else ever confirmed a landing — every
/// surface kept counting down to an arrival that had already happened.
///
/// Guards: the sighting must be fresh (a stale one says nothing about now),
/// placed (no coordinates, nothing to place), within `LANDING_RADIUS_KM` of
/// the arrival airport (on the ground at Newark is a diversion, not this
/// landing), and after the departure — the tail parked at the destination
/// before this flight left is its previous rotation, not this arrival.
export function landedSighting(
  sample: { on_ground: boolean; velocity: number; altitude: number;
            lat: number | null; lon: number | null; reportedAt: string } | null | undefined,
  arrival: { lat: number; lon: number },
  departedMs: number,
  nowMs: number,
  freshMs = 15 * 60_000,
): boolean {
  if (!sample || sample.lat == null || sample.lon == null) return false;
  const seen = Date.parse(sample.reportedAt);
  if (!Number.isFinite(seen) || nowMs - seen >= freshMs || seen > nowMs + 60_000) return false;
  if (seen <= departedMs + 10 * 60_000) return false;
  const state = classifyGround(sample);
  if (state !== "at_gate" && state !== "taxiing") return false;
  return haversineKm({ lat: sample.lat, lon: sample.lon }, arrival) <= LANDING_RADIUS_KM;
}
