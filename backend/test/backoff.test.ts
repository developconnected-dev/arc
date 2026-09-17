import test from "node:test";
import assert from "node:assert/strict";
import { ProviderBackoff, retryAfterMs, BACKOFF_429_MS, BACKOFF_TICK_MS, BACKOFF_MAX_MS } from "../src/backoff.ts";

const NOW = Date.parse("2026-09-17T12:00:00Z");
const KEY = "flight|LX8|2026-09-17";

/// A provider that answers every request the same way, and counts them.
function provider(status: number, headers: Record<string, string> = {}) {
  const p = {
    calls: 0,
    call: async () => { p.calls++; return new Response(status === 204 ? null : "[]", { status, headers }); },
  };
  return p;
}

/// THE regression, as observed on 2026-09-17: one cron tick logged
/// "adb fetch failed: 429 flight|LX8|2026-09-17" five times, every minute —
/// five shared_flights rows naming the same flight, each re-asking a provider
/// that had just said no, because a non-answer left no trace anywhere.
test("five cron callers in one tick reach a rate-limiting provider once", async () => {
  const backoff = new ProviderBackoff();
  const adb = provider(429);
  const answers: (Response | null)[] = [];
  for (let i = 0; i < 5; i++) {
    answers.push(await backoff.ask(KEY, "cron", NOW + i * 200, adb.call));
  }
  assert.equal(adb.calls, 1);
  assert.equal(answers[0]?.status, 429);
  assert.deepEqual(answers.slice(1), [null, null, null, null]);
});

test("the next tick is still inside a 429's hold; the one after the hold is not", async () => {
  const backoff = new ProviderBackoff();
  const adb = provider(429);
  await backoff.ask(KEY, "cron", NOW, adb.call);
  await backoff.ask(KEY, "cron", NOW + 60_000, adb.call);
  assert.equal(adb.calls, 1);
  await backoff.ask(KEY, "cron", NOW + BACKOFF_429_MS + 1, adb.call);
  assert.equal(adb.calls, 2);
});

test("a hold is per key: another flight is asked about as usual", async () => {
  const backoff = new ProviderBackoff();
  const adb = provider(429);
  await backoff.ask(KEY, "cron", NOW, adb.call);
  await backoff.ask("flight|LH400|2026-09-17", "cron", NOW + 200, adb.call);
  assert.equal(adb.calls, 2);
});

/// A person is waiting on a search, and the search path already paces itself
/// and makes one deliberate retry pass 1.1 s later. Holding that back would
/// turn a one-second rate limit into ninety seconds of "no such flight".
test("an interactive caller is never held back", async () => {
  const backoff = new ProviderBackoff();
  const adb = provider(429);
  await backoff.ask(KEY, "cron", NOW, adb.call);
  const res = await backoff.ask(KEY, "interactive", NOW + 1100, adb.call);
  assert.equal(adb.calls, 2);
  assert.equal(res?.status, 429);
});

test("...but its 429 still holds the cron off the same key", async () => {
  const backoff = new ProviderBackoff();
  const adb = provider(429);
  await backoff.ask(KEY, "interactive", NOW, adb.call);
  assert.equal(await backoff.ask(KEY, "cron", NOW + 5_000, adb.call), null);
  assert.equal(adb.calls, 1);
});

test("an answer lifts the hold", async () => {
  const backoff = new ProviderBackoff();
  await backoff.ask(KEY, "cron", NOW, provider(429).call);
  await backoff.ask(KEY, "interactive", NOW + 2_000, provider(200).call);
  const adb = provider(200);
  await backoff.ask(KEY, "cron", NOW + 4_000, adb.call);
  assert.equal(adb.calls, 1);
});

test("a 404 is an answer, not a fault", async () => {
  const backoff = new ProviderBackoff();
  await backoff.ask(KEY, "cron", NOW, provider(404).call);
  assert.equal(backoff.heldUntil(KEY, NOW + 1), null);
});

/// A 5xx is the same waste within a tick, but says nothing about the next
/// minute — so it is held for less than the cron's period.
test("a 5xx is held for the rest of this tick only", async () => {
  const backoff = new ProviderBackoff();
  const adb = provider(503);
  await backoff.ask(KEY, "cron", NOW, adb.call);
  await backoff.ask(KEY, "cron", NOW + 300, adb.call);
  assert.equal(adb.calls, 1);
  assert.ok(BACKOFF_TICK_MS < 60_000);
  await backoff.ask(KEY, "cron", NOW + 60_000, adb.call);
  assert.equal(adb.calls, 2);
});

test("a fetch that throws is held like a 5xx, and still throws", async () => {
  const backoff = new ProviderBackoff();
  await assert.rejects(backoff.ask(KEY, "cron", NOW, async () => { throw new Error("network"); }));
  assert.equal(backoff.heldUntil(KEY, NOW + 1), NOW + BACKOFF_TICK_MS);
});

test("Retry-After is honoured when it asks for longer than the default", async () => {
  const backoff = new ProviderBackoff();
  const adb = provider(429, { "retry-after": "300" });
  await backoff.ask(KEY, "cron", NOW, adb.call);
  assert.equal(backoff.heldUntil(KEY, NOW + 1), NOW + 300_000);
});

/// "Retry-After: 1" is the per-second limiter talking. One second later is
/// still the same tick, with the same four callers queued behind this one.
test("a Retry-After shorter than a tick still holds for the tick", async () => {
  const backoff = new ProviderBackoff();
  await backoff.ask(KEY, "cron", NOW, provider(429, { "retry-after": "1" }).call);
  assert.equal(backoff.heldUntil(KEY, NOW + 1), NOW + BACKOFF_TICK_MS);
});

test("a garbage or enormous Retry-After cannot park a flight for a day", async () => {
  const backoff = new ProviderBackoff();
  await backoff.ask(KEY, "cron", NOW, provider(429, { "retry-after": "86400" }).call);
  assert.equal(backoff.heldUntil(KEY, NOW + 1), NOW + BACKOFF_MAX_MS);
  await backoff.ask("k2", "cron", NOW, provider(429, { "retry-after": "soon" }).call);
  assert.equal(backoff.heldUntil("k2", NOW + 1), NOW + BACKOFF_429_MS);
});

test("retryAfterMs reads seconds and HTTP dates, and nothing else", () => {
  assert.equal(retryAfterMs("120", NOW), 120_000);
  assert.equal(retryAfterMs(new Date(NOW + 30_000).toUTCString(), NOW), 30_000);
  assert.equal(retryAfterMs(new Date(NOW - 30_000).toUTCString(), NOW), null);
  assert.equal(retryAfterMs("-5", NOW), null);
  assert.equal(retryAfterMs("", NOW), null);
  assert.equal(retryAfterMs(null, NOW), null);
});

/// For the non-answers only the caller can recognise: a 2xx whose body is
/// malformed, or an empty answer about a flight we already hold legs for.
test("hold() parks a key by hand, for a tick", async () => {
  const backoff = new ProviderBackoff();
  backoff.hold(KEY, NOW);
  const adb = provider(200);
  assert.equal(await backoff.ask(KEY, "cron", NOW + 500, adb.call), null);
  assert.equal(adb.calls, 0);
});

test("the memo cannot grow without bound", async () => {
  const backoff = new ProviderBackoff();
  for (let i = 0; i < 2000; i++) backoff.hold(`flight|X${i}|2026-09-17`, NOW);
  assert.ok(backoff.size <= 501);
});

// ── Wiring ──
// index.ts cannot be imported here (see sharepage.test.ts), and a backoff
// nothing consults is the bug all over again — so read the real function.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const source = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../src/index.ts"), "utf8");
const from = source.indexOf("async function fetchLegsCached(");
const to = source.indexOf("async function cacheAirlabsResult(");
assert.ok(from > 0 && to > from,
  "fetchLegsCached not found — the markers moved, fix this test rather than deleting it");
const body = source.slice(from, to);

test("fetchLegsCached reaches the provider only through the backoff", () => {
  assert.match(body, /adbBackoff\.ask\(key, source,/);
  assert.equal(body.match(/adbFetch\(/g)?.length, 1, "exactly one provider call site, inside ask()");
});

/// A held caller made no request. Counting it would inflate adb_cron by
/// four phantom calls a minute — the currency the budget gate bootstraps on.
test("a held caller returns stale legs before the budget is bumped", () => {
  const held = body.indexOf("if (!res)");
  const bump = body.indexOf("budgetBump(");
  assert.ok(held > 0, "no early return for a held key");
  assert.ok(held < bump, "held keys must return before budgetBump");
});

test("the non-answers only the caller can see are parked too", () => {
  assert.equal(body.match(/adbBackoff\.hold\(key/g)?.length, 2, "bad JSON, and empty-while-we-hold-legs");
});
