interface Env {
  AVIATIONSTACK_API_KEY: string;
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const cors = { "Access-Control-Allow-Origin": "*", "Content-Type": "application/json" };

    // Handle CORS preflight
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
      return Response.json({ ok: true }, { headers: cors });
    }

    // ── /flight — search by flight number + date ──
    if (url.pathname === "/flight") {
      const number = url.searchParams.get("number");
      const date = url.searchParams.get("date");
      if (!number) return new Response("missing number", { status: 400 });

      const params = new URLSearchParams({
        access_key: env.AVIATIONSTACK_API_KEY,
        flight_iata: number,
      });
      if (date) params.set("flight_date", date);

      // Note: AviationStack free tier only supports HTTP, not HTTPS
      // Upgrade to paid plan to use HTTPS
      const apiRes = await fetch(`http://api.aviationstack.com/v1/flights?${params}`);
      const raw = await apiRes.json() as { data?: Array<Record<string, unknown>> };

      if (!raw.data || raw.data.length === 0) {
        return Response.json([], { headers: cors });
      }

      const results = raw.data.map((f: Record<string, unknown>) => {
        const dep = f.departure as Record<string, unknown> | undefined;
        const arr = f.arrival as Record<string, unknown> | undefined;
        const airline = f.airline as Record<string, unknown> | undefined;
        const aircraft = f.aircraft as Record<string, unknown> | undefined;
        const flight = f.flight as Record<string, unknown> | undefined;

        return {
          flight_number: (flight?.iata as string) ?? number,
          airline_name: (airline?.name as string) ?? "",
          airline_iata: (airline?.iata as string) ?? "",
          dep_iata: (dep?.iata as string) ?? "",
          arr_iata: (arr?.iata as string) ?? "",
          dep_city: null, // AviationStack doesn't include city in flights endpoint
          arr_city: null,
          dep_scheduled: (dep?.scheduled as string) ?? "",
          arr_scheduled: (arr?.scheduled as string) ?? "",
          status: (f.flight_status as string) ?? "scheduled",
          dep_gate: (dep?.gate as string) ?? null,
          dep_terminal: (dep?.terminal as string) ?? null,
          arr_gate: (arr?.gate as string) ?? null,
          arr_terminal: (arr?.terminal as string) ?? null,
          arr_baggage: (arr?.baggage as string) ?? null,
          delay: (dep?.delay as number) ?? 0,
          aircraft_type: aircraft ? `${aircraft.iata ?? ""}` : null,
          aircraft_registration: (aircraft?.registration as string) ?? null,
          dep_lat: null, // Will be enriched with airport data client-side
          dep_lon: null,
          arr_lat: null,
          arr_lon: null,
        };
      });

      return Response.json(results, { headers: cors });
    }

    // ── /position — live aircraft position from OpenSky ──
    if (url.pathname === "/position") {
      const icao24 = url.searchParams.get("icao24");
      if (!icao24) return new Response("missing icao24", { status: 400 });

      try {
        const apiRes = await fetch(
          `https://opensky-network.org/api/states/all?icao24=${icao24.toLowerCase()}`,
          { headers: { "Accept": "application/json" } }
        );
        const raw = await apiRes.json() as { states?: Array<Array<unknown>> };

        if (!raw.states || raw.states.length === 0) {
          return Response.json(null, { status: 404, headers: cors });
        }

        const s = raw.states[0]!;
        const position = {
          icao24: s[0] as string,
          lat: (s[6] as number) ?? 0,
          lon: (s[5] as number) ?? 0,
          altitude: (s[7] as number) ?? 0,
          velocity: (s[9] as number) ?? 0,
          heading: (s[10] as number) ?? 0,
          on_ground: (s[8] as boolean) ?? false,
        };

        return Response.json(position, { headers: cors });
      } catch {
        return Response.json(null, { status: 502, headers: cors });
      }
    }

    // ── /journey/:code — shared journey live viewer ──
    const journeyMatch = url.pathname.match(/^\/journey\/([a-z0-9]+)$/);
    if (journeyMatch) {
      const code = journeyMatch[1];
      return new Response(sharedJourneyHTML(code, env.SUPABASE_URL, env.SUPABASE_ANON_KEY), {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    return new Response("not found", { status: 404 });
  },
};

function sharedJourneyHTML(code: string, supabaseUrl: string, anonKey: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Arc — Live Flight</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { background:#121217; color:#fff; font-family:-apple-system,system-ui,sans-serif; min-height:100vh; display:flex; flex-direction:column; align-items:center; justify-content:center; padding:24px; }
  .card { background:#1c1c1e; border-radius:20px; padding:32px; max-width:420px; width:100%; border:1px solid rgba(255,255,255,0.08); }
  .route { display:flex; align-items:center; justify-content:space-between; margin-bottom:24px; }
  .iata { font-size:36px; font-weight:800; letter-spacing:-1px; }
  .city { font-size:12px; color:rgba(255,255,255,0.5); margin-top:4px; }
  .center { text-align:center; }
  .flight-num { font-size:11px; color:rgba(255,255,255,0.3); font-weight:600; }
  .progress-bar { background:rgba(255,255,255,0.1); height:4px; border-radius:2px; margin:12px 0; position:relative; }
  .progress-fill { background:#0EA5E9; height:100%; border-radius:2px; transition:width 1s ease; }
  .plane-dot { position:absolute; top:-4px; width:12px; height:12px; background:#0EA5E9; border-radius:50%; transition:left 1s ease; }
  .status { display:inline-block; padding:4px 12px; border-radius:20px; font-size:12px; font-weight:700; margin-bottom:20px; }
  .status.on-time { background:rgba(34,197,94,0.15); color:#22c55e; }
  .status.delayed { background:rgba(249,115,22,0.15); color:#f97316; }
  .status.landed { background:rgba(34,197,94,0.15); color:#22c55e; }
  .status.active { background:rgba(14,165,233,0.15); color:#0EA5E9; }
  .info-row { display:flex; justify-content:space-between; padding:8px 0; border-bottom:1px solid rgba(255,255,255,0.05); }
  .info-label { color:rgba(255,255,255,0.5); font-size:13px; }
  .info-value { font-size:13px; font-weight:600; }
  .time { font-size:14px; font-family:ui-monospace,monospace; color:rgba(255,255,255,0.6); }
  .logo { text-align:center; margin-top:24px; font-size:11px; color:rgba(255,255,255,0.2); }
  .loading { color:rgba(255,255,255,0.4); text-align:center; padding:40px; }
  #error { color:#f97316; text-align:center; display:none; }
</style>
</head>
<body>
<div class="card" id="card">
  <div class="loading" id="loading">Loading flight...</div>
  <div id="error">Journey not found or expired.</div>
  <div id="content" style="display:none">
    <div class="route">
      <div><div class="iata" id="dep-iata">---</div><div class="city" id="dep-city"></div></div>
      <div class="center">
        <div class="flight-num" id="flight-num"></div>
        <div class="progress-bar"><div class="progress-fill" id="progress"></div><div class="plane-dot" id="plane-dot"></div></div>
      </div>
      <div style="text-align:right"><div class="iata" id="arr-iata">---</div><div class="city" id="arr-city"></div></div>
    </div>
    <div id="status-pill"></div>
    <div class="time" style="display:flex;justify-content:space-between;margin-bottom:16px">
      <span id="dep-time"></span><span id="arr-time"></span>
    </div>
    <div id="info-rows"></div>
  </div>
</div>
<div class="logo">Tracked by Arc</div>
<script>
const SUPA_URL = '${supabaseUrl}';
const SUPA_KEY = '${anonKey}';
const CODE = '${code}';

async function load() {
  try {
    // Get journey
    const jRes = await fetch(SUPA_URL + '/rest/v1/shared_journeys?share_code=eq.' + CODE + '&is_active=eq.true&select=*', {
      headers: { apikey: SUPA_KEY, Authorization: 'Bearer ' + SUPA_KEY }
    });
    const journeys = await jRes.json();
    if (!journeys.length) { showError(); return; }
    const journey = journeys[0];

    // Get flight
    const fRes = await fetch(SUPA_URL + '/rest/v1/shared_flights?id=eq.' + journey.flight_id + '&select=*', {
      headers: { apikey: SUPA_KEY, Authorization: 'Bearer ' + SUPA_KEY }
    });
    const flights = await fRes.json();
    if (!flights.length) { showError(); return; }

    render(flights[0]);
    document.getElementById('loading').style.display = 'none';
    document.getElementById('content').style.display = 'block';

    // Poll every 30s
    setInterval(async () => {
      const r = await fetch(SUPA_URL + '/rest/v1/shared_flights?id=eq.' + journey.flight_id + '&select=*', {
        headers: { apikey: SUPA_KEY, Authorization: 'Bearer ' + SUPA_KEY }
      });
      const f = await r.json();
      if (f.length) render(f[0]);
    }, 30000);
  } catch(e) { showError(); }
}

function render(f) {
  document.getElementById('dep-iata').textContent = f.departure_iata;
  document.getElementById('arr-iata').textContent = f.arrival_iata;
  document.getElementById('dep-city').textContent = f.departure_city;
  document.getElementById('arr-city').textContent = f.arrival_city;
  document.getElementById('flight-num').textContent = f.flight_number + ' · ' + f.airline;
  document.getElementById('dep-time').textContent = new Date(f.scheduled_departure).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});
  document.getElementById('arr-time').textContent = new Date(f.scheduled_arrival).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});

  const pct = Math.min(100, Math.max(0, f.progress * 100));
  document.getElementById('progress').style.width = pct + '%';
  document.getElementById('plane-dot').style.left = 'calc(' + pct + '% - 6px)';

  let statusClass = 'on-time';
  let statusText = 'On Time';
  if (f.status === 'active') { statusClass = 'active'; statusText = 'In Flight'; }
  if (f.status === 'landed') { statusClass = 'landed'; statusText = 'Landed'; }
  if (f.delay_minutes > 0) { statusClass = 'delayed'; statusText = 'Delayed ' + f.delay_minutes + 'm'; }
  if (f.status === 'cancelled') { statusClass = 'delayed'; statusText = 'Cancelled'; }
  document.getElementById('status-pill').innerHTML = '<span class="status ' + statusClass + '">' + statusText + '</span>';

  let rows = '';
  if (f.departure_gate) rows += infoRow('Gate', f.departure_gate);
  if (f.arrival_gate) rows += infoRow('Arrival Gate', f.arrival_gate);
  if (f.baggage_claim) rows += infoRow('Baggage', f.baggage_claim);
  if (f.aircraft_type) rows += infoRow('Aircraft', f.aircraft_type);
  if (f.live_altitude) rows += infoRow('Altitude', Math.round(f.live_altitude * 3.281).toLocaleString() + ' ft');
  if (f.live_speed) rows += infoRow('Speed', Math.round(f.live_speed * 1.944) + ' kts');
  document.getElementById('info-rows').innerHTML = rows;
}

function infoRow(label, value) {
  return '<div class="info-row"><span class="info-label">' + label + '</span><span class="info-value">' + value + '</span></div>';
}

function showError() {
  document.getElementById('loading').style.display = 'none';
  document.getElementById('error').style.display = 'block';
}

load();
</script>
</body>
</html>`;
}
