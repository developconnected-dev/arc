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
var D=${JSON.stringify(payload)};
var CODE=${JSON.stringify(code)};
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
  var facts=[];
  if(f.dep.gate)facts.push('Gate <b>'+f.dep.gate+'</b>');
  if(f.dep.terminal)facts.push('Terminal <b>'+f.dep.terminal+'</b>');
  if(f.arr.belt)facts.push('Belt <b>'+f.arr.belt+'</b>');
  if(f.aircraft)facts.push(f.aircraft);
  if(f.delay>0)facts.push('<b>+'+f.delay+' min</b>');
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
