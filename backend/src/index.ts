import { apnsConfigured, sendLiveActivityPush, sendAlertPush, apnsJwt, tokenIsDead } from "./apns";
import { toISO, repairLegForRoute, cachedRowFresh, isCompleteLeg, templatesFromNeighbour, completeLeg, confirmedRunwayTime, movementIsLive, localDay, departsOnLocalDate, answerForDay } from "./legs";
import { classifyGround, taxiPriorMinutes, adbPositionToSample, DEFAULT_TAXI_PRIOR } from "./ground";
import { predictGate, type GateObservation } from "./gates";
import { contentState } from "./activity";
import { flightNews, type WatchState } from "./alerts";
import { shouldWriteSharedRow, laterISO, sharedRowIsDue, sharedRowCheckInterval, providerAnswered } from "./freshness";
import { pickLeg, plausibleActualDeparture } from "./legmatch";
import { verifiedRoute } from "./place";
import { handleTransit } from "./routes-transit";
import { modesToQuery, routeFromQuery, dateFromQuery } from "./classify";
import { wxRows, airportWeatherPayload } from "./weather";

interface Env {
  RAPIDAPI_KEY: string;          // AeroDataBox key (RapidAPI). Set via `wrangler secret put RAPIDAPI_KEY`.
  AIRLABS_KEY?: string;          // AirLabs fallback (free 1k/mo). Set via `wrangler secret put AIRLABS_KEY`.
  AVIATIONSTACK_API_KEY?: string; // legacy fallback (optional)
  // Server-side Supabase access. The service-role key is the only one used:
  // every table this Worker touches is closed to anon.
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY?: string;
  // Remote Live Activity pushes — SUPABASE_SERVICE_KEY and all three APNS_*
  // required before the cron does anything:
  APNS_TEAM_ID?: string;         // Apple Developer Team ID
  APNS_KEY_ID?: string;          // APNs auth key ID
  APNS_P8?: string;              // full .p8 file contents
  AI_API_KEY?: string;           // Anthropic API key — booking-text parsing (claude-haiku-4-5)
  // Contact string the ADS-B aggregators demand of API callers, e.g.
  // "you@example.com". Only affects /position, which serves the app's live
  // map: Cloudflare's shared egress IPs are rate-limited (adsb.lol 429) or
  // blocked (adsb.fi, airplanes.live 403) for anonymous callers, so devices
  // read the aggregators themselves. The server's own witness does not need
  // it — it reads the position AeroDataBox returns on the leg call.
  ADSB_CONTACT?: string;
}

const APP_BUNDLE_ID = "com.arc.flighttracker";

const ADB_HOST = "aerodatabox.p.rapidapi.com";

/// The only date shape allowed to reach a provider URL path or Date() math.
const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;

// AeroDataBox's full FlightStatus vocabulary (confirmed against the live API +
// its published OpenAPI schema): unknown, expected, enRoute, checkIn, boarding,
// gateClosed, departed, delayed, approaching, arrived, canceled, diverted,
// canceledUncertain. The app only knows 5 buckets, so map into those —
// anything pre-departure collapses to "scheduled" (delay is tracked separately
// via the `delay` field, not the status string).
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
  canceleduncertain: "cancelled",
  diverted: "diverted",
};

function normalizeStatus(raw: unknown): string {
  const key = String(raw ?? "").toLowerCase();
  return STATUS_MAP[key] ?? "scheduled";
}

function delayMinutes(scheduled: unknown, revised: unknown): number {
  const s = toISO(scheduled), r = toISO(revised);
  if (!s || !r) return 0;
  return Math.max(0, Math.round((new Date(r).getTime() - new Date(s).getTime()) / 60000));
}

/// Map one AeroDataBox flight leg to the app's FlightSearchResult shape.
function mapLeg(f: Record<string, any>): Record<string, unknown> {
  const dep = f.departure ?? {};
  const arr = f.arrival ?? {};
  const depA = dep.airport ?? {};
  const arrA = arr.airport ?? {};
  const air = f.airline ?? {};
  const ac = f.aircraft ?? {};
  const depSched = dep.scheduledTime?.utc ?? dep.scheduledTime?.local;
  const depRev = dep.revisedTime?.utc ?? dep.revisedTime?.local ?? depSched;
  const arrSched = arr.scheduledTime?.utc ?? arr.scheduledTime?.local;
  const arrRev = arr.revisedTime?.utc ?? arr.revisedTime?.local ?? arrSched;
  // revisedTime is a published ESTIMATE that airlines file before anything has
  // moved; runwayTime is the wheels-up/-down time — but AeroDataBox documents
  // it as "actual / estimated", so it too can be a projection for a flight
  // still at the gate. The two used to be conflated into *_actual, so a
  // delayed flight carried an "actual departure" — exactly the field the app
  // treats as "confirmed departed" (it ends the Departing hedge and flips
  // every surface to past tense). Estimates now travel in *_estimated, and a
  // runway time is only promoted to *_actual once the provider's status says
  // the movement happened (see confirmedRunwayTime).
  const depRunwayRaw = dep.runwayTime?.utc ?? dep.runwayTime?.local;
  const depRunway = confirmedRunwayTime(depRunwayRaw, f.status, "dep");
  const arrRunway = confirmedRunwayTime(arr.runwayTime?.utc ?? arr.runwayTime?.local, f.status, "arr");
  // The unconfirmed runway time is still useful: it is the provider's own
  // estimate of wheels-up, which every surface hedges against instead of
  // the gate time (taxi-out at a hub is routinely 20–40 minutes).
  const depRunwayEstimated = depRunway ? null : (toISO(depRunwayRaw) || null);
  return {
    flight_number: String(f.number ?? "").replace(/\s+/g, ""),
    airline_name: air.name ?? "",
    airline_iata: air.iata ?? "",
    dep_iata: depA.iata ?? "",
    arr_iata: arrA.iata ?? "",
    dep_city: depA.municipalityName ?? null,
    arr_city: arrA.municipalityName ?? null,
    dep_scheduled: toISO(depSched),
    arr_scheduled: toISO(arrSched),
    // The calendar date at the DEPARTURE airport, kept because it is the only
    // thing that can tell this leg from the one a day either side of it. The
    // provider indexes by local date and answers with departures AND arrivals
    // (`dateLocalRole` defaults to `Both`), so a flight landing after midnight
    // comes back on two dates — see `departsOnLocalDate`.
    dep_local_date: localDay(dep.scheduledTime?.local),
    status: normalizeStatus(f.status),
    dep_gate: dep.gate ?? null,
    dep_terminal: dep.terminal ?? null,
    arr_gate: arr.gate ?? null,
    arr_terminal: arr.terminal ?? null,
    arr_baggage: arr.baggageBelt ?? null,
    delay: delayMinutes(depSched, depRev),
    dep_actual: depRunway,
    arr_actual: arrRunway,
    dep_runway_estimated: depRunwayEstimated,
    dep_live: movementIsLive(dep.quality),
    // Where the aircraft actually is, from the same call (`withLocation=true`
    // has always been in the URL — the answer was simply discarded). This is
    // what lets the server tell taxiing from flying without an ADS-B
    // aggregator, all of which refuse Cloudflare's shared egress IPs.
    position: adbPositionToSample(f.location),
    dep_estimated: depRev !== depSched ? toISO(depRev) : null,
    arr_estimated: arrRev !== arrSched ? toISO(arrRev) : null,
    aircraft_type: ac.model ?? null,
    aircraft_registration: ac.reg ?? null,
    aircraft_icao24: ac.modeS ?? null,
    dep_lat: depA.location?.lat ?? null,
    dep_lon: depA.location?.lon ?? null,
    arr_lat: arrA.location?.lat ?? null,
    arr_lon: arrA.location?.lon ?? null,
  };
}

async function adbFetch(path: string, env: Env): Promise<Response> {
  return fetch(`https://${ADB_HOST}${path}`, {
    headers: { "X-RapidAPI-Key": env.RAPIDAPI_KEY, "X-RapidAPI-Host": ADB_HOST },
  });
}

// ── AirLabs fallback ──

const AIRLABS_STATUS_MAP: Record<string, string> = {
  scheduled: "scheduled",
  en_route: "active",
  active: "active",
  landed: "landed",
  cancelled: "cancelled",
  incident: "diverted",
  diverted: "diverted",
  unknown: "scheduled",
};

/// Ensure a time string is proper ISO-8601 with timezone.
/// AirLabs returns "2026-07-21 09:55" (no T, no Z) for local times
/// and "2026-07-21T07:55:00.000Z" or "2026-07-21 07:55" for UTC times.
/// We normalise everything to end with "Z" when it came from a _utc field,
/// and convert local times via JS Date (which treats bare strings as UTC in
/// Cloudflare Workers) — but since AirLabs local times are actually local
/// we must NOT append Z to them. Instead we prefer _utc fields exclusively.
function airlabsToISO(utcTime: unknown, localTime: unknown): string {
  // Strongly prefer the UTC time
  if (typeof utcTime === "string" && utcTime.length >= 16) {
    let t = utcTime.trim().replace(" ", "T");
    // Ensure it ends with Z for UTC
    if (!t.endsWith("Z") && !t.includes("+") && !t.includes("-", 10)) {
      t += "Z";
    }
    const d = new Date(t);
    if (!isNaN(d.getTime())) return d.toISOString();
  }
  // Fallback: local time — but mark as-is and let the app handle it
  // This is a last resort; the time may be wrong by the TZ offset
  if (typeof localTime === "string" && localTime.length >= 16) {
    let t = localTime.trim().replace(" ", "T");
    // Assume UTC as safe default (better than letting iOS guess device TZ)
    if (!t.endsWith("Z") && !t.includes("+") && !t.includes("-", 10)) {
      t += "Z";
    }
    const d = new Date(t);
    if (!isNaN(d.getTime())) return d.toISOString();
  }
  return "";
}

/// What the AI reads out of a free-text flight search.
interface ParsedFlightQuery {
  flights: { number: string; date: string }[];
  dep_iata: string;
  arr_iata: string;
  date: string;
  // Retired from the schema (AI number-guessing was the weakest source and
  // its output tokens most of the parse latency); kept optional so cached
  // parses from before the change still deserialize.
  candidates?: string[];
}

/// One structured-output call: explicit flight numbers, a route if the text
/// names one (cities resolved to IATA), a date, and — the part that catches
/// codeshares — flight numbers *likely to operate* the route or to be the
/// operating flight behind a marketing number. Candidates are suggestions
/// only; the caller verifies each against real schedule data before anything
/// reaches the user.
async function aiParseFlightQuery(query: string, env: Env): Promise<ParsedFlightQuery | null> {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.AI_API_KEY!,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      // Haiku: this is a trivial extract-a-route task, every answer is
      // verified against real schedule data before reaching the user, and
      // the parse is the search's largest fixed latency (~3 s on Sonnet).
      // No thinking param — Haiku 4.5 doesn't think unless asked to.
      model: "claude-haiku-4-5",
      max_tokens: 800,
      output_config: {
        format: {
          type: "json_schema",
          schema: {
            type: "object",
            properties: {
              flights: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    number: { type: "string", description: "IATA flight number written in the text, compact, e.g. A31653" },
                    date: { type: "string", description: "YYYY-MM-DD if this leg has its own date, else empty string" },
                  },
                  required: ["number", "date"],
                  additionalProperties: false,
                },
              },
              dep_iata: { type: "string", description: "Departure airport IATA if a route is named, else empty string" },
              arr_iata: { type: "string", description: "Arrival airport IATA if a route is named, else empty string" },
              date: { type: "string", description: "Travel date YYYY-MM-DD, else empty string" },
            },
            required: ["flights", "dep_iata", "arr_iata", "date"],
            additionalProperties: false,
          },
        },
      },
      system: `You turn a flight-search query into structured search terms. Today's date is ${new Date().toISOString().slice(0, 10)}. The query may be a flight number, a codeshare marketing number, a route in city or airport names, free text, or a pasted booking confirmation. Resolve cities to IATA airport codes, and resolve ONLY the place actually named. Never substitute a different or similarly-named place: "Syros" is JSY and is not Santorini, "Kos" is not Kosice, "San Jose" in Costa Rica is not San Jose in California. If a name is ambiguous, or you cannot place it confidently, leave dep_iata and arr_iata empty — answering about a city the traveller did not name is far worse than not answering, because they may add the wrong flight. When the year is missing, pick the next occurrence of the date from today. For a codeshare-looking number (an airline code with a number that airline doesn't operate itself on any plausible route): when you are CONFIDENT which route that marketing number serves, also fill dep_iata and arr_iata so the route can be searched directly. Never guess a route you are unsure of — a wrong route would surface real flights the user never asked about. Answer with the minimum: no candidate lists, no commentary.`,
      messages: [{ role: "user", content: query }],
    }),
  });
  if (!res.ok) {
    console.error("aiParseFlightQuery failed:", res.status, await res.text());
    return null;
  }
  const data = await res.json<any>();
  if (data?.stop_reason === "refusal") return null;
  const text = (data?.content ?? []).find((b: any) => b.type === "text")?.text;
  if (!text) return null;
  try { return JSON.parse(text) as ParsedFlightQuery; } catch { return null; }
}

/// Scheduled flights on a route, per AirLabs. Each row can carry both an
/// operating and a codeshare number; the caller treats both as candidates
/// and lets verification decide which is real. Errors (including the monthly
/// quota being exhausted) surface as an empty list — the caller has other
/// candidate sources.
// AirLabs reports an exhausted monthly quota inside a 200 response; remember
// that for a while instead of spending ~0.5 s per search awaiting the same no.
let airlabsDeadUntil = 0;

async function airlabsRouteSchedules(
  dep: string, arr: string, env: Env
): Promise<{ operating: string | null; marketing: string | null }[]> {
  if (!env.AIRLABS_KEY || Date.now() < airlabsDeadUntil) return [];
  try {
    const res = await fetch(
      `https://airlabs.co/api/v9/schedules?dep_iata=${encodeURIComponent(dep)}&arr_iata=${encodeURIComponent(arr)}&api_key=${env.AIRLABS_KEY}`
    );
    if (!res.ok) return [];
    const data = await res.json() as { response?: Array<Record<string, any>>; error?: unknown };
    if (data.error) { airlabsDeadUntil = Date.now() + 6 * 3600_000; return []; }
    if (!Array.isArray(data.response)) return [];
    return data.response.map(r => ({
      operating: (r.cs_flight_iata as string) ?? null,
      marketing: (r.flight_iata as string) ?? null,
    }));
  } catch {
    return [];
  }
}

/// Resolve a codeshare MARKETING number (A31653) to the flight that actually
/// operates it, plus its route.
///
/// Nothing indexes a marketing number against a date months out — which is how
/// a real booking searched as "A31653 on 18 September" came back empty while
/// the very same flight sat in the data as LH1751. AeroDataBox DOES resolve
/// marketing numbers inside its live window (measured: today and tomorrow,
/// nothing beyond), answering with the OPERATING flight's leg. So ask it
/// there, and carry the number and route it reveals back to the date the user
/// asked about, where normal verification takes over.
///
/// The limit is honest: a marketing number re-pointed at a different operator
/// between now and the travel date resolves to the old one. Because the result
/// is then verified on the target date and filtered to the resolved route, a
/// stale mapping shows up as no result rather than as the wrong flight.
///
/// (This replaces an AirLabs lookup that could never have worked: its
/// /schedules endpoint reaches ~10 hours ahead, and cs_flight_iata is a
/// response field, not a query parameter.)
/// The legs for `number` on `day` — and when the provider's far-future
/// record is missing or hollow, the same flight a week either side shifted
/// onto the day (see `shiftLegToDay`). Only for days at least two days out:
/// inside that window the live record is the truth, holes included.
/// The neighbour lookups ride the normal 72h far-future cache, so a week of
/// re-asks costs one provider call.
async function legsWithWeeklyFallback(
  env: Env, number: string, day: string, source: "cron" | "interactive"
): Promise<{ legs: Record<string, unknown>[] | null; cache: string }> {
  const direct = await fetchLegsCached(env, "flight", number, day, source);
  const own = (direct.legs ?? []) as Record<string, unknown>[];
  const complete = own.filter(isCompleteLeg);
  if (complete.length > 0) return { legs: complete, cache: direct.cache };

  const dayMs = Date.parse(`${day}T00:00:00Z`);
  if (!isFinite(dayMs) || dayMs - Date.now() < 2 * 86_400_000) return direct;

  const todayMs = Date.parse(new Date().toISOString().slice(0, 10) + "T00:00:00Z");
  // Same weekday only (±7, ±14): a daily rotation also flies ±1, but a
  // Tue/Thu/Sat service doesn't, and a wrong day is worse than none.
  for (const offsetDays of [-7, 7, -14, 14]) {
    const nMs = dayMs + offsetDays * 86_400_000;
    if (nMs < todayMs) continue;
    const nDay = new Date(nMs).toISOString().slice(0, 10);
    const n = await fetchLegsCached(env, "flight", number, nDay, source);
    const templates = templatesFromNeighbour(n.legs as Record<string, unknown>[] | null, nDay, day);
    if (templates.length === 0) continue;
    // The day's own hollow record keeps whatever it did say (its own time,
    // a gate); the neighbour fills the rest.
    const legs = own.length > 0
      ? own.map(h => completeLeg(h, templates[0]!))
      : templates;
    return { legs, cache: "inferred" };
  }
  return direct;
}

async function resolveMarketingNumber(
  env: Env, number: string
): Promise<{ operating: string; dep: string; arr: string; depTimeUTC: string } | null> {
  const now = Date.now();
  for (let i = 0; i < 2; i++) {
    const day = new Date(now + i * 86_400_000).toISOString().slice(0, 10);
    const { legs } = await fetchLegsCached(env, "flight", number, day, "interactive");
    for (const leg of legs ?? []) {
      const operating = String(leg["flight_number"] ?? "").toUpperCase();
      const dep = String(leg["dep_iata"] ?? "").toUpperCase();
      const arr = String(leg["arr_iata"] ?? "").toUpperCase();
      // A DIFFERENT number coming back is precisely what marks this as a
      // codeshare. Same number back means an ordinary flight that simply
      // isn't scheduled on the requested date, and there is nothing to map.
      if (operating && dep && arr && operating !== number.toUpperCase()) {
        // The live-window leg is complete, so it also carries a real
        // scheduled departure time for this exact flight. That covers the
        // target date's record having had its departure side hollowed out,
        // at no extra provider call — same weekly-repeat reasoning route
        // discovery already runs on.
        return { operating, dep, arr, depTimeUTC: String(leg["dep_scheduled"] ?? "") };
      }
    }
  }
  return null;
}

async function airlabsFlightSearch(number: string, env: Env): Promise<Record<string, unknown>[]> {
  if (!env.AIRLABS_KEY || Date.now() < airlabsDeadUntil) return [];
  const clean = number.replace(/\s+/g, "");
  const res = await fetch(
    `https://airlabs.co/api/v9/flight?flight_iata=${encodeURIComponent(clean)}&api_key=${env.AIRLABS_KEY}`
  );
  if (!res.ok) return [];
  const data = await res.json() as { response?: Record<string, any>; error?: unknown };
  if (data.error) { airlabsDeadUntil = Date.now() + 6 * 3600_000; return []; }
  const f = data.response;
  if (!f || typeof f !== "object") return [];

  return [{
    flight_number: f.flight_iata ?? clean,
    airline_name: f.airline_name ?? "",
    airline_iata: f.airline_iata ?? "",
    dep_iata: f.dep_iata ?? "",
    arr_iata: f.arr_iata ?? "",
    dep_city: f.dep_city ?? null,
    arr_city: f.arr_city ?? null,
    dep_scheduled: airlabsToISO(f.dep_time_utc, f.dep_time),
    arr_scheduled: airlabsToISO(f.arr_time_utc, f.arr_time),
    dep_actual: f.dep_actual_utc ? airlabsToISO(f.dep_actual_utc, f.dep_actual) : null,
    arr_actual: f.arr_actual_utc ? airlabsToISO(f.arr_actual_utc, f.arr_actual) : null,
    status: AIRLABS_STATUS_MAP[f.status ?? ""] ?? "scheduled",
    dep_gate: f.dep_gate ?? null,
    dep_terminal: f.dep_terminal ?? null,
    arr_gate: f.arr_gate ?? null,
    arr_terminal: f.arr_terminal ?? null,
    arr_baggage: f.arr_baggage ?? null,
    delay: f.delayed ?? 0,
    aircraft_type: f.aircraft_icao ?? null,
    aircraft_registration: f.reg_number ?? null,
    aircraft_icao24: f.hex ?? null,
    dep_lat: f.dep_lat ?? null,
    dep_lon: f.dep_lng ?? null,
    arr_lat: f.arr_lat ?? null,
    arr_lon: f.arr_lng ?? null,
  }];
}

/// Search using AirLabs schedules endpoint (for future flights not yet active)
async function airlabsScheduleSearch(number: string, env: Env): Promise<Record<string, unknown>[]> {
  if (!env.AIRLABS_KEY) return [];
  const clean = number.replace(/\s+/g, "");
  const res = await fetch(
    `https://airlabs.co/api/v9/schedules?flight_iata=${encodeURIComponent(clean)}&api_key=${env.AIRLABS_KEY}`
  );
  if (!res.ok) return [];
  const data = await res.json() as { response?: Array<Record<string, any>> };
  if (!data.response || !Array.isArray(data.response)) return [];

  return data.response.map(f => ({
    flight_number: f.flight_iata ?? clean,
    airline_name: f.airline_name ?? f.airline_iata ?? "",
    airline_iata: f.airline_iata ?? "",
    dep_iata: f.dep_iata ?? "",
    arr_iata: f.arr_iata ?? "",
    dep_city: null,
    arr_city: null,
    dep_scheduled: airlabsToISO(f.dep_time_utc, f.dep_time),
    arr_scheduled: airlabsToISO(f.arr_time_utc, f.arr_time),
    dep_actual: null,
    arr_actual: null,
    status: AIRLABS_STATUS_MAP[f.status ?? ""] ?? "scheduled",
    dep_gate: f.dep_gate ?? null,
    dep_terminal: f.dep_terminal ?? null,
    arr_gate: f.arr_gate ?? null,
    arr_terminal: f.arr_terminal ?? null,
    arr_baggage: null,
    delay: f.delayed ?? 0,
    aircraft_type: f.aircraft_icao ?? null,
    aircraft_registration: null,
    aircraft_icao24: null,
    dep_lat: null,
    dep_lon: null,
    arr_lat: null,
    arr_lon: null,
  }));
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const cors = { "Access-Control-Allow-Origin": "*", "Content-Type": "application/json" };

    if (req.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
          "Access-Control-Max-Age": "86400",
        },
      });
    }

    // Rail and ferry live in their own module and answer null for anything
    // that isn't theirs, so the flight routes below are untouched by them.
    const transit = await handleTransit(req, url, cors);
    if (transit) return transit;

    if (url.pathname === "/health") {
      const budget = env.SUPABASE_SERVICE_KEY ? await budgetRow(env) : null;
      return Response.json({
        ok: true,
        providers: {
          aerodatabox: !!env.RAPIDAPI_KEY,
          airlabs: !!env.AIRLABS_KEY,
          ai: !!env.AI_API_KEY,
          supabase: !!env.SUPABASE_SERVICE_KEY,
          apns: !!(env.APNS_TEAM_ID && env.APNS_KEY_ID && env.APNS_P8),
          // Keyless public feeds — configured by definition. Named for what
          // /position actually calls (it left OpenSky for airplanes.live).
          airplaneslive: true,
          waitport: true,
        },
        budget: budget ? (() => {
          // Report against the REAL plan, not the bootstrap constant. Dividing
          // by ADB_MONTHLY_CALLS made a healthy account read "2246/900" — an
          // alarming number for something nothing was actually gating on,
          // since the gate is RapidAPI's own `remaining` (see fetchLegsCached).
          const used = (budget.adb_cron ?? 0) + (budget.adb_interactive ?? 0);
          const remaining = budget.adb_remaining as number | null | undefined;
          const planQuota = typeof remaining === "number" ? used + remaining : ADB_MONTHLY_CALLS;
          const cronReserve = Math.max(50, Math.floor(planQuota * ADB_CRON_RESERVE_SHARE));
          return {
            month: budget.month,
            adb_used: `${used}/${planQuota}`,
            adb_cron: `${budget.adb_cron}/${planQuota}`,
            // What RapidAPI itself last reported — the authority, unlike our count.
            adb_remaining_per_rapidapi: remaining ?? null,
            // Where each caller actually stops. The cron yields first so an
            // interactive search still works on the last of the quota.
            adb_plan_known: typeof remaining === "number",
            adb_cron_stops_below: typeof remaining === "number" ? cronReserve : null,
            adb_throttled: typeof remaining === "number" ? remaining <= cronReserve : used >= ADB_MONTHLY_CALLS,
            airlabs: `${budget.airlabs_calls}/${AIRLABS_BUDGET}`,
          };
        })() : null,
      }, { headers: cors });
    }

    // ── /parse-booking ── Extract flight number and date from a forwarded booking email or confirmation text
    if (url.pathname === "/parse-booking" && req.method === "POST") {
      if (!env.AI_API_KEY) {
        return Response.json({ error: "AI_API_KEY not configured on backend yet" }, { status: 503, headers: cors });
      }
      try {
        const body = await req.json<{ text?: string; email?: string }>() ?? {};
        const input = (body.text || body.email || "").trim();
        if (!input) {
          return Response.json({ error: "No booking text or email content provided" }, { status: 400, headers: cors });
        }

        let parsed;
        if (env.AI_API_KEY.startsWith("sk-ant-")) {
          // Anthropic Messages API. Structured outputs constrain the response
          // to this schema, so there is no markdown fence to strip and no
          // parse failure to swallow. Today's date is injected because
          // booking emails routinely omit the year ("Thu, 18 Sep").
          const aiRes = await fetch("https://api.anthropic.com/v1/messages", {
            method: "POST",
            headers: {
              "x-api-key": env.AI_API_KEY,
              "anthropic-version": "2023-06-01",
              "content-type": "application/json",
            },
            body: JSON.stringify({
              // Haiku, same as the search parse: trivial extraction, and
              // every flight it names is looked up against real schedule
              // data afterwards. No thinking param — Haiku doesn't think
              // unless asked.
              model: "claude-haiku-4-5",
              max_tokens: 1000,
              output_config: {
                format: {
                  type: "json_schema",
                  schema: {
                    type: "object",
                    properties: {
                      flights: {
                        type: "array",
                        items: {
                          type: "object",
                          properties: {
                            flightNumber: {
                              type: "string",
                              description: "IATA airline designator + number with no spaces, e.g. LX1413",
                            },
                            date: {
                              type: "string",
                              format: "date",
                              description: "Local departure date, YYYY-MM-DD",
                            },
                          },
                          required: ["flightNumber", "date"],
                          additionalProperties: false,
                        },
                      },
                    },
                    required: ["flights"],
                    additionalProperties: false,
                  },
                },
              },
              system: `You extract flight legs from booking confirmations, e-tickets and airline emails. Today's date is ${new Date().toISOString().slice(0, 10)}. Extract every flight leg. When the year is missing, pick the next occurrence of that date from today. If the text contains no flights, return an empty flights array.`,
              messages: [{ role: "user", content: input }],
            })
          });

          if (!aiRes.ok) {
            const errText = await aiRes.text();
            return Response.json({ error: "Anthropic extraction service failed", details: errText }, { status: 502, headers: cors });
          }

          const data = await aiRes.json<any>();
          if (data?.stop_reason === "refusal") {
            parsed = { flights: [] };
          } else {
            const text = (data?.content ?? []).find((b: any) => b.type === "text")?.text ?? '{"flights":[]}';
            try {
              parsed = JSON.parse(text);
            } catch {
              parsed = { flights: [] };
            }
          }
        } else {
          // OpenAI Chat Completions API fallback
          const aiRes = await fetch("https://api.openai.com/v1/chat/completions", {
            method: "POST",
            headers: {
              "Authorization": `Bearer ${env.AI_API_KEY}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "gpt-4o-mini",
              temperature: 0.1,
              response_format: { type: "json_object" },
              messages: [
                {
                  role: "system",
                  content: "You are an expert flight booking information extraction assistant. Extract all flight legs from the provided confirmation text or email. Return a JSON object with an array 'flights', where each item has 'flightNumber' (standard IATA like LX1413, no extra spaces) and 'date' (YYYY-MM-DD in local departure time, defaulting to near future if year is missing). If no flights found, return { \"flights\": [] }."
                },
                { role: "user", content: input }
              ]
            })
          });

          if (!aiRes.ok) {
            const errText = await aiRes.text();
            return Response.json({ error: "OpenAI extraction service failed", details: errText }, { status: 502, headers: cors });
          }

          const data = await aiRes.json<any>();
          const content = data?.choices?.[0]?.message?.content ?? "{\"flights\":[]}";
          try {
            parsed = JSON.parse(content);
          } catch {
            parsed = { flights: [] };
          }
        }

        return Response.json({ ok: true, flights: parsed?.flights ?? [] }, { headers: cors });
      } catch (err: any) {
        return Response.json({ error: "Invalid request format or JSON", details: err?.message }, { status: 400, headers: cors });
      }
    }

    // ── /search-flights ── natural-language search: routes, codeshares, free text
    //
    // "Athens to Munich on 18 September" or "A31653 18 Sep" (a codeshare
    // marketing number no provider indexes). One AI call turns the text into
    // explicit numbers, a route, and *likely operating flights*; AirLabs route
    // schedules add real candidates when its quota is alive. Every candidate
    // is then verified against the cached AeroDataBox pipeline for the target
    // date — an AI guess that doesn't verify is dropped, so hallucination
    // can't reach the user. Returns the verified flights; the app lets the
    // user pick.
    if (url.pathname === "/search-flights" && req.method === "POST") {
      // Declared out here so the catch below can still return whatever the
      // rail/ferry providers managed, even when the flight path threw.
      let groundAndWater: Promise<Record<string, unknown>[]> = Promise.resolve([]);
      try {
        const body = await req.json<{ query?: string; dep_iata?: string; arr_iata?: string; date?: string }>() ?? {};
        const query = (body.query ?? "").trim();
        if (!query) return Response.json({ error: "Empty query" }, { status: 400, headers: cors });

        // ── which kinds of journey could this be? ──
        //
        // One search box, no mode picker, so the query itself decides. Rail and
        // sea are started FIRST and awaited at the end: they talk to different
        // providers than the flight pipeline, so running them alongside costs
        // nothing in wall-clock and a train stops being second-class.
        //
        // Air is never skipped. It is the mode Arc has always answered and the
        // classifier is evidence, not proof — dropping the flight search on a
        // guess would be a strictly worse failure than an extra query.
        const wanted = new Set(modesToQuery(query));
        const queryRoute = routeFromQuery(query);
        // The date, without an AI round-trip. Rail and ferry have no other use
        // for the parser, so making them wait on it — and fall back to TODAY
        // when it is slow or unconfigured — answered September bookings with
        // this afternoon's sailings.
        const clientDay = /^\d{4}-\d{2}-\d{2}$/.test(body.date ?? "") ? body.date! : undefined;
        const searchDay = clientDay ?? dateFromQuery(query) ?? new Date().toISOString().slice(0, 10);

        // Kicked off with whatever day we already know. When the client didn't
        // send one, the date lives in the free text ("10 Sep") and only the
        // parser can read it — so the call is deferred until the parse lands
        // rather than silently searching today. Getting this wrong is not
        // subtle: it answers a September booking with this afternoon's sailings.
        const startGroundAndWater = (day: string) => (async () => {
          if (!queryRoute || (!wanted.has("rail") && !wanted.has("sea"))) return [];
          const origin = new URL(req.url).origin;
          const jobs: Promise<Record<string, unknown>[]>[] = [];
          // In-process, not a fetch to our own public URL: a Worker cannot
          // loop back to itself over the network (the request never leaves
          // the isolate and fails), which made every rail/sea fan-out return
          // [] in production while the direct endpoints worked fine.
          const ask = async (path: string) => {
            try {
              const u = new URL(`${origin}${path}`);
              const r = await handleTransit(new Request(u.toString(), { headers: { Accept: "application/json" } }), u, cors);
              if (!r || !r.ok) return [];
              const j = await r.json();
              return Array.isArray(j) ? j as Record<string, unknown>[] : [];
            } catch { return []; }   // a provider being down must not fail the search
          };
          if (wanted.has("rail")) {
            jobs.push(ask(`/rail/search?from=${encodeURIComponent(queryRoute.from)}` +
              `&to=${encodeURIComponent(queryRoute.to)}&date=${day}`));
          }
          if (wanted.has("sea")) {
            jobs.push(ask(`/ferry/search?from=${encodeURIComponent(queryRoute.from)}` +
              `&to=${encodeURIComponent(queryRoute.to)}&date=${day}`));
          }
          return (await Promise.all(jobs)).flat();
        })();
        groundAndWater = startGroundAndWater(searchDay);

        // The app resolves plain routes locally and sends them pre-parsed —
        // skipping the AI call, which is most of a warm search's latency.
        // AI stays the parser for everything it can't read.
        const t0 = Date.now();
        const timings: Record<string, number> = {};
        const preParsed = /^[A-Z]{3}$/i.test(body.dep_iata ?? "")
          && /^[A-Z]{3}$/i.test(body.arr_iata ?? "")
          && /^\d{4}-\d{2}-\d{2}$/.test(body.date ?? "");
        let parsed: ParsedFlightQuery | null;
        if (preParsed) {
          parsed = { flights: [], dep_iata: body.dep_iata!, arr_iata: body.arr_iata!,
                     date: body.date!, candidates: [] };
        } else {
          if (!env.AI_API_KEY?.startsWith("sk-ant-")) {
            // Rail and sea don't need the parser — they read place names
            // straight off the query — so a missing AI key must not take them
            // down with the flight search.
            const only = await groundAndWater;
            if (only.length) return Response.json({ flights: only }, { headers: cors });
            return Response.json({ error: "AI search not configured" }, { status: 503, headers: cors });
          }
          // Same text, same day → same parse. Keyed by day because relative
          // dates ("tomorrow") change meaning at midnight. Saves the single
          // slowest fixed cost (~2-3 s) on every repeat, from any device.
          const norm = query.toLowerCase().replace(/\s+/g, " ");
          const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(norm));
          const qhash = [...new Uint8Array(digest)].slice(0, 16)
            .map(b => b.toString(16).padStart(2, "0")).join("");
          const pkey = `aiparse|${new Date().toISOString().slice(0, 10)}|${qhash}`;
          const prow = (await cacheRows(env, [pkey])).get(pkey);
          if (prow && Date.now() - Date.parse(String(prow.fetched_at)) < 24 * 3600_000) {
            parsed = prow.payload as unknown as ParsedFlightQuery;
          } else {
            parsed = await aiParseFlightQuery(query, env);
            if (parsed) {
              const fresh = { key: pkey, payload: parsed, provider: "aiparse", fetched_at: new Date().toISOString() };
              rowMemoSet(pkey, fresh);
              const w = await sbService(env, "POST", "/flight_cache?on_conflict=key", fresh);
              if (!w.ok) console.error("aiparse cache write failed:", w.status, await w.text());
            }
          }
        }
        timings["parse"] = Date.now() - t0;
        // The parser failing says nothing about a ferry: "Piraeus to Santorini"
        // names no airport, so the AI legitimately returns nothing while the
        // sailing the user actually wants is sitting in the other result.
        if (!parsed) {
          return Response.json({ flights: await groundAndWater }, { headers: cors });
        }

        const today = new Date().toISOString().slice(0, 10);
        // The model's date is a string it composed — only a real ISO day may
        // reach provider URL paths or Date() math (C1: an unpadded "2026-9-18"
        // made adbRouteDiscovery throw and 500 the whole search).
        const defaultDay = parsed.date && ISO_DAY.test(parsed.date) ? parsed.date : today;


        // Check the parser's route against the places the query actually names.
        // Asked for "Syros to Athens" it answers JTR — Santorini — and the
        // search then offered a different island's departures as the answer.
        // Instructing it not to changed nothing; it still says JTR. So the
        // answer is verified rather than trusted. A pre-parsed route came from
        // the client's own airport table and needs no second opinion.
        let dropped: string[] = [];
        if (!preParsed) {
          const checked = verifiedRoute(query, parsed.dep_iata, parsed.arr_iata);
          dropped = checked.dropped;
          if (dropped.length) {
            console.error("route verification dropped:", dropped.join(","), "for:", query.slice(0, 80));
          }
          parsed = { ...parsed, dep_iata: checked.dep, arr_iata: checked.arr };
        }

        let route = parsed.dep_iata && parsed.arr_iata
          ? { dep: parsed.dep_iata.toUpperCase(), arr: parsed.arr_iata.toUpperCase() }
          : null;

        // Codeshare marketing numbers used to be resolved here, against
        // AirLabs' schedule DB. That could never have worked: AirLabs
        // /schedules reaches at most ~10 hours ahead, and cs_flight_iata is a
        // RESPONSE field, not a query parameter — so the lookup filtered on
        // nothing and answered about nothing. Resolution now happens after
        // verification instead (see "marketing number" below), where it costs
        // provider calls only for the searches that actually need it.

        // Candidates in priority order: numbers the user actually typed,
        // then AirLabs schedule rows for the route (operating AND codeshare
        // columns — verification sorts out which is real), then AI guesses.
        const candidates: { number: string; date: string }[] = [];
        const push = (num: string | undefined | null, date: string) => {
          const clean = (num ?? "").replace(/[^A-Z0-9]/gi, "").toUpperCase();
          if (clean.length >= 3 && !candidates.some(c => c.number === clean && c.date === date)) {
            candidates.push({ number: clean, date });
          }
        };
        for (const f of parsed.flights ?? []) push(f.number, f.date || defaultDay);
        // Scheduled departure times off the route's board, by flight number.
        // The only source of a departure time for a leg the provider served
        // with its departure side hollowed out — see `repairLegForRoute`.
        const boardTimeByNumber = new Map<string, string>();
        if (route) {
          // Real data first: the departure board names the route's flights;
          // AirLabs adds rows when its quota allows. The AI's own guesses come
          // last — they're the weakest source and exist only as a fallback.
          const [discovery, airlabsRows] = await Promise.all([
            adbRouteDiscovery(env, route.dep, route.arr, defaultDay),
            airlabsRouteSchedules(route.dep, route.arr, env),
          ]);
          for (const b of discovery.board) {
            if (b.time && !boardTimeByNumber.has(b.number)) boardTimeByNumber.set(b.number, b.time);
          }
          // Where a board DOES list a codeshare marketing number as its own
          // row, the rows sharing its movement name the operating flight, and
          // those siblings outrank plain route discovery. Measured caveat:
          // Athens' board does not list A31653, so this resolves nothing for
          // the case it was written for — `resolveMarketingNumber` is what
          // actually handles that, further down.
          for (const f of parsed.flights ?? []) {
            const clean = (f.number ?? "").replace(/[^A-Z0-9]/gi, "").toUpperCase();
            const mine = discovery.board.find(b => b.number === clean);
            if (!mine) continue;
            for (const sib of discovery.board) {
              if (sib.number !== mine.number && sib.dest === mine.dest && sib.time === mine.time) {
                push(sib.number, f.date || defaultDay);
              }
            }
          }
          for (const num of discovery.routeNumbers) push(num, defaultDay);
          for (const row of airlabsRows) {
            push(row.operating, defaultDay);
            push(row.marketing, defaultDay);
          }
        }
        // AI-guessed numbers are only usable when a route filters them —
        // unfiltered, a wrong guess that happens to be a real flight
        // somewhere (CA1653 for "A31653") sails through verification.
        if (route) for (const num of parsed.candidates ?? []) push(num, defaultDay);
        timings["discovery"] = Date.now() - t0 - timings["parse"];

        // The requested date is the LOCAL departure date; leg timestamps are
        // UTC. Strict equality dropped every verified flight whose UTC date
        // differs from its local one (00:30 JST = previous day in UTC) —
        // paid for, correct, and then filtered out. ADB's by-number endpoint
        // is itself local-date-indexed, so ±1 day is exact, not sloppy.
        const sameFlightDay = (legIso: unknown, dateStr: string) => {
          const leg = String(legIso ?? "").slice(0, 10);
          if (!leg) return false;
          const diff = Math.abs(Date.parse(`${leg}T00:00Z`) - Date.parse(`${dateStr}T00:00Z`));
          return isFinite(diff) && diff <= 86_400_000;
        };
        // Verify candidates concurrently, but through a pool of 4: the full
        // 8-wide burst tripped the provider's per-second rate limit, and a
        // rate-limited candidate silently vanished from THAT search only —
        // identical searches grew 5 → 6 → 7 results as the cache filled in.
        // `legs === null` means transient failure (429/network), never
        // "doesn't exist" — those get one delayed retry so the first search
        // already returns the complete set.
        const capped = candidates.slice(0, 8);
        // One bulk read for every candidate's cache row — per-candidate
        // reads plus retries overflowed Cloudflare's 50-subrequests-per-
        // invocation cap on cold searches (the whole search 500'd).
        const keyOf = (c: { number: string; date: string }) => `flight|${c.number}|${c.date}`;
        const preByKey = await cacheRows(env, capped.map(keyOf));
        // AeroDataBox rate-limits per second (a 4-wide burst drew 429s and
        // identical searches grew result by result as stragglers cached).
        // Pipelined pacing: LAUNCH one provider call every ~1.4 s without
        // waiting for its response — same safe request rate as before, minus
        // one response-time per cold candidate. Cache hits pass instantly.
        // Failures get one serial, paced retry pass at the end.
        const slots: (CachedFetch | Promise<CachedFetch>)[] = [];
        let lastLaunch = 0;
        for (const c of capped) {
          const pre = preByKey.get(keyOf(c)) ?? null;
          if (cachedRowFresh(pre)) {
            slots.push({ legs: pre!.payload as Record<string, unknown>[], cache: "hit" });
            continue;
          }
          // 1.1 s spacing: the provider limit is per-second — 1.4 s was
          // comfortable but cost ~2.5 s extra on an 8-candidate cold search.
          const wait = lastLaunch + 1100 - Date.now();
          if (wait > 0) await new Promise((r) => setTimeout(r, wait));
          lastLaunch = Date.now();
          slots.push(fetchLegsCached(env, "flight", c.number, c.date, "interactive", pre));
        }
        const settled = await Promise.all(slots.map((s) => Promise.resolve(s)));
        let retriesLeft = 3;
        for (let i = 0; i < settled.length; i++) {
          if (settled[i].legs === null && retriesLeft-- > 0) {
            await new Promise((r) => setTimeout(r, 1100));
            settled[i] = await fetchLegsCached(env, "flight", capped[i].number, capped[i].date, "interactive", null);
          }
        }
        const verified = capped.map((c, i) => ({ c, legs: settled[i].legs ?? [] }));
        const results: Record<string, unknown>[] = [];
        const collect = (legs: Record<string, unknown>[], forRoute: typeof route, date: string,
                         fallbackBoardTime: string | null = null) => {
          for (const raw of legs) {
            const board = boardTimeByNumber.get(String(raw["flight_number"] ?? "").toUpperCase())
              ?? fallbackBoardTime;
            const leg = repairLegForRoute(raw, forRoute, board, date);
            if (!leg) continue;
            // The searched date is a LOCAL departure date, and when the leg
            // carries its own the comparison is exact — which is the only way
            // to separate a route's two consecutive operations when it lands
            // after midnight (see `departsOnLocalDate`).
            if (!departsOnLocalDate(leg, date)) continue;
            // Either timestamp dates the leg. Requiring the departure one
            // dropped every record whose departure side the provider had
            // hollowed out — the same flights the route filter was dropping.
            // This stays the answer for a leg with no local date of its own:
            // one repaired from a departure board, or cached before they were
            // kept. ±1 day, because a UTC stamp and a local date legitimately
            // disagree by one.
            if (!sameFlightDay(leg["dep_scheduled"] || leg["arr_scheduled"], date)) continue;
            if (results.some(r => r["flight_number"] === leg["flight_number"]
                               && r["dep_scheduled"] === leg["dep_scheduled"])) continue;
            results.push(leg);
          }
        };
        for (const { c, legs } of verified) collect(legs, route, c.date);

        // Nothing verified, and the user typed a flight number with no route
        // to anchor it: that is what a codeshare marketing number looks like
        // from here. Resolve it against the live window and search the flight
        // that actually operates it. Costs provider calls only on searches
        // that have already come back empty.
        if (results.length === 0 && !route) {
          for (const f of (parsed.flights ?? []).slice(0, 2)) {
            const clean = (f.number ?? "").replace(/[^A-Z0-9]/gi, "").toUpperCase();
            if (clean.length < 3) continue;
            const resolved = await resolveMarketingNumber(env, clean);
            if (!resolved) continue;
            const day = f.date || defaultDay;
            const opRoute = { dep: resolved.dep, arr: resolved.arr };
            const { legs } = await fetchLegsCached(env, "flight", resolved.operating, day, "interactive");
            // Carry the number the user actually typed. They booked A31653;
            // answering with a bare "LH1751" is correct but unrecognisable, so
            // the app can show both.
            const tagged = (legs ?? []).map(l => ({ ...l, marketing_number: clean }));
            collect(tagged, opRoute, day, resolved.depTimeUTC || null);
            if (results.length) break;
          }
        }
        // Trains and sailings join the same list, sorted with the flights by
        // departure. They are the same shape, so one result list stays one
        // result list — the user picks a journey, not a mode.
        const other = await groundAndWater;
        const merged = [...results, ...other].sort((a: any, b: any) =>
          String(a?.dep_scheduled ?? "").localeCompare(String(b?.dep_scheduled ?? "")));

        if ((body as any).debug) {
          timings["verify"] = Date.now() - t0 - timings["parse"] - timings["discovery"];
          return Response.json({ flights: merged, parsed, candidates, timings, dropped,
                                 modes: [...wanted], route: queryRoute }, { headers: cors });
        }
        return Response.json({ flights: merged }, { headers: cors });
      } catch (err: any) {
        // The flight pipeline failing says nothing about the ferry search that
        // already succeeded beside it. Returning what we have beats returning
        // an error the user can do nothing about — and it keeps rail and sea
        // working when AeroDataBox, Supabase or the parser is down.
        try {
          const salvaged = await groundAndWater;
          if (salvaged.length) return Response.json({ flights: salvaged }, { headers: cors });
        } catch { /* nothing to salvage */ }
        return Response.json({ error: "Search failed", details: err?.message }, { status: 500, headers: cors });
      }
    }

    // ── /flight?number=LX1413&date=2026-07-20 ── status by flight number + date
    if (url.pathname === "/flight") {
      const number = url.searchParams.get("number");
      const date = url.searchParams.get("date");
      if (!number) return new Response("missing number", { status: 400, headers: cors });
      // The date lands in a provider URL path unencoded — anything but a
      // plain ISO day would let an anonymous caller steer the paid API key
      // at arbitrary endpoints ("../../airports/…").
      if (date && !ISO_DAY.test(date)) return Response.json([], { headers: cors });

      // 1. Shared cache → AeroDataBox (budget-guarded). One answer serves
      // every family device, the cron, and share pages for its TTL.
      //
      // `date` is a LOCAL departure date, and it is worth being exact about
      // where it comes from. The tracker and the schedule backfill build it in
      // the departure airport's own zone. The Add-a-flight search cannot — it
      // has no airport yet, only a number — so it sends the calendar date the
      // traveller typed, read in the device's zone. For a typed date those are
      // the same string: it is parsed and formatted in the same calendar, so
      // it round-trips exactly. They can diverge only when NO date was typed
      // and "today" is taken from the device while the departure airport is
      // hours away — and there the device's today is as fair a reading of
      // "this flight, now" as anything the server could invent.
      const day = date ?? new Date().toISOString().slice(0, 10);
      const { legs: cachedLegs, cache } = await legsWithWeeklyFallback(env, number, day, "interactive");
      // The gate is "did AeroDataBox answer at all", and the answer is then
      // narrowed to the day that was asked about — see `answerForDay` for why
      // an all-wrong-day answer is an empty one rather than a fall-through.
      if (cachedLegs && cachedLegs.length > 0) {
        return Response.json(answerForDay(cachedLegs, date),
                             { headers: { ...cors, "x-arc-cache": cache } });
      }

      // 2. Fallback: AirLabs. Its /flight endpoint is REAL-TIME ONLY — it
      // returns the flight's current leg regardless of what date was asked
      // for. Without the date filter below, polling tomorrow's flight while
      // AeroDataBox is down stamped TODAY's landed leg (status + actual
      // times) onto it, corrupting the stored flight.
      if (env.AIRLABS_KEY) {
        try {
          const matchesDate = (r: Record<string, unknown>) =>
            !date || String(r["dep_scheduled"] ?? "").slice(0, 10) === date;
          // Try real-time flight endpoint first (active flights)
          let results = (await airlabsFlightSearch(number, env)).filter(matchesDate);
          // If no active flight, try schedules
          if (results.length === 0) {
            results = (await airlabsScheduleSearch(number, env)).filter(matchesDate);
          }
          if (results.length > 0) {
            // Cache only date-anchored answers. A date-less query passes the
            // filter above unconditionally, and AirLabs is real-time-only —
            // caching ITS current leg under today's key let the cron read
            // "landed" for a flight that hadn't departed and end its Live
            // Activity.
            if (date) await cacheAirlabsResult(env, number, day, results as Record<string, unknown>[]);
            const b = await budgetRow(env);
            await budgetBump(env, "airlabs_calls", (b["airlabs_calls"] as number) ?? 0);
            return Response.json(results, { headers: { ...cors, "x-arc-cache": "airlabs" } });
          }
        } catch { /* fall through */ }
      }

      // 3. Still nothing, and a future date: the number may be a codeshare
      // marketing number, which no provider indexes at range. Resolve it in
      // the live window and answer with the flight that actually operates it.
      //
      // This is what gives an ALREADY-ADDED flight live data. A flight saved
      // as "A31653" was polled here by the tracker and the daily schedule
      // backfill on every pass, got [] every time, and so never acquired a
      // schedule, a gate, a position or a Live Activity — the flight simply
      // sat dead in the list until the day before departure. Both callers
      // match legs on route and time rather than on the number (see
      // ScheduleBackfill.bestLeg), so the operating flight's leg lands on the
      // right flight without the app needing to know any of this.
      if (date && Date.parse(`${date}T00:00:00Z`) > Date.now()) {
        const resolved = await resolveMarketingNumber(env, number);
        if (resolved) {
          const { legs } = await legsWithWeeklyFallback(env, resolved.operating, day, "interactive");
          const marketing = number.replace(/\s+/g, "").toUpperCase();
          // Same day rule as the direct answer above: the operating flight has
          // consecutive operations too, and a codeshare traveller is no less
          // able to add yesterday's by mistake.
          const onRoute = answerForDay(legs ?? [], date)
            .map(l => repairLegForRoute({ ...l, marketing_number: marketing },
                                        { dep: resolved.dep, arr: resolved.arr },
                                        resolved.depTimeUTC || null, day))
            .filter((l): l is Record<string, unknown> => l !== null);
          if (onRoute.length > 0) {
            return Response.json(onRoute, { headers: { ...cors, "x-arc-cache": "codeshare" } });
          }
        }
      }

      return Response.json([], { headers: cors });
    }

    // ── /inbound?reg=HB-JMB&date=2026-07-20 ── previous leg of the same tail
    if (url.pathname === "/inbound") {
      const reg = url.searchParams.get("reg");
      const date = url.searchParams.get("date");
      if (!reg) return Response.json(null, { headers: cors });
      if (date && !ISO_DAY.test(date)) return Response.json([], { headers: cors });
      const regDay = date ?? new Date().toISOString().slice(0, 10);
      const { legs, cache } = await fetchLegsCached(env, "reg", reg, regDay, "interactive");
      // the leg immediately before the queried flight is the inbound
      return Response.json(legs ?? [], { headers: { ...cors, "x-arc-cache": cache } });
    }

    // ── /position?icao24=…&reg=…&flight=… ── live position (airplanes.live) ──
    //
    // Was OpenSky, which returned 502 through here: it rejects Cloudflare's
    // egress IPs, so the plane simply never appeared. airplanes.live is free,
    // needs no key, answers from Workers, and carries more — registration,
    // type and callsign — plus how old the fix is.
    //
    // Three ways in, tried in order. A missing hex code used to abort the whole
    // feature silently; registration and callsign are both enough on their own.
    if (url.pathname === "/position") {
      const attempts = [
        ["icao", url.searchParams.get("icao24")],
        ["reg", url.searchParams.get("reg")],
        ["callsign", url.searchParams.get("flight")],
      ].filter(([, v]) => !!v) as [string, string][];

      if (attempts.length === 0) return new Response("missing icao24, reg or flight", { status: 400 });

      // ?debug=1 — which host answered what. Cloudflare egress has been
      // rejected by ADS-B aggregators before (OpenSky), and a silent null
      // is indistinguishable from "nothing is flying".
      if (url.searchParams.get("debug")) {
        const diag: Record<string, unknown> = {};
        for (const host of ADSB_HOSTS) {
          for (const [kind, value] of attempts) {
            const key = value.trim().replace(/\s+/g, "").toLowerCase();
            try {
              const res = await fetch(`${host.base}${host.prefix}/${kind}/${encodeURIComponent(key)}`,
                                      { headers: { Accept: "application/json", "User-Agent": adsbUA(env) } });
              const body = await res.text();
              diag[`${host.base} ${kind}`] = { status: res.status, body: body.slice(0, 140) };
            } catch (e) {
              diag[`${host.base} ${kind}`] = { error: String(e) };
            }
          }
        }
        return Response.json(diag, { headers: cors });
      }

      for (const [kind, value] of attempts) {
        const pos = await fetchADSB(env, kind, value);
        if (pos) return Response.json(pos, { headers: cors });
      }
      return Response.json(null, { status: 404, headers: cors });
    }

    // ── /s/:code ── live share page. Server-rendered (route + times + OG
    // tags baked in, so iMessage unfurls and there's no loading flash), then
    // the page polls /s/:code/data. All Supabase reads happen HERE with the
    // service key — shared_flights RLS blocks anon, which is why the old
    // /journey page could never load.
    const shareDataMatch = url.pathname.match(/^\/s\/([a-z0-9]+)\/data$/);
    if (shareDataMatch) {
      const payload = await loadSharePayload(env, shareDataMatch[1]);
      if (!payload) return Response.json({ error: "not_found" }, { status: 404, headers: cors });
      return Response.json(payload, { headers: cors });
    }
    const shareMatch = url.pathname.match(/^\/s\/([a-z0-9]+)$/);
    if (shareMatch) {
      const payload = await loadSharePayload(env, shareMatch[1]);
      return new Response(sharePageHTML(shareMatch[1], payload), {
        status: payload ? 200 : 404,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }
    // Legacy share URLs from earlier builds.
    const journeyMatch = url.pathname.match(/^\/journey\/([a-z0-9]+)$/);
    if (journeyMatch) {
      return Response.redirect(`${url.origin}/s/${journeyMatch[1]}`, 301);
    }

    // ── /f/:code ── friend-invite landing page. Phone with Arc installed:
    // "Open in Arc" jumps into the app via arc://friend/<code>. Anyone else
    // gets the what-is-this pitch (Flighty-style).
    const inviteMatch = url.pathname.match(/^\/f\/([a-z0-9]+)$/);
    if (inviteMatch) {
      const code = inviteMatch[1];
      const invites = await sbSelect(env,
        `/friend_invites?code=eq.${encodeURIComponent(code)}&select=inviter,expires_at`);
      let inviterName: string | null = null;
      let expired = false;
      if (invites.length) {
        expired = !!invites[0].expires_at && Date.parse(invites[0].expires_at) < Date.now();
        const profs = await sbSelect(env, `/profiles?id=eq.${invites[0].inviter}&select=display_name`);
        inviterName = profs[0]?.display_name || null;
      }
      return new Response(invitePageHTML(code, inviterName, expired), {
        status: invites.length ? 200 : 404,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    // ── /weather/hazards — real en-route weather, as published ──
    //
    // SIGMETs and AIRMETs from aviationweather.gov: actual hazard areas with
    // real polygons, hazard type, altitude band and a validity window. Free,
    // keyless, and global (the international feed covers every FIR).
    //
    // This replaces a client-side generator that derived a "storm cell" and a
    // "jet stream" from the hash of the flight number — invented data drawn on
    // the map as though observed, and not even stable, since Swift seeds
    // hashValue per process so it changed on every launch.
    if (url.pathname === "/weather/hazards") {
      const sources = [
        "https://aviationweather.gov/api/data/isigmet?format=json",
        "https://aviationweather.gov/api/data/airsigmet?format=json",
      ];
      const hazards: Record<string, unknown>[] = [];

      await Promise.all(sources.map(async (src) => {
        try {
          // Edge-cached: SIGMETs are issued hourly and valid for hours, so a
          // 10-minute TTL serves every device from one upstream fetch.
          const res = await fetch(src, { cf: { cacheTtl: 600, cacheEverything: true } });
          if (!res.ok) return;
          const rows = await res.json() as Record<string, any>[];
          for (const r of Array.isArray(rows) ? rows : []) {
            const coords = (r.coords ?? []).filter(
              (c: any) => typeof c?.lat === "number" && typeof c?.lon === "number");
            if (coords.length < 3) continue;   // need a polygon, not a point
            hazards.push({
              kind: hazardKind(String(r.hazard ?? "")),
              severe: isSevereHazard(r),
              base: r.base ?? r.altitudeLow1 ?? null,
              top: r.top ?? r.altitudeHi1 ?? null,
              region: r.firName ?? r.firId ?? r.icaoId ?? null,
              validTo: r.validTimeTo ?? null,
              coords: coords.map((c: any) => ({ lat: c.lat, lon: c.lon })),
            });
          }
        } catch { /* one source failing shouldn't blank the other */ }
      }));

      // Never hand back an expired advisory — a stale storm is worse than none.
      const nowSec = Math.floor(Date.now() / 1000);
      const live = hazards.filter((h) => !h.validTo || (h.validTo as number) >= nowSec);

      return Response.json({ ok: true, updated: new Date().toISOString(), hazards: live },
                           { headers: { ...cors, "cache-control": "public, max-age=300" } });
    }

    // ── /weather/airport?icao=LSZH&at=<iso> — conditions now AND at a time ──
    //
    // What actually delays a departure is the weather at the airport, not a
    // storm cell en route (aircraft route around those and lose minutes). This
    // returns the current METAR plus the TAF period covering `at`, normalised.
    // The app scores the risk from these numbers so the thresholds stay
    // testable in Swift rather than buried in a Worker.
    //
    // aviationweather.gov carries international METAR/TAF, so European stations
    // (LSZH, LGAV, EDDM …) work the same as US ones. Keyless and free.
    if (url.pathname === "/weather/airport") {
        const icao = (url.searchParams.get("icao") ?? "").toUpperCase().slice(0, 4);
        if (!/^[A-Z]{4}$/.test(icao)) {
          return Response.json({ error: "icao required" }, { status: 400, headers: cors });
        }
        const at = Date.parse(url.searchParams.get("at") ?? "") || Date.now();
        const atSec = Math.floor(at / 1000);

        const [metarRes, tafRes] = await Promise.all([
          fetch(`https://aviationweather.gov/api/data/metar?ids=${icao}&format=json`,
                { cf: { cacheTtl: 300, cacheEverything: true } }).catch(() => null),
          fetch(`https://aviationweather.gov/api/data/taf?ids=${icao}&format=json`,
                { cf: { cacheTtl: 900, cacheEverything: true } }).catch(() => null),
        ]);

        // Not every airport is observed, and fewer are forecast: Syros (LGSO)
        // has a METAR and no TAF, and the provider says so with a 204 and an
        // empty body. Parsing that leniently is what keeps an uncovered
        // airport a null forecast instead of a 500 on the detail screen.
        const [metarRows, tafRows] = await Promise.all([wxRows(metarRes), wxRows(tafRes)]);

        return Response.json(airportWeatherPayload(icao, atSec, metarRows, tafRows),
                             { headers: { ...cors, "cache-control": "public, max-age=300" } });
    }

    // ── /arrival-gate?icao=&flight=&from=&to= — the stand, where published ──
    //
    // The flight-by-number endpoint returns arrival.gate as null everywhere —
    // checked across eight legs at ZRH, LHR and JFK, landed and airborne. The
    // airport FIDS endpoint DOES carry it, but only for airports that publish
    // stands: Frankfurt returned gates for 31 of 33 arrivals, Zurich and
    // Heathrow for none of theirs. (The inverse holds for belts, which ZRH
    // publishes and FRA doesn't — each airport shares what it shares.)
    //
    // One FIDS call covers a whole arrival window, so it's cached per airport
    // and hour: several flights landing around the same time cost one request
    // between them, not one each.
    //
    // `from`/`to` are LOCAL to the airport and supplied by the caller, which
    // carries a timezone database; the Worker does not.
    if (url.pathname === "/arrival-gate") {
      const icao = (url.searchParams.get("icao") ?? "").toUpperCase();
      const flight = (url.searchParams.get("flight") ?? "").toUpperCase().replace(/\s+/g, "");
      const from = url.searchParams.get("from") ?? "";
      const to = url.searchParams.get("to") ?? "";
      if (!/^[A-Z]{4}$/.test(icao) || !flight || !from || !to) {
        return Response.json({ error: "icao, flight, from and to are required" },
                             { status: 400, headers: cors });
      }

      // Key on the WHOLE window. Start-hour alone made two different windows
      // share one cached board — a flight arriving in the part only the
      // second window covered got a wrong "not found" for 5 minutes.
      const key = `fids|${icao}|${from.slice(0, 13)}|${to.slice(0, 13)}`;
      let arrivals = await cachedFids(env, key);

      if (!arrivals) {
        if (!env.RAPIDAPI_KEY) return Response.json(null, { status: 404, headers: cors });
        const budget = await budgetRow(env);
        const remaining = budget["adb_remaining"] as number | null | undefined;
        // Same guard as every other provider call — a gate is a nicety, and
        // must never be the thing that exhausts the plan.
        if (typeof remaining === "number" && remaining <= 0) {
          return Response.json(null, { status: 404, headers: cors });
        }
        const path = `/flights/airports/icao/${icao}/${encodeURIComponent(from)}/${encodeURIComponent(to)}`
          + `?withLeg=false&direction=Arrival&withCancelled=false&withCodeshared=true`
          + `&withCargo=false&withPrivate=false&withLocation=false`;
        const res = await adbFetch(path, env);
        await budgetBump(env, "adb_interactive", (budget["adb_interactive"] as number) ?? 0,
                         res.headers.get("x-ratelimit-requests-remaining"));
        if (!res.ok) {
          return Response.json({ error: "fids", status: res.status,
                                 detail: (await res.text()).slice(0, 200) },
                               { status: 404, headers: cors });
        }
        const raw = await res.json() as Record<string, any>;
        arrivals = (raw?.arrivals ?? []) as Record<string, any>[];
        await storeFids(env, key, arrivals);
      }

      const match = arrivals.find(a =>
        String(a.number ?? "").toUpperCase().replace(/\s+/g, "") === flight);
      // Report what was actually seen: "no gate published" and "flight not in
      // this window" are different problems and shouldn't look identical.
      if (!match) {
        return Response.json({ matched: false, arrivalsInWindow: arrivals.length },
                             { status: 404, headers: cors });
      }

      return Response.json({
        flight,
        gate: match.movement?.gate ?? null,
        terminal: match.movement?.terminal ?? null,
        belt: match.movement?.baggageBelt ?? null,
      }, { headers: { ...cors, "cache-control": "public, max-age=120" } });
    }

    // ── /security/:iata — airport security wait time ──
    const securityMatch = url.pathname.match(/^\/security\/([A-Z]{3})$/i);
    if (securityMatch) {
      const iata = securityMatch[1]!.toUpperCase();
      try {
        // 1. Try Waitport (free, covers EU: FRA, MUC, DUS, AMS, LHR, CPH, ARN, EDI, DUB, IST)
        const wpRes = await fetch(`https://waitport.com/api/v1/all?airport=eq.${iata}&order=id.desc&limit=1`);
        if (wpRes.ok) {
          const wpData = await wpRes.json() as Array<{ queue: number; timestamp: string; airport: string }>;
          if (wpData.length > 0 && wpData[0]) {
            return Response.json({
              iata,
              securityMinutes: wpData[0].queue,
              source: "waitport",
              updatedAt: wpData[0].timestamp
            }, { headers: cors });
          }
        }

        // 2. Fallback: time-of-day estimate
        const hour = new Date().getUTCHours();
        let estimated: number;
        if (hour >= 5 && hour <= 8) estimated = 20;
        else if (hour >= 15 && hour <= 18) estimated = 15;
        else if (hour >= 9 && hour <= 14) estimated = 10;
        else estimated = 5;

        return Response.json({
          iata,
          securityMinutes: estimated,
          source: "estimate",
        }, { headers: cors });
      } catch {
        return Response.json({ iata, securityMinutes: null, source: "error" }, { headers: cors });
      }
    }

    // ── /airport/:iata?icao=LSZH&country=CH — Airport Intelligence ──
    // Aggregates free sources into one plain-English status: METAR aviation
    // weather (global, aviationweather.gov, keyless), FAA NAS status (US
    // ground stops/delay programs with named reasons), Waitport security.
    const airportMatch = url.pathname.match(/^\/airport\/([A-Z]{3})$/i);
    if (airportMatch) {
      const iata = airportMatch[1]!.toUpperCase();
      const icao = (url.searchParams.get("icao") ?? "").toUpperCase();
      const country = (url.searchParams.get("country") ?? "").toUpperCase();
      try {
        const [weather, faa, security] = await Promise.all([
          icao ? fetchMetar(icao) : Promise.resolve(null),
          country === "US" ? fetchFaaStatus(iata) : Promise.resolve(null),
          fetchSecurityWait(iata),
        ]);
        const synth = synthesizeAirportStatus(weather, faa);
        return Response.json({
          iata, icao,
          updatedAt: new Date().toISOString(),
          severity: synth.severity,          // "normal" | "minor" | "major"
          headline: synth.headline,
          reasons: synth.reasons,
          weather,
          faa,
          securityMinutes: security,
        }, { headers: cors });
      } catch {
        return Response.json({ iata, severity: "unknown", headline: "Status unavailable" }, { headers: cors });
      }
    }

    // ── Gate observation flywheel: ONE upserted row per flight per day ──
    // ── /gates/predict?flight=LH1751&dep=ATH (or &arr=ATH) ──
    //
    // Which gate this flight number actually tends to use, from the tracker's
    // own observations. A connection weeks out has no assigned gates, so the
    // walk between them can't be measured — but the same flight returns to the
    // same pier often enough that its history beats a flat airport average.
    // The airport's learned taxi-out for an hour of day — the grace every
    // surface gives a departure before assuming wheels-up.
    // Does APNs accept our credentials? Pushes to a deliberately invalid
    // device token: Apple authenticates the JWT and the topic BEFORE it
    // looks at the token, so "BadDeviceToken" is a pass (key, team and topic
    // are right) while InvalidProviderToken or TopicDisallowed name exactly
    // what is wrong. No device and no live flight needed.
    if (url.pathname === "/apns-selftest") {
      if (!apnsConfigured(env)) {
        return Response.json({ ok: false, reason: "APNS_TEAM_ID, APNS_KEY_ID and APNS_P8 must all be set" },
                             { headers: cors });
      }
      const out: Record<string, unknown> = {};
      for (const host of ["sandbox", "production"] as const) {
        try {
          const status = await apnsProbe(env, host);
          out[host] = status;
        } catch (e) {
          out[host] = { error: String(e) };
        }
      }
      return Response.json(out, { headers: cors });
    }

    if (url.pathname === "/taxi/prior") {
      const iata = (url.searchParams.get("iata") ?? "").toUpperCase();
      const hour = Number(url.searchParams.get("hour") ?? new Date().getUTCHours());
      if (!iata) return Response.json({ minutes: DEFAULT_TAXI_PRIOR, samples: 0 }, { headers: cors });
      return Response.json(await taxiPriorFor(env, iata, Number.isFinite(hour) ? hour : new Date().getUTCHours()),
                           { headers: cors });
    }

    if (url.pathname === "/gates/predict") {
      const flight = (url.searchParams.get("flight") ?? "").replace(/\s+/g, "").toUpperCase();
      const dep = (url.searchParams.get("dep") ?? "").toUpperCase();
      const arr = (url.searchParams.get("arr") ?? "").toUpperCase();
      const direction = dep ? "departure" : "arrival";
      const airport = dep || arr;
      if (!flight || !airport || !env.SUPABASE_SERVICE_KEY) {
        return Response.json({ gate: null, terminal: null, agreeing: 0, samples: 0, confidence: 0 },
                             { headers: cors });
      }
      const column = dep ? "departure_iata" : "arrival_iata";
      const rows = await sbSelect(env,
        `/gate_observations?flight_number=eq.${encodeURIComponent(flight)}`
        + `&${column}=eq.${encodeURIComponent(airport)}`
        + `&select=flight_date,dep_gate,dep_terminal,arr_gate,arr_terminal`
        + `&order=flight_date.desc&limit=20`);
      return Response.json(predictGate(rows as GateObservation[], direction), { headers: cors });
    }

    if (url.pathname === "/gates/observe" && req.method === "POST") {
      if (!env.SUPABASE_SERVICE_KEY) return Response.json({ ok: false }, { headers: cors });
      if (!(await requireSupabaseUser(env, req))) return new Response("unauthorized", { status: 401, headers: cors });
      try {
        const b = await req.json() as Record<string, unknown>;
        if (!b["flight_number"] || !b["departure_iata"] || !b["flight_date"]) {
          return new Response("bad request", { status: 400, headers: cors });
        }
        const res = await sbService(env, "POST",
          "/gate_observations?on_conflict=flight_number,departure_iata,flight_date", {
          flight_number: b["flight_number"],
          departure_iata: b["departure_iata"],
          arrival_iata: b["arrival_iata"] ?? "",
          flight_date: b["flight_date"],
          dep_gate: b["dep_gate"] ?? null,
          dep_terminal: b["dep_terminal"] ?? null,
          arr_gate: b["arr_gate"] ?? null,
          arr_terminal: b["arr_terminal"] ?? null,
          updated_at: new Date().toISOString(),
        });
        return Response.json({ ok: res.ok }, { headers: cors });
      } catch {
        return new Response("bad request", { status: 400, headers: cors });
      }
    }

    // ── POST /gates/store — app-fetched OSM gates into the cache ──
    // Overpass rejects Cloudflare egress IPs, so the APP fetches OSM directly
    // (native URLSession, residential IP) and stores here; reads below stay
    // cache-first so each airport is fetched from Overpass once per ~90 days.
    if (url.pathname === "/gates/store" && req.method === "POST") {
      if (!env.SUPABASE_SERVICE_KEY) return Response.json({ ok: false }, { headers: cors });
      if (!(await requireSupabaseUser(env, req))) return new Response("unauthorized", { status: 401, headers: cors });
      try {
        const b = await req.json() as { iata?: string; gates?: Array<{ ref: string; lat: number; lon: number }> };
        const iata = (b.iata ?? "").toUpperCase();
        const gates = (b.gates ?? []).filter(g => g.ref && typeof g.lat === "number" && typeof g.lon === "number");
        if (!/^[A-Z]{3}$/.test(iata) || gates.length === 0 || gates.length > 500) {
          return new Response("bad request", { status: 400, headers: cors });
        }
        const now = new Date().toISOString();
        await sbService(env, "DELETE", `/airport_gates?iata=eq.${iata}`);
        await sbService(env, "POST", "/airport_gates",
          gates.map(g => ({ iata, ref: g.ref, lat: g.lat, lon: g.lon, fetched_at: now })));
        return Response.json({ ok: true, stored: gates.length }, { headers: cors });
      } catch {
        return new Response("bad request", { status: 400, headers: cors });
      }
    }

    // ── /gates/:iata?lat=..&lon=.. — gate coordinates (OSM, cached 90 days) ──
    const gatesMatch = url.pathname.match(/^\/gates\/([A-Z]{3})$/i);
    if (gatesMatch) {
      const iata = gatesMatch[1]!.toUpperCase();
      const lat = parseFloat(url.searchParams.get("lat") ?? "");
      const lon = parseFloat(url.searchParams.get("lon") ?? "");
      try {
        if (env.SUPABASE_SERVICE_KEY) {
          const cached = await sbSelect(env, `/airport_gates?iata=eq.${iata}&select=ref,lat,lon,fetched_at`);
          const fresh = cached.length > 0 &&
            Date.now() - new Date(cached[0]!.fetched_at).getTime() < 90 * 24 * 3600 * 1000;
          if (fresh) {
            return Response.json(cached.map(g => ({ ref: g.ref, lat: g.lat, lon: g.lon })), { headers: cors });
          }
        }
        if (isNaN(lat) || isNaN(lon)) return Response.json([], { headers: cors });

        // Overpass rejects requests without a User-Agent.
        const q = `[out:json][timeout:15];node["aeroway"="gate"](around:3500,${lat},${lon});out;`;
        const res = await fetch("https://overpass-api.de/api/interpreter", {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded", "user-agent": "ArcFlightTracker/1.0 (personal project)" },
          body: `data=${encodeURIComponent(q)}`,
        });
        if (!res.ok) return Response.json([], { headers: cors });
        const data = await res.json() as { elements?: Array<{ lat: number; lon: number; tags?: Record<string, string> }> };
        const gates = (data.elements ?? [])
          .filter(e => e.tags?.["ref"])
          .map(e => ({ ref: e.tags!["ref"]!, lat: e.lat, lon: e.lon }));

        if (env.SUPABASE_SERVICE_KEY && gates.length > 0) {
          const now = new Date().toISOString();
          // Refresh the cache wholesale for this airport.
          await sbService(env, "DELETE", `/airport_gates?iata=eq.${iata}`);
          for (const chunk of [gates]) {
            await sbService(env, "POST", "/airport_gates", chunk.map(g => ({
              iata, ref: g.ref, lat: g.lat, lon: g.lon, fetched_at: now,
            })));
          }
        }
        return Response.json(gates, { headers: cors });
      } catch {
        return Response.json([], { headers: cors });
      }
    }

    // ── Live Activity push registration ──
    if (url.pathname === "/la/register" && req.method === "POST") {
      if (!env.SUPABASE_SERVICE_KEY) return Response.json({ ok: false, reason: "unconfigured" }, { headers: cors });
      try {
        const body = await req.json() as {
          token?: string; type?: string; env?: string; user_id?: string;
          replaces?: string;
          flight?: Record<string, unknown>;
          local?: { boarding_lead_minutes?: number; companions?: unknown[] };
        };
        if (!body.token || (body.type !== "update" && body.type !== "start")) {
          return new Response("bad request", { status: 400, headers: cors });
        }
        // The token this device used to have. iOS mints a NEW push-to-start
        // token on every rotation, and the old one is dead the moment the new
        // one exists — but nothing said so, and 187 rows had piled up for one
        // tester. Only the device knows which row is its own predecessor: the
        // server sees tokens, not devices, and could not tell a rotation from
        // a second phone. So the device names it, and the row goes with it.
        if (typeof body.replaces === "string" && /^[0-9a-f]{32,200}$/i.test(body.replaces)
            && body.replaces !== body.token) {
          await sbService(env, "DELETE",
            `/live_activity_tokens?token=eq.${encodeURIComponent(body.replaces)}`);
        }
        const f = body.flight ?? {};
        const row: Record<string, unknown> = {
          token: body.token,
          token_type: body.type,
          // Owner of this device's token. pushStarts refuses to start
          // activities for tokens without one — the owner is what stops
          // one user's flight from appearing on another user's lock screen.
          user_id: typeof body.user_id === "string"
            && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(body.user_id)
            ? body.user_id : null,
          apns_env: body.env === "production" ? "production" : "sandbox",
          flight_number: f["flight_number"] ?? null,
          departure_iata: f["departure_iata"] ?? null,
          arrival_iata: f["arrival_iata"] ?? null,
          departure_city: f["departure_city"] ?? null,
          arrival_city: f["arrival_city"] ?? null,
          airline: f["airline"] ?? null,
          aircraft_type: f["aircraft_type"] ?? null,
          seat: f["seat"] ?? null,
          scheduled_departure: f["scheduled_departure"] ?? null,
          scheduled_arrival: f["scheduled_arrival"] ?? null,
          updated_at: new Date().toISOString(),
        };
        // Facts only the device can know — the airline's boarding lead and the
        // friends on this flight — parked where every push can echo them back.
        // A Live Activity push REPLACES the content state wholesale, so
        // whatever the Worker cannot restate is erased from the lock screen
        // until the app next runs; these two were being erased every tick.
        if (body.local) {
          const lead = Number(body.local.boarding_lead_minutes);
          const local: Record<string, unknown> = {};
          if (Number.isFinite(lead) && lead >= 0 && lead <= 240) local.boarding_lead_minutes = Math.round(lead);
          if (Array.isArray(body.local.companions)) local.companions = body.local.companions.slice(0, 8);
          // Merge rather than overwrite: last_state also carries the cached
          // leg, the insight and the taxi evidence between ticks.
          const existing = await sbSelect(env,
            `/live_activity_tokens?select=last_state&token=eq.${encodeURIComponent(body.token)}`);
          row.last_state = { ...((existing[0] as any)?.last_state ?? {}), local };
        }
        const res = await sbService(env, "POST", "/live_activity_tokens?on_conflict=token", row);
        return Response.json({ ok: res.ok }, { headers: cors });
      } catch {
        return new Response("bad request", { status: 400, headers: cors });
      }
    }

    // ── Ordinary push registration ──
    // Separate from /la/register: that token belongs to ONE Live Activity and
    // dies with it. This one belongs to the device, and is what lets Arc say
    // anything at all about a flight that has no card running — which, more
    // than three hours before departure, is every flight.
    if (url.pathname === "/push/register" && req.method === "POST") {
      if (!env.SUPABASE_SERVICE_KEY) return Response.json({ ok: false, reason: "unconfigured" }, { headers: cors });
      try {
        const body = await req.json() as { token?: string; env?: string; user_id?: string };
        const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
        // No owner, no registration. The watcher looks up flights BY owner, so
        // an ownerless token could only ever be sent someone else's news.
        if (!body.token || !/^[0-9a-f]{64,200}$/i.test(body.token)
            || typeof body.user_id !== "string" || !uuid.test(body.user_id)) {
          return new Response("bad request", { status: 400, headers: cors });
        }
        const res = await sbService(env, "POST", "/device_tokens?on_conflict=token", {
          token: body.token,
          user_id: body.user_id,
          apns_env: body.env === "sandbox" ? "sandbox" : "production",
          updated_at: new Date().toISOString(),
        });
        return Response.json({ ok: res.ok }, { headers: cors });
      } catch {
        return new Response("bad request", { status: 400, headers: cors });
      }
    }

    if (url.pathname === "/push/unregister" && req.method === "POST") {
      if (!env.SUPABASE_SERVICE_KEY) return Response.json({ ok: false }, { headers: cors });
      try {
        const body = await req.json() as { token?: string };
        if (!body.token) return new Response("bad request", { status: 400, headers: cors });
        await sbService(env, "DELETE", `/device_tokens?token=eq.${encodeURIComponent(body.token)}`);
        return Response.json({ ok: true }, { headers: cors });
      } catch {
        return new Response("bad request", { status: 400, headers: cors });
      }
    }

    // ── Refresh one friend's flight, now, because someone is looking at it ──
    //
    // The viewer has a working connection — that is WHY they are looking — but
    // until this endpoint the friend path made no network call of any kind. It
    // read the mirrored row and nothing else, so a friend's flight was only
    // ever as fresh as the last cron tick or the traveller's own phone. The
    // one device that is definitely awake and definitely interested could not
    // ask.
    //
    // It cannot write the row itself: RLS lets a friend SELECT but only the
    // owner UPDATE, which is right — you should not be able to edit someone
    // else's flight. So it asks the Worker, which holds the service key and
    // therefore has to re-check the friendship the policy would have enforced.
    if (url.pathname === "/shared/refresh" && req.method === "POST") {
      if (!env.SUPABASE_SERVICE_KEY) return Response.json({ ok: false, reason: "unconfigured" }, { headers: cors });
      const viewer = await supabaseUserId(env, req);
      if (!viewer) return new Response("unauthorized", { status: 401, headers: cors });
      try {
        const body = await req.json() as { id?: string };
        const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
        if (!body.id || !uuid.test(body.id)) {
          return new Response("bad request", { status: 400, headers: cors });
        }
        const rows = await sbSelect(env, `/shared_flights?id=eq.${body.id}&select=*`) as unknown as Record<string, any>[];
        if (!rows.length) return new Response("not found", { status: 404, headers: cors });
        const row = rows[0];
        // Same answer the RLS policy would give, restated because the service
        // key bypasses it.
        if (!await areFriends(env, viewer, String(row.user_id))) {
          return new Response("not found", { status: 404, headers: cors });
        }
        const now = Date.now();
        // Somebody already asked in the last minute — for this row, or because
        // several friends opened it at once. Their answer is this answer.
        const recent = row.checked_at && now - Date.parse(row.checked_at) < 60_000;
        if (!recent && ((row.mode as string) ?? "air") === "air") {
          await refreshOneSharedRow(env, row, now);
        }
        const after = await sbSelect(env, `/shared_flights?id=eq.${body.id}&select=*`);
        return Response.json({ ok: true, refreshed: !recent, flight: after[0] ?? row }, { headers: cors });
      } catch {
        return new Response("bad request", { status: 400, headers: cors });
      }
    }

    if (url.pathname === "/la/unregister" && req.method === "POST") {
      if (!env.SUPABASE_SERVICE_KEY) return Response.json({ ok: false }, { headers: cors });
      try {
        const body = await req.json() as { token?: string };
        if (!body.token) return new Response("bad request", { status: 400, headers: cors });
        await sbService(env, "DELETE", `/live_activity_tokens?token=eq.${encodeURIComponent(body.token)}`);
        return Response.json({ ok: true }, { headers: cors });
      } catch {
        return new Response("bad request", { status: 400, headers: cors });
      }
    }

    return new Response("not found", { status: 404 });
  },

  // ── Every-minute cron: push Live Activity updates server-side ──
  // This is what makes the lock screen move with the app fully closed:
  // progress is recomputed each minute (free), provider data refreshed at
  // most every 5 minutes per flight (metered), and phase transitions
  // (scheduled→active→landed) are derived from the clock in between.
  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    // Only Supabase is required to run at all. APNs gates the PUSH loops
    // inside — it used to gate everything, which also silenced the
    // shared_flights refresher, so friends' rows froze whenever the traveler
    // closed the app, for a key the refresher never needed.
    if (!env.SUPABASE_SERVICE_KEY) return;
    ctx.waitUntil(runLiveActivityCron(env));
  },
};

// ── Airport Intelligence internals ──

interface AirportWeather {
  category: string | null;    // VFR / MVFR / IFR / LIFR
  tempC: number | null;
  windKt: number | null;
  gustKt: number | null;
  visibility: string | null;
  wx: string | null;          // raw weather phenomena, e.g. "TSRA", "-SN"
  raw: string | null;
}

/// FIDS arrivals cached in the same table as flight lookups. Five minutes: a
/// stand can change late, but not every few seconds, and one call serves every
/// flight arriving in that hour.
// ── Isolate-local row cache over flight_cache ──
// Every Supabase read is a ~100-200 ms edge→DB round trip, and a warm search
// strings several in sequence. Holding rows briefly per isolate skips the
// re-DOWNLOAD only — every consumer still judges freshness from the row's
// own fetched_at, so nothing is served past its real TTL. Writes update the
// memo in place; other isolates' writes surface within 60 s, which for
// schedule data is noise.
const rowMemo = new Map<string, { row: Record<string, any> | null; at: number }>();
const ROW_MEMO_MS = 60_000;

function rowMemoSet(key: string, row: Record<string, any> | null): void {
  if (rowMemo.size > 500) rowMemo.clear();
  rowMemo.set(key, { row, at: Date.now() });
}

/// flight_cache rows for the given keys (memo first, one bulk read for the
/// rest). Absent rows come back as null — also memoized, so a dead candidate
/// doesn't cost a read per search.
async function cacheRows(env: Env, keys: string[]): Promise<Map<string, Record<string, any> | null>> {
  const out = new Map<string, Record<string, any> | null>();
  const missing: string[] = [];
  for (const k of keys) {
    const hit = rowMemo.get(k);
    if (hit && Date.now() - hit.at < ROW_MEMO_MS) out.set(k, hit.row);
    else missing.push(k);
  }
  if (missing.length) {
    const rows = await sbSelect(env,
      `/flight_cache?key=in.(${missing.map(k => encodeURIComponent(`"${k.replace(/"/g, '\\"')}"`)).join(",")})&select=*`);
    const byKey = new Map(rows.map(r => [String(r["key"]), r]));
    for (const k of missing) {
      const row = byKey.get(k) ?? null;
      rowMemoSet(k, row);
      out.set(k, row);
    }
  }
  return out;
}

async function cachedFids(env: Env, key: string, ttlMs = 5 * 60_000): Promise<Record<string, any>[] | null> {
  if (!env.SUPABASE_SERVICE_KEY) return null;
  const row = (await cacheRows(env, [key])).get(key);
  if (!row) return null;
  if (Date.now() - Date.parse(String(row.fetched_at)) > ttlMs) return null;
  return row.payload as Record<string, any>[];
}

/// Which flight numbers fly a route, discovered from the departure board.
///
/// Schedules repeat weekly, so the board of the *nearest same weekday within
/// FIDS reach* names the flights that operate the route on the target date —
/// including codeshare marketing numbers, which FIDS lists as their own
/// entries. The caller verifies every number against the target date, so a
/// seasonal change surfaces as a dropped candidate, not a wrong result.
/// Costs two budget-guarded FIDS calls per airport-day, cached for a day and
/// shared with everything else that reads the same board.
/// One row of a departure board: with `withCodeshared=true` a codeshare
/// marketing number and its operating flight appear as SEPARATE rows sharing
/// the same destination and scheduled time — which is how a marketing number
/// nobody indexes (A31653) maps to the flight that actually operates it.
interface BoardEntry { number: string; dest: string; time: string }

async function adbRouteDiscovery(
  env: Env, depIATA: string, arrIATA: string, targetDate: string
): Promise<{ routeNumbers: string[]; board: BoardEntry[] }> {
  const empty = { routeNumbers: [], board: [] };
  if (!env.RAPIDAPI_KEY) return empty;

  // Nearest date with the target's weekday that FIDS can still serve.
  const today = new Date(); today.setUTCHours(0, 0, 0, 0);
  const target = new Date(`${targetDate}T00:00:00Z`);
  if (isNaN(target.getTime())) return empty;
  let discovery = target;
  const daysOut = Math.round((target.getTime() - today.getTime()) / 86_400_000);
  if (daysOut > 6 || daysOut < -6) {
    const shift = ((target.getUTCDay() - today.getUTCDay()) + 7) % 7;
    discovery = new Date(today.getTime() + shift * 86_400_000);
  }
  const day = discovery.toISOString().slice(0, 10);

  const numbers: string[] = [];
  const board: BoardEntry[] = [];
  let paceNeeded = false;
  const windows = [[`${day}T00:00`, `${day}T11:59`], [`${day}T12:00`, `${day}T23:59`]];
  const keys = windows.map(([from]) => `fidsdep|${depIATA}|${from.slice(0, 13)}`);
  // Both windows in one (memoized) read; the budget row is read lazily,
  // only when a board actually needs fetching — a warm search pays zero
  // extra round trips here.
  const rows = await cacheRows(env, keys);
  let budget: Record<string, any> | null = null;
  for (let i = 0; i < windows.length; i++) {
    const [from, to] = windows[i];
    const key = keys[i];
    const row = rows.get(key);
    let departures = row && Date.now() - Date.parse(String(row.fetched_at)) < 24 * 3600_000
      ? (row.payload as Record<string, any>[])
      : null;
    if (!departures) {
      budget ??= await budgetRow(env);
      const remaining = budget["adb_remaining"] as number | null | undefined;
      if (typeof remaining === "number" && remaining <= 0) continue;
      // Same per-second provider limit as verification: don't fire the
      // second window on the heels of the first.
      if (paceNeeded) await new Promise((r) => setTimeout(r, 650));
      paceNeeded = true;
      const path = `/flights/airports/iata/${depIATA}/${encodeURIComponent(from)}/${encodeURIComponent(to)}`
        + `?withLeg=false&direction=Departure&withCancelled=false&withCodeshared=true`
        + `&withCargo=false&withPrivate=false&withLocation=false`;
      let res = await adbFetch(path, env);
      if (!res.ok) {
        // One delayed retry: a transiently failed window silently shrank
        // the candidate list — and the result set — on that search only,
        // so identical searches returned different flights.
        await new Promise((r) => setTimeout(r, 500));
        res = await adbFetch(path, env);
      }
      await budgetBump(env, "adb_interactive", (budget["adb_interactive"] as number) ?? 0,
                       res.headers.get("x-ratelimit-requests-remaining"));
      if (!res.ok) continue;
      const rows = await fidsRows(res, "departures");
      if (rows === null) continue;
      departures = rows;
      await storeFids(env, key, departures);
    }
    for (const d of departures) {
      const dest = String(d?.movement?.airport?.iata ?? "").toUpperCase();
      const num = String(d?.number ?? "").replace(/\s+/g, "").toUpperCase();
      if (!num || !dest) continue;
      const time = String(d?.movement?.scheduledTime?.utc ?? d?.movement?.scheduledTime?.local ?? "");
      board.push({ number: num, dest, time });
      // Codeshare alias rows stay on the board (they resolve typed marketing
      // numbers to their operator) but are NOT verification candidates: the
      // by-number endpoint doesn't index them, so each one bought a paced
      // provider call for a guaranteed empty answer.
      const isAlias = String(d?.codeshareStatus ?? "").toLowerCase() === "iscodeshared";
      if (dest === arrIATA.toUpperCase() && !isAlias && !numbers.includes(num)) numbers.push(num);
    }
  }

  // A small airport may have no departure board at all. Syros publishes
  // nothing, so "Syros to Athens" discovered zero candidates and answered
  // "no flights" — while GQ21 JSY→ATH sat in the provider's by-number index
  // the whole time, findable if only something had named it. Athens, being a
  // hub, has a perfectly good ARRIVALS board that names it.
  //
  // Gated on the departure board being genuinely EMPTY rather than merely
  // having nothing for this destination: "no data for this airport" is worth
  // a second look, "data exists and nothing flies there" is already the answer
  // and must not buy two more provider calls on every fruitless search.
  if (board.length === 0) {
    for (const num of await arrivalBoardNumbers(env, depIATA, arrIATA, day)) {
      if (!numbers.includes(num)) numbers.push(num);
    }
  }
  return { routeNumbers: numbers, board };
}

/// Flight numbers arriving at `arrIATA` from `depIATA`, read off the
/// DESTINATION's arrivals board — the way round that works when the origin is
/// too small to publish departures. Same windows, cache and budget guard as
/// the departure board; the caller verifies every number as usual.
async function arrivalBoardNumbers(
  env: Env, depIATA: string, arrIATA: string, day: string
): Promise<string[]> {
  const numbers: string[] = [];
  const windows = [[`${day}T00:00`, `${day}T11:59`], [`${day}T12:00`, `${day}T23:59`]];
  const keys = windows.map(([from]) => `fidsarr|${arrIATA}|${from.slice(0, 13)}`);
  const rows = await cacheRows(env, keys);
  let budget: Record<string, any> | null = null;
  let paceNeeded = false;

  for (let i = 0; i < windows.length; i++) {
    const [from, to] = windows[i];
    const key = keys[i];
    const row = rows.get(key);
    let arrivals = row && Date.now() - Date.parse(String(row.fetched_at)) < 24 * 3600_000
      ? (row.payload as Record<string, any>[])
      : null;
    if (!arrivals) {
      budget ??= await budgetRow(env);
      const remaining = budget["adb_remaining"] as number | null | undefined;
      if (typeof remaining === "number" && remaining <= 0) continue;
      if (paceNeeded) await new Promise((r) => setTimeout(r, 650));
      paceNeeded = true;
      const path = `/flights/airports/iata/${arrIATA}/${encodeURIComponent(from)}/${encodeURIComponent(to)}`
        + `?withLeg=false&direction=Arrival&withCancelled=false&withCodeshared=true`
        + `&withCargo=false&withPrivate=false&withLocation=false`;
      let res = await adbFetch(path, env);
      if (!res.ok) {
        await new Promise((r) => setTimeout(r, 500));
        res = await adbFetch(path, env);
      }
      await budgetBump(env, "adb_interactive", (budget["adb_interactive"] as number) ?? 0,
                       res.headers.get("x-ratelimit-requests-remaining"));
      if (!res.ok) continue;
      const rows = await fidsRows(res, "arrivals");
      if (rows === null) continue;
      arrivals = rows;
      await storeFids(env, key, arrivals);
    }
    for (const a of arrivals) {
      // On an arrivals board the movement airport is where the flight CAME
      // FROM — the mirror of the departures case.
      const origin = String(a?.movement?.airport?.iata ?? "").toUpperCase();
      const num = String(a?.number ?? "").replace(/\s+/g, "").toUpperCase();
      const isAlias = String(a?.codeshareStatus ?? "").toLowerCase() === "iscodeshared";
      if (!num || origin !== depIATA.toUpperCase() || isAlias) continue;
      if (!numbers.includes(num)) numbers.push(num);
    }
  }
  return numbers;
}

/// Movements off a FIDS response, tolerating the empty body this provider
/// sends for "nothing here".
///
/// Same trap as the by-number endpoint: an airport too small to publish a
/// board answers 2xx with zero bytes, `res.json()` throws on that, and here the
/// throw escaped all the way out of /search-flights as a 500. So "Syros to
/// Athens" didn't fail for want of coverage — it crashed the whole search,
/// and the app's `try?` quietly rendered that as "no flights found".
///
/// null means the body was present but unreadable — a provider fault, not an
/// answer, and must not be cached as an empty board for a day.
async function fidsRows(res: Response, key: "departures" | "arrivals"): Promise<Record<string, any>[] | null> {
  const body = (await res.text()).trim();
  if (!body) return [];
  try {
    const raw = JSON.parse(body) as Record<string, any>;
    const rows = raw?.[key];
    return Array.isArray(rows) ? rows as Record<string, any>[] : [];
  } catch {
    console.error("adb fids bad json:", key, body.slice(0, 200));
    return null;
  }
}

async function storeFids(env: Env, key: string, arrivals: Record<string, any>[]): Promise<void> {
  if (!env.SUPABASE_SERVICE_KEY) return;
  const fresh = { key, payload: arrivals, provider: "adb-fids", fetched_at: new Date().toISOString() };
  rowMemoSet(key, fresh);
  await sbService(env, "POST", "/flight_cache?on_conflict=key", fresh);
}

/// SIGMET hazard codes to something a passenger can read. TS/CONVECTIVE are
/// thunderstorms, MTW is mountain wave, VA volcanic ash, TC tropical cyclone.
function hazardKind(raw: string): string {
  switch (raw.toUpperCase()) {
    case "TS": case "CONVECTIVE": return "thunderstorms";
    case "TURB": return "turbulence";
    case "ICE": case "ICING": return "icing";
    case "VA": return "volcanic ash";
    case "TC": return "tropical cyclone";
    case "MTW": return "mountain wave";
    case "IFR": case "MT_OBSC": return "low visibility";
    default: return raw.toLowerCase() || "hazard";
  }
}

/// Qualifiers come from the SIGMET text (SEV severe, FRQ frequent, EMBD
/// embedded); the US feed uses a numeric severity instead. Ash and cyclones
/// are always worth the stronger styling.
function isSevereHazard(r: Record<string, any>): boolean {
  const q = String(r.qualifier ?? "").toUpperCase();
  if (q.includes("SEV") || q.includes("FRQ")) return true;
  const kind = String(r.hazard ?? "").toUpperCase();
  if (kind === "VA" || kind === "TC") return true;
  return typeof r.severity === "number" && r.severity >= 4;
}

async function fetchMetar(icao: string): Promise<AirportWeather | null> {
  try {
    const res = await fetch(`https://aviationweather.gov/api/data/metar?ids=${icao}&format=json`);
    const m = (await wxRows(res))[0];
    if (!m) return null;
    return {
      category: m.fltCat ?? null,
      tempC: typeof m.temp === "number" ? m.temp : null,
      windKt: typeof m.wspd === "number" ? m.wspd : null,
      gustKt: typeof m.wgst === "number" ? m.wgst : null,
      visibility: m.visib != null ? String(m.visib) : null,
      wx: m.wxString ?? null,
      raw: m.rawOb ?? null,
    };
  } catch { return null; }
}

interface FaaDelay {
  type: string;       // "Ground Stop" | "Ground Delay" | "Closure" | "Arrival/Departure Delay"
  reason: string;
  avgMinutes: number | null;
}

/// FAA NAS status is XML; the structure is flat enough to extract per-airport
/// blocks with regexes rather than shipping an XML parser to the edge.
async function fetchFaaStatus(iata: string): Promise<FaaDelay | null> {
  try {
    const res = await fetch("https://nasstatus.faa.gov/api/airport-status-information");
    if (!res.ok) return null;
    const xml = await res.text();

    const block = (tag: string) => new RegExp(`<${tag}>(?:(?!</${tag}>).)*?<ARPT>${iata}</ARPT>(?:(?!</${tag}>).)*?</${tag}>`, "s").exec(xml)?.[0] ?? null;
    const field = (b: string, tag: string) => new RegExp(`<${tag}>(.*?)</${tag}>`, "s").exec(b)?.[1]?.trim() ?? null;
    const minutes = (s: string | null): number | null => {
      if (!s) return null;
      const h = /(\d+)\s*hour/.exec(s); const m = /(\d+)\s*minute/.exec(s);
      const total = (h ? parseInt(h[1]!) * 60 : 0) + (m ? parseInt(m[1]!) : 0);
      return total > 0 ? total : null;
    };

    const gs = block("Ground_Stop");
    if (gs) return { type: "Ground Stop", reason: field(gs, "Reason") ?? "ATC ground stop", avgMinutes: null };
    const gd = block("Ground_Delay");
    if (gd) return { type: "Ground Delay", reason: field(gd, "Reason") ?? "traffic management", avgMinutes: minutes(field(gd, "Avg")) };
    const cl = block("Airport_Closure");
    if (cl) return { type: "Closure", reason: field(cl, "Reason") ?? "airport closed", avgMinutes: null };
    const ad = block("Delay");   // Arrival/Departure delay entries
    if (ad && ad.includes(`<ARPT>${iata}</ARPT>`)) {
      return { type: "Arrival/Departure Delay", reason: field(ad, "Reason") ?? "delays", avgMinutes: minutes(field(ad, "Max")) };
    }
    return null;
  } catch { return null; }
}

async function fetchSecurityWait(iata: string): Promise<number | null> {
  try {
    const res = await fetch(`https://waitport.com/api/v1/all?airport=eq.${iata}&order=id.desc&limit=1`);
    if (!res.ok) return null;
    const data = await res.json() as Array<{ queue: number }>;
    return data?.[0]?.queue ?? null;
  } catch { return null; }
}

/// Rule-based plain-English synthesis — deliberately deterministic (no LLM):
/// the vocabulary of airport disruption is small and the stakes of a wrong
/// dramatic headline are high.
function synthesizeAirportStatus(w: AirportWeather | null, faa: FaaDelay | null):
  { severity: "normal" | "minor" | "major"; headline: string; reasons: string[] } {
  const reasons: string[] = [];
  let severity: "normal" | "minor" | "major" = "normal";
  const bump = (s: "minor" | "major") => {
    if (s === "major" || severity === "major") severity = "major";
    else severity = "minor";
  };

  if (faa) {
    if (faa.type === "Ground Stop") { bump("major"); reasons.push(`FAA ground stop — ${faa.reason}`); }
    else if (faa.type === "Closure") { bump("major"); reasons.push(`Airport closure — ${faa.reason}`); }
    else if (faa.type === "Ground Delay") {
      bump((faa.avgMinutes ?? 0) >= 45 ? "major" : "minor");
      reasons.push(`FAA ground delay program — ${faa.reason}${faa.avgMinutes ? ` (avg ${faa.avgMinutes} min)` : ""}`);
    } else { bump("minor"); reasons.push(`${faa.type} — ${faa.reason}`); }
  }

  if (w) {
    const wx = (w.wx ?? "").toUpperCase();
    if (wx.includes("TS")) { bump("major"); reasons.push("Thunderstorms at the airport"); }
    if (wx.includes("SN") || wx.includes("FZ")) { bump("major"); reasons.push("Snow or freezing conditions"); }
    if (w.category === "LIFR") { bump("major"); reasons.push("Very low visibility operations"); }
    else if (w.category === "IFR") { bump("minor"); reasons.push("Low visibility operations"); }
    if ((w.gustKt ?? 0) >= 30 || (w.windKt ?? 0) >= 25) { bump("minor"); reasons.push(`Strong winds${w.gustKt ? ` (gusts ${w.gustKt} kt)` : ""}`); }
  }

  const headline =
    severity === "normal" ? "Operating normally"
    : severity === "minor" ? "Minor disruptions possible"
    : "Significant disruptions";
  return { severity, headline, reasons };
}

// ── API economy: shared response cache + monthly provider budget ──
//
// One provider answer serves every consumer (each device, the LA cron,
// share pages) for a phase-aware TTL; a monthly budget with an interactive
// reserve caps total burn. Stale cache beats no data; the caller's own
// fallbacks (AirLabs, clock healing) cover the rest.

// One pool rather than two fixed caps. The old split reserved 250 calls for
// the cron — which cannot run at all until APNs is configured — while searches
// hit a wall at 150 and the app reported "flight not found". Now the cron may
// take at most a share of the pool, so an interactive search always has room,
// and unused cron budget is available instead of stranded.
//
// Sized for the AeroDataBox PRO plan: 6,000 units/month, and the endpoints we
// call cost several units each, so the ceiling is in calls and deliberately
// conservative. `adb_remaining` records what RapidAPI itself reports so /health
// shows the real number instead of only our guess at it.
const ADB_MONTHLY_CALLS = 900;
const ADB_CRON_SHARE = 0.6;
// Once RapidAPI has told us what's left we use that instead of guessing, and
// only stop the cron early so a search always has quota behind it. The
// reserve is a SHARE of the observed plan (spent + remaining), not a fixed
// count — a fixed 2000 permanently silenced the cron on any smaller plan.
const ADB_CRON_RESERVE_SHARE = 0.25;
const AIRLABS_BUDGET = 800;           // per month (plan is 1k)

function monthKey(): string {
  return new Date().toISOString().slice(0, 7);
}

// A cold search reads the budget ~10× in two seconds, and every read is a
// Cloudflare subrequest counted against the 50-per-invocation cap the search
// overflowed. The budget is monthly — a 10 s-stale read changes nothing.
let budgetMemo: { row: Record<string, any>; at: number } | null = null;

async function budgetRow(env: Env): Promise<Record<string, any>> {
  if (budgetMemo && Date.now() - budgetMemo.at < 10_000) return budgetMemo.row;
  const m = monthKey();
  const rows = await sbSelect(env, `/api_budget?month=eq.${m}&select=*`);
  const row = rows.length
    ? rows[0]
    : { month: m, adb_cron: 0, adb_interactive: 0, airlabs_calls: 0 };
  if (!rows.length) await sbService(env, "POST", "/api_budget?on_conflict=month", { month: m });
  // Memoize only a REAL row. sbSelect answers [] for errors too, and pinning
  // the fabricated all-zeros row for 10 s makes the guard fail open exactly
  // when Supabase is having a bad moment.
  if (rows.length) budgetMemo = { row, at: Date.now() };
  return row;
}

async function budgetBump(env: Env, field: string, current: number,
                          remaining?: string | null): Promise<void> {
  // RapidAPI reports what's actually left on every response. Recording it means
  // /health shows the provider's own number, not just our count of attempts —
  // the two disagreeing is exactly how a plan upgrade went unnoticed.
  const left = remaining == null ? NaN : Number(remaining);
  if (budgetMemo) {
    budgetMemo.row[field] = ((budgetMemo.row[field] as number) ?? current) + 1;
    if (Number.isFinite(left)) budgetMemo.row["adb_remaining"] = left;
  }
  // SQL-side increment (migration 014): a fanned-out search fires several of
  // these concurrently, and read-modify-write PATCHes counted them as one.
  const res = await sbService(env, "POST", "/rpc/bump_api_budget", {
    p_month: monthKey(), p_field: field,
    p_remaining: Number.isFinite(left) ? left : null,
  });
  if (!res.ok && res.status !== 503) {
    // RPC missing (migration not applied yet): fall back to the old PATCH so
    // accounting degrades to approximate instead of stopping.
    const patch: Record<string, unknown> = { [field]: current + 1 };
    if (Number.isFinite(left)) patch["adb_remaining"] = left;
    await sbService(env, "PATCH", `/api_budget?month=eq.${monthKey()}`, patch);
  }
}

/// Phase-aware freshness: how long a cached answer stays good, judged from
/// the flight's own times. Tight only in the windows where data actually
interface CachedFetch {
  legs: Record<string, unknown>[] | null;
  cache: "hit" | "stale" | "miss" | "none";
}

/// Cache-first, budget-guarded provider fetch. `kind` picks the ADB endpoint
/// (flight number vs tail registration); results are stored ALREADY MAPPED
/// so every consumer sees one provider-agnostic shape.
async function fetchLegsCached(
  env: Env, kind: "flight" | "reg", ident: string, date: string,
  source: "cron" | "interactive",
  // Cache row already fetched by the caller (bulk read): the row itself,
  // or null for "known absent". undefined = not preloaded, read it here.
  pre?: Record<string, any> | null
): Promise<CachedFetch> {
  const key = `${kind}|${ident.toUpperCase()}|${date}`;
  const cached = pre !== undefined
    ? (pre ?? undefined)
    : ((await cacheRows(env, [key])).get(key) ?? undefined);
  const cachedLegs = cached ? (cached.payload as Record<string, unknown>[]) : null;
  if (cachedRowFresh(cached)) {
    return { legs: cachedLegs!, cache: "hit" };
  }

  // Needs a refresh — is there budget left?
  if (!env.RAPIDAPI_KEY) return { legs: cachedLegs, cache: cachedLegs ? "stale" : "none" };
  const budget = await budgetRow(env);
  const field = source === "cron" ? "adb_cron" : "adb_interactive";
  const cronUsed = (budget["adb_cron"] as number) ?? 0;
  const totalUsed = cronUsed + ((budget["adb_interactive"] as number) ?? 0);
  const remaining = budget["adb_remaining"] as number | null | undefined;
  // Prefer what the provider reports; our own count can't know the plan, which
  // is how an upgrade left searches blocked against a ceiling that no longer
  // existed. The local cap is only the bootstrap, before the first response.
  const planQuota = typeof remaining === "number" ? totalUsed + remaining : ADB_MONTHLY_CALLS;
  const cronReserve = Math.max(50, Math.floor(planQuota * ADB_CRON_RESERVE_SHARE));
  const blocked = typeof remaining === "number"
    ? remaining <= (source === "cron" ? cronReserve : 0)
    : source === "cron"
      ? cronUsed >= ADB_MONTHLY_CALLS * ADB_CRON_SHARE
      : totalUsed >= ADB_MONTHLY_CALLS;
  if (blocked) {
    return { legs: cachedLegs, cache: cachedLegs ? "stale" : "none" };
  }

  try {
    const path = kind === "flight"
      ? `/flights/number/${encodeURIComponent(ident)}/${date}?withAircraftImage=false&withLocation=true`
      : `/flights/reg/${encodeURIComponent(ident)}/${date}?withLocation=true`;
    const res = await adbFetch(path, env);
    // Count attempts, not just successes — a 429 burns real quota state.
    await budgetBump(env, field, (budget[field] as number) ?? 0,
                     res.headers.get("x-ratelimit-requests-remaining"));
    if (res.ok || res.status === 404) {
      // "No such flight that day" comes back as a 2xx with an EMPTY BODY, not
      // a 404. res.json() throws on that, and the throw used to escape to the
      // catch below — so the negative answer was never cached. Every later
      // search re-asked the same dead number, which tripped the provider's
      // per-second limit and took genuinely-real candidates down with it:
      // identical searches returned different flights. Read the body as text
      // and treat empty as "no legs", which IS a definitive answer worth
      // caching. Malformed-but-present JSON is a provider fault, not an
      // answer, so it still falls through uncached.
      const body = res.ok ? (await res.text()).trim() : "";
      let raw: unknown = [];
      if (body) {
        try {
          raw = JSON.parse(body);
        } catch {
          console.error("adb bad json:", key, body.slice(0, 200));
          return { legs: cachedLegs, cache: cachedLegs ? "stale" : "none" };
        }
      }
      const legs = (Array.isArray(raw) ? raw : []).map((l) => mapLeg(l as Record<string, any>));
      // An empty answer does not overwrite legs we already have. Measured:
      // AeroDataBox served LH1753 on 2026-09-18 in full, then answered 204 for
      // the very same number and date minutes later — so "nothing" from this
      // provider means "nothing right now", not "no such flight". Overwriting
      // on that would blank a real, already-known flight out of the app.
      //
      // Bounded at a day, though: a flight really can leave the schedule, and
      // past that the silence has to be believed or a dropped route would haunt
      // the results forever.
      const heldFor = Date.now() - Date.parse(String(cached?.fetched_at ?? ""));
      if (legs.length === 0 && cachedLegs && cachedLegs.length > 0
          && isFinite(heldFor) && heldFor < 24 * 3600_000) {
        return { legs: cachedLegs, cache: "stale" };
      }
      // Cache empty answers too: "doesn't fly that date" is a definitive
      // answer (10-min TTL). Without it every search re-fetched the same
      // dead candidates — burning quota and, when the re-fetch got
      // rate-limited, changing the result set from search to search.
      // Transient failures (429/5xx) fall through uncached below.
      const fresh = { key, payload: legs, provider: "adb", fetched_at: new Date().toISOString() };
      rowMemoSet(key, fresh);
      await sbService(env, "POST", "/flight_cache?on_conflict=key", fresh);
      return { legs, cache: "miss" };
    }
    console.error("adb fetch failed:", res.status, key);
  } catch (e) { console.error("adb fetch threw:", key, String(e)); }
  return { legs: cachedLegs, cache: cachedLegs ? "stale" : "none" };
}

/// Store an AirLabs-served answer in the same cache (dedupes its 1k/month
/// quota too) — call after a successful AirLabs fallback.
async function cacheAirlabsResult(env: Env, ident: string, date: string,
                                  legs: Record<string, unknown>[]): Promise<void> {
  const key = `flight|${ident.toUpperCase()}|${date}`;
  const fresh = { key, payload: legs, provider: "airlabs", fetched_at: new Date().toISOString() };
  rowMemoSet(key, fresh);
  await sbService(env, "POST", "/flight_cache?on_conflict=key", fresh);
}

// ── Live Activity cron internals ──

/// The service key writes for these endpoints, so the Worker itself must
/// check WHO is asking: any signed-in user may contribute, nobody anonymous
/// may wipe an airport's gate map or poison the prediction history.
async function requireSupabaseUser(env: Env, req: Request): Promise<boolean> {
  return (await supabaseUserId(env, req)) !== null;
}

/// WHICH signed-in user is asking, or null. Needed wherever the answer depends
/// on the caller's identity rather than merely on their being signed in — the
/// service key bypasses RLS, so any row-level rule has to be re-stated here.
async function supabaseUserId(env: Env, req: Request): Promise<string | null> {
  const auth = req.headers.get("authorization");
  if (!auth?.startsWith("Bearer ") || !env.SUPABASE_URL || !env.SUPABASE_SERVICE_KEY) return null;
  try {
    const res = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: env.SUPABASE_SERVICE_KEY, authorization: auth },
    });
    if (!res.ok) return null;
    const body = await res.json() as { id?: unknown };
    return typeof body.id === "string" ? body.id : null;
  } catch { return null; }
}

/// Whether these two are actually friends — the `Friends can view shared
/// flights` policy from migration 001, restated for the service key.
async function areFriends(env: Env, a: string, b: string): Promise<boolean> {
  if (a === b) return true;
  const rows = await sbSelect(env,
    "/friendships?select=id&status=eq.accepted"
    + `&or=(and(requester_id.eq.${a},addressee_id.eq.${b}),and(requester_id.eq.${b},addressee_id.eq.${a}))`);
  return rows.length > 0;
}

async function sbService(env: Env, method: string, path: string, body?: unknown): Promise<Response> {
  // A rejected fetch (DNS, connect) must not escape — /flight has a provider
  // fallback that never ran because the cache read 500'd first.
  try {
    return await fetch(`${env.SUPABASE_URL}/rest/v1${path}`, {
      method,
      headers: {
        apikey: env.SUPABASE_SERVICE_KEY!,
        authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        "content-type": "application/json",
        prefer: method === "POST" ? "resolution=merge-duplicates,return=minimal" : "return=minimal",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    return new Response(null, { status: 503 });
  }
}

async function sbSelect(env: Env, path: string): Promise<Record<string, any>[]> {
  try {
    const res = await fetch(`${env.SUPABASE_URL}/rest/v1${path}`, {
      headers: {
        apikey: env.SUPABASE_SERVICE_KEY!,
        authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    });
    if (!res.ok) return [];
    const data = await res.json();
    return Array.isArray(data) ? data as Record<string, any>[] : [];
  } catch {
    return [];
  }
}

/// ActivityKit decodes remote content-state with a default JSONDecoder, whose
/// Date strategy is seconds since 2001-01-01 (timeIntervalSinceReferenceDate) —
/// NOT unix epoch and NOT ISO strings. Getting this wrong fails silently.
function refDate(iso: string | null | undefined): number | null {
  if (!iso) return null;
  const ms = new Date(iso).getTime();
  if (isNaN(ms)) return null;
  return ms / 1000 - 978307200;
}

interface TokenRow {
  token: string;
  token_type: string;
  user_id: string | null;
  apns_env: "sandbox" | "production";
  flight_number: string | null;
  departure_iata: string | null;
  arrival_iata: string | null;
  departure_city: string | null;
  arrival_city: string | null;
  airline: string | null;
  aircraft_type: string | null;
  seat: string | null;
  scheduled_departure: string | null;
  scheduled_arrival: string | null;
  last_state: Record<string, any>;
}

/// One throwaway push at an invalid token, reporting what APNs said.
async function apnsProbe(env: Env, hostEnv: "sandbox" | "production"): Promise<Record<string, unknown>> {
  const host = hostEnv === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const jwt = await apnsJwt(env);
  const res = await fetch(`https://${host}/3/device/${"0".repeat(64)}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": `${APP_BUNDLE_ID}.push-type.liveactivity`,
      "apns-push-type": "liveactivity",
      "apns-priority": "5",
      "apns-expiration": "0",
      "content-type": "application/json",
    },
    body: JSON.stringify({ aps: { timestamp: Math.floor(Date.now() / 1000), event: "update", "content-state": {} } }),
  });
  const body = await res.text();
  let reason = "";
  try { reason = (JSON.parse(body) as { reason?: string }).reason ?? ""; } catch { reason = body.slice(0, 120); }
  return {
    status: res.status,
    reason,
    // Apple checks the token last: anything BUT a credential complaint means
    // the key, team and topic were accepted.
    credentialsAccepted: reason === "BadDeviceToken" || res.status === 200,
  };
}

async function runLiveActivityCron(env: Env): Promise<void> {
  // The push loops need APNs; the shared_flights refresher below does not.
  if (apnsConfigured(env)) {
    const rows = await sbSelect(env, "/live_activity_tokens?select=*") as unknown as TokenRow[];
    const updateRows = rows.filter(r => r.token_type === "update" && r.flight_number && r.scheduled_departure);
    // One line per tick saying what this loop can even see. Without it there
    // is no way to tell a token that was dropped from a token that is being
    // pushed to happily — both look identical from outside, which is how a
    // frozen lock screen went unexplained.
    if (rows.length > 0) {
      console.log("LA tokens:", rows.length, "update:", updateRows.length,
                  updateRows.map(r => `${r.flight_number}@${r.scheduled_departure}`).join(","));
    }

    // Stay under Cloudflare's 50-subrequests-per-invocation cap: a refresh
    // tick costs up to ~8 subrequests per row, and rows come back in stable DB
    // order — an unbounded loop over many tokens starved the SAME tail of
    // users on every single invocation once the cap threw. Shuffle and cap;
    // the cron runs every minute, so the rest are simply next in line.
    const shuffled = [...updateRows];
    for (let i = shuffled.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
    }
    for (const row of shuffled.slice(0, 15)) {
      try {
        await pushUpdateForRow(env, row);
      } catch (e) {
        // Keep the loop alive for other rows — but SAY so. Swallowed whole,
        // a row that throws every tick is a lock screen frozen for ever with
        // its token still in the table and nothing anywhere to explain it.
        console.error("LA push failed:", row.flight_number, row.token.slice(0, 8), String(e));
      }
    }

    // Push-to-start: begin a Live Activity server-side for flights entering the
    // 3h window, even if the app hasn't been opened. Upcoming flights come from
    // user_flights (the signed-in cloud mirror); without sign-in the app's own
    // local 3h check still covers the app-was-opened-recently case.
    const startRows = rows.filter(r => r.token_type === "start");
    if (startRows.length > 0) {
      try {
        await pushStarts(env, startRows, updateRows);
      } catch (e) { console.error("LA push-to-start failed:", String(e)); }
    }
  }

  // Friend-facing flight rows: shared_flights is only ever written by the
  // traveler's own device, so it froze the moment they stopped opening the
  // app — which is exactly when friends watch closest. Keep active-window
  // rows fresh server-side from the same provider cache the pushes use.
  try {
    await refreshSharedFlights(env);
  } catch (e) { console.error("shared refresh failed:", String(e)); }

  // LAST, deliberately. Flights that are still too far out for a Live Activity
  // to exist are the only path by which a cancellation the night before
  // reaches anyone — but they are also the least time-critical thing this tick
  // does, and Cloudflare caps subrequests per invocation. Running the watcher
  // after the live work means a busy minute costs a far-out flight one hour of
  // latency, rather than costing a taxiing aircraft its sighting.
  if (apnsConfigured(env)) {
    try {
      await watchUpcoming(env);
    } catch { /* best-effort — never take the rest of the tick down with it */ }
  }
}


/// One aircraft from the ADS-B aggregators, in the units every Arc client
/// speaks (metres, m/s). `kind` is icao | reg | callsign. Both hosts serve
/// the same readsb /v2 shape; adsb.lol is open, airplanes.live started
/// gating unregistered callers (403 "contact us") in 2026-08, so it is the
/// fallback. null when nothing is broadcasting under that identifier.
/// The community ADS-B aggregators, in preference order. Same readsb /v2
/// payload, different prefixes and different rate-limit moods — Workers share
/// egress IPs with everyone else on Cloudflare, so a per-IP limiter can lock
/// us out through no fault of ours. Trying several is the cheap insurance.
/// What `/position` answers with. The interface went out with `watchAircraft`
/// when the server witness moved to the provider's own location block, but
/// three signatures below kept naming it — a type error that neither node's
/// type-stripping nor esbuild ever evaluates, so it survived as a lie about
/// a shape nothing checked.
interface ADSBPosition {
  icao24: string;
  lat: number;
  lon: number;
  altitude: number;
  velocity: number;
  heading: number;
  on_ground: boolean;
  registration: string | null;
  age_seconds: number | null;
}

const ADSB_HOSTS = [
  { base: "https://api.adsb.lol", prefix: "/v2" },
  { base: "https://opendata.adsb.fi", prefix: "/api/v2" },
  { base: "https://api.airplanes.live", prefix: "/v2" },
];
/// Both aggregators reject anonymous callers — adsb.lol answers a bare
/// Worker fetch with 403 "User-Agent too generic; include valid contact
/// info." Cloudflare sends no UA of its own, which is why live position
/// silently returned null in production. Identify the project and where to
/// reach it; no personal data belongs in an outbound header.
const ADSB_UA_BASE = "ArcFlightTracker/1.0 (+https://arc-backend.owncalai.workers.dev";
function adsbUA(env: Env): string {
  return env.ADSB_CONTACT ? `${ADSB_UA_BASE}; ${env.ADSB_CONTACT})` : `${ADSB_UA_BASE})`;
}
async function fetchADSB(env: Env, kind: string, value: string): Promise<ADSBPosition | null> {
  const key = value.trim().replace(/\s+/g, "").toLowerCase();
  if (!key) return null;
  for (const host of ADSB_HOSTS) {
    const hit = await fetchADSBFrom(env, host, `/${kind}/${encodeURIComponent(key)}`);
    if (hit) return hit;
  }
  return null;
}
async function fetchADSBFrom(env: Env, host: { base: string; prefix: string }, path: string): Promise<ADSBPosition | null> {
  const list = await fetchADSBList(env, host, path);
  const ac = list.find(a => typeof a?.lat === "number" && typeof a?.lon === "number");
  return ac ? toADSBPosition(ac) : null;
}

/// Every aircraft a query returns. adsb.lol calls the array `ac`, adsb.fi
/// calls it `aircraft` on some routes — accept either.
async function fetchADSBList(env: Env, host: { base: string; prefix: string }, path: string): Promise<Record<string, any>[]> {
  try {
    const res = await fetch(`${host.base}${host.prefix}${path}`,
                            { headers: { Accept: "application/json", "User-Agent": adsbUA(env) } });
    if (!res.ok) return [];
    const raw = await res.json() as { ac?: Record<string, any>[]; aircraft?: Record<string, any>[] };
    return raw.ac ?? raw.aircraft ?? [];
  } catch { return []; }
}

function toADSBPosition(ac: Record<string, any>): ADSBPosition | null {
  try {
    // alt_baro is feet, or the string "ground" when it's on the deck; gs is knots.
    const onGround = ac.alt_baro === "ground";
    const altFt = typeof ac.alt_baro === "number" ? ac.alt_baro : 0;
    const speedKt = typeof ac.gs === "number" ? ac.gs : 0;
    return {
      icao24: String(ac.hex ?? "").toUpperCase(),
      lat: ac.lat, lon: ac.lon,
      altitude: Math.round(altFt * 0.3048),
      velocity: speedKt * 0.514444,
      heading: typeof ac.track === "number" ? ac.track : 0,
      on_ground: onGround,
      registration: ac.r ?? null,
      age_seconds: typeof ac.seen_pos === "number" ? Math.round(ac.seen_pos) : null,
    };
  } catch { return null; }
}

/// The airport's learned taxi-out for this hour, from the last 60 wheels-up
/// observations there. DEFAULT_TAXI_PRIOR until the airport has taught us.
async function taxiPriorFor(env: Env, iata: string, hourUTC: number): Promise<{ minutes: number; samples: number }> {
  if (!iata || !env.SUPABASE_SERVICE_KEY) return { minutes: DEFAULT_TAXI_PRIOR, samples: 0 };
  const rows = await sbSelect(env,
    `/taxi_observations?departure_iata=eq.${encodeURIComponent(iata.toUpperCase())}`
    + `&select=taxi_minutes,hour_utc&order=observed_at.desc&limit=60`);
  return {
    minutes: taxiPriorMinutes(rows as { taxi_minutes: number; hour_utc: number }[], hourUTC),
    samples: rows.length,
  };
}

/// Teach the airport its taxi-out from an observed wheels-up.
async function recordTaxiObservation(env: Env, row: Record<string, any>, takeoffISO: string): Promise<void> {
  const offBlock = new Date(row.scheduled_departure).getTime() + ((row.delay_minutes as number) ?? 0) * 60_000;
  const taxiStart = row.taxi_started_at ? Date.parse(row.taxi_started_at) : offBlock;
  const taxiMinutes = Math.round((Date.parse(takeoffISO) - taxiStart) / 60_000);
  if (!(taxiMinutes >= 0 && taxiMinutes <= 120)) return;
  await sbService(env, "POST", "/taxi_observations?on_conflict=flight_number,departure_iata,flight_date", {
    departure_iata: row.departure_iata,
    flight_number: row.flight_number,
    flight_date: String(row.scheduled_departure).slice(0, 10),
    hour_utc: new Date(offBlock).getUTCHours(),
    taxi_minutes: taxiMinutes,
    observed_at: takeoffISO,
  });
}

/// Bring ONE shared row up to date against the provider, applying the merge
/// rules that decide what a friend is allowed to be told.
///
/// Extracted so the cron and the on-demand endpoint cannot drift: a viewer
/// refreshing a friend's flight by hand must get exactly the same answer the
/// cron would have written, including "a provider null never erases a
/// device-reported value" and "a wheels-up already established is never
/// un-confirmed".
async function refreshOneSharedRow(env: Env, row: Record<string, any>, now: number): Promise<void> {
    if (!row.flight_number) return;
    const day = String(row.scheduled_departure).slice(0, 10);
    const { legs, cache } = await fetchLegsCached(env, "flight", String(row.flight_number), day, "cron");
    const leg = pickLeg(legs, {
      depIata: row.departure_iata, arrIata: row.arrival_iata,
      scheduledDepMs: Date.parse(String(row.scheduled_departure)),
    });
    if (!leg) {
      // We looked and the provider had nothing to say — which, for a flight
      // further out than it publishes schedules for, is the ordinary answer
      // rather than a failure. Returning here without a word cost two things
      // at once: the friend's screen had nothing newer than `updated_at` to
      // read, so it counted upward from the traveller's last write for ever;
      // and `/shared/refresh` deduplicates on `checked_at`, so with the column
      // never written its once-a-minute guard never engaged and every open
      // reached the provider again.
      //
      // Only stamp when the fetch actually landed. A budget-blocked or
      // malformed one must not tell the screen this row was just verified.
      if (providerAnswered(cache)
          && shouldWriteSharedRow({ changed: false, checkedAt: row.checked_at, now })) {
        await sbService(env, "PATCH", `/shared_flights?id=eq.${row.id}`, {
          checked_at: new Date(now).toISOString(),
        });
      }
      return;
    }
    // Timestamps compare by instant, not string: the provider writes "…Z",
    // PostgREST reads back "…+00:00", and a string comparison would call
    // every unchanged row changed on every tick.
    const tsDiffers = (a: unknown, b: unknown): boolean => {
      const ta = a ? Date.parse(String(a)) : NaN;
      const tb = b ? Date.parse(String(b)) : NaN;
      return (isNaN(ta) ? null : ta) !== (isNaN(tb) ? null : tb);
    };
    // What the provider's own position block says the aircraft is doing.
    // Same call, same key, no IP rate limit — this is how a friend sees
    // "Taxiing" while the traveller's phone is in airplane mode, and how a
    // take-off gets confirmed with nobody's app open at all.
    //
    // Computed BEFORE `changed`, which reads it: declared after, `state` sat
    // in the temporal dead zone, so the moment every other operand was false
    // — i.e. precisely when the new sighting was the only news — evaluating
    // `changed` threw ReferenceError, the catch below swallowed it, and the
    // row was skipped. The server witness never wrote a taxi state it had
    // observed unless something unrelated changed in the same tick.
    const sample = leg["position"] as ReturnType<typeof adbPositionToSample>;
    const sampleFresh = !!sample && now - Date.parse(sample.reportedAt) < 15 * 60_000;
    const state = sampleFresh ? classifyGround(sample) : "unknown";
    const changed =
      leg["status"] !== row.status ||
      (leg["delay"] ?? 0) !== row.delay_minutes ||
      (leg["dep_gate"] ?? row.departure_gate) !== row.departure_gate ||
      (leg["arr_gate"] ?? row.arrival_gate) !== row.arrival_gate ||
      (leg["arr_baggage"] ?? row.baggage_claim) !== row.baggage_claim ||
      tsDiffers(leg["dep_actual"] ?? row.actual_departure, row.actual_departure) ||
      tsDiffers(leg["arr_actual"] ?? row.actual_arrival, row.actual_arrival) ||
      tsDiffers(leg["arr_actual"] ?? leg["arr_estimated"] ?? row.estimated_arrival, row.estimated_arrival) ||
      tsDiffers(leg["dep_runway_estimated"] ?? row.est_takeoff, row.est_takeoff) ||
      (leg["aircraft_registration"] ?? row.aircraft_registration) !== row.aircraft_registration ||
      // A new sighting is itself news: it is what the friend's screen reads
      // to say taxiing rather than flying.
      (state !== "unknown" && (state !== row.ground_state || !row.ground_observed_at));
    // Even an unchanged answer is worth recording: it is how the friend's
    // screen knows this was VERIFIED a minute ago rather than left alone for
    // nine hours. Throttled so a stable row costs one small write every few
    // minutes rather than one a minute — comfortably inside the ten-minute
    // window in which the app will still say "Live".
    if (!shouldWriteSharedRow({ changed, checkedAt: row.checked_at, now })) return;
    const ground: Record<string, unknown> = {};
    if (state !== "unknown") {
      ground.ground_state = state;
      ground.ground_observed_at = sample!.reportedAt;
      if (state === "taxiing" && !row.taxi_started_at) ground.taxi_started_at = sample!.reportedAt;
      // The device owns the live position while it is still talking; once it
      // has gone quiet the provider's is the better witness and friends'
      // maps keep moving.
      // Measured against `updated_at`, which only a real change writes — so
      // this still means "the traveller's device has stopped talking", not
      // "the cron stamped checked_at a minute ago".
      const deviceQuiet = !row.updated_at || now - Date.parse(row.updated_at) > 5 * 60_000;
      if ((deviceQuiet || row.live_source === "provider") && sample!.lat != null) {
        ground.live_lat = sample!.lat;
        ground.live_lon = sample!.lon;
        ground.live_altitude = sample!.altitude;
        ground.live_speed = sample!.velocity;
        ground.live_source = "provider";
      }
      if (state === "airborne" && !row.actual_departure) {
        // First sighting off the ground IS the take-off, and it beats the
        // provider's own runway time to the row by minutes.
        ground.actual_departure = sample!.reportedAt;
        await recordTaxiObservation(env, row, sample!.reportedAt);
      }
    }
    // Screened, not trusted: a departure that precedes its own schedule by
    // hours is another operation's timestamp that reached this row, and the
    // carry-forward below would otherwise pin it here for ever. Dropping it
    // lets a row contaminated by the old route-only leg match heal itself on
    // the next tick.
    const carried = plausibleActualDeparture(row.actual_departure, Date.parse(String(row.scheduled_departure)));
    const confirmedDeparture = (ground.actual_departure as string | undefined)
      ?? carried ?? leg["dep_actual"] ?? null;
    await sbService(env, "PATCH", `/shared_flights?id=eq.${row.id}`, {
      ...ground,
      status: confirmedDeparture && leg["status"] !== "landed" && leg["status"] !== "cancelled"
        && leg["status"] !== "diverted" ? "active" : leg["status"],
      delay_minutes: leg["delay"] ?? 0,
      // A provider null must not erase device-reported values — for ANY of
      // these. estimated/actual used to be written `?? null`, so one provider
      // response without them blanked what the traveler's device had already
      // reported, and their friends watched a confirmed departure un-confirm.
      departure_gate: leg["dep_gate"] ?? row.departure_gate ?? null,
      arrival_gate: leg["arr_gate"] ?? row.arrival_gate ?? null,
      baggage_claim: leg["arr_baggage"] ?? row.baggage_claim ?? null,
      estimated_arrival: leg["arr_actual"] ?? leg["arr_estimated"] ?? row.estimated_arrival ?? null,
      // A wheels-up already established — by this cron's own sighting or by
      // the traveller's device — is a better witness than the provider's
      // (later, off-block-flavoured) fact: keep the earlier one.
      actual_departure: confirmedDeparture,
      actual_arrival: leg["arr_actual"] ?? row.actual_arrival ?? null,
      est_takeoff: leg["dep_runway_estimated"] ?? row.est_takeoff ?? null,
      aircraft_registration: leg["aircraft_registration"] ?? row.aircraft_registration ?? null,
      aircraft_icao24: leg["aircraft_icao24"] ?? row.aircraft_icao24 ?? null,
      // We looked, and this is when. Written every time, so a friend's screen
      // can tell "verified a minute ago" from "abandoned nine hours ago".
      checked_at: new Date(now).toISOString(),
      // Only a real change touches `updated_at`. It is the signal that the
      // traveller's own device is still writing this row, and stamping it on
      // every consultation would make the cron mistake itself for the device
      // and then stand aside for a phone that is not there.
      ...(changed ? { updated_at: new Date(now).toISOString() } : {}),
    });
}

/// Refresh provider-derived fields of shared_flights rows in their active
/// window (4 h before departure → 45 min past delay-adjusted arrival), so a
/// friend's view keeps moving when the traveler's device goes quiet. Never
/// touches live position/progress — those stay device-reported.
async function refreshSharedFlights(env: Env): Promise<void> {
  const now = Date.now();
  const from = new Date(now - 24 * 3600_000).toISOString();
  // Out to thirty hours, not four: before that the ONLY writer of these rows
  // was the traveller's own device, on its tracker poll, while their app was
  // open. See sharedRowCheckInterval — far-out rows are consulted hourly, so
  // widening the net costs a fraction of a call per flight per hour.
  const to = new Date(now + 30 * 3600_000).toISOString();
  const rows = await sbSelect(env,
    "/shared_flights?select=id,flight_number,departure_iata,arrival_iata,scheduled_departure,scheduled_arrival," +
    "status,delay_minutes,departure_gate,arrival_gate,baggage_claim,updated_at,mode," +
    "estimated_arrival,actual_departure,actual_arrival,est_takeoff,aircraft_registration,aircraft_icao24," +
    "ground_state,ground_observed_at,taxi_started_at,live_source,checked_at" +
    `&scheduled_departure=gte.${from}&scheduled_departure=lte.${to}`
  ) as unknown as Record<string, any>[];

  const active = rows.filter(r => {
    // AeroDataBox only answers for air legs; a rail/sea row would burn a
    // budget-guarded call on a guaranteed miss and crowd flights out of the cap.
    if (((r.mode as string) ?? "air") !== "air") return false;
    const delayMs = ((r.delay_minutes as number) ?? 0) * 60_000;
    const dep = new Date(r.scheduled_departure).getTime();
    const arr = new Date(r.scheduled_arrival ?? r.scheduled_departure).getTime() + delayMs;
    return sharedRowIsDue({ depMs: dep, arrMs: arr, checkedAt: r.checked_at, now })
      && r.status !== "landed" && r.status !== "cancelled"
      // The traveler's own device may be updating this row right now —
      // only step in once it has gone quiet.
      && (!r.updated_at || now - Date.parse(r.updated_at) > 5 * 60_000);
  });

  // Shuffle so nobody is starved by stable DB order, then put the flights
  // closest to departure first: with a thirty-hour net there are far more
  // candidates than the per-tick cap, and a row taxiing right now must never
  // wait behind one leaving tomorrow morning.
  for (let i = active.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [active[i], active[j]] = [active[j], active[i]];
  }
  const urgency = (r: Record<string, any>) => {
    const delayMs = ((r.delay_minutes as number) ?? 0) * 60_000;
    const dep = new Date(r.scheduled_departure).getTime() + delayMs;
    // The REAL arrival, not the departure: passing dep for both would put an
    // aircraft currently in the air past its own arrival grace, scoring it as
    // out of scope and sorting the most urgent row in the list dead last.
    const arr = new Date(r.scheduled_arrival ?? r.scheduled_departure).getTime() + delayMs;
    return sharedRowCheckInterval({ depMs: dep, arrMs: arr, now }) ?? Number.MAX_SAFE_INTEGER;
  };
  active.sort((a, b) => urgency(a) - urgency(b));
  for (const row of active.slice(0, 5)) {
    try {
      await refreshOneSharedRow(env, row, now);
    } catch (e) {
      // One malformed row must not kill the refreshes behind it this tick.
      console.error("refreshSharedFlights row failed:", row?.id, e);
    }
  }
}

/// Watch upcoming flights that no Live Activity covers yet, and say something
/// when the answer changes.
///
/// The three hours before departure are already covered: push-to-start opens a
/// card and `pushUpdateForRow` keeps it moving. Everything EARLIER had no
/// channel at all — Arc's alerts were local notifications, scheduled on the
/// device, so they could only fire while the app was awake. The cron knew a
/// flight was cancelled and had no way to say so.
///
/// Deliberately slow. A cancellation twenty hours out does not need
/// minute-level freshness, so each flight is looked at about once an hour and
/// only a handful are looked at per tick. Every fetch rides the shared,
/// budget-guarded cache at source "cron", so this can never eat the
/// interactive reserve that a reconnecting device depends on.
const WATCH_PER_TICK = 4;
const WATCH_INTERVAL_MS = 55 * 60_000;

async function watchUpcoming(env: Env): Promise<void> {
  const now = Date.now();
  // From the edge of Live Activity coverage out to a day and a half.
  const from = new Date(now + 3 * 3600_000).toISOString();
  const to = new Date(now + 36 * 3600_000).toISOString();
  const stale = new Date(now - WATCH_INTERVAL_MS).toISOString();
  const rows = await sbSelect(env,
    "/user_flights?select=id,user_id,flight_number,departure_iata,arrival_iata,arrival_city," +
    "scheduled_departure,status,delay_minutes,departure_gate,mode,watch_state" +
    `&scheduled_departure=gte.${from}&scheduled_departure=lte.${to}` +
    `&or=(watch_checked_at.is.null,watch_checked_at.lt.${stale})` +
    "&status=in.(scheduled,boarding,gateClosed)"
  ) as unknown as Record<string, any>[];

  // AeroDataBox only answers for air legs; anything else would spend a
  // budget-guarded call on a guaranteed miss.
  const due = rows.filter(r => (((r.mode as string) ?? "air") === "air") && r.flight_number);
  for (let i = due.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [due[i], due[j]] = [due[j], due[i]];
  }

  for (const row of due.slice(0, WATCH_PER_TICK)) {
    try {
      const day = String(row.scheduled_departure).slice(0, 10);
      const { legs } = await fetchLegsCached(env, "flight", String(row.flight_number), day, "cron");
      const leg = pickLeg(legs, {
        depIata: row.departure_iata, arrIata: row.arrival_iata,
        scheduledDepMs: Date.parse(String(row.scheduled_departure)),
      });
      // Stamp the check even when the provider had nothing, so one unanswerable
      // flight does not occupy a slot on every tick from now on.
      const checked: Record<string, unknown> = { watch_checked_at: new Date(now).toISOString() };
      if (!leg) {
        await sbService(env, "PATCH", `/user_flights?id=eq.${row.id}`, checked);
        continue;
      }

      const news = flightNews({
        flightNumber: String(row.flight_number),
        arrivalCity: String(row.arrival_city || row.arrival_iata || "your destination"),
        status: String(leg["status"] ?? row.status ?? "scheduled"),
        delayMinutes: Number(leg["delay"] ?? 0),
        departureGate: (leg["dep_gate"] as string | null) ?? null,
        scheduledDeparture: Date.parse(String(row.scheduled_departure)),
        now,
        prior: (row.watch_state ?? {}) as WatchState,
      });
      if (news) {
        await sendToUser(env, String(row.user_id), news.title, news.body,
                         news.collapseId, String(row.flight_number));
        checked.watch_state = news.state;
      }
      await sbService(env, "PATCH", `/user_flights?id=eq.${row.id}`, checked);
    } catch (e) {
      console.error("watchUpcoming row failed:", row?.id, e);
    }
  }
}

/// Deliver one alert to every device a user has registered, and forget the
/// ones APNs says are gone.
async function sendToUser(env: Env, userId: string, title: string, body: string,
                          collapseId: string, threadId: string): Promise<void> {
  const tokens = await sbSelect(env,
    `/device_tokens?select=token,apns_env&user_id=eq.${encodeURIComponent(userId)}`
  ) as unknown as { token: string; apns_env: "sandbox" | "production" }[];
  for (const t of tokens.slice(0, 5)) {
    const status = await sendAlertPush(env, t.token, t.apns_env, APP_BUNDLE_ID,
                                       { title, body }, collapseId, threadId);
    if (status !== 200) console.error("alert push non-200:", status, threadId, t.token.slice(0, 8));
    if (status === 410 || status === 400) {
      await sbService(env, "DELETE", `/device_tokens?token=eq.${encodeURIComponent(t.token)}`);
    }
  }
}

/// How often the cron re-consults the provider, by flight phase. Progress
/// ticks between refreshes cost nothing — they're computed from stored
/// times. Only the windows where data really moves get tight cadence.
function cronRefreshIntervalMs(depMs: number, arrMs: number, now: number): number {
  if (now < depMs - 90 * 60_000) return 10 * 60_000;        // pre-departure, far
  // Gate assignment and boarding land in the last ~hour; a 10-minute cron
  // hold on top of the 5-minute cache TTL is how Arc told someone their
  // gate a quarter hour after the airline's own app did. The fetch rides
  // the shared cache, so tightening here costs one provider call per TTL
  // window at most, shared with every device asking about the same flight.
  if (now < depMs + 20 * 60_000) return 5 * 60_000;         // gate/boarding/departure
  if (now < arrMs - 45 * 60_000) return 30 * 60_000;        // cruise
  return 10 * 60_000;                                        // arrival window
}

async function pushUpdateForRow(env: Env, row: TokenRow): Promise<void> {
  const now = Date.now();
  const prior = row.last_state ?? {};
  let flight: Record<string, any> | null = prior.flight ?? null;
  const fetchedAt: number = prior.fetched_at ?? 0;
  const pushedAt: number = prior.pushed_at ?? 0;
  let lastFetch = fetchedAt;
  let dataChanged = false;
  // What this token has established about the gate-to-runway gap, carried
  // between ticks in last_state. Without it every push rebuilt the lock
  // screen's DepartureEvidence from nothing, so the card that said
  // "Taxiing · 14m" reverted to a clock presumption five minutes later —
  // undoing on the server exactly what the device had witnessed.
  const evidence: Record<string, string | undefined> = { ...(prior.evidence ?? {}) };

  // Nothing to do far ahead of departure — and no reason to burn quota.
  const schedDepGuess = new Date(row.scheduled_departure!).getTime();
  if (now < schedDepGuess - 4 * 60 * 60 * 1000) return;

  // Phase-aware provider refresh through the SHARED cache (source "cron",
  // capped by its own monthly budget — it can never eat the interactive
  // reserve that reconnecting devices depend on).
  const priorDelayMs = ((flight?.["delay"] as number) ?? 0) * 60_000;
  const knownDep = flight?.["dep_actual"] ? new Date(flight["dep_actual"]).getTime() : schedDepGuess + priorDelayMs;
  const knownArr = flight?.["arr_actual"] ? new Date(flight["arr_actual"]).getTime()
    : new Date(row.scheduled_arrival ?? row.scheduled_departure!).getTime() + priorDelayMs;
  if (now - fetchedAt > cronRefreshIntervalMs(knownDep, knownArr, now)) {
    const day = row.scheduled_departure!.slice(0, 10);
    const { legs } = await fetchLegsCached(env, "flight", row.flight_number!, day, "cron");
    // A flight number can have multiple legs that day — and on a route that
    // lands after local midnight, two of them are the SAME route on
    // consecutive days. Match by route AND scheduled time.
    const leg = pickLeg(legs, {
      depIata: row.departure_iata, arrIata: row.arrival_iata,
      scheduledDepMs: schedDepGuess,
    });
    if (leg) {
      dataChanged = !!flight && (
        leg["status"] !== flight["status"] ||
        leg["delay"] !== flight["delay"] ||
        leg["dep_gate"] !== flight["dep_gate"] ||
        leg["arr_gate"] !== flight["arr_gate"] ||
        leg["arr_baggage"] !== flight["arr_baggage"]
      );
      flight = leg as Record<string, any>;
    }
    lastFetch = now;
    // A source that reports movements and did NOT report a take-off has just
    // told us the aircraft is still on the ground — which is what pushes back
    // the moment any surface may presume otherwise. Recorded only on a real
    // consultation, never on the cached ticks in between.
    if (leg && !leg["dep_actual"] && leg["dep_live"] === true) {
      evidence.last_seen_on_ground = new Date(now).toISOString();
    }
    await sbService(env, "PATCH", `/live_activity_tokens?token=eq.${encodeURIComponent(row.token)}`, {
      last_state: { ...prior, flight, fetched_at: now, evidence },
      updated_at: new Date().toISOString(),
    });
  }

  const delay: number = flight?.["delay"] ?? 0;
  const schedDepMs = new Date(row.scheduled_departure!).getTime();
  const schedArrMs = new Date(row.scheduled_arrival ?? row.scheduled_departure!).getTime();
  const depMs = flight?.["dep_actual"] ? new Date(flight["dep_actual"]).getTime() : schedDepMs + delay * 60_000;
  const arrMs = flight?.["arr_actual"] ? new Date(flight["arr_actual"]).getTime() : schedArrMs + delay * 60_000;

  // Status: the provider's value, UNTOUCHED. The widget already flips its
  // layout by clock on its own; the status string is its CONFIRMATION
  // signal ("Departing…"/"Landing soon" vs. confirmed flying/landed).
  // Clock-healing to "active"/"landed" here fabricated confirmations —
  // a traveler still seated at the gate through an unreported extra delay
  // was told they were flying.
  const status: string = flight?.["status"] ?? "scheduled";

  // Done: final "end" push (keeps the landed card up an hour), then forget the token.
  if (now > arrMs + 45 * 60 * 1000 || status === "cancelled") {
    const endPayload = {
      aps: {
        timestamp: Math.floor(now / 1000),
        event: "end",
        "dismissal-date": Math.floor(now / 1000) + 3600,
        "content-state": contentState(status, depMs, arrMs, delay, Math.round((arrMs - schedArrMs) / 60_000),
                                      flight, null,
                                      { offBlockMs: depMs, taxiPrior: DEFAULT_TAXI_PRIOR, evidence, local: prior.local }),
      },
    };
    const end = await sendLiveActivityPush(env, row.token, row.apns_env, APP_BUNDLE_ID, endPayload, 5);
    // Deliberate end-of-life, logged so it is never confused with a rejection.
    console.log("LA ended:", row.flight_number, "status", status, "st", end.status, end.reason ?? "");
    await sbService(env, "DELETE", `/live_activity_tokens?token=eq.${encodeURIComponent(row.token)}`);
    return;
  }

  // Not yet in the window where updates matter (>4h before departure): skip.
  if (now < depMs - 4 * 60 * 60 * 1000) return;

  // What this airport's taxi actually takes at this hour — the grace the
  // lock screen gives a departure before it may presume wheels-up.
  const taxiPrior = (flight?.["dep_iata"])
    ? (await taxiPriorFor(env, String(flight["dep_iata"]), new Date(depMs).getUTCHours())).minutes
    : DEFAULT_TAXI_PRIOR;

  // stale-date = next phase boundary: iOS re-renders the Live Activity once
  // when content goes stale, and that render re-evaluates the clock-based
  // phase — so the pre→during→after layout flips on time even if this was
  // the last push before the device went offline (i.e. takeoff). Judged by
  // CLOCK, not status (status is no longer clock-healed): the boundary
  // after an unconfirmed departure is the end of the widget's 20-min
  // "Departing…" hedge.
  // The boundary after an unconfirmed departure is the EXPECTED WHEELS-UP —
  // off-block plus this airport's learned taxi-out, or the provider's own
  // estimate — not the gate time plus a constant. A 20-minute grace expires
  // mid-taxi at any busy hub, and the re-render it schedules is what flipped
  // a lock screen to "In Air" while its owner sat in an ATC hold.
  // The provider's own position block, from the same leg call — the witness
  // that tells taxiing from flying with no app open. Same freshness rule as
  // refreshSharedFlights: a sighting older than 15 minutes says nothing about
  // now, and `flight` is a cached leg that can outlive its own position.
  const sample = flight?.["position"] as ReturnType<typeof adbPositionToSample> | undefined;
  const groundState = (sample && now - Date.parse(sample.reportedAt) < 15 * 60_000)
    ? classifyGround(sample) : "unknown";
  if (groundState !== "unknown") {
    if (groundState === "taxiing" && !evidence.taxi_started_at) {
      evidence.taxi_started_at = sample!.reportedAt;
    }
    // A first sighting on the move, or off the ground, is worth the user's
    // attention now rather than at the next routine tick.
    if (groundState !== evidence.ground_state) dataChanged = true;
    evidence.ground_state = groundState;
    evidence.ground_observed_at = sample!.reportedAt;
  }
  const depActualMs = flight?.["dep_actual"] ? Date.parse(String(flight["dep_actual"])) : NaN;
  const estTakeoffMs = flight?.["dep_runway_estimated"]
    ? Date.parse(String(flight["dep_runway_estimated"])) : NaN;
  const wheelsUpMs = Math.max(
    depMs + taxiPrior * 60_000,
    Number.isFinite(estTakeoffMs) ? estTakeoffMs : 0,
  );
  const staleAt = now < depMs
    ? Math.floor(depMs / 1000)
    : !Number.isFinite(depActualMs) && now < wheelsUpMs
      ? Math.floor(wheelsUpMs / 1000)
      : Math.floor(Math.max(arrMs, now + 60_000) / 1000);
  // Routine progress ticks every 5 minutes (they cost no provider calls —
  // progress comes from stored times); real changes push immediately at
  // priority 10. Every-minute pushes just drained the system's LA budget.
  if (!dataChanged && now - pushedAt < 5 * 60 * 1000) return;

  // The smart line: regenerated only when the situation FINGERPRINT changes
  // (a new delay, a gate move, a status flip); routine ticks re-push the
  // cached line, so Haiku runs a handful of times per flight, not per push.
  const arrDelay = Math.round((arrMs - schedArrMs) / 60_000);
  const insightKey = [status, delay, arrDelay, flight?.["dep_gate"] ?? "", flight?.["arr_baggage"] ?? ""].join("|");
  // No line by DEFAULT. A normal flight — on time, gate where it was, no
  // trend — gets nothing; only a situation with an actual story is worth a
  // model call, let alone the user's attention.
  const gateMoved = prior.insight_gate != null
    && (flight?.["dep_gate"] ?? null) !== prior.insight_gate;
  const delayMoved = prior.insight_delay != null
    && Math.abs(delay - (prior.insight_delay as number)) >= 10;
  const hasStory =
    Math.abs(arrDelay - delay) >= 10   // schedule padding absorbing a late start (or losing time)
    || delayMoved                       // delay trend since the last line
    || gateMoved                        // gate change
    || delay >= 25                      // a delay big enough to re-plan around
    || arrDelay <= -10;                 // making up real time in the air
  let insight: string | null = null;
  if (hasStory && env.AI_API_KEY) {
    insight = prior.insight_key === insightKey
      ? ((prior.insight as string | null) ?? null)
      : await generateInsight(env, {
          status,
          departure_delay_minutes: delay,
          arrival_delay_minutes: arrDelay,
          previous_departure_delay_minutes: prior.insight_delay ?? null,
          minutes_until_departure: Math.round((depMs - now) / 60_000),
          departure_gate: flight?.["dep_gate"] ?? null,
          previous_departure_gate: prior.insight_gate ?? null,
          baggage_belt: flight?.["arr_baggage"] ?? null,
        });
  }

  const payload = {
    aps: {
      timestamp: Math.floor(now / 1000),
      event: "update",
      "stale-date": staleAt,
      "content-state": contentState(status, depMs, arrMs, delay, arrDelay, flight, insight,
                                    { offBlockMs: depMs, taxiPrior, evidence, local: prior.local }),
      ...(dataChanged && flight?.["dep_gate"] ? {
        alert: {
          title: `${row.flight_number} update`,
          body: `Gate ${flight["dep_gate"]}${delay > 0 ? ` · ${delay}m late` : ""}`,
        },
      } : {}),
    },
  };
  // What actually went on the wire. A push that is ACCEPTED but carries the
  // same stale leg every time is indistinguishable, from outside, from no
  // push at all — the lock screen simply never changes.
  console.log("LA push:", row.flight_number,
              "changed", dataChanged,
              "status", status,
              "depActual", flight?.["dep_actual"] ?? null,
              "ground", evidence.ground_state ?? null,
              "obs", evidence.ground_observed_at ?? null,
              "fetchAge", Math.round((now - lastFetch) / 1000) + "s");
  const { status: st, reason } = await sendLiveActivityPush(
    env, row.token, row.apns_env, APP_BUNDLE_ID, payload, dataChanged ? 10 : 5);
  await sbService(env, "PATCH", `/live_activity_tokens?token=eq.${encodeURIComponent(row.token)}`, {
    last_state: {
      ...prior, flight, fetched_at: lastFetch, pushed_at: now, evidence,
      insight, insight_key: insightKey, insight_delay: delay,
      insight_gate: flight?.["dep_gate"] ?? null,
    },
  });
  // A push channel that dies silently is a lock screen frozen at whatever it
  // last said, with nothing anywhere to say why. 410/400 mean the token is
  // genuinely gone and dropping it is right — but dropping it WITHOUT a word
  // is how a card sat on "Taxiing" for an hour while the aircraft was on
  // approach, and no log existed to tell the two apart.
  if (st !== 200) {
    console.error("LA push non-200:", st, reason ?? "(no reason)", row.flight_number, row.token.slice(0, 8),
                  tokenIsDead(st, reason) ? "(dropping token)" : "(keeping token)");
  }
  if (tokenIsDead(st, reason)) {
    await sbService(env, "DELETE", `/live_activity_tokens?token=eq.${encodeURIComponent(row.token)}`);
  }
}

/// Mirror of FlightActivityAttributes.ContentState — field names and types are
/// a wire contract with the app; change them together or pushes silently fail.
/// The Live Activity's "smart line": one sentence of UNDERSTANDING — not a
/// restatement of numbers the widget already shows (times, delay, gate are
/// all visible), but what they mean: a delay trend, a knock-on expectation,
/// time made up in the air. Phrased by Haiku from structured signals, same
/// idiom as the parse calls above. The caller caches by signal fingerprint
/// so the model runs only when the situation actually changes — never on
/// routine progress ticks.
async function generateInsight(env: Env, signals: Record<string, unknown>): Promise<string | null> {
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": env.AI_API_KEY!,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        // Haiku: a trivial phrasing task over a handful of numbers, running
        // inside the cron's latency budget.
        model: "claude-haiku-4-5",
        max_tokens: 120,
        output_config: {
          format: {
            type: "json_schema",
            schema: {
              type: "object",
              properties: {
                insight: {
                  type: "string",
                  description: "ONE calm, factual line, max 70 characters, no emoji. Empty string when the numbers carry no story worth adding.",
                },
              },
              required: ["insight"],
              additionalProperties: false,
            },
          },
        },
        system: "You write the single smart line on a flight tracker's lock-screen widget — but ONLY when it genuinely earns its place. The widget already SHOWS times, delay minutes, gate and baggage; restating any of them is worthless. The bar: would this line change what the traveler does or expects? A delay that keeps growing vs. one that is holding, a late departure the schedule padding will absorb (arrival delay clearly smaller than departure delay), a gate change, real time being made up in the air. Anything obvious or merely descriptive fails the bar — prefer the empty string; silence is the default, a line is the exception. When you do write one: calm, factual, max 70 characters, no emoji.",
        messages: [{ role: "user", content: JSON.stringify(signals) }],
      }),
    });
    if (!res.ok) return null;
    const data = (await res.json()) as Record<string, any>;
    const text = data?.content?.[0]?.text;
    if (typeof text !== "string") return null;
    const insight = String(JSON.parse(text)?.insight ?? "").trim();
    return insight.length > 0 ? insight.slice(0, 90) : null;
  } catch (e) {
    console.error("insight generation failed:", String(e));
    return null;
  }
}

/// How many push-to-start tokens one cron tick may push to. Each costs a
/// subrequest, plus one more to delete it when APNs refuses it, against
/// Cloudflare's 50-per-invocation ceiling that the rest of the tick shares.
const START_PER_TICK = 10;

async function pushStarts(env: Env, startRows: TokenRow[], updateRows: TokenRow[]): Promise<void> {
  const now = Date.now();
  const soon = new Date(now + 3 * 60 * 60 * 1000).toISOString();
  const nowIso = new Date(now).toISOString();
  const upcoming = await sbSelect(
    env,
    `/user_flights?select=*&scheduled_departure=gte.${nowIso}&scheduled_departure=lte.${soon}&status=in.(scheduled,boarding,gateClosed)`
  );
  if (upcoming.length === 0) return;

  // No owner, no starts — fail closed. Cross-joining every user's flights with
  // every start token put user A's flight (seat included) on user B's lock
  // screen; a token registered before sign-in gets nothing until it
  // re-registers with its owner. And a token whose owner has nothing in the
  // window would do no work below anyway, so it must not occupy a slot.
  const owners = new Set(upcoming.map(u => String(u["user_id"] ?? "")));
  const candidates = startRows.filter(r => r.user_id && owners.has(r.user_id));

  // iOS mints a NEW push-to-start token whenever it rotates one, and every one
  // of them was kept: 187 rows had accumulated for a single tester. They cost
  // nothing on a quiet tick, because the filter above drops them — but the
  // moment a flight enters the 3h window, every one of that owner's tokens
  // gets a push inside ONE invocation, and a Worker gets 50 subrequests.
  //
  // Same treatment the update loop already carries, for the same reason:
  // shuffle so it is never the same tail that misses out, cap so the tick
  // survives, and let the cron's every-minute cadence do the rest — dead
  // tokens are deleted as they are refused, so a backlog drains itself. The
  // window is three hours; this drains 187 in twenty minutes.
  for (let i = candidates.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [candidates[i], candidates[j]] = [candidates[j], candidates[i]];
  }
  const batch = candidates.slice(0, START_PER_TICK);
  // Never silently. A cap that isn't logged reads as "everyone was covered".
  if (candidates.length > batch.length) {
    console.log("LA starts:", candidates.length, "eligible, pushing", batch.length, "this tick");
  }

  for (const startRow of batch) {
    const sent: Record<string, number> = startRow.last_state?.sent ?? {};
    let sentChanged = false;

    // Air only: a push-to-start for a train would put plane iconography and
    // gate copy on a lock screen; the app starts non-air activities itself
    // with mode-aware attributes.
    for (const f of upcoming.filter(u => u["user_id"] === startRow.user_id
        && ((u["mode"] as string) ?? "air") === "air")) {
      const key = `${f.flight_number}-${String(f.scheduled_departure).slice(0, 10)}`;
      // Skip if an update token already exists for this flight (activity is
      // already running) or we already sent a start recently.
      const alreadyLive = updateRows.some(u =>
        u.flight_number === f.flight_number &&
        u.scheduled_departure?.slice(0, 10) === String(f.scheduled_departure).slice(0, 10)
      );
      if (alreadyLive || (sent[key] && now - sent[key] < 6 * 60 * 60 * 1000)) continue;

      const depMs = new Date(f.scheduled_departure).getTime() + (f.delay_minutes ?? 0) * 60_000;
      const arrMs = new Date(f.scheduled_arrival ?? f.scheduled_departure).getTime() + (f.delay_minutes ?? 0) * 60_000;
      const payload = {
        aps: {
          timestamp: Math.floor(now / 1000),
          event: "start",
          "attributes-type": "FlightActivityAttributes",
          attributes: {
            flightNumber: f.flight_number,
            departureIATA: f.departure_iata,
            arrivalIATA: f.arrival_iata,
            departureCity: f.departure_city ?? "",
            arrivalCity: f.arrival_city ?? "",
            airline: f.airline ?? "",
            aircraftType: f.aircraft_type ?? null,
            seat: f.seat ?? null,
            modeRaw: "air",
            // Each end's own zone, so a push-started card prints an arrival
            // the way the ARRIVAL airport reads it rather than the way the
            // reader's phone does.
            departureTZID: f.departure_tz ?? null,
            arrivalTZID: f.arrival_tz ?? null,
          },
          "content-state": contentState(f.status ?? "scheduled", depMs, arrMs, f.delay_minutes ?? 0, f.delay_minutes ?? 0, {
            dep_gate: f.departure_gate, dep_terminal: f.departure_terminal,
            arr_gate: f.arrival_gate, arr_terminal: f.arrival_terminal,
            arr_baggage: f.baggage_claim,
          }),
          alert: {
            title: `${f.flight_number} to ${f.arrival_city ?? f.arrival_iata}`,
            body: "Departing soon — live tracking started",
          },
        },
      };
      const { status: st, reason } = await sendLiveActivityPush(
        env, startRow.token, startRow.apns_env, APP_BUNDLE_ID, payload, 10);
      if (st !== 200) {
        console.error("LA push-to-start non-200:", st, reason ?? "(no reason)",
                      f.flight_number, startRow.token.slice(0, 8));
      }
      if (tokenIsDead(st, reason)) {
        await sbService(env, "DELETE", `/live_activity_tokens?token=eq.${encodeURIComponent(startRow.token)}`);
        break;
      }
      sent[key] = now;
      sentChanged = true;
    }

    if (sentChanged) {
      await sbService(env, "PATCH", `/live_activity_tokens?token=eq.${encodeURIComponent(startRow.token)}`, {
        last_state: { sent },
        updated_at: new Date().toISOString(),
      });
    }
  }
}


// ── Live share page (/s/:code) ──
//
// The share artifact for people WITHOUT the app: a full-screen cinematic
// live tracker — dark world map, glowing great-circle arc that fills in as
// the flight progresses, the plane easing along it, a ticking countdown.
// Server-rendered so iMessage unfurls it and the first paint needs no
// round-trip; afterwards the page polls /s/:code/data.

interface SharePayload {
  expired: boolean;
  sharer: string;
  flight: Record<string, any>;
}

async function loadSharePayload(env: Env, code: string): Promise<SharePayload | null> {
  const journeys = await sbSelect(env,
    `/shared_journeys?share_code=eq.${encodeURIComponent(code)}&select=flight_id,is_active,expires_at`);
  if (!journeys.length) return null;
  const j = journeys[0];
  const flights = await sbSelect(env, `/shared_flights?id=eq.${j.flight_id}&select=*`);
  if (!flights.length) return null;
  const f = flights[0];
  const profs = await sbSelect(env, `/profiles?id=eq.${f.user_id}&select=display_name`);
  const expired = !j.is_active || (j.expires_at ? Date.parse(j.expires_at) < Date.now() : false);
  const offBlock = Date.parse(f.scheduled_departure) + ((f.delay_minutes as number) || 0) * 60_000;
  const taxiPrior = ((f.mode as string) ?? "air") === "air"
    ? (await taxiPriorFor(env, String(f.departure_iata ?? ""), new Date(offBlock).getUTCHours())).minutes
    : 0;
  // Hand the page exactly what it renders — never the raw row (user_id etc.).
  return {
    expired,
    sharer: profs[0]?.display_name || "",
    flight: {
      number: f.flight_number, airline: f.airline, status: f.status,
      // Post-012 columns, defaulted for rows written before the migration.
      mode: (f.mode as string) ?? "air",
      dataTier: (f.data_tier as string) ?? "live",
      vessel: f.vessel_name ?? null,
      note: f.disruption_note ?? null,
      delay: f.delay_minutes || 0, aircraft: f.aircraft_type,
      // The newer of "someone changed this" and "the cron verified this". A
      // stable cruising flight changes nothing for hours, and reporting only
      // the former is why this page could say "9h ago" about a row the server
      // had confirmed a minute earlier.
      progress: f.progress || 0, updated: laterISO(f.updated_at, f.checked_at),
      live: (f.live_lat != null && f.live_lon != null) ? { lat: f.live_lat, lon: f.live_lon } : null,
      // What the aircraft itself was last seen doing (cron ADS-B watch), and
      // the grace the page gives a departure before presuming wheels-up.
      ground: { state: f.ground_state ?? null, observedAt: f.ground_observed_at ?? null,
                taxiStartedAt: f.taxi_started_at ?? null },
      taxiPrior,
      dep: {
        iata: f.departure_iata, city: f.departure_city,
        lat: f.departure_lat, lon: f.departure_lon,
        gate: f.departure_gate, terminal: f.departure_terminal,
        scheduled: f.scheduled_departure, actual: f.actual_departure,
        estTakeoff: f.est_takeoff ?? null,
      },
      arr: {
        iata: f.arrival_iata, city: f.arrival_city,
        lat: f.arrival_lat, lon: f.arrival_lon,
        gate: f.arrival_gate, terminal: f.arrival_terminal, belt: f.baggage_claim,
        scheduled: f.scheduled_arrival, estimated: f.estimated_arrival, actual: f.actual_arrival,
      },
    },
  };
}

function escHTML(s: unknown): string {
  return String(s ?? "").replace(/[&<>"']/g, c =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

function sharePageHTML(code: string, payload: SharePayload | null): string {
  if (!payload) {
    return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Arc — Journey not found</title>
<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#06080f;color:#e8eefc;font-family:-apple-system,system-ui,sans-serif;text-align:center;padding:24px}
.c{max-width:340px}.p{font-size:44px;margin-bottom:14px}h1{font-size:20px;font-weight:800;margin:0 0 8px}p{font-size:14px;opacity:.55;line-height:1.5;margin:0}</style></head>
<body><div class="c"><div class="p">🌙</div><h1>This journey isn't in the sky anymore.</h1>
<p>Links shared from Arc expire 48 hours after they were last shared.</p></div></body></html>`;
  }

  const f = payload.flight;
  const sharer = payload.sharer || "Someone";
  // The share page speaks the leg's own vocabulary — migration 012's header
  // names this exact page as the reason `mode` rides along with the row.
  const mode = (f.mode as string) ?? "air";
  const verb = mode === "sea" ? "is sailing" : mode === "rail" ? "is riding" : "is flying";
  const inTransitLabel = mode === "sea" ? "At sea" : mode === "rail" ? "En route" : "In flight";
  const arrivedLabel = mode === "air" ? "Landed" : "Arrived";
  // Only a live tier may claim punctuality; a timetable-only sailing names
  // its source instead of wearing a green "On time".
  const punctual = ((f.dataTier as string) ?? "live") === "live";
  const vehicleSVGPath = mode === "sea"
    // Simple hull-and-cabin ferry glyph.
    ? "M4 10h16l-2 6H6l-2-6zm4-4h8v3H8V6zm-1 12c1 .8 2 .8 3 0s2-.8 3 0 2 .8 3 0 2-.8 3 0v2c-1 .8-2 .8-3 0s-2-.8-3 0-2 .8-3 0-2-.8-3 0-2 .8-3 0v-2c1-.8 2-.8 3 0z"
    : mode === "rail"
    // Simple tram-front glyph.
    ? "M7 3h10c1.1 0 2 .9 2 2v9c0 1.1-.9 2-2 2h-1l2 3h-2l-2-3H10l-2 3H6l2-3H7c-1.1 0-2-.9-2-2V5c0-1.1.9-2 2-2zm0 3v4h10V6H7zm1.5 7.5c.83 0 1.5-.67 1.5-1.5S9.33 10.5 8.5 10.5 7 11.17 7 12s.67 1.5 1.5 1.5zm7 0c.83 0 1.5-.67 1.5-1.5s-.67-1.5-1.5-1.5-1.5.67-1.5 1.5.67 1.5 1.5 1.5z"
    : "M21.5 15.5v-2l-8-5v-5c0-.83-.67-1.5-1.5-1.5S10.5 2.67 10.5 3.5v5l-8 5v2l8-2.5v5.5l-2 1.5v1.5l3.5-1 3.5 1V20l-2-1.5V13l8 2.5z";
  const title = `${escHTML(sharer)} ${verb} ${escHTML(f.dep.iata)} → ${escHTML(f.arr.iata)}`;
  const desc = `${escHTML(f.airline)} ${escHTML(f.number)} · ${escHTML(f.dep.city)} to ${escHTML(f.arr.city)} · live on Arc`;

  return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>${title}</title>
<meta property="og:title" content="${title}">
<meta property="og:description" content="${desc}">
<meta property="og:type" content="website">
<meta name="theme-color" content="#06080f">
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
*{margin:0;padding:0;box-sizing:border-box}
html,body{height:100%}
body{background:#06080f;color:#e8eefc;font-family:-apple-system,system-ui,sans-serif;overflow:hidden}
#map{position:fixed;inset:0;background:#06080f}
.leaflet-container{background:#06080f;font:inherit}
.vignette{position:fixed;inset:0;pointer-events:none;z-index:500;
  background:radial-gradient(120% 90% at 50% 40%,transparent 55%,rgba(3,5,10,.72) 100%),
             linear-gradient(180deg,rgba(3,5,10,.78),transparent 22%),
             linear-gradient(0deg,rgba(3,5,10,.9) 0%,transparent 42%)}
.hud{position:fixed;left:0;right:0;z-index:600;display:flex;flex-direction:column;align-items:center;
  padding-left:max(18px,env(safe-area-inset-left));padding-right:max(18px,env(safe-area-inset-right))}
.hud.top{top:0;padding-top:max(22px,env(safe-area-inset-top))}
.eyebrow{font-size:11px;font-weight:800;letter-spacing:.22em;color:#8fb8dd;text-transform:uppercase}
.title{font-size:clamp(22px,6vw,30px);font-weight:800;letter-spacing:-.02em;margin-top:6px;text-align:center;
  text-shadow:0 2px 24px rgba(0,0,0,.8)}
.chip-row{display:flex;gap:8px;margin-top:10px}
.chip{font-size:11px;font-weight:800;letter-spacing:.08em;padding:5px 11px;border-radius:999px;
  background:rgba(53,208,255,.14);color:#6fe0ff;border:1px solid rgba(111,224,255,.25)}
.chip.late{background:rgba(255,69,58,.16);color:#ff8078;border-color:rgba(255,99,89,.3)}
.chip.ok{background:rgba(48,209,88,.14);color:#5be08a;border-color:rgba(91,224,138,.25)}
.chip.ghost{background:rgba(255,255,255,.07);color:#c7d5ea;border-color:rgba(255,255,255,.12)}
.hud.bottom{bottom:0;padding-bottom:max(18px,env(safe-area-inset-bottom))}
.card{width:min(430px,100%);border-radius:22px;padding:18px 20px 14px;
  background:rgba(9,13,22,.62);border:1px solid rgba(140,180,230,.14);
  backdrop-filter:blur(22px) saturate(1.4);-webkit-backdrop-filter:blur(22px) saturate(1.4);
  box-shadow:0 18px 60px rgba(0,0,0,.55)}
.count-label{font-size:11px;font-weight:800;letter-spacing:.22em;color:#8fb8dd;text-align:center;text-transform:uppercase}
.count{font-size:clamp(40px,12vw,58px);font-weight:800;letter-spacing:-.01em;text-align:center;line-height:1.15;
  font-variant-numeric:tabular-nums;
  background:linear-gradient(180deg,#fff,#8fd8ff);-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent}
.route-row{display:flex;align-items:center;gap:12px;margin-top:10px}
.ep{flex:1}.ep.right{text-align:right}
.iata{font-size:20px;font-weight:800}
.t{font-size:14px;font-weight:700;color:#6fe0ff;font-variant-numeric:tabular-nums}
.t.late{color:#ff8078}
.sub{font-size:11px;color:#7e8ba3;margin-top:1px}
.mid{flex:1.3;position:relative;height:22px}
.bar{position:absolute;left:0;right:0;top:10px;height:3px;border-radius:2px;background:rgba(140,180,230,.18)}
.bar i{display:block;height:100%;width:0;border-radius:2px;background:linear-gradient(90deg,#35d0ff,#6fe0ff);
  box-shadow:0 0 12px rgba(53,208,255,.8);transition:width 1s linear}
.mid svg{position:absolute;top:-1px;left:0;transform:translateX(-50%);transition:left 1s linear;
  filter:drop-shadow(0 0 6px rgba(111,224,255,.9))}
.facts{display:flex;flex-wrap:wrap;gap:6px;justify-content:center;margin-top:12px}
.fact{font-size:11px;font-weight:700;color:#c7d5ea;background:rgba(255,255,255,.06);
  border:1px solid rgba(255,255,255,.09);padding:4px 10px;border-radius:999px}
.fact b{color:#ffd60a}
.brand{margin-top:12px;text-align:center;font-size:10px;letter-spacing:.18em;color:#5a6880;text-transform:uppercase}
.brand b{color:#8fb8dd}
.ribbon{position:fixed;top:0;left:0;right:0;z-index:700;text-align:center;font-size:11px;font-weight:800;
  letter-spacing:.12em;padding:6px;background:rgba(255,159,10,.92);color:#1a1204;text-transform:uppercase}
.plane-halo{position:relative}
.plane-halo::before{content:"";position:absolute;inset:-9px;border-radius:50%;
  background:radial-gradient(circle,rgba(111,224,255,.35),transparent 70%);animation:pulse 2.4s ease-in-out infinite}
@keyframes pulse{0%,100%{transform:scale(.8);opacity:.5}50%{transform:scale(1.25);opacity:1}}
.ap-label{background:none;border:none;box-shadow:none;color:#c7d5ea;font-size:11px;font-weight:800;letter-spacing:.06em;
  text-shadow:0 1px 8px rgba(0,0,0,.9)}
.leaflet-control-attribution{background:rgba(6,8,15,.55)!important;color:#5a6880!important;font-size:9px!important}
.leaflet-control-attribution a{color:#7e8ba3!important}
</style></head><body>
<div id="map"></div><div class="vignette"></div>
<div class="ribbon" id="ribbon" hidden>Link expired — last known state</div>
<header class="hud top">
  <div class="eyebrow" id="eyebrow"></div>
  <div class="title" id="title"></div>
  <div class="chip-row"><span class="chip" id="status-chip"></span><span class="chip ghost" id="flight-chip"></span></div>
</header>
<footer class="hud bottom"><div class="card">
  <div class="count-label" id="count-label"></div>
  <div class="count" id="count">—</div>
  <div class="route-row">
    <div class="ep"><div class="iata" id="dep-iata"></div><div class="t" id="dep-time"></div><div class="sub" id="dep-sub"></div></div>
    <div class="mid">
      <svg id="bar-plane" width="20" height="20" viewBox="0 0 24 24" fill="#6fe0ff"><path d="${vehicleSVGPath}"/></svg>
      <div class="bar"><i id="bar-fill"></i></div>
    </div>
    <div class="ep right"><div class="iata" id="arr-iata"></div><div class="t" id="arr-time"></div><div class="sub" id="arr-sub"></div></div>
  </div>
  <div class="facts" id="facts"></div>
  <div class="brand">Live from <b>Arc</b> · <span id="updated"></span></div>
</div></footer>
<script>
var D=${JSON.stringify(payload).replace(/</g, "\\u003c")};
var CODE=${JSON.stringify(code).replace(/</g, "\\u003c")};
var N=160;

function P(s){return s?Date.parse(s):null}
function depT(){var f=D.flight;return P(f.dep.actual)||((P(f.dep.scheduled)||0)+(f.delay||0)*60000)}
function arrT(){var f=D.flight;return P(f.arr.actual)||P(f.arr.estimated)||((P(f.arr.scheduled)||0)+(f.delay||0)*60000)}
// Mirror of the app's DepartureEvidence: "has it left?" from evidence, not
// the clock. Off-block is the airline's number; wheels-up is what the page
// waits for — the aircraft seen airborne, or a confirmed departure. Until
// the expected wheels-up (off-block + the airport's taxi-out, the provider's
// own estimate, or a taxi-out after the last on-ground sighting) it says
// Departing/Taxiing; after it, with no confirmation, it only *presumes*.
var PRE=['scheduled','boarding','gateClosed'];
function offBlockT(){var f=D.flight;return (P(f.dep.scheduled)||0)+(f.delay||0)*60000}
function lastOnGroundT(){
  var f=D.flight,g=f.ground||{},t=0;
  if(g.state&&g.state!=='airborne'&&g.observedAt)t=Math.max(t,P(g.observedAt)||0);
  if(PRE.indexOf(f.status)>=0&&!f.dep.actual&&f.updated)t=Math.max(t,P(f.updated)||0);
  return t;
}
// 90 minutes past off-block, the hedge stops. Without this the slide below
// re-anchors on every row update, so a flight the provider never confirms
// stays "Departing" for ever and this page can never reach "Presumed
// airborne" at all — the mirror image of the bug the whole feature exists to
// prevent. Mirrors DepartureEvidence.hardCap / .freshWindow.
var HARD_CAP=90*60000,FRESH=15*60000;
function wheelsUpT(){
  var f=D.flight,prior=(f.taxiPrior||0)*60000,lg=lastOnGroundT();
  return Math.max(offBlockT()+prior,P(f.dep.estTakeoff)||0,
                  lg?Math.min(lg+prior,offBlockT()+HARD_CAP):0);
}
function depPhase(){
  var f=D.flight,now=Date.now(),g=f.ground||{},dep=P(f.dep.actual);
  var fresh=g.observedAt&&(now-P(g.observedAt))<FRESH&&P(g.observedAt)<=now;
  // A confirmation that hasn't happened yet is a filing, not a fact — and a
  // sighting older than the fresh window says nothing about now.
  if((dep&&dep<=now)||(fresh&&g.state==='airborne'))return 'airborne';
  if(now<offBlockT())return 'before';
  if(fresh&&g.state==='taxiing')return 'taxiing';
  // Once it has started rolling, a pause is still the taxi: most of a
  // 35-minute taxi at a busy hub is spent stopped in the queue, and
  // flickering between Taxiing and Departing on every hold is worse.
  if(fresh&&g.state==='at_gate')return g.taxiStartedAt?'taxiing':'departing';
  return now<wheelsUpT()?'departing':'presumed';
}
function phase(){
  var f=D.flight,now=Date.now();
  if(f.status==='cancelled')return 'cancelled';
  if(f.status==='landed')return 'landed';
  var d=depPhase();
  if(d==='before')return 'pre';
  if(d==='departing'||d==='taxiing'||d==='presumed')return d;
  return now>=arrT()?'landing':'air';
}
function prog(){
  var ph=phase();
  if(ph==='pre'||ph==='departing'||ph==='taxiing')return 0;
  if(ph==='landed')return 1;
  var d=depT(),a=arrT();
  if(!d||!a||a<=d)return D.flight.progress||0;
  return Math.min(1,Math.max(0,(Date.now()-d)/(a-d)));
}

// Great circle with antimeridian unwrap.
function gc(a,b,n){
  var R=Math.PI/180,G=180/Math.PI;
  var p1=a[0]*R,l1=a[1]*R,p2=b[0]*R,l2=b[1]*R;
  var d=2*Math.asin(Math.sqrt(Math.pow(Math.sin((p2-p1)/2),2)+Math.cos(p1)*Math.cos(p2)*Math.pow(Math.sin((l2-l1)/2),2)));
  var pts=[];
  for(var i=0;i<=n;i++){
    var t=i/n;
    if(d<1e-8){pts.push([a[0]+(b[0]-a[0])*t,a[1]+(b[1]-a[1])*t]);continue}
    var A=Math.sin((1-t)*d)/Math.sin(d),B=Math.sin(t*d)/Math.sin(d);
    var x=A*Math.cos(p1)*Math.cos(l1)+B*Math.cos(p2)*Math.cos(l2);
    var y=A*Math.cos(p1)*Math.sin(l1)+B*Math.cos(p2)*Math.sin(l2);
    var z=A*Math.sin(p1)+B*Math.sin(p2);
    pts.push([Math.atan2(z,Math.sqrt(x*x+y*y))*G,Math.atan2(y,x)*G]);
  }
  for(var i=1;i<pts.length;i++){
    while(pts[i][1]-pts[i-1][1]>180)pts[i][1]-=360;
    while(pts[i][1]-pts[i-1][1]<-180)pts[i][1]+=360;
  }
  return pts;
}
function bearing(a,b){
  var R=Math.PI/180;
  var y=Math.sin((b[1]-a[1])*R)*Math.cos(b[0]*R);
  var x=Math.cos(a[0]*R)*Math.sin(b[0]*R)-Math.sin(a[0]*R)*Math.cos(b[0]*R)*Math.cos((b[1]-a[1])*R);
  return Math.atan2(y,x)*180/Math.PI;
}

var f=D.flight;
var A=[f.dep.lat,f.dep.lon],B=[f.arr.lat,f.arr.lon];
var PTS=gc(A,B,N);

var map=L.map('map',{zoomControl:false,attributionControl:true});
L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
  {attribution:'&copy; OpenStreetMap &copy; CARTO',maxZoom:12}).addTo(map);
map.fitBounds(L.latLngBounds(PTS),{paddingTopLeft:[40,120],paddingBottomRight:[40,290]});

// Route layers: dim dashed full path, then the flown part as glow + crisp.
L.polyline(PTS,{color:'#3a648c',weight:2,opacity:.95,dashArray:'1 4',lineCap:'round'}).addTo(map);
var glow=L.polyline([],{color:'#35d0ff',weight:9,opacity:.2,lineCap:'round'}).addTo(map);
var crisp=L.polyline([],{color:'#6fe0ff',weight:2.5,opacity:.95,lineCap:'round'}).addTo(map);

// divIcon's html IS innerHTML, and the IATA labels come from client-written
// rows — the same reason renderStatic escapes gate/terminal/belt below.
function esc(s){return String(s).replace(/[&<>"']/g,function(c){return '&#'+c.charCodeAt(0)+';'})}
function apDot(ll,label,side){
  L.circleMarker(ll,{radius:4,color:'#9fd4ff',weight:2,fillColor:'#06080f',fillOpacity:1}).addTo(map);
  L.marker(ll,{icon:L.divIcon({className:'ap-label',html:esc(label),iconAnchor:side==='r'?[-8,7]:[38,7]}),interactive:false}).addTo(map);
}
apDot(A,f.dep.iata,'l');apDot(B,f.arr.iata,'r');

var planeIcon=L.divIcon({className:'',iconSize:[26,26],iconAnchor:[13,13],
  html:'<div class="plane-halo"><svg id="plane-svg" width="26" height="26" viewBox="0 0 24 24" fill="#eaf7ff" style="filter:drop-shadow(0 0 5px rgba(111,224,255,.95))"><path d="${vehicleSVGPath}"/></svg></div>'});
var plane=L.marker(PTS[0],{icon:planeIcon,interactive:false}).addTo(map);

function fmtT(ms){
  if(!ms)return '—';
  return new Intl.DateTimeFormat(undefined,{hour:'2-digit',minute:'2-digit'}).format(new Date(ms));
}
function fmtDur(ms){
  var s=Math.max(0,Math.round(ms/1000));
  var h=Math.floor(s/3600),m=Math.floor(s%3600/60),ss=s%60;
  if(h>0)return h+':'+String(m).padStart(2,'0')+':'+String(ss).padStart(2,'0');
  return m+':'+String(ss).padStart(2,'0');
}

function renderStatic(){
  var f=D.flight;
  document.getElementById('eyebrow').textContent=(D.sharer||'Someone')+' ${verb}';
  document.getElementById('title').textContent=(f.dep.city||f.dep.iata)+' to '+(f.arr.city||f.arr.iata);
  document.getElementById('flight-chip').textContent=f.airline+' '+f.number;
  document.getElementById('dep-iata').textContent=f.dep.iata;
  document.getElementById('arr-iata').textContent=f.arr.iata;
  document.getElementById('dep-sub').textContent='Departure · your time';
  document.getElementById('arr-sub').textContent='Arrival · your time';
  var dt=document.getElementById('dep-time'),at=document.getElementById('arr-time');
  dt.textContent=fmtT(depT());at.textContent=fmtT(arrT());
  dt.className='t'+(f.delay>0?' late':'');at.className='t'+(f.delay>0?' late':'');
  // Escape data before it meets innerHTML — these strings come from
  // client-written rows, and this page is meant to be sent to strangers.
  var E=function(s){return String(s).replace(/[&<>"']/g,function(c){return '&#'+c.charCodeAt(0)+';'})};
  var facts=[];
  if(f.dep.gate)facts.push('Gate <b>'+E(f.dep.gate)+'</b>');
  if(f.dep.terminal)facts.push('Terminal <b>'+E(f.dep.terminal)+'</b>');
  if(f.arr.belt)facts.push('Belt <b>'+E(f.arr.belt)+'</b>');
  if(f.aircraft)facts.push(E(f.aircraft));
  if(f.delay>0)facts.push('<b>+'+(+f.delay||0)+' min</b>');
  document.getElementById('facts').innerHTML=facts.map(function(x){return '<div class="fact">'+x+'</div>'}).join('');
  if(D.expired)document.getElementById('ribbon').hidden=false;
}

function tick(){
  var f=D.flight,ph=phase(),p=prog();
  var chip=document.getElementById('status-chip'),cl=document.getElementById('count-label'),c=document.getElementById('count');
  if(ph==='pre'){chip.textContent=${punctual}?(f.delay>0?'Delayed':'On time'):'Timetable';chip.className='chip '+(${punctual}?(f.delay>0?'late':'ok'):'ghost');
    cl.textContent='Departs in';c.textContent=fmtDur(depT()-Date.now());}
  else if(ph==='departing'){chip.textContent='Departing';chip.className='chip ghost';
    cl.textContent='${mode === "air" ? "Takeoff" : "Departure"}';c.textContent='Not yet confirmed';}
  else if(ph==='taxiing'){var ts=P((f.ground||{}).taxiStartedAt)||offBlockT();
    chip.textContent='Taxiing';chip.className='chip ghost';
    cl.textContent='Taxiing for';c.textContent=fmtDur(Date.now()-ts);}
  else if(ph==='presumed'){chip.textContent='Presumed airborne';chip.className='chip ghost';
    cl.textContent='${mode === "air" ? "Landing in" : "Arriving in"}';c.textContent=fmtDur(arrT()-Date.now());}
  else if(ph==='air'){chip.textContent='${inTransitLabel}';chip.className='chip';
    cl.textContent='${mode === "air" ? "Landing in" : "Arriving in"}';c.textContent=fmtDur(arrT()-Date.now());}
  else if(ph==='landing'){chip.textContent='${mode === "air" ? "Landing soon" : "Arriving soon"}';chip.className='chip';
    cl.textContent='Arrival';c.textContent='Any moment';}
  else if(ph==='landed'){chip.textContent='${arrivedLabel}';chip.className='chip ok';
    cl.textContent='${arrivedLabel}';
    var ago=Date.now()-arrT();
    c.textContent=ago>0&&ago<6*3600000?Math.max(1,Math.round(ago/60000))+' min ago':fmtT(arrT());}
  else{chip.textContent='Cancelled';chip.className='chip late';cl.textContent='Status';c.textContent='Cancelled';}

  // Plane + flown path. Live ADS-B position wins when it's fresh (<15 min).
  var idx=Math.max(0,Math.min(N,Math.round(p*N)));
  var tip=PTS[idx];
  var liveFresh=f.live&&f.updated&&(Date.now()-Date.parse(f.updated))<15*60000;
  if(liveFresh)tip=[f.live.lat,f.live.lon];
  var flown=PTS.slice(0,idx+1);if(liveFresh)flown.push(tip);
  glow.setLatLngs(flown);crisp.setLatLngs(flown);
  plane.setLatLng(tip);
  var b=bearing(PTS[Math.max(0,idx-1)],PTS[Math.min(N,idx+1)]);
  var svg=document.getElementById('plane-svg');
  if(svg&&${mode === "air" ? "true" : "false"})svg.style.transform='rotate('+b+'deg)';
  var grounded=ph==='pre'||ph==='departing'||ph==='taxiing';
  plane.setOpacity(grounded&&!liveFresh?0:1);
  document.getElementById('bar-fill').style.width=(p*100)+'%';
  document.getElementById('bar-plane').style.left=(p*100)+'%';
  document.getElementById('bar-plane').style.opacity=grounded?0:1;
  var upd=document.getElementById('updated');
  upd.textContent=f.updated?('updated '+fmtT(Date.parse(f.updated))):'';
}

renderStatic();tick();
setInterval(tick,1000);
if(!D.expired){
  setInterval(function(){
    fetch('/s/'+CODE+'/data').then(function(r){return r.ok?r.json():null}).then(function(d){
      if(d&&d.flight){D=d;f=D.flight;renderStatic();}
    }).catch(function(){});
  },45000);
}
</script></body></html>`;
}

// ── Friend-invite landing page (/f/:code) ──
//
// What a recipient WITHOUT the app sees. Mirrors the in-app intro artwork
// (globe + avatar bubbles with live pills) in pure CSS, then hands off to
// the app via the arc:// scheme.

function invitePageHTML(code: string, inviterName: string | null, expired: boolean): string {
  const name = inviterName ? escHTML(inviterName) : null;
  const title = !name ? "Invite not found — Arc"
    : expired ? `${name}'s invite expired — Arc`
    : `${name} wants to share flights with you — Arc`;

  const heading = !name ? "This invite doesn't exist."
    : expired ? "This invite has expired."
    : `${name} wants to share flights with you`;

  const sub = !name
    ? "The link may have been mistyped — ask your friend to send it again."
    : expired
    ? `Invite links live for 48 hours. Ask ${name} for a fresh one — it takes two taps.`
    : "Automatically see each other's upcoming flights, watch each other fly on the map, and get live updates when flights take off, land, or change. Free and private — no account, no email.";

  const initials = name ? name.split(/\s+/).map(w => w[0]).slice(0, 2).join("").toUpperCase() : "?";

  const actions = (!name || expired) ? "" : `
  <div class="steps">
    <div class="step"><span class="n">1</span>Get Arc on your iPhone <span class="dim">(ask ${name} — family TestFlight)</span></div>
    <div class="step"><span class="n">2</span>Open this invite again</div>
  </div>
  <a class="cta" href="arc://friend/${code}">Open in Arc</a>
  <div class="hint">Nothing happening? Arc isn't installed yet — do step 1 first.</div>`;

  return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>${title}</title>
<meta property="og:title" content="${heading}">
<meta property="og:description" content="Share flights live on Arc — no account needed.">
<meta name="theme-color" content="#06080f">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#06080f;color:#e8eefc;font-family:-apple-system,system-ui,sans-serif;min-height:100vh;
  display:flex;flex-direction:column;align-items:center;padding:28px 22px 40px;overflow-x:hidden}
.brand{display:flex;align-items:center;gap:9px;align-self:flex-start;margin-bottom:10px}
.mark{width:34px;height:34px;border-radius:9px;background:linear-gradient(135deg,#0a84ff,#35d0ff);
  display:flex;align-items:center;justify-content:center;font-size:17px}
.brand b{font-size:16px;letter-spacing:.24em}
.hero{position:relative;width:290px;height:250px;margin:18px 0 6px;flex-shrink:0}
.globe{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:210px;height:210px;border-radius:50%;
  background:radial-gradient(circle at 32% 28%,#1a52a6,#071a3d 72%);
  border:1px solid rgba(77,176,255,.35);box-shadow:0 24px 80px rgba(20,80,180,.45)}
.arc1,.arc2{position:absolute;border:1.5px dashed rgba(77,176,255,.55);border-radius:50%;
  width:200px;height:200px;left:50%;top:50%;clip-path:inset(0 0 62% 0)}
.arc1{transform:translate(-50%,-50%) rotate(-24deg)}
.arc2{transform:translate(-50%,-50%) rotate(38deg)}
.bub{position:absolute;display:flex;flex-direction:column;align-items:center;gap:5px}
.av{width:54px;height:54px;border-radius:50%;display:flex;align-items:center;justify-content:center;
  font-weight:800;font-size:20px;color:#fff;border:3px solid #06080f;box-shadow:0 8px 22px rgba(0,0,0,.5)}
.pill{font-size:10px;font-weight:800;letter-spacing:.06em;padding:4px 8px;border-radius:999px;white-space:nowrap}
.b1{left:8px;top:52px}.b1 .av{background:linear-gradient(135deg,#e05555,#9c2f4e)}
.b1 .pill{background:#ff453a;color:#fff}
.b2{right:6px;top:16px}.b2 .av{background:linear-gradient(135deg,#8e6ae0,#5b3fae)}
.b2 .pill{background:#ffd60a;color:#000}
.b3{left:50%;transform:translateX(-50%);bottom:0}.b3 .av{background:linear-gradient(135deg,#5f83d8,#38549e)}
.b3 .pill{background:rgba(255,255,255,.16);color:#dfe9fb}
h1{font-size:28px;font-weight:800;letter-spacing:-.02em;text-align:center;max-width:340px;margin-top:14px}
.sub{font-size:15px;line-height:1.55;color:#9aa8c2;text-align:center;max-width:340px;margin-top:12px}
.steps{margin-top:26px;display:flex;flex-direction:column;gap:12px;width:100%;max-width:340px}
.step{display:flex;align-items:center;gap:12px;font-size:15px;font-weight:600}
.step .dim{color:#6c7a94;font-weight:500}
.n{width:26px;height:26px;border-radius:50%;background:#e8eefc;color:#06080f;font-weight:800;font-size:13px;
  display:flex;align-items:center;justify-content:center;flex-shrink:0}
.cta{margin-top:24px;width:100%;max-width:340px;text-align:center;background:linear-gradient(135deg,#0a84ff,#35d0ff);
  color:#fff;text-decoration:none;font-weight:700;font-size:17px;padding:16px;border-radius:999px;
  box-shadow:0 10px 30px rgba(10,132,255,.35)}
.hint{margin-top:14px;font-size:12px;color:#6c7a94;text-align:center}
.foot{margin-top:auto;padding-top:30px;font-size:10px;letter-spacing:.18em;color:#4c5a74;text-transform:uppercase}
</style></head><body>
<div class="brand"><div class="mark">✈️</div><b>ARC</b></div>
<div class="hero">
  <div class="globe"></div><div class="arc1"></div><div class="arc2"></div>
  <div class="bub b1"><div class="av">M</div><div class="pill">⚠ DELAYED</div></div>
  <div class="bub b2"><div class="av">J</div><div class="pill">✈ LANDED</div></div>
  <div class="bub b3"><div class="av">${initials}</div><div class="pill">✈ IN 8H 55M</div></div>
</div>
<h1>${heading}</h1>
<p class="sub">${sub}</p>
${actions}
<div class="foot">Arc · Flights, live, together</div>
</body></html>`;
}
