/**
 * APNs, without Firebase.
 *
 * `docs/push-notifications.md` says iOS "can be reached without Firebase
 * at all, by addressing APNs directly with a token-based `.p8` key — and
 * should be, because FCM cannot send the PushKit VoIP push that a real
 * CallKit incoming-call screen needs". This is that.
 *
 * ---------------------------------------------------------------------
 * Why it is worth a second transport rather than one more FCM platform
 *
 * Two reasons, and only the first is about features.
 *
 *   1. **PushKit.** A VoIP push is a different `apns-push-type` sent to
 *      a different topic (`<bundle>.voip`) carrying a different token,
 *      and it is the only thing that gets a full-screen CallKit ring
 *      rather than a banner somebody has to notice and tap. FCM has no
 *      way to send one — it is not an option it withholds, it is not in
 *      the protocol it speaks to Apple. So an app that rings the way
 *      people expect a phone to ring cannot go through Firebase.
 *
 *   2. **One fewer party.** Everything else in this system's push design
 *      is arranged so that no third party has to be trusted or paid:
 *      browsers take a VAPID pair generated locally, and the payload is
 *      ciphertext under RFC 8291. Firebase for iOS would be a Google
 *      project in the middle of an Apple conversation, holding the
 *      notifications of an application whose chat carries payslips.
 *      A `.p8` from the Apple developer account removes it.
 *
 * Android still needs Firebase. There is no direct equivalent — that is
 * Google's transport all the way down.
 *
 * ---------------------------------------------------------------------
 * The two traps, both of which fail silently
 *
 * **The token must be REUSED.** APNs rate-limits provider token
 * *generation*, not requests: minting a fresh JWT more often than once
 * every twenty minutes earns `TooManyProviderTokenUpdates` (429), and
 * the obvious implementation — sign a JWT per notification — trips it
 * the moment two people are in a conversation. It also refuses a token
 * older than an hour. So one is minted, cached, and re-minted just
 * before it ages out; [TOKEN_LIFETIME] is the number and the only one.
 *
 * **The host is not one host.** A token from a development build is
 * meaningless to the production host and vice versa, and the answer is
 * `400 BadDeviceToken` either way — which reads as "the phone is gone"
 * rather than "you are talking to the wrong Apple". `APNS_PRODUCTION`
 * decides, and [isDeadToken] deliberately does NOT treat
 * `BadDeviceToken` as a dead handset for exactly this reason.
 *
 * ---------------------------------------------------------------------
 * Written out rather than pulled in
 *
 * The whole of it is one ES256 JWT and one POST. WebCrypto has ECDSA
 * over P-256 and Deno's `fetch` speaks HTTP/2, which APNs requires — a
 * dependency would buy nothing and has to cold-start before a phone
 * rings.
 *
 * `apns_test.ts` verifies the JWT against its own public key rather than
 * against a stored vector. Not because the bytes vary — Deno's ECDSA
 * turns out to be DETERMINISTIC, and two signings of one string with
 * one key are identical, which is the opposite of what this paragraph
 * said until a mutation survived and proved it — but because a stored
 * vector would assert that this implementation still produces the same
 * bytes, and what is worth asserting is that Apple could verify them.
 *
 * Secrets, which live only in Edge Functions → Secrets:
 *   APNS_KEY_P8      the whole .p8 file, PEM, including BEGIN/END lines
 *   APNS_KEY_ID      the 10-character Key ID the .p8 was downloaded with
 *   APNS_TEAM_ID     the 10-character Apple team identifier
 *   APNS_TOPIC       the app's bundle identifier
 *   APNS_PRODUCTION  "true" for api.push.apple.com, otherwise sandbox
 */
import { b64urlEncode } from "./web_push.ts";
import { pemToDer } from "./der.ts";

const utf8 = (s: string) => new TextEncoder().encode(s);

/**
 * A Uint8Array whose buffer is an ArrayBuffer specifically.
 *
 * The same accommodation `web_push.ts` makes, for the same reason:
 * WebCrypto wants a BufferSource and will not take a Uint8Array typed
 * over the wider ArrayBufferLike.
 */
function buf(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(
    bytes.byteOffset,
    bytes.byteOffset + bytes.byteLength,
  ) as ArrayBuffer;
}

/** What it takes to talk to APNs as ourselves. */
export interface ApnsKeys {
  /** The 10-character Key ID. Goes in the JWT header as `kid`. */
  keyId: string;
  /** The 10-character Apple team identifier. The JWT's `iss`. */
  teamId: string;
  /** The app's bundle identifier. A VoIP push appends `.voip`. */
  topic: string;
  /** The `.p8` as downloaded: PKCS#8 PEM, BEGIN/END lines and all. */
  privateKeyPem: string;
  /** Production host rather than sandbox. */
  production: boolean;
}

/**
 * How long a provider token is used before it is minted again.
 *
 * Fifty minutes. APNs refuses one older than an hour and refuses to let
 * you mint them more often than every twenty minutes, so the usable
 * window is narrow at both ends and this sits in the middle of it: long
 * enough never to be rate-limited, short enough never to age out, with
 * ten minutes of slack for a clock that is wrong.
 */
export const TOKEN_LIFETIME = 50 * 60 * 1000;

/** `https://api.push.apple.com` or the sandbox beside it. */
export function apnsHost(keys: ApnsKeys): string {
  return keys.production
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
}

/**
 * The topic a push of this kind goes to.
 *
 * A VoIP push is addressed to `<bundle>.voip` and nothing else will do:
 * sent to the plain bundle it is refused with `TopicDisallowed`, and a
 * PushKit token sent to the plain topic is `DeviceTokenNotForTopic`.
 * Two tokens, two topics, one app.
 */
export function apnsTopic(keys: ApnsKeys, pushType: ApnsPushType): string {
  return pushType === "voip" ? `${keys.topic}.voip` : keys.topic;
}

export type ApnsPushType = "alert" | "voip" | "background";

/**
 * Which kind of push a notification of this kind is.
 *
 * A call is a VoIP push, which is the whole reason this file exists. A
 * message is an ordinary alert.
 *
 * `apns-push-type` is not advisory: since iOS 13 APNs rejects a request
 * whose declared type does not match what the payload does, and a VoIP
 * push that claims to be an alert is refused outright.
 */
export function apnsPushType(kind: string): ApnsPushType {
  return kind === "call" ? "voip" : "alert";
}

let cached: { keyId: string; signed: string; until: number } | null = null;

/**
 * Forget the cached provider token.
 *
 * For the tests, and for the one production case that needs it: a 403
 * `ExpiredProviderToken` means our clock disagrees with Apple's, and the
 * only useful response is to mint a fresh one rather than send the same
 * stale token for another fifty minutes.
 */
export function resetApnsToken(): void {
  cached = null;
}

/**
 * The `authorization` header value, minted at most once per
 * [TOKEN_LIFETIME].
 *
 * The claims are `iss` and `iat` and nothing else. APNs has no `exp`:
 * it ages a token by its `iat`, so adding one is at best ignored and at
 * worst a rejection.
 */
export async function apnsAuthorization(
  keys: ApnsKeys,
  now: Date = new Date(),
): Promise<string> {
  // Keyed on the Key ID as well as the clock, so rotating the key in the
  // dashboard takes effect on the next notification rather than fifty
  // minutes later.
  if (cached && cached.keyId === keys.keyId && now.getTime() < cached.until) {
    return `bearer ${cached.signed}`;
  }

  const header = b64urlEncode(
    utf8(JSON.stringify({ alg: "ES256", kid: keys.keyId })),
  );
  const claims = b64urlEncode(
    utf8(JSON.stringify({
      iss: keys.teamId,
      iat: Math.floor(now.getTime() / 1000),
    })),
  );

  const signed = `${header}.${claims}`;
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      await signingKey(keys),
      buf(utf8(signed)),
    ),
  );

  // WebCrypto's ECDSA output is already r||s, which is what JWS wants.
  // Most other ECDSA APIs hand back DER and need unwrapping first; this
  // one does not, and `web_push.ts` says the same thing where it signs.
  const token = `${signed}.${b64urlEncode(signature)}`;
  cached = {
    keyId: keys.keyId,
    signed: token,
    until: now.getTime() + TOKEN_LIFETIME,
  };
  return `bearer ${token}`;
}

let importedKey: { pem: string; key: CryptoKey } | null = null;

/** The `.p8`, imported once. */
async function signingKey(keys: ApnsKeys): Promise<CryptoKey> {
  if (importedKey && importedKey.pem === keys.privateKeyPem) {
    return importedKey.key;
  }

  let der: Uint8Array;
  try {
    der = pemToDer(keys.privateKeyPem, "PRIVATE KEY");
  } catch {
    throw new Error(
      "APNS_KEY_P8 is not a PEM private key. Paste the .p8 file whole, " +
        "including its BEGIN PRIVATE KEY and END PRIVATE KEY lines. See " +
        "docs/push-notifications.md.",
    );
  }

  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey(
      "pkcs8",
      buf(der),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
  } catch {
    // The likeliest cause by a distance: somebody pasted an App Store
    // Connect API key, or a certificate's key, instead of the APNs one.
    // They are all .p8 files and only one of them is this one.
    throw new Error(
      "APNS_KEY_P8 is a PEM key but not a P-256 one, so it is not an APNs " +
        "auth key. Apple issues several kinds of .p8; this one is made " +
        "under Certificates, Identifiers & Profiles -> Keys with Apple " +
        "Push Notification service ticked.",
    );
  }

  importedKey = { pem: keys.privateKeyPem, key };
  return key;
}

/**
 * Whether the handset is gone, as opposed to the request being wrong.
 *
 * The distinction is load-bearing, because acting on it DELETES a
 * registration. `410 Unregistered` is Apple saying the app was removed
 * from that device, which is the one unambiguous case.
 *
 * `BadDeviceToken` is deliberately NOT here, and that is the whole
 * comment. It is what a perfectly live handset answers when a sandbox
 * token is sent to the production host or the other way round, and
 * treating it as death would have a misconfigured deployment quietly
 * unregister every iPhone it has — leaving nothing to notice once the
 * configuration was fixed. A wrong host is a deployment problem that
 * should stay visible; `sendApns` reports it as a failure and keeps the
 * row.
 */
export function isDeadToken(status: number, reason?: string): boolean {
  if (status === 410) return true;
  return reason === "Unregistered";
}

export interface ApnsResult {
  ok: boolean;
  status: number;
  /** Apple's own word for what was wrong, where it gave one. */
  reason?: string;
  /** The handset is gone and its row should be forgotten. */
  dead: boolean;
}

export interface ApnsOptions {
  /** `alert` for a message, `voip` for a call. */
  pushType: ApnsPushType;
  /**
   * When the notification stops being worth delivering, as a unix time;
   * 0 means "now or never", which is what a call wants.
   */
  expiration?: number;
  /** 10 for anything somebody should see immediately. */
  priority?: number;
  /** So a retry cannot ring twice. */
  id?: string;
  /** `fetch`, for the tests. */
  transport?: typeof fetch;
}

/**
 * One notification to one handset.
 *
 * Failures are RETURNED rather than thrown. One handset that has been
 * wiped must not stop the other four people in the conversation being
 * told, and the caller counts the outcomes.
 */
export async function sendApns(
  keys: ApnsKeys,
  deviceToken: string,
  payload: Record<string, unknown>,
  options: ApnsOptions,
): Promise<ApnsResult> {
  const send = options.transport ?? fetch;
  const headers: Record<string, string> = {
    "authorization": await apnsAuthorization(keys),
    "apns-topic": apnsTopic(keys, options.pushType),
    "apns-push-type": options.pushType,
    "apns-priority": String(options.priority ?? 10),
    "content-type": "application/json",
  };
  // Zero is a meaningful expiration -- "deliver now or not at all" --
  // so this cannot be a truthiness test.
  if (options.expiration !== undefined) {
    headers["apns-expiration"] = String(options.expiration);
  }
  if (options.id) headers["apns-id"] = options.id;

  let response: Response;
  try {
    response = await send(`${apnsHost(keys)}/3/device/${deviceToken}`, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
    });
  } catch (_) {
    // A network that dropped is not a handset that is gone. Reported as
    // a failure, and the registration is kept.
    return { ok: false, status: 0, dead: false };
  }

  if (response.ok) {
    // APNs answers 200 with an empty body. Read it anyway so the
    // connection can be reused for the next handset rather than left
    // half-consumed.
    await response.body?.cancel();
    return { ok: true, status: response.status, dead: false };
  }

  // Apple's errors are `{"reason":"BadDeviceToken"}`. A body that is not
  // JSON is a gateway in the way rather than Apple, and has no reason.
  let reason: string | undefined;
  try {
    const body = await response.json();
    const said = (body as { reason?: unknown })?.reason;
    if (typeof said === "string") reason = said;
  } catch {
    // Left undefined.
  }

  // A stale provider token is the one failure worth acting on here: the
  // next notification should mint a fresh one rather than send the same
  // rejected token for the rest of its fifty minutes.
  if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") {
    resetApnsToken();
  }

  return {
    ok: false,
    status: response.status,
    reason,
    dead: isDeadToken(response.status, reason),
  };
}

/**
 * The keys from the environment, or null where APNs is not configured.
 *
 * Null rather than an exception, because a deployment with no Apple
 * account is the ordinary case rather than a broken one — the same
 * posture `vapidFromEnv` takes. What is refused, in `send-push`, is
 * having nobody reachable by anything.
 *
 * A PARTIALLY configured one does throw. Four secrets that have to
 * agree, three of them set, is somebody halfway through a job, and
 * answering "not configured" would leave them looking for the reason
 * iPhones are being skipped.
 */
export function apnsFromEnv(): ApnsKeys | null {
  const pem = Deno.env.get("APNS_KEY_P8");
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const topic = Deno.env.get("APNS_TOPIC");

  const set = [pem, keyId, teamId, topic].filter(
    (v) => v !== undefined && v.trim() !== "",
  );
  if (set.length === 0) return null;
  if (set.length < 4) {
    const missing = [
      pem?.trim() ? null : "APNS_KEY_P8",
      keyId?.trim() ? null : "APNS_KEY_ID",
      teamId?.trim() ? null : "APNS_TEAM_ID",
      topic?.trim() ? null : "APNS_TOPIC",
    ].filter(Boolean);
    throw new Error(
      `APNs is half configured: ${missing.join(", ")} ${
        missing.length === 1 ? "is" : "are"
      } missing. Set all four or none. See docs/push-notifications.md.`,
    );
  }

  return {
    // `.p8` files are pasted through dashboards that eat the newlines,
    // so a literal backslash-n is put back. `pemToDer` would otherwise
    // fail on a key that is perfectly correct and merely flattened.
    privateKeyPem: pem!.replace(/\\n/g, "\n").trim(),
    keyId: keyId!.trim(),
    teamId: teamId!.trim(),
    topic: topic!.trim(),
    production: (Deno.env.get("APNS_PRODUCTION") ?? "").trim().toLowerCase() ===
      "true",
  };
}
