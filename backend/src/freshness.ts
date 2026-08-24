/// The two timestamps on a shared flight, and what they mean.
///
/// `updated_at` answers "did anything CHANGE?" — the traveller's device wrote
/// this row, or the cron found the provider had something new. Its age is how
/// the cron decides whether the device is still talking, so it must not be
/// stamped merely because the cron looked.
///
/// `checked_at` answers "when did we last LOOK?" — stamped on every
/// consultation, differing answer or not.
///
/// Conflating them cost Arc the whole friend-liveness feature. A flight that
/// was simply stable — cruising, on time, gates already known — matched the
/// provider on every tick, so nothing was ever written, so the friend's screen
/// read `updated_at` and said "Updated 9h ago" about a row the server had
/// confirmed sixty seconds earlier. It never reached the ten-minute window in
/// which the app says "Live", and the map bubble (which wants a fix under
/// fifteen minutes old) never appeared at all.

/// How long a verified-but-unchanged row may go unstamped. Comfortably inside
/// the ten minutes the app allows before it stops saying "Live", so a stable
/// flight still reads as live without costing a write every minute.
export const CHECK_STAMP_INTERVAL_MS = 4 * 60_000;

/// Whether this tick should write the row at all.
export function shouldWriteSharedRow(a: {
  changed: boolean;
  checkedAt?: string | null;
  now: number;
}): boolean {
  if (a.changed) return true;
  if (!a.checkedAt) return true;
  const t = Date.parse(a.checkedAt);
  if (!Number.isFinite(t)) return true;
  return a.now - t > CHECK_STAMP_INTERVAL_MS;
}

/// Whether a consultation actually produced a CURRENT answer about this row.
///
/// `fetchLegsCached` reports how it answered. "miss" reached the provider;
/// "hit" was served from a cache entry still inside its TTL. Both are current
/// answers, and both mean we looked. "stale" and "none" mean the fetch could
/// not be made at all — no budget left, no key, a provider fault — and whatever
/// came back with them is old.
///
/// The distinction exists because an EMPTY answer is a legitimate one. A flight
/// further out than the provider publishes schedules for has no leg, and saying
/// so is still verification: it is how a friend's screen learns that the row was
/// looked at just now rather than abandoned since the traveller last opened
/// their app. A fetch that never landed must not make that claim.
export function providerAnswered(cache: "hit" | "stale" | "miss" | "none"): boolean {
  return cache === "hit" || cache === "miss";
}

/// The later of two ISO stamps, either of which may be absent — what every
/// reader of this row should treat as "how old is this".
export function laterISO(a: string | null | undefined,
                         b: string | null | undefined): string | null {
  const ta = a ? Date.parse(a) : NaN;
  const tb = b ? Date.parse(b) : NaN;
  if (!Number.isFinite(ta)) return Number.isFinite(tb) ? b! : null;
  if (!Number.isFinite(tb)) return a!;
  return ta >= tb ? a! : b!;
}

/// How often the cron should re-consult the provider about a shared row, by
/// how far out the flight is — or null when the row is out of scope entirely.
///
/// The window used to start four hours before departure, full stop. Outside
/// it, `shared_flights` was written by exactly one thing: the traveller's own
/// device, on its 60-second tracker poll, while their app happened to be
/// running. So a friend looking at a flight leaving this evening saw whatever
/// that phone last said — which is why "9h ago" was not a bug at all in that
/// window, just the truth about how little was watching.
///
/// Widening it is nearly free: the fetch rides the same budget-guarded,
/// shared leg cache the rest of the cron uses, and a flight twenty hours out
/// needs looking at once an hour, not once a minute. What it buys is the
/// thing friends actually care about before a trip — a cancellation, a
/// schedule move, a gate — arriving without anyone opening anything.
export function sharedRowCheckInterval(a: {
  depMs: number;
  arrMs: number;
  now: number;
}): number | null {
  const { depMs, arrMs, now } = a;
  if (now > arrMs + 45 * 60_000) return null;        // done, and past its grace
  if (now > depMs - 4 * 3600_000) return 0;          // live window: every tick it is due
  if (now > depMs - 12 * 3600_000) return 30 * 60_000;
  if (now > depMs - 30 * 3600_000) return 60 * 60_000;
  return null;                                        // too far out to be news
}

/// Whether this row is due, given when it was last consulted.
export function sharedRowIsDue(a: {
  depMs: number;
  arrMs: number;
  checkedAt?: string | null;
  now: number;
}): boolean {
  const interval = sharedRowCheckInterval(a);
  if (interval === null) return false;
  if (!a.checkedAt) return true;
  const t = Date.parse(a.checkedAt);
  if (!Number.isFinite(t)) return true;
  return a.now - t >= interval;
}
