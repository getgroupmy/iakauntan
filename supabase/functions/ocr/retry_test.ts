import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  isTransient,
  ReaderRefusal,
  withOneRetry,
} from "./retry.ts";

/**
 * A 503 cost somebody a scan, and the fix is only as good as the line
 * it draws: retry what will be different a second later, and nothing
 * else.
 */

Deno.test("not now is retried", () => {
  // The four the vendors document, and every 5xx. 503 is the one from
  // the report -- the model at capacity.
  for (const status of [408, 409, 429, 500, 502, 503, 504, 529, 599]) {
    assertEquals(isTransient(status), true, `${status}`);
  }
});

Deno.test("and no is not", () => {
  // Each of these is a statement about THIS request and will be just as
  // true a second later. A 400 is a malformed schema -- which `0681`
  // caused once by leaving a field out of `required` -- and retrying it
  // spends a second to be told the same thing.
  for (const status of [200, 400, 401, 403, 404, 413, 422]) {
    assertEquals(isTransient(status), false, `${status}`);
  }
});

Deno.test("nothing answering at all is not transient", () => {
  // `0` is what a status reads as when there was no response. A caller
  // that never reached the vendor has a different problem from one that
  // was turned away, and treating them alike would retry a DNS failure
  // as though it were a busy model.
  assertEquals(isTransient(0), false);
});

Deno.test("a transient refusal is asked again, once", async () => {
  let calls = 0;
  const out = await withOneRetry(
    () => {
      calls++;
      if (calls === 1) throw new ReaderRefusal("busy", 503);
      return Promise.resolve("read");
    },
    { sleep: () => Promise.resolve() },
  );
  assertEquals(out, "read");
  assertEquals(calls, 2);
});

Deno.test("and only once", async () => {
  // ONE extra attempt, not a loop. Somebody is standing there holding a
  // receipt; four tries over twenty seconds is a spinner they have
  // already given up on.
  let calls = 0;
  await assertRejects(
    () =>
      withOneRetry(
        () => {
          calls++;
          throw new ReaderRefusal("busy", 503);
        },
        { sleep: () => Promise.resolve() },
      ),
    ReaderRefusal,
  );
  assertEquals(calls, 2);
});

Deno.test("a permanent refusal is not asked again", async () => {
  let calls = 0;
  await assertRejects(
    () =>
      withOneRetry(
        () => {
          calls++;
          throw new ReaderRefusal("that key is dead", 401);
        },
        { sleep: () => Promise.resolve() },
      ),
    ReaderRefusal,
  );
  assertEquals(calls, 1);
});

Deno.test("nor is anything that is not a refusal", async () => {
  // A file missing from storage, a body that was not JSON, a type
  // nothing reads. Ours or the document's, and asking again cannot
  // change it -- so these must not go round twice however transient
  // their wording looks.
  let calls = 0;
  await assertRejects(
    () =>
      withOneRetry(
        () => {
          calls++;
          throw new Error("The file is no longer in storage: not found");
        },
        { sleep: () => Promise.resolve() },
      ),
    Error,
  );
  assertEquals(calls, 1);
});

Deno.test("the first failure is handed back, so it can be kept", async () => {
  // A blip the person never saw is still a vendor having a bad
  // afternoon, and the scan row is the only place that would record it.
  const seen: ReaderRefusal[] = [];
  await withOneRetry(
    (() => {
      let n = 0;
      return () => {
        n++;
        if (n === 1) throw new ReaderRefusal("overloaded", 503);
        return Promise.resolve("read");
      };
    })(),
    { onRetry: (f) => seen.push(f), sleep: () => Promise.resolve() },
  );
  assertEquals(seen.length, 1);
  assertEquals(seen[0].status, 503);
  assertEquals(seen[0].message, "overloaded");
});

Deno.test("and nothing is handed back when nothing failed", async () => {
  const seen: ReaderRefusal[] = [];
  const out = await withOneRetry(
    () => Promise.resolve("read"),
    { onRetry: (f) => seen.push(f), sleep: () => Promise.resolve() },
  );
  assertEquals(out, "read");
  assertEquals(seen.length, 0);
});

Deno.test("it waits before asking again", async () => {
  // Asking again in the same millisecond is asking the same overloaded
  // model the same question. The pause is the point.
  const waited: number[] = [];
  let calls = 0;
  await withOneRetry(
    () => {
      calls++;
      if (calls === 1) throw new ReaderRefusal("busy", 503);
      return Promise.resolve("read");
    },
    {
      sleep: (ms) => {
        waited.push(ms);
        return Promise.resolve();
      },
    },
  );
  assertEquals(waited.length, 1);
  assertEquals(waited[0] > 0, true);
});
