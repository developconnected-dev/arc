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

/// How close together a cancelled row and an operating same-route sibling
/// must sit before they are one operation re-filed rather than two flights.
///
/// A reschedule is sometimes filed as TWO rows: the original operation
/// marked cancelled, its replacement a separate leg minutes to a couple of
/// hours away. The closest-by-drift rule alone picks the cancelled row —
/// the stored time IS the original's — and the app then asserts a
/// cancellation for a flight that operates. Within this window, two
/// same-number departures on one route cannot be two operations (no
/// turnaround is that fast, and no airline files one number twice in three
/// hours), so a cancelled row with a living sibling this close is the same
/// flight, moved. Beyond it — a shuttle's other rotation, hours away — the
/// cancellation is real and must stay loud.
export const RESCHEDULE_WINDOW_MS = 3 * 3600_000;

/// A row selection should step away from when the same operation also
/// exists un-disfavoured: a cancellation, or the provider's own
/// "likely cancelled" guess (`cancel_uncertain` — see legs.ts).
function disfavored(leg: Record<string, unknown>): boolean {
  return leg["status"] === "cancelled" || leg["cancel_uncertain"] === true;
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
    if (bestDrift > MAX_LEG_DRIFT_MS) return null;
    // A cancelled (or guess-flagged) winner with an operating sibling inside
    // the reschedule window is the original of a re-filing: the sibling is
    // the flight. Anchored on the cancelled row's own time, not the wanted
    // one — the replacement is close to the operation it replaces. Ties
    // prefer the later sibling; reschedules move flights later.
    if (disfavored(best.leg)) {
      const replacement = dated
        .filter(c => !disfavored(c.leg) && Math.abs(c.depMs - best.depMs) <= RESCHEDULE_WINDOW_MS)
        .sort((a, b) => (Math.abs(a.depMs - best.depMs) - Math.abs(b.depMs - best.depMs))
          || (b.depMs - a.depMs))[0];
      if (replacement) return replacement.leg;
    }
    return best.leg;
  }

  // No leg on this route carries a scheduled time, so none can be
  // date-checked. Taking the first is the old behaviour, kept for the one
  // case where it was never what went wrong.
  return routed[0];
}

/// The delay a stored row should display, measured against ITS OWN schedule
/// rather than the leg's.
///
/// Identical schedules hand the leg's own delay back unchanged, so this is
/// safe everywhere a leg's delay meets a stored scheduled time. Where they
/// differ — a retiming the provider filed as a new scheduled time, or a
/// reschedule adopted from a cancelled row's replacement (see pickLeg) —
/// the shift IS part of the lateness: a row holding 22:00 whose leg departs
/// 22:25 on its own schedule is 25 minutes late for the person who planned
/// around 22:00. Never negative: a flight moved earlier renders at the
/// stored time, the direction it is safe to be wrong in.
export function effectiveDelayMinutes(
  leg: Record<string, unknown> | null | undefined,
  storedScheduledMs: number,
): number {
  const raw = Math.max(0, Math.round(Number(leg?.["delay"] ?? 0) || 0));
  const legSched = Date.parse(String(leg?.["dep_scheduled"] ?? ""));
  if (!Number.isFinite(legSched) || !Number.isFinite(storedScheduledMs)) return raw;
  return Math.max(0, Math.round((legSched + raw * 60_000 - storedScheduledMs) / 60_000));
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
