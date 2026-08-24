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
