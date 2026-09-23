import {
  assert,
  assertEquals,
  assertMatch,
  assertRejects,
  assertStringIncludes,
} from "jsr:@std/assert@1.0.19";
import {
  type ApiCall,
  CallLog,
  MyInvoisClient,
  sha256Hex,
  toBase64,
  validationLink,
} from "./myinvois.ts";

/**
 * The client that talks to LHDN, and the three pure functions whose
 * output LHDN reads byte for byte.
 *
 * Nothing here reaches the network. `fetch` is replaced for the length
 * of each test that needs it, which is also the only way to see the
 * request the client BUILDS -- the host it picked, the header it added
 * for an intermediary, the path it appended -- rather than the reply it
 * got. A wrong host is a submission that silently went to preprod, and
 * an invoice that was never filed.
 *
 * Two hazards, both written down because they are invisible in a
 * passing run:
 *
 * `tokenCache` is module scope. It outlives a test. Every test below
 * uses its own client id, so one test's cached token cannot answer
 * another's `getToken` and turn a real assertion into a no-op. The
 * cache-hit test is the only one that reuses an id, and it does so
 * deliberately.
 *
 * And `documentHash` is compared by LHDN against the base64 `document`
 * we send beside it. The hash is of the RAW JSON and the document is
 * the base64 OF THAT SAME JSON: hash the base64, or base64 a different
 * string than you hashed, and MyInvois rejects the submission with a
 * message about neither. The pair is asserted together at the bottom.
 */

/** Swap `fetch` for the duration of `body`, and hand back what it saw. */
async function withFetch(
  reply: (url: string, init: RequestInit) => Response,
  body: () => Promise<void>,
): Promise<{ url: string; init: RequestInit }[]> {
  const seen: { url: string; init: RequestInit }[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = ((input: string | URL | Request, init: RequestInit = {}) => {
    const url = String(input);
    seen.push({ url, init });
    return Promise.resolve(reply(url, init));
  }) as typeof fetch;
  try {
    await body();
  } finally {
    globalThis.fetch = real;
  }
  return seen;
}

function token(expiresIn = 3600): Response {
  return new Response(
    JSON.stringify({
      access_token: "tok-abc",
      token_type: "Bearer",
      expires_in: expiresIn,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

Deno.test("sha256Hex is the hex of the UTF-8 bytes, lowercase", async () => {
  // The published vector. Pins the algorithm, not just the shape.
  assertEquals(
    await sha256Hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );

  // A name with an em dash in it, hashed as UTF-8. UTF-16 would give
  // e95870d3..., and a company whose name is entirely ASCII would never
  // show the difference.
  assertEquals(
    await sha256Hex("Kedai Kopi Ah Seng Sdn Bhd — Jalan Ampang, 50450"),
    "26c9888d0347929ba4f716aa2438878e0ea2021bc4ec28f3beeba9794ba8a509",
  );
});

Deno.test("sha256Hex pads a byte below 0x10 to two characters", async () => {
  // sha256("39") begins 0x0b. Without the padStart that byte renders as
  // "b", the digest is 63 characters, and every hash whose bytes all
  // exceed 0x0f -- most of them -- still looks right.
  const digest = await sha256Hex("39");
  assertEquals(
    digest,
    "0b918943df0962bc7a1824c0555a389347b4febdc7cf9d1254406d80ce44e3f9",
  );
  assertEquals(digest.length, 64);
  assertMatch(digest, /^[0-9a-f]{64}$/);
});

Deno.test("toBase64 survives characters btoa alone cannot take", () => {
  const name = "Kedai Kopi Ah Seng Sdn Bhd — Jalan Ampang, 50450";
  assertEquals(
    toBase64(name),
    "S2VkYWkgS29waSBBaCBTZW5nIFNkbiBCaGQg4oCUIEphbGFuIEFtcGFuZywgNTA0NTA=",
  );

  // btoa(name) throws InvalidCharacterError on the em dash: this is the
  // whole reason the function exists rather than being a one-liner.
  let threw = false;
  try {
    btoa(name);
  } catch {
    threw = true;
  }
  assert(threw, "btoa should refuse the multi-byte string this encodes");

  // And it round-trips: what LHDN decodes is the string we started with.
  const back = new TextDecoder().decode(
    Uint8Array.from(atob(toBase64(name)), (c) => c.charCodeAt(0)),
  );
  assertEquals(back, name);
});

Deno.test("validationLink points at the portal the environment belongs to", () => {
  const uuid = "F9D425P6DS7D8IU";
  const longId = "YRVW9M8QK2";

  assertEquals(
    validationLink("production", uuid, longId),
    `https://myinvois.hasil.gov.my/${uuid}/share/${longId}`,
  );
  assertEquals(
    validationLink("sandbox", uuid, longId),
    `https://preprod.myinvois.hasil.gov.my/${uuid}/share/${longId}`,
  );

  // The portal host is NOT the API host. `preprod-api...` serves the API
  // and would give a buyer scanning the QR code nothing to look at.
  assert(!validationLink("sandbox", uuid, longId).includes("preprod-api"));
  assert(!validationLink("production", uuid, longId).includes("preprod"));
});

Deno.test("the environment decides both hosts", async () => {
  const seen = await withFetch(() => token(), async () => {
    await new MyInvoisClient({
      clientId: "hosts-prod",
      clientSecret: "s",
      environment: "production",
    }).getDocumentDetails("abc");
  });
  assertEquals(seen[0].url, "https://api.myinvois.hasil.gov.my/connect/token");
  assertEquals(
    seen[1].url,
    "https://api.myinvois.hasil.gov.my/api/v1.0/documents/abc/details",
  );

  const sandbox = await withFetch(() => token(), async () => {
    await new MyInvoisClient({
      clientId: "hosts-sandbox",
      clientSecret: "s",
      environment: "sandbox",
    }).getDocumentDetails("abc");
  });
  assertEquals(
    sandbox[0].url,
    "https://preprod-api.myinvois.hasil.gov.my/connect/token",
  );
  assertEquals(
    sandbox[1].url,
    "https://preprod-api.myinvois.hasil.gov.my/api/v1.0/documents/abc/details",
  );
});

Deno.test("the client secret is never written to the call log", async () => {
  const client = new MyInvoisClient({
    clientId: "secret-test",
    clientSecret: "hunter2-do-not-log",
    environment: "sandbox",
  });
  await withFetch(() => token(), async () => {
    await client.getToken();
  });

  const logged = JSON.stringify(client.calls);
  assert(
    !logged.includes("hunter2-do-not-log"),
    `the secret reached the audit trail: ${logged}`,
  );
  // The call itself is still recorded -- the assertion above passes
  // trivially if nothing was logged at all.
  assertEquals(client.calls.length, 1);
  assertEquals(client.calls[0].operation, "token");
  assertEquals(client.calls[0].status, 200);
});

Deno.test("a rejected token is thrown, with the status, and not cached", async () => {
  const client = new MyInvoisClient({
    clientId: "bad-creds",
    clientSecret: "wrong",
    environment: "sandbox",
  });

  const seen = await withFetch(
    () => new Response("invalid_client", { status: 401 }),
    async () => {
      const err = await assertRejects(() => client.getToken(), Error);
      assertStringIncludes(err.message, "401");
      assertStringIncludes(err.message, "invalid_client");
      // A second attempt must reach the identity service again: a
      // failure that got cached locks the org out until the instance
      // recycles.
      await assertRejects(() => client.getToken(), Error);
    },
  );
  assertEquals(seen.length, 2);
  assertEquals(client.calls[0].error, "invalid_client");
});

Deno.test("a live token is reused and a nearly-dead one is not", async () => {
  let issued = 0;
  await withFetch(() => {
    issued++;
    return token(3600);
  }, async () => {
    const creds = {
      clientId: "cache-live",
      clientSecret: "s",
      environment: "sandbox" as const,
    };
    await new MyInvoisClient(creds).getToken();
    // A different client object, same credentials: the cache is module
    // scope on purpose, because MyInvois rate limits the identity
    // service hard and every edge invocation builds a new client.
    await new MyInvoisClient(creds).getToken();
  });
  assertEquals(issued, 1);

  // 30 seconds of life left. The client refreshes a minute early, so
  // this one is already spent.
  let reissued = 0;
  await withFetch(() => {
    reissued++;
    return token(30);
  }, async () => {
    const creds = {
      clientId: "cache-expiring",
      clientSecret: "s",
      environment: "sandbox" as const,
    };
    await new MyInvoisClient(creds).getToken();
    await new MyInvoisClient(creds).getToken();
  });
  assertEquals(reissued, 2);
});

Deno.test("the cache key separates environments and taxpayers", async () => {
  let issued = 0;
  await withFetch(() => {
    issued++;
    return token();
  }, async () => {
    const base = { clientId: "key-split", clientSecret: "s" };
    // Same id, sandbox then production: a token minted against preprod
    // is not accepted by production.
    await new MyInvoisClient({ ...base, environment: "sandbox" }).getToken();
    await new MyInvoisClient({ ...base, environment: "production" }).getToken();
    // Same id and environment, acting for two different taxpayers. The
    // token carries the onbehalfof identity; reusing one across clients
    // files a client's invoice under another client's TIN.
    await new MyInvoisClient({
      ...base,
      environment: "production",
      onBehalfOf: "C1234567890",
    }).getToken();
    await new MyInvoisClient({
      ...base,
      environment: "production",
      onBehalfOf: "C9999999999",
    }).getToken();
  });
  assertEquals(issued, 4);
});

Deno.test("onBehalfOf rides on the token request and on every call", async () => {
  const seen = await withFetch(() => token(), async () => {
    await new MyInvoisClient({
      clientId: "obo",
      clientSecret: "s",
      environment: "sandbox",
      onBehalfOf: "C2584563222",
    }).getDocumentDetails("abc");
  });
  for (const { url, init } of seen) {
    const headers = init.headers as Record<string, string>;
    assertEquals(headers["onbehalfof"], "C2584563222", `missing on ${url}`);
  }
  assertEquals(seen.length, 2);

  // And is absent -- not empty, not "undefined" -- when the org files
  // for itself.
  const own = await withFetch(() => token(), async () => {
    await new MyInvoisClient({
      clientId: "no-obo",
      clientSecret: "s",
      environment: "sandbox",
    }).getDocumentDetails("abc");
  });
  for (const { init } of own) {
    assert(!("onbehalfof" in (init.headers as Record<string, string>)));
  }
});

Deno.test("each operation reaches the endpoint LHDN publishes for it", async () => {
  const client = new MyInvoisClient({
    clientId: "endpoints",
    clientSecret: "s",
    environment: "production",
  });
  const api = "https://api.myinvois.hasil.gov.my/api/v1.0";

  const seen = await withFetch(() => token(), async () => {
    await client.submitDocuments([]);
    await client.getSubmission("SUB-1");
    await client.getSubmission("SUB-1", 2, 50);
    await client.getDocumentDetails("DOC-1");
    await client.setDocumentState("DOC-1", "cancelled", "Duplicate");
    await client.validateTin("C2584563222", "BRN", "202001234567");
  });

  const calls = seen.slice(1); // the first is the token
  assertEquals(calls.map((c) => c.init.method), [
    "POST",
    "GET",
    "GET",
    "GET",
    "PUT",
    "GET",
  ]);
  assertEquals(calls[0].url, `${api}/documentsubmissions`);
  // Paging defaults matter: page 1 of 100 is what a single-invoice
  // submission needs, and pageNo=0 returns nothing at all.
  assertEquals(calls[1].url, `${api}/documentsubmissions/SUB-1?pageNo=1&pageSize=100`);
  assertEquals(calls[2].url, `${api}/documentsubmissions/SUB-1?pageNo=2&pageSize=50`);
  assertEquals(calls[3].url, `${api}/documents/DOC-1/details`);
  assertEquals(calls[4].url, `${api}/documents/state/DOC-1/state`);
  assertEquals(
    JSON.parse(String(calls[4].init.body)),
    { status: "cancelled", reason: "Duplicate" },
  );
  assertEquals(
    calls[5].url,
    `${api}/taxpayer/validate/C2584563222?idType=BRN&idValue=202001234567`,
  );

  // Every one of them is in the audit trail, in order, named.
  assertEquals(client.calls.map((c: ApiCall) => c.operation), [
    "token",
    "submit",
    "submission_status",
    "submission_status",
    "status",
    "cancel",
    "validate_tin",
  ]);
});

Deno.test("an identifier with a slash in it cannot rewrite the path", async () => {
  const seen = await withFetch(() => token(), async () => {
    await new MyInvoisClient({
      clientId: "escaping",
      clientSecret: "s",
      environment: "sandbox",
    }).validateTin("C123/../../x", "NRIC", "880101-14-5566");
  });
  const url = seen[1].url;
  assertStringIncludes(url, "/taxpayer/validate/C123%2F..%2F..%2Fx");
  assert(!url.includes("validate/C123/"));
});

Deno.test("a non-JSON body is kept rather than lost", async () => {
  const client = new MyInvoisClient({
    clientId: "html-error",
    clientSecret: "s",
    environment: "sandbox",
  });
  await withFetch((url) => {
    if (url.endsWith("/connect/token")) return token();
    // What a gateway returns when MyInvois is down: HTML, not JSON.
    return new Response("<html>502 Bad Gateway</html>", { status: 502 });
  }, async () => {
    const { status, data } = await client.getDocumentDetails("DOC-1");
    // A 502 is returned, not thrown -- only the token call throws, so
    // the caller can record the failed submission against the invoice.
    assertEquals(status, 502);
    assertEquals(data, { raw: "<html>502 Bad Gateway</html>" });
  });
  assertStringIncludes(String(client.calls[1].error), "502 Bad Gateway");
});

Deno.test("an empty 204 body reads as null, not as a parse failure", async () => {
  const client = new MyInvoisClient({
    clientId: "empty-body",
    clientSecret: "s",
    environment: "sandbox",
  });
  await withFetch((url) => {
    if (url.endsWith("/connect/token")) return token();
    return new Response(null, { status: 204 });
  }, async () => {
    const { status, data } = await client.setDocumentState("D", "rejected", "r");
    assertEquals(status, 204);
    assertEquals(data, null);
  });
});

Deno.test("a log passed in is the log written to", async () => {
  // Two clients, one trail: a submission and its status poll belong to
  // the same invoice and are persisted together.
  const shared = new CallLog();
  await withFetch(() => token(), async () => {
    await new MyInvoisClient(
      { clientId: "shared-a", clientSecret: "s", environment: "sandbox" },
      shared,
    ).submitDocuments([]);
    await new MyInvoisClient(
      { clientId: "shared-b", clientSecret: "s", environment: "sandbox" },
      shared,
    ).getSubmission("SUB-1");
  });
  assertEquals(shared.calls.map((c) => c.operation), [
    "token",
    "submit",
    "token",
    "submission_status",
  ]);
  for (const call of shared.calls) {
    assert(call.durationMs >= 0, "a call was logged without a duration");
  }
});

Deno.test("documentHash is of the same bytes document carries", async () => {
  // The pair MyInvois checks against each other. Hashing the base64, or
  // encoding a re-serialised copy of the JSON, both produce a rejection
  // that names neither field.
  const ubl = JSON.stringify({ Invoice: [{ ID: [{ _: "INV-0001" }] }] });
  const doc = {
    format: "JSON" as const,
    document: toBase64(ubl),
    documentHash: await sha256Hex(ubl),
    codeNumber: "INV-0001",
  };

  const decoded = new TextDecoder().decode(
    Uint8Array.from(atob(doc.document), (c) => c.charCodeAt(0)),
  );
  assertEquals(decoded, ubl);
  assertEquals(doc.documentHash, await sha256Hex(decoded));
  assertMatch(doc.documentHash, /^[0-9a-f]{64}$/);

  const seen = await withFetch(() => token(), async () => {
    await new MyInvoisClient({
      clientId: "submit-shape",
      clientSecret: "s",
      environment: "sandbox",
    }).submitDocuments([doc]);
  });
  assertEquals(JSON.parse(String(seen[1].init.body)), { documents: [doc] });
});
