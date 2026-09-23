import { assertEquals } from "jsr:@std/assert@1.0.19";
import { normalise, probeRoutes } from "./provider.ts";

/**
 * Reading ssmsearch.com's answer.
 *
 * The rest of this function is network and database, and neither
 * belongs in a unit test. `normalise` is the part that is pure and the
 * part that decides what a person is shown to pick from — which, when
 * they pick it, becomes a registration number on an e-Invoice. Getting
 * it wrong is silent: a row read badly shows a plausible company with
 * somebody else's number.
 *
 * Their field names are read in several spellings on purpose, because
 * this is not a documented API and the shape is what their own
 * frontend happens to send today.
 */

Deno.test("reads a result the way their site sends it", () => {
  const out = normalise({
    data: [{
      id: 4242,
      name: "TM Technology Services Sdn Bhd",
      slug: "tm-technology-services",
      regNo: "201901030189",
      oldRegNo: "571389-H",
      typeId: 1,
    }],
    total: 1,
  }, 1, 20);

  assertEquals(out.items.length, 1);
  assertEquals(out.items[0].name, "TM Technology Services Sdn Bhd");
  assertEquals(out.items[0].reg_no, "201901030189");
  assertEquals(out.items[0].reg_no_old, "571389-H");
  assertEquals(out.items[0].entity_type_id, 1);
  // Filled from the id when they send no title, so the picker can say
  // "Company" rather than "1".
  assertEquals(out.items[0].entity_type, "Company");
  assertEquals(out.total, 1);
});

Deno.test("and the way api.ssmsearch.com actually sends it", () => {
  // The names their own search page reads off a row: snake_case, and
  // the kind of entity as a word under `entity`. A live search on
  // 14 Sep 2026 rendered through exactly these.
  const out = normalise({
    data: [{
      name: "KABEER HOLDINGS SDN. BHD.",
      reg_no: "201901030189",
      reg_no_old: "1339519-K",
      entity: "Company",
    }],
    total: 1,
    is_more_than_limit: false,
    is_not_logged_in: false,
  }, 1, 20);

  assertEquals(out.items[0].reg_no, "201901030189");
  assertEquals(out.items[0].reg_no_old, "1339519-K");
  assertEquals(out.items[0].entity_type, "Company");
});

Deno.test("and under the other names they use for the same fields", () => {
  const out = normalise({
    items: [{
      companyId: "7",
      companyName: "Kedai Runcit Sejahtera",
      registrationNo: "202301001234",
      entityTypeId: 2,
      typeName: "Business",
    }],
  }, 1, 20);

  assertEquals(out.items[0].ssm_id, 7);
  assertEquals(out.items[0].name, "Kedai Runcit Sejahtera");
  assertEquals(out.items[0].reg_no, "202301001234");
  assertEquals(out.items[0].entity_type, "Business");
});

Deno.test("drops a row with no name rather than offering a blank one", () => {
  // A blank line in a picker is a thing somebody can select, and what
  // they would be selecting is a registration number with no company
  // attached to it.
  const out = normalise({
    data: [
      { id: 1, regNo: "201901030189" },
      { id: 2, name: "   ", regNo: "202301001234" },
      { id: 3, name: "Real Sdn Bhd" },
    ],
  }, 1, 20);

  assertEquals(out.items.length, 1);
  assertEquals(out.items[0].name, "Real Sdn Bhd");
});

Deno.test("survives an answer with nothing in it", () => {
  // Their endpoint answering `{}` must be "no matches", not a crash on
  // somebody's screen.
  const out = normalise({}, 1, 20);
  assertEquals(out.items, []);
  assertEquals(out.total, 0);
  assertEquals(out.page, 1);
  assertEquals(out.per_page, 20);
});

Deno.test("counts what it found when they send no total", () => {
  const out = normalise({
    data: [{ name: "One Sdn Bhd" }, { name: "Two Sdn Bhd" }],
  }, 2, 10);
  assertEquals(out.total, 2);
  assertEquals(out.page, 2);
});

Deno.test("takes a number as a name rather than losing the row", () => {
  // A business registered under digits alone is unusual and real, and
  // a reader that insisted on a string would drop it.
  const out = normalise({ data: [{ name: 12345, regNo: "202301001234" }] }, 1, 20);
  assertEquals(out.items[0].name, "12345");
});


/**
 * Finding the endpoints.
 *
 * `probeRoutes` exists because the paths this feature shipped with were
 * read off a package rather than off a live browser, and the first real
 * sign-in answered "Page not found: /api/user/login" in ssmsearch.com's
 * own words. The machine this repository is edited on cannot reach
 * ssmsearch.com at all, so the only thing that can find the real path
 * is the function itself.
 *
 * Two things about it are worth asserting, and neither needs a network.
 */
Deno.test("a probe rules out 404 and keeps everything else", async () => {
  const seen: Array<{ url: string; method: string; body: string | null }> = [];
  const fake = ((url: string | URL, init?: RequestInit) => {
    const u = String(url);
    seen.push({
      url: u,
      method: init?.method ?? "GET",
      body: (init?.body as string) ?? null,
    });
    // Their 404 shape, and a validation complaint from the one route
    // that is real.
    if (u.includes("/auth/login")) {
      return Promise.resolve(
        new Response(JSON.stringify({ message: "The email field is required." }), {
          status: 422,
        }),
      );
    }
    return Promise.resolve(
      new Response(JSON.stringify({ message: `Page not found: ${u}` }), {
        status: 404,
      }),
    );
  }) as unknown as typeof fetch;

  const found = await probeRoutes(
    fake,
    "https://ssmsearch.com/api/",
    ["/user/login", "/auth/login"],
    ["/company/search"],
  );

  // The whole point: one path is a route and the others are not.
  assertEquals(found.login.map((h) => h.exists), [false, true]);
  assertEquals(found.login[1].path, "/auth/login");
  assertEquals(found.login[1].status, 422);
  assertEquals(found.login[1].said, "The email field is required.");

  // A trailing slash on the root must not produce `//auth/login`, which
  // is a different path and would be answered 404 by a server that has
  // the route.
  assertEquals(seen[0].url, "https://ssmsearch.com/api/user/login");
  assertEquals(seen[2].url, "https://ssmsearch.com/api/company/search");
  // Their search is a POST, so the probe asks it the way their site does.
  assertEquals(seen[2].method, "POST");
});

Deno.test("a probe sends no credentials", async () => {
  const bodies: Array<string | null> = [];
  const fake = ((_url: string | URL, init?: RequestInit) => {
    bodies.push((init?.body as string) ?? null);
    return Promise.resolve(new Response("{}", { status: 404 }));
  }) as unknown as typeof fetch;

  await probeRoutes(fake, "https://ssmsearch.com/api", ["/a", "/b"], ["/c"]);

  // The assertion this test exists for. Distinguishing a route from a
  // 404 needs no password, and spraying a working credential across a
  // third party's URL space to learn something an empty body answers
  // is not a trade worth making.
  assertEquals(bodies, ["{}", "{}", "{}"]);
});
