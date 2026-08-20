// Rail and ferry HTTP handlers, kept out of index.ts so that file gains one
// dispatch call rather than a few hundred lines.
//
// Everything here is I/O and shape-shuffling; the logic these call into lives in
// transit.ts and classify.ts, where it is unit-tested without a network.

import ports from "./ports.json";
import {
  dedupeStopTimes, mapRailTrip, mapFerryItinerary, railServiceKey, matchesService,
  disruptionNoteFor, isoCountryCode,
  type TripMode,
} from "./transit.ts";
import { classifyQuery, modesToQuery } from "./classify.ts";
import {
  buildFerryGraph, routeAlongFerries, simplify, overpassQuery, type OSMWay, type LatLon,
} from "./searoute.ts";

/// Transitous asks every consumer to identify itself with an application name,
/// version and a way to reach the author, and to keep resource use modest. Both
/// are conditions of the service being free and volunteer-run, so they are not
/// optional politeness — see https://transitous.org/api/
const TRANSITOUS = "https://api.transitous.org/api/v1";
const UA = "Arc/0.1 (+https://github.com/arc-app; szerdick@ethz.ch)";

const FERRYHOPPER_MCP = "https://mcp.ferryhopper.com/mcp";

interface Port {
  name: string; code: string; country: string;
  tz: string | null;
  /// From OpenStreetMap via scripts/port-coords.mjs. null where OSM had no
  /// confident match — those sailings simply aren't drawn.
  lat?: number | null; lon?: number | null;
}
const PORTS = ports as Port[];

/// Port name → IANA zone. See build-ports.mjs for why this is a curated table
/// and not a geocoding call.
const PORT_TZ = new Map(PORTS.map(p => [p.name.toUpperCase(), p.tz ?? ""]));
const zoneForPort = (name: string) => PORT_TZ.get(String(name ?? "").toUpperCase()) ?? "";

/// Port name → the operator's own code, which is what a ticket prints.
const PORT_CODE = new Map(PORTS.map(p => [p.name.toUpperCase(), p.code ?? ""]));
const codeForPort = (name: string) => PORT_CODE.get(String(name ?? "").toUpperCase()) ?? "";

/// Port name → country name, for the disruption feed's country parameter.
const PORT_COUNTRY = new Map(PORTS.map(p => [p.name.toUpperCase(), p.country ?? ""]));
const countryForPort = (name: string) => PORT_COUNTRY.get(String(name ?? "").toUpperCase()) ?? "";

/// Port name → position. Ferryhopper publishes none, so this is the only source
/// a sailing has for the map.
const PORT_POS = new Map(
  PORTS.filter(p => typeof p.lat === "number" && typeof p.lon === "number")
       .map(p => [p.name.toUpperCase(), { lat: p.lat as number, lon: p.lon as number }]));
const coordForPort = (name: string) => PORT_POS.get(String(name ?? "").toUpperCase()) ?? null;

// ── plumbing ──────────────────────────────────────────────────────────────

async function getJSON(url: string): Promise<any> {
  const res = await fetch(url, { headers: { "User-Agent": UA, Accept: "application/json" } });
  if (!res.ok) throw new Error(`${res.status} ${url}`);
  return res.json();
}

/// One MCP tool call. The server answers as an SSE stream even for a single
/// reply, so the JSON arrives on a `data:` line rather than as the whole body.
async function mcpCall(name: string, args: Record<string, unknown>): Promise<any> {
  const res = await fetch(FERRYHOPPER_MCP, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
      "User-Agent": UA,
    },
    body: JSON.stringify({
      jsonrpc: "2.0", id: 1, method: "tools/call",
      params: { name, arguments: args },
    }),
  });
  if (!res.ok) throw new Error(`ferryhopper ${res.status}`);
  const text = await res.text();
  for (const line of text.split("\n")) {
    if (!line.startsWith("data: ")) continue;
    const payload = JSON.parse(line.slice(6));
    if (payload?.result) return payload.result;
    if (payload?.error) throw new Error(String(payload.error?.message ?? "mcp error"));
  }
  throw new Error("ferryhopper: no data frame");
}

/// Edge-cache a GET response.
///
/// Neither upstream publishes a rate limit — Transitous asks consumers to keep
/// usage modest, and Ferryhopper's MCP documents none at all, which is a reason
/// to be careful rather than a licence. Caching at the edge means repeat
/// searches of the same route on the same day cost the upstream nothing.
async function cached(
  req: Request, ttlSeconds: number, produce: () => Promise<unknown>,
  cors: Record<string, string>,
): Promise<Response> {
  const cacheable = req.method === "GET";
  const cache = cacheable ? (caches as any).default : undefined;
  const hit = cache ? await cache.match(req) : undefined;
  if (hit) return hit;
  const body = await produce();
  const res = Response.json(body, {
    headers: { ...cors, "Cache-Control": `public, max-age=${ttlSeconds}` },
  });
  // cache.put throws on non-GET — the work was done, don't 502 the reply.
  if (cache) try { await cache.put(req, res.clone()); } catch { /* uncacheable */ }
  return res;
}

function bad(message: string, cors: Record<string, string>, status = 400): Response {
  return Response.json({ error: message }, { status, headers: cors });
}

// ── handlers ──────────────────────────────────────────────────────────────

// ── sea routing (OSM ferry ways via Overpass) ────────────────────────────

/// Public Overpass instances, tried in order — each has its own bad days.
const OVERPASS = [
  "https://overpass-api.de/api/interpreter",
  "https://lz4.overpass-api.de/api/interpreter",
  "https://z.overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://overpass.private.coffee/api/interpreter",
];

async function fetchFerryWays(from: LatLon, to: LatLon, budgetMs: number): Promise<OSMWay[] | null> {
  const q = overpassQuery(from, to);
  const deadline = Date.now() + budgetMs;
  for (const ep of OVERPASS) {
    const left = deadline - Date.now();
    if (left < 3000) break;
    try {
      const res = await fetch(ep, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": UA },
        body: "data=" + encodeURIComponent(q),
        signal: AbortSignal.timeout(Math.min(left, 25_000)),
      });
      if (!res.ok) continue;
      const j = await res.json() as { elements?: any[]; remark?: string };
      const ways = (j.elements ?? []).filter(e => e.type === "way" && Array.isArray(e.geometry)) as OSMWay[];
      // A timeout comes back as HTTP 200 with a "remark" and no elements —
      // treating it as an answer cached "no sea route" for 30 days.
      if (j.remark || ways.length === 0) continue;
      return ways;
    } catch { /* next mirror */ }
  }
  return null;
}

/// The path a sailing between two ports follows, along OSM's ferry lines —
/// or null when the network doesn't connect them, in which case the app
/// draws its honest straight fallback. Cached a month per port pair: the
/// lines change on the timescale of timetables, not sailings.
async function seaRoute(from: LatLon, to: LatLon, budgetMs = 40_000): Promise<LatLon[] | null> {
  const key = new Request(`https://arc.internal/searoute?f=${from[0].toFixed(3)},${from[1].toFixed(3)}&t=${to[0].toFixed(3)},${to[1].toFixed(3)}`);
  const cache = (caches as any).default;
  const hit = cache ? await cache.match(key) : undefined;
  if (hit) {
    const j = await hit.json() as { path: LatLon[] | null };
    return j.path;
  }
  const ways = await fetchFerryWays(from, to, budgetMs);
  if (!ways) return null;   // provider down: don't cache a miss we didn't earn
  const r = routeAlongFerries(buildFerryGraph(ways), from, to);
  const path = r ? simplify(r.path) : null;
  if (cache) {
    await cache.put(key, Response.json({ path }, {
      headers: { "Cache-Control": `public, max-age=${30 * 86_400}` },
    }));
  }
  return path;
}

/// Returns a Response for a rail/ferry/classify path, or null if the request is
/// none of ours — which is what lets index.ts fall straight through to the
/// flight routes it already has.
export async function handleTransit(
  req: Request, url: URL, cors: Record<string, string>,
): Promise<Response | null> {
  const p = url.pathname;
  if (!p.startsWith("/rail/") && !p.startsWith("/ferry/") && p !== "/classify") return null;

  try {
    // ── what kind of journey is this query? ──
    //
    // Exposed so the app can decide which providers to search without
    // duplicating the rules client-side.
    if (p === "/classify") {
      const q = url.searchParams.get("q") ?? "";
      return Response.json({ query: q, modes: modesToQuery(q), ranked: classifyQuery(q) },
        { headers: cors });
    }

    // ── /rail/stations?q= ── typeahead over stops ──
    if (p === "/rail/stations") {
      const q = (url.searchParams.get("q") ?? "").trim();
      if (q.length < 2) return Response.json([], { headers: cors });
      return cached(req, 86_400, async () => {
        const rs = await getJSON(
          `${TRANSITOUS}/geocode?text=${encodeURIComponent(q)}&type=STOP`);
        return (rs as any[]).slice(0, 12).map(r => ({
          id: r.id, name: r.name, lat: r.lat, lon: r.lon,
          country: r.country ?? null, tz: r.tz ?? null,
        }));
      }, cors);
    }

    // ── /rail/departures?stopId=&time=&n= ── the board you pick a train from ──
    if (p === "/rail/departures") {
      const stopId = url.searchParams.get("stopId");
      if (!stopId) return bad("missing stopId", cors);
      const time = url.searchParams.get("time") ?? new Date().toISOString();
      const parsedN = Number(url.searchParams.get("n") ?? 20);
      const n = Math.min(Math.max(Number.isFinite(parsedN) ? Math.floor(parsedN) : 20, 1), 50);
      const modes = url.searchParams.get("modes")
        ?? "HIGHSPEED_RAIL,LONG_DISTANCE,NIGHT_RAIL,REGIONAL_FAST_RAIL,REGIONAL_RAIL,FERRY";
      // Short TTL: this is the surface that shows a delay.
      return cached(req, 60, async () => {
        const board = await getJSON(
          `${TRANSITOUS}/stoptimes?stopId=${encodeURIComponent(stopId)}` +
          `&time=${encodeURIComponent(time)}&n=${n}&mode=${encodeURIComponent(modes)}`);
        return dedupeStopTimes(board.stopTimes ?? []).map((st: any) => ({
          trip_id: st.tripId,
          service: st.routeShortName ?? "",
          operator: st.agencyName ?? "",
          headsign: st.headsign ?? "",
          mode: st.mode ?? "",
          // The stop as the BOARD names it — this is the id that matches the
          // trip response, unlike the one used to query the board.
          stop_id: st.place?.stopId ?? stopId,
          stop_name: st.place?.name ?? "",
          scheduled: st.place?.scheduledDeparture ?? "",
          expected: st.place?.departure ?? "",
          track: st.place?.track ?? null,
          realtime: st.realTime === true,
        }));
      }, cors);
    }

    // ── /rail/trip?tripId=&from=&to= ── one booked service, as a leg ──
    if (p === "/rail/trip") {
      const tripId = url.searchParams.get("tripId");
      if (!tripId) return bad("missing tripId", cors);
      const from = url.searchParams.get("from");
      const to = url.searchParams.get("to");
      const trip = await getJSON(`${TRANSITOUS}/trip?tripId=${encodeURIComponent(tripId)}`);
      const leg = mapRailTrip(trip, from, to);
      if (!leg) {
        // Either the feed renumbered the trip, or the boarding/alighting stop
        // isn't on this service. Both are recoverable by re-resolving from the
        // board, and both are better reported than papered over with the
        // service's own endpoints — which would show a wrong destination.
        return Response.json({ error: "trip did not resolve to the requested legs" },
          { status: 404, headers: cors });
      }
      return Response.json([leg], { headers: { ...cors, "Cache-Control": "public, max-age=60" } });
    }

    // ── /rail/reresolve?stopId=&key=&time= ── recover a stale trip id ──
    //
    // MOTIS trip ids embed a per-import sequence that a feed rebuild renumbers,
    // so a train added weeks ahead eventually stops resolving. The stable
    // identity is what the ticket says; this finds today's id for it.
    if (p === "/rail/reresolve") {
      const stopId = url.searchParams.get("stopId");
      const key = url.searchParams.get("key");
      if (!stopId || !key) return bad("missing stopId or key", cors);
      const time = url.searchParams.get("time") ?? new Date().toISOString();
      const board = await getJSON(
        `${TRANSITOUS}/stoptimes?stopId=${encodeURIComponent(stopId)}` +
        `&time=${encodeURIComponent(time)}&n=50`);
      const match = dedupeStopTimes(board.stopTimes ?? [])
        .find((st: any) => matchesService(st, key));
      return Response.json({ trip_id: match?.tripId ?? null }, { headers: cors });
    }

    // ── /rail/search?from=&to=&date= ── trains on a route ──
    //
    // Transitous has no search-by-train-number: to find "ICE 373" you must
    // already know a station it calls at. A route query is the shape that
    // actually works, and it is also what someone with a ticket types.
    //
    // Each itinerary leg carries its own tripId, so every result here is
    // individually trackable afterwards — which is the whole point, since Arc
    // stores booked services rather than journey plans.
    if (p === "/rail/search") {
      const from = url.searchParams.get("from");
      const to = url.searchParams.get("to");
      const date = url.searchParams.get("date");
      if (!from || !to) return bad("missing from or to", cors);
      return cached(req, 300, async () => {
        const stopOf = async (q: string) => {
          const rs = await getJSON(`${TRANSITOUS}/geocode?text=${encodeURIComponent(q)}&type=STOP`);
          return (rs as any[])[0] ?? null;
        };
        const [a, b] = await Promise.all([stopOf(from), stopOf(to)]);
        if (!a || !b) return [];
        const time = date ? `${date}T06:00:00Z` : new Date().toISOString();
        const plan = await getJSON(
          `${TRANSITOUS}/plan?fromPlace=${encodeURIComponent(a.id)}` +
          `&toPlace=${encodeURIComponent(b.id)}&time=${encodeURIComponent(time)}` +
          `&numItineraries=4&transitModes=HIGHSPEED_RAIL,LONG_DISTANCE,NIGHT_RAIL,` +
          `REGIONAL_FAST_RAIL,REGIONAL_RAIL,FERRY`);

        const out: Record<string, unknown>[] = [];
        const seen = new Set<string>();
        for (const it of (plan.itineraries ?? [])) {
          for (const l of (it.legs ?? [])) {
            // Walking connections aren't journeys, and a leg with no trip id
            // can't be tracked afterwards, so neither belongs in results.
            if (!l.tripId || l.mode === "WALK") continue;
            // A plan leg and a trip leg are the same shape, so the mapper that
            // already handles slicing and realtime works unchanged.
            const leg = mapRailTrip({ legs: [l] });
            if (!leg) continue;
            const key = `${leg.flight_number}|${leg.dep_scheduled}|${leg.arr_scheduled}`;
            if (seen.has(key)) continue;   // the same train serves several itineraries
            seen.add(key);
            out.push(leg);
          }
        }
        return out;
      }, cors);
    }

    // ── /ferry/ports?q= ── typeahead over the bundled port table ──
    if (p === "/ferry/ports") {
      const q = (url.searchParams.get("q") ?? "").trim().toUpperCase();
      if (!q) return Response.json([], { headers: cors });
      // Rank, don't just filter. A plain substring match put EMPIRE BAY above
      // PIRAEUS for "PIR", because "empIRe" contains it — which is the wrong
      // first row for anyone typing a port code.
      const scored = PORTS.map(x => {
        const name = x.name.toUpperCase(), code = x.code.toUpperCase();
        let rank = -1;
        if (code === q) rank = 0;
        else if (name.startsWith(q)) rank = 1;
        else if (code.startsWith(q)) rank = 2;
        // A match at the start of any word — "SANTA CRUZ" for "CRUZ".
        else if (new RegExp(`\\b${q.replace(/[^A-Z0-9]/g, ".")}`).test(name)) rank = 3;
        else if (name.includes(q)) rank = 4;
        return { x, rank };
      }).filter(s => s.rank >= 0)
        .sort((a, b) => a.rank - b.rank || a.x.name.localeCompare(b.x.name))
        .slice(0, 20).map(s => s.x);
      return Response.json(scored, { headers: { ...cors, "Cache-Control": "public, max-age=86400" } });
    }

    // ── /ferry/search?from=&to=&date= ── sailings on a crossing ──
    // ── /ferry/route?from=lat,lon&to=lat,lon ── the sailing's line, from OSM ──
    if (p === "/ferry/route") {
      const parse = (v: string | null): LatLon | null => {
        const m = /^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$/.exec(v ?? "");
        return m ? [Number(m[1]), Number(m[2])] : null;
      };
      const from = parse(url.searchParams.get("from")), to = parse(url.searchParams.get("to"));
      if (!from || !to) return bad("from and to must be lat,lon", cors);
      const path = await seaRoute(from, to);
      return Response.json({ route_path: path }, {
        headers: { ...cors, "Cache-Control": "public, max-age=86400" },
      });
    }

    if (p === "/ferry/search") {
      const from = url.searchParams.get("from");
      const to = url.searchParams.get("to");
      const date = url.searchParams.get("date");
      if (!from || !to || !date) return bad("missing from, to or date", cors);
      // Ferryhopper resolves port NAMES and rejects codes, so `from`/`to` are
      // passed through as the user's words rather than normalised to a code.
      return cached(req, 1800, async () => {
        const result = await mcpCall("search_trips", {
          departureLocation: from, arrivalLocation: to, date,
        });
        const itineraries = result?.structuredContent?.foundDirectItinerariesForTrip ?? [];
        const sailings = (itineraries as any[]).flatMap(it => mapFerryItinerary(it, zoneForPort, codeForPort, coordForPort));

        // Disruption notices are the ONLY change signal a sailing has (there
        // is no per-sailing delay anywhere in the free data), so a search that
        // doesn't carry them ships silence. One country-wide fetch per side,
        // best-effort: a notice failure must never sink the search itself.
        // The line the crossing follows, once per port pair (every sailing
        // between the same two ports shares it). Best-effort within a short
        // budget so a slow Overpass never holds the search hostage; the app
        // asks /ferry/route itself for anything that comes back without one.
        try {
          const first = sailings.find(s => s["dep_lat"] != null && s["arr_lat"] != null);
          if (first) {
            const path = await seaRoute(
              [first["dep_lat"] as number, first["dep_lon"] as number],
              [first["arr_lat"] as number, first["arr_lon"] as number], 9_000);
            if (path) for (const s of sailings) s["route_path"] = path;
          }
        } catch { /* best-effort */ }

        try {
          const countries = [...new Set(
            sailings.flatMap(s => [s["dep_city"], s["arr_city"]])
              .map(n => isoCountryCode(countryForPort(String(n ?? ""))))
              .filter((c): c is string => !!c)
          )].slice(0, 2);
          if (countries.length) {
            const notices = (await Promise.all(countries.map(c =>
              mcpCall("get_disruptions", { tripDate: date, country: c })
                .then(r => (r?.structuredContent?.disruptions ?? []) as unknown[])
                .catch(() => [] as unknown[])
            ))).flat();
            if (notices.length) {
              for (const s of sailings) {
                s["disruption_note"] = disruptionNoteFor(s, notices);
              }
            }
          }
        } catch { /* best-effort */ }
        return sailings;
      }, cors);
    }

    // ── /ferry/disruptions?country=&date= ── the only change signal ferries have ──
    if (p === "/ferry/disruptions") {
      const country = (url.searchParams.get("country") ?? "").toUpperCase();
      const date = url.searchParams.get("date") ?? new Date().toISOString().slice(0, 10);
      if (!/^[A-Z]{2,3}$/.test(country)) return bad("country must be a 2–3 letter code", cors);
      return cached(req, 1800, async () => {
        const result = await mcpCall("get_disruptions", { tripDate: date, country });
        return result?.structuredContent?.disruptions ?? [];
      }, cors);
    }

    return null;
  } catch (err) {
    // A transit provider being down must not take the flight routes with it.
    return Response.json({ error: String((err as Error)?.message ?? err) },
      { status: 502, headers: cors });
  }
}

export type { TripMode };
