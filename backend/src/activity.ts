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

import { plausibleEstimatedArrival } from "./legmatch.ts";

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
    local?: {
      boarding_lead_minutes?: number;
      companions?: unknown[];
      seat?: string;
      /// Device-witnessed wheels-up (TakeoffSensor). Echoed so a push
      /// cannot replace 19:41 with the delay-adjusted gate time.
      actual_departure?: string;
    };
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
  const parsedDevice = extra?.local?.actual_departure
    ? Date.parse(String(extra.local.actual_departure)) : NaN;
  const parsedProvider = flight?.["dep_actual"] ? Date.parse(String(flight["dep_actual"])) : NaN;
  const depActual = Number.isFinite(parsedProvider) ? parsedProvider
    : Number.isFinite(parsedDevice) ? parsedDevice : null;
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
    // The traveller's CURRENT seat, echoed from the device's registration.
    // The attributes' copy is frozen when the card starts, so a seat added
    // in the app afterwards exists only here — and null (never registered)
    // tells the widget to fall back to the attributes.
    seat: extra?.local?.seat ?? null,
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

/// The clock every Live Activity surface reads. Same inputs as
/// `ContentState.clock` on the Swift side — a push that used
/// `scheduledArrival + departureDelay` and ignored `arr_estimated` is how
/// VY8462's Island counted 1h 5m while the lock screen counted 26m.
///
/// Lives below `contentState` so the contract check's first `return {`
/// is still the wire payload, not this helper.
export function liveActivityClock(opts: {
  schedDepMs: number;
  schedArrMs: number;
  delay: number;
  depActual?: string | number | null;
  arrActual?: string | number | null;
  arrEstimated?: string | null;
  deviceActualDeparture?: string | number | null;
}): { depMs: number; arrMs: number; delay: number; arrDelay: number; offBlockMs: number } {
  const delay = Math.max(0, Math.round(Number(opts.delay) || 0));
  const offBlockMs = opts.schedDepMs + delay * 60_000;
  // Displayed departure is the GATE time the airline tag describes.
  // Wheels-up (dep_actual / TakeoffSensor) is evidence, not this clock —
  // putting 19:41 next to "5m Late" is a half-updated card (Mira).
  const depMs = offBlockMs;

  const arrActual = parseMs(opts.arrActual);
  const est = typeof opts.arrEstimated === "string"
    ? plausibleEstimatedArrival(opts.arrEstimated, depMs) : null;
  const estMs = est ? Date.parse(est) : NaN;
  const arrMs = arrActual ?? (Number.isFinite(estMs) ? estMs : opts.schedArrMs + delay * 60_000);

  return {
    depMs,
    arrMs,
    delay,
    arrDelay: Math.round((arrMs - opts.schedArrMs) / 60_000),
    offBlockMs,
  };
}

function parseMs(v: string | number | null | undefined): number | null {
  if (v == null || v === "") return null;
  const n = typeof v === "number" ? v : Date.parse(String(v));
  return Number.isFinite(n) ? n : null;
}
