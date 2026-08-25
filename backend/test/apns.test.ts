import test from "node:test";
import assert from "node:assert/strict";
import { tokenIsDead } from "../src/apns.ts";

/// Which APNs refusals mean "this token is gone" — and, far more importantly,
/// which do not.
///
/// The push loops delete a token on 410 OR 400, reading both as "the device
/// no longer has this activity". 410 does mean exactly that. 400 does not:
/// APNs answers 400 for a malformed payload as readily as for a bad token, and
/// the status alone cannot tell them apart. A single wrong field in the
/// content-state — a rename on the Swift side, a stray null — would therefore
/// have made the very next cron tick delete EVERY live token it pushed to, and
/// every lock screen in the app would have gone dark with nothing in the logs
/// but a row of 400s.
///
/// So the reason string decides, and anything unrecognised keeps its token.
/// A token wrongly kept costs one wasted push a minute; a token wrongly
/// deleted cannot be recovered until the app is opened again.
test("410 is unregistered, whatever else it says", () => {
  assert.equal(tokenIsDead(410, "Unregistered"), true);
  assert.equal(tokenIsDead(410, null), true);
});

test("400 is only fatal when APNs names the TOKEN", () => {
  assert.equal(tokenIsDead(400, "BadDeviceToken"), true);
  assert.equal(tokenIsDead(400, "DeviceTokenNotForTopic"), true);
});

test("the regression: a payload APNs cannot read must not cost the token", () => {
  assert.equal(tokenIsDead(400, "BadMessageId"), false);
  assert.equal(tokenIsDead(400, "PayloadTooLarge"), false);
  assert.equal(tokenIsDead(400, "MissingTopic"), false);
  // Unreadable body, unknown reason, provider fault — all keep the token.
  assert.equal(tokenIsDead(400, null), false);
  assert.equal(tokenIsDead(400, "SomethingAppleAddedLater"), false);
});

test("our own end of the problem is never the device's fault", () => {
  assert.equal(tokenIsDead(403, "ExpiredProviderToken"), false);
  assert.equal(tokenIsDead(429, "TooManyRequests"), false);
  assert.equal(tokenIsDead(500, "InternalServerError"), false);
  assert.equal(tokenIsDead(503, null), false);
});

test("a delivered push is not a dead token", () => {
  assert.equal(tokenIsDead(200, null), false);
});
