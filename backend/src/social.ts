/// What a friend is told about someone else's flight, and when.
///
/// Pure on purpose, like alerts.ts. The delivery around it — which rows to
/// diff, whose tokens to send to — is plumbing in index.ts; this file is the
/// judgement, and it mirrors FriendAlerts.events on the device word for word
/// so a friend hears the same thing whether the server or the app said it.

export type FriendPhase = "upcoming" | "airborne" | "landed";

/// The phase an ALERT may claim — witnessed, never inferred. The feed and
/// map heal by the clock; a push is words on a lock screen with no muted
/// colour to hedge them, so "Anna is in the air" waits for a source: a
/// reported departure, the provider calling the leg active, or a fresh
/// airborne sighting. Landed only from the status. Mirrors
/// FriendFlightMath.witnessedPhase and DepartureEvidence.phase(at:).
const FRESH_WINDOW_MS = 15 * 60_000;

export function witnessedPhase(row: {
  status: string;
  actual_departure?: string | null;
  ground_state?: string | null;
  ground_observed_at?: string | null;
}, now: number): FriendPhase {
  if (row.status === "landed") return "landed";
  if (row.status === "active" || row.status === "diverted") return "airborne";
  const actual = row.actual_departure ? Date.parse(row.actual_departure) : NaN;
  if (Number.isFinite(actual) && actual <= now) return "airborne";
  const seen = row.ground_observed_at ? Date.parse(row.ground_observed_at) : NaN;
  const fresh = Number.isFinite(seen) && seen <= now && now - seen < FRESH_WINDOW_MS;
  if (fresh && row.ground_state === "airborne") return "airborne";
  return "upcoming";
}

export interface FriendAlertState {
  phase?: FriendPhase;
  delay?: number;
}

export interface FriendNews {
  kind: "tookOff" | "landed" | "delayed";
  collapseId: string;
  title: string;
  body: string;
}

/// A ferry is not in the air and a train does not land. The words per mode,
/// mirroring TripMode's verbs and FriendAlerts.wording on the device. A row
/// with no mode, or one this build doesn't know, is a flight — what every row
/// was before migration 012.
function friendWords(mode: string | null | undefined): {
  underway: string; arrived: (city: string) => string; noun: string;
} {
  if (mode === "sea") return { underway: "is at sea ⛴️", arrived: (city) => `arrived in ${city} ⛴️`, noun: "ferry" };
  if (mode === "rail") return { underway: "is en route 🚆", arrived: (city) => `arrived in ${city} 🚆`, noun: "train" };
  return { underway: "is in the air ✈️", arrived: (city) => `landed in ${city} 🛬`, noun: "flight" };
}

/// Same floor as the device: a friend's delay is worth a buzz at fifteen
/// minutes more than last said, not at every minute of drift.
const FRIEND_DELAY_STEP = 15;

export function friendFlightNews(args: {
  flightId: string;
  travellerName: string;
  flightNumber: string;
  /// 'air' | 'rail' | 'sea' — shared_flights.mode.
  mode?: string | null;
  departureIata: string;
  arrivalIata: string;
  arrivalCity: string;
  status: string;
  delayMinutes: number;
  actualDeparture: string | null;
  groundState: string | null;
  groundObservedAt: string | null;
  now: number;
  prior: FriendAlertState;
}): { news: FriendNews | null; state: FriendAlertState } {
  const phase = witnessedPhase({
    status: args.status, actual_departure: args.actualDeparture,
    ground_state: args.groundState, ground_observed_at: args.groundObservedAt,
  }, args.now);
  const state: FriendAlertState = { phase, delay: args.delayMinutes };

  // A cancelled flight has no take-off, landing or delay to announce.
  if (args.status === "cancelled") return { news: null, state };
  // First sight records silently — no spam when a friend connects mid-trip.
  if (!args.prior.phase) return { news: null, state };

  const route = `${args.flightNumber} ${args.departureIata} → ${args.arrivalIata}`;
  const priorPhase = args.prior.phase;
  const priorDelay = args.prior.delay ?? 0;
  const id = (kind: string) => `friend-${args.flightId}-${kind}`;
  const words = friendWords(args.mode);

  if (priorPhase !== "airborne" && phase === "airborne") {
    return { state, news: { kind: "tookOff", collapseId: id("tookoff"),
      title: `${args.travellerName} ${words.underway}`, body: route } };
  }
  if (priorPhase !== "landed" && phase === "landed") {
    return { state, news: { kind: "landed", collapseId: id("landed"),
      title: `${args.travellerName} ${words.arrived(args.arrivalCity)}`, body: route } };
  }
  if (phase === "upcoming" && args.delayMinutes >= priorDelay + FRIEND_DELAY_STEP) {
    return { state, news: { kind: "delayed", collapseId: id("delayed"),
      title: `${args.travellerName}'s ${words.noun} is ${args.delayMinutes}m late`, body: route } };
  }
  return { news: null, state };
}

/// "Carl added a trip for you together" — the invite waits at the top of My
/// Trips, so the body says where to find it. Mirrors
/// ArcNotifications.notifyTripInvite.
export function tripInviteNews(args: {
  senderName: string;
  departureCity: string;
  arrivalCity: string;
  scheduledDeparture: string;
}): { title: string; body: string } {
  const route = [args.departureCity, args.arrivalCity].filter(c => !!c).join(" → ");
  const dep = Date.parse(args.scheduledDeparture);
  const when = Number.isFinite(dep)
    ? new Date(dep).toLocaleDateString("en-US", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" })
    : "";
  const detail = [route, when].filter(s => !!s).join(" · ");
  const tail = "Accept it in My Trips to add it to your list.";
  return {
    title: `${args.senderName} added a trip for you together`,
    body: detail ? `${detail}. ${tail}` : tail,
  };
}

/// Who hears about a traveller's flight: accepted friends in either direction,
/// narrowed to the row's audience when it has one, minus anyone who muted the
/// traveller — and never the traveller.
export function recipientsFor(args: {
  travellerId: string;
  audience: string[] | null;
  friendships: { requester_id: string; addressee_id: string; status: string }[];
  profiles: { id: string; muted_friends?: string[] | null }[];
}): string[] {
  const { travellerId, audience } = args;
  const muted = new Set(
    args.profiles.filter(p => (p.muted_friends ?? []).includes(travellerId)).map(p => p.id));
  const out = new Set<string>();
  for (const f of args.friendships) {
    if (f.status !== "accepted") continue;
    const other = f.requester_id === travellerId ? f.addressee_id
      : f.addressee_id === travellerId ? f.requester_id : null;
    if (!other || other === travellerId) continue;
    if (audience && !audience.includes(other)) continue;
    if (muted.has(other)) continue;
    out.add(other);
  }
  return [...out];
}

// ── "Anna is at ZRH too" ──

export interface OverlapFlight {
  id: string;
  flight_number: string;
  departure_iata: string;
  arrival_iata: string;
  scheduled_departure: string;
  scheduled_arrival: string;
  delay_minutes: number;
  status: string;
  estimated_arrival?: string | null;
  actual_arrival?: string | null;
}

export interface AirportOverlap {
  friendId: string;
  friendName: string;
  airport: string;
  windowStart: number;
  windowEnd: number;
  myFlightId: string;
}

const HOUR = 3600_000;
/// Same rules as FriendsStore.airportOverlaps on the device.
const OVERLAP_WINDOW = 3 * HOUR;
const OVERLAP_GRACE = 6 * HOUR;
const COMPANION_ROTATION = 18 * HOUR;

function effectiveDeparture(f: OverlapFlight): number {
  return Date.parse(f.scheduled_departure) + (f.delay_minutes ?? 0) * 60_000;
}

function effectiveArrival(f: OverlapFlight): number {
  const dep = effectiveDeparture(f);
  const actual = f.actual_arrival ? Date.parse(f.actual_arrival) : NaN;
  if (Number.isFinite(actual) && actual > dep) return actual;
  const est = f.estimated_arrival ? Date.parse(f.estimated_arrival) : NaN;
  if (Number.isFinite(est) && est > dep) return est;
  return Date.parse(f.scheduled_arrival) + (f.delay_minutes ?? 0) * 60_000;
}

function norm(n: string): string { return n.replace(/\s+/g, "").toUpperCase(); }

/// The coincidences: a friend at one of my airports within three hours of
/// me, on a flight that is NOT mine — a companion on the same journey is
/// shown on the flight itself, not announced as a meeting.
export function airportOverlaps(args: {
  mine: OverlapFlight[];
  friends: { id: string; name: string; flights: OverlapFlight[] }[];
  now: number;
}): AirportOverlap[] {
  const { now } = args;
  const found: AirportOverlap[] = [];
  const seen = new Set<string>();
  for (const my of args.mine) {
    if (my.status === "cancelled") continue;
    const myDep = effectiveDeparture(my), myArr = effectiveArrival(my);
    const myDepIata = my.departure_iata.toUpperCase(), myArrIata = my.arrival_iata.toUpperCase();
    const myNumber = norm(my.flight_number);
    for (const friend of args.friends) {
      for (const f of friend.flights) {
        if (f.status === "cancelled") continue;
        const fDep = effectiveDeparture(f), fArr = effectiveArrival(f);
        if (myNumber && norm(f.flight_number) === myNumber
            && Math.abs(fDep - Date.parse(my.scheduled_departure)) < COMPANION_ROTATION) continue;
        const fDepIata = f.departure_iata.toUpperCase(), fArrIata = f.arrival_iata.toUpperCase();

        let airport: string | null = null, start = 0, end = 0;
        if (myDepIata === fDepIata
            && Math.abs(myDep - fDep) <= OVERLAP_WINDOW && myDep > now - OVERLAP_GRACE) {
          airport = myDepIata;
          start = Math.min(myDep, fDep) - HOUR;
          end = Math.max(myDep, fDep);
        } else if (myArrIata === fDepIata || myDepIata === fArrIata || myArrIata === fArrIata) {
          // My time at the shared airport, and theirs.
          const myT = myDepIata === fArrIata ? myDep : myArr;
          const fT = fDepIata === myArrIata ? fDep : fArr;
          if (Math.abs(myT - fT) <= OVERLAP_WINDOW && myT > now - OVERLAP_GRACE) {
            airport = myArrIata === fDepIata ? myArrIata : fArrIata;
            start = Math.min(myT, fT) - HOUR;
            end = Math.max(myT, fT) + HOUR;
          }
        }
        if (!airport) continue;
        const key = `${friend.id}|${airport}`;
        if (seen.has(key)) continue;
        seen.add(key);
        found.push({ friendId: friend.id, friendName: friend.name, airport,
                     windowStart: start, windowEnd: end, myFlightId: my.id });
      }
    }
  }
  return found;
}

/// Mirrors ArcNotifications.notifyAirportOverlap: the window in the
/// airport's own zone, "today" judged there too.
export function overlapNews(args: {
  friendName: string; airport: string; windowStart: number; windowEnd: number;
  timeZone: string | null | undefined; now: number;
}): { title: string; body: string } {
  const zone = args.timeZone || "UTC";
  const hm = (ms: number) => {
    try {
      return new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit", hour12: false, timeZone: zone })
        .format(new Date(ms));
    } catch {
      return new Date(ms).toISOString().slice(11, 16);
    }
  };
  const day = (ms: number) => {
    try {
      return new Intl.DateTimeFormat("en-CA", { year: "numeric", month: "2-digit", day: "2-digit", timeZone: zone })
        .format(new Date(ms));
    } catch {
      return new Date(ms).toISOString().slice(0, 10);
    }
  };
  const today = day(args.windowStart) === day(args.now);
  return {
    title: `${args.friendName} is at ${args.airport} too`,
    body: `You're both there ${today ? "today" : "in the same window"} · ${hm(args.windowStart)} - ${hm(args.windowEnd)}.`,
  };
}
