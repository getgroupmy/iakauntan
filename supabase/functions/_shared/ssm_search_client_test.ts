import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  normalizeEntityType,
  normalizeSearchResults,
  SsmApiError,
  SsmSearchClient,
} from "./ssm-search-client.ts";

/**
 * Reading SSM's official Search API.
 *
 * Every production call is CHARGED against a points balance the whole
 * platform shares, so the one thing this cannot do is talk to SSM.
 * `fetch` is injected and the assertions are about the parts that
 * decide what a person is shown and what the app records — which,
 * once picked, becomes a registration number on an e-Invoice.
 *
 * Three of these are about failures that arrive wearing a 200. CIDP
 * puts its errors INSIDE the payload: `errorMsg` beside the data, under
 * a normal success status. A client that reads only the HTTP status
 * treats "no such company" as a company.
 */

function respond(body: unknown, status = 200): typeof fetch {
  return () =>
    Promise.resolve(
      new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json" },
      }),
    );
}

function client(fetchImpl: typeof fetch): SsmSearchClient {
  return new SsmSearchClient({
    apiKey: "k",
    apiSecret: "s",
    baseUrl: "https://example.invalid/",
    fetch: fetchImpl,
  });
}

const oneHit = {
  getSearchEntity: {
    searchEntity: {
      currentPage: "1",
      nextPage: "2",
      data: [{
        companyName: "MAJU SDN. BHD.",
        companyNo: "199301012345",
        oldCompanyNo: "123456-X",
        entityType: "company",
      }],
    },
  },
};

Deno.test("the payload is unwrapped from its single-key envelope", async () => {
  const out = await client(respond(oneHit)).searchEntity({ name: "MAJU" });
  assertEquals(out.searchEntity?.data?.length, 1);
});

Deno.test("a search result gives the four fields that are saved", () => {
  const hits = normalizeSearchResults(oneHit.getSearchEntity);
  assertEquals(hits.length, 1);
  assertEquals(hits[0].name, "MAJU SDN. BHD.");
  assertEquals(hits[0].newRegNo, "199301012345");
  assertEquals(hits[0].oldRegNo, "123456-X");
  assertEquals(hits[0].entityType, "company");
});

Deno.test("a missing field is an empty string, never undefined", () => {
  // The four go straight onto a contact. `undefined` reaching
  // `set_contact_ssm_entity` would arrive as a missing key, and the
  // column would keep whatever a person had typed off a letterhead --
  // which is the thing the lookup exists to replace.
  const hits = normalizeSearchResults({
    searchEntity: { data: [{ companyName: "ONLY A NAME SDN BHD" }] },
    // deno-lint-ignore no-explicit-any
  } as any);
  assertEquals(hits[0].newRegNo, "");
  assertEquals(hits[0].oldRegNo, "");
  assertEquals(hits[0].entityType, "");
});

Deno.test("an error inside a 200 is an error", async () => {
  // The one that matters. CIDP answers HTTP 200 with `errorMsg` beside
  // the data, so a client reading only the status shows a company that
  // is not there.
  const err = await assertRejects(
    () =>
      client(
        respond({
          getCompProfile: { errorMsg: "No record found", successCode: "404" },
        }),
      ).companyProfile({ regNo: "199301012345" }),
    SsmApiError,
  );
  assertEquals(err.kind, "upstream");
  assertEquals(err.status, 200);
  assertEquals(err.code, "404");
});

Deno.test("an empty errorMsg is not an error", () => {
  // The control. CIDP sends `errorMsg: ""` on success, and a truthiness
  // check that took it for a failure would refuse every good answer.
  return client(respond({ getCompProfile: { errorMsg: "", rocCompanyInfo: {} } }))
    .companyProfile({ regNo: "199301012345" })
    .then((out) => assertEquals(typeof out, "object"));
});

Deno.test("a 401 is our credential, and says so", async () => {
  const err = await assertRejects(
    () => client(respond({ error: "Invalid API key" }, 401)).searchEntity({ name: "X" }),
    SsmApiError,
  );
  assertEquals(err.kind, "auth");
});

Deno.test("a 200 with no wrapper key is not a result", async () => {
  const err = await assertRejects(
    () => client(respond({ message: "Unauthorized" })).searchEntity({ name: "X" }),
    SsmApiError,
  );
  assertEquals(err.kind, "payload");
});

Deno.test("a 404 carrying a statusCode is a wrong route, not a wrong company", async () => {
  // Different advice: a route error means SSMSEARCH_API_BASE_URL is
  // wrong and nobody's search will ever work, where "no record" means
  // this one company was not found.
  const err = await assertRejects(
    () =>
      client(respond({ message: "Cannot POST", error: "Not Found", statusCode: 404 }, 404))
        .searchEntity({ name: "X" }),
    SsmApiError,
  );
  assertEquals(err.kind, "route");
});

Deno.test("a body that is not JSON is reported as such", async () => {
  const err = await assertRejects(
    () =>
      new SsmSearchClient({
        apiKey: "k",
        apiSecret: "s",
        baseUrl: "https://example.invalid/",
        fetch: () => Promise.resolve(new Response("<html>gateway</html>")),
      }).searchEntity({ name: "X" }),
    SsmApiError,
  );
  assertEquals(err.kind, "parse");
});

Deno.test("the key and the secret go in the headers and not the body", async () => {
  let seen: Request | null = null;
  let sentBody = "";
  await client(((url: string | URL | Request, init?: RequestInit) => {
    seen = new Request(url as string, init);
    sentBody = String(init?.body ?? "");
    return Promise.resolve(
      new Response(JSON.stringify(oneHit), { status: 200 }),
    );
  }) as typeof fetch).searchEntity({ name: "MAJU" });

  const req = seen as unknown as Request;
  assertEquals(req.headers.get("x-Gateway-APIKey"), "k");
  assertEquals(req.headers.get("x-Gateway-APISecret"), "s");
  // Never in the body, which is what gets logged and cached.
  assertEquals(sentBody.includes('"k"'), false);
  assertEquals(sentBody.includes('"s"'), false);
});

Deno.test("every call carries a reference, and SSM's support asks for it", async () => {
  let ref: string | null = null;
  await client(((url: string | URL | Request, init?: RequestInit) => {
    ref = new Request(url as string, init).headers.get("x-Client-Ref-No");
    return Promise.resolve(new Response(JSON.stringify(oneHit), { status: 200 }));
  }) as typeof fetch).searchEntity({ name: "MAJU" });
  assertEquals(typeof ref, "string");
  assertEquals((ref as unknown as string).length > 0, true);
});

Deno.test("searchAll stops when the next page is the current one", async () => {
  // The loop that would otherwise pay for the same page forever. CIDP
  // repeats `currentPage` in `nextPage` on the last page rather than
  // sending an empty one.
  let calls = 0;
  const c = client((() => {
    calls++;
    return Promise.resolve(
      new Response(
        JSON.stringify({
          getSearchEntity: {
            searchEntity: {
              currentPage: "1",
              nextPage: "1",
              data: [{ companyName: "ONE SDN BHD" }],
            },
          },
        }),
        { status: 200 },
      ),
    );
  }) as typeof fetch);

  const out = await c.searchAll({ name: "ONE" }, { maxPages: 5 });
  assertEquals(calls, 1);
  assertEquals(out.pagesFetched, 1);
  assertEquals(out.exhausted, true);
});

Deno.test("and stops at maxPages when the register does not", async () => {
  // Every page is a charged call. A register that keeps offering a next
  // page must not be able to spend the balance.
  let calls = 0;
  const c = client((() => {
    calls++;
    return Promise.resolve(
      new Response(
        JSON.stringify({
          getSearchEntity: {
            searchEntity: {
              currentPage: String(calls),
              nextPage: String(calls + 1),
              data: [{ companyName: `PAGE ${calls} SDN BHD` }],
            },
          },
        }),
        { status: 200 },
      ),
    );
  }) as typeof fetch);

  const out = await c.searchAll({ name: "MANY" }, { maxPages: 3 });
  assertEquals(calls, 3);
  assertEquals(out.hits.length, 3);
  assertEquals(out.exhausted, false);
});

Deno.test("a profile goes to the endpoint the entity type has", async () => {
  // Four types, four endpoints, and the LLP one takes the OLD number
  // where every other takes the new. Sending the wrong one is a charged
  // call that finds nothing.
  const seen: string[] = [];
  const bodies: string[] = [];
  const c = client(((url: string | URL | Request, init?: RequestInit) => {
    seen.push(new URL(url as string).pathname);
    bodies.push(String(init?.body ?? ""));
    return Promise.resolve(
      new Response(JSON.stringify({ getCompProfile: {}, getBizProfile: {}, getLlpCurrentProfile: {}, getParticularsOfAdtFirm: {} }), { status: 200 }),
    );
  }) as typeof fetch);

  await c.profileFor("company", { newRegNo: "199301012345" });
  await c.profileFor("business", { newRegNo: "SP0503123-L" });
  await c.profileFor("limited_liability_partnerships", {
    newRegNo: "201901030189",
    oldRegNo: "LLP0012345-LGN",
  });
  await c.profileFor("audit_firm", { newRegNo: "AF0301" });

  assertEquals(seen, [
    "/get-company-profile-document",
    "/get-bizprofile-document",
    "/get-llp-current-profile",
    "/get-auditfirm-particular",
  ]);
  // The LLP call sent the OLD number, not the new one.
  assertEquals(bodies[2].includes("LLP0012345-LGN"), true);
  assertEquals(bodies[2].includes("201901030189"), false);
  // And the audit firm went under its own key.
  assertEquals(bodies[3].includes("adtFirmNo"), true);
});

Deno.test("an unknown entity type is refused rather than guessed", async () => {
  const err = await assertRejects(
    () => client(respond({})).profileFor("cooperative", { newRegNo: "1" }),
    SsmApiError,
  );
  assertEquals(err.kind, "payload");
});

Deno.test("the words the app uses for a type are the words CIDP wants", () => {
  assertEquals(normalizeEntityType("Sdn Bhd"), "company");
  assertEquals(normalizeEntityType("PLT"), "limited_liability_partnerships");
  assertEquals(normalizeEntityType("Audit Firm"), "audit_firm");
  assertEquals(normalizeEntityType("Enterprise"), "business");
  // Not guessed. A type this does not know must reach `profileFor` as
  // unknown so the call is refused before it is paid for.
  assertEquals(normalizeEntityType("Cooperative"), "unknown");
});

Deno.test("a client with no key refuses to be built", () => {
  let threw = false;
  try {
    new SsmSearchClient({ apiKey: "", apiSecret: "s" });
  } catch {
    threw = true;
  }
  assertEquals(threw, true);
});
