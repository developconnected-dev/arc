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

// AeroDataBox's full FlightStatus vocabulary (confirmed against the live API +
// its published OpenAPI schema): unknown, expected, enRoute, checkIn, boarding,
// gateClosed, departed, delayed, approaching, arrived, canceled, diverted,
// canceledUncertain. The app only knows a handful of buckets, so map into
// those — anything pre-departure collapses to "scheduled" (delay is tracked
// separately via the `delay` field, not the status string).
//
// canceledUncertain is the provider's own GUESS — its docs word it "likely
// cancelled", and a retimed filing gets stamped with it when the provider
// can't reconcile the airline's records. It used to collapse into
// "cancelled", so a rescheduled flight that went on to operate wore a red
// "Flight Cancelled", drew a rebooking push, and then had every later delay
// and gate update swallowed by the said-once cancellation latch. A guess
// travels as `cancel_uncertain` on a scheduled leg now, never as the fact.
const STATUS_MAP: Record<string, string> = {
  unknown: "scheduled",
  expected: "scheduled",
  checkin: "scheduled",
  boarding: "boarding",       // preserve boarding status
  gateclosed: "gateClosed",   // preserve gate closed status
  delayed: "scheduled",
  enroute: "active",
  departed: "active",
  approaching: "active",
  arrived: "landed",
  canceled: "cancelled",
  cancelled: "cancelled",
  canceleduncertain: "scheduled",
  diverted: "diverted",
};

export function normalizeStatus(raw: unknown): string {
  const key = String(raw ?? "").toLowerCase();
  return STATUS_MAP[key] ?? "scheduled";
}

/// The provider guessing at a cancellation — a fact about the provider,
/// carried beside the status rather than dressed up as one.
export function isCancelUncertain(raw: unknown): boolean {
  return String(raw ?? "").toLowerCase() === "canceleduncertain";
}

/// The calendar date at the airport, out of AeroDataBox's own local timestamp.
///
/// Every `scheduledTime` the provider serves carries BOTH `utc` and `local`
/// (its `DateTimeContract` requires the pair), and the local one is already
/// dated in the airport's own zone — "2026-08-24 22:00+02:00". Reading the day
/// off it is exact and needs no timezone table: the alternative, deriving it
/// from the UTC stamp, is precisely the mistake it exists to prevent.
export function localDay(local: unknown): string | null {
  const m = String(local ?? "").trim().match(/^(\d{4}-\d{2}-\d{2})/);
  return m ? m[1]! : null;
}

/// Does this leg depart on `date` — the LOCAL date the caller asked about?
///
/// AeroDataBox indexes `/flights/number/{n}/{date}` by local date and, per its
/// own spec, `dateLocalRole` defaults to `Both`: the answer holds every flight
/// that departs on that date OR arrives on it. For a route landing after
/// midnight those are two different operations a day apart — LX2146 departs
/// Zurich at 22:00 and lands in Valencia at 00:05, so a search for the 25th
/// came back with the 24th's flight as well, first in the list and identical
/// on screen down to the minute. Someone looking for their own flight tapped
/// it and added the wrong day.
///
/// A leg with no local date is one this Worker cached before it kept them.
/// Hiding those would blank real flights out of search for as long as their
/// rows live, so they pass exactly as they always did.
export function departsOnLocalDate(leg: Record<string, unknown>, date: string): boolean {
  const local = leg["dep_local_date"];
  if (typeof local !== "string" || !local) return true;
  return local === date;
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
  if (now < dep - 8 * 3600_000) return 30 * 60_000;         // the night before
  // The last hours before the card starts. A cancellation filed here is the
  // one someone can still act on — leave for the airport or not — and the
  // watcher checks four times an hour in this band. Holding the answer for
  // thirty minutes would have made three of those four checks re-read the
  // same bytes: the cache, not the watcher, would have been the latency.
  if (now < dep - 3 * 3600_000) return 15 * 60_000;         // day-of, close in
  if (now < dep + 20 * 60_000) return 5 * 60_000;           // boarding/departure
  // Twenty minutes past the gate with NO confirmed take-off, the answer is
  // still moving: the runway estimate slides, the actual is imminent, and
  // the card's flip to In Air waits on exactly this row. A cruise-length
  // hold here put that flip on a fifteen-minute clock at any slow hub.
  // Bounded by the same hard cap as the hedge itself.
  if (!leg["dep_actual"] && now < dep + 90 * 60_000) return 5 * 60_000;
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
  // The local date moves with the times it belongs to. Left behind, the
  // inferred timetable would be filtered out by the very date it was inferred
  // for — the leg would be built for the 18th and still claim the 25th.
  const shiftedLocalDay = (): string | null => {
    const d = localDay(leg["dep_local_date"]);
    if (!d) return null;
    const ms = Date.parse(`${d}T00:00:00Z`) + delta;
    return isFinite(ms) ? new Date(ms).toISOString().slice(0, 10) : null;
  };
  return {
    ...leg,
    dep_scheduled: shift(leg["dep_scheduled"]),
    arr_scheduled: shift(leg["arr_scheduled"]),
    dep_local_date: shiftedLocalDay(),
    dep_actual: null,
    arr_actual: null,
    dep_estimated: null,
    arr_estimated: null,
    status: "scheduled",
    cancel_uncertain: false,
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

/// The provider's answer, narrowed to the day the caller asked about.
///
/// A dateless query has no day to hold it to and is returned whole — it is a
/// live "where is this flight now" lookup, not a question about a date.
///
/// When a date WAS given and nothing departs on it, the answer is empty, and
/// deliberately so. It is tempting to treat that as "ask somebody else" and
/// fall through to the next provider, and that is wrong twice over:
///
///  1. AeroDataBox answering with the neighbouring day's operation is not
///     silence. It is the provider saying it holds this number's schedule and
///     that nothing on it departs that day — which is the truthful answer, and
///     the one the app already words well ("No schedule published yet for
///     LX2146 on Tue, 25 Aug"). Offering the day before instead is the bug
///     this whole file exists to stop.
///  2. The next provider is AirLabs, which is real-time only, dates legs by
///     their UTC stamp rather than their local one, and gets its reply cached
///     under THIS date's key. Falling through would hand the date question to
///     the source least able to answer it, and let that answer outlive the
///     search that caused it.
///
/// The codeshare resolver further down is unaffected: a marketing number no
/// provider indexes comes back with NO legs at all, so it is reached exactly
/// as it always was.
export function answerForDay<T extends Record<string, unknown>>(
  legs: T[], date: string | null | undefined,
): T[] {
  return date ? legs.filter(l => departsOnLocalDate(l, date)) : legs;
}

/// The neighbouring week's answer, turned into a timetable for `toDay`.
///
/// `legsWithWeeklyFallback` asks for the same number a week either side of a
/// provider hole and shifts what comes back by whole days. What comes back is
/// a date query like any other, so it carries the same two-legs-for-one-date
/// problem: `dateLocalRole` defaults to `Both`, and on a route landing after
/// midnight the FIRST leg returned for the neighbour day is the day before it.
/// Taking that one built the timetable from an operation two days off the one
/// it was inferred for — and once legs carried their own local date, the
/// endpoint that asked for the inference filtered it straight back out.
///
/// Filtering to the neighbour's own departures first is the whole fix. A leg
/// with no local date of its own is kept, exactly as everywhere else: that is
/// a row cached before they were recorded, not a leg on the wrong day.
export function templatesFromNeighbour<T extends Record<string, unknown>>(
  legs: T[] | null | undefined, fromDay: string, toDay: string,
): Record<string, unknown>[] {
  return (legs ?? [])
    .filter(l => departsOnLocalDate(l, fromDay))
    .filter(isCompleteLeg)
    .map(l => shiftLegToDay(l, fromDay, toDay))
    .filter((l): l is Record<string, unknown> => l !== null);
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

/// AeroDataBox's `runwayTime` is documented as "Actual / estimated time on the
/// runway": the same field holds a projection while the flight still sits at
/// the gate and the wheels-up/-down fact once it moved. Only the provider's
/// status string tells them apart, so a runway time is promoted to *_actual
/// only when the status says that movement happened. A flight with no status
/// at all ("Unknown" — common outside live coverage) gets the benefit of the
/// doubt once the time is comfortably in the past; a delayed flight's stale
/// projection is caught by its "Delayed" status, not by the clock.
const DEPARTED_STATUSES = new Set(["departed", "enroute", "approaching", "arrived", "diverted"]);
const ARRIVED_STATUSES = new Set(["arrived", "diverted"]);
const UNKNOWN_STATUS_GRACE_MS = 10 * 60_000;

export function confirmedRunwayTime(
  runway: unknown, status: unknown, side: "dep" | "arr", now: Date = new Date(),
): string | null {
  const iso = toISO(runway);
  if (!iso) return null;
  const key = String(status ?? "unknown").toLowerCase();
  const confirmed = side === "dep" ? DEPARTED_STATUSES : ARRIVED_STATUSES;
  // "Departed" flips at off-block, while the runway time can still be a
  // projection for the taxi ahead: a take-off that hasn't happened yet is an
  // estimate by definition, whatever the status says.
  if (confirmed.has(key)) {
    return side === "dep" && new Date(iso).getTime() > now.getTime() ? null : iso;
  }
  if (key === "unknown" || key === "") {
    return new Date(iso).getTime() <= now.getTime() - UNKNOWN_STATUS_GRACE_MS ? iso : null;
  }
  return null;
}

/// AeroDataBox's per-movement `quality` array says whether live data exists
/// for that end of the flight at all. Without "Live", no confirmation will
/// ever arrive and the clock is the only witness; with it, the *absence* of
/// a confirmation is itself evidence the flight hasn't moved.
export function movementIsLive(quality: unknown): boolean {
  return Array.isArray(quality) && quality.some(q => String(q).toLowerCase() === "live");
}
