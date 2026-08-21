// Pure leg arithmetic — no network, no env, no imports. Kept apart from
// index.ts so it can be unit-tested directly with `node --test`.

/// Normalise AeroDataBox time ("2026-07-20 09:15Z" / with seconds) to ISO-8601.
export function toISO(s: unknown): string {
  if (typeof s !== "string" || !s) return "";
  let t = s.trim().replace(" ", "T");
  // ensure seconds present before the trailing offset/Z
  const m = t.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(:\d{2})?(.*)$/);
  if (m) t = `${m[1]}${m[2] ?? ":00"}${m[3] || "Z"}`;
  const d = new Date(t);
  return isNaN(d.getTime()) ? "" : d.toISOString();
}

/// A scheduled departure rebuilt from the route's own departure board.
///
/// Used only when the provider degraded the departure side away entirely (see
/// `repairLegForRoute`). The board entry is a real scheduled time for the same
/// flight on the same weekday, not a guess — but it carries the board's date,
/// so only its time of day survives. The arrival timestamp anchors which UTC
/// day that time belongs to, which keeps overnight flights on the right side
/// of midnight instead of landing before they leave.
export function departureFromBoardTime(
  boardTimeUTC: string, arrScheduled: unknown, date: string
): string {
  const iso = toISO(boardTimeUTC);
  if (!iso) return "";
  const timeOfDay = iso.slice(10);                 // "T09:45:00.000Z"
  const arrMs = Date.parse(String(arrScheduled ?? ""));
  if (isFinite(arrMs)) {
    for (const offset of [0, -86_400_000]) {
      const day = new Date(arrMs + offset).toISOString().slice(0, 10);
      const ms = Date.parse(`${day}${timeOfDay}`);
      if (isFinite(ms) && ms <= arrMs) return new Date(ms).toISOString();
    }
  }
  const ms = Date.parse(`${date}${timeOfDay}`);
  return isFinite(ms) ? new Date(ms).toISOString() : "";
}

/// One leg checked against the route it was discovered on, with a degraded
/// endpoint repaired — or null when it genuinely belongs to another route.
///
/// AeroDataBox serves some far-out schedule records with one side hollowed
/// out: `"departure": {"airport": {"name": "Athens"}, "quality": []}` — a name
/// and nothing else, no IATA code and no time. `mapLeg` turns that into
/// `dep_iata: ""`, and the verifier used to demand that BOTH endpoints equal
/// the searched route. So the flights with a degraded side were fetched, paid
/// for, and then silently dropped: LH1751 on 18 Sep — the flight that actually
/// operates codeshare A31653 — was found and discarded on every single search.
///
/// A blank endpoint means UNKNOWN, not "somewhere else". So every endpoint the
/// provider did fill has to match, at least one has to match (a leg with
/// nothing to anchor it is not evidence of anything), and only then is the
/// blank side filled in from the route — sound, because the candidate came off
/// that very route's departure board.
export function repairLegForRoute(
  leg: Record<string, unknown>,
  route: { dep: string; arr: string } | null,
  boardTimeUTC: string | null,
  date: string,
): Record<string, unknown> | null {
  if (!route) return leg;
  const dep = String(leg["dep_iata"] ?? "").toUpperCase();
  const arr = String(leg["arr_iata"] ?? "").toUpperCase();
  if (dep && dep !== route.dep) return null;
  if (arr && arr !== route.arr) return null;
  if (!dep && !arr) return null;
  const out = { ...leg };
  if (!dep) out["dep_iata"] = route.dep;
  if (!arr) out["arr_iata"] = route.arr;
  if (!String(leg["dep_scheduled"] ?? "") && boardTimeUTC) {
    const rebuilt = departureFromBoardTime(boardTimeUTC, leg["arr_scheduled"], date);
    if (rebuilt) out["dep_scheduled"] = rebuilt;
  }
  return out;
}

/// How long a cached answer stays usable: tight around the moments a flight
/// moves (boarding/departure, arrival); loose in cruise and the far future.
// One payload can hold several legs of the same number (A→B→C). Freshness
// must follow the MOST demanding leg — judging by legs[0] alone froze the
// second sector's gates and delay for 24 h the moment the first one landed.
export function cacheTTLms(legs: Record<string, any>[]): number {
  if (legs.length > 1) {
    return Math.min(...legs.map(l => cacheTTLms([l])));
  }
  const leg = legs[0];
  if (!leg) return 10 * 60_000;
  const delayMs = ((leg["delay"] as number) ?? 0) * 60_000;
  const dep = leg["dep_actual"] ? Date.parse(String(leg["dep_actual"]))
    : Date.parse(String(leg["dep_scheduled"] ?? "")) + delayMs;
  const arr = leg["arr_actual"] ? Date.parse(String(leg["arr_actual"]))
    : Date.parse(String(leg["arr_scheduled"] ?? "")) + delayMs;
  const now = Date.now();
  if (isNaN(dep) || isNaN(arr)) return 10 * 60_000;
  // A schedule weeks out barely moves; hold it long so repeat searches of
  // the same route (family, next day) answer from cache — near-instant and
  // quota-free. Within a week, tighten back up.
  if (now < dep - 7 * 24 * 3600_000) return 72 * 3600_000;  // deep future
  if (now < dep - 24 * 3600_000) return 6 * 3600_000;       // far future
  if (now < dep - 3 * 3600_000) return 30 * 60_000;         // day-of
  if (now < dep + 20 * 60_000) return 5 * 60_000;           // boarding/departure
  if (now < arr - 45 * 60_000) return 15 * 60_000;          // cruise
  if (now < arr + 45 * 60_000) return 2 * 60_000;           // arrival window
  return 24 * 3600_000;                                     // flight is history
}


/// Is this flight_cache row still fresh for `date`? Shared by fetchLegsCached
/// and the search pipeliner, which must know BEFORE calling whether a real
/// provider fetch will happen — pacing is for provider calls, not cache hits.
export function cachedRowFresh(row: Record<string, any> | null | undefined): boolean {
  const legs = row?.payload as Record<string, any>[] | undefined;
  if (!row || !legs) return false;
  const age = Date.now() - Date.parse(String(row.fetched_at));
  // An empty answer is held just long enough to stop one search session
  // re-asking the same dead number over and over (which is what tripped the
  // provider's per-second limit and made real flights drop out of results).
  // Five minutes, and deliberately no longer: this provider answers 204 for
  // flights it demonstrably has, so every second of negative caching is a
  // second a real flight can be missing. The old rule held empties for 48 h on
  // anything more than a week out — long enough to hide a booked flight for
  // two days. Five minutes collapses a burst without outliving a retry.
  const ttl = legs.length > 0 ? cacheTTLms(legs) : 5 * 60_000;
  return age < ttl;
}


/// Is this leg complete enough to be added as a flight — both endpoints and
/// both scheduled times? AeroDataBox serves far-out records with a side
/// hollowed out (see `repairLegForRoute`), and an empty `arr_iata` would
/// become a flight to nowhere.
export function isCompleteLeg(leg: Record<string, unknown>): boolean {
  return !!String(leg["dep_iata"] ?? "") && !!String(leg["arr_iata"] ?? "")
    && !!String(leg["dep_scheduled"] ?? "") && !!String(leg["arr_scheduled"] ?? "");
}

/// The same flight, moved to another day.
///
/// AeroDataBox's far-future schedule has holes: LH1751 answered in full for
/// 11 Sep and 25 Sep and empty for 18 Sep — a daily rotation does not skip a
/// Friday, the provider does. When the asked day is empty but the same
/// number flies the same weekday a week either side, that neighbour IS the
/// schedule, shifted by whole days. Everything live is stripped (status,
/// actuals, delay, gates, tail) and the result is marked `data_tier:
/// "scheduled"` — a timetable the app keeps re-checking until the real
/// record returns, never a claim of punctuality.
export function shiftLegToDay(
  leg: Record<string, unknown>, fromDay: string, toDay: string,
): Record<string, unknown> | null {
  const delta = Date.parse(`${toDay}T00:00:00Z`) - Date.parse(`${fromDay}T00:00:00Z`);
  if (!isFinite(delta) || !isCompleteLeg(leg)) return null;
  const shift = (v: unknown): string => {
    const ms = Date.parse(String(v ?? ""));
    return isFinite(ms) ? new Date(ms + delta).toISOString() : "";
  };
  return {
    ...leg,
    dep_scheduled: shift(leg["dep_scheduled"]),
    arr_scheduled: shift(leg["arr_scheduled"]),
    dep_actual: null,
    arr_actual: null,
    status: "scheduled",
    delay: 0,
    dep_gate: null,
    arr_gate: null,
    arr_baggage: null,
    aircraft_registration: null,
    aircraft_icao24: null,
    data_tier: "scheduled",
    schedule_inferred_from: fromDay,
  };
}

/// A hollow leg for the asked day (one endpoint or time missing) completed
/// from the shifted neighbour: the day's own fields win wherever present.
export function completeLeg(
  hollow: Record<string, unknown>, template: Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = { ...template };
  for (const [k, v] of Object.entries(hollow)) {
    if (v !== null && v !== undefined && v !== "") out[k] = v;
  }
  // Completed from a neighbour ⇒ the record is partly timetable.
  out["data_tier"] = "scheduled";
  out["schedule_inferred_from"] = template["schedule_inferred_from"] ?? null;
  return out;
}
