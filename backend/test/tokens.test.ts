import test from "node:test";
import assert from "node:assert/strict";
import { staleTokenQueries } from "../src/tokens.ts";

const NOW = Date.parse("2026-09-13T12:00:00Z");
const iso = (ms: number) => new Date(ms).toISOString();

// 280 of 284 rows in live_activity_tokens were push-to-start tokens that
// nothing would ever push to: ownerless ones from signed-out installs, and
// tokens from devices that have not opened Arc in months. They cost a full
// table read every minute and a subrequest each the day a flight comes into
// range. Three rules, each a PostgREST DELETE the cron runs once an hour.
test("an ownerless start token a day old is swept", () => {
  const q = staleTokenQueries(NOW);
  const ownerless = q.find(x => x.reason === "ownerless-start")!;
  assert.ok(ownerless.path.includes("token_type=eq.start"));
  assert.ok(ownerless.path.includes("user_id=is.null"));
  assert.ok(ownerless.path.includes(`updated_at=lt.${iso(NOW - 24 * 3600_000)}`));
});

test("a start token from a device silent for 45 days is swept", () => {
  const q = staleTokenQueries(NOW).find(x => x.reason === "silent-start")!;
  assert.ok(q.path.includes("token_type=eq.start"));
  assert.ok(q.path.includes(`updated_at=lt.${iso(NOW - 45 * 86_400_000)}`));
  assert.ok(!q.path.includes("user_id=is.null"));
});

test("an update token whose flight arrived two days ago is swept", () => {
  const q = staleTokenQueries(NOW).find(x => x.reason === "landed-update")!;
  assert.ok(q.path.includes("token_type=eq.update"));
  assert.ok(q.path.includes(`scheduled_arrival=lt.${iso(NOW - 2 * 86_400_000)}`));
});

test("every query is scoped to the token table and nothing else", () => {
  for (const q of staleTokenQueries(NOW)) {
    assert.ok(q.path.startsWith("/live_activity_tokens?"), q.path);
    assert.ok(q.path.includes("=lt."), "every rule has a time bound");
  }
});
