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

/**
 * A bank statement is not a purchase document.
 *
 * The prompt used to open "You are reading a purchase document" and
 * then, several paragraphs later, the target list would offer a bank
 * statement as one of the destinations. The framing came first and a
 * statement is emphatically not one — which is the likeliest reason a
 * statement sent for scanning came back having recognised nothing.
 *
 * The four notes below are not decoration. Each one is a way a
 * Malaysian statement is read wrongly, and each has a counterpart in
 * `statement_import.dart` that depends on the reader answering this
 * way — so dropping a paragraph here silently disarms code over there.
 */
Deno.test("the opening does not call every document a purchase", () => {
  assert(
    !SYSTEM.startsWith("You are reading a purchase document"),
    "the first sentence frames everything after it",
  );
  assertStringIncludes(SYSTEM, "BANK STATEMENT");
});

Deno.test("a statement's sign is asked for, because the page has none", () => {
  assertStringIncludes(SYSTEM, "IT PRINTS NO SIGN");
  assertStringIncludes(SYSTEM, "Debit and Credit");
});

Deno.test("the running balance is asked for on every line", () => {
  // `balancesDecideTheSigns` settles the sign of every line from it,
  // and settles nothing at all without it.
  assertStringIncludes(SYSTEM, "RUNNING BALANCE IS THE MOST VALUABLE");
  assertStringIncludes(SYSTEM, "for every line that prints one");
});

Deno.test("a day and a month is given as printed, with no year added", () => {
  // `parsePartialStatementDate` reads `03/09`, and `resolveStatement
  // Year` puts it in the right year -- including the December that
  // belongs to the year before the header's. A reader that helpfully
  // added the header year would take that decision away and get it
  // wrong across new year.
  assertStringIncludes(SYSTEM, "DATE IS OFTEN A DAY AND A MONTH");
  assertStringIncludes(SYSTEM, "do not add this year");
});

Deno.test("the brought-forward row is asked for, with no amount", () => {
  // `scannedStatement` recognises it by exactly that shape and uses it
  // to anchor the chain. Asked for by its Malay name as well, because
  // that is what most of them print.
  assertStringIncludes(SYSTEM, "BAKI DIBAWA KE");
  assertStringIncludes(SYSTEM, "NO AMOUNT");
});

Deno.test("and every printed line is asked for, including the odd ones", () => {
  assertStringIncludes(SYSTEM, "in the order printed");
  assertStringIncludes(SYSTEM, "reconciles to");
});
