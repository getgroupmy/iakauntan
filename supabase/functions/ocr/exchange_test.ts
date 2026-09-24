import {
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "jsr:@std/assert@1.0.19";
import { clip, Exchange, MAX_BODY, record, safeEndpoint } from "./exchange.ts";

/**
 * The console asked for the reader's reply in raw. The one thing that
 * must never reach it is a key, and the one thing that must always
 * reach the CALLER is the body it was going to read anyway -- a log
 * that consumes the response it was watching would break every scan.
 */

Deno.test("the query string is never kept", () => {
  // Gemini's key travels in `?key=`. This is the assertion this file
  // exists for.
  assertEquals(
    safeEndpoint(
      "https://generativelanguage.googleapis.com/v1beta/models/x:gen?key=AIzaSECRET",
    ),
    "https://generativelanguage.googleapis.com/v1beta/models/x:gen",
  );
});

Deno.test("nor is a credential in the authority", () => {
  assertEquals(
    safeEndpoint("https://user:hunter2@example.test/v1/read"),
    "https://example.test/v1/read",
  );
});

Deno.test("something that is not a url is not passed through", () => {
  // An endpoint this cannot parse is one it cannot promise to have
  // cleaned, so it keeps none of it.
  assertEquals(safeEndpoint("not a url at all ?key=SECRET"), "");
});

Deno.test("a short body is kept whole", () => {
  assertEquals(clip("{\"error\":\"nope\"}"), {
    body: "{\"error\":\"nope\"}",
    truncated: false,
  });
});

Deno.test("and a long one is cut, and says so", () => {
  const long = "x".repeat(MAX_BODY + 500);
  const out = clip(long);
  assertEquals(out.body.length, MAX_BODY);
  assertEquals(out.truncated, true);
});

Deno.test("the reply is recorded and still readable by the caller", async () => {
  const rec: Exchange[] = [];
  const response = await record(
    rec,
    "https://api.example.test/v1/messages?key=SECRET",
    { method: "POST" },
    () =>
      Promise.resolve(
        new Response('{"content":[{"type":"text","text":"99 Speedmart"}]}', {
          status: 200,
        }),
      ),
  );

  // The caller's `.json()` still works. A body is a stream and can be
  // read once, so this is the whole reason the recording happens
  // inside `record` rather than beside each `response.json()`.
  const body = await response.json();
  assertEquals(body.content[0].text, "99 Speedmart");

  assertEquals(rec.length, 1);
  assertEquals(rec[0].status, 200);
  assertEquals(rec[0].ok, true);
  assertEquals(rec[0].endpoint, "https://api.example.test/v1/messages");
  assertStringIncludes(rec[0].body, "99 Speedmart");
});

Deno.test("a refusal is recorded with its body", async () => {
  const rec: Exchange[] = [];
  const response = await record(
    rec,
    "https://api.example.test/v1/messages",
    {},
    () =>
      Promise.resolve(
        new Response('{"error":{"message":"high demand"}}', { status: 503 }),
      ),
  );

  assertEquals(response.status, 503);
  assertEquals(response.ok, false);
  assertEquals(rec[0].status, 503);
  assertEquals(rec[0].ok, false);
  assertStringIncludes(rec[0].body, "high demand");
});

Deno.test("nothing answering at all is a record too, at status 0", async () => {
  const rec: Exchange[] = [];
  await assertRejects(
    () =>
      record(rec, "https://api.example.test/v1/messages", {}, () => {
        throw new TypeError("error sending request");
      }),
    TypeError,
  );

  // "Nothing answered" is a different fault from "answered no", and
  // the console could not tell them apart before this.
  assertEquals(rec.length, 1);
  assertEquals(rec[0].status, 0);
  assertEquals(rec[0].ok, false);
  assertStringIncludes(rec[0].body, "error sending request");
});

Deno.test("an answer with no body is not turned into a crash", async () => {
  // Constructing a 204 with a body throws, and a throw in here would
  // be the logging costing a scan it was only watching.
  const rec: Exchange[] = [];
  const response = await record(
    rec,
    "https://api.example.test/v1/messages",
    {},
    () => Promise.resolve(new Response(null, { status: 204 })),
  );
  assertEquals(response.status, 204);
  assertEquals(rec[0].status, 204);
  assertEquals(rec[0].body, "");
});

Deno.test("every call is kept, in the order they happened", async () => {
  // A retry and a fallback are two more calls on the same scan, and
  // which one answered what is the question somebody is troubleshooting.
  const rec: Exchange[] = [];
  const codes = [503, 200];
  for (const status of codes) {
    await record(
      rec,
      `https://api.example.test/${status}`,
      {},
      () => Promise.resolve(new Response(`{"n":${status}}`, { status })),
    );
  }
  assertEquals(rec.map((e) => e.status), [503, 200]);
  assertEquals(rec[1].endpoint, "https://api.example.test/200");
});
