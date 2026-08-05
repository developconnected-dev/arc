// Explicit extension so `node --test` can resolve this directly; esbuild (and
// therefore wrangler) accepts it unchanged.
import { AIRPORT_CITY } from "./airports.ts";

// Does the route the parser produced actually correspond to the places the
// traveller named?
//
// The parser is a language model and it is confidently wrong about small
// places: asked for "Syros to Athens" it answers JTR — Santorini — and the
// search then returns a different island's departures as though they were the
// answer. Prompting it not to did nothing; it still says JTR. So the answer is
// checked rather than trusted, which is the only thing that actually holds.
//
// This CANNOT invent a route, only refuse one. A refused endpoint leaves the
// search unanchored, which yields nothing — and nothing is the correct answer
// to a question whose place we couldn't confirm. Offering somewhere else is
// not: it invites the traveller to add the wrong flight.

/// Generic words that appear in hundreds of city names and would match almost
/// any sentence. "Syros Island" must be recognised by SYROS, never by ISLAND.
const GENERIC = new Set([
  "ISLAND", "ISLANDS", "AIRPORT", "INTERNATIONAL", "REGIONAL", "MUNICIPAL",
  "COUNTY", "FIELD", "AIRBASE", "AIRFIELD", "METROPOLITAN", "NATIONAL",
]);

/// Exonyms the client already understands, so a German query isn't rejected
/// for naming a city the English-language table spells differently. Mirrors
/// FlightQueryParser.primaryAirport on the app side.
const ALIASES: Record<string, string> = {
  WIEN: "VIE", GENF: "GVA", MUNCHEN: "MUC", MAILAND: "MXP", ROM: "FCO",
  VENEDIG: "VCE", NEAPEL: "NAP", LISSABON: "LIS", KOPENHAGEN: "CPH",
  NIZZA: "NCE", PRAG: "PRG", WARSCHAU: "WAW", ATHEN: "ATH", BRUSSEL: "BRU",
  KOLN: "CGN", NURNBERG: "NUE", MOSKAU: "SVO", PEKING: "PEK", LONDRES: "LHR",
  PARIS: "CDG", MAILAND_LIN: "LIN",
};

/// Uppercase, strip diacritics, reduce everything else to single spaces, so
/// "Zürich nach München" and "ZURICH NACH MUNCHEN" compare equal.
export function normalizePlaceText(text: string): string {
  return text
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, " ")
    .trim();
}

function tokens(text: string): Set<string> {
  return new Set(normalizePlaceText(text).split(" ").filter(Boolean));
}

/// Is this airport one of the places the query actually names?
///
/// Accepts the IATA code written out ("ATH to MUC"), any distinctive word of
/// the airport's city ("Syros" for JSY "Syros Island"), or a known exonym
/// ("Wien" for VIE, whose table entry reads "Vienna").
export function queryMentions(query: string, iata: string): boolean {
  const code = (iata ?? "").toUpperCase();
  if (!/^[A-Z]{3}$/.test(code)) return false;
  const words = tokens(query);
  if (words.has(code)) return true;
  for (const [alias, target] of Object.entries(ALIASES)) {
    if (target === code && words.has(alias)) return true;
  }
  const city = AIRPORT_CITY[code];
  if (!city) return false;
  for (const part of normalizePlaceText(city).split(" ")) {
    if (part.length >= 4 && !GENERIC.has(part) && words.has(part)) return true;
  }
  return false;
}

/// The parser's route with any endpoint the query never mentioned removed.
///
/// Both endpoints are checked independently: a query can name one place Arc
/// can confirm and one it can't, and half a verified route is still better
/// than a whole invented one.
export function verifiedRoute(
  query: string, dep: string | undefined, arr: string | undefined
): { dep: string; arr: string; dropped: string[] } {
  const dropped: string[] = [];
  const check = (code: string | undefined): string => {
    const value = (code ?? "").toUpperCase();
    if (!/^[A-Z]{3}$/.test(value)) return "";
    if (queryMentions(query, value)) return value;
    dropped.push(value);
    return "";
  };
  return { dep: check(dep), arr: check(arr), dropped };
}
