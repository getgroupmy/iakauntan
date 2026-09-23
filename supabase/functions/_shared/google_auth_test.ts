import {
  assert,
  assertEquals,
  assertMatch,
  assertRejects,
  assertStringIncludes,
} from "jsr:@std/assert@1.0.19";
import { googleAccessToken, type ServiceAccount } from "./google_auth.ts";

/**
 * The forty lines that stand in for a Google SDK.
 *
 * Nothing here reaches Google. A real 2048-bit RSA key is generated in
 * this process, the private half is written out as the PEM a service
 * account JSON carries, and `fetch` is replaced so the assertion the
 * function BUILT can be read -- and verified against the public half.
 *
 * That last part is the point. Every mistake available in here --
 * base64url that left a `+` in, a signature over the wrong bytes, a PEM
 * whose escaped newlines were not unescaped -- produces a well-formed
 * string that Google rejects with `invalid_grant` and nothing else. The
 * only way to tell a good assertion from a bad one without asking
 * Google is to verify the signature, which is what the first test does.
 *
 * `b64url` and `pkcs8` are not exported, so they are asserted through
 * the assertion they produce rather than directly.
 */

const pair = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true,
  ["sign", "verify"],
) as CryptoKeyPair;

function toPem(der: ArrayBuffer): string {
  const bytes = new Uint8Array(der);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  const body = btoa(binary).replace(/(.{64})/g, "$1\n");
  return `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`;
}

const PEM = toPem(await crypto.subtle.exportKey("pkcs8", pair.privateKey));

function account(over: Partial<ServiceAccount> = {}): ServiceAccount {
  return {
    client_email: "ocr@iakauntan-ocr.iam.gserviceaccount.com",
    private_key: PEM,
    ...over,
  };
}

// An ArrayBuffer rather than a Uint8Array, for the reason the source
// file records at `pkcs8`: `verify` wants a BufferSource backed by an
// ArrayBuffer specifically, and the plain constructor gives you one
// declared over the wider ArrayBufferLike.
function fromB64Url(s: string): ArrayBuffer {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(padded + "=".repeat((4 - padded.length % 4) % 4));
  const buffer = new ArrayBuffer(raw.length);
  const out = new Uint8Array(buffer);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return buffer;
}

/** Does Google's verifier accept this assertion? */
async function verifies(assertion: string): Promise<boolean> {
  const [header, claims, signature] = assertion.split(".");
  const pub = await crypto.subtle.importKey(
    "spki",
    await crypto.subtle.exportKey("spki", pair.publicKey),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  return await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    pub,
    fromB64Url(signature),
    new TextEncoder().encode(`${header}.${claims}`),
  );
}

function decodeSegment(s: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(fromB64Url(s)));
}

/** Swap `fetch`, returning the assertion the function posted. */
async function capture(
  reply: Response,
  sa: ServiceAccount,
  scope = "https://www.googleapis.com/auth/cloud-platform",
): Promise<{ url: string; init: RequestInit; token?: string; error?: Error }> {
  const real = globalThis.fetch;
  let seen!: { url: string; init: RequestInit };
  globalThis.fetch = ((input: string | URL | Request, init: RequestInit = {}) => {
    seen = { url: String(input), init };
    return Promise.resolve(reply);
  }) as typeof fetch;
  try {
    const token = await googleAccessToken(sa, scope);
    return { ...seen, token };
  } catch (error) {
    return { ...seen, error: error as Error };
  } finally {
    globalThis.fetch = real;
  }
}

function granted(token = "ya29.a0Af"): Response {
  return new Response(
    JSON.stringify({ access_token: token, token_type: "Bearer", expires_in: 3599 }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

Deno.test("the assertion is a JWT Google can verify", async () => {
  const before = Math.floor(Date.now() / 1000);
  const { init, token } = await capture(granted(), account(), "scope-under-test");
  assertEquals(token, "ya29.a0Af");

  const assertion = new URLSearchParams(String(init.body)).get("assertion")!;
  const [header, claims, signature] = assertion.split(".");
  assertEquals(assertion.split(".").length, 3);

  // base64url is base64 with three substitutions. A `+`, a `/` or a
  // trailing `=` anywhere in here is rejected by Google as
  // invalid_grant, with nothing said about which character.
  for (const segment of [header, claims, signature]) {
    assertMatch(segment, /^[A-Za-z0-9_-]+$/);
  }

  assertEquals(decodeSegment(header), { alg: "RS256", typ: "JWT" });

  const payload = decodeSegment(claims);
  assertEquals(payload.iss, "ocr@iakauntan-ocr.iam.gserviceaccount.com");
  assertEquals(payload.scope, "scope-under-test");
  assertEquals(payload.aud, "https://oauth2.googleapis.com/token");
  // An hour is the maximum Google accepts; ask for more and the whole
  // grant is refused.
  assertEquals(Number(payload.exp) - Number(payload.iat), 3600);
  assert(Number(payload.iat) >= before, "iat predates the call");
  assert(Number(payload.iat) <= Math.floor(Date.now() / 1000) + 1);

  // And the signature really is over `header.claims` with the key from
  // the PEM. This is the assertion that a hand-rolled signer needs and
  // that no amount of shape-checking replaces.
  assert(await verifies(assertion), "Google would refuse this assertion");
});

Deno.test("a key pasted with escaped newlines is the same key", async () => {
  // How these arrive: the JSON was pasted through something that
  // escaped the newlines, so the PEM is one line containing a literal
  // backslash-n. atob on that throws, and the org sees a 500 with no
  // explanation.
  const escaped = PEM.replace(/\n/g, "\\n");
  assert(!escaped.includes("\n"), "the fixture is not actually escaped");

  const { init } = await capture(granted(), account({ private_key: escaped }));
  const assertion = new URLSearchParams(String(init.body)).get("assertion")!;
  assert(
    await verifies(assertion),
    "the escaped-newline key signed something Google would refuse",
  );
});

Deno.test("a PEM carrying whatever it was pasted through still loads", async () => {
  // `atob` strips ASCII whitespace itself, so the newline cases below
  // would pass without the `\s` strip in `pkcs8`. The non-breaking
  // space is why that strip is there: it is NOT ASCII whitespace,
  // `atob` throws InvalidCharacterError on it, and it is exactly what
  // a key copied out of a rendered web page or a PDF carries.
  const nbsp = PEM.replace("\n", "\u00a0\n");
  for (const [name, key] of [
    ["no trailing newline", PEM.trimEnd()],
    ["wrapped in blanks", `\n\n  ${PEM}  \n`],
    ["a non-breaking space", nbsp],
  ] as const) {
    const { token, error } = await capture(granted(), account({ private_key: key }));
    assertEquals(error, undefined, `${name}: ${error?.message}`);
    assertEquals(token, "ya29.a0Af", name);
  }
});

Deno.test("the token endpoint is Google's, unless the account names another", async () => {
  const standard = await capture(granted(), account());
  assertEquals(standard.url, "https://oauth2.googleapis.com/token");
  assertEquals(
    (standard.init.headers as Record<string, string>)["Content-Type"],
    "application/x-www-form-urlencoded",
  );
  assertEquals(standard.init.method, "POST");
  assertEquals(
    new URLSearchParams(String(standard.init.body)).get("grant_type"),
    "urn:ietf:params:oauth:grant-type:jwt-bearer",
  );

  // `token_uri` is in the service account JSON and is what an emulator
  // or a sovereign endpoint is pointed at. It must reach BOTH the
  // request and the `aud` claim -- sign for one endpoint and post to
  // another and the grant is refused.
  const custom = await capture(
    granted(),
    account({ token_uri: "https://oauth2.example.test/token" }),
  );
  assertEquals(custom.url, "https://oauth2.example.test/token");
  const claims = decodeSegment(
    new URLSearchParams(String(custom.init.body)).get("assertion")!.split(".")[1],
  );
  assertEquals(claims.aud, "https://oauth2.example.test/token");
});

Deno.test("a credential that is not a service account says so before signing", async () => {
  // The ordinary mistake: an API key, or an OAuth client JSON, pasted
  // where the service account belongs. Caught before crypto.subtle is
  // reached, so the message is about the credential rather than about
  // a DataError from importKey.
  let fetched = false;
  const real = globalThis.fetch;
  globalThis.fetch = (() => {
    fetched = true;
    return Promise.resolve(granted());
  }) as typeof fetch;
  try {
    for (const bad of [
      { client_email: "", private_key: PEM },
      { client_email: "ocr@example.iam.gserviceaccount.com", private_key: "" },
      {} as ServiceAccount,
    ]) {
      const err = await assertRejects(
        () => googleAccessToken(bad as ServiceAccount, "s"),
        Error,
      );
      assertStringIncludes(err.message, "not a service account JSON");
      assertStringIncludes(err.message, "client_email");
      assertStringIncludes(err.message, "private_key");
    }
  } finally {
    globalThis.fetch = real;
  }
  assert(!fetched, "a malformed credential was sent to Google anyway");
});

Deno.test("Google's refusal is repeated, not swallowed", async () => {
  const refused = new Response(
    JSON.stringify({
      error: "invalid_grant",
      error_description: "Invalid JWT Signature.",
    }),
    { status: 400, headers: { "Content-Type": "application/json" } },
  );
  const { error } = await capture(refused, account());
  // error_description is the only field that ever says what is wrong.
  assertStringIncludes(String(error?.message), "Invalid JWT Signature.");

  // With only `error`, that is what gets repeated.
  const terse = await capture(
    new Response(JSON.stringify({ error: "unauthorized_client" }), { status: 401 }),
    account(),
  );
  assertStringIncludes(String(terse.error?.message), "unauthorized_client");

  // And when the body is not JSON at all -- a proxy's HTML error page --
  // the status is what is left to report. Losing it here turns a 503
  // into "undefined".
  const html = await capture(
    new Response("<html>503</html>", { status: 503 }),
    account(),
  );
  assertStringIncludes(String(html.error?.message), "503");
});

Deno.test("a 200 carrying no access_token is a failure", async () => {
  // Not hypothetical: a token endpoint behind a captive portal answers
  // 200 with something else entirely. Returning `undefined` from here
  // sends `Authorization: Bearer undefined` to Document AI, which fails
  // one layer further away from the cause.
  const { error, token } = await capture(
    new Response(JSON.stringify({ token_type: "Bearer" }), { status: 200 }),
    account(),
  );
  assertEquals(token, undefined);
  assert(error instanceof Error, "an empty grant was accepted");
  assertStringIncludes(error.message, "Google refused the service account");
});
