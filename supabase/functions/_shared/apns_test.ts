/**
 * APNs, asserted.
 *
 * A push service answering 200 proves very little — `web_push_test.ts`
 * makes the same point about 201 — so what is checked here is the parts
 * where being wrong produces no error at all:
 *
 *   * THE PROVIDER TOKEN IS REUSED. APNs rate-limits token generation
 *     rather than requests, so signing one per notification earns
 *     `TooManyProviderTokenUpdates` as soon as two people are in a
 *     conversation. The obvious implementation is the broken one, and
 *     nothing about it looks wrong.
 *   * THE CLAIMS ARE `iss` AND `iat`, with no `exp`. Apple ages a token
 *     by `iat`; an `exp` is at best ignored.
 *   * A VoIP PUSH GOES TO ITS OWN TOPIC. `<bundle>.voip`, or it is
 *     refused — and a VoIP push is the entire reason for addressing
 *     APNs directly rather than going through FCM.
 *   * `BadDeviceToken` IS NOT DEATH. It is what a live handset says
 *     when the wrong host was used, and acting on it would unregister
 *     every iPhone on a misconfigured deployment.
 *
 * The signature is verified against its own public key rather than a
 * stored vector, which is the opposite of what `web_push_test.ts` does:
 * there is no reference implementation to pin against here, and a
 * vector would pin the throwaway key rather than the arithmetic.
 *
 * One thing worth knowing, because it was found the hard way while
 * breaking this file on purpose: **Deno's ECDSA is deterministic.** Two
 * signings of one string with one key are byte-identical, so a test
 * cannot tell "a fresh token was minted" from "the cached one came
 * back" by comparing the strings. The assertions below move the clock
 * instead, which changes `iat` and is the real mechanism anyway.
 */
import { assert, assertEquals, assertRejects, assertThrows } from
  "jsr:@std/assert@1.0.19";
import {
  apnsAuthorization,
  apnsFromEnv,
  apnsHost,
  apnsPushType,
  apnsTopic,
  isDeadToken,
  resetApnsToken,
  sendApns,
  TOKEN_LIFETIME,
} from "./apns.ts";
import { b64urlDecode } from "./web_push.ts";

/** A throwaway P-256 key in the shape Apple hands a `.p8` over in. */
async function makeKey(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", pair.privateKey),
  );
  const body = btoa(String.fromCharCode(...pkcs8)).replace(
    /(.{64})/g,
    "$1\n",
  );
  return {
    pem: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`,
    publicKey: pair.publicKey,
  };
}

async function keys(overrides: Record<string, unknown> = {}) {
  const { pem, publicKey } = await makeKey();
  return {
    publicKey,
    keys: {
      keyId: "ABCDE12345",
      teamId: "TEAM123456",
      topic: "my.iakauntan.iakauntan",
      privateKeyPem: pem,
      production: false,
      ...overrides,
    },
  };
}

/**
 * The same accommodation `apns.ts` and `web_push.ts` both make.
 *
 * WebCrypto wants a BufferSource and will not take a Uint8Array typed
 * over the wider ArrayBufferLike, which is what `b64urlDecode` returns.
 */
function buf(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(
    bytes.byteOffset,
    bytes.byteOffset + bytes.byteLength,
  ) as ArrayBuffer;
}

function parts(authorization: string) {
  assert(authorization.startsWith("bearer "), authorization);
  const [header, claims, signature] = authorization.slice(7).split(".");
  const text = new TextDecoder();
  return {
    header: JSON.parse(text.decode(b64urlDecode(header))),
    claims: JSON.parse(text.decode(b64urlDecode(claims))),
    signature,
    signed: `${header}.${claims}`,
  };
}

Deno.test("the provider token says who is asking", async () => {
  resetApnsToken();
  const { keys: k } = await keys();
  const { header, claims } = parts(await apnsAuthorization(k));

  assertEquals(header.alg, "ES256");
  assertEquals(header.kid, "ABCDE12345");
  assertEquals(claims.iss, "TEAM123456");
  assertEquals(typeof claims.iat, "number");
});

Deno.test("and carries no exp, which Apple does not use", async () => {
  // Apple ages a provider token by its `iat`. An `exp` is not the
  // mechanism, and adding one is at best ignored.
  resetApnsToken();
  const { keys: k } = await keys();
  const { claims } = parts(await apnsAuthorization(k));
  assertEquals("exp" in claims, false);
  assertEquals(Object.keys(claims).sort(), ["iat", "iss"]);
});

Deno.test("the signature is really made with the key", async () => {
  resetApnsToken();
  const { keys: k, publicKey } = await keys();
  const { signature, signed } = parts(await apnsAuthorization(k));

  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    buf(b64urlDecode(signature)),
    buf(new TextEncoder().encode(signed)),
  );
  assert(ok, "the JWT does not verify against its own public key");
});

Deno.test("one token is reused rather than minted per notification", async () => {
  // The trap. APNs rate-limits token GENERATION -- a fresh JWT per
  // notification earns `TooManyProviderTokenUpdates` as soon as a
  // conversation has two people in it -- and nothing about signing one
  // each time looks wrong.
  resetApnsToken();
  const { keys: k } = await keys();
  const first = await apnsAuthorization(k, new Date(1_000_000_000_000));
  const again = await apnsAuthorization(k, new Date(1_000_000_060_000));
  assertEquals(first, again);
});

Deno.test("and minted again before it ages out", async () => {
  resetApnsToken();
  const { keys: k } = await keys();
  const start = new Date(1_000_000_000_000);
  const first = await apnsAuthorization(k, start);
  const later = await apnsAuthorization(
    k,
    new Date(start.getTime() + TOKEN_LIFETIME + 1),
  );
  assert(first !== later, "the token was never refreshed");

  // Inside the hour Apple allows, with room for a wrong clock. A
  // lifetime at or over the hour would age out in production and a
  // lifetime under twenty minutes would be rate-limited, so the window
  // is narrow at both ends.
  assert(TOKEN_LIFETIME < 60 * 60 * 1000, "a token this old is refused");
  assert(TOKEN_LIFETIME > 20 * 60 * 1000, "minting this often is refused");
});

Deno.test("rotating the key takes effect at once", async () => {
  // Not fifty minutes later. Somebody who has just replaced a leaked
  // key should not have it keep being used.
  resetApnsToken();
  const a = await keys();
  const b = await keys({ keyId: "ZZZZZ99999" });
  const at = new Date(1_000_000_000_000);
  const first = await apnsAuthorization(a.keys, at);
  const second = await apnsAuthorization(b.keys, at);
  assert(first !== second);
  assertEquals(parts(second).header.kid, "ZZZZZ99999");
});

Deno.test("a call is a VoIP push and a message is not", () => {
  assertEquals(apnsPushType("call"), "voip");
  assertEquals(apnsPushType("message"), "alert");
  // Anything unrecognised is an ordinary alert rather than a VoIP push:
  // a wrong VoIP push is refused outright, a wrong alert is merely an
  // alert.
  assertEquals(apnsPushType("something-new"), "alert");
});

Deno.test("a VoIP push goes to its own topic", async () => {
  // `<bundle>.voip`, and nothing else will do -- sent to the plain
  // topic it is `TopicDisallowed`. This is the whole reason for
  // addressing APNs directly instead of going through FCM.
  const { keys: k } = await keys();
  assertEquals(apnsTopic(k, "voip"), "my.iakauntan.iakauntan.voip");
  assertEquals(apnsTopic(k, "alert"), "my.iakauntan.iakauntan");
});

Deno.test("sandbox and production are different hosts", async () => {
  const { keys: k } = await keys();
  assertEquals(apnsHost(k), "https://api.sandbox.push.apple.com");
  assertEquals(
    apnsHost({ ...k, production: true }),
    "https://api.push.apple.com",
  );
});

Deno.test("only Unregistered means the handset is gone", () => {
  assert(isDeadToken(410, "Unregistered"));
  assert(isDeadToken(410));

  // The one that matters. `BadDeviceToken` is what a perfectly live
  // iPhone answers when a sandbox token is sent to the production host,
  // and treating it as death would quietly unregister every handset on
  // a deployment whose APNS_PRODUCTION is wrong -- leaving nothing to
  // notice once somebody fixed it.
  assertEquals(isDeadToken(400, "BadDeviceToken"), false);
  assertEquals(isDeadToken(403, "InvalidProviderToken"), false);
  assertEquals(isDeadToken(429, "TooManyProviderTokenUpdates"), false);
  assertEquals(isDeadToken(500), false);
});

Deno.test("a notification carries the headers APNs requires", async () => {
  resetApnsToken();
  const { keys: k } = await keys();
  let seen: { url: string; headers: Record<string, string>; body: string } | null =
    null;

  const result = await sendApns(k, "abc123", { aps: { alert: "hi" } }, {
    pushType: "voip",
    expiration: 0,
    id: "11111111-1111-1111-1111-111111111111",
    transport: ((url: string, init: RequestInit) => {
      seen = {
        url,
        headers: init.headers as Record<string, string>,
        body: init.body as string,
      };
      return Promise.resolve(new Response(null, { status: 200 }));
    }) as unknown as typeof fetch,
  });

  assert(result.ok);
  assertEquals(result.dead, false);
  assert(seen !== null);
  const sent = seen as unknown as {
    url: string;
    headers: Record<string, string>;
    body: string;
  };
  assertEquals(sent.url, "https://api.sandbox.push.apple.com/3/device/abc123");
  assertEquals(sent.headers["apns-push-type"], "voip");
  assertEquals(sent.headers["apns-topic"], "my.iakauntan.iakauntan.voip");
  assertEquals(sent.headers["apns-priority"], "10");
  // Zero is meaningful -- "now or never", which is what a ringing phone
  // wants -- so it must survive a truthiness test that would drop it.
  assertEquals(sent.headers["apns-expiration"], "0");
  assertEquals(sent.headers["apns-id"], "11111111-1111-1111-1111-111111111111");
  assert(sent.headers["authorization"].startsWith("bearer "));
  assertEquals(JSON.parse(sent.body).aps.alert, "hi");
});

Deno.test("Apple's reason comes back with the failure", async () => {
  resetApnsToken();
  const { keys: k } = await keys();
  const result = await sendApns(k, "abc123", {}, {
    pushType: "alert",
    transport: (() =>
      Promise.resolve(
        new Response(JSON.stringify({ reason: "Unregistered" }), {
          status: 410,
        }),
      )) as unknown as typeof fetch,
  });
  assertEquals(result.ok, false);
  assertEquals(result.status, 410);
  assertEquals(result.reason, "Unregistered");
  assert(result.dead);
});

Deno.test("a dropped connection is not a dead handset", async () => {
  resetApnsToken();
  const { keys: k } = await keys();
  const result = await sendApns(k, "abc123", {}, {
    pushType: "alert",
    transport: (() =>
      Promise.reject(new Error("connection reset"))) as unknown as typeof fetch,
  });
  assertEquals(result.ok, false);
  assertEquals(result.dead, false);
  // Kept, so the notification is merely missed rather than the phone
  // being unregistered by a bad minute on the network.
  assertEquals(result.status, 0);
});

Deno.test("a stale provider token is thrown away rather than reused", async () => {
  // Otherwise the same rejected token goes out for the rest of its
  // fifty minutes and every notification in that window is lost.
  resetApnsToken();
  const { keys: k } = await keys();

  // `sendApns` mints against the real clock, so this one has to as
  // well -- an earlier version pinned this call to a date in 2001 and
  // the cache was then invalidated by the twenty-five year gap rather
  // than by the reset. It passed with the reset deleted: a test of
  // clock arithmetic wearing this test's name.
  const before = await apnsAuthorization(k);

  await sendApns(k, "abc123", {}, {
    pushType: "alert",
    transport: (() =>
      Promise.resolve(
        new Response(JSON.stringify({ reason: "ExpiredProviderToken" }), {
          status: 403,
        }),
      )) as unknown as typeof fetch,
  });

  // A second later, which is still well inside the fifty minutes -- so
  // a live cache returns the same string and only a reset mints a new
  // one. The second is what makes them distinguishable: `iat` moves,
  // and the signature alone would not, because Deno's ECDSA is
  // deterministic.
  const after = await apnsAuthorization(k, new Date(Date.now() + 1000));
  assert(before !== after, "the rejected token was used again");
});

Deno.test("and an ordinary failure does not throw the token away", async () => {
  // The control on the test above. Without it, a version that reset the
  // cache after EVERY failure would pass -- and would mint a fresh
  // provider token per failed notification, which is how a deployment
  // earns `TooManyProviderTokenUpdates` on top of whatever was already
  // wrong.
  resetApnsToken();
  const { keys: k } = await keys();
  const before = await apnsAuthorization(k);

  await sendApns(k, "abc123", {}, {
    pushType: "alert",
    transport: (() =>
      Promise.resolve(
        new Response(JSON.stringify({ reason: "Unregistered" }), {
          status: 410,
        }),
      )) as unknown as typeof fetch,
  });

  assertEquals(await apnsAuthorization(k, new Date(Date.now() + 1000)), before);
});

Deno.test("a key that is not an APNs key says so", async () => {
  resetApnsToken();
  const { keys: k } = await keys();
  await assertRejects(
    () =>
      apnsAuthorization({
        ...k,
        privateKeyPem: "nothing like a PEM file",
      }),
    Error,
    "APNS_KEY_P8 is not a PEM private key",
  );
});

Deno.test("configured, not configured, and half configured", () => {
  const names = [
    "APNS_KEY_P8",
    "APNS_KEY_ID",
    "APNS_TEAM_ID",
    "APNS_TOPIC",
    "APNS_PRODUCTION",
  ];
  const saved = Object.fromEntries(names.map((n) => [n, Deno.env.get(n)]));
  const restore = () => {
    for (const n of names) {
      const was = saved[n];
      if (was === undefined) Deno.env.delete(n);
      else Deno.env.set(n, was);
    }
  };

  try {
    for (const n of names) Deno.env.delete(n);
    // A deployment with no Apple account is the ordinary case, not a
    // broken one.
    assertEquals(apnsFromEnv(), null);

    // Half of it is somebody midway through a job, and answering "not
    // configured" would leave them hunting for why iPhones are skipped.
    Deno.env.set("APNS_KEY_ID", "ABCDE12345");
    assertThrows(() => apnsFromEnv(), Error, "half configured");

    Deno.env.set("APNS_KEY_P8", "-----BEGIN PRIVATE KEY-----\\nAAAA\\n" +
      "-----END PRIVATE KEY-----");
    Deno.env.set("APNS_TEAM_ID", "TEAM123456");
    Deno.env.set("APNS_TOPIC", "my.iakauntan.iakauntan");
    const k = apnsFromEnv();
    assert(k !== null);
    assertEquals(k!.teamId, "TEAM123456");
    // Dashboards eat newlines out of a pasted .p8, so a literal
    // backslash-n is put back -- otherwise a perfectly correct key is
    // refused for being flattened.
    assert(k!.privateKeyPem.includes("\n"));
    assert(!k!.privateKeyPem.includes("\\n"));
    // Sandbox until somebody says otherwise: shipping to the production
    // host by default would refuse every token a development build
    // registered, with `BadDeviceToken` and no explanation.
    assertEquals(k!.production, false);

    Deno.env.set("APNS_PRODUCTION", "true");
    assertEquals(apnsFromEnv()!.production, true);
  } finally {
    restore();
  }
});
