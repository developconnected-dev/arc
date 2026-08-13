// Which kind of journey is the user searching for? Pure, no network, no env —
// same contract as legs.ts and transit.ts so `node --test` can drive it.
//
// Arc has ONE search box and one "My Trips" list; nothing in the UI asks the
// user to pick a mode first. So the query itself has to say what it is, and this
// is what reads it. It runs before the AI parser and, for the many queries that
// are unambiguous, instead of it — a locally-recognised "ICE 373" should not
// cost a model round-trip.
//
// The important design decision: this returns RANKED GUESSES, not an answer.
// Several real designators mean different things in different modes, and there
// is no evidence in the string to settle them — see AMBIGUOUS below. Forcing a
// single answer there would silently show the user the wrong journey; offering
// both lets the search resolve each against its provider and return what exists.

import type { TripMode } from "./transit.ts";

export interface ModeGuess {
  mode: TripMode;
  /// 0..1. Above CONFIDENT the caller may skip other modes entirely.
  confidence: number;
  /// Why, in words — surfaced in logs and useful when a guess looks wrong.
  reason: string;
}

/// A guess at or above this is strong enough to query alone.
export const CONFIDENT = 0.8;

// ── vocabulary ────────────────────────────────────────────────────────────

/// The user naming the mode outright. Nothing outranks this.
const KEYWORDS: [RegExp, TripMode, string][] = [
  [/\b(ferry|ferries|boat|sailing|vessel|ship|traghetto|fähre|faehre|ferje|ferga|πλοίο|plio|barco|bateau)\b/i,
    "sea", "said so"],
  [/\b(train|rail|railway|zug|bahn|treno|tren|trein|tåg|tog|juna|τρένο)\b/i,
    "rail", "said so"],
  [/\b(flight|flights|fly|flying|plane|airline|flug|volo|vuelo|vol|πτήση)\b/i,
    "air", "said so"],
];

/// Carrier names, which merely SUGGEST a mode.
///
/// Kept below the keywords on purpose. "ferry booked via DB travel centre"
/// names DB and means a ferry; scoring an operator as loudly as the word the
/// user actually chose let a booking channel outvote the journey itself.
const OPERATOR_HINTS: [RegExp, TripMode, string][] = [
  [/\b(sncf|öbb|oebb|sbb|cff|trenitalia|renfe|ns|nmbs|sncb|pkp|cd|mav|hzpp)\b/i,
    "rail", "named a railway"],
];

/// Rail service prefixes that no airline uses, so they settle the question.
const RAIL_ONLY = new Set([
  "ICE", "ICN", "EC", "ECE", "RE", "RB", "RJ", "RJX", "NJ", "EN", "TGV", "TER",
  "THA", "IZY", "OUI", "AVE", "AVLO", "ALVIA", "MD", "RGX", "SBB", "IR", "RER",
  "EST", "EUROSTAR", "THALYS", "RAILJET", "NIGHTJET", "FRECCIAROSSA",
  "FRECCIARGENTO", "FRECCIABIANCA", "ITALO", "INTERCITY", "REGIONALE",
]);

/// Designators that are a train to one traveller and a flight to another. There
/// is nothing in "FR 9612" to say whether it is Ryanair or a Frecciarossa out of
/// Roma Termini — both exist, both carry that number format. Guessing would be
/// wrong roughly half the time, so both are offered and the providers decide.
const AMBIGUOUS: Record<string, [TripMode, TripMode]> = {
  FR: ["air", "rail"],   // Ryanair / Frecciarossa
  IT: ["air", "rail"],   // Hahn Air / Italo
  VY: ["air", "rail"],   // Vueling / Vy (Norway)
  IC: ["rail", "air"],   // InterCity / (rare) charter codes
  S: ["rail", "air"],    // S-Bahn / Shuttle America
};

/// Ferry operators and their best-known vessels, in the waters this app is for.
const SEA_OPERATORS = /\b(blue ?star|seajets|sea ?jets|hellenic ?seaways|minoan|anek|superfast|grimaldi|gnv|tirrenia|moby|corsica ?(ferries|linea)|baleària|balearia|trasmediterranea|fred\.? ?olsen|armas|jadrolinija|krilo|toremar|caremar|liberty ?lines|attica|golden ?star|fast ?ferries|aegean ?(speed|flying)|dfds|stena|tallink|viking ?line|silja|color ?line|fjord ?line|brittany ?ferries|irish ?ferries|p&o)\b/i;

/// Airline-style number: two-character code then up to four digits. Matches the
/// shape only — whether the code is an airline is decided above.
const FLIGHT_NUMBER = /^([A-Z][A-Z0-9]|[A-Z]{3})\s?(\d{1,4})[A-Z]?$/;
/// Rail-style: letters then a number. The prefix is capped at five characters
/// because every real service prefix is short (ICE, RJX, TGV, NJ) and a longer
/// one means we are reading an ordinary word — "Milan 2026" must not become
/// service "MILAN" number 2026.
const SERVICE_NUMBER = /^([A-Z]{1,5})\s?(\d{1,5})$/;

function norm(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

const MONTH = "jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec";

/// Remove when-they-are-travelling before reading what-they-are-travelling-on.
///
/// Dates are the single biggest source of false designators, because a code
/// beside a day number looks exactly like a service number. "PIR JTR 12 Aug" —
/// a ferry route with a date — joined "JTR" to "12" and read it as flight
/// JTR12, classifying a sailing as air with 0.85 confidence and searching only
/// airlines. The user's ferry was never looked for.
function stripDates(text: string): string {
  return text
    .replace(/\b\d{4}-\d{2}-\d{2}\b/g, " ")                               // 2026-08-12
    .replace(/\b\d{1,2}[./]\d{1,2}(?:[./]\d{2,4})?\b/g, " ")              // 12/08, 12.08.26
    .replace(new RegExp(`\\b\\d{1,2}(?:st|nd|rd|th)?\\s*(?:${MONTH})\\w*\\b`, "gi"), " ")
    .replace(new RegExp(`\\b(?:${MONTH})\\w*\\s*\\d{1,2}(?:st|nd|rd|th)?\\b`, "gi"), " ")
    .replace(/\b(mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)\w*\b/gi, " ")
    .replace(/\b(today|tonight|tomorrow|tmrw|morgen|domani|heute|oggi)\b/gi, " ")
    .replace(/\b(20\d{2})\b/g, " ");                                      // bare year
}

/// Pull out anything shaped like a service designator: "ICE 373", "LX14",
/// "RE3", "BLUE STAR DELOS" is not one (no digits) and is caught by operator
/// matching instead.
function designators(text: string): string[] {
  const out: string[] = [];
  // "ICE 373" and "ICE373" both appear on tickets; join a bare code to a
  // following number so the two spellings classify identically.
  const tokens = norm(stripDates(text).toUpperCase()).split(/[^A-Z0-9]+/).filter(Boolean);
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i], next = tokens[i + 1] ?? "";
    // Join BEFORE testing the token alone. "W6 2345" is Wizz Air 2345, but "W6"
    // on its own also reads as a service prefix W with number 6 — so testing
    // first and joining second classified a Wizz flight as a train.
    const joinable = /^(?=.*[A-Z])[A-Z0-9]{1,4}$/.test(tok) && /^\d{1,5}$/.test(next);
    if (joinable) { out.push(tok + next); i++; continue; }
    if (SERVICE_NUMBER.test(tok)) out.push(tok);
  }
  return out;
}

function add(into: Map<TripMode, ModeGuess>, mode: TripMode, confidence: number, reason: string) {
  const prev = into.get(mode);
  // A mode keeps its single strongest piece of evidence rather than accumulating
  // weak ones — three vague hints should not outrank one explicit "ferry".
  if (!prev || confidence > prev.confidence) into.set(mode, { mode, confidence, reason });
}

/// Rank the modes a query might mean, most likely first.
///
/// Never returns an empty list: a query with no signal at all is still a
/// journey the user wants, and air is the mode Arc has always been able to
/// answer, so it leads — with low confidence, so the caller still tries others.
export function classifyQuery(raw: unknown): ModeGuess[] {
  const text = norm(String(raw ?? ""));
  const guesses = new Map<TripMode, ModeGuess>();
  if (!text) return [{ mode: "air", confidence: 0.1, reason: "empty query" }];

  // 1. The user simply said which. Nothing outranks that.
  for (const [re, mode, reason] of KEYWORDS) {
    if (re.test(text)) add(guesses, mode, 0.95, reason);
  }

  // 2. A named operator — weaker than the user's own word for the journey.
  if (SEA_OPERATORS.test(text)) add(guesses, "sea", 0.9, "named a ferry operator");
  for (const [re, mode, reason] of OPERATOR_HINTS) {
    if (re.test(text)) add(guesses, mode, 0.7, reason);
  }

  // 3. Service designators.
  for (const d of designators(text)) {
    const m = d.match(SERVICE_NUMBER);
    if (!m) continue;
    const prefix = m[1];

    if (AMBIGUOUS[prefix]) {
      // Deliberately below CONFIDENT on both, so the caller queries both.
      const [first, second] = AMBIGUOUS[prefix];
      add(guesses, first, 0.5, `"${prefix}" is used by both`);
      add(guesses, second, 0.45, `"${prefix}" is used by both`);
      continue;
    }
    if (RAIL_ONLY.has(prefix)) {
      add(guesses, "rail", 0.9, `"${prefix}" is a rail service`);
      continue;
    }
    // Two letters and a short number is the airline shape; longer prefixes are
    // not, and a five-digit number is not a flight number either.
    if (FLIGHT_NUMBER.test(d)) add(guesses, "air", 0.85, "flight-number shape");
    else add(guesses, "rail", 0.6, "service-number shape, not an airline's");
  }

  // 4. Nothing recognised. Air leads on history, not on evidence, and stays
  //    low enough that the caller still asks the other providers.
  if (!guesses.size) {
    return [
      { mode: "air", confidence: 0.34, reason: "no signal; air is Arc's default" },
      { mode: "rail", confidence: 0.33, reason: "no signal" },
      { mode: "sea", confidence: 0.33, reason: "no signal" },
    ];
  }

  return [...guesses.values()].sort((a, b) =>
    b.confidence - a.confidence || a.mode.localeCompare(b.mode));
}

/// Connectors that separate an origin from a destination, in the languages a
/// query to this app plausibly arrives in. A bare hyphen only counts when it is
/// spaced, so "Aix-en-Provence" stays one place.
const CONNECTOR = /\s(?:to|→|->|>|–|—|-|nach|bis|a|per|verso|naar|til|till|hasta|vers|σε)\s/i;

/// The two places a route query names, in order.
///
/// Rail and sea searches need place NAMES: a MOTIS stop is found by name and
/// Ferryhopper resolves names while rejecting codes. The AI parser answers in
/// IATA codes, which are the wrong currency for both and are not worth
/// disturbing a carefully-tuned prompt to change.
///
/// Returns null rather than guessing when the query names no route — a single
/// place, or a bare service number, is not a crossing.
export function routeFromQuery(raw: unknown): { from: string; to: string } | null {
  const text = norm(stripDates(String(raw ?? "")))
    // Drop the mode word itself, so "ferry Piraeus to Santorini" doesn't make
    // the origin "ferry Piraeus".
    .replace(/\b(ferry|ferries|boat|sailing|train|rail|flight|fly|from)\b/gi, " ");
  const parts = norm(text).split(CONNECTOR);
  if (parts.length !== 2) return null;
  const from = norm(parts[0]), to = norm(parts[1]);
  if (!from || !to) return null;
  // A leftover service designator is not a place.
  if (SERVICE_NUMBER.test(from.toUpperCase()) || SERVICE_NUMBER.test(to.toUpperCase())) return null;
  return { from, to };
}

const MONTH_INDEX: Record<string, number> = {
  jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5,
  jul: 6, aug: 7, sep: 8, sept: 8, oct: 9, nov: 10, dec: 11,
};

/// The travel date a query names, as YYYY-MM-DD, or null.
///
/// Rail and sea searches need a date, and until this existed the only thing
/// that could read "10 Sep" was the AI parser — which meant a ferry search
/// waited on an AI call it has no other use for, and fell back to TODAY whenever
/// that call was unavailable or failed. A September booking then came back with
/// this afternoon's sailings, which looks like the right answer and is not.
///
/// Deliberately conservative: anything it cannot read confidently returns null,
/// and the caller falls back to today knowing it is a fallback.
export function dateFromQuery(raw: unknown, now: Date = new Date()): string | null {
  const text = norm(String(raw ?? ""));
  const iso = (y: number, m: number, d: number) =>
    `${y}-${String(m + 1).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
  const shift = (days: number) => {
    const t = new Date(now.getTime() + days * 86_400_000);
    return iso(t.getUTCFullYear(), t.getUTCMonth(), t.getUTCDate());
  };

  if (/\btoday\b/i.test(text)) return shift(0);
  if (/\b(tomorrow|tmrw|morgen|domani)\b/i.test(text)) return shift(1);

  const explicit = text.match(/\b(\d{4})-(\d{2})-(\d{2})\b/);
  if (explicit) return `${explicit[1]}-${explicit[2]}-${explicit[3]}`;

  // "10 Sep" and "Sep 10", each with an optional ordinal suffix and year.
  const monthOf = (word: string) => {
    const w = word.toLowerCase();
    return MONTH_INDEX[w.slice(0, 4)] ?? MONTH_INDEX[w.slice(0, 3)];
  };
  let day: number | undefined, mon: number | undefined, year: number | undefined;
  const dayFirst = text.match(
    new RegExp(`\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(${MONTH})\\w*(?:\\s+(\\d{4}))?\\b`, "i"));
  const monthFirst = text.match(
    new RegExp(`\\b(${MONTH})\\w*\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:\\s+(\\d{4}))?\\b`, "i"));
  if (dayFirst) {
    day = +dayFirst[1]; mon = monthOf(dayFirst[2]); year = dayFirst[3] ? +dayFirst[3] : undefined;
  } else if (monthFirst) {
    mon = monthOf(monthFirst[1]); day = +monthFirst[2]; year = monthFirst[3] ? +monthFirst[3] : undefined;
  }

  if (day === undefined || mon === undefined || !(day >= 1 && day <= 31)) return null;
  if (year !== undefined) return iso(year, mon, day);
  // No year given: take the next occurrence, so a query in December for
  // "10 Jan" means next month rather than eleven months ago.
  const thisYear = now.getUTCFullYear();
  const candidate = Date.UTC(thisYear, mon, day);
  const todayUTC = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  return iso(candidate < todayUTC ? thisYear + 1 : thisYear, mon, day);
}

/// The modes a search should actually query, in order.
///
/// One confident guess is queried alone; anything less fans out, because a
/// wrong single guess costs the user a search that finds nothing while the
/// journey they meant sits one provider away.
export function modesToQuery(raw: unknown): TripMode[] {
  const ranked = classifyQuery(raw);
  if (ranked[0].confidence >= CONFIDENT) return [ranked[0].mode];
  const worth = ranked.filter(g => g.confidence >= 0.3).map(g => g.mode);
  // Never hand the caller an empty list. A weak guess is still somewhere to
  // look; nothing to search is a dead search box.
  return worth.length ? worth : [ranked[0].mode];
}
