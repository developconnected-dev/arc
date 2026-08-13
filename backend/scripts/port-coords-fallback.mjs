// Second pass for ports the terminal query couldn't name-match.
//
// Run AFTER port-coords.mjs: node scripts/port-coords-fallback.mjs
//
// The first pass asks OSM for ferry terminals and matches them by name. That
// works wherever the two sources agree on what the place is called, and fails
// on a whole class of Greek island routes where they don't: Ferryhopper sells a
// ticket to "ANDROS", the island, while the OSM terminal is "Gavrio", the town
// the boat actually docks at. No amount of string matching bridges that.
//
// So unmatched names are looked up as PLACES — islands, towns, villages — and
// the ferry line is drawn to the settlement rather than the quay. That is off by
// a kilometre or two, which at the zoom a Mediterranean crossing is viewed at is
// a pixel. Marked `approx` so the distinction survives in the data rather than
// being quietly forgotten.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const UA = "Arc/0.1 (personal trip tracker; szerdick@ethz.ch)";
const ENDPOINTS = [
  "https://overpass.private.coffee/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://overpass-api.de/api/interpreter",
];

const SCOPE = {
  "Greece": "GR", "Italy": "IT", "Spain": "ES", "Croatia": "HR", "Turkey": "TR",
  "France": "FR", "Portugal": "PT", "Malta": "MT", "Albania": "AL",
  "Montenegro": "ME", "Slovenia": "SI", "Morocco": "MA", "Tunisia": "TN",
  "Algeria": "DZ", "Egypt": "EG", "Gibraltar": "GI",
  "United Kingdom (UK)": "GB", "Ireland": "IE", "Netherlands": "NL",
  "Germany": "DE", "Denmark": "DK", "Sweden": "SE", "Norway": "NO",
  "Finland": "FI", "Estonia": "EE", "Latvia": "LV", "Lithuania": "LT",
  "Poland": "PL",
};

const sleep = ms => new Promise(r => setTimeout(r, ms));

function norm(s) {
  return String(s ?? "")
    .replace(/\([^)]*\)/g, " ")
    .normalize("NFD").replace(/[̀-ͯ]/g, "")
    .toUpperCase()
    .replace(/\b(PORT|PORTO|PUERTO|LIMANI|PIER|TERMINAL|FERRY|ALL PORTS|HARBOUR|HARBOR|ISLAND|NEW|OLD)\b/g, " ")
    .replace(/[^A-Z0-9]+/g, " ")
    .trim();
}

async function overpass(query) {
  for (const ep of ENDPOINTS) {
    try {
      const res = await fetch(ep, {
        method: "POST",
        headers: { "User-Agent": UA, "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ data: query }),
      });
      if (!res.ok) continue;
      const text = await res.text();
      if (!text.trimStart().startsWith("{")) continue;
      return JSON.parse(text);
    } catch { /* next mirror */ }
  }
  return null;
}

/// Named settlements and islands in one country. `place` covers exactly the
/// vocabulary these port names use — an island, or the town on it.
async function placesIn(cc) {
  const q = `[out:json][timeout:180];
area["ISO3166-1"="${cc}"][admin_level=2]->.a;
(
  node["place"~"^(island|islet|town|village|city|suburb)$"](area.a);
);
out tags center;`;
  const data = await overpass(q);
  if (!data) return [];
  const out = [];
  for (const e of data.elements ?? []) {
    const t = e.tags ?? {};
    const lat = e.lat ?? e.center?.lat, lon = e.lon ?? e.center?.lon;
    if (!isFinite(lat) || !isFinite(lon)) continue;
    const names = [t.name, t["name:en"], t.int_name, t.alt_name]
      .filter(Boolean).map(norm).filter(Boolean);
    if (!names.length) continue;
    // A bigger settlement is the likelier ferry call than a hamlet sharing its
    // name, so rank by place type when several match.
    const rank = { city: 5, town: 4, island: 3, village: 2, suburb: 1, islet: 1 }[t.place] ?? 0;
    out.push({ names, lat: +Number(lat).toFixed(5), lon: +Number(lon).toFixed(5), rank });
  }
  return out;
}

/// Exact name only. The first pass already tried fuzzy matching against a
/// maritime-only set, where a loose hit is probably still a port. Here the
/// candidate pool is every town in the country, so anything short of an exact
/// match invites the wrong village entirely.
function matchExact(portName, places) {
  const want = norm(portName);
  if (!want || want.length < 3) return null;
  let best = null;
  for (const p of places) {
    if (!p.names.includes(want)) continue;
    if (!best || p.rank > best.rank) best = p;
  }
  return best ? { lat: best.lat, lon: best.lon, approx: true } : null;
}

const ports = JSON.parse(readFileSync(join(here, "..", "src", "ports.json"), "utf8"));
const outPath = join(here, "ports_coords.json");
const resolved = JSON.parse(readFileSync(outPath, "utf8"));

for (const [country, cc] of Object.entries(SCOPE)) {
  // "(ALL PORTS)" entries are Ferryhopper groupings, not places — a sailing is
  // always sold from a real port, so there is nothing to locate.
  const pending = ports.filter(p =>
    p.country === country && p.name in resolved && !resolved[p.name]
    && !p.name.includes("ALL PORTS"));
  if (!pending.length) continue;

  const places = await placesIn(cc);
  if (!places.length) { console.log(`${country.padEnd(20)} no places returned`); continue; }
  let hit = 0;
  for (const p of pending) {
    const m = matchExact(p.name, places);
    if (m) { resolved[p.name] = m; hit++; }
  }
  console.log(`${country.padEnd(20)} places ${String(places.length).padStart(6)}   recovered ${hit}/${pending.length}`);
  writeFileSync(outPath, JSON.stringify(resolved, null, 1));
  await sleep(2500);
}

const total = Object.keys(resolved).length, ok = Object.values(resolved).filter(Boolean).length;
const approx = Object.values(resolved).filter(v => v?.approx).length;
console.log(`\nresolved ${ok}/${total} (${approx} located to the settlement rather than the quay)`);
