/// What is worth waking a phone for, and what has already been said.
///
/// Pure on purpose. The delivery around it (which rows to look at, which
/// tokens to send to) is plumbing; the judgement — is this news, or is it the
/// same delay restated for the fourth hour running — is the part that decides
/// whether Arc is useful or is the app you mute.

export interface WatchState {
  /// The delay, in minutes, that was last announced.
  delay?: number;
  /// The gate that was last announced.
  gate?: string;
  /// Set once the cancellation has been announced.
  cancelled?: boolean;
  /// Set while the provider's "may be cancelled" guess has been announced —
  /// cleared (with a banner) when the guess clears, unlike `cancelled`,
  /// which is a fact and latches.
  uncertainSaid?: boolean;
}

/// The Settings toggles, as the device mirrors them into
/// profiles.notify_prefs. Absent means on. A cancellation has no toggle.
export interface NotifyPrefs {
  delays?: boolean;
  gates?: boolean;
  landing?: boolean;
}

export type AlertKind = "cancelled" | "uncertain" | "delay" | "gate";

export interface AlertNews {
  kind: AlertKind;
  /// Stable per fact, so a re-statement REPLACES the banner already on the
  /// lock screen rather than stacking a second, contradictory one.
  collapseId: string;
  title: string;
  body: string;
  /// The state to remember once this has been sent.
  state: WatchState;
}

/// A delay only becomes news once it is worth re-planning around, and only
/// again when it has moved enough that the earlier number is misleading.
const DELAY_FLOOR = 15;
const DELAY_STEP = 10;
/// Gates published more than this far out are provisional and churn; saying
/// so hourly would train the user to ignore Arc.
const GATE_HORIZON_MS = 6 * 3600_000;

/// The leg's own words — LocalAlertNews.vehicle and TripMode's
/// boardingPointLabel/operatorNoun on the device. No mode, or one this
/// build doesn't know, is a flight.
function legWords(mode: string | null | undefined): {
  noun: string; plural: string; place: string; point: string; operator: string;
} {
  if (mode === "sea") return { noun: "ferry", plural: "ferries", place: "port", point: "berth", operator: "ferry operator" };
  if (mode === "rail") return { noun: "train", plural: "trains", place: "station", point: "platform", operator: "operator" };
  return { noun: "flight", plural: "flights", place: "airport", point: "gate", operator: "airline" };
}

export function flightNews(args: {
  flightNumber: string;
  /// 'air' | 'rail' | 'sea' — user_flights.mode.
  mode?: string | null;
  arrivalCity: string;
  status: string;
  delayMinutes: number;
  departureGate: string | null;
  scheduledDeparture: number;
  now: number;
  prior: WatchState;
  /// The provider's own "likely cancelled" guess (AeroDataBox
  /// canceledUncertain) — rescheduled flights that go on to operate carry it
  /// routinely, so it draws a hedged heads-up, never the rebooking advice.
  cancelUncertain?: boolean;
}): AlertNews | null {
  const { flightNumber, arrivalCity, status, delayMinutes, departureGate, prior } = args;
  const state: WatchState = { ...prior };
  const w = legWords(args.mode);
  const Point = w.point[0].toUpperCase() + w.point.slice(1);

  // A cancellation outranks everything else and is said exactly once.
  if (status === "cancelled") {
    if (prior.cancelled) return null;
    state.cancelled = true;
    return {
      kind: "cancelled",
      collapseId: `${flightNumber}-cancelled`,
      title: `${flightNumber} is cancelled`,
      body: `Your ${w.noun} to ${arrivalCity} won't operate. Rebooking now beats rebooking at the ${w.place}.`,
      state,
    };
  }
  // Once cancelled, a provider flipping back to "scheduled" is a data glitch
  // far more often than a reinstated flight; don't chase it with a banner.
  if (prior.cancelled) return null;

  // The guess: said once, on the cancellation's collapse id so a later fact
  // REPLACES it on the lock screen — and deliberately NOT latched like one,
  // so the delay and gate news below keep flowing for a flight that is
  // probably still operating.
  if (args.cancelUncertain && !prior.uncertainSaid) {
    state.uncertainSaid = true;
    return {
      kind: "uncertain",
      collapseId: `${flightNumber}-cancelled`,
      title: `${flightNumber} may be cancelled`,
      body: `The data feed flags your ${w.noun} to ${arrivalCity} as possibly cancelled — `
        + `rescheduled ${w.plural} sometimes carry this mark. Worth checking with the ${w.operator}.`,
      state,
    };
  }
  // A guess that clears is worth one line, same as a delay that clears:
  // whoever saw "may be cancelled" is still wondering.
  if (!args.cancelUncertain && prior.uncertainSaid) {
    state.uncertainSaid = false;
    return {
      kind: "uncertain",
      collapseId: `${flightNumber}-cancelled`,
      title: `${flightNumber} looks like it's operating`,
      body: `The possibly-cancelled flag on your ${w.noun} to ${arrivalCity} has cleared.`,
      state,
    };
  }

  const announced = prior.delay ?? 0;
  if (delayMinutes >= DELAY_FLOOR && Math.abs(delayMinutes - announced) >= DELAY_STEP) {
    state.delay = delayMinutes;
    const improving = delayMinutes < announced;
    return {
      kind: "delay",
      collapseId: `${flightNumber}-delay`,
      title: `${flightNumber} is ${delayText(delayMinutes)} late`,
      body: improving
        ? `Down from ${announced}m. Now departing about ${delayMinutes} minutes behind schedule.`
        : `Departure to ${arrivalCity} is running about ${delayMinutes} minutes behind schedule.`,
      state,
    };
  }
  // A delay that has cleared is worth one line — people re-plan around these.
  if (announced >= DELAY_FLOOR && delayMinutes < DELAY_FLOOR) {
    state.delay = delayMinutes;
    return {
      kind: "delay",
      collapseId: `${flightNumber}-delay`,
      title: `${flightNumber} is back on schedule`,
      body: `The ${announced}m delay has cleared.`,
      state,
    };
  }

  if (departureGate && departureGate !== prior.gate
      && args.scheduledDeparture - args.now < GATE_HORIZON_MS) {
    const moved = !!prior.gate;
    state.gate = departureGate;
    return {
      kind: "gate",
      collapseId: `${flightNumber}-gate`,
      title: moved ? `${flightNumber} moved to ${w.point} ${departureGate}`
                   : `${flightNumber} departs from ${w.point} ${departureGate}`,
      body: moved ? `Changed from ${w.point} ${prior.gate}.` : `${Point} is now published.`,
      state,
    };
  }

  return null;
}

/// What the user's Settings let through. The watcher still RECORDS a fact
/// it does not send, so switching the toggle back on does not replay it.
export function applyPrefs(news: AlertNews, prefs: NotifyPrefs | null | undefined): AlertNews | null {
  if (news.kind === "delay" && prefs?.delays === false) return null;
  if (news.kind === "gate" && prefs?.gates === false) return null;
  return news;
}

/// The banner a Live Activity UPDATE push may carry, or null for a silent
/// card repaint.
///
/// An LA update fires on every data change — a status flip, a belt
/// appearing, a taxi sighting — but the BANNER is only for news a person
/// re-plans around: the gate moving, or the delay changing materially. It
/// used to ride `dataChanged` wholesale with the gate as its text, so once
/// a gate existed every unrelated change re-bannered the same
/// "Gate A64 · 25m late", over and over, for the whole boarding hour.
export function laAlert(args: {
  flightNumber: string;
  priorGate: string | null;
  gate: string | null;
  priorDelay: number;
  delay: number;
  /// The Settings toggles: a part the user switched off is left out, and a
  /// banner with nothing left is no banner.
  prefs?: NotifyPrefs | null;
}): { title: string; body: string } | null {
  const { flightNumber, priorGate, gate, priorDelay, delay } = args;
  const gateChanged = !!gate && gate !== priorGate && args.prefs?.gates !== false;
  // Same floor and step as the watcher's delay news: a move under ten
  // minutes, or churn entirely below the fifteen-minute floor, is not news.
  const delayMoved = Math.abs(delay - priorDelay) >= 10
    && (delay >= 15 || priorDelay >= 15)
    && args.prefs?.delays !== false;
  if (!gateChanged && !delayMoved) return null;
  const parts: string[] = [];
  if (gateChanged && gate) parts.push(`Gate ${gate}`);
  if (delay > 0 && args.prefs?.delays !== false) parts.push(`${delayText(delay)} late`);
  else if (delayMoved) parts.push("back on schedule");
  if (parts.length === 0) return null;
  return { title: `${flightNumber} update`, body: parts.join(" · ") };
}

/// A delay as a duration: "16m", "1h", "2h 25m". Mirrors FlightClock.delayText
/// on the device, so a banner and the row beneath it say the same thing.
export function delayText(minutes: number): string {
  const h = Math.floor(minutes / 60), m = minutes % 60;
  if (h >= 1) return m > 0 ? `${h}h ${m}m` : `${h}h`;
  return `${minutes}m`;
}
