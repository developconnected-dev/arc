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

/// Same floor as the device: a friend's delay is worth a buzz at fifteen
/// minutes more than last said, not at every minute of drift.
const FRIEND_DELAY_STEP = 15;

export function friendFlightNews(args: {
  flightId: string;
  travellerName: string;
  flightNumber: string;
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

  if (priorPhase !== "airborne" && phase === "airborne") {
    return { state, news: { kind: "tookOff", collapseId: id("tookoff"),
      title: `${args.travellerName} is in the air ✈️`, body: route } };
  }
  if (priorPhase !== "landed" && phase === "landed") {
    return { state, news: { kind: "landed", collapseId: id("landed"),
      title: `${args.travellerName} landed in ${args.arrivalCity} 🛬`, body: route } };
  }
  if (phase === "upcoming" && args.delayMinutes >= priorDelay + FRIEND_DELAY_STEP) {
    return { state, news: { kind: "delayed", collapseId: id("delayed"),
      title: `${args.travellerName}'s flight is ${args.delayMinutes}m late`, body: route } };
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
