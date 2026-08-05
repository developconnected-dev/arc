import test from "node:test";
import assert from "node:assert/strict";
import { queryMentions, verifiedRoute, normalizePlaceText } from "../src/place.ts";

test("the reported bug: Santorini is refused for a Syros query", () => {
  const q = "Syros to Athens 18 September";
  assert.equal(queryMentions(q, "JSY"), true, "JSY is 'Syros Island'");
  assert.equal(queryMentions(q, "JTR"), false, "JTR is 'Santorini Island' — never named");

  const route = verifiedRoute(q, "JTR", "ATH");
  assert.equal(route.dep, "", "the wrong island must not survive");
  assert.equal(route.arr, "ATH", "Athens was genuinely named");
  assert.deepEqual(route.dropped, ["JTR"]);
});

test("a correctly parsed route passes untouched", () => {
  const route = verifiedRoute("Athens to Munich 18 September", "ATH", "MUC");
  assert.deepEqual(route, { dep: "ATH", arr: "MUC", dropped: [] });
});

test("codes written out are accepted as naming the place", () => {
  assert.equal(queryMentions("JSY to ATH tomorrow", "JSY"), true);
  assert.equal(queryMentions("JSY to ATH tomorrow", "ATH"), true);
});

test("a German query is not rejected for using an exonym", () => {
  // The table says "Vienna" and "Munich"; the traveller wrote Wien and München.
  assert.equal(queryMentions("Wien nach Munchen am 18. September", "VIE"), true);
  assert.equal(queryMentions("Wien nach München am 18. September", "MUC"), true);
});

test("diacritics and punctuation don't defeat a match", () => {
  assert.equal(normalizePlaceText("Zürich nach München"), "ZURICH NACH MUNCHEN");
  assert.equal(queryMentions("Zürich to Düsseldorf", "ZRH"), true);
});

test("generic words in a city name can't match by themselves", () => {
  // JSY is "Syros Island". A query about some other island must not match it
  // on the word ISLAND alone.
  assert.equal(queryMentions("Long Island to Athens", "JSY"), false);
  assert.equal(queryMentions("island hopping in Greece", "JTR"), false);
});

test("short city fragments can't match promiscuously", () => {
  // "New York" is matched on YORK, not on NEW, which would otherwise fire on
  // any sentence containing the word "new".
  assert.equal(queryMentions("a new flight to Athens", "JFK"), false);
  assert.equal(queryMentions("New York to Athens", "JFK"), true);
});

test("an unknown or malformed code is refused rather than assumed", () => {
  assert.equal(queryMentions("Athens to Munich", "ZZZ"), false);
  assert.equal(queryMentions("Athens to Munich", ""), false);
  assert.equal(queryMentions("Athens to Munich", "AT"), false);
  const route = verifiedRoute("Athens to Munich", undefined, undefined);
  assert.deepEqual(route, { dep: "", arr: "", dropped: [] });
});

test("both endpoints are judged independently", () => {
  // One real, one hallucinated: keep the real one.
  const route = verifiedRoute("Syros to Athens", "JTR", "ATH");
  assert.equal(route.dep, "");
  assert.equal(route.arr, "ATH");
});
