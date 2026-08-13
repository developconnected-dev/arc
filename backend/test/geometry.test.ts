import test from "node:test";
import assert from "node:assert/strict";
import { decodePolyline, simplify, routePath, ROUTE_EPSILON } from "../src/geometry.ts";

// The canonical example from Google's polyline specification.
const GOOGLE_EXAMPLE = "_p~iF~ps|U_ulLnnqC_mqNvxq`@";

test("decodes the reference polyline", () => {
  const pts = decodePolyline(GOOGLE_EXAMPLE, 5);
  assert.deepEqual(pts, [[38.5, -120.2], [40.7, -120.95], [43.252, -126.453]]);
});

test("precision is honoured, because getting it wrong is silent", () => {
  // MOTIS reports precision 7. Decoding that string as precision 5 doesn't
  // throw — it just multiplies every coordinate by 100 and puts the line
  // thousands of degrees off the map, where nothing complains.
  const at5 = decodePolyline(GOOGLE_EXAMPLE, 5);
  const at7 = decodePolyline(GOOGLE_EXAMPLE, 7);
  assert.equal(at7[0][0], at5[0][0] / 100);
});

test("a truncated or empty polyline degrades instead of throwing", () => {
  assert.deepEqual(decodePolyline("", 7), []);
  assert.deepEqual(decodePolyline(null, 7), []);
  assert.deepEqual(decodePolyline(undefined, 7), []);
  assert.doesNotThrow(() => decodePolyline("_p~iF~ps|U_ulL", 5));
});

// ── simplification ────────────────────────────────────────────────────────

/// A straight run of points with one real detour in the middle.
const withDetour: [number, number][] = [
  [0, 0], [0, 1], [0, 2], [0, 3],
  [1, 4],                          // the bend that must survive
  [0, 5], [0, 6], [0, 7],
];

test("collinear points are dropped and real bends are kept", () => {
  const s = simplify(withDetour, 0.1);
  assert.ok(s.length < withDetour.length, "nothing was simplified");
  assert.deepEqual(s[0], [0, 0]);
  assert.deepEqual(s[s.length - 1], [0, 7]);
  assert.ok(s.some(p => p[0] === 1 && p[1] === 4), "the bend was flattened away");
});

test("endpoints are never dropped", () => {
  for (const eps of [0.001, 0.5, 50]) {
    const s = simplify(withDetour, eps);
    assert.deepEqual(s[0], withDetour[0], `ε=${eps}`);
    assert.deepEqual(s[s.length - 1], withDetour[withDetour.length - 1], `ε=${eps}`);
  }
});

test("a coarse tolerance collapses to the straight line", () => {
  assert.equal(simplify(withDetour, 100).length, 2);
});

test("degenerate inputs pass through untouched", () => {
  assert.deepEqual(simplify([], 0.1), []);
  assert.deepEqual(simplify([[1, 2]], 0.1), [[1, 2]]);
  assert.deepEqual(simplify([[1, 2], [3, 4]], 0.1), [[1, 2], [3, 4]]);
  assert.deepEqual(simplify(withDetour, 0), withDetour, "ε=0 must not discard anything");
});

test("a long track simplifies without exhausting the stack", () => {
  // 20,000 points is the real scale — one ICE run. A recursive implementation
  // recurses deep enough here to risk taking the whole response down with it.
  const long: [number, number][] = [];
  for (let i = 0; i < 20_000; i++) long.push([Math.sin(i / 400) * 2, i / 400]);
  let out: [number, number][] = [];
  assert.doesNotThrow(() => { out = simplify(long, ROUTE_EPSILON); });
  assert.ok(out.length > 2 && out.length < long.length / 5,
    `expected a large reduction, got ${out.length} of ${long.length}`);
});

test("simplification preserves the order of travel", () => {
  const long: [number, number][] = [];
  for (let i = 0; i < 2_000; i++) long.push([Math.sin(i / 100), i / 100]);
  const s = simplify(long, ROUTE_EPSILON);
  for (let i = 1; i < s.length; i++) {
    assert.ok(s[i][1] > s[i - 1][1], "points came back out of order");
  }
});

// ── the leg-level helper ──────────────────────────────────────────────────

test("a leg with real geometry yields a drawable path", () => {
  const leg = { legGeometry: { points: GOOGLE_EXAMPLE, precision: 5 } };
  const path = routePath(leg, 0.0001);
  assert.ok(path && path.length >= 3);
  assert.deepEqual(path![0], [38.5, -120.2]);
});

test("a leg without geometry says so rather than inventing one", () => {
  // Ferries carry none at all; the map falls back to a straight line, which is
  // honest, whereas an empty array would read as "this route has no shape".
  assert.equal(routePath({}), null);
  assert.equal(routePath({ legGeometry: {} }), null);
  assert.equal(routePath({ legGeometry: { points: "" } }), null);
  assert.equal(routePath(null as never), null);
});

test("geometry that simplifies to a straight line returns null", () => {
  // Two points describe exactly what the map already draws between the
  // endpoints, so carrying them would be payload for no picture.
  const straight = { legGeometry: { points: GOOGLE_EXAMPLE, precision: 5 } };
  assert.equal(routePath(straight, 1000), null);
});
