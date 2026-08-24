/// The Live Activity wire contract.
///
/// `ContentState` is mirrored field-for-field in `Shared/FlightActivityAttributes.swift`;
/// names and types must change on both sides together or pushes decode into
/// defaults and fail SILENTLY — no error, just a lock screen quietly missing
/// what it used to show.
///
/// The rule that makes this file worth its own module: a Live Activity push
/// REPLACES the entire content state. ActivityKit does not merge. So every
/// field the app can set has to be restated here on every push, or the server
/// erases it — which is precisely how the taxi evidence the device had
/// witnessed was being reset to a clock presumption five minutes later.

export function contentState(
  status: string, depMs: number, arrMs: number, delay: number, arrDelay: number,
  flight: Record<string, any> | null, insight: string | null = null,
  extra: {
    offBlockMs: number;
    taxiPrior: number;
    /// What this token has witnessed about the taxi (see pushUpdateForRow).
    evidence?: Record<string, string | undefined>;
    /// Facts only the device can know, echoed back so a server push does not
    /// erase them. ActivityKit REPLACES the whole content state on every
    /// push — there is no merge — so anything the Worker omits is gone from
    /// the lock screen until the app next runs.
    local?: { boarding_lead_minutes?: number; companions?: unknown[] };
  } | null = null
): Record<string, unknown> {
  const now = Date.now();
  const total = arrMs - depMs;
  const progress = total > 0 ? Math.min(1, Math.max(0, (now - depMs) / total)) : 0;
  const appleEpoch = (ms: number | null | undefined) =>
    ms == null ? null : ms / 1000 - 978307200;
  const iso = (v: string | undefined) => {
    if (!v) return null;
    const t = Date.parse(v);
    return Number.isFinite(t) ? appleEpoch(t) : null;
  };
  const estTakeoff = flight?.["dep_runway_estimated"]
    ? Date.parse(String(flight["dep_runway_estimated"])) : null;
  const depActual = flight?.["dep_actual"] ? Date.parse(String(flight["dep_actual"])) : null;
  const offBlock = extra?.offBlockMs ?? depMs;
  const lead = extra?.local?.boarding_lead_minutes;
  return {
    status,
    departureTime: depMs / 1000 - 978307200,
    arrivalTime: arrMs / 1000 - 978307200,
    // Boarding is an airline-specific lead the DEVICE computes; it travels as
    // that lead in minutes rather than an instant, so it keeps tracking the
    // delay-adjusted off-block time here instead of going stale — or, as it
    // did until now, disappearing from the card on every server push.
    boardingTime: lead == null ? null : appleEpoch(offBlock - lead * 60_000),
    delayMinutes: delay,
    arrivalDelayMinutes: arrDelay,
    insight,
    // Friends on this same flight. The Worker cannot derive these (the
    // avatars are files staged in the device's App Group), so it echoes what
    // the app registered rather than blanking the cluster every five minutes.
    companions: extra?.local?.companions ?? null,
    updatedAt: appleEpoch(now),
    departureGate: flight?.["dep_gate"] ?? null,
    departureTerminal: flight?.["dep_terminal"] ?? null,
    arrivalGate: flight?.["arr_gate"] ?? null,
    arrivalTerminal: flight?.["arr_terminal"] ?? null,
    baggageClaim: flight?.["arr_baggage"] ?? null,
    progress,
    // The gate-to-runway evidence. offBlock travels separately from
    // departureTime because that one prefers a confirmed take-off, and the
    // taxi is measured from the gate — the distinction that stopped a lock
    // screen announcing "In Air" to someone still queueing for the runway.
    offBlock: appleEpoch(offBlock),
    estimatedTakeoff: appleEpoch(Number.isFinite(estTakeoff as number) ? estTakeoff : null),
    actualDeparture: appleEpoch(Number.isFinite(depActual as number) ? depActual : null),
    // Everything DepartureEvidence needs to hold the hedge for THIS airport's
    // real taxi. Omitted until now, so each push reset the lock screen to a
    // clock presumption it had already been taught to distrust.
    groundState: extra?.evidence?.ground_state ?? null,
    groundObservedAt: iso(extra?.evidence?.ground_observed_at),
    taxiStartedAt: iso(extra?.evidence?.taxi_started_at),
    lastSeenOnGround: iso(extra?.evidence?.last_seen_on_ground),
    taxiPriorMinutes: extra?.taxiPrior ?? null,
  };
}
