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

/// How long to leave one upcoming flight alone between watch checks.
///
/// The watcher covers 3h to 36h before departure — the gap between "too far
/// out for a Live Activity" and "not worth watching yet", and precisely where
/// a cancellation gets filed. One flat interval of 55 minutes covered all of
/// it, which was wrong at both ends: a cancellation three hours out could sit
/// for most of an hour while someone decided whether to leave for the airport,
/// while a flight thirty hours out was re-asked every 55 minutes about a
/// schedule the shared cache was holding for six.
///
/// So the interval tracks what the cache can actually answer. Checking faster
/// than the cache's own TTL re-reads the same bytes; checking slower than it
/// wastes the freshness already paid for. The far band is now LOOSER than the
/// 55 minutes it replaces, and that is what pays for the near bands.
export function watchIntervalMs(depMs: number, now: number): number {
  if (!Number.isFinite(depMs)) return 30 * 60_000;
  const until = depMs - now;
  if (until < 8 * 3600_000) return 15 * 60_000;   // the last hours before the card
  if (until < 24 * 3600_000) return 30 * 60_000;  // the night before
  return 3 * 3600_000;                            // a day and a half out
}

/// The floor the SQL prefilter uses. It selects on one interval for every row,
/// so it has to be the tightest any row can want — anything longer would leave
/// a due flight unselected and `watchIntervalMs` would never see it.
export const WATCH_MIN_INTERVAL_MS = 15 * 60_000;

// ── The AeroDataBox budget gate ──

/// The plan is denominated in UNITS, and a unit is not a call: this key holds
/// the PRO plan's 6,000 units/month, and this workload measures about two
/// units per call (the by-number endpoint bills per included data block;
/// airport boards cost more). The Worker's own counters count CALLS, and the
/// provider's `x-ratelimit-requests-remaining` counts UNITS — the old gate
/// added the two together, so the Worker still saw headroom while RapidAPI
/// mailed "100% reached". Every comparison here converts calls to estimated
/// units before mixing currencies. The constants only bootstrap a fresh
/// month: after the first response, the provider's own number governs.
export const ADB_MONTHLY_UNITS = 6000;
export const ADB_UNITS_PER_CALL = 2;
/// The cron may spend at most this share of the bootstrap month.
export const ADB_CRON_SHARE = 0.6;
/// Once the provider's remaining is known, the cron stands down while this
/// share of the observed plan is still left — an interactive search must
/// always have quota behind it, so only searches may spend the last of it.
export const ADB_CRON_RESERVE_SHARE = 0.25;

export function adbGate(
  source: "cron" | "interactive",
  cronCalls: number,
  totalCalls: number,
  remainingUnits: number | null | undefined,
): { blocked: boolean; estUnitsUsed: number; planUnits: number; cronReserveUnits: number } {
  const estUnitsUsed = totalCalls * ADB_UNITS_PER_CALL;
  const planUnits = typeof remainingUnits === "number"
    ? estUnitsUsed + remainingUnits
    : ADB_MONTHLY_UNITS;
  const cronReserveUnits = Math.max(100, Math.floor(planUnits * ADB_CRON_RESERVE_SHARE));
  const blocked = typeof remainingUnits === "number"
    ? remainingUnits <= (source === "cron" ? cronReserveUnits : 0)
    : source === "cron"
      ? cronCalls * ADB_UNITS_PER_CALL >= ADB_MONTHLY_UNITS * ADB_CRON_SHARE
      : estUnitsUsed >= ADB_MONTHLY_UNITS;
  return { blocked, estUnitsUsed, planUnits, cronReserveUnits };
}

/// When the provider's quota window rolls over, from the
/// `x-ratelimit-requests-reset` header (seconds until reset). The one
/// question a "100% reached" email raises — when am I back? — had no answer
/// anywhere: the Worker read the remaining header and threw this one away.
/// Bounded to a sane window so a garbage header can't write a reset date
/// years out.
export function resetAtFromHeader(
  seconds: string | null | undefined, now: number = Date.now(),
): string | null {
  const s = Number(seconds);
  if (!Number.isFinite(s) || s <= 0 || s > 45 * 86_400) return null;
  return new Date(now + s * 1000).toISOString();
}

// ── The Live Activity cron's takeoff clocks ──

/// Mirrors DepartureEvidence.hardCap: past this, the presumption has spoken
/// and there is nothing minute-fresh left to learn about the departure.
export const TAKEOFF_HARD_CAP_MS = 90 * 60_000;

/// How often the cron re-consults the provider, by flight phase. Progress
/// ticks between refreshes cost nothing — they're computed from stored
/// times. Only the windows where data really moves get tight cadence.
///
/// `departureConfirmed` matters at one boundary: twenty minutes past the
/// gate time the old curve dropped to cruise cadence whether or not anyone
/// had confirmed a take-off — so a 35-minute taxi at a slow hub had its
/// runway-time confirmation, the very fact the card flips to In Air on,
/// arriving on a THIRTY-minute clock. Unconfirmed, the tight cadence holds
/// to the hedge's own hard cap.
export function cronRefreshIntervalMs(
  depMs: number, arrMs: number, now: number, departureConfirmed: boolean,
): number {
  if (now < depMs - 90 * 60_000) return 10 * 60_000;        // pre-departure, far
  // Gate assignment and boarding land in the last ~hour; a 10-minute cron
  // hold on top of the 5-minute cache TTL is how Arc told someone their
  // gate a quarter hour after the airline's own app did. The fetch rides
  // the shared cache, so tightening here costs one provider call per TTL
  // window at most, shared with every device asking about the same flight.
  if (now < depMs + 20 * 60_000) return 5 * 60_000;         // gate/boarding/departure
  if (!departureConfirmed && now < depMs + TAKEOFF_HARD_CAP_MS) {
    return 5 * 60_000;                                       // still on the ground, maybe
  }
  if (now < arrMs - 45 * 60_000) return 30 * 60_000;        // cruise
  return 10 * 60_000;                                        // arrival window
}

/// Whether this tick should spend an ADS-B look on the aircraft: only the
/// takeoff window (just before off-block until the hard cap), only while
/// nobody has confirmed the departure, and not once a sighting already saw
/// it flying. The aggregators are free, but every look is a subrequest —
/// this window is what keeps it to a handful of aircraft per tick.
export function takeoffWatchDue(
  depMs: number, now: number,
  departureConfirmed: boolean, groundState: string | null | undefined,
): boolean {
  if (departureConfirmed || groundState === "airborne") return false;
  return now >= depMs - 15 * 60_000 && now <= depMs + TAKEOFF_HARD_CAP_MS;
}
