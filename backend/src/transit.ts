// Pure ground/water transit logic — no network, no env, no imports. Kept apart
// from index.ts for the same reason as legs.ts: so it can be unit-tested
// directly with `node --test`.
//
// Arc started as a flight tracker and its normalized "leg" shape (see mapLeg in
// index.ts) is the contract every screen, widget and Live Activity reads. Rail
// and sea legs are mapped into that SAME shape here rather than getting a
// parallel one, because the alternative — a second leg type — would fork every
// consumer of it. What the modes genuinely don't share (a vessel's MMSI, a
// ferry's disruption notice) is added as extra keys the air path simply leaves
// unset.

export type TripMode = "air" | "rail" | "sea";

/// How much the provider actually knows about this leg, as opposed to how much
/// the UI would like to imply.
///
/// Flights and most trains report a revised time against a scheduled one, so
/// "On Time" is a fact. Ferries do not: the Mediterranean operators publish a
/// timetable and, separately, prose disruption notices — there is no per-sailing
/// delay number anywhere. Painting a green "On Time" badge on a sailing would
/// therefore be inventing information, so the tier travels with the leg and the
/// UI keys its confidence off it.
export type DataTier = "live" | "scheduled" | "manual";

// ── time zones ────────────────────────────────────────────────────────────

/// The offset, in ms, that `tz` was at the given instant.
function offsetMsAt(utcMs: number, tz: string): number {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hour12: false,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
  const p: Record<string, string> = {};
  for (const { type, value } of dtf.formatToParts(new Date(utcMs))) p[type] = value;
  // Some ICU builds render midnight as hour "24" rather than "00".
  const hour = p.hour === "24" ? 0 : Number(p.hour);
  const asUTC = Date.UTC(
    Number(p.year), Number(p.month) - 1, Number(p.day),
    hour, Number(p.minute), Number(p.second),
  );
  return asUTC - utcMs;
}

/// Read a wall-clock timestamp as the time it names IN `tz`, and return real UTC.
///
/// Ferryhopper reports every sailing as e.g. "2026-08-12T07:25:00Z" — but that
/// is NOT UTC. It is the local clock at the port, with a `Z` glued on. Taking it
/// at face value shifts Greek sailings three hours earlier and silently corrupts
/// every countdown, notification and Live Activity built on it.
///
/// Worse, the two ends of one crossing are in DIFFERENT zones, so there is no
/// single offset to apply: Algeciras 00:01 (Spain, UTC+2) → Tanger Med 00:31
/// (Morocco, UTC+1) reads as a 30-minute hop when it is really 1h30. Each
/// endpoint has to be resolved against its own port's zone, which is why this
/// takes a zone per call and the Worker looks one up per port.
///
/// Doing it here rather than in the app means Arc's clients only ever see true
/// UTC — the identical contract the AeroDataBox path already gives them.
export function zonedNaiveToUTC(naive: unknown, tz: string): string {
  const m = String(naive ?? "").match(
    /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?/);
  if (!m) return "";
  const wall = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] ?? 0));
  if (!tz) return new Date(wall).toISOString();
  // Treat the wall clock as UTC, correct by the offset in force there, then
  // re-read the offset at that corrected instant. The second pass is what makes
  // the hours either side of a DST change come out right, because the offset
  // before the transition is not the offset after it.
  let utc = wall - offsetMsAt(wall, tz);
  utc = wall - offsetMsAt(utc, tz);
  return new Date(utc).toISOString();
}

// ── display codes ─────────────────────────────────────────────────────────

/// Tokens that name the *kind* of place rather than the place, in the languages
/// the European feeds actually use. Dropped before a code is derived, so
/// "München Hbf" and "München Hauptbahnhof" can't produce different codes.
const NOISE = new Set([
  "hbf", "hauptbahnhof", "bahnhof", "bhf", "hb", "sbb", "cff", "ffs", "ns",
  "station", "stations", "stazione", "stazione fs", "fs", "gare", "estacion",
  "estacio", "centraal", "centrale", "central", "termini", "terminal",
  "port", "porto", "puerto", "limani", "s", "u", "s+u", "railway", "rail",
  "all", "ports", "de", "di", "du", "la", "le", "el",
]);

/// A short, stable, human-recognisable code for a station or port.
///
/// This exists because of a concrete layout constraint, not tidiness. Arc renders
/// `dep_iata`/`arr_iata` raw into fixed-width chips in the list row, the home
/// widget and the Dynamic Island — three places where a long string does not
/// wrap, it destroys the layout. Transitous stop ids are things like
/// "de-DELFI_de:11000:900003201"; putting one in that field would break every
/// one of those surfaces.
///
/// So the opaque provider handle lives in `dep_stop_id` and this supplies the
/// three letters that go on screen. Codes are display-only and MAY collide
/// (rail "BER" for Berlin Hbf vs the airport's BER) — nothing is ever looked up
/// by them, so a collision costs nothing and the familiarity is worth more.
export function displayCode(name: unknown): string {
  const raw = String(name ?? "")
    .replace(/\([^)]*\)/g, " ")             // "THIRA (SANTORINI)" → "THIRA"
    .normalize("NFD").replace(/[̀-ͯ]/g, "");  // Zürich → Zurich
  const tokens = raw.split(/[^A-Za-z]+/).filter(Boolean)
    .filter(t => !NOISE.has(t.toLowerCase()));
  if (!tokens.length) return String(name ?? "").slice(0, 3).toUpperCase();
  const first = tokens[0].toUpperCase();
  // A first token too short to carry a code borrows initials from what follows,
  // so "AG.MARINA" → AGM rather than a bare, ambiguous "AG".
  if (first.length >= 3) return first.slice(0, 3);
  return (first + tokens.slice(1).map(t => t[0].toUpperCase()).join(""))
    .slice(0, 3);
}

import { routePath } from "./geometry.ts";

// ── rail: Transitous / MOTIS ──────────────────────────────────────────────

/// The service designator with any per-run number stripped: "RE3 (3305)" → "RE3".
/// Feeds disagree on whether to append it, so nothing that compares two services
/// may compare the raw string.
function routeDesignator(name: unknown): string {
  return String(name ?? "").split("(")[0].replace(/\s+/g, "").toUpperCase();
}

interface StopTime {
  tripId?: string; mode?: string; realTime?: boolean;
  routeShortName?: string; headsign?: string; agencyName?: string;
  place?: { scheduledDeparture?: string; departure?: string; track?: string };
}

/// Collapse the same train appearing once per overlapping feed.
///
/// Transitous ingests national and regional feeds side by side, and they double
/// up: a departure board for Berlin Hbf returns RE3 to Lutherstadt Wittenberg
/// twice, once from `de-DELFI` and once from `de-VBB`, same service, same
/// minute. Shown raw the user picks their train from a list containing it twice.
///
/// The realtime-bearing copy wins, because that is the difference that matters —
/// the DELFI row carried `realTime: true` and a revised time while the VBB row
/// only had the timetable.
export function dedupeStopTimes<T extends StopTime>(stopTimes: T[]): T[] {
  const best = new Map<string, T>();
  for (const st of stopTimes ?? []) {
    const key = [
      // Only the designator, not the run number: the two feeds label the same
      // train "RE3 (3305)" and "RE3", so keying on the raw string treats them
      // as different services and defeats the whole exercise.
      routeDesignator(st.routeShortName),
      st.place?.scheduledDeparture ?? "",
      String(st.headsign ?? "").trim().toLowerCase(),
    ].join("|");
    const seen = best.get(key);
    if (!seen || (st.realTime && !seen.realTime)) best.set(key, st);
  }
  return [...best.values()];
}

/// The identity of a booked train that survives the provider re-importing its data.
///
/// MOTIS trip ids look like `20260826_08:32_de-DELFI_3322119068`: a date, a time
/// and a per-import sequence number. That last part is not stable — the feed is
/// rebuilt regularly and the numbering goes with it. Storing only the trip id
/// and polling it forever would work right up until a refresh, at which point a
/// train the user added weeks ago quietly stops resolving.
///
/// So the durable key is what a ticket actually says — operator, service number,
/// where you board, and when it was scheduled to leave — and the trip id is kept
/// only as a fast path that is re-resolved from the departure board when it fails.
export function railServiceKey(leg: Record<string, any>): string {
  return [
    String(leg.airline_name ?? "").trim().toLowerCase(),
    String(leg.flight_number ?? "").replace(/\s+/g, "").toUpperCase(),
    String(leg.dep_stop_id ?? leg.dep_iata ?? "").trim(),
    String(leg.dep_scheduled ?? "").slice(0, 16),   // to the minute
  ].join("|");
}

/// Does this departure-board entry re-identify a previously booked service?
/// Used to recover a trip id after a feed refresh invalidated the stored one.
export function matchesService(st: StopTime, key: string): boolean {
  const [, number, , sched] = key.split("|");
  return routeDesignator(st.routeShortName) === routeDesignator(number) &&
    String(st.place?.scheduledDeparture ?? "").slice(0, 16) === sched;
}

interface MotisPlace {
  name?: string; stopId?: string; track?: string; scheduledTrack?: string;
  scheduledArrival?: string; scheduledDeparture?: string;
  arrival?: string; departure?: string;
  lat?: number; lon?: number; tz?: string; cancelled?: boolean;
}

/// Every call of a MOTIS trip, in order, as one flat list.
function tripStops(leg: Record<string, any>): MotisPlace[] {
  return [leg.from ?? {}, ...(leg.intermediateStops ?? []), leg.to ?? {}];
}

/// A stop id reduced to the station it names, dropping the platform it happens
/// to be using.
///
/// German DHIDs are `de:11000:900003200:2:52` — country, area, station, then
/// platform and section. The tail moves whenever a train is re-platformed, so
/// an id captured when a trip was added stops matching the moment the operator
/// changes the platform, which is exactly the disruption a tracker exists to
/// report. Comparing at station level survives that.
function stationOf(id: unknown): string {
  const s = String(id ?? "").trim().toLowerCase();
  if (!s) return "";
  const parts = s.split(":");
  return parts.length <= 3 ? s : parts.slice(0, 3).join(":");
}

/// Is this trip stop the one the passenger named?
///
/// Ids alone are not enough. Querying the departure board for Berlin Hbf as
/// `de-DELFI_de:11000:900003201` returns trips whose own stop is
/// `de-DELFI_de:11000:900003200:2:52` — a different station NUMBER, because a
/// large Hbf is several DHID stations (main level, deep level) that a traveller
/// experiences as one place. So the name is matched too, and callers are
/// expected to keep both: the board row's `place.stopId` — which does equal the
/// trip's id — and the stop name, which survives a renumbering.
function sameStop(s: MotisPlace, want: string): boolean {
  const w = want.trim().toLowerCase();
  if (!w) return false;
  if (String(s.name ?? "").trim().toLowerCase() === w) return true;
  const a = stationOf(s.stopId);
  return !!a && a === stationOf(w);
}

/// Turn a MOTIS trip into Arc's leg shape, sliced to the part the user booked.
///
/// A train is not a flight in one important way: it stops on the way, and the
/// passenger's leg is usually a slice of the service rather than the whole run.
/// ICE 373 goes Berlin → Chur; a ticket for Berlin → Basel is the same train and
/// a different leg. Mapping the trip's own endpoints would put Chur on a card
/// for someone getting off at Basel, so the boarding and alighting stops are
/// located in the call list and everything is read from those.
///
/// `from`/`to` may be a stop id or a stop name; ids are preferred because names
/// vary between feeds ("Berlin Hbf" vs "S+U Berlin Hauptbahnhof").
export function mapRailTrip(
  trip: Record<string, any>,
  from?: string | null,
  to?: string | null,
): Record<string, unknown> | null {
  const leg = (trip?.legs ?? [])[0];
  if (!leg) return null;
  const stops = tripStops(leg);
  const at = sameStop;

  // A named endpoint that isn't on this service is refused rather than
  // approximated. Falling back to the run's own start/end looks harmless and is
  // not: ICE 373 finishes at Chur, so a Basel passenger whose stop failed to
  // match would be shown a card claiming they are going to Chur — a wrong
  // destination, wrong arrival time, and a countdown to the wrong moment. No
  // answer is recoverable; a confidently wrong one is not.
  let i = 0;
  if (from) {
    i = stops.findIndex(s => at(s, String(from)));
    if (i < 0) return null;
  }
  // The alighting stop must come after boarding, so a name that also appears
  // earlier on the run (loops, ring lines) can't invert the leg.
  let j = stops.length - 1;
  if (to) {
    j = stops.findIndex((s, idx) => idx > i && at(s, String(to)));
    if (j < 0) return null;
  }
  if (j <= i) return null;

  const dep = stops[i], arr = stops[j];
  const depSched = dep.scheduledDeparture ?? dep.scheduledArrival ?? "";
  const depReal = dep.departure ?? depSched;
  const arrSched = arr.scheduledArrival ?? arr.scheduledDeparture ?? "";
  const arrReal = arr.arrival ?? arrSched;
  const live = leg.realTime === true;

  return {
    mode: "rail" as TripMode,
    data_tier: (live ? "live" : "scheduled") as DataTier,
    flight_number: String(leg.routeShortName ?? "").replace(/\s+/g, " ").trim(),
    airline_name: leg.agencyName ?? "",
    airline_iata: "",
    dep_iata: displayCode(dep.name),
    arr_iata: displayCode(arr.name),
    dep_stop_id: dep.stopId ?? null,
    arr_stop_id: arr.stopId ?? null,
    // Each end's own zone, straight from the feed and correct across borders
    // (Berlin → Chur comes back Europe/Berlin → Europe/Zurich). Sent so the app
    // never has to guess a station's zone from its display code.
    dep_tz: dep.tz ?? null,
    arr_tz: arr.tz ?? null,
    dep_city: dep.name ?? null,
    arr_city: arr.name ?? null,
    dep_scheduled: depSched,
    arr_scheduled: arrSched,
    // A cancelled call is the strongest thing a rail feed says. It outranks
    // every timing detail, so it is read before anything else.
    status: (dep.cancelled || arr.cancelled) ? "cancelled" : "scheduled",
    // A platform is a gate: the thing you must find before the doors close.
    // Reusing the field means the widget and Live Activity display it already.
    dep_gate: dep.track ?? null,
    arr_gate: arr.track ?? null,
    // The platform originally advertised, when it differs from the one now in
    // force. A platform change minutes before departure is the single most
    // useful thing a station board tells you, and it is only visible as the gap
    // between these two — `track` alone looks identical either way.
    dep_gate_scheduled: dep.scheduledTrack ?? null,
    dep_terminal: null,
    arr_terminal: null,
    arr_baggage: null,
    delay: live ? delayMinutes(depSched, depReal) : 0,
    dep_actual: live && depReal !== depSched ? depReal : null,
    arr_actual: live && arrReal !== arrSched ? arrReal : null,
    aircraft_type: null,
    aircraft_registration: null,
    aircraft_icao24: null,
    vessel_name: null,
    vessel_mmsi: null,
    trip_id: leg.tripId ?? trip?.legs?.[0]?.tripId ?? null,
    // The real track, simplified. A great-circle arc is right for a plane and
    // false for a train — it draws Berlin→Basel straight across the countryside
    // instead of routing via Frankfurt and Mannheim. null when the provider
    // gave no geometry, and the map falls back to the straight line.
    route_path: routePath(leg),
    dep_lat: dep.lat ?? null,
    dep_lon: dep.lon ?? null,
    arr_lat: arr.lat ?? null,
    arr_lon: arr.lon ?? null,
  };
}

function delayMinutes(sched: unknown, revised: unknown): number {
  const s = Date.parse(String(sched ?? "")), r = Date.parse(String(revised ?? ""));
  if (!isFinite(s) || !isFinite(r)) return 0;
  return Math.round((r - s) / 60_000);
}

// ── sea: Ferryhopper ──────────────────────────────────────────────────────

/// Resolves a port name to its IANA zone. Backed by the bundled port table in
/// the Worker; injected here so the mapping stays pure and testable.
export type PortZoneLookup = (portName: string) => string;

/// Resolves a port name to its position, or null when OSM had no confident
/// match. Ports without coordinates simply aren't drawn — the map already
/// skips any leg with a zero endpoint — which is preferable to a line to a
/// place the ship does not go.
export type PortCoordLookup = (portName: string) => { lat: number; lon: number } | null;

interface FerrySegment {
  departurePort?: { name?: string };
  arrivalPort?: { name?: string };
  departureDateTime?: string;
  arrivalDateTime?: string;
  ownerCompany?: { name?: string };
  marketingCompany?: { name?: string; iconURL?: string };
  vessel?: { name?: string };
}

/// Map one Ferryhopper itinerary to Arc legs — one leg per sailing.
///
/// A multi-segment itinerary is a connection (island hop with a change), which
/// in Arc's model is two legs rather than one leg with a stop, matching how a
/// connecting flight is already handled.
///
/// Note what is deliberately absent: any notion of "on time". Ferryhopper serves
/// the timetable and, separately, operator disruption prose — never a revised
/// time per sailing. So every sea leg is born `scheduled`, `delay` 0, with no
/// actual times, and it is the caller's job to attach a disruption note. That is
/// the honest shape of what the source knows.
export function mapFerryItinerary(
  itinerary: Record<string, any>,
  zoneFor: PortZoneLookup,
  codeFor?: (portName: string) => string,
  coordFor?: PortCoordLookup,
): Record<string, unknown>[] {
  const segments: FerrySegment[] = itinerary?.segments ?? [];
  // The operator's own port code beats one derived from the name, because it is
  // what the passenger's ticket says: a Piraeus→Syros booking reads "PIR - JSY",
  // and deriving from "SYROS" would put SYR on the card instead — the right
  // island under a code the traveller has never seen. Only codes short enough
  // for the fixed-width chips qualify; the rest fall back to derivation.
  const chip = (name: string) => {
    const code = (codeFor?.(name) ?? "").trim().toUpperCase();
    return /^[A-Z0-9]{2,4}$/.test(code) ? code : displayCode(name);
  };
  return segments.map(seg => {
    const depName = String(seg.departurePort?.name ?? "");
    const arrName = String(seg.arrivalPort?.name ?? "");
    const operator = seg.marketingCompany?.name ?? seg.ownerCompany?.name ?? "";
    const vessel = String(seg.vessel?.name ?? "");
    return {
      mode: "sea" as TripMode,
      data_tier: "scheduled" as DataTier,
      // The vessel is what a ferry ticket identifies the sailing by — there is
      // no service number — so it takes the slot the flight number occupies.
      flight_number: vessel,
      airline_name: operator,
      airline_iata: "",
      operator_logo: seg.marketingCompany?.iconURL ?? null,
      dep_iata: chip(depName),
      arr_iata: chip(arrName),
      // The searchable port NAME, not a code: Ferryhopper's search rejects
      // LOCODEs ("PIR" → no route found) and only resolves names ("Piraeus"),
      // so the name is the identifier that has to survive into storage.
      dep_stop_id: depName || null,
      arr_stop_id: arrName || null,
      dep_tz: zoneFor(depName) || null,
      arr_tz: zoneFor(arrName) || null,
      dep_city: depName || null,
      arr_city: arrName || null,
      dep_scheduled: zonedNaiveToUTC(seg.departureDateTime, zoneFor(depName)),
      arr_scheduled: zonedNaiveToUTC(seg.arrivalDateTime, zoneFor(arrName)),
      status: "scheduled",
      dep_gate: null, arr_gate: null,
      dep_terminal: null, arr_terminal: null, arr_baggage: null,
      delay: 0,
      dep_actual: null, arr_actual: null,
      aircraft_type: null, aircraft_registration: null, aircraft_icao24: null,
      vessel_name: vessel || null,
      vessel_mmsi: null,           // filled in by MMSI resolution, when known
      disruption_note: null,
      booking_url: itinerary?.deepLink ?? null,
      // Ferryhopper publishes no positions, so these come from the bundled
      // port table (built from OSM). A sailing with either end unresolved is
      // left at null and the map skips it rather than drawing to Null Island.
      dep_lat: coordFor?.(depName)?.lat ?? null,
      dep_lon: coordFor?.(depName)?.lon ?? null,
      arr_lat: coordFor?.(arrName)?.lat ?? null,
      arr_lon: coordFor?.(arrName)?.lon ?? null,
      // No provider publishes sailing geometry, so a ferry is a straight line
      // between its ports — right across open water, and an approximation on
      // coastal routes that hug a shoreline.
      route_path: null,
    };
  });
}

/// Which live-position source, if any, can track this leg.
///
/// Guards a real hazard rather than being decorative. `aircraft_icao24` feeds
/// the OpenSky lookup, and a vessel's MMSI is nine digits where an ICAO24 is six
/// hex — handing one to the other silently returns a position for a different
/// vehicle, or nothing, with no error to notice. Position lookups therefore
/// dispatch on mode, never on "whichever id is populated".
export function positionSourceFor(
  leg: Record<string, any>,
): { source: "opensky"; id: string } | { source: "ais"; id: string } | null {
  const mode = String(leg?.mode ?? "air");
  if (mode === "air") {
    const id = String(leg?.aircraft_icao24 ?? "").trim();
    return id ? { source: "opensky", id } : null;
  }
  if (mode === "sea") {
    const id = String(leg?.vessel_mmsi ?? "").trim();
    return /^\d{9}$/.test(id) ? { source: "ais", id } : null;
  }
  return null;   // no free live-position source for trains
}
