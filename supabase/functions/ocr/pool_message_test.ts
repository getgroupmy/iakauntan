import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { poolProblem } from "./pool.ts";

// A pool with nothing to give looks the same from the scan's side —
// no key, no scan — and is three different situations, two of which
// fix themselves and one of which does not.
//
// The message is the only thing anybody sees, and it is seen at the
// moment scanning has stopped. Telling an operator to add a key when
// the keys are merely busy is an hour spent on the wrong thing at the
// worst time; telling them to wait when the pool is empty is an hour
// spent on nothing at all.
//
// So the three are asserted apart, and each is asserted to say what to
// DO rather than what is true.

Deno.test("an empty pool asks for a key", () => {
  assertEquals(poolProblem(0, 0), "no keys have been added to it");
});

Deno.test("keys that are all switched off or out of hours say so", () => {
  const said = poolProblem(3, 0);
  assertStringIncludes(said, "all 3 of its keys");
  assertStringIncludes(said, "switched off or outside the hours");
  // And NOT the other thing. An operator told the keys are spent goes
  // away and waits, and these ones are not coming back on their own.
  assertEquals(said.includes("spent their allowance"), false);
});

Deno.test("keys that are usable but spent say when they come back", () => {
  const said = poolProblem(3, 3);
  assertStringIncludes(said, "spent their allowance");
  assertStringIncludes(said, "the minute, the day or the month rolls over");
  // The other way round: nobody should be sent to switch a key on.
  assertEquals(said.includes("switched off"), false);
});

Deno.test("one key reads as one key, not as a count of nothing", () => {
  // The count is in the sentence, so a pool of one that is spent says
  // "all 1 of its keys" rather than a bare phrase that reads as though
  // the pool were bigger.
  assertStringIncludes(poolProblem(1, 1), "all 1 of its keys");
});

Deno.test("usable can never exceed keys, and a bad pair still answers", () => {
  // `ocr_key_pool_size` counts usable as a filter over the same rows,
  // so this cannot happen — but a message function that threw on it
  // would turn a pool problem into a 500 and lose the real reason.
  assertStringIncludes(poolProblem(2, 5), "spent their allowance");
  // And a negative, which is what a null coalesced wrongly would look
  // like.
  assertEquals(poolProblem(-1, 0), "no keys have been added to it");
});
