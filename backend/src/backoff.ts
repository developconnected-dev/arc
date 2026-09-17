/// A short, isolate-local memory of "the provider would not answer about this
/// key just now" — so the cron stops re-asking it.
///
/// `fetchLegsCached` deliberately leaves a transient failure (429/5xx)
/// uncached: it is not an answer, and stale legs beat a fabricated "no such
/// flight". But leaving NO trace meant every caller behind the first re-issued
/// the identical request. Measured 2026-09-17: five shared_flights rows naming
/// LX8 drew five 429s a tick, every tick — `refreshOneSharedRow` only stamps
/// `checked_at` on a real answer, so the same five rows were due again a
/// minute later, for as long as the spell lasted. Each one also bumped the
/// budget counters and leaned on the very per-second limit it was tripping.
///
/// This is NOT a cache of the failure. Nothing is stored about the flight;
/// callers keep getting the stale legs they would have got anyway. It only
/// answers "is it worth asking again yet?", and only for the cron: a person
/// waiting on a search is never held back (the search path paces itself and
/// retries once, on purpose).
///
/// Isolate-local like `rowMemo`, and on the same reasoning: cron invocations
/// usually land on a warm isolate, and when one doesn't, the cost is one extra
/// request — the behaviour this replaces, once.

/// Less than the cron's minute: "not again THIS tick", with no opinion about
/// the next one. For faults that say nothing about a minute from now.
export const BACKOFF_TICK_MS = 45_000;
/// A 429 without a usable Retry-After: sit out the next tick as well.
export const BACKOFF_429_MS = 90_000;
/// A garbage or hostile Retry-After must not park a flight for hours — the
/// lock screen of someone boarding is downstream of this.
export const BACKOFF_MAX_MS = 15 * 60_000;

/// `Retry-After` as milliseconds from `now`: delta-seconds or an HTTP date.
/// null when absent, unparseable, or not in the future.
export function retryAfterMs(header: string | null | undefined, now: number): number | null {
  const h = (header ?? "").trim();
  if (!h) return null;
  if (/^\d+$/.test(h)) {
    const ms = Number(h) * 1000;
    return ms > 0 ? ms : null;
  }
  const at = Date.parse(h);
  if (!Number.isFinite(at) || at <= now) return null;
  return at - now;
}

export class ProviderBackoff {
  private until = new Map<string, number>();

  get size(): number { return this.until.size; }

  /// When `key` may be asked about again, or null if it may be asked now.
  heldUntil(key: string, now: number): number | null {
    const t = this.until.get(key);
    if (t === undefined) return null;
    if (now >= t) { this.until.delete(key); return null; }
    return t;
  }

  /// Park a key by hand — for the non-answers only the caller can recognise
  /// (a 2xx with a malformed body, an empty answer about a flight we hold).
  hold(key: string, now: number, ms: number = BACKOFF_TICK_MS): number {
    if (this.until.size > 500) this.until.clear();
    const t = now + Math.min(Math.max(ms, BACKOFF_TICK_MS), BACKOFF_MAX_MS);
    this.until.set(key, t);
    return t;
  }

  /// Make the provider call unless the cron has been told to wait. null means
  /// "held — no request was made"; the caller serves what it already has and
  /// must not count a call against the budget.
  async ask(key: string, source: "cron" | "interactive", now: number,
            call: () => Promise<Response>): Promise<Response | null> {
    if (source === "cron" && this.heldUntil(key, now) !== null) return null;
    let res: Response;
    try {
      res = await call();
    } catch (e) {
      this.hold(key, now);
      throw e;
    }
    if (res.status === 429) {
      this.hold(key, now, retryAfterMs(res.headers.get("retry-after"), now) ?? BACKOFF_429_MS);
    } else if (res.status >= 500) {
      this.hold(key, now);
    } else {
      this.until.delete(key);
    }
    return res;
  }
}
