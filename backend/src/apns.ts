// APNs client for remote Live Activity updates, signed with an ES256 JWT via
// WebCrypto (no dependencies — runs as-is on Cloudflare Workers).

export interface ApnsEnv {
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_P8?: string; // full .p8 file contents (PEM)
}

export function apnsConfigured(env: ApnsEnv): boolean {
  return !!(env.APNS_TEAM_ID && env.APNS_KEY_ID && env.APNS_P8);
}

// Cached per isolate; APNs accepts tokens up to 60 min old.
let cachedJwt: { token: string; issuedAt: number } | null = null;

export async function apnsJwt(env: ApnsEnv): Promise<string> {
  if (cachedJwt && Date.now() - cachedJwt.issuedAt < 45 * 60 * 1000) {
    return cachedJwt.token;
  }
  const der = pemToDer(env.APNS_P8!);
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const header = b64url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const claims = b64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) }));
  const input = `${header}.${claims}`;
  // WebCrypto ECDSA returns the raw 64-byte r||s form — exactly what JWT ES256 wants.
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(input)
  );
  const token = `${input}.${b64urlBytes(new Uint8Array(sig))}`;
  cachedJwt = { token, issuedAt: Date.now() };
  return token;
}

function pemToDer(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const raw = atob(b64);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes.buffer;
}

function b64url(s: string): string {
  return b64urlBytes(new TextEncoder().encode(s));
}

function b64urlBytes(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// Sends one ordinary alert notification. Same credentials, same connection,
/// different push type — and the same reason it reaches a phone at 38,000 feet
/// that free airline messaging Wi-Fi whitelists Apple's push endpoints.
///
/// `collapseId` lets a newer statement about the same fact replace an older
/// one still queued, instead of stacking two contradictory banners.
///
/// Returns status AND reason, like `sendLiveActivityPush`, because the same
/// trap applies: a bare 400 is just as often a payload APNs could not read
/// as a token it does not know, and the caller must go through `tokenIsDead`
/// before dropping anything — deleting on the status alone would let one
/// malformed alert delete every device token it was sent to, taking the
/// whole alert channel dark with no error anywhere a phone could show.
/// The body of an alert push. Custom keys sit beside `aps` — that is where
/// iOS puts them into the notification's userInfo, which is what a tap reads
/// to find the flight it was about — and can never replace `aps` itself.
export function alertPayload(
  alert: { title: string; body: string },
  threadId?: string,
  userInfo?: Record<string, string>
): Record<string, unknown> {
  return {
    ...(userInfo ?? {}),
    aps: {
      alert: { title: alert.title, body: alert.body },
      sound: "default",
      ...(threadId ? { "thread-id": threadId } : {}),
    },
  };
}

/// A silent push: wakes the app for a background refresh, shows nothing.
export function backgroundPayload(): Record<string, unknown> {
  return { aps: { "content-available": 1 } };
}

/// Sends one background push. iOS budgets these (a few per hour per app)
/// and may hold one for a better moment, so the caller spaces them out.
export async function sendBackgroundPush(
  env: ApnsEnv,
  deviceToken: string,
  apnsHostEnv: "sandbox" | "production",
  bundleId: string
): Promise<ApnsResult> {
  const host = apnsHostEnv === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const jwt = await apnsJwt(env);
  const res = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": bundleId,
      "apns-push-type": "background",
      "apns-priority": "5",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 1800),
      "content-type": "application/json",
    },
    body: JSON.stringify(backgroundPayload()),
  });
  let reason: string | null = null;
  if (res.status !== 200) {
    try {
      const body = await res.text();
      if (body) reason = (JSON.parse(body) as { reason?: string }).reason ?? null;
    } catch { /* an unreadable refusal names nothing */ }
  }
  return { status: res.status, reason };
}

export async function sendAlertPush(
  env: ApnsEnv,
  deviceToken: string,
  apnsHostEnv: "sandbox" | "production",
  bundleId: string,
  alert: { title: string; body: string },
  collapseId?: string,
  threadId?: string,
  userInfo?: Record<string, string>
): Promise<ApnsResult> {
  const host = apnsHostEnv === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const jwt = await apnsJwt(env);
  const res = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      // A flight fact is worth waking the screen for, but not worth waking it
      // a week from now: an undeliverable alert should die, not queue.
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 6 * 3600),
      ...(collapseId ? { "apns-collapse-id": collapseId.slice(0, 64) } : {}),
      "content-type": "application/json",
    },
    body: JSON.stringify(alertPayload(alert, threadId, userInfo)),
  });
  let reason: string | null = null;
  if (res.status !== 200) {
    try {
      const body = await res.text();
      if (body) reason = (JSON.parse(body) as { reason?: string }).reason ?? null;
    } catch { /* an unreadable refusal names nothing */ }
  }
  return { status: res.status, reason };
}

/// Sends one Live Activity push. Returns the APNs HTTP status —
/// 410 (or 400 BadDeviceToken) means the token is dead and should be deleted.
/// APNs reasons that mean THIS TOKEN is gone, as opposed to "this request was
/// wrong". Everything else keeps its token.
///
/// 410 always means unregistered. 400 does not: APNs answers 400 for a payload
/// it cannot read just as readily as for a token it does not know, and the
/// status alone cannot separate them. Deleting on a bare 400 meant one wrong
/// field in the content-state — a rename on the Swift side, a stray null —
/// would have had the next cron tick delete every token it pushed to, taking
/// every lock screen in the app dark at once.
///
/// A token wrongly kept costs one wasted push a minute. A token wrongly
/// deleted cannot come back until the app is opened again, which for a
/// push-to-start token is precisely the thing it exists to avoid needing.
const DEAD_TOKEN_REASONS = new Set(["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"]);

export function tokenIsDead(status: number, reason: string | null | undefined): boolean {
  if (status === 410) return true;
  if (status !== 400) return false;
  return typeof reason === "string" && DEAD_TOKEN_REASONS.has(reason);
}

/// The status APNs answered with, and the reason string it named — the second
/// being the only thing that can tell a dead token from a bad payload.
export interface ApnsResult { status: number; reason: string | null }

export async function sendLiveActivityPush(
  env: ApnsEnv,
  deviceToken: string,
  apnsHostEnv: "sandbox" | "production",
  bundleId: string,
  payload: Record<string, unknown>,
  priority: 5 | 10
): Promise<ApnsResult> {
  const host = apnsHostEnv === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const jwt = await apnsJwt(env);
  const res = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": `${bundleId}.push-type.liveactivity`,
      "apns-push-type": "liveactivity",
      "apns-priority": String(priority),
      "apns-expiration": "0",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  // Only a refusal carries a body worth reading, and a body we cannot parse
  // leaves the reason null — which `tokenIsDead` treats as "keep it".
  let reason: string | null = null;
  if (res.status !== 200) {
    try {
      const body = await res.text();
      if (body) reason = (JSON.parse(body) as { reason?: string }).reason ?? null;
    } catch { /* an unreadable refusal names nothing */ }
  }
  return { status: res.status, reason };
}
