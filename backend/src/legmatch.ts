/// Which of a flight number's legs is THIS flight.
///
/// A flight number is not a flight. `/flights/number/LX2146/2026-08-24` can
/// answer with two legs, because the provider windows by LOCAL date and
/// LX2146 lands at 00:05: yesterday's departure ARRIVES on today's date, so it
/// comes back alongside today's. Both are ZRH→VLC.
///
/// Selection used to be `find(dep_iata && arr_iata) ?? legs[0]` — route only,
/// never date — so `find` took the first, which is yesterday's and has already
/// landed. A friend's flight still hours from pushback showed "Landed", wore
/// yesterday's gate, and reported its departure as "23h 53m Early": exactly
/// 24 hours minus the 7 minutes yesterday's aircraft was late. The same idiom
/// sat in the Live Activity push loop and the alert watcher, so a lock screen
/// could show yesterday's flight and an alert could announce it.

/// How far a leg's scheduled departure may sit from the row's before it is a
/// DIFFERENT operation rather than a moved one. Airlines retime by hours and
/// the daily sibling is a whole day away, so anything inside half a day is
/// still plausibly this flight and anything beyond it is not.
export const MAX_LEG_DRIFT_MS = 12 * 3600_000;

/// A leg's scheduled departure, in ms, or null when it carries none.
function legDepMs(leg: Record<string, unknown>): number | null {
  const raw = leg["dep_scheduled"];
  if (typeof raw !== "string" || !raw) return null;
  const t = Date.parse(raw);
  return Number.isFinite(t) ? t : null;
}

export function pickLeg<T extends Record<string, unknown>>(
  legs: T[] | null | undefined,
  want: { depIata?: string | null; arrIata?: string | null; scheduledDepMs: number },
): T | null {
  if (!legs || legs.length === 0) return null;

  // Route first: a number that flies two different pairs in a day is two
  // different flights, and no amount of clock proximity makes one the other.
  // Only filter when we actually know the route — rows predating it must
  // still resolve.
  const routed = (want.depIata && want.arrIata)
    ? legs.filter(l => l["dep_iata"] === want.depIata && l["arr_iata"] === want.arrIata)
    : legs;
  if (routed.length === 0) return null;

  const dated = routed
    .map(leg => ({ leg, depMs: legDepMs(leg) }))
    .filter((c): c is { leg: T; depMs: number } => c.depMs !== null);

  if (dated.length > 0) {
    let best = dated[0];
    let bestDrift = Math.abs(best.depMs - want.scheduledDepMs);
    for (const c of dated.slice(1)) {
      const drift = Math.abs(c.depMs - want.scheduledDepMs);
      // Strictly better, so the result cannot depend on the order the
      // provider happened to return them in.
      if (drift < bestDrift) { best = c; bestDrift = drift; }
    }
    // Nothing plausible beats something wrong. Every caller already treats a
    // null leg as "the provider had nothing to say about this row", which is
    // the truthful answer when the only candidate is another day's operation.
    return bestDrift <= MAX_LEG_DRIFT_MS ? best.leg : null;
  }

  // No leg on this route carries a scheduled time, so none can be
  // date-checked. Taking the first is the old behaviour, kept for the one
  // case where it was never what went wrong.
  return routed[0];
}

/// How far before its own schedule a departure may plausibly sit.
///
/// Airlines push back a few minutes early; they do not leave hours early, and
/// they never leave a day early. Anything beyond this is not an early
/// departure, it is another operation's timestamp that reached this row.
export const MAX_EARLY_DEPARTURE_MS = 6 * 3600_000;

/// An `actual_departure` worth carrying forward, or null.
///
/// The row write keeps `row.actual_departure` when the provider reports none,
/// so that a provider null cannot erase what the traveller's own device
/// witnessed. Once yesterday's leg had written its 20:07 into a row scheduled
/// for tonight, that same clause pinned it there permanently — and a carried
/// departure forces the status to "active", so the row went on insisting a
/// flight had left when it had not even boarded.
///
/// Screening it on the way through means a contaminated row heals itself on
/// the next tick instead of needing to be found and repaired by hand. Late
/// departures are left alone: a delay has no ceiling worth asserting here.
export function plausibleActualDeparture(
  actual: string | null | undefined,
  scheduledDepMs: number,
): string | null {
  if (typeof actual !== "string" || !actual) return null;
  const t = Date.parse(actual);
  if (!Number.isFinite(t)) return null;
  if (!Number.isFinite(scheduledDepMs)) return actual;
  return t < scheduledDepMs - MAX_EARLY_DEPARTURE_MS ? null : actual;
}
