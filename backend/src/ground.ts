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

/// When Arc expects the wheels to leave the ground, from what it knows:
/// never before the provider's own estimate, never before off-block plus the
/// airport's taxi-out, and never within a taxi-out of the last moment a
/// witness saw the aircraft on the ground. All epoch milliseconds.
export function expectedWheelsUp(a: {
  offBlock: number; priorMinutes: number; estimate?: number | null; lastOnGround?: number | null;
}): number {
  const prior = a.priorMinutes * 60_000;
  return Math.max(
    a.offBlock + prior,
    a.estimate ?? 0,
    a.lastOnGround ? a.lastOnGround + prior : 0,
  );
}
