interface Env {
  RAPIDAPI_KEY: string;          // AeroDataBox key (RapidAPI). Set via `wrangler secret put RAPIDAPI_KEY`.
  AIRLABS_KEY?: string;          // AirLabs fallback (free 1k/mo). Set via `wrangler secret put AIRLABS_KEY`.
  AVIATIONSTACK_API_KEY?: string; // legacy fallback (optional)
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string;
}

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

      // 2. Fallback: AirLabs
      if (env.AIRLABS_KEY) {
        try {
          // Try real-time flight endpoint first (active flights)
          let results = await airlabsFlightSearch(number, env);
          // If no active flight, try schedules
          if (results.length === 0) {
            results = await airlabsScheduleSearch(number, env);
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

    return new Response("not found", { status: 404 });
  },
};

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
