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

export interface AlertNews {
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

export function flightNews(args: {
  flightNumber: string;
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

  // A cancellation outranks everything else and is said exactly once.
  if (status === "cancelled") {
    if (prior.cancelled) return null;
    state.cancelled = true;
    return {
      collapseId: `${flightNumber}-cancelled`,
      title: `${flightNumber} is cancelled`,
      body: `Your flight to ${arrivalCity} won't operate. Rebooking now beats rebooking at the airport.`,
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
      collapseId: `${flightNumber}-cancelled`,
      title: `${flightNumber} may be cancelled`,
      body: `The data feed flags your flight to ${arrivalCity} as possibly cancelled — `
        + `rescheduled flights sometimes carry this mark. Worth checking with the airline.`,
      state,
    };
  }
  // A guess that clears is worth one line, same as a delay that clears:
  // whoever saw "may be cancelled" is still wondering.
  if (!args.cancelUncertain && prior.uncertainSaid) {
    state.uncertainSaid = false;
    return {
      collapseId: `${flightNumber}-cancelled`,
      title: `${flightNumber} looks like it's operating`,
      body: `The possibly-cancelled flag on your flight to ${arrivalCity} has cleared.`,
      state,
    };
  }

  const announced = prior.delay ?? 0;
  if (delayMinutes >= DELAY_FLOOR && Math.abs(delayMinutes - announced) >= DELAY_STEP) {
    state.delay = delayMinutes;
    const improving = delayMinutes < announced;
    return {
      collapseId: `${flightNumber}-delay`,
      title: `${flightNumber} is ${delayMinutes}m late`,
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
      collapseId: `${flightNumber}-gate`,
      title: moved ? `${flightNumber} moved to gate ${departureGate}`
                   : `${flightNumber} departs from gate ${departureGate}`,
      body: moved ? `Changed from gate ${prior.gate}.` : `Gate is now published.`,
      state,
    };
  }

  return null;
}
