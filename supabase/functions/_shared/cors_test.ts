import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { corsFor, fail, failUnexpected, json, logFailure } from "./cors.ts";

/**
 * The preflight, and what a failure is allowed to say.
 *
 * Two things here have already cost a working day each.
 *
 * `ssm-search` shipped with its own three-line CORS constant allowing
 * `authorization, content-type`. supabase-js sends `x-client-info` on
 * every call and `apikey` when the client carries one, so the browser's
 * preflight was refused BEFORE THE FUNCTION RAN -- no status, no body,
 * nothing in the function's log, and on screen only "ClientException:
 * Load failed". `check_edge_cors.py` now refuses a function that writes
 * its own headers; this asserts the shared list those functions get is
 * the right one.
 *
 * And an unexpected error carries whatever the thing that threw it was
 * holding: a Postgres message naming a column, a provider URL, a
 * fragment of somebody's invoice. None of that belongs in a response
 * body, and the only way to know it is not there is to throw one that
 * says so and look.
 *
 * `serveFunction` itself is not tested here -- it calls `Deno.serve` and
 * binds a port. That every function goes THROUGH it is what
 * `check_edge_cors.py` asserts, statically, over the whole directory.
 */

const HEADERS = "Access-Control-Allow-Headers";

Deno.test("the preflight allows the headers supabase-js actually sends", () => {
  const allowed = corsFor()[HEADERS];
  // The two that were missing. Without them the browser refuses the
  // request before the function is reached, which reads on screen as
  // the network being down.
  assertStringIncludes(allowed, "x-client-info");
  assertStringIncludes(allowed, "apikey");
  // And the two nobody has ever got wrong, so the list cannot be
  // narrowed to the pair above by somebody tidying.
  assertStringIncludes(allowed, "authorization");
  assertStringIncludes(allowed, "content-type");
});

Deno.test("and the header the scheduled workflows send", () => {
  // `x-scheduler-secret` is how the cron workflows identify themselves.
  // They send no Origin and enforce nothing, but the header still has
  // to be allowed or a browser-side call on the same function fails.
  assertStringIncludes(corsFor()[HEADERS], "x-scheduler-secret");
});

Deno.test("POST, GET and OPTIONS, because the preflight is an OPTIONS", () => {
  const methods = corsFor()["Access-Control-Allow-Methods"];
  for (const m of ["POST", "GET", "OPTIONS"]) {
    assertStringIncludes(methods, m);
  }
});

Deno.test("Vary: Origin is always sent", () => {
  // Without it a cache in front of these functions can hand one
  // origin's Access-Control-Allow-Origin to another, which is a CORS
  // failure that only appears under load and never in testing.
  assertEquals(corsFor().Vary, "Origin");
  assertEquals(
    corsFor(new Request("https://x.test", { headers: { Origin: "https://a" } }))
      .Vary,
    "Origin",
  );
});

Deno.test("with no allowlist configured the origin is *", () => {
  // Which is where this started and what the running deployment relies
  // on. A change that made the default restrictive would take every
  // browser call down at once.
  assertEquals(corsFor()["Access-Control-Allow-Origin"], "*");
});

Deno.test("an allowlist admits what is on it and says nothing otherwise", async () => {
  // ALLOWED is read at module load, so this needs its own instance of
  // the module. The query string is what makes Deno fetch a second
  // one rather than hand back the cached first.
  Deno.env.set("ALLOWED_ORIGINS", "https://iakauntan.com, https://*.iakauntan.com");
  const mod = await import("./cors.ts?allowlist=1");
  const at = (origin: string) =>
    mod.corsFor(
      new Request("https://x.test", { headers: { Origin: origin } }),
    )["Access-Control-Allow-Origin"];

  assertEquals(at("https://iakauntan.com"), "https://iakauntan.com");
  // One `*` stands for exactly one DNS label, which is what lets a
  // company's own subdomain work -- 0327 sells those, and an
  // exact-match list cannot name a domain that does not exist yet.
  assertEquals(at("https://sinar.iakauntan.com"), "https://sinar.iakauntan.com");

  // NO HEADER, not a wrong one. Echoing an origin that is not on the
  // list is the mistake the allowlist exists to avoid, and a browser
  // refuses a response with no Allow-Origin -- which is the intended
  // outcome.
  assertEquals(at("https://evil.test"), undefined);
  assertEquals(at(""), undefined);

  // The rest of the headers are still there, so a refused origin gets
  // a well-formed response that it simply may not read.
  const refused = mod.corsFor(
    new Request("https://x.test", { headers: { Origin: "https://evil.test" } }),
  );
  assertStringIncludes(refused[HEADERS], "x-client-info");
  assertEquals(refused.Vary, "Origin");

  Deno.env.delete("ALLOWED_ORIGINS");
});

Deno.test("json carries the CORS headers and the content type", async () => {
  const res = json({ ok: true });
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("Content-Type"), "application/json");
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*");
  assertEquals(await res.json(), { ok: true });
});

Deno.test("fail says what the caller is meant to act on", async () => {
  const res = fail("Line 3 has no classification code", 422, { line: 3 });
  assertEquals(res.status, 422);
  const body = await res.json();
  assertEquals(body.error, "Line 3 has no classification code");
  // `extra` is caller-facing detail, deliberately -- which invoice
  // line LHDN rejected is the whole point of the message.
  assertEquals(body.details, { line: 3 });
});

Deno.test("fail with no detail says null rather than leaving it out", async () => {
  const body = await fail("nope").json();
  assertEquals(body.details, null);
});

Deno.test("an unexpected error tells the caller nothing it was holding", async () => {
  // The error message here is the shape of a real one: a Postgres
  // error naming a column and a constraint, which is exactly what
  // leaks a schema to somebody who should not have it.
  const err = new Error(
    'duplicate key value violates unique constraint ' +
      '"contacts_org_id_tin_key" DETAIL: Key (tin)=(C1234567890) exists.',
  );
  // Quietened, because the point of this function is that it DOES log
  // the real error -- asserted in the next test -- and a passing suite
  // should not print somebody's constraint name to prove it.
  const real = console.error;
  console.error = () => {};
  let res: Response;
  try {
    res = failUnexpected(err, "test-event");
  } finally {
    console.error = real;
  }

  assertEquals(res.status, 500);
  const text = await res.text();
  assert(!text.includes("contacts_org_id_tin_key"), "leaked the constraint");
  assert(!text.includes("C1234567890"), "leaked the value");

  const body = JSON.parse(text);
  assertStringIncludes(body.error, "Something went wrong at our end");
  // The reference is the whole mechanism: it is useless to an attacker
  // and it is how the person debugging finds the real error in the log.
  assert(typeof body.ref === "string" && body.ref.length > 0);
});

Deno.test("and the reference in the body is the one in the log", () => {
  const lines: string[] = [];
  const real = console.error;
  console.error = (...args: unknown[]) => lines.push(String(args[0]));
  try {
    const ref = logFailure(new TypeError("x is not a function"), "an-event", {
      hasKey: false,
    });
    assertEquals(lines.length, 1);
    const logged = JSON.parse(lines[0]);
    assertEquals(logged.ref, ref);
    assertEquals(logged.event, "an-event");
    // The type and the message, never the object -- whatever threw it
    // may be carrying a request body on it.
    assertEquals(logged.kind, "TypeError");
    assertEquals(logged.message, "x is not a function");
    // Context keeps its type: a boolean answers "was a key
    // configured" more honestly than the string "yes".
    assertEquals(logged.hasKey, false);
  } finally {
    console.error = real;
  }
});

Deno.test("something thrown that is not an Error still logs usably", () => {
  const lines: string[] = [];
  const real = console.error;
  console.error = (...args: unknown[]) => lines.push(String(args[0]));
  try {
    logFailure("just a string", "an-event");
    const logged = JSON.parse(lines[0]);
    assertEquals(logged.kind, "string");
    assertEquals(logged.message, "just a string");
  } finally {
    console.error = real;
  }
});
