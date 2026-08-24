import test from "node:test";
import assert from "node:assert/strict";
import { wxRows, airportWeatherPayload } from "../src/weather.ts";

/// The reported bug: opening the flight-detail screen for Syros (JSY/LGSO)
/// answered 500. aviationweather.gov publishes a METAR for LGSO but no TAF,
/// and for a station it doesn't forecast it replies 204 with an EMPTY BODY.
/// `res.ok` is true for 204, so `await res.json()` threw
/// "SyntaxError: Unexpected end of JSON input" out of the handler.
///
/// An airport nobody forecasts must degrade to a null forecast, never to a
/// 500 — the screen has somewhere to put "no data" and nowhere to put an
/// error.

test("the reported bug: a 204 with an empty body is no rows, not a throw", async () => {
  const res = new Response(null, { status: 204 });   // undici forbids a body on 204, as does HTTP
  assert.deepEqual(await wxRows(res), []);
});

test("an OK response with an empty body is no rows either", async () => {
  // Same shape, 200: the provider has answered "nothing here" both ways.
  assert.deepEqual(await wxRows(new Response("", { status: 200 })), []);
});

test("a non-JSON body (an error page) is no rows", async () => {
  const res = new Response("<html>502 Bad Gateway</html>",
                           { status: 200, headers: { "content-type": "text/html" } });
  assert.deepEqual(await wxRows(res), []);
});

test("a non-OK status is no rows", async () => {
  assert.deepEqual(await wxRows(new Response("[]", { status: 503 })), []);
});

test("a failed fetch (null) is no rows", async () => {
  assert.deepEqual(await wxRows(null), []);
});

test("a JSON object rather than an array is no rows", async () => {
  assert.deepEqual(await wxRows(new Response('{"error":"nope"}')), []);
});

test("rows survive unchanged when the provider does answer", async () => {
  const rows = await wxRows(new Response('[{"icaoId":"LGAV","wspd":13}]'));
  assert.equal(rows.length, 1);
  assert.equal(rows[0].icaoId, "LGAV");
});

// ── the payload the app decodes ──

const LGSO_METAR = {
  icaoId: "LGSO", fltCat: "VFR", wspd: 18, wgst: null, visib: "6+",
  clouds: [{ cover: "BKN", base: 2500 }], wxString: null,
  reportTime: "2026-09-18T08:00:00.000Z",
};

test("an airport with a METAR but no TAF reports now, and null for the forecast", () => {
  const p = airportWeatherPayload("LGSO", 1789704600, [LGSO_METAR], []);
  assert.equal(p.ok, true);
  assert.equal(p.icao, "LGSO");
  assert.equal(p.now?.category, "VFR");
  assert.equal(p.now?.windKt, 18);
  assert.equal(p.now?.ceilingFt, 2500);
  assert.equal(p.atTime, null, "no TAF means no forecast — not an error");
});

test("an airport with neither observation nor forecast is empty, still ok", () => {
  const p = airportWeatherPayload("LGSO", 1789704600, [], []);
  assert.deepEqual(p, { ok: true, icao: "LGSO", now: null, atTime: null });
});

test("the forecast period containing the departure time is the one returned", () => {
  const taf = { fcsts: [
    { timeFrom: 1000, timeTo: 2000, wspd: 5 },
    { timeFrom: 2000, timeTo: 3000, wspd: 25, wshearSpd: 40 },
    { timeFrom: 3000, timeTo: 4000, wspd: 9 },
  ] };
  const p = airportWeatherPayload("LGAV", 2500, [], [taf]);
  assert.equal(p.atTime?.windKt, 25);
  assert.equal(p.atTime?.windShear, true);
  assert.equal(p.atTime?.from, 2000);
});

test("past the end of the TAF, its last period is used rather than nothing", () => {
  const taf = { fcsts: [{ timeFrom: 1000, timeTo: 2000, wspd: 5 },
                        { timeFrom: 2000, timeTo: 3000, wspd: 9 }] };
  const p = airportWeatherPayload("LGAV", 99999, [], [taf]);
  assert.equal(p.atTime?.windKt, 9);
});

test("a TAF row with no periods at all doesn't invent one", () => {
  const p = airportWeatherPayload("LGAV", 2500, [], [{ fcsts: [] }]);
  assert.equal(p.atTime, null);
});
