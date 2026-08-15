import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  buildFerryGraph, routeAlongFerries, simplify, haversineKm, overpassQuery,
  type OSMWay, type LatLon,
} from "../src/searoute.ts";

// Real OSM ferry ways for the Aegean (Overpass, 2026-08-15) — 230 ways.
const ways: OSMWay[] = JSON.parse(
  readFileSync(new URL("./fixtures/ferry_ways_aegean.json", import.meta.url), "utf8"));
const graph = buildFerryGraph(ways);

const PIRAEUS: LatLon = [37.9488, 23.6372];
const SANTORINI: LatLon = [36.3917, 25.4261];
const MYKONOS: LatLon = [37.4452, 25.3289];
const AEGINA: LatLon = [37.7469, 23.4281];
const HERAKLION: LatLon = [35.3444, 25.1442];

test("Piraeus → Santorini follows the Cyclades corridor, not a detour via Crete", () => {
  const r = routeAlongFerries(graph, PIRAEUS, SANTORINI);
  assert.ok(r, "route exists");
  const direct = haversineKm(PIRAEUS, SANTORINI);
  // A real ferry line is a little longer than the straight line, never double.
  assert.ok(r!.km > direct && r!.km < direct * 1.25, `km ${r!.km} vs direct ${direct}`);
  // Never dips south of 36.2° — that would be the Crete lane.
  assert.ok(r!.path.every(p => p[0] > 36.2), "stays north of Crete");
  assert.deepEqual(r!.path[0], PIRAEUS);
  assert.deepEqual(r!.path[r!.path.length - 1], SANTORINI);
});

test("a short hop stays short — Piraeus → Aegina is not routed round the archipelago", () => {
  const r = routeAlongFerries(graph, PIRAEUS, AEGINA);
  assert.ok(r);
  assert.ok(r!.km < 45, `km ${r!.km}`);
});

test("Piraeus → Heraklion takes the direct southern line", () => {
  const r = routeAlongFerries(graph, PIRAEUS, HERAKLION);
  assert.ok(r);
  assert.ok(r!.km < haversineKm(PIRAEUS, HERAKLION) * 1.1);
});

test("Piraeus → Mykonos is served", () => {
  const r = routeAlongFerries(graph, PIRAEUS, MYKONOS);
  assert.ok(r);
  assert.ok(r!.km < haversineKm(PIRAEUS, MYKONOS) * 1.3);
});

test("a port off the network yields null, never a made-up line", () => {
  // Mid-Atlantic: nothing within snapping distance.
  assert.equal(routeAlongFerries(graph, [45, -30], SANTORINI), null);
});

test("simplify keeps ends and shape while cutting points", () => {
  const r = routeAlongFerries(graph, PIRAEUS, SANTORINI)!;
  const s = simplify(r.path);
  assert.ok(s.length < r.path.length);
  assert.ok(s.length >= 4);
  assert.deepEqual(s[0], r.path[0]);
  assert.deepEqual(s[s.length - 1], r.path[r.path.length - 1]);
  // Length barely changes.
  const len = (p: LatLon[]) => p.slice(1).reduce((acc, q, i) => acc + haversineKm(p[i], q), 0);
  assert.ok(Math.abs(len(s) - len(r.path)) < 2);
});

test("the Overpass query boxes both ports with padding", () => {
  const q = overpassQuery(PIRAEUS, SANTORINI);
  assert.match(q, /route"="ferry"/);
  assert.match(q, /\(36\.042,23\.287,38\.299,25\.776\)/);
});
