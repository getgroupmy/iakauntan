import { assertEquals } from "jsr:@std/assert@1";
import { SsmSearchClient } from "../_shared/ssm-search-client.ts";
import { SsmError } from "./provider.ts";
import {
  asSsmError,
  chosenProvider,
  CIDP_ENTITY_TYPE,
  ENTITY_TYPE_ID,
  SsmSearchApi,
  toSsmEntity,
} from "./api_provider.ts";
import { SsmApiError } from "../_shared/ssm-search-client.ts";

/**
 * The seam between the interim lookup and SSM's own API.
 *
 * `provider.ts` said what this had to be: "a second class implementing
 * the same two methods". The risk is not that the new provider fails —
 * a failure is loud. It is that it succeeds while meaning something
 * slightly different: a registration number under the wrong key, an
 * entity type that comes back null, a page that claims to be the last
 * when it is not. Every one of those shows a plausible company with
 * somebody else's number on the e-Invoice.
 *
 * `search()` is driven against an injected `fetch`, because reaching
 * SSM is a charged call.
 */

function apiWith(pages: unknown[]): SsmSearchApi {
  let i = 0;
  const client = new SsmSearchClient({
    apiKey: "k",
    apiSecret: "s",
    baseUrl: "https://cidp.example.invalid/",
    fetch: () =>
      Promise.resolve(
        new Response(JSON.stringify(pages[Math.min(i++, pages.length - 1)]), {
          status: 200,
        }),
      ),
  });
  return new SsmSearchApi(null, client);
}

function page(
  data: Record<string, string>[],
  currentPage = "1",
  nextPage = "",
) {
  return { getSearchEntity: { searchEntity: { currentPage, nextPage, data } } };
}

const maju = {
  companyName: "MAJU SDN. BHD.",
  companyNo: "199301012345",
  oldCompanyNo: "123456-X",
  entityType: "company",
};

Deno.test("the switch defaults to the interim provider", () => {
  // The subscription is under SSM's review and there is no key. A typo
  // in the dashboard secret must not switch a working lookup off.
  assertEquals(chosenProvider(undefined), "web");
  assertEquals(chosenProvider(""), "web");
  assertEquals(chosenProvider("API "), "api");
  assertEquals(chosenProvider("apy"), "web");
  assertEquals(chosenProvider("WEB"), "web");
});

Deno.test("a hit becomes the entity the rest of this already reads", async () => {
  const out = await apiWith([page([maju])]).search("MAJU", null, 1, 20);

  assertEquals(out.items.length, 1);
  const e = out.items[0];
  assertEquals(e.name, "MAJU SDN. BHD.");
  // The four fields a search result saves, on the columns
  // `set_contact_ssm_entity` has always written.
  assertEquals(e.reg_no, "199301012345");
  assertEquals(e.reg_no_old, "123456-X");
  assertEquals(e.entity_type_id, 1);
  assertEquals(e.entity_type, "Company");
  // CIDP has neither. Null rather than an invented value.
  assertEquals(e.ssm_id, null);
  assertEquals(e.slug, null);
});

Deno.test("a blank number is null, not an empty string", () => {
  // `''` and "never told us" are different facts, and
  // `set_contact_ssm_entity` overwrites with what it is given.
  const e = toSsmEntity({
    name: "ONLY A NAME SDN BHD",
    newRegNo: "",
    oldRegNo: "",
    entityType: "",
  });
  assertEquals(e.reg_no, null);
  assertEquals(e.reg_no_old, null);
  assertEquals(e.entity_type_id, null);
  assertEquals(e.entity_type, null);
});

Deno.test("a type CIDP adds arrives as itself", () => {
  // Not null. The register is somebody else's list, and a fifth kind
  // should reach the screen as its own word rather than as nothing.
  const e = toSsmEntity({
    name: "SOMETHING NEW",
    newRegNo: "1",
    oldRegNo: "",
    entityType: "cooperative",
  });
  assertEquals(e.entity_type_id, null);
  assertEquals(e.entity_type, "cooperative");
});

Deno.test("the four types map both ways and agree", () => {
  // The app's filter is built on the numbering; CIDP takes words. A
  // filter chosen under one provider has to mean the same under the
  // other.
  for (const [id, word] of Object.entries(CIDP_ENTITY_TYPE)) {
    assertEquals(ENTITY_TYPE_ID[word], Number(id));
  }
  assertEquals(Object.keys(CIDP_ENTITY_TYPE).length, 4);
});

Deno.test("a filtered search sends the word for the number", async () => {
  let sent = "";
  const client = new SsmSearchClient({
    apiKey: "k",
    apiSecret: "s",
    baseUrl: "https://cidp.example.invalid/",
    fetch: ((_u: string | URL | Request, init?: RequestInit) => {
      sent = String(init?.body ?? "");
      return Promise.resolve(
        new Response(JSON.stringify(page([maju])), { status: 200 }),
      );
    }) as typeof fetch,
  });
  // 25 is the Limited Liability Partnership in `ENTITY_TYPES`.
  await new SsmSearchApi(null, client).search("ANY", 25, 1, 20);

  assertEquals(sent.includes("limited_liability_partnerships"), true);
});

Deno.test("no filter sends no entity type at all", async () => {
  let sent = "";
  const client = new SsmSearchClient({
    apiKey: "k",
    apiSecret: "s",
    baseUrl: "https://cidp.example.invalid/",
    fetch: ((_u: string | URL | Request, init?: RequestInit) => {
      sent = String(init?.body ?? "");
      return Promise.resolve(
        new Response(JSON.stringify(page([maju])), { status: 200 }),
      );
    }) as typeof fetch,
  });
  await new SsmSearchApi(null, client).search("ANY", null, 1, 20);

  // Not `"entityType":null` and not an empty string: either would be a
  // filter for a type that does not exist.
  assertEquals(sent.includes("entityType"), false);
});

Deno.test("another page to come is a total the app reads as more", async () => {
  // The app computes `hasMore` as `page * per_page < total`. CIDP never
  // says how many matches there are, only whether there is another
  // page, so `total` says "at least one more" and nothing else.
  const out = await apiWith([page([maju, maju], "1", "2")])
    .search("MAJU", null, 1, 20);

  assertEquals(out.per_page, 2);
  assertEquals(out.page * out.per_page < out.total, true);
});

Deno.test("and the last page is the last page", async () => {
  const out = await apiWith([page([maju, maju], "1", "")])
    .search("MAJU", null, 1, 20);

  assertEquals(out.total, 2);
  assertEquals(out.page * out.per_page < out.total, false);
});

Deno.test("a next page that repeats the current one is the last page", async () => {
  // CIDP echoes `currentPage` rather than sending an empty `nextPage`
  // on the last page. Read literally, that is an endless "Load more"
  // against a charged API.
  const out = await apiWith([page([maju], "3", "3")]).search("MAJU", null, 3, 20);

  assertEquals(out.page * out.per_page < out.total, false);
});

Deno.test("an empty page is the end, whatever nextPage says", async () => {
  const out = await apiWith([page([], "2", "3")]).search("NOTHING", null, 2, 20);

  assertEquals(out.items.length, 0);
  assertEquals(out.page * out.per_page < out.total, false);
});

Deno.test("a refused key reads as a login failure, not as the user's", () => {
  // A 401 from SSM is OUR secret being wrong. Forwarded as an
  // authentication failure it would send somebody to the sign-in screen
  // over a credential they never typed.
  const e = asSsmError(
    new SsmApiError({ kind: "auth", path: "/get-search-entity", message: "bad key" }),
  );
  assertEquals(e instanceof SsmError, true);
  assertEquals(e.code, "SSM_LOGIN_FAILED");
  // The message names the two secrets, because the person who can act
  // on it is an operator and not the user who searched.
  assertEquals(e.message.includes("SSMSEARCH_API_KEY"), true);
});

Deno.test("the failure codes are ones the app already has words for", () => {
  // `ssm_repository.dart` switches on these. A new code would reach a
  // user as a raw upstream message.
  assertEquals(
    asSsmError(new SsmApiError({ kind: "network", path: "/get-search-entity", message: "x" })).code,
    "SSM_UNREACHABLE",
  );
  assertEquals(
    asSsmError(new SsmApiError({ kind: "route", path: "/get-search-entity", message: "x" })).code,
    "SSM_UNREACHABLE",
  );
  assertEquals(
    asSsmError(new SsmApiError({ kind: "upstream", path: "/get-search-entity", message: "no record" })).code,
    "SSM_SEARCH_FAILED",
  );
});

Deno.test("something that is not an SSM failure is not dressed as one", () => {
  const e = asSsmError(new TypeError("undefined is not a function"));
  assertEquals(e.code, "INTERNAL");
  assertEquals(e.status, 500);
});

Deno.test("the provider names itself, and not as the other one", async () => {
  // The cache is keyed on this name. Two providers under one name is an
  // answer from ssmsearch.com served as an answer from SSM's own
  // register.
  const api = apiWith([page([maju])]);
  assertEquals(api.name, "ssm_api");
  await api.search("MAJU", null, 1, 20);
});
