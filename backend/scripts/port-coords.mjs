// Resolves port coordinates from OpenStreetMap, so ferry legs can be drawn.
//
// Run: node scripts/port-coords.mjs   (writes scripts/ports_coords.json)
//
// WHY OVERPASS AND NOT A GEOCODER. The first attempt asked a geocoder for each
// port by name, one request each. That was wrong twice over: Nominatim's policy
// prohibits bulk geocoding and it began returning 429 after ~16 lookups — and
// because the script recorded any failure as "unresolved", it was quietly
// manufacturing false "this port has no coordinates" entries. A rate limit was
// being written into the data as a fact about the world.
//
// Overpass answers the question that was actually being asked: "where are the
// ferry terminals in this country?" — one request per country instead of one per
// port, and the country filter is part of the query rather than a check bolted
// on afterwards. Matching then happens locally against a known-good set.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const UA = "Arc/0.1 (personal trip tracker; szerdick@ethz.ch)";

/// The main overpass-api.de instance answered "server is probably too busy";
/// these mirrors are tried in order and the first that responds is used.
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

/// Compare names across languages and spellings: OSM often carries the local
/// form ("Πειραιάς") where Ferryhopper carries a transliteration ("PIRAEUS"),
/// so every name variant a feature offers is considered.
function norm(s) {
  return String(s ?? "")
    .replace(/\([^)]*\)/g, " ")
    .normalize("NFD").replace(/[̀-ͯ]/g, "")
    .toUpperCase()
    .replace(/\b(PORT|PORTO|PUERTO|LIMANI|PIER|TERMINAL|FERRY|ALL PORTS|HARBOUR|HARBOR)\b/g, " ")
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
      if (!text.trimStart().startsWith("{")) continue;   // an HTML error page
      return JSON.parse(text);
    } catch { /* try the next mirror */ }
  }
  return null;
}

/// Every named maritime feature in one country.
async function terminalsIn(cc) {
  const q = `[out:json][timeout:180];
area["ISO3166-1"="${cc}"][admin_level=2]->.a;
(
  node["amenity"="ferry_terminal"](area.a);
  way["amenity"="ferry_terminal"](area.a);
  node["harbour"="yes"](area.a);
  way["harbour"="yes"](area.a);
);
out center tags;`;
  const data = await overpass(q);
  if (!data) return [];
  const out = [];
  for (const e of data.elements ?? []) {
    const t = e.tags ?? {};
    const lat = e.lat ?? e.center?.lat, lon = e.lon ?? e.center?.lon;
    if (!isFinite(lat) || !isFinite(lon)) continue;
    const names = [t.name, t["name:en"], t.int_name, t.alt_name, t["name:el"]]
      .filter(Boolean).map(norm).filter(Boolean);
    if (!names.length) continue;
    out.push({ names, lat: +Number(lat).toFixed(5), lon: +Number(lon).toFixed(5) });
  }
  return out;
}

/// Best match for a port name among a country's features.
///
/// Exact first, then whole-word containment either way — "ERMOUPOLI SYROS"
/// should match "SYROS". Anything looser invites the wrong island, so a port
/// with no confident match stays unresolved rather than being approximated.
function match(portName, features) {
  const want = norm(portName);
  if (!want) return null;
  const wantWords = new Set(want.split(" "));
  let best = null, bestScore = 0;
  for (const f of features) {
    for (const n of f.names) {
      let score = 0;
      if (n === want) score = 100;
      else if (n.startsWith(want + " ") || want.startsWith(n + " ")) score = 80;
      else {
        const words = n.split(" ");
        const shared = words.filter(w => w.length > 3 && wantWords.has(w)).length;
        if (shared) score = 40 + shared * 10;
      }
      if (score > bestScore) { bestScore = score; best = f; }
    }
  }
  return bestScore >= 40 ? { lat: best.lat, lon: best.lon, score: bestScore } : null;
}

const ports = JSON.parse(readFileSync(join(here, "..", "src", "ports.json"), "utf8"));
const outPath = join(here, "ports_coords.json");
const resolved = existsSync(outPath) ? JSON.parse(readFileSync(outPath, "utf8")) : {};

for (const [country, cc] of Object.entries(SCOPE)) {
  const inCountry = ports.filter(p => p.country === country);
  if (!inCountry.length || inCountry.every(p => p.name in resolved)) continue;
  const features = await terminalsIn(cc);
  let hit = 0;
  for (const p of inCountry) {
    const m = match(p.name, features);
    resolved[p.name] = m ? { lat: m.lat, lon: m.lon } : null;
    if (m) hit++;
  }
  console.log(`${country.padEnd(20)} features ${String(features.length).padStart(5)}   matched ${hit}/${inCountry.length}`);
  writeFileSync(outPath, JSON.stringify(resolved, null, 1));
  await sleep(2500);   // be a good neighbour to a free, donated service
}

const total = Object.keys(resolved).length, ok = Object.values(resolved).filter(Boolean).length;
console.log(`\nresolved ${ok}/${total} ports`);
