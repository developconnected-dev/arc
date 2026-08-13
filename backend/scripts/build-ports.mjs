// Builds src/ports.json — the port → IANA timezone table the ferry path needs.
//
// Run: node scripts/build-ports.mjs
//
// WHY A CURATED MAP AND NOT GEOCODING. The obvious approach — geocode each port
// name and read the zone off the result — was tried and abandoned because it is
// confidently wrong. Against api.transitous.org: "PIRAEUS" resolved to
// Europe/Belgrade (a rental business in Serbia), "THIRA (SANTORINI)" to
// Asia/Manila, "LAS PALMAS" to America/Chicago. A bulk run would have produced
// a table that looks complete and silently shifts sailings by hours, which is
// strictly worse than admitting we don't know.
//
// So: a country default, plus explicit overrides for the archipelagos that sit
// in a different zone from their mainland. Countries that genuinely span zones
// and are outside Arc's scope get `null` rather than a guess — see UNRESOLVED.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

/// One zone for the whole country. Every entry here is a country that observes
/// a single time, so the default is the answer, not an approximation.
const COUNTRY_TZ = {
  "Albania": "Europe/Tirane", "Algeria": "Africa/Algiers", "Anguilla": "America/Anguilla",
  "Antigua and Barbuda": "America/Antigua", "Austria": "Europe/Vienna",
  "Belize": "America/Belize", "Bermuda": "Atlantic/Bermuda",
  "Bonaire, St Eustatius and Saba": "America/Kralendijk",
  "British Virgin Islands": "America/Tortola", "Cambodia": "Asia/Phnom_Penh",
  "Cape Verde Islands": "Atlantic/Cape_Verde", "Cayman Islands": "America/Cayman",
  "China": "Asia/Shanghai", "Colombia": "America/Bogota", "Comoros": "Indian/Comoro",
  "Costa Rica": "America/Costa_Rica", "Croatia": "Europe/Zagreb",
  "Denmark": "Europe/Copenhagen", "Dominica": "America/Dominica",
  "Dominican Republic": "America/Santo_Domingo", "Egypt": "Africa/Cairo",
  "Estonia": "Europe/Tallinn", "Fiji": "Pacific/Fiji", "Finland": "Europe/Helsinki",
  "Germany": "Europe/Berlin", "Gibraltar": "Europe/Gibraltar", "Greece": "Europe/Athens",
  "Guadeloupe": "America/Guadeloupe", "Guatemala": "America/Guatemala",
  "Guernsey": "Europe/Guernsey", "Guinea": "Africa/Conakry", "Honduras": "America/Tegucigalpa",
  "Hong Kong, China": "Asia/Hong_Kong", "Ireland": "Europe/Dublin", "Italy": "Europe/Rome",
  "Japan": "Asia/Tokyo", "Jersey": "Europe/Jersey", "Jordan": "Asia/Amman",
  "Latvia": "Europe/Riga", "Lithuania": "Europe/Vilnius", "Macau, China": "Asia/Macau",
  "Malaysia": "Asia/Kuala_Lumpur", "Malta": "Europe/Malta", "Martinique": "America/Martinique",
  "Mayotte": "Indian/Mayotte", "Montenegro": "Europe/Podgorica", "Morocco": "Africa/Casablanca",
  "Netherlands": "Europe/Amsterdam", "New Caledonia": "Pacific/Noumea",
  "Nicaragua": "America/Managua", "Norway": "Europe/Oslo", "Panama": "America/Panama",
  "Philippines": "Asia/Manila", "Poland": "Europe/Warsaw", "Puerto Rico": "America/Puerto_Rico",
  "Saint Kitts and Nevis": "America/St_Kitts", "Saint Lucia": "America/St_Lucia",
  "Saint Martin": "America/Marigot", "Seychelles": "Indian/Mahe",
  "Sierra Leone": "Africa/Freetown", "Singapore": "Asia/Singapore",
  "Slovakia": "Europe/Bratislava", "Slovenia": "Europe/Ljubljana", "Sri Lanka": "Asia/Colombo",
  "Sweden": "Europe/Stockholm", "Tanzania": "Africa/Dar_es_Salaam", "Thailand": "Asia/Bangkok",
  "The Bahamas": "America/Nassau", "Tunisia": "Africa/Tunis", "Turkey": "Europe/Istanbul",
  "U.S. Virgin Islands": "America/St_Thomas", "United Kingdom (UK)": "Europe/London",
  "Uruguay": "America/Montevideo", "Vietnam": "Asia/Ho_Chi_Minh",
  // Single-zone in practice for their ferry ports:
  "New Zealand": "Pacific/Auckland",   // Chathams have no ferry port here
  "Singapore ": "Asia/Singapore",
};

/// Countries whose ports genuinely span zones, where a single default would be
/// wrong somewhere. Ports here resolve to null unless an override names them —
/// none of these are in Arc's European/Mediterranean scope, and a wrong hour on
/// a Florida or Queensland sailing is not a trade worth making for coverage.
const UNRESOLVED = new Set([
  "United States (USA)", "Australia", "Indonesia", "Brazil", "Mexico", "Canada",
  "Argentina", "Ecuador", "French Polynesia", "Venezuela", "India",
]);

/// Archipelagos that keep a different time from their own mainland. Matched on
/// the port name as Ferryhopper spells it.
///
/// Spain: the Canaries are UTC+0/+1 while the mainland and Balearics are
/// UTC+1/+2 — a full hour, on routes Fred. Olsen and Armas run daily.
/// Portugal: every Portuguese port in this dataset is insular. Funchal and
/// Porto Santo are Madeira (UTC+0/+1); the rest are the Azores (UTC-1/+0).
/// CALHETA was the one genuine ambiguity — there is a Calheta in Madeira and
/// another in São Jorge — and it resolves to the Azores on evidence: its direct
/// connections are Madalena, Horta, Praia da Vitória, Pico and Terceira, all
/// Azorean.
/// France: Saint-Barthélemy is in the Caribbean, four hours off Paris.
const OVERRIDES = [
  ["Spain", "Atlantic/Canary", [
    "AGAETE", "ARRECIFE", "CORRALEJO", "EL HIERRO (VALVERDE)", "FUERTEVENTURA (ALL PORTS)",
    "GRAN CANARIA (ALL PORTS)", "ISLA DE LOBOS", "LA GOMERA (ALL PORTS)", "LA GRACIOSA",
    "LANZAROTE (ALL PORTS)", "LAS PALMAS GC", "LOS CRISTIANOS", "MORRO JABLE", "ORZOLA",
    "PLAYA BLANCA", "PLAYA SANTIAGO", "PTO. ROSARIO", "PUERTO CALERO", "PUERTO DEL CARMEN",
    "SAN SEBASTIAN DE LA GOMERA", "SANTA CRUZ DE LA PALMA", "SANTA CRUZ DE TENERIFE",
    "TENERIFE (ALL PORTS)", "VALLE GRAN REY",
  ]],
  ["Portugal", "Atlantic/Madeira", ["FUNCHAL", "PORTO SANTO"]],
  ["France", "America/St_Barthelemy", ["ST. BARTH"]],
];

/// Applied after the overrides: whatever is left in these countries.
const INSULAR_DEFAULT = { "Portugal": "Atlantic/Azores", "Spain": "Europe/Madrid", "France": "Europe/Paris" };

const raw = JSON.parse(readFileSync(join(here, "ports_raw.json"), "utf8"));

// Positions resolved separately by port-coords.mjs (OpenStreetMap via Overpass).
// Optional: without it the table still carries names, codes and zones, and
// ferries simply aren't drawn on the map.
const coordsPath = join(here, "ports_coords.json");
const coords = existsSync(coordsPath) ? JSON.parse(readFileSync(coordsPath, "utf8")) : {};

/// Rough envelopes for the countries Arc actually plots, as [minLat, maxLat,
/// minLon, maxLon].
///
/// A last check on positions that came from name matching. It caught a real
/// one: "FRANCE NORTH (ALL PORTS)" and "FRANCE SOUTH (ALL PORTS)" — Ferryhopper
/// groupings rather than places — matched a harbour in MARTINIQUE, which is
/// technically France and 6,700 km from the Channel. A coordinate outside its
/// own country's envelope is not that country's port, whatever it is named.
const ENVELOPE = {
  "Greece": [34, 42, 19, 29.8], "Italy": [35, 47.2, 6, 19],
  "Croatia": [42, 46.6, 13, 20], "Turkey": [35.5, 42.5, 25.5, 45],
  "Malta": [35.7, 36.2, 14.1, 14.7], "Albania": [39.5, 42.7, 19, 21.1],
  "Montenegro": [41.8, 43.6, 18.4, 20.4], "Slovenia": [45.4, 46.9, 13.3, 16.6],
  "Tunisia": [30, 37.6, 7.5, 11.6], "Morocco": [27.6, 36, -13.2, -1],
  // Spain, Portugal and France own territory in several oceans, so their
  // envelopes deliberately span the archipelagos the ferries actually serve.
  "Spain": [27, 44, -19, 5], "Portugal": [32, 42.5, -32, -6],
  "France": [41, 51.5, -5.5, 10],
};

const overrideFor = new Map();
for (const [country, tz, names] of OVERRIDES) {
  for (const n of names) overrideFor.set(`${country}|${n}`, tz);
}

const ports = raw.map(p => {
  const country = p.countryName ?? "";
  const name = p.name ?? "";
  const tz = overrideFor.get(`${country}|${name}`)
    ?? INSULAR_DEFAULT[country]
    ?? (UNRESOLVED.has(country) ? null : COUNTRY_TZ[country] ?? null);
  let pos = coords[name];
  const box = ENVELOPE[country];
  if (pos && box && !(pos.lat >= box[0] && pos.lat <= box[1]
                      && pos.lon >= box[2] && pos.lon <= box[3])) {
    pos = null;   // matched something with the right name in the wrong ocean
  }
  return {
    name, code: p.code ?? "", country, tz,
    lat: pos?.lat ?? null, lon: pos?.lon ?? null,
  };
});

const resolved = ports.filter(p => p.tz).length;
const byCountryUnresolved = {};
for (const p of ports) if (!p.tz) byCountryUnresolved[p.country] = (byCountryUnresolved[p.country] ?? 0) + 1;

mkdirSync(join(here, "..", "src"), { recursive: true });
writeFileSync(join(here, "..", "src", "ports.json"), JSON.stringify(ports) + "\n");

console.log(`ports: ${ports.length}, timezone resolved: ${resolved} (${(100 * resolved / ports.length).toFixed(1)}%)`);
console.log("unresolved by country:", byCountryUnresolved);
const med = ports.filter(p => ["Greece", "Italy", "Spain", "Croatia", "Turkey", "France", "Portugal", "Malta", "Albania", "Montenegro", "Morocco", "Tunisia", "Slovenia"].includes(p.country));
console.log(`Mediterranean scope: ${med.filter(p => p.tz).length}/${med.length} timezone resolved`);
const positioned = ports.filter(p => p.lat != null).length;
console.log(`positions: ${positioned}/${ports.length} (${med.filter(p => p.lat != null).length}/${med.length} in the Mediterranean)`);
