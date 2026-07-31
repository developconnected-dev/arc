import { apnsConfigured, sendLiveActivityPush } from "./apns";

interface Env {
  RAPIDAPI_KEY: string;          // AeroDataBox key (RapidAPI). Set via `wrangler secret put RAPIDAPI_KEY`.
  AIRLABS_KEY?: string;          // AirLabs fallback (free 1k/mo). Set via `wrangler secret put AIRLABS_KEY`.
  AVIATIONSTACK_API_KEY?: string; // legacy fallback (optional)
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string;
  // Remote Live Activity pushes — all four required before the cron does anything:
  SUPABASE_SERVICE_KEY?: string; // service-role key (token table has no anon access)
  APNS_TEAM_ID?: string;         // Apple Developer Team ID
  APNS_KEY_ID?: string;          // APNs auth key ID
  APNS_P8?: string;              // full .p8 file contents
  AI_API_KEY?: string;           // OpenAI / LLM API key for AI booking email parsing
}

const APP_BUNDLE_ID = "com.arc.flighttracker";

const ADB_HOST = "aerodatabox.p.rapidapi.com";

/// Normalise AeroDataBox time ("2026-07-20 09:15Z" / with seconds) to ISO-8601.
function toISO(s: unknown): string {
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
    status: normalizeStatus(f.status),
    dep_gate: dep.gate ?? null,
    dep_terminal: dep.terminal ?? null,
    arr_gate: arr.gate ?? null,
    arr_terminal: arr.terminal ?? null,
    arr_baggage: arr.baggageBelt ?? null,
    delay: delayMinutes(depSched, depRev),
    dep_actual: depRev !== depSched ? toISO(depRev) : null,
    arr_actual: arrRev !== arrSched ? toISO(arrRev) : null,
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
  candidates: string[];
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
      model: "claude-sonnet-5",
      max_tokens: 800,
      thinking: { type: "disabled" },
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
              candidates: {
                type: "array",
                items: { type: "string" },
                description: "Up to 6 IATA flight numbers of real scheduled nonstop services that likely match: flights serving the named route, or the operating flight behind a codeshare marketing number in the query. Empty if unsure.",
              },
            },
            required: ["flights", "dep_iata", "arr_iata", "date", "candidates"],
            additionalProperties: false,
          },
        },
      },
      system: `You turn a flight-search query into structured search terms. Today's date is ${new Date().toISOString().slice(0, 10)}. The query may be a flight number, a codeshare marketing number, a route in city or airport names, free text, or a pasted booking confirmation. Resolve cities to IATA airport codes. When the year is missing, pick the next occurrence of the date from today. For routes, list the well-known nonstop flight numbers serving them in candidates; for a codeshare-looking number (an airline code with a number that airline doesn't operate itself on any plausible route), list the likely operating flight numbers — and when you are CONFIDENT which route that marketing number serves, also fill dep_iata and arr_iata so the route can be searched directly. Never guess a route you are unsure of: flight-number candidates get filtered against the route, but a wrong route itself would surface real flights the user never asked about.`,
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

/// Resolve a flight number AirLabs' schedule DB knows — crucially including
/// codeshare marketing numbers (A31653), which no other source indexes.
/// Returns the operating number + route so the normal ADB verification can
/// take over. Tries the number as marketing (cs_flight_iata) first, then as
/// its own flight. Quota-guarded like the route lookup.
async function airlabsNumberSchedules(
  number: string, env: Env
): Promise<{ operating: string; dep: string; arr: string }[]> {
  if (!env.AIRLABS_KEY || Date.now() < airlabsDeadUntil) return [];
  const clean = number.replace(/\s+/g, "");
  for (const param of ["cs_flight_iata", "flight_iata"]) {
    try {
      const res = await fetch(
        `https://airlabs.co/api/v9/schedules?${param}=${encodeURIComponent(clean)}&api_key=${env.AIRLABS_KEY}`
      );
      if (!res.ok) continue;
      const data = await res.json() as { response?: Array<Record<string, any>>; error?: unknown };
      if (data.error) { airlabsDeadUntil = Date.now() + 6 * 3600_000; return []; }
      const rows = (data.response ?? [])
        .map(r => ({
          operating: String(r.flight_iata ?? ""),
          dep: String(r.dep_iata ?? "").toUpperCase(),
          arr: String(r.arr_iata ?? "").toUpperCase(),
        }))
        .filter(r => r.operating && r.dep && r.arr);
      if (rows.length) return rows;
    } catch { /* try the next param */ }
  }
  return [];
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

    if (url.pathname === "/health") {
      const budget = env.SUPABASE_SERVICE_KEY ? await budgetRow(env) : null;
      return Response.json({
        ok: true,
        providers: {
          aerodatabox: !!env.RAPIDAPI_KEY,
          airlabs: !!env.AIRLABS_KEY,
          opensky: true,
          waitport: true,
        },
        budget: budget ? {
          month: budget.month,
          adb_used: `${(budget.adb_cron ?? 0) + (budget.adb_interactive ?? 0)}/${ADB_MONTHLY_CALLS}`,
          adb_cron: `${budget.adb_cron}/${Math.floor(ADB_MONTHLY_CALLS * ADB_CRON_SHARE)}`,
          // What RapidAPI itself last reported — the authority, unlike our count.
          adb_remaining_per_rapidapi: budget.adb_remaining ?? null,
          airlabs: `${budget.airlabs_calls}/${AIRLABS_BUDGET}`,
        } : null,
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
              model: "claude-sonnet-5",
              max_tokens: 1000,
              // Extraction needs no reasoning pass; on this model thinking is
              // on by default and would eat into max_tokens.
              thinking: { type: "disabled" },
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
      try {
        const body = await req.json<{ query?: string; dep_iata?: string; arr_iata?: string; date?: string }>() ?? {};
        const query = (body.query ?? "").trim();
        if (!query) return Response.json({ error: "Empty query" }, { status: 400, headers: cors });

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
            return Response.json({ error: "AI search not configured" }, { status: 503, headers: cors });
          }
          parsed = await aiParseFlightQuery(query, env);
        }
        timings["parse"] = Date.now() - t0;
        if (!parsed) return Response.json({ flights: [] }, { headers: cors });

        const today = new Date().toISOString().slice(0, 10);
        const defaultDay = parsed.date || today;
        let route = parsed.dep_iata && parsed.arr_iata
          ? { dep: parsed.dep_iata.toUpperCase(), arr: parsed.arr_iata.toUpperCase() }
          : null;

        // A typed number with no route to anchor it: AirLabs' schedule DB is
        // the one source that maps codeshare marketing numbers (A31653) to
        // the operating flight + route. One quota-guarded call, only in
        // exactly this corner; the route it yields feeds board discovery
        // and filters verification like any other.
        const resolvedOperating: { number: string; date: string }[] = [];
        if (!route) {
          for (const f of (parsed.flights ?? []).slice(0, 2)) {
            const rows = await airlabsNumberSchedules(f.number, env);
            if (rows.length) {
              route = { dep: rows[0].dep, arr: rows[0].arr };
              for (const r of rows) resolvedOperating.push({ number: r.operating, date: f.date || defaultDay });
              break;
            }
          }
        }

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
        for (const r of resolvedOperating) push(r.number, r.date);
        if (route) {
          // Real data first: the departure board names the route's flights
          // (including codeshare marketing numbers); AirLabs adds rows when
          // its quota allows. The AI's own guesses come last — they're the
          // weakest source and exist only as a fallback.
          const [discovery, airlabsRows] = await Promise.all([
            adbRouteDiscovery(env, route.dep, route.arr, defaultDay),
            airlabsRouteSchedules(route.dep, route.arr, env),
          ]);
          // A queried number that shows on the board as a codeshare row maps
          // to its operating flight via the rows sharing its movement —
          // that's how "A31653" (indexed nowhere) becomes LH1757. Those
          // siblings outrank plain route discovery.
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
        const preRows = capped.length
          ? await sbSelect(env, `/flight_cache?key=in.(${capped.map(c => encodeURIComponent(keyOf(c))).join(",")})&select=*`)
          : [];
        const preByKey = new Map(preRows.map(r => [String(r["key"]), r]));
        // AeroDataBox rate-limits per second: even a 4-wide burst drew 429s,
        // and each 429'd candidate vanished from that search only — identical
        // searches grew result by result as stragglers finally cached. So:
        // serial, pacing only the calls that actually hit the provider
        // (cache hits pass instantly; a warm search stays fast).
        const verified: { c: { number: string; date: string }; legs: Record<string, unknown>[] }[] = [];
        let retriesLeft = 4;
        let paceNeeded = false;
        for (const c of capped) {
          if (paceNeeded) await new Promise((r) => setTimeout(r, 1000));
          const pre = preByKey.get(keyOf(c)) ?? null;
          let r = await fetchLegsCached(env, "flight", c.number, c.date, "interactive", pre);
          paceNeeded = r.cache !== "hit";
          if (r.legs === null && retriesLeft-- > 0) {
            await new Promise((r2) => setTimeout(r2, 2500));
            r = await fetchLegsCached(env, "flight", c.number, c.date, "interactive", null);
          }
          verified.push({ c, legs: r.legs ?? [] });
        }
        const results: Record<string, unknown>[] = [];
        for (const { c, legs } of verified) {
          for (const leg of legs) {
            if (!sameFlightDay(leg["dep_scheduled"], c.date)) continue;
            if (route && (String(leg["dep_iata"]).toUpperCase() !== route.dep
                       || String(leg["arr_iata"]).toUpperCase() !== route.arr)) continue;
            if (results.some(r => r["flight_number"] === leg["flight_number"]
                               && r["dep_scheduled"] === leg["dep_scheduled"])) continue;
            results.push(leg);
          }
        }
        if ((body as any).debug) {
          timings["verify"] = Date.now() - t0 - timings["parse"] - timings["discovery"];
          return Response.json({ flights: results, parsed, candidates, timings }, { headers: cors });
        }
        return Response.json({ flights: results }, { headers: cors });
      } catch (err: any) {
        return Response.json({ error: "Search failed", details: err?.message }, { status: 500, headers: cors });
      }
    }

    // ── /flight?number=LX1413&date=2026-07-20 ── status by flight number + date
    if (url.pathname === "/flight") {
      const number = url.searchParams.get("number");
      const date = url.searchParams.get("date");
      if (!number) return new Response("missing number", { status: 400 });

      // 1. Shared cache → AeroDataBox (budget-guarded). One answer serves
      // every family device, the cron, and share pages for its TTL.
      const day = date ?? new Date().toISOString().slice(0, 10);
      const { legs: cachedLegs, cache } = await fetchLegsCached(env, "flight", number, day, "interactive");
      if (cachedLegs && cachedLegs.length > 0) {
        return Response.json(cachedLegs, { headers: { ...cors, "x-arc-cache": cache } });
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

      return Response.json([], { headers: cors });
    }

    // ── /inbound?reg=HB-JMB&date=2026-07-20 ── previous leg of the same tail
    if (url.pathname === "/inbound") {
      const reg = url.searchParams.get("reg");
      const date = url.searchParams.get("date");
      if (!reg) return Response.json(null, { headers: cors });
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

      for (const [kind, value] of attempts) {
        try {
          const key = value.trim().replace(/\s+/g, "").toLowerCase();
          if (!key) continue;
          const res = await fetch(`https://api.airplanes.live/v2/${kind}/${encodeURIComponent(key)}`,
                                  { headers: { Accept: "application/json" } });
          if (!res.ok) continue;
          const raw = await res.json() as { ac?: Record<string, any>[] };
          const ac = (raw.ac ?? []).find(a => typeof a?.lat === "number" && typeof a?.lon === "number");
          if (!ac) continue;

          // alt_baro is feet, or the string "ground" when it's on the deck;
          // gs is knots. Our clients speak metres and m/s.
          const onGround = ac.alt_baro === "ground";
          const altFt = typeof ac.alt_baro === "number" ? ac.alt_baro : 0;
          const speedKt = typeof ac.gs === "number" ? ac.gs : 0;

          return Response.json({
            icao24: String(ac.hex ?? "").toUpperCase(),
            lat: ac.lat,
            lon: ac.lon,
            altitude: Math.round(altFt * 0.3048),
            velocity: speedKt * 0.514444,
            heading: typeof ac.track === "number" ? ac.track : 0,
            on_ground: onGround,
            registration: ac.r ?? null,
            // Seconds since the fix. A five-minute-old position matters when
            // you're watching an aircraft taxi, so don't hide it.
            age_seconds: typeof ac.seen_pos === "number" ? Math.round(ac.seen_pos) : null,
          }, { headers: cors });
        } catch { /* try the next identifier */ }
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

        const metar = metarRes?.ok ? ((await metarRes.json()) as any[])[0] : null;
        const taf = tafRes?.ok ? ((await tafRes.json()) as any[])[0] : null;

        // The forecast period that contains the departure time.
        let period: any = null;
        for (const f of (taf?.fcsts ?? []) as any[]) {
          if (f.timeFrom <= atSec && atSec < (f.timeTo ?? f.timeFrom)) { period = f; break; }
        }
        // Past the end of the TAF: fall back to its last period rather than
        // reporting nothing at all.
        if (!period && (taf?.fcsts?.length ?? 0) > 0) period = taf.fcsts[taf.fcsts.length - 1];

        return Response.json({
          ok: true,
          icao,
          now: metar ? {
            category: metar.fltCat ?? null,
            visibilityM: metersFromVisibility(metar.visib),
            ceilingFt: lowestCeiling(metar.clouds),
            windKt: numberOrNull(metar.wspd),
            gustKt: numberOrNull(metar.wgst),
            wx: metar.wxString ?? null,
            observed: metar.reportTime ?? null,
          } : null,
          atTime: period ? {
            visibilityM: metersFromVisibility(period.visib),
            ceilingFt: lowestCeiling(period.clouds),
            windKt: numberOrNull(period.wspd),
            gustKt: numberOrNull(period.wgst),
            windShear: period.wshearSpd != null,
            wx: period.wxString ?? null,
            from: period.timeFrom ?? null,
            to: period.timeTo ?? null,
          } : null,
        }, { headers: { ...cors, "cache-control": "public, max-age=300" } });
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
    if (url.pathname === "/gates/observe" && req.method === "POST") {
      if (!env.SUPABASE_SERVICE_KEY) return Response.json({ ok: false }, { headers: cors });
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
        const body = await req.json() as { token?: string; type?: string; env?: string; user_id?: string; flight?: Record<string, unknown> };
        if (!body.token || (body.type !== "update" && body.type !== "start")) {
          return new Response("bad request", { status: 400, headers: cors });
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
        const res = await sbService(env, "POST", "/live_activity_tokens?on_conflict=token", row);
        return Response.json({ ok: res.ok }, { headers: cors });
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
    if (!apnsConfigured(env) || !env.SUPABASE_SERVICE_KEY) return;
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
async function cachedFids(env: Env, key: string, ttlMs = 5 * 60_000): Promise<Record<string, any>[] | null> {
  if (!env.SUPABASE_SERVICE_KEY) return null;
  const rows = await sbSelect(env, `/flight_cache?key=eq.${encodeURIComponent(key)}&select=*`);
  const row = rows[0];
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
  const budget = await budgetRow(env);
  const remaining = budget["adb_remaining"] as number | null | undefined;
  if (typeof remaining === "number" && remaining <= 0) return empty;

  // Nearest date with the target's weekday that FIDS can still serve.
  const today = new Date(); today.setUTCHours(0, 0, 0, 0);
  const target = new Date(`${targetDate}T00:00:00Z`);
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
  for (const [from, to] of [[`${day}T00:00`, `${day}T11:59`], [`${day}T12:00`, `${day}T23:59`]]) {
    const key = `fidsdep|${depIATA}|${from.slice(0, 13)}`;
    let departures = await cachedFids(env, key, 24 * 3600_000);
    if (!departures) {
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
      const raw = await res.json() as Record<string, any>;
      departures = (raw?.departures ?? []) as Record<string, any>[];
      await storeFids(env, key, departures);
    }
    for (const d of departures) {
      const dest = String(d?.movement?.airport?.iata ?? "").toUpperCase();
      const num = String(d?.number ?? "").replace(/\s+/g, "").toUpperCase();
      if (!num || !dest) continue;
      const time = String(d?.movement?.scheduledTime?.utc ?? d?.movement?.scheduledTime?.local ?? "");
      board.push({ number: num, dest, time });
      if (dest === arrIATA.toUpperCase() && !numbers.includes(num)) numbers.push(num);
    }
  }
  return { routeNumbers: numbers, board };
}

async function storeFids(env: Env, key: string, arrivals: Record<string, any>[]): Promise<void> {
  if (!env.SUPABASE_SERVICE_KEY) return;
  await sbService(env, "POST", "/flight_cache?on_conflict=key", {
    key, payload: arrivals, provider: "adb-fids", fetched_at: new Date().toISOString(),
  });
}

function numberOrNull(v: unknown): number | null {
  return typeof v === "number" && isFinite(v) ? v : null;
}

/// METAR/TAF visibility comes as statute miles, sometimes as "6+" — normalise
/// to metres so one set of thresholds works everywhere.
function metersFromVisibility(v: unknown): number | null {
  if (typeof v === "number") return Math.round(v * 1609.34);
  if (typeof v === "string") {
    const n = parseFloat(v.replace("+", ""));
    if (!isNaN(n)) return Math.round(n * 1609.34);
  }
  return null;
}

/// Lowest broken/overcast layer — that's the operational ceiling; scattered
/// and few layers don't count.
function lowestCeiling(clouds: unknown): number | null {
  if (!Array.isArray(clouds)) return null;
  let lowest: number | null = null;
  for (const layer of clouds as Record<string, any>[]) {
    const cover = String(layer.cover ?? "").toUpperCase();
    if (cover !== "BKN" && cover !== "OVC" && cover !== "OVX") continue;
    const base = numberOrNull(layer.base);
    if (base != null && (lowest == null || base < lowest)) lowest = base;
  }
  return lowest;
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
    if (!res.ok) return null;
    const arr = await res.json() as Array<Record<string, any>>;
    const m = arr?.[0];
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
// only stop the cron early so a search always has quota behind it.
const ADB_CRON_RESERVE = 2000;
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
  const patch: Record<string, unknown> = { [field]: current + 1 };
  // RapidAPI reports what's actually left on every response. Recording it means
  // /health shows the provider's own number, not just our count of attempts —
  // the two disagreeing is exactly how a plan upgrade went unnoticed.
  const left = remaining == null ? NaN : Number(remaining);
  if (Number.isFinite(left)) patch["adb_remaining"] = left;
  if (budgetMemo) {
    budgetMemo.row[field] = current + 1;
    if (Number.isFinite(left)) budgetMemo.row["adb_remaining"] = left;
  }
  await sbService(env, "PATCH", `/api_budget?month=eq.${monthKey()}`, patch);
}

/// Phase-aware freshness: how long a cached answer stays good, judged from
/// the flight's own times. Tight only in the windows where data actually
/// moves (boarding/departure, arrival); loose in cruise and the far future.
// One payload can hold several legs of the same number (A→B→C). Freshness
// must follow the MOST demanding leg — judging by legs[0] alone froze the
// second sector's gates and delay for 24 h the moment the first one landed.
function cacheTTLms(legs: Record<string, any>[]): number {
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
    : (await sbSelect(env, `/flight_cache?key=eq.${encodeURIComponent(key)}&select=*`))[0];
  const cachedLegs = cached ? (cached.payload as Record<string, unknown>[]) : null;
  if (cached && cachedLegs) {
    const age = Date.now() - Date.parse(String(cached.fetched_at));
    // Empty payload = a cached "doesn't fly that date". For dates weeks out
    // that answer is stable — hold it 48 h so searches stop re-burning quota
    // on the same dead candidates. Near-term, re-ask soon: schedules appear.
    const depMs = Date.parse(`${date}T00:00:00Z`);
    const ttl = cachedLegs.length > 0 ? cacheTTLms(cachedLegs as Record<string, any>[])
      : (isFinite(depMs) && depMs - Date.now() > 7 * 86_400_000 ? 48 * 3600_000 : 10 * 60_000);
    if (age < ttl) {
      return { legs: cachedLegs, cache: "hit" };
    }
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
  const blocked = typeof remaining === "number"
    ? remaining <= (source === "cron" ? ADB_CRON_RESERVE : 0)
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
      const raw = res.ok ? ((await res.json()) as unknown) : [];
      const legs = (Array.isArray(raw) ? raw : []).map((l) => mapLeg(l as Record<string, any>));
      // Cache empty answers too: "doesn't fly that date" is a definitive
      // answer (10-min TTL). Without it every search re-fetched the same
      // dead candidates — burning quota and, when the re-fetch got
      // rate-limited, changing the result set from search to search.
      // Transient failures (429/5xx) fall through uncached below.
      await sbService(env, "POST", "/flight_cache?on_conflict=key", {
        key, payload: legs, provider: "adb", fetched_at: new Date().toISOString(),
      });
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
  await sbService(env, "POST", "/flight_cache?on_conflict=key", {
    key, payload: legs, provider: "airlabs", fetched_at: new Date().toISOString(),
  });
}

// ── Live Activity cron internals ──

async function sbService(env: Env, method: string, path: string, body?: unknown): Promise<Response> {
  return fetch(`${env.SUPABASE_URL}/rest/v1${path}`, {
    method,
    headers: {
      apikey: env.SUPABASE_SERVICE_KEY!,
      authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      "content-type": "application/json",
      prefer: method === "POST" ? "resolution=merge-duplicates,return=minimal" : "return=minimal",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function sbSelect(env: Env, path: string): Promise<Record<string, any>[]> {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1${path}`, {
    headers: {
      apikey: env.SUPABASE_SERVICE_KEY!,
      authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
    },
  });
  if (!res.ok) return [];
  const data = await res.json();
  return Array.isArray(data) ? data as Record<string, any>[] : [];
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

async function runLiveActivityCron(env: Env): Promise<void> {
  const rows = await sbSelect(env, "/live_activity_tokens?select=*") as unknown as TokenRow[];
  const updateRows = rows.filter(r => r.token_type === "update" && r.flight_number && r.scheduled_departure);

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
    } catch { /* keep the loop alive for other rows */ }
  }

  // Push-to-start: begin a Live Activity server-side for flights entering the
  // 3h window, even if the app hasn't been opened. Upcoming flights come from
  // user_flights (the signed-in cloud mirror); without sign-in the app's own
  // local 3h check still covers the app-was-opened-recently case.
  const startRows = rows.filter(r => r.token_type === "start");
  if (startRows.length > 0) {
    try {
      await pushStarts(env, startRows, updateRows);
    } catch { /* best-effort */ }
  }
}

/// How often the cron re-consults the provider, by flight phase. Progress
/// ticks between refreshes cost nothing — they're computed from stored
/// times. Only the windows where data really moves get tight cadence.
function cronRefreshIntervalMs(depMs: number, arrMs: number, now: number): number {
  if (now < depMs + 20 * 60_000) return 10 * 60_000;        // pre-dep + departure
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
    // A flight number can have multiple legs that day — match ours by route.
    const leg = (legs ?? []).find(l =>
      l["dep_iata"] === row.departure_iata && l["arr_iata"] === row.arrival_iata
    ) ?? (legs && legs.length > 0 ? legs[0] : null);
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
    await sbService(env, "PATCH", `/live_activity_tokens?token=eq.${encodeURIComponent(row.token)}`, {
      last_state: { ...prior, flight, fetched_at: now },
      updated_at: new Date().toISOString(),
    });
  }

  const delay: number = flight?.["delay"] ?? 0;
  const schedDepMs = new Date(row.scheduled_departure!).getTime();
  const schedArrMs = new Date(row.scheduled_arrival ?? row.scheduled_departure!).getTime();
  const depMs = flight?.["dep_actual"] ? new Date(flight["dep_actual"]).getTime() : schedDepMs + delay * 60_000;
  const arrMs = flight?.["arr_actual"] ? new Date(flight["arr_actual"]).getTime() : schedArrMs + delay * 60_000;

  // Status: provider value, then clock-healed the same way the app heals.
  let status: string = flight?.["status"] ?? "scheduled";
  if ((status === "scheduled" || status === "boarding" || status === "gateClosed") && now >= depMs) status = "active";
  if (status === "active" && now >= arrMs) status = "landed";

  // Done: final "end" push (keeps the landed card up an hour), then forget the token.
  if (now > arrMs + 45 * 60 * 1000 || status === "cancelled") {
    const endPayload = {
      aps: {
        timestamp: Math.floor(now / 1000),
        event: "end",
        "dismissal-date": Math.floor(now / 1000) + 3600,
        "content-state": contentState(status, depMs, arrMs, delay, flight),
      },
    };
    await sendLiveActivityPush(env, row.token, row.apns_env, APP_BUNDLE_ID, endPayload, 5);
    await sbService(env, "DELETE", `/live_activity_tokens?token=eq.${encodeURIComponent(row.token)}`);
    return;
  }

  // Not yet in the window where updates matter (>4h before departure): skip.
  if (now < depMs - 4 * 60 * 60 * 1000) return;

  // stale-date = next phase boundary: iOS re-renders the Live Activity once
  // when content goes stale, and that render re-evaluates the clock-based
  // phase — so the pre→during→after layout flips on time even if this was
  // the last push before the device went offline (i.e. takeoff).
  const staleAt = status === "scheduled" || status === "boarding" || status === "gateClosed"
    ? Math.floor(depMs / 1000)
    : Math.floor(Math.max(arrMs, now + 60_000) / 1000);
  const payload = {
    aps: {
      timestamp: Math.floor(now / 1000),
      event: "update",
      "stale-date": staleAt,
      "content-state": contentState(status, depMs, arrMs, delay, flight),
      ...(dataChanged && flight?.["dep_gate"] ? {
        alert: {
          title: `${row.flight_number} update`,
          body: `Gate ${flight["dep_gate"]}${delay > 0 ? ` · ${delay}m late` : ""}`,
        },
      } : {}),
    },
  };
  // Routine progress ticks every 5 minutes (they cost no provider calls —
  // progress comes from stored times); real changes push immediately at
  // priority 10. Every-minute pushes just drained the system's LA budget.
  if (!dataChanged && now - pushedAt < 5 * 60 * 1000) return;
  const st = await sendLiveActivityPush(env, row.token, row.apns_env, APP_BUNDLE_ID, payload, dataChanged ? 10 : 5);
  await sbService(env, "PATCH", `/live_activity_tokens?token=eq.${encodeURIComponent(row.token)}`, {
    last_state: { ...prior, flight, fetched_at: lastFetch, pushed_at: now },
  });
  if (st === 410 || st === 400) {
    await sbService(env, "DELETE", `/live_activity_tokens?token=eq.${encodeURIComponent(row.token)}`);
  }
}

/// Mirror of FlightActivityAttributes.ContentState — field names and types are
/// a wire contract with the app; change them together or pushes silently fail.
function contentState(
  status: string, depMs: number, arrMs: number, delay: number, flight: Record<string, any> | null
): Record<string, unknown> {
  const now = Date.now();
  const total = arrMs - depMs;
  const progress = total > 0 ? Math.min(1, Math.max(0, (now - depMs) / total)) : 0;
  return {
    status,
    departureTime: depMs / 1000 - 978307200,
    arrivalTime: arrMs / 1000 - 978307200,
    boardingTime: null,
    securityWaitMinutes: null,
    delayMinutes: delay,
    departureGate: flight?.["dep_gate"] ?? null,
    departureTerminal: flight?.["dep_terminal"] ?? null,
    arrivalGate: flight?.["arr_gate"] ?? null,
    arrivalTerminal: flight?.["arr_terminal"] ?? null,
    baggageClaim: flight?.["arr_baggage"] ?? null,
    altitude: null,
    speed: null,
    heading: null,
    progress,
  };
}

async function pushStarts(env: Env, startRows: TokenRow[], updateRows: TokenRow[]): Promise<void> {
  const now = Date.now();
  const soon = new Date(now + 3 * 60 * 60 * 1000).toISOString();
  const nowIso = new Date(now).toISOString();
  const upcoming = await sbSelect(
    env,
    `/user_flights?select=*&scheduled_departure=gte.${nowIso}&scheduled_departure=lte.${soon}&status=in.(scheduled,boarding,gateClosed)`
  );
  if (upcoming.length === 0) return;

  for (const startRow of startRows) {
    // No owner, no starts — fail closed. Cross-joining every user's flights
    // with every start token put user A's flight (seat included) on user
    // B's lock screen; a token registered before sign-in gets nothing until
    // it re-registers with its owner.
    if (!startRow.user_id) continue;
    const sent: Record<string, number> = startRow.last_state?.sent ?? {};
    let sentChanged = false;

    for (const f of upcoming.filter(u => u["user_id"] === startRow.user_id)) {
      const key = `${f.flight_number}-${String(f.scheduled_departure).slice(0, 10)}`;
      // Skip if an update token already exists for this flight (activity is
      // already running) or we already sent a start recently.
      const alreadyLive = updateRows.some(u =>
        u.flight_number === f.flight_number &&
        u.scheduled_departure?.slice(0, 10) === String(f.scheduled_departure).slice(0, 10)
      );
      if (alreadyLive || (sent[key] && now - sent[key] < 6 * 60 * 60 * 1000)) continue;

      const depMs = new Date(f.scheduled_departure).getTime() + (f.delay_minutes ?? 0) * 60_000;
      const arrMs = new Date(f.scheduled_arrival).getTime() + (f.delay_minutes ?? 0) * 60_000;
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
          },
          "content-state": contentState(f.status ?? "scheduled", depMs, arrMs, f.delay_minutes ?? 0, {
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
      const st = await sendLiveActivityPush(env, startRow.token, startRow.apns_env, APP_BUNDLE_ID, payload, 10);
      if (st === 410 || st === 400) {
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
  // Hand the page exactly what it renders — never the raw row (user_id etc.).
  return {
    expired,
    sharer: profs[0]?.display_name || "",
    flight: {
      number: f.flight_number, airline: f.airline, status: f.status,
      delay: f.delay_minutes || 0, aircraft: f.aircraft_type,
      progress: f.progress || 0, updated: f.updated_at,
      live: (f.live_lat != null && f.live_lon != null) ? { lat: f.live_lat, lon: f.live_lon } : null,
      dep: {
        iata: f.departure_iata, city: f.departure_city,
        lat: f.departure_lat, lon: f.departure_lon,
        gate: f.departure_gate, terminal: f.departure_terminal,
        scheduled: f.scheduled_departure, actual: f.actual_departure,
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
  const title = `${escHTML(sharer)} is flying ${escHTML(f.dep.iata)} → ${escHTML(f.arr.iata)}`;
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
      <svg id="bar-plane" width="20" height="20" viewBox="0 0 24 24" fill="#6fe0ff"><path d="M21.5 15.5v-2l-8-5v-5c0-.83-.67-1.5-1.5-1.5S10.5 2.67 10.5 3.5v5l-8 5v2l8-2.5v5.5l-2 1.5v1.5l3.5-1 3.5 1V20l-2-1.5V13l8 2.5z"/></svg>
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
function phase(){
  var f=D.flight,now=Date.now();
  if(f.status==='cancelled')return 'cancelled';
  if(f.status==='landed')return 'landed';
  if(f.status==='active')return now>=arrT()?'landing':'air';
  return now>=depT()?'air':'pre';   // clock heals a stale status
}
function prog(){
  var ph=phase();
  if(ph==='pre')return 0;
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

function apDot(ll,label,side){
  L.circleMarker(ll,{radius:4,color:'#9fd4ff',weight:2,fillColor:'#06080f',fillOpacity:1}).addTo(map);
  L.marker(ll,{icon:L.divIcon({className:'ap-label',html:label,iconAnchor:side==='r'?[-8,7]:[38,7]}),interactive:false}).addTo(map);
}
apDot(A,f.dep.iata,'l');apDot(B,f.arr.iata,'r');

var planeIcon=L.divIcon({className:'',iconSize:[26,26],iconAnchor:[13,13],
  html:'<div class="plane-halo"><svg id="plane-svg" width="26" height="26" viewBox="0 0 24 24" fill="#eaf7ff" style="filter:drop-shadow(0 0 5px rgba(111,224,255,.95))"><path d="M21.5 15.5v-2l-8-5v-5c0-.83-.67-1.5-1.5-1.5S10.5 2.67 10.5 3.5v5l-8 5v2l8-2.5v5.5l-2 1.5v1.5l3.5-1 3.5 1V20l-2-1.5V13l8 2.5z"/></svg></div>'});
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
  document.getElementById('eyebrow').textContent=(D.sharer||'Someone')+' is flying';
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
  if(ph==='pre'){chip.textContent=f.delay>0?'Delayed':'On time';chip.className='chip '+(f.delay>0?'late':'ok');
    cl.textContent='Departs in';c.textContent=fmtDur(depT()-Date.now());}
  else if(ph==='air'){chip.textContent='In flight';chip.className='chip';
    cl.textContent='Landing in';c.textContent=fmtDur(arrT()-Date.now());}
  else if(ph==='landing'){chip.textContent='Landing soon';chip.className='chip';
    cl.textContent='Arrival';c.textContent='Any moment';}
  else if(ph==='landed'){chip.textContent='Landed';chip.className='chip ok';
    cl.textContent='Landed';
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
  if(svg)svg.style.transform='rotate('+b+'deg)';
  plane.setOpacity(ph==='pre'?0:1);
  document.getElementById('bar-fill').style.width=(p*100)+'%';
  document.getElementById('bar-plane').style.left=(p*100)+'%';
  document.getElementById('bar-plane').style.opacity=ph==='pre'?0:1;
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
