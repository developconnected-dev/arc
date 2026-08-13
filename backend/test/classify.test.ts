import test from "node:test";
import assert from "node:assert/strict";
import { classifyQuery, modesToQuery, routeFromQuery, dateFromQuery, CONFIDENT } from "../src/classify.ts";

const top = (q: string) => classifyQuery(q)[0].mode;

// ── the easy majority ─────────────────────────────────────────────────────

test("a flight number reads as a flight", () => {
  for (const q of ["LX14", "LX 14", "U24523", "BA117", "W6 2345", "A31653"]) {
    assert.equal(top(q), "air", q);
  }
});

test("a train number reads as a train", () => {
  for (const q of ["ICE 373", "ICE373", "RJX 65", "TGV 9241", "EC 8", "NJ 40295", "RE3"]) {
    assert.equal(top(q), "rail", q);
  }
});

test("a named ferry operator reads as a sailing", () => {
  for (const q of ["Blue Star Piraeus Naxos", "SeaJets to Santorini",
                   "Jadrolinija Split Hvar", "Baleària Denia Ibiza", "GNV Bari Durazzo"]) {
    assert.equal(top(q), "sea", q);
  }
});

test("saying the word settles it outright", () => {
  assert.equal(top("ferry from Piraeus to Santorini"), "sea");
  assert.equal(top("train to Milano"), "rail");
  assert.equal(top("flight to New York"), "air");
  assert.equal(top("traghetto Napoli Palermo"), "sea");
  assert.equal(top("Zug nach Berlin"), "rail");
});

test("a confident guess is queried on its own", () => {
  assert.deepEqual(modesToQuery("ICE 373"), ["rail"]);
  assert.deepEqual(modesToQuery("ferry to Naxos"), ["sea"]);
  assert.ok(classifyQuery("ICE 373")[0].confidence >= CONFIDENT);
});

// ── genuine ambiguity, deliberately preserved ─────────────────────────────

test("a designator both modes really use offers both", () => {
  // FR 9612 is Ryanair 9612 AND a Frecciarossa out of Roma Termini. Nothing in
  // the string decides it, so committing to one would be wrong about half the
  // time — for a user who then simply gets no result.
  const modes = modesToQuery("FR 9612");
  assert.ok(modes.includes("air"), "Ryanair");
  assert.ok(modes.includes("rail"), "Frecciarossa");
});

test("ambiguity is never dressed up as confidence", () => {
  for (const g of classifyQuery("FR 9612")) {
    assert.ok(g.confidence < CONFIDENT, `${g.mode} claimed ${g.confidence}`);
  }
});

test("context resolves an ambiguous designator", () => {
  // The same number, once the user has said which they mean.
  assert.equal(top("FR 9612 train"), "rail");
  assert.equal(top("FR 9612 flight"), "air");
  assert.deepEqual(modesToQuery("FR 9612 train"), ["rail"]);
});

test("VY and IT are ambiguous the same way", () => {
  assert.ok(modesToQuery("VY 8000").includes("air"));   // Vueling
  assert.ok(modesToQuery("VY 8000").includes("rail"));  // Vy Norway
  assert.ok(modesToQuery("IT 9950").length > 1);        // Italo / Hahn Air
});

// ── no signal ─────────────────────────────────────────────────────────────

test("a bare route asks everyone", () => {
  const modes = modesToQuery("Zurich to Milan");
  assert.equal(modes.length, 3, "any of the three could serve this pair");
});

test("an empty query still answers", () => {
  assert.deepEqual(classifyQuery("").map(g => g.mode), ["air"]);
  assert.deepEqual(classifyQuery(null).map(g => g.mode), ["air"]);
  assert.deepEqual(classifyQuery(undefined).map(g => g.mode), ["air"]);
});

test("every query yields at least one mode to try", () => {
  for (const q of ["", "   ", "???", "🚢", "12345", "a", "Piraeus"]) {
    assert.ok(modesToQuery(q).length >= 1, `"${q}" produced nothing to search`);
  }
});

// ── ranking discipline ────────────────────────────────────────────────────

test("one explicit word outranks several vague hints", () => {
  // "DB" hints rail, but the user said ferry. Weak evidence must not pile up
  // past a direct statement.
  const ranked = classifyQuery("ferry booked via DB travel centre");
  assert.equal(ranked[0].mode, "sea");
});

test("guesses come back sorted, strongest first", () => {
  for (const q of ["FR 9612", "Zurich to Milan", "ICE 373"]) {
    const c = classifyQuery(q).map(g => g.confidence);
    assert.deepEqual(c, [...c].sort((a, b) => b - a), q);
  }
});

test("every guess explains itself", () => {
  for (const g of classifyQuery("FR 9612")) assert.ok(g.reason.length > 0);
});

test("classification does not depend on spacing or case", () => {
  assert.equal(top("ice 373"), top("ICE373"));
  assert.equal(top("lx 14"), top("LX14"));
});

// ── dates are not service numbers ─────────────────────────────────────────
//
// A code beside a day number looks exactly like a service number, and getting
// this wrong is expensive: "PIR JTR 12 Aug" once read as flight JTR12 and
// searched airlines only, so the ferry the user actually wanted was never
// looked for at all.

test("a route with a date does not invent a service number", () => {
  for (const q of ["PIR JTR 12 Aug", "Piraeus Santorini 12 Aug", "Split Hvar 3 Sep",
                   "Berlin Basel 26 Aug", "Naxos Paros 1st July"]) {
    const modes = modesToQuery(q);
    assert.equal(modes.length, 3, `"${q}" narrowed to ${modes} on a date, not a designator`);
  }
});

test("dates in every common spelling are ignored", () => {
  for (const q of ["ZRH JFK 2026-08-12", "ZRH JFK 12/08", "ZRH JFK Aug 12",
                   "ZRH JFK tomorrow", "ZRH JFK Fri", "ZRH JFK 12th Aug"]) {
    assert.equal(modesToQuery(q).length, 3, `"${q}" read its date as a service`);
  }
});

test("a real designator still survives alongside a date", () => {
  assert.equal(top("LX14 on 12 Aug"), "air");
  assert.equal(top("ICE 373 tomorrow"), "rail");
  assert.deepEqual(modesToQuery("ICE 373 on 2026-08-26"), ["rail"]);
});

// ── route extraction ──────────────────────────────────────────────────────

test("a route query yields its two places, in order", () => {
  assert.deepEqual(routeFromQuery("Piraeus to Santorini"), { from: "Piraeus", to: "Santorini" });
  assert.deepEqual(routeFromQuery("Zurich to Milan"), { from: "Zurich", to: "Milan" });
  assert.deepEqual(routeFromQuery("Berlin → Basel"), { from: "Berlin", to: "Basel" });
  assert.deepEqual(routeFromQuery("Split - Hvar"), { from: "Split", to: "Hvar" });
  assert.deepEqual(routeFromQuery("Zürich nach München"), { from: "Zürich", to: "München" });
});

test("the mode word is not mistaken for part of the origin", () => {
  assert.deepEqual(routeFromQuery("ferry Piraeus to Santorini"),
    { from: "Piraeus", to: "Santorini" });
  assert.deepEqual(routeFromQuery("train from Berlin to Basel"),
    { from: "Berlin", to: "Basel" });
});

test("a date does not leak into a place name", () => {
  assert.deepEqual(routeFromQuery("Piraeus to Santorini 12 Aug"),
    { from: "Piraeus", to: "Santorini" });
  assert.deepEqual(routeFromQuery("Berlin to Basel tomorrow"),
    { from: "Berlin", to: "Basel" });
});

test("a hyphenated place stays one place", () => {
  // Only a SPACED hyphen separates a route; otherwise "Aix-en-Provence" splits
  // into two places that don't exist.
  assert.deepEqual(routeFromQuery("Aix-en-Provence to Marseille"),
    { from: "Aix-en-Provence", to: "Marseille" });
});

test("things that are not routes return nothing", () => {
  assert.equal(routeFromQuery("ICE 373"), null);
  assert.equal(routeFromQuery("LX14"), null);
  assert.equal(routeFromQuery("Piraeus"), null);
  assert.equal(routeFromQuery(""), null);
  assert.equal(routeFromQuery(null), null);
  // Three places is not a crossing this can resolve; better nothing than a
  // confident wrong pair.
  assert.equal(routeFromQuery("Berlin to Basel to Milan"), null);
});

// ── the vessel case ───────────────────────────────────────────────────────

test("a vessel name with no number is still a sailing", () => {
  // Ferry tickets identify the sailing by ship, not by a service number, so a
  // query can carry no digits at all.
  assert.equal(top("Blue Star Delos"), "sea");
  assert.equal(top("Superfast II Ancona Patras"), "sea");
});

// ── travel dates, read without the AI parser ──────────────────────────────
//
// Rail and sea searches need a date and have no other use for an AI call. Until
// this existed, "10 Sep" was only legible to the parser — so a ferry search fell
// back to TODAY whenever that was slow, unavailable or unconfigured, and
// answered a September booking with this afternoon's sailings.

const NOW = new Date("2026-08-05T12:00:00Z");

test("a day-and-month is read straight off the query", () => {
  assert.equal(dateFromQuery("ferry piraeus to syros 10 sep", NOW), "2026-09-10");
  assert.equal(dateFromQuery("Piraeus to Syros 10 September", NOW), "2026-09-10");
  assert.equal(dateFromQuery("Piraeus to Syros Sep 10", NOW), "2026-09-10");
  assert.equal(dateFromQuery("Piraeus to Syros 10th Sept", NOW), "2026-09-10");
});

test("an explicit date wins outright", () => {
  assert.equal(dateFromQuery("Berlin to Basel 2026-08-26", NOW), "2026-08-26");
  assert.equal(dateFromQuery("Naxos to Paros 3 Sep 2027", NOW), "2027-09-03");
});

test("today and tomorrow resolve against the caller's clock", () => {
  assert.equal(dateFromQuery("ICE 373 today", NOW), "2026-08-05");
  assert.equal(dateFromQuery("ICE 373 tomorrow", NOW), "2026-08-06");
});

test("a bare day-month takes the NEXT occurrence", () => {
  // Asked in August for "10 Jan", the traveller means next January — not one
  // seven months gone.
  assert.equal(dateFromQuery("Piraeus to Syros 10 Jan", NOW), "2027-01-10");
  assert.equal(dateFromQuery("Piraeus to Syros 10 Aug", NOW), "2026-08-10");
});

test("a query with no date says so instead of guessing", () => {
  assert.equal(dateFromQuery("ferry piraeus to syros", NOW), null);
  assert.equal(dateFromQuery("ICE 373", NOW), null);
  assert.equal(dateFromQuery("", NOW), null);
  assert.equal(dateFromQuery(null, NOW), null);
  assert.equal(dateFromQuery("Piraeus to Syros 99 Sep", NOW), null);
});
