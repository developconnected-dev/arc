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

async function airlabsFlightSearch(number: string, env: Env): Promise<Record<string, unknown>[]> {
  if (!env.AIRLABS_KEY) return [];
  const clean = number.replace(/\s+/g, "");
  const res = await fetch(
    `https://airlabs.co/api/v9/flight?flight_iata=${encodeURIComponent(clean)}&api_key=${env.AIRLABS_KEY}`
  );
  if (!res.ok) return [];
  const data = await res.json() as { response?: Record<string, any> };
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
      return Response.json({
        ok: true,
        providers: {
          aerodatabox: !!env.RAPIDAPI_KEY,
          airlabs: !!env.AIRLABS_KEY,
          opensky: true,
          waitport: true,
        }
      }, { headers: cors });
    }

    // ── /flight?number=LX1413&date=2026-07-20 ── status by flight number + date
    if (url.pathname === "/flight") {
      const number = url.searchParams.get("number");
      const date = url.searchParams.get("date");
      if (!number) return new Response("missing number", { status: 400 });

      // 1. Try AeroDataBox first (if key available and not exhausted)
      if (env.RAPIDAPI_KEY) {
        try {
          const path = `/flights/number/${encodeURIComponent(number)}${date ? `/${date}` : ""}` +
            `?withAircraftImage=false&withLocation=true`;
          const res = await adbFetch(path, env);
          if (res.ok) {
            const raw = (await res.json()) as unknown;
            const legs = Array.isArray(raw) ? raw : [];
            if (legs.length > 0) {
              return Response.json(legs.map((l) => mapLeg(l as Record<string, any>)), { headers: cors });
            }
          }
          // If 429 (rate limited) or other error, fall through to AirLabs
        } catch { /* fall through */ }
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
            return Response.json(results, { headers: cors });
          }
        } catch { /* fall through */ }
      }

      return Response.json([], { headers: cors });
    }

    // ── /inbound?reg=HB-JMB&date=2026-07-20 ── previous leg of the same tail
    if (url.pathname === "/inbound") {
      const reg = url.searchParams.get("reg");
      const date = url.searchParams.get("date");
      if (!reg || !env.RAPIDAPI_KEY) return Response.json(null, { headers: cors });
      try {
        const path = `/flights/reg/${encodeURIComponent(reg)}${date ? `/${date}` : ""}?withLocation=true`;
        const res = await adbFetch(path, env);
        if (!res.ok) return Response.json(null, { headers: cors });
        const raw = (await res.json()) as unknown;
        const legs = (Array.isArray(raw) ? raw : []).map((l) => mapLeg(l as Record<string, any>));
        // the leg immediately before the queried flight is the inbound
        return Response.json(legs, { headers: cors });
      } catch {
        return Response.json(null, { status: 502, headers: cors });
      }
    }

    // ── /position?icao24=4b1815 ── live position (OpenSky, free)
    if (url.pathname === "/position") {
      const icao24 = url.searchParams.get("icao24");
      if (!icao24) return new Response("missing icao24", { status: 400 });
      try {
        const res = await fetch(
          `https://opensky-network.org/api/states/all?icao24=${icao24.toLowerCase()}`,
          { headers: { Accept: "application/json" } }
        );
        const raw = (await res.json()) as { states?: Array<Array<unknown>> };
        if (!raw.states || raw.states.length === 0) return Response.json(null, { status: 404, headers: cors });
        const s = raw.states[0]!;
        return Response.json({
          icao24: s[0] as string,
          lat: (s[6] as number) ?? 0,
          lon: (s[5] as number) ?? 0,
          altitude: (s[7] as number) ?? 0,
          velocity: (s[9] as number) ?? 0,
          heading: (s[10] as number) ?? 0,
          on_ground: (s[8] as boolean) ?? false,
        }, { headers: cors });
      } catch {
        return Response.json(null, { status: 502, headers: cors });
      }
    }

    // ── /journey/:code ── shared journey live viewer (unchanged)
    const journeyMatch = url.pathname.match(/^\/journey\/([a-z0-9]+)$/);
    if (journeyMatch) {
      const code = journeyMatch[1];
      return new Response(sharedJourneyHTML(code, env.SUPABASE_URL, env.SUPABASE_ANON_KEY), {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
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

    // ── Live Activity push registration ──
    if (url.pathname === "/la/register" && req.method === "POST") {
      if (!env.SUPABASE_SERVICE_KEY) return Response.json({ ok: false, reason: "unconfigured" }, { headers: cors });
      try {
        const body = await req.json() as { token?: string; type?: string; env?: string; flight?: Record<string, unknown> };
        if (!body.token || (body.type !== "update" && body.type !== "start")) {
          return new Response("bad request", { status: 400, headers: cors });
        }
        const f = body.flight ?? {};
        const row: Record<string, unknown> = {
          token: body.token,
          token_type: body.type,
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

  for (const row of updateRows) {
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

async function pushUpdateForRow(env: Env, row: TokenRow): Promise<void> {
  const now = Date.now();
  const prior = row.last_state ?? {};
  let flight: Record<string, any> | null = prior.flight ?? null;
  const fetchedAt: number = prior.fetched_at ?? 0;
  let dataChanged = false;

  // Refresh provider data at most every 5 minutes per flight.
  if (env.RAPIDAPI_KEY && now - fetchedAt > 5 * 60 * 1000) {
    try {
      const day = row.scheduled_departure!.slice(0, 10);
      const res = await adbFetch(
        `/flights/number/${encodeURIComponent(row.flight_number!)}/${day}?withAircraftImage=false&withLocation=true`,
        env
      );
      if (res.ok) {
        const raw = await res.json();
        const legs = Array.isArray(raw) ? raw : [];
        // A flight number can have multiple legs that day — match ours by route.
        const leg = legs.map(l => mapLeg(l as Record<string, any>)).find(l =>
          l["dep_iata"] === row.departure_iata && l["arr_iata"] === row.arrival_iata
        ) ?? (legs.length > 0 ? mapLeg(legs[0] as Record<string, any>) : null);
        if (leg) {
          dataChanged = !!flight && (
            leg["status"] !== flight["status"] ||
            leg["delay"] !== flight["delay"] ||
            leg["dep_gate"] !== flight["dep_gate"] ||
            leg["arr_gate"] !== flight["arr_gate"] ||
            leg["arr_baggage"] !== flight["arr_baggage"]
          );
          flight = leg;
        }
      }
    } catch { /* fly on cached data */ }
    await sbService(env, "PATCH", `/live_activity_tokens?token=eq.${encodeURIComponent(row.token)}`, {
      last_state: { flight, fetched_at: now },
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

  const payload = {
    aps: {
      timestamp: Math.floor(now / 1000),
      event: "update",
      "stale-date": Math.floor(now / 1000) + 20 * 60,
      "content-state": contentState(status, depMs, arrMs, delay, flight),
      ...(dataChanged && flight?.["dep_gate"] ? {
        alert: {
          title: `${row.flight_number} update`,
          body: `Gate ${flight["dep_gate"]}${delay > 0 ? ` · ${delay}m late` : ""}`,
        },
      } : {}),
    },
  };
  // Priority 10 (immediate) only when something real changed — routine
  // progress ticks go at 5 to respect the system's update budget.
  const st = await sendLiveActivityPush(env, row.token, row.apns_env, APP_BUNDLE_ID, payload, dataChanged ? 10 : 5);
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
    const sent: Record<string, number> = startRow.last_state?.sent ?? {};
    let sentChanged = false;

    for (const f of upcoming) {
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

function sharedJourneyHTML(code: string, supabaseUrl: string, anonKey: string): string {
  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Arc — Live Flight</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { background:#f2f2f7; color:#000; font-family:-apple-system,system-ui,sans-serif; min-height:100vh; display:flex; flex-direction:column; align-items:center; justify-content:center; padding:24px; }
  @media (prefers-color-scheme: dark){ body{ background:#000; color:#fff; } .card{ background:#1c1c1e !important; } }
  .card { background:#fff; border-radius:20px; padding:32px; max-width:420px; width:100%; box-shadow:0 8px 40px rgba(0,0,0,0.12); }
  .route { display:flex; align-items:center; justify-content:space-between; margin-bottom:24px; }
  .iata { font-size:36px; font-weight:800; letter-spacing:-1px; }
  .city { font-size:12px; opacity:0.5; margin-top:4px; }
  .center { text-align:center; flex:1; }
  .flight-num { font-size:11px; opacity:0.4; font-weight:600; }
  .progress-bar { background:rgba(128,128,128,0.2); height:4px; border-radius:2px; margin:12px 8px; position:relative; }
  .progress-fill { background:#34c759; height:100%; border-radius:2px; transition:width 1s ease; }
  .plane-dot { position:absolute; top:-4px; width:12px; height:12px; background:#34c759; border-radius:50%; transition:left 1s ease; }
  .status { display:inline-block; padding:4px 12px; border-radius:20px; font-size:12px; font-weight:700; margin-bottom:20px; }
  .status.on-time,.status.landed { background:rgba(52,199,89,0.15); color:#34c759; }
  .status.delayed { background:rgba(255,59,48,0.15); color:#ff3b30; }
  .status.active { background:rgba(52,199,89,0.15); color:#34c759; }
  .info-row { display:flex; justify-content:space-between; padding:8px 0; border-bottom:1px solid rgba(128,128,128,0.15); }
  .info-label { opacity:0.5; font-size:13px; }
  .info-value { font-size:13px; font-weight:600; }
  .time { font-size:14px; font-family:ui-monospace,monospace; opacity:0.6; }
  .logo { text-align:center; margin-top:24px; font-size:11px; opacity:0.3; }
  .loading { opacity:0.4; text-align:center; padding:40px; }
  #error { color:#ff3b30; text-align:center; display:none; }
</style></head>
<body><div class="card" id="card">
  <div class="loading" id="loading">Loading flight…</div>
  <div id="error">Journey not found or expired.</div>
  <div id="content" style="display:none">
    <div class="route">
      <div><div class="iata" id="dep-iata">---</div><div class="city" id="dep-city"></div></div>
      <div class="center"><div class="flight-num" id="flight-num"></div>
        <div class="progress-bar"><div class="progress-fill" id="progress"></div><div class="plane-dot" id="plane-dot"></div></div></div>
      <div style="text-align:right"><div class="iata" id="arr-iata">---</div><div class="city" id="arr-city"></div></div>
    </div>
    <div id="status-pill"></div>
    <div class="time" style="display:flex;justify-content:space-between;margin-bottom:16px"><span id="dep-time"></span><span id="arr-time"></span></div>
    <div id="info-rows"></div>
  </div>
</div><div class="logo">Tracked by Arc</div>
<script>
const SUPA_URL='${supabaseUrl}',SUPA_KEY='${anonKey}',CODE='${code}';
async function load(){try{
  const jRes=await fetch(SUPA_URL+'/rest/v1/shared_journeys?share_code=eq.'+CODE+'&is_active=eq.true&select=*',{headers:{apikey:SUPA_KEY,Authorization:'Bearer '+SUPA_KEY}});
  const journeys=await jRes.json(); if(!journeys.length){showError();return;} const journey=journeys[0];
  const fRes=await fetch(SUPA_URL+'/rest/v1/shared_flights?id=eq.'+journey.flight_id+'&select=*',{headers:{apikey:SUPA_KEY,Authorization:'Bearer '+SUPA_KEY}});
  const flights=await fRes.json(); if(!flights.length){showError();return;}
  render(flights[0]); document.getElementById('loading').style.display='none'; document.getElementById('content').style.display='block';
  setInterval(async()=>{const r=await fetch(SUPA_URL+'/rest/v1/shared_flights?id=eq.'+journey.flight_id+'&select=*',{headers:{apikey:SUPA_KEY,Authorization:'Bearer '+SUPA_KEY}});const f=await r.json();if(f.length)render(f[0]);},30000);
}catch(e){showError();}}
function render(f){
  document.getElementById('dep-iata').textContent=f.departure_iata;document.getElementById('arr-iata').textContent=f.arrival_iata;
  document.getElementById('dep-city').textContent=f.departure_city;document.getElementById('arr-city').textContent=f.arrival_city;
  document.getElementById('flight-num').textContent=f.flight_number+' · '+f.airline;
  document.getElementById('dep-time').textContent=new Date(f.scheduled_departure).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});
  document.getElementById('arr-time').textContent=new Date(f.scheduled_arrival).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});
  const pct=Math.min(100,Math.max(0,f.progress*100));document.getElementById('progress').style.width=pct+'%';document.getElementById('plane-dot').style.left='calc('+pct+'% - 6px)';
  let sc='on-time',st='On Time';if(f.status==='active'){sc='active';st='In Flight';}if(f.status==='landed'){sc='landed';st='Landed';}if(f.delay_minutes>0){sc='delayed';st='Delayed '+f.delay_minutes+'m';}if(f.status==='cancelled'){sc='delayed';st='Cancelled';}
  document.getElementById('status-pill').innerHTML='<span class="status '+sc+'">'+st+'</span>';
  let rows='';if(f.departure_gate)rows+=infoRow('Gate',f.departure_gate);if(f.arrival_gate)rows+=infoRow('Arrival Gate',f.arrival_gate);if(f.baggage_claim)rows+=infoRow('Baggage',f.baggage_claim);if(f.aircraft_type)rows+=infoRow('Aircraft',f.aircraft_type);if(f.live_altitude)rows+=infoRow('Altitude',Math.round(f.live_altitude*3.281).toLocaleString()+' ft');if(f.live_speed)rows+=infoRow('Speed',Math.round(f.live_speed*1.944)+' kts');
  document.getElementById('info-rows').innerHTML=rows;
}
function infoRow(l,v){return '<div class="info-row"><span class="info-label">'+l+'</span><span class="info-value">'+v+'</span></div>';}
function showError(){document.getElementById('loading').style.display='none';document.getElementById('error').style.display='block';}
load();
</script></body></html>`;
}
