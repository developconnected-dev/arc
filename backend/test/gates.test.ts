import test from "node:test";
import assert from "node:assert/strict";
import { predictGate } from "../src/gates.ts";

const dep = (gate: string | null, terminal: string | null = null) =>
  ({ dep_gate: gate, dep_terminal: terminal });

test("picks the gate the flight actually keeps using", () => {
  const p = predictGate([dep("B24"), dep("B24"), dep("B22"), dep("B24")], "departure");
  assert.equal(p.gate, "B24");
  assert.equal(p.agreeing, 3);
  assert.equal(p.samples, 4);
  assert.ok(p.confidence > 0.7);
});

test("a schedule change wins over sheer count", () => {
  // Newest first: the flight moved to A11 recently, after a long run at B24.
  // Recency weighting has to let three fresh sightings beat four stale ones,
  // or a seasonal re-gating would be outvoted by history for weeks.
  const observations = [
    dep("A11"), dep("A11"), dep("A11"),
    dep("B24"), dep("B24"), dep("B24"), dep("B24"),
  ];
  assert.equal(predictGate(observations, "departure").gate, "A11");
});

test("reports the terminal belonging to the winning gate", () => {
  const p = predictGate([dep("B24", "2"), dep("B24", "2"), dep("A11", "1")], "departure");
  assert.equal(p.gate, "B24");
  assert.equal(p.terminal, "2");
});

test("no usable history is reported as no prediction, not a guess", () => {
  assert.deepEqual(predictGate([], "departure"),
    { gate: null, terminal: null, agreeing: 0, samples: 0, confidence: 0 });
  assert.equal(predictGate([dep(null), dep("  ")], "departure").gate, null);
});

test("scattered gates report low confidence so the caller can decline them", () => {
  const p = predictGate([dep("A1"), dep("B2"), dep("C3"), dep("D4")], "departure");
  assert.ok(p.confidence <= 0.3, `expected low confidence, got ${p.confidence}`);
});

test("arrival direction reads the arrival columns", () => {
  const p = predictGate(
    [{ arr_gate: "K7", arr_terminal: "3" }, { arr_gate: "K7" }, { dep_gate: "B24" }],
    "arrival");
  assert.equal(p.gate, "K7");
  assert.equal(p.terminal, "3");
  assert.equal(p.samples, 2, "a departure-only row is not arrival evidence");
});

test("gate matching ignores case and stray spacing", () => {
  const p = predictGate([dep(" b24 "), dep("B24")], "departure");
  assert.equal(p.gate, "B24");
  assert.equal(p.agreeing, 2);
});

// ── standFromBoard ──

import { standFromBoard } from "../src/gates.ts";

const boardRow = (number: string, movement: Record<string, unknown> = {}) =>
  ({ number, movement });

test("finds a flight's gate on the board, however FIDS spaces the number", () => {
  const board = [
    boardRow("LX 318", { gate: "A52", terminal: "1" }),
    boardRow("U2 1183", { gate: "21", terminal: "" }),
  ];
  const stand = standFromBoard(board, "U21183");
  assert.deepEqual(stand, { gate: "21", terminal: "", belt: null });
});

test("a flight not in the window is a miss, not a row of nulls", () => {
  assert.equal(standFromBoard([boardRow("LX318", { gate: "A52" })], "U21183"), null);
});

test("a listed flight with no gate yet answers with nulls — an answer, not a miss", () => {
  const stand = standFromBoard([boardRow("U2 1183", {})], "U2 1183");
  assert.deepEqual(stand, { gate: null, terminal: null, belt: null });
});

test("a row with no movement at all doesn't throw", () => {
  const stand = standFromBoard([{ number: "U21183" }], "U21183");
  assert.deepEqual(stand, { gate: null, terminal: null, belt: null });
});

test("an arrival row's belt comes through where the airport publishes one", () => {
  const stand = standFromBoard(
    [boardRow("LX2146", { gate: null, terminal: "1", baggageBelt: "9" })], "LX2146");
  assert.deepEqual(stand, { gate: null, terminal: "1", belt: "9" });
});
