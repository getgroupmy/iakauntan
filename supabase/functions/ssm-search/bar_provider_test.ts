import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { SsmError } from "./provider.ts";
import {
  BarDirectoryWeb,
  BAR_QUERY_CANDIDATES,
  DEFAULT_BAR_ROUTES,
  probeBar,
  readBarRows,
} from "./bar_provider.ts";

/**
 * Reading the Malaysian Bar's directory.
 *
 * ## What these tests can and cannot prove
 *
 * They prove the READER: given HTML of a particular shape, the right
 * rows come out, and given HTML of no recognised shape, nothing does.
 * That is worth having on its own, because the failure this guards
 * against is the quiet one — a heading read as a solicitor, or a
 * postcode written into a contact's registration number.
 *
 * They do NOT prove the shape is right. Nobody has seen this site's
 * markup from a machine that could also run this code; the network the
 * repository is edited on refuses the host with a 403 from its own
 * egress proxy. The fixtures below are what a directory of this kind
 * plausibly emits, not what this one does.
 *
 * `0589` was in exactly this position against ssmsearch.com and its
 * header records how it ended: "the paths this shipped with were a
 * guess and the first live sign-in proved them wrong". So `probeBar`
 * exists, and until somebody has pressed it a working search here is
 * luck rather than evidence.
 */

const tableHtml = `
<table class="results">
  <tr><th>Name</th><th>Firm</th><th>State</th></tr>
  <tr>
    <td>LEE MEI LING</td>
    <td>Lee &amp; Partners</td>
    <td>Selangor</td>
  </tr>
  <tr>
    <td>AHMAD BIN ISMAIL</td>
    <td>Ahmad Chambers</td>
    <td>WP Kuala Lumpur</td>
  </tr>
</table>`;

const cardHtml = `
<div class="search-result listing">
  <div>TAN AH KOW</div>
  <div>Enrolment No: A/1234</div>
  <div>Pulau Pinang</div>
</div>
<div class="search-result listing">
  <div>ABC &amp; CO</div>
  <div>Johor</div>
</div>`;

function responding(body: string, status = 200): typeof fetch {
  return () =>
    Promise.resolve(
      new Response(body, {
        status,
        headers: { "content-type": "text/html" },
      }),
    );
}

Deno.test("a table of results reads as rows", () => {
  const rows = readBarRows(tableHtml);
  assertEquals(rows.length, 2);
  assertEquals(rows[0].name, "LEE MEI LING");
  assertEquals(rows[1].name, "AHMAD BIN ISMAIL");
});

Deno.test("the heading row is not a person", () => {
  // The quiet failure this guards against. "Name" filed as a solicitor
  // on a client record looks exactly like a real row.
  const rows = readBarRows(tableHtml);
  assertEquals(rows.some((r) => r.name === "Name"), false);
});

Deno.test("entities are read as entities and people as people", () => {
  // Not a kind of business — what the Bar registers is a person or a
  // firm of them, and saying which beats leaving it null.
  const rows = readBarRows(tableHtml);
  assertEquals(rows[0].entity_type, "Advocate & Solicitor");

  const cards = readBarRows(cardHtml);
  assertEquals(cards[1].name, "ABC & CO");
  assertEquals(cards[1].entity_type, "Law Firm");
});

Deno.test("cards read when there is no table", () => {
  const rows = readBarRows(cardHtml);
  assertEquals(rows.length, 2);
  assertEquals(rows[0].name, "TAN AH KOW");
});

Deno.test("a number is taken only where the row names one", () => {
  // The directory shows telephone numbers and postcodes too, and a
  // postcode written into a contact's registration number is worse
  // than an empty field.
  const cards = readBarRows(cardHtml);
  assertEquals(cards[0].reg_no, "A/1234");

  const table = readBarRows(tableHtml);
  assertEquals(table[0].reg_no, null);
});

Deno.test("a postcode in the row is not taken for a number", () => {
  const rows = readBarRows(`
    <table><tr><td>SITI BINTI YUSOF</td><td>50450 Kuala Lumpur</td></tr></table>
  `);
  assertEquals(rows.length, 1);
  assertEquals(rows[0].reg_no, null);
});

Deno.test("markup this does not recognise yields nothing, not a guess", () => {
  // The whole reason there is no clever fallback. A name recognised
  // wrongly becomes a solicitor on a client record; an empty result
  // reads as "not found", which is recoverable.
  assertEquals(readBarRows("<p>Just a moment…</p>").length, 0);
  assertEquals(readBarRows("").length, 0);
  assertEquals(readBarRows("<html><body><h1>Not found</h1></body></html>").length, 0);
});

Deno.test("entities carry no handles the Bar does not issue", () => {
  // `ssm_id` and `slug` belong to ssmsearch.com. Null rather than
  // invented.
  const rows = readBarRows(tableHtml);
  assertEquals(rows[0].ssm_id, null);
  assertEquals(rows[0].slug, null);
  assertEquals(rows[0].reg_no_old, null);
});

Deno.test("the search sends the configured parameter, and one page", () => {
  let asked = "";
  const bar = new BarDirectoryWeb(
    null,
    { ...DEFAULT_BAR_ROUTES, queryParam: "name" },
    ((u: string | URL | Request) => {
      asked = String(u);
      return Promise.resolve(new Response(tableHtml, { status: 200 }));
    }) as typeof fetch,
  );
  return bar.search("LEE", null, 1, 20).then((out) => {
    assertEquals(asked.includes("name=LEE"), true);
    // Page 1 carries no page parameter: a directory that numbers from
    // one does not need telling.
    assertEquals(asked.includes("page="), false);
    assertEquals(out.items.length, 2);
  });
});

Deno.test("a refusal is reported as a refusal, not as no results", async () => {
  // Their server saying no is not the same as nobody by that name, and
  // the answer is to stop for a while rather than retype it.
  const bar = new BarDirectoryWeb(null, DEFAULT_BAR_ROUTES, responding("", 429));
  const err = await assertRejects(
    () => bar.search("LEE", null, 1, 20),
    SsmError,
  );
  assertEquals(err.code, "SSM_RATE_LIMITED");
});

Deno.test("and so is being blocked outright", async () => {
  const bar = new BarDirectoryWeb(null, DEFAULT_BAR_ROUTES, responding("", 403));
  const err = await assertRejects(
    () => bar.search("LEE", null, 1, 20),
    SsmError,
  );
  assertEquals(err.code, "SSM_RATE_LIMITED");
});

Deno.test("a server error is not a rate limit", async () => {
  // The control for the two above: three different answers must not
  // collapse into one message, or an operator reading the console
  // learns nothing from it.
  const bar = new BarDirectoryWeb(null, DEFAULT_BAR_ROUTES, responding("", 500));
  const err = await assertRejects(
    () => bar.search("LEE", null, 1, 20),
    SsmError,
  );
  assertEquals(err.code, "SSM_SEARCH_FAILED");
});

Deno.test("an unreachable host says so", async () => {
  const bar = new BarDirectoryWeb(
    null,
    DEFAULT_BAR_ROUTES,
    (() => Promise.reject(new TypeError("dns"))) as typeof fetch,
  );
  const err = await assertRejects(
    () => bar.search("LEE", null, 1, 20),
    SsmError,
  );
  assertEquals(err.code, "SSM_UNREACHABLE");
});

Deno.test("the routes are overridable, which is the point of them", () => {
  // The shape is a guess, so an operator who can see the real thing
  // corrects it with a secret rather than a deploy. 0589's lesson.
  let asked = "";
  const bar = new BarDirectoryWeb(
    null,
    { root: "https://example.invalid/dir", searchPath: "find", queryParam: "q" },
    ((u: string | URL | Request) => {
      asked = String(u);
      return Promise.resolve(new Response(tableHtml, { status: 200 }));
    }) as typeof fetch,
  );
  return bar.search("TAN", null, 2, 20).then(() => {
    assertEquals(asked.startsWith("https://example.invalid/dir/find?"), true);
    assertEquals(asked.includes("q=TAN"), true);
    assertEquals(asked.includes("page=2"), true);
  });
});

Deno.test("the probe reports which parameter produced rows", async () => {
  // The whole answer to "the shape is a guess": one press turns every
  // inference in that file into a fact.
  const hits = await probeBar(
    ((u: string | URL | Request) => {
      const url = String(u);
      // Only `keyword` returns anything, which is what the probe is
      // for finding out.
      return Promise.resolve(
        new Response(url.includes("keyword=") ? tableHtml : "<p>nothing</p>", {
          status: 200,
        }),
      );
    }) as typeof fetch,
  );

  assertEquals(hits.length, BAR_QUERY_CANDIDATES.length);
  const winner = hits.filter((h) => h.rows > 0);
  assertEquals(winner.length, 1);
  assertEquals(winner[0].param, "keyword");
  assertEquals(winner[0].rows, 2);
});

Deno.test("a probe against a dead host reports it rather than throwing", async () => {
  const hits = await probeBar(
    (() => Promise.reject(new TypeError("dns"))) as typeof fetch,
    DEFAULT_BAR_ROUTES,
    "LEE",
    ["name"],
  );
  assertEquals(hits.length, 1);
  assertEquals(hits[0].status, 0);
  assertEquals(hits[0].rows, 0);
});
