/**
 * Web Push, checked against the reference implementation.
 *
 *   deno test supabase/functions/_shared/web_push_test.ts
 *
 * The failure this exists to catch is the silent one. A push service
 * returns 201 Created for any well-formed request, whether or not the
 * browser can decrypt what is inside it — so a mistake in the key
 * derivation produces a system that reports every notification as sent
 * and delivers none of them. Nothing in production would say so.
 *
 * A round trip against our own code would not catch it either: encrypt
 * and decrypt sharing one wrong constant agree with each other
 * perfectly. So the assertion is against somebody else's arithmetic —
 * `web_push_vector.json` was produced by `http_ece` and `web-push`, the
 * implementations most of the world's web push traffic goes through,
 * and it is compared byte for byte.
 *
 * The keys in that fixture are throwaway, generated for it and used
 * nowhere. Regenerate the whole file with `node web_push_vector.js`.
 */
import {
  assert,
  assertEquals,
  assertNotEquals,
  assertRejects,
} from "jsr:@std/assert@1";
import {
  b64urlDecode,
  b64urlEncode,
  encryptPayload,
  vapidAuthorization,
  type VapidKeys,
  type WebPushSubscription,
} from "./web_push.ts";

const vector = JSON.parse(
  await Deno.readTextFile(
    new URL("./web_push_vector.json", import.meta.url),
  ),
) as {
  subscription: WebPushSubscription;
  sender: { publicKey: string; privateKey: string };
  salt: string;
  plaintext: string;
  body: string;
  vapid: {
    publicKey: string;
    privateKey: string;
    subject: string;
    expiry: number;
    authorization: string;
  };
};

/**
 * WebCrypto wants a buffer it knows is not shared, and a Uint8Array
 * declared over the wider ArrayBufferLike does not satisfy it.
 */
const src = (b: Uint8Array): ArrayBuffer =>
  b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) as ArrayBuffer;

/** The fixture's sender key pair, in the form WebCrypto wants. */
async function senderKeys(): Promise<CryptoKeyPair> {
  const pub = b64urlDecode(vector.sender.publicKey);
  const privateKey = await crypto.subtle.importKey(
    "jwk",
    {
      kty: "EC",
      crv: "P-256",
      d: vector.sender.privateKey,
      x: b64urlEncode(pub.slice(1, 33)),
      y: b64urlEncode(pub.slice(33, 65)),
      ext: true,
    },
    { name: "ECDH", namedCurve: "P-256" },
    false,
    ["deriveBits"],
  );
  const publicKey = await crypto.subtle.importKey(
    "raw",
    src(pub),
    { name: "ECDH", namedCurve: "P-256" },
    true,
    [],
  );
  return { privateKey, publicKey };
}

Deno.test("the encrypted body matches http_ece byte for byte", async () => {
  const body = await encryptPayload(
    vector.subscription,
    new TextEncoder().encode(vector.plaintext),
    { salt: b64urlDecode(vector.salt), ephemeral: await senderKeys() },
  );

  assertEquals(
    b64urlEncode(body),
    vector.body,
    "the payload no longer matches the reference implementation, which "
      + "means browsers will accept the request and drop the message",
  );
});

Deno.test("and the comparison is not vacuous: one different byte of salt "
  + "changes the whole ciphertext", async () => {
  // Without this the test above would pass for an implementation that
  // ignored its inputs and returned a constant.
  const salt = b64urlDecode(vector.salt);
  salt[0] ^= 0x01;

  const body = await encryptPayload(
    vector.subscription,
    new TextEncoder().encode(vector.plaintext),
    { salt, ephemeral: await senderKeys() },
  );

  assertNotEquals(b64urlEncode(body), vector.body);
});

Deno.test("the header is framed as RFC 8188 requires", async () => {
  const body = await encryptPayload(
    vector.subscription,
    new TextEncoder().encode("x"),
    { salt: b64urlDecode(vector.salt), ephemeral: await senderKeys() },
  );

  assertEquals(
    b64urlEncode(body.slice(0, 16)),
    vector.salt,
    "the salt comes first, or the browser derives the wrong key",
  );
  assertEquals(
    new DataView(body.buffer).getUint32(16, false),
    4096,
    "record size, big endian",
  );
  assertEquals(body[20], 65, "the key length byte");
  assertEquals(
    b64urlEncode(body.slice(21, 86)),
    vector.sender.publicKey,
    "and then our public key, which is how the browser derives its half",
  );
});

Deno.test("a fresh message reuses nothing", async () => {
  const twice = await Promise.all([
    encryptPayload(vector.subscription, new TextEncoder().encode("hello")),
    encryptPayload(vector.subscription, new TextEncoder().encode("hello")),
  ]);

  // Same plaintext, same recipient, different bytes: a new salt and a
  // new ephemeral key each time. Reusing either would let the push
  // service link two messages to one sender session.
  assertNotEquals(b64urlEncode(twice[0]), b64urlEncode(twice[1]));
});

Deno.test("a subscription with the wrong sized keys is refused rather than "
  + "encrypted to nobody", async () => {
  const short: WebPushSubscription = {
    ...vector.subscription,
    p256dh: b64urlEncode(new Uint8Array(32)),
  };
  await assertRejects(
    () => encryptPayload(short, new TextEncoder().encode("x")),
    Error,
    "65 bytes",
  );

  await assertRejects(
    () =>
      encryptPayload(
        { ...vector.subscription, auth: b64urlEncode(new Uint8Array(8)) },
        new TextEncoder().encode("x"),
      ),
    Error,
    "16 bytes",
  );

  // The control: the untouched subscription still encrypts.
  const ok = await encryptPayload(
    vector.subscription,
    new TextEncoder().encode("x"),
  );
  assert(ok.length > 86);
});

// ---------------------------------------------------------------------
// VAPID
// ---------------------------------------------------------------------

const keys: VapidKeys = {
  publicKey: vector.vapid.publicKey,
  privateKey: vector.vapid.privateKey,
  subject: vector.vapid.subject,
};

/** The moment that produces the fixture's expiry, twelve hours on. */
const signedAt = new Date((vector.vapid.expiry - 12 * 60 * 60) * 1000);

Deno.test("the VAPID header says what web-push says", async () => {
  const ours = await vapidAuthorization(keys, vector.subscription.endpoint, signedAt);

  const segments = (header: string) =>
    header.slice("vapid t=".length, header.indexOf(", k=")).split(".");

  // The signature is not compared: ECDSA is randomised, so two correct
  // signatures over the same bytes differ. The header and claims are
  // deterministic, and they are where the mistakes are — a wrong
  // audience or a missing subject is refused by the push service with a
  // 403 that names neither.
  assertEquals(segments(ours).slice(0, 2), segments(vector.vapid.authorization).slice(0, 2));

  // And the key is sent alongside, or the push service cannot check it.
  assert(ours.endsWith(`, k=${vector.vapid.publicKey}`));
});

Deno.test("and the signature verifies against the public key", async () => {
  const header = await vapidAuthorization(
    keys,
    vector.subscription.endpoint,
    signedAt,
  );
  const jwt = header.slice("vapid t=".length, header.indexOf(", k="));
  const [h, c, s] = jwt.split(".");

  const verified = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    await crypto.subtle.importKey(
      "raw",
      src(b64urlDecode(vector.vapid.publicKey)),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    ),
    src(b64urlDecode(s)),
    src(new TextEncoder().encode(`${h}.${c}`)),
  );
  assert(verified, "a JWT nobody can verify is a 403 from every push service");
});

Deno.test("the audience is the push service, not the endpoint", async () => {
  // Sending the full endpoint is the classic mistake: it leaks the
  // subscription into the token and the push service rejects it.
  const header = await vapidAuthorization(
    keys,
    "https://updates.push.services.mozilla.com/wpush/v2/gAAAA-secret",
    signedAt,
  );
  const claims = JSON.parse(
    new TextDecoder().decode(
      b64urlDecode(header.slice("vapid t=".length).split(".")[1]),
    ),
  );

  assertEquals(claims.aud, "https://updates.push.services.mozilla.com");
  assertEquals(claims.sub, vector.vapid.subject);
  assertEquals(claims.exp, vector.vapid.expiry);
});

Deno.test("a mismatched key pair fails here, not at the push service", async () => {
  const other = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const otherPublic = b64urlEncode(
    new Uint8Array(await crypto.subtle.exportKey("raw", other.publicKey)),
  );

  await assertRejects(
    () =>
      vapidAuthorization(
        { ...keys, publicKey: otherPublic },
        vector.subscription.endpoint,
      ),
    Error,
  );
});

Deno.test("a public key that is not an uncompressed point is named as such",
  async () => {
    await assertRejects(
      () =>
        vapidAuthorization(
          { ...keys, publicKey: b64urlEncode(new Uint8Array(65)) },
          vector.subscription.endpoint,
        ),
      Error,
      "0x04",
    );
  });

Deno.test("base64url survives padding and the standard alphabet", () => {
  const bytes = crypto.getRandomValues(new Uint8Array(65));
  const url = b64urlEncode(bytes);
  assertEquals(b64urlDecode(url), bytes);
  // How a key arrives when somebody has pasted it through a tool that
  // padded it, or one that never converted the alphabet.
  assertEquals(b64urlDecode(url + "=".repeat((4 - url.length % 4) % 4)), bytes);
  assertEquals(
    b64urlDecode(btoa(String.fromCharCode(...bytes))),
    bytes,
  );
});
