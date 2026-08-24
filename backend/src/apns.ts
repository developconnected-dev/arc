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
export async function sendAlertPush(
  env: ApnsEnv,
  deviceToken: string,
  apnsHostEnv: "sandbox" | "production",
  bundleId: string,
  alert: { title: string; body: string },
  collapseId?: string,
  threadId?: string
): Promise<number> {
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
    body: JSON.stringify({
      aps: {
        alert: { title: alert.title, body: alert.body },
        sound: "default",
        ...(threadId ? { "thread-id": threadId } : {}),
      },
    }),
  });
  return res.status;
}

/// Sends one Live Activity push. Returns the APNs HTTP status —
/// 410 (or 400 BadDeviceToken) means the token is dead and should be deleted.
export async function sendLiveActivityPush(
  env: ApnsEnv,
  deviceToken: string,
  apnsHostEnv: "sandbox" | "production",
  bundleId: string,
  payload: Record<string, unknown>,
  priority: 5 | 10
): Promise<number> {
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
  return res.status;
}
