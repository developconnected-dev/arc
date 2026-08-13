import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { zonedNaiveToUTC } from "../src/transit.ts";

interface Port { name: string; code: string; country: string; tz: string | null }
const PORTS: Port[] = JSON.parse(readFileSync(new URL("../src/ports.json", import.meta.url), "utf8"));
const tz = (name: string) => PORTS.find(p => p.name === name)?.tz ?? null;

// These are the values that fail silently. A wrong zone doesn't throw, doesn't
// look wrong in the JSON, and surfaces only as a sailing that boarded an hour
// ago — so they are pinned here rather than trusted.

test("the port table covers Arc's waters completely", () => {
  const scope = ["Greece", "Italy", "Spain", "Croatia", "Turkey", "France", "Portugal",
                 "Malta", "Albania", "Montenegro", "Morocco", "Tunisia", "Slovenia"];
  const inScope = PORTS.filter(p => scope.includes(p.country));
  const missing = inScope.filter(p => !p.tz);
  assert.equal(missing.length, 0,
    `unresolved: ${missing.slice(0, 5).map(p => `${p.name}/${p.country}`).join(", ")}`);
  assert.ok(inScope.length > 600, `only ${inScope.length} ports in scope`);
});

test("the Mediterranean mainlands are on mainland time", () => {
  assert.equal(tz("PIRAEUS"), "Europe/Athens");
  assert.equal(tz("THIRA (SANTORINI)"), "Europe/Athens");
  assert.equal(tz("LIVORNO"), "Europe/Rome");
  assert.equal(tz("SPLIT"), "Europe/Zagreb");
  assert.equal(tz("BARCELONA"), "Europe/Madrid");
  assert.equal(tz("MARSEILLE"), "Europe/Paris");
});

test("the Canaries keep their own hour", () => {
  // An hour off the mainland, on routes Fred. Olsen and Armas run daily. This
  // is the case that made a country-wide default unsafe.
  for (const p of ["SANTA CRUZ DE TENERIFE", "LAS PALMAS GC", "ARRECIFE",
                   "LOS CRISTIANOS", "SANTA CRUZ DE LA PALMA", "MORRO JABLE"]) {
    assert.equal(tz(p), "Atlantic/Canary", p);
  }
  // …while the Balearics do not.
  for (const p of ["PALMA DE MALLORCA", "IBIZA", "MAHON", "DENIA"]) {
    assert.equal(tz(p), "Europe/Madrid", p);
  }
});

test("the Azores and Madeira are told apart", () => {
  assert.equal(tz("FUNCHAL"), "Atlantic/Madeira");
  assert.equal(tz("PORTO SANTO"), "Atlantic/Madeira");
  assert.equal(tz("HORTA"), "Atlantic/Azores");
  assert.equal(tz("PONTA DELGADA") ?? "Atlantic/Azores", "Atlantic/Azores");
  // CALHETA exists in BOTH archipelagos. Resolved on evidence, not memory: its
  // direct connections are Madalena, Horta, Praia da Vitória, Pico and
  // Terceira — every one of them Azorean.
  assert.equal(tz("CALHETA"), "Atlantic/Azores");
});

test("a Caribbean port filed under France is not on Paris time", () => {
  assert.equal(tz("ST. BARTH"), "America/St_Barthelemy");
  assert.equal(tz("AJACCIO"), "Europe/Paris", "Corsica is Paris time");
});

test("ports outside Arc's scope admit they are unresolved", () => {
  // Better a null the caller can react to than a plausible wrong hour. These
  // countries span zones and no ferry Arc cares about calls at them.
  const us = PORTS.filter(p => p.country === "United States (USA)");
  assert.ok(us.length > 0 && us.every(p => p.tz === null));
});

test("the table actually corrects a real sailing", () => {
  // End to end: the naive stamp Ferryhopper returns for Blue Star Delos, read
  // through this table, must land on 04:25Z — not the 07:25Z the `Z` claims.
  assert.equal(
    zonedNaiveToUTC("2026-08-12T07:25:00Z", tz("PIRAEUS")!),
    "2026-08-12T04:25:00.000Z");
  // And a Canary crossing must not borrow Madrid's offset.
  assert.notEqual(
    zonedNaiveToUTC("2026-08-12T09:00:00Z", tz("LOS CRISTIANOS")!),
    zonedNaiveToUTC("2026-08-12T09:00:00Z", tz("PALMA DE MALLORCA")!));
});

test("no port carries a timezone the runtime can't use", () => {
  for (const p of PORTS) {
    if (!p.tz) continue;
    assert.doesNotThrow(() => new Intl.DateTimeFormat("en-US", { timeZone: p.tz! }),
      `${p.name} has an unusable zone: ${p.tz}`);
  }
});
