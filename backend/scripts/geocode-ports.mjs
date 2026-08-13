// Resolves port coordinates so ferry legs can be drawn on the map.
//
// Run: node scripts/geocode-ports.mjs   (~12 minutes; writes ports_coords.json)
//
// WHY THIS IS SAFE WHERE THE EARLIER ATTEMPT WAS NOT. Geocoding port names
// against a general search endpoint produced confident nonsense — "PIRAEUS"
// resolved to a rental business in Serbia, "LAS PALMAS" to Chicago. The failure
// was never the coordinates themselves; it was accepting whatever came back.
//
// So every lookup here is CONSTRAINED and then CHECKED:
//   1. the search is restricted to the port's own country server-side, which
//      alone kills the Serbia and Chicago class of error;
//   2. the result must still report that country back;
//   3. it must be a plausible maritime feature, not an arbitrary shop that
//      happens to share the name.
// Anything failing a check is written as null. A missing arc is a small gap; an
// arc drawn to the wrong continent is a bug the user has to notice themselves.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const UA = "Arc/0.1 (personal trip tracker; szerdick@ethz.ch)";

/// Nominatim asks for at most one request a second and a contact in the
/// User-Agent. Both are honoured; this is a one-off build step, not a runtime
/// dependency, and the result is committed so it never runs on someone's behalf.
const DELAY_MS = 1100;

/// Arc's waters. Ports outside these countries keep null coordinates — they are
/// out of scope, and geocoding 800 more of them would be a lot of someone
/// else's bandwidth for routes this app will never show.
const SCOPE = {
  "Greece": "gr", "Italy": "it", "Spain": "es", "Croatia": "hr", "Turkey": "tr",
  "France": "fr", "Portugal": "pt", "Malta": "mt", "Albania": "al",
  "Montenegro": "me", "Slovenia": "si", "Morocco": "ma", "Tunisia": "tn",
  "Algeria": "dz", "Egypt": "eg", "Gibraltar": "gi",
  "United Kingdom (UK)": "gb", "Ireland": "ie", "Netherlands": "nl",
  "Germany": "de", "Denmark": "dk", "Sweden": "se", "Norway": "no",
  "Finland": "fi", "Estonia": "ee", "Latvia": "lv", "Lithuania": "lt",
  "Poland": "pl",
};

/// OSM classes a genuine port can legitimately carry. A "shop" or an "office"
/// with a matching name is the exact trap this exists to catch.
const MARITIME_OK = new Set([
  "place", "harbour", "ferry_terminal", "waterway", "natural", "boundary",
  "landuse", "man_made", "amenity", "railway",
]);

const sleep = ms => new Promise(r => setTimeout(r, ms));

/// Strip Ferryhopper's decorations so the query is the place, not the listing:
/// "THIRA (SANTORINI)" → "Thira", "HVAR (ALL PORTS)" → "Hvar".
function searchable(name) {
  return name
    .replace(/\(ALL PORTS\)/gi, " ")
    .replace(/\([^)]*\)/g, " ")
    .replace(/\bPIER\b|\bPORT\b/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
}

async function geocode(name, cc) {
  const q = searchable(name);
  if (!q) return null;
  const url = "https://nominatim.openstreetmap.org/search"
    + `?q=${encodeURIComponent(q)}&format=jsonv2&limit=3&countrycodes=${cc}&addressdetails=1`;
  const res = await fetch(url, { headers: { "User-Agent": UA, Accept: "application/json" } });
  if (!res.ok) return null;
  const rows = await res.json();
  for (const r of rows) {
    const gotCC = String(r.address?.country_code ?? "").toLowerCase();
    if (gotCC !== cc) continue;                       // check 2
    if (!MARITIME_OK.has(String(r.category ?? ""))) continue;  // check 3
    const lat = Number(r.lat), lon = Number(r.lon);
    if (!isFinite(lat) || !isFinite(lon)) continue;
    return { lat: +lat.toFixed(5), lon: +lon.toFixed(5), matched: r.display_name, kind: r.category };
  }
  return null;
}

const ports = JSON.parse(readFileSync(join(here, "..", "src", "ports.json"), "utf8"));
const outPath = join(here, "ports_coords.json");
const done = existsSync(outPath) ? JSON.parse(readFileSync(outPath, "utf8")) : {};

const todo = ports.filter(p => SCOPE[p.country] && !(p.name in done));
console.log(`in scope: ${ports.filter(p => SCOPE[p.country]).length}, already done: ${Object.keys(done).length}, to do: ${todo.length}`);

let ok = 0, miss = 0, n = 0;
for (const p of todo) {
  try {
    const hit = await geocode(p.name, SCOPE[p.country]);
    done[p.name] = hit;
    hit ? ok++ : miss++;
  } catch (e) {
    done[p.name] = null; miss++;
  }
  if (++n % 25 === 0) {
    writeFileSync(outPath, JSON.stringify(done, null, 1));
    console.log(`  ${n}/${todo.length}  resolved ${ok}  unresolved ${miss}`);
  }
  await sleep(DELAY_MS);
}
writeFileSync(outPath, JSON.stringify(done, null, 1));
console.log(`done: ${ok} resolved, ${miss} unresolved, written to ports_coords.json`);
