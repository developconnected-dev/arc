// Pure arithmetic for the delay-prediction measurement — no network, no env,
// so every rule here is unit-testable without a live call.
//
// The question being measured: how much earlier does Arc's knock-on prediction
// fire than the airline's own published delay? Arc predicts from physics (the
// inbound aircraft cannot land, turn around and leave on time); the airline
// publishes when operations gives up on recovering it. The gap between those
// two moments is the only speed claim Arc can honestly make.

/// How close the airline has to get before we call a prediction confirmed.
///
/// Arc predicts a departure time, the airline files one, and they will not
/// agree to the minute — nor should they have to. Ten minutes is the same
/// threshold `RotationChain.predictDelay` uses to decide a prediction is worth
/// making at all, so confirmation is judged on the scale the prediction was
/// made on.
export const PREDICTION_TOLERANCE_MIN = 10;

/// Has the airline's own number caught up with what Arc said?
export function predictionConfirmed(predictedMinutes: number, officialMinutes: number): boolean {
  if (!Number.isFinite(predictedMinutes) || !Number.isFinite(officialMinutes)) return false;
  return officialMinutes >= predictedMinutes - PREDICTION_TOLERANCE_MIN;
}

/// Minutes between Arc saying it and the airline saying it, or null when the
/// pair cannot be read. Negative is possible and is NOT clamped: a prediction
/// that arrived after the airline's own filing is a real outcome, and hiding it
/// would flatter the average.
export function leadMinutes(predictedAt: unknown, confirmedAt: unknown): number | null {
  const p = Date.parse(String(predictedAt ?? ""));
  const c = Date.parse(String(confirmedAt ?? ""));
  if (!Number.isFinite(p) || !Number.isFinite(c)) return null;
  return Math.round((c - p) / 60_000);
}

export interface PredictionRow {
  predicted_minutes?: number;
  official_minutes_at_prediction?: number;
  predicted_at?: string;
  confirmed_at?: string | null;
  official_minutes_at_confirmation?: number | null;
}

export interface PredictionSummary {
  predictions: number;
  confirmed: number;
  unconfirmed: number;
  /// Minutes of lead, over the CONFIRMED ones only — stated alongside the
  /// unconfirmed count so the reader can see what the average leaves out.
  medianLeadMinutes: number | null;
  meanLeadMinutes: number | null;
  bestLeadMinutes: number | null;
  worstLeadMinutes: number | null;
  /// Predictions that merely restated a delay the airline had already filed.
  /// These are not leads and must not be counted as any: `RotationChain` is
  /// supposed to stay silent unless it beats the official number by ten, so a
  /// non-zero count here is a bug in the predictor, not a slow airline.
  echoes: number;
}

/// The whole picture, in the shape a person can argue with.
///
/// The median leads the mean deliberately. One flight whose airline sat on a
/// six-hour cancellation would drag an average into a number nobody should
/// print, and this measurement exists precisely to stop a number nobody should
/// print from reaching a landing page.
export function summarise(rows: PredictionRow[]): PredictionSummary {
  const leads: number[] = [];
  let confirmed = 0, echoes = 0;
  for (const r of rows) {
    if ((r.official_minutes_at_prediction ?? 0) >= (r.predicted_minutes ?? 0)) echoes++;
    if (!r.confirmed_at) continue;
    confirmed++;
    const lead = leadMinutes(r.predicted_at, r.confirmed_at);
    if (lead !== null) leads.push(lead);
  }
  leads.sort((a, b) => a - b);
  const median = leads.length === 0 ? null
    : leads.length % 2 === 1 ? leads[(leads.length - 1) / 2]!
    : Math.round((leads[leads.length / 2 - 1]! + leads[leads.length / 2]!) / 2);
  return {
    predictions: rows.length,
    confirmed,
    unconfirmed: rows.length - confirmed,
    medianLeadMinutes: median ?? null,
    meanLeadMinutes: leads.length ? Math.round(leads.reduce((a, b) => a + b, 0) / leads.length) : null,
    bestLeadMinutes: leads.length ? leads[leads.length - 1]! : null,
    worstLeadMinutes: leads.length ? leads[0]! : null,
    echoes,
  };
}
