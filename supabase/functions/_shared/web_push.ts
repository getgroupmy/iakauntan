/**
 * Web Push, without Firebase.
 *
 * A browser subscription is not a Firebase token. `pushManager.subscribe`
 * hands back an endpoint URL belonging to whichever push service the
 * browser uses, plus two keys, and anybody holding a VAPID key pair can
 * post to it. No Google project, no Apple account, no third party in the
 * middle — which is why this is the one platform whose notifications can
 * be turned on without asking anybody's permission first.
 *
 * Two RFCs, and both have to be right or the browser silently drops the
 * message:
 *
 *   RFC 8292  VAPID — who is sending. A JWT signed with our own P-256
 *             key, so the push service can rate-limit and contact us
 *             rather than relaying for anonymous strangers.
 *   RFC 8291  the payload — encrypted end to end, to a key only that
 *             browser holds. The push service carries the bytes and
 *             cannot read them.
 *
 * The encryption is not optional and not decoration. A push service is
 * an intermediary this system did not choose and cannot audit, and this
 * application's chat carries payslips and bank details. Under RFC 8291
 * what it relays is ciphertext.
 *
 * ---------------------------------------------------------------------
 * Written out rather than pulled in
 *
 * Every step below is HMAC, ECDH and AES-GCM — all of which WebCrypto
 * already has. The alternative was a dependency in the hot path of a
 * function that has to cold-start before somebody's phone rings.
 *
 * The risk of writing it out is that a mistake here is invisible: the
 * push service returns 201 Created for a correctly formed request
 * carrying a payload the browser cannot decrypt, and nothing anywhere
 * reports an error. So `web_push_test.ts` checks the output against
 * `http_ece`, the reference implementation the rest of the world uses,
 * byte for byte — an assertion that fails if any of this drifts.
 */

/** base64url: base64 with two substitutions and no padding. */
export function b64urlEncode(bytes: Uint8Array): string {
  return btoa(Array.from(bytes, (b) => String.fromCharCode(b)).join(""))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/** Tolerant of padding and of the standard alphabet, because keys are pasted. */
export function b64urlDecode(text: string): Uint8Array {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

const utf8 = (s: string) => new TextEncoder().encode(s);

/**
 * A Uint8Array whose buffer is an ArrayBuffer specifically.
 *
 * WebCrypto wants a BufferSource, and a Uint8Array typed over the wider
 * ArrayBufferLike — which is what several of these operations produce —
 * does not satisfy it.
 */
function buf(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(
    bytes.byteOffset,
    bytes.byteOffset + bytes.byteLength,
  ) as ArrayBuffer;
}

async function hmac(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey(
    "raw",
    buf(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, buf(data)));
}

/**
 * HKDF (RFC 5869), single expansion round.
 *
 * Every use here asks for 32 bytes or fewer, which one round of
 * SHA-256 covers. Asking for more would need a second round chained on
 * the first, so it is refused rather than silently truncated.
 */
async function hkdf(
  salt: Uint8Array,
  ikm: Uint8Array,
  info: Uint8Array,
  length: number,
): Promise<Uint8Array> {
  if (length > 32) throw new Error("hkdf: one round gives at most 32 bytes");
  const prk = await hmac(salt, ikm);
  return (await hmac(prk, concat(info, Uint8Array.of(1)))).slice(0, length);
}

/** What `pushManager.subscribe().toJSON()` gives the browser. */
export interface WebPushSubscription {
  /** The push service's URL for this installation. Also its identity. */
  endpoint: string;
  /** The browser's P-256 public key, uncompressed: 65 bytes. */
  p256dh: string;
  /** A shared secret the browser generated: 16 bytes. */
  auth: string;
}

/** Ours, generated once and kept in the function's secrets. */
export interface VapidKeys {
  /** Uncompressed P-256 public point, 65 bytes. Also given to the browser. */
  publicKey: string;
  /** The raw private scalar, 32 bytes. */
  privateKey: string;
  /** `mailto:` or `https:` — how a push service reaches us about abuse. */
  subject: string;
}

/**
 * Verified once per cold start, because the check costs a signature.
 *
 * Keyed on the pair itself rather than a boolean, so rotating the keys
 * in the function's secrets re-checks rather than trusting the last
 * answer.
 */
let checkedKey: { id: string; key: CryptoKey } | null = null;

/**
 * The private scalar, imported for signing, after proving it belongs
 * with the public one.
 *
 * WebCrypto will not take a bare 32-byte scalar, so it is assembled into
 * a JWK with the two halves of the public point as x and y — and it does
 * *not* check that the scalar and the point are a pair. Give it two keys
 * from different pairs and it signs perfectly happily; the push service
 * then checks the signature against the public key we advertised,
 * fails, and answers 403 with no explanation. Two mistyped characters in
 * a secret, and every notification stops with nothing anywhere saying
 * why.
 *
 * So the pair is proved here, by signing a probe and verifying it
 * against the advertised public key. One signature per cold start, in
 * exchange for a sentence instead of a silence.
 */
async function signingKey(keys: VapidKeys): Promise<CryptoKey> {
  const id = `${keys.publicKey}.${keys.privateKey}`;
  if (checkedKey?.id === id) return checkedKey.key;

  const pub = b64urlDecode(keys.publicKey);
  if (pub.length !== 65 || pub[0] !== 0x04) {
    throw new Error(
      "The VAPID public key is not an uncompressed P-256 point. It should " +
        "be 65 bytes beginning 0x04.",
    );
  }
  const priv = b64urlDecode(keys.privateKey);
  if (priv.length !== 32) {
    throw new Error("The VAPID private key is not 32 bytes.");
  }

  const key = await crypto.subtle.importKey(
    "jwk",
    {
      kty: "EC",
      crv: "P-256",
      d: b64urlEncode(priv),
      x: b64urlEncode(pub.slice(1, 33)),
      y: b64urlEncode(pub.slice(33, 65)),
      ext: true,
    },
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );

  const probe = utf8("vapid key pair check");
  const paired = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    await crypto.subtle.importKey(
      "raw",
      buf(pub),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    ),
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      buf(probe),
    ),
    buf(probe),
  );
  if (!paired) {
    throw new Error(
      "WEB_PUSH_PUBLIC_KEY and WEB_PUSH_PRIVATE_KEY are not a pair. Every " +
        "push service will answer 403. Generate both together and set them " +
        "together — see docs/push-notifications.md.",
    );
  }

  checkedKey = { id, key };
  return key;
}

/**
 * The `Authorization` header for one endpoint.
 *
 * Scoped to the push service's origin and time limited, so a header
 * captured in transit is not a licence to send as us forever. Twelve
 * hours: the RFC allows twenty-four, and half of it leaves room for a
 * clock that is wrong without being useless.
 */
export async function vapidAuthorization(
  keys: VapidKeys,
  endpoint: string,
  now: Date = new Date(),
): Promise<string> {
  const audience = new URL(endpoint).origin;
  const header = b64urlEncode(utf8(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const claims = b64urlEncode(
    utf8(JSON.stringify({
      aud: audience,
      exp: Math.floor(now.getTime() / 1000) + 12 * 60 * 60,
      sub: keys.subject,
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

  // ECDSA over WebCrypto is already r||s, which is what JWS wants — no
  // DER unwrapping, unlike most other ECDSA APIs.
  return `vapid t=${signed}.${b64urlEncode(signature)}, k=${keys.publicKey}`;
}

/** Record size. One record is always enough here; a notification is tiny. */
const RECORD_SIZE = 4096;

/**
 * The body of one push message: RFC 8291 over the aes128gcm coding of
 * RFC 8188.
 *
 * `salt` and `ephemeral` exist so the test can pin every byte against
 * the reference implementation. Production passes neither, and a fresh
 * key pair per message is the whole point — reusing one would let the
 * push service link two messages to the same sender session.
 */
export async function encryptPayload(
  subscription: WebPushSubscription,
  plaintext: Uint8Array,
  fixed?: { salt?: Uint8Array; ephemeral?: CryptoKeyPair },
): Promise<Uint8Array> {
  const uaPublic = b64urlDecode(subscription.p256dh);
  const authSecret = b64urlDecode(subscription.auth);
  if (uaPublic.length !== 65) {
    throw new Error("The subscription's p256dh key is not 65 bytes.");
  }
  if (authSecret.length !== 16) {
    throw new Error("The subscription's auth secret is not 16 bytes.");
  }

  const salt = fixed?.salt ?? crypto.getRandomValues(new Uint8Array(16));
  const ephemeral = fixed?.ephemeral ?? await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  );

  const asPublic = new Uint8Array(
    await crypto.subtle.exportKey("raw", ephemeral.publicKey),
  );

  const shared = new Uint8Array(
    await crypto.subtle.deriveBits(
      {
        name: "ECDH",
        public: await crypto.subtle.importKey(
          "raw",
          buf(uaPublic),
          { name: "ECDH", namedCurve: "P-256" },
          false,
          [],
        ),
      },
      ephemeral.privateKey,
      256,
    ),
  );

  // The step that binds the ciphertext to this pair of keys: both public
  // keys go into the derivation, so a message encrypted for one browser
  // cannot be replayed at another even by whoever relayed it.
  const ikm = await hkdf(
    authSecret,
    shared,
    concat(utf8("WebPush: info"), Uint8Array.of(0), uaPublic, asPublic),
    32,
  );

  const cek = await hkdf(
    salt,
    ikm,
    concat(utf8("Content-Encoding: aes128gcm"), Uint8Array.of(0)),
    16,
  );
  const nonce = await hkdf(
    salt,
    ikm,
    concat(utf8("Content-Encoding: nonce"), Uint8Array.of(0)),
    12,
  );

  // 0x02 marks the last record. 0x01 would say "more follows", and the
  // browser would wait for a record that never comes.
  const padded = concat(plaintext, Uint8Array.of(2));

  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: buf(nonce), tagLength: 128 },
      await crypto.subtle.importKey("raw", buf(cek), "AES-GCM", false, [
        "encrypt",
      ]),
      buf(padded),
    ),
  );

  const recordSize = new Uint8Array(4);
  new DataView(recordSize.buffer).setUint32(0, RECORD_SIZE, false);

  // salt | record size | key length | our public key | ciphertext
  return concat(
    salt,
    recordSize,
    Uint8Array.of(asPublic.length),
    asPublic,
    ciphertext,
  );
}

/** What happened to one handset. */
export interface WebPushResult {
  ok: boolean;
  status: number;
  /** The subscription is gone: forget it rather than retrying forever. */
  gone: boolean;
  detail?: string;
}

/**
 * Post one notification.
 *
 * `urgency` and `ttl` are not the same question. TTL is how long the
 * push service should hold it for a browser that is offline; urgency is
 * whether to wake a device that is saving battery. A call is high and
 * short-lived — a call notification arriving after the caller gave up is
 * worse than none — and a message is normal and worth keeping for a day.
 */
export async function sendWebPush(
  subscription: WebPushSubscription,
  payload: string,
  keys: VapidKeys,
  options: { ttl?: number; urgency?: "very-low" | "low" | "normal" | "high" } =
    {},
): Promise<WebPushResult> {
  const body = await encryptPayload(subscription, utf8(payload));

  const response = await fetch(subscription.endpoint, {
    method: "POST",
    headers: {
      Authorization: await vapidAuthorization(keys, subscription.endpoint),
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      TTL: String(options.ttl ?? 86400),
      Urgency: options.urgency ?? "normal",
    },
    body: buf(body),
  });

  if (response.ok) {
    // The body is empty on success and reading it keeps the connection
    // from being held open.
    await response.body?.cancel();
    return { ok: true, status: response.status, gone: false };
  }

  const detail = await response.text().catch(() => "");
  return {
    ok: false,
    status: response.status,
    // 404 the endpoint never existed, 410 the browser revoked it. Both
    // mean this row will never be delivered to again.
    gone: response.status === 404 || response.status === 410,
    detail: detail.slice(0, 500),
  };
}

/**
 * The keys, or null if nobody has set them.
 *
 * Null rather than a throw: a deployment that has configured Firebase
 * and not web push should still reach its phones, and the caller reports
 * which half is missing.
 */
export function vapidFromEnv(): VapidKeys | null {
  const publicKey = Deno.env.get("WEB_PUSH_PUBLIC_KEY");
  const privateKey = Deno.env.get("WEB_PUSH_PRIVATE_KEY");
  if (!publicKey || !privateKey) return null;
  return {
    publicKey,
    privateKey,
    subject: Deno.env.get("WEB_PUSH_SUBJECT") ?? "mailto:support@iakauntan.my",
  };
}
