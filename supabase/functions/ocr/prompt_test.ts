import { assert, assertStringIncludes } from "jsr:@std/assert@1.0.19";
import { SYSTEM } from "./prompt.ts";

/**
 * The reader is told a document may be handwritten.
 *
 * Reported against a handwritten payment voucher: the number and the
 * amount came back, the date came back as a day nobody had written on
 * the page, and the payee did not come back at all. Every field
 * description said "as printed" and nothing anywhere said the page
 * might not be.
 *
 * A paragraph in a prompt is the easiest thing in this repository to
 * lose — it has no callers, no types and no compiler. These are the
 * four things it must not lose.
 */
Deno.test("the reader is told a document may be handwritten", () => {
  assertStringIncludes(SYSTEM, "HANDWRITTEN");
  // And that it is ordinary here rather than an edge case, which is
  // what makes the difference between reading carefully and declining.
  assertStringIncludes(SYSTEM, "Malaysian businesses still write");
});

Deno.test("an unreadable field is null rather than a guess", () => {
  // The failure that was actually reported: a date came back filled,
  // so nobody checked it. A null is checked; a wrong date is not.
  assertStringIncludes(SYSTEM, "that field is null");
  assert(
    SYSTEM.includes("A guess on a handwritten figure is worse"),
    "the prompt must say why a null beats a guess, not only that it wants one",
  );
});

Deno.test("a value is never taken from elsewhere on the page", () => {
  // `September 2023` in the body is what the payment was FOR. The
  // reader returned a date built out of it.
  assertStringIncludes(SYSTEM, "Never take a value from somewhere else");
});

Deno.test("it still says the things it said before handwriting", () => {
  // The paragraphs the handwriting note was added around. A rewrite
  // that dropped them would trade one report for three older ones.
  assertStringIncludes(SYSTEM, "Malaysian bookkeeper");
  assertStringIncludes(SYSTEM, "one entry");
  assertStringIncludes(SYSTEM, "SST");
  assertStringIncludes(SYSTEM, "never a guess");
});
