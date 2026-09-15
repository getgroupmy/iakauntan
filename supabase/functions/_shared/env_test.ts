import { assertEquals, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import { requireEnv } from "./env.ts";

/**
 * Six lines, and the one decision in them.
 *
 * `requireEnv` exists for the case its own comment describes: a `!`
 * hands `undefined` to `createClient`, which fails several frames later
 * with a message about a malformed URL, and the person reading that log
 * cannot tell it from a network problem. Nineteen call sites depend on
 * the message naming the variable instead.
 *
 * The decision is `!value` rather than `value === undefined`: an empty
 * string is treated as missing. That is right -- a secret set to "" in
 * the dashboard is a secret that is not set, and it is the shape a
 * mis-pasted value takes -- and it is invisible, so it is pinned here.
 */

Deno.test("a variable that is set comes back", () => {
  Deno.env.set("IAKAUNTAN_TEST_VAR", "a-value");
  try {
    assertEquals(requireEnv("IAKAUNTAN_TEST_VAR"), "a-value");
  } finally {
    Deno.env.delete("IAKAUNTAN_TEST_VAR");
  }
});

Deno.test("a missing one throws, naming itself", () => {
  Deno.env.delete("IAKAUNTAN_ABSENT_VAR");
  const err = assertThrows(() => requireEnv("IAKAUNTAN_ABSENT_VAR"), Error);
  // The name is the entire point. Without it the log says only that
  // something was undefined, several frames from here.
  assertStringIncludes(err.message, "IAKAUNTAN_ABSENT_VAR");
  assertStringIncludes(err.message, "Missing required environment variable");
});

Deno.test("an empty variable counts as missing", () => {
  // A secret set to "" in the dashboard is a secret that is not set --
  // and it is what a mis-pasted value looks like. Returning "" instead
  // would send an empty service-role key to createClient and fail as a
  // 401 from PostgREST, which reads as a permissions problem.
  Deno.env.set("IAKAUNTAN_EMPTY_VAR", "");
  try {
    const err = assertThrows(() => requireEnv("IAKAUNTAN_EMPTY_VAR"), Error);
    assertStringIncludes(err.message, "IAKAUNTAN_EMPTY_VAR");
  } finally {
    Deno.env.delete("IAKAUNTAN_EMPTY_VAR");
  }
});

Deno.test("a variable whose value is falsy but real is not missing", () => {
  // The control for the test above. `!value` is deliberate about "" and
  // must not become a truthiness check over the value's MEANING: "0" and
  // "false" are ordinary settings and a `!` on a parsed value would
  // reject them.
  for (const value of ["0", "false", " "]) {
    Deno.env.set("IAKAUNTAN_FALSY_VAR", value);
    try {
      assertEquals(requireEnv("IAKAUNTAN_FALSY_VAR"), value);
    } finally {
      Deno.env.delete("IAKAUNTAN_FALSY_VAR");
    }
  }
});
