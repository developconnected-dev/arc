// Pure gate-observation arithmetic — no network, no env, no imports, so it can
// be unit-tested directly with `node --test`.

export interface GateObservation {
  flight_date?: string;
  dep_gate?: string | null;
  dep_terminal?: string | null;
  arr_gate?: string | null;
  arr_terminal?: string | null;
}

export interface GatePrediction {
  gate: string | null;
  terminal: string | null;
  /// How many observations backed the winning gate, and how many were looked at.
  agreeing: number;
  samples: number;
  /// agreeing / samples, 0–1. The card uses this to decide whether the guess is
  /// worth showing at all — a gate seen once in twelve is noise, not a pattern.
  confidence: number;
}

/// The gate a flight actually tends to use, from what the tracker has seen.
///
/// Airlines don't publish next month's gate assignments, so a connection more
/// than a day or two out has no gate to measure a walk between. But the same
/// flight number does tend back to the same pier: `gate_observations` has been
/// accumulating the real gate for every tracked flight, every day, and the mode
/// of that history is a far better guess than a flat "typical airport" number.
///
/// Recency-weighted, because a seasonal schedule change moves a flight to a new
/// pier and the old gates should lose to the new ones rather than outvote them
/// on sheer count. Observations are expected newest-first.
export function predictGate(
  observations: GateObservation[],
  direction: "departure" | "arrival",
): GatePrediction {
  const gateOf = (o: GateObservation) =>
    direction === "departure" ? o.dep_gate : o.arr_gate;
  const terminalOf = (o: GateObservation) =>
    direction === "departure" ? o.dep_terminal : o.arr_terminal;

  const withGate = observations.filter((o) => {
    const g = gateOf(o);
    return typeof g === "string" && g.trim() !== "";
  });
  if (withGate.length === 0) {
    return { gate: null, terminal: null, agreeing: 0, samples: 0, confidence: 0 };
  }

  // Newest observation carries the most weight, decaying to a floor so old
  // sightings still count for something.
  const weights = new Map<string, number>();
  const counts = new Map<string, number>();
  withGate.forEach((o, index) => {
    const gate = gateOf(o)!.trim().toUpperCase();
    const weight = Math.max(0.35, 1 - index * 0.08);
    weights.set(gate, (weights.get(gate) ?? 0) + weight);
    counts.set(gate, (counts.get(gate) ?? 0) + 1);
  });

  let best = "";
  let bestWeight = -1;
  for (const [gate, weight] of weights) {
    if (weight > bestWeight) { best = gate; bestWeight = weight; }
  }

  // The terminal reported alongside the winning gate — not the modal terminal
  // overall, which could name a terminal the winning gate isn't even in.
  const terminal = withGate.find((o) => gateOf(o)!.trim().toUpperCase() === best
    && typeof terminalOf(o) === "string" && terminalOf(o)!.trim() !== "");

  const agreeing = counts.get(best) ?? 0;
  return {
    gate: best,
    terminal: terminal ? terminalOf(terminal)!.trim() : null,
    agreeing,
    samples: withGate.length,
    confidence: agreeing / withGate.length,
  };
}

/// One flight's row off an airport FIDS board, either direction.
///
/// What the flight-by-number endpoint doesn't carry, the airport's own board
/// often does — this is the matching both directions of /arrival-gate share.
/// Rows are matched the way FIDS numbers them ("U2 1234" ≡ "U21234"); a board
/// that lists the flight but publishes no gate answers with nulls, which is
/// an answer ("no gate yet"), not a miss.
export interface BoardStand {
  gate: string | null;
  terminal: string | null;
  belt: string | null;
}

export function standFromBoard(
  rows: Record<string, any>[], flight: string,
): BoardStand | null {
  const wanted = flight.toUpperCase().replace(/\s+/g, "");
  const match = rows.find((r) =>
    String(r?.number ?? "").toUpperCase().replace(/\s+/g, "") === wanted);
  if (!match) return null;
  return {
    gate: match.movement?.gate ?? null,
    terminal: match.movement?.terminal ?? null,
    belt: match.movement?.baggageBelt ?? null,
  };
}
