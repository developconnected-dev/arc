import test from "node:test";
import assert from "node:assert/strict";
import {
  witnessedPhase, friendFlightNews, tripInviteNews, recipientsFor,
  type FriendAlertState,
} from "../src/social.ts";

const NOW = Date.parse("2026-07-24T12:00:00Z");
const iso = (ms: number) => new Date(ms).toISOString();

const row = {
  flightId: "f1",
  travellerName: "Anna",
  flightNumber: "LX2084",
  departureIata: "ZRH",
  arrivalIata: "LIS",
  arrivalCity: "Lisbon",
  status: "scheduled",
  delayMinutes: 0,
  actualDeparture: null as string | null,
  groundState: null as string | null,
  groundObservedAt: null as string | null,
  now: NOW,
  prior: {} as FriendAlertState,
};

// ── witnessedPhase: an alert may only claim what a source said ──

test("the clock alone never makes a flight airborne", () => {
  assert.equal(witnessedPhase({ status: "scheduled" }, NOW), "upcoming");
});

test("the provider calling the leg active is a takeoff witness", () => {
  assert.equal(witnessedPhase({ status: "active" }, NOW), "airborne");
  assert.equal(witnessedPhase({ status: "diverted" }, NOW), "airborne");
});

test("a reported departure in the past is a takeoff witness; one still ahead is a filing", () => {
  assert.equal(witnessedPhase({ status: "scheduled", actual_departure: iso(NOW - 60_000) }, NOW), "airborne");
  assert.equal(witnessedPhase({ status: "scheduled", actual_departure: iso(NOW + 60_000) }, NOW), "upcoming");
});

test("a fresh airborne sighting counts; a stale one does not", () => {
  assert.equal(witnessedPhase({ status: "scheduled", ground_state: "airborne",
    ground_observed_at: iso(NOW - 5 * 60_000) }, NOW), "airborne");
  assert.equal(witnessedPhase({ status: "scheduled", ground_state: "airborne",
    ground_observed_at: iso(NOW - 40 * 60_000) }, NOW), "upcoming");
});

test("landed comes only from the status", () => {
  assert.equal(witnessedPhase({ status: "landed" }, NOW), "landed");
});

// ── friendFlightNews: the diff against what friends were last told ──

test("first sight of a flight records silently", () => {
  const r = friendFlightNews({ ...row, status: "active" });
  assert.equal(r.news, null);
  assert.equal(r.state.phase, "airborne");
});

test("a witnessed takeoff after an upcoming baseline is news", () => {
  const r = friendFlightNews({ ...row, status: "active", prior: { phase: "upcoming", delay: 0 } });
  assert.ok(r.news);
  assert.equal(r.news!.kind, "tookOff");
  assert.match(r.news!.title, /Anna is in the air/);
  assert.match(r.news!.body, /LX2084 ZRH → LIS/);
  assert.equal(r.state.phase, "airborne");
});

test("the same takeoff is not said twice", () => {
  const first = friendFlightNews({ ...row, status: "active", prior: { phase: "upcoming", delay: 0 } });
  const again = friendFlightNews({ ...row, status: "active", prior: first.state });
  assert.equal(again.news, null);
});

test("a landing is news once the status says so", () => {
  const r = friendFlightNews({ ...row, status: "landed", prior: { phase: "airborne", delay: 0 } });
  assert.equal(r.news!.kind, "landed");
  assert.match(r.news!.title, /Anna landed in Lisbon/);
});

test("a landing discovered from an upcoming baseline is still a landing, not a takeoff", () => {
  const r = friendFlightNews({ ...row, status: "landed", prior: { phase: "upcoming", delay: 0 } });
  assert.equal(r.news!.kind, "landed");
});

test("a delay growing by fifteen minutes before departure is news", () => {
  const r = friendFlightNews({ ...row, delayMinutes: 20, prior: { phase: "upcoming", delay: 0 } });
  assert.equal(r.news!.kind, "delayed");
  assert.match(r.news!.title, /Anna's flight is 20m late/);
  assert.equal(r.state.delay, 20);
});

test("a delay creeping by less than fifteen minutes is not", () => {
  const r = friendFlightNews({ ...row, delayMinutes: 14, prior: { phase: "upcoming", delay: 0 } });
  assert.equal(r.news, null);
  // The baseline still moves, so the next fifteen is measured from here.
  assert.equal(r.state.delay, 14);
});

test("delay news stops once the flight is airborne", () => {
  const r = friendFlightNews({ ...row, status: "active", delayMinutes: 40, prior: { phase: "airborne", delay: 0 } });
  assert.equal(r.news, null);
});

test("a cancelled flight has nothing to announce", () => {
  const r = friendFlightNews({ ...row, status: "cancelled", delayMinutes: 90, prior: { phase: "upcoming", delay: 0 } });
  assert.equal(r.news, null);
});

test("each fact has its own collapse id so a takeoff never replaces a landing", () => {
  const t = friendFlightNews({ ...row, status: "active", prior: { phase: "upcoming", delay: 0 } }).news!;
  const l = friendFlightNews({ ...row, status: "landed", prior: { phase: "airborne", delay: 0 } }).news!;
  assert.notEqual(t.collapseId, l.collapseId);
  assert.match(t.collapseId, /f1/);
});

// ── tripInviteNews ──

test("a trip invite names the sender and the journey", () => {
  const n = tripInviteNews({ senderName: "Carl", departureCity: "Zurich", arrivalCity: "Lisbon",
    scheduledDeparture: "2026-07-24T11:30:00Z" });
  assert.equal(n.title, "Carl added a trip for you together");
  assert.match(n.body, /Zurich → Lisbon/);
  assert.match(n.body, /Accept it in My Trips/);
});

test("a trip invite with no cities still names the day", () => {
  const n = tripInviteNews({ senderName: "Carl", departureCity: "", arrivalCity: "",
    scheduledDeparture: "2026-07-24T11:30:00Z" });
  assert.match(n.body, /^Fri, Jul 24\. Accept it in My Trips/);
});

test("a trip invite with nothing to say about the journey still reads", () => {
  const n = tripInviteNews({ senderName: "Carl", departureCity: "", arrivalCity: "", scheduledDeparture: "" });
  assert.equal(n.body, "Accept it in My Trips to add it to your list.");
});

// ── recipientsFor: who hears about a traveller's flight ──

const friendships = [
  { requester_id: "anna", addressee_id: "carl", status: "accepted" },
  { requester_id: "bea", addressee_id: "anna", status: "accepted" },
  { requester_id: "anna", addressee_id: "dan", status: "pending" },
];

test("accepted friends in either direction hear it; pending ones do not", () => {
  const r = recipientsFor({ travellerId: "anna", audience: null, friendships, profiles: [] });
  assert.deepEqual(r.sort(), ["bea", "carl"]);
});

test("a flight shared to an audience reaches only that audience", () => {
  const r = recipientsFor({ travellerId: "anna", audience: ["carl"], friendships, profiles: [] });
  assert.deepEqual(r, ["carl"]);
});

test("a friend who muted the traveller is left alone", () => {
  const r = recipientsFor({ travellerId: "anna", audience: null, friendships,
    profiles: [{ id: "carl", muted_friends: ["anna"] }] });
  assert.deepEqual(r, ["bea"]);
});

test("the traveller never hears about their own flight", () => {
  const r = recipientsFor({ travellerId: "anna", audience: ["anna", "carl"], friendships, profiles: [] });
  assert.deepEqual(r, ["carl"]);
});

// ── airportOverlaps: "Anna is at ZRH too" ──
//
// Mirrors FriendsStore.airportOverlaps on the device: a friend at one of my
// airports within three hours of me, on a flight that is NOT mine. Times are
// the effective ones (schedule plus delay).
import { airportOverlaps, overlapNews } from "../src/social.ts";

const T0 = Date.parse("2026-09-20T10:00:00Z");
const mine = (over: Partial<Parameters<typeof airportOverlaps>[0]["mine"][0]> = {}) => ({
  id: "my1", flight_number: "GQ21", departure_iata: "JSY", arrival_iata: "ATH",
  scheduled_departure: iso(T0), scheduled_arrival: iso(T0 + 45 * 60_000),
  delay_minutes: 0, status: "scheduled", ...over,
});
const theirs = (over: Record<string, unknown> = {}) => ({
  id: "s1", flight_number: "OA123", departure_iata: "ATH", arrival_iata: "LHR",
  scheduled_departure: iso(T0 + 120 * 60_000), scheduled_arrival: iso(T0 + 340 * 60_000),
  delay_minutes: 0, status: "scheduled", estimated_arrival: null, ...over,
});
const anna = { id: "anna", name: "Anna" };

test("a friend leaving my arrival airport within three hours is an overlap there", () => {
  const found = airportOverlaps({ mine: [mine()], friends: [{ ...anna, flights: [theirs()] }], now: T0 - 3600_000 });
  assert.equal(found.length, 1);
  assert.equal(found[0].airport, "ATH");
  assert.equal(found[0].friendId, "anna");
  assert.equal(found[0].myFlightId, "my1");
});

test("a friend at my departure airport around my departure is an overlap there", () => {
  const f = theirs({ departure_iata: "JSY", arrival_iata: "ATH", scheduled_departure: iso(T0 + 90 * 60_000) });
  const found = airportOverlaps({ mine: [mine()], friends: [{ ...anna, flights: [f] }], now: T0 - 3600_000 });
  assert.deepEqual(found.map(o => o.airport), ["JSY"]);
});

test("a companion on my own flight is not an overlap", () => {
  const same = theirs({ flight_number: "GQ 21", departure_iata: "JSY", arrival_iata: "ATH", scheduled_departure: iso(T0) });
  const found = airportOverlaps({ mine: [mine()], friends: [{ id: "carl", name: "Carl", flights: [same] }], now: T0 - 3600_000 });
  assert.equal(found.length, 0);
});

test("more than three hours apart is not an overlap", () => {
  const far = theirs({ scheduled_departure: iso(T0 + 300 * 60_000) });
  assert.equal(airportOverlaps({ mine: [mine()], friends: [{ ...anna, flights: [far] }], now: T0 - 3600_000 }).length, 0);
});

test("my flight more than six hours gone no longer overlaps with anyone", () => {
  assert.equal(airportOverlaps({ mine: [mine()], friends: [{ ...anna, flights: [theirs()] }], now: T0 + 8 * 3600_000 }).length, 0);
});

test("a cancelled friend flight and a cancelled own flight are ignored", () => {
  assert.equal(airportOverlaps({ mine: [mine()], friends: [{ ...anna, flights: [theirs({ status: "cancelled" })] }], now: T0 - 3600_000 }).length, 0);
  assert.equal(airportOverlaps({ mine: [mine({ status: "cancelled" })], friends: [{ ...anna, flights: [theirs()] }], now: T0 - 3600_000 }).length, 0);
});

test("one overlap per friend and airport, whatever the number of matching flights", () => {
  const found = airportOverlaps({ mine: [mine(), mine({ id: "my2", flight_number: "GQ23" })],
    friends: [{ ...anna, flights: [theirs(), theirs({ id: "s2", flight_number: "OA125" })] }], now: T0 - 3600_000 });
  assert.equal(found.length, 1);
});

test("the banner names the friend, the airport and the window in the airport's own zone", () => {
  const n = overlapNews({ friendName: "Anna", airport: "ATH", windowStart: T0 + 60 * 60_000, windowEnd: T0 + 180 * 60_000,
    timeZone: "Europe/Athens", now: T0 });
  assert.equal(n.title, "Anna is at ATH too");
  assert.equal(n.body, "You're both there today · 14:00 - 16:00.");
});

test("a window on another day says so", () => {
  const n = overlapNews({ friendName: "Anna", airport: "ATH", windowStart: T0 + 25 * 3600_000, windowEnd: T0 + 27 * 3600_000,
    timeZone: "Europe/Athens", now: T0 });
  assert.match(n.body, /in the same window/);
});
