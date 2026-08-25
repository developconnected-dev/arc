import test from "node:test";
import assert from "node:assert/strict";
import { predictionConfirmed, leadMinutes, summarise, PREDICTION_TOLERANCE_MIN } from "../src/prediction.ts";

test("the airline reaching what Arc said confirms it", () => {
  assert.equal(predictionConfirmed(45, 45), true);
  assert.equal(predictionConfirmed(45, 60), true);
});

test("...and it does not have to agree to the minute", () => {
  assert.equal(predictionConfirmed(45, 45 - PREDICTION_TOLERANCE_MIN), true);
  assert.equal(predictionConfirmed(45, 34), false);
});

test("nothing published is not a confirmation", () => {
  assert.equal(predictionConfirmed(45, 0), false);
  assert.equal(predictionConfirmed(45, NaN), false);
});

test("the lead is the gap between Arc saying it and the airline saying it", () => {
  assert.equal(leadMinutes("2026-08-25T10:00:00Z", "2026-08-25T11:30:00Z"), 90);
});

/// Not clamped, deliberately. A prediction that landed after the airline's own
/// filing is a real outcome, and hiding it would flatter the average — which is
/// the one thing this measurement must not do.
test("a prediction that arrived LATE is recorded as negative, not as zero", () => {
  assert.equal(leadMinutes("2026-08-25T11:00:00Z", "2026-08-25T10:45:00Z"), -15);
});

test("an unresolved or unreadable pair has no lead", () => {
  assert.equal(leadMinutes("2026-08-25T10:00:00Z", null), null);
  assert.equal(leadMinutes(null, "2026-08-25T10:00:00Z"), null);
  assert.equal(leadMinutes("nonsense", "2026-08-25T10:00:00Z"), null);
});

const row = (mins: number, official: number, at: string, confirmed: string | null) => ({
  predicted_minutes: mins, official_minutes_at_prediction: official,
  predicted_at: at, confirmed_at: confirmed,
});

test("the summary reports the median, and says what it left out", () => {
  const s = summarise([
    row(40, 0, "2026-08-25T10:00:00Z", "2026-08-25T11:00:00Z"),   // 60
    row(50, 0, "2026-08-25T10:00:00Z", "2026-08-25T10:20:00Z"),   // 20
    row(30, 0, "2026-08-25T10:00:00Z", "2026-08-25T12:00:00Z"),   // 120
    row(25, 0, "2026-08-25T10:00:00Z", null),                     // never confirmed
  ]);
  assert.equal(s.predictions, 4);
  assert.equal(s.confirmed, 3);
  assert.equal(s.unconfirmed, 1);
  assert.equal(s.medianLeadMinutes, 60);
  assert.equal(s.bestLeadMinutes, 120);
  assert.equal(s.worstLeadMinutes, 20);
});

/// The median leads the mean for a reason: one airline sitting on a six-hour
/// cancellation would drag an average into a number nobody should print, and
/// stopping a number nobody should print from reaching a landing page is the
/// entire purpose of this measurement.
test("one enormous outlier moves the mean and not the median", () => {
  const rows = [
    row(40, 0, "2026-08-25T10:00:00Z", "2026-08-25T10:30:00Z"),   // 30
    row(40, 0, "2026-08-25T10:00:00Z", "2026-08-25T10:40:00Z"),   // 40
    row(40, 0, "2026-08-25T10:00:00Z", "2026-08-25T16:00:00Z"),   // 360
  ];
  const s = summarise(rows);
  assert.equal(s.medianLeadMinutes, 40);
  assert.equal(s.meanLeadMinutes, 143);
});

/// An "echo" is a prediction that merely restated a delay the airline had
/// already filed. `RotationChain.predictDelay` is supposed to stay silent
/// unless it beats the official number by ten minutes, so a non-zero count
/// here is a bug in the predictor — not a slow airline, and certainly not a
/// lead time to boast about.
test("a prediction that only restated a published delay is counted as an echo", () => {
  const s = summarise([
    row(40, 45, "2026-08-25T10:00:00Z", "2026-08-25T10:01:00Z"),
    row(40, 0, "2026-08-25T10:00:00Z", "2026-08-25T11:00:00Z"),
  ]);
  assert.equal(s.echoes, 1);
});

test("nothing measured yet is empty rather than zero", () => {
  const s = summarise([]);
  assert.equal(s.predictions, 0);
  assert.equal(s.medianLeadMinutes, null);
  assert.equal(s.meanLeadMinutes, null);
});
