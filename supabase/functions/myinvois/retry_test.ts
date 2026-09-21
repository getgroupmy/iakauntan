import { assertEquals } from "jsr:@std/assert@1";
import {
  exhaustedNote,
  isExhausted,
  MAX_ATTEMPTS,
  nextAttempt,
} from "./retry.ts";

// `einvoice_documents.retry_count` was a column with nothing writing to
// it. The bulk picker selects `status in ('queued','draft','failed',
// 'invalid')`, and `invalid` is what MyInvois says when it has REJECTED
// a document -- a buyer TIN that does not exist, a classification code
// LHDN does not have. Almost never transient, and re-submitted on every
// sweep for ever because nothing counted the attempts.

Deno.test("the first failure is the first attempt", () => {
  assertEquals(nextAttempt(0), 1);
  assertEquals(nextAttempt(null), 1);
  assertEquals(nextAttempt(undefined), 1);
});

Deno.test("a null count is not a NaN count", () => {
  // `retry_count` is `not null default 0`, so a null should not reach
  // here at all -- and a row read with `select("*")` into a loosely
  // typed object is exactly where one would. `0 + null` is 0 in
  // JavaScript and `undefined + 1` is NaN, which PostgREST sends as
  // `null` and which would reset the count on every failure: the
  // unbounded retry, restored, with a counter beside it saying
  // nothing.
  assertEquals(Number.isFinite(nextAttempt(undefined)), true);
  assertEquals(Number.isFinite(nextAttempt(null)), true);
});

Deno.test("a negative count cannot walk the ceiling backwards", () => {
  // Nothing writes a negative. But a clamp that trusted the input
  // would let one buy extra attempts for ever, and the column is a
  // signed smallint.
  assertEquals(nextAttempt(-3), 1);
});

Deno.test("the count stops at the ceiling", () => {
  assertEquals(nextAttempt(MAX_ATTEMPTS - 1), MAX_ATTEMPTS);
  assertEquals(nextAttempt(MAX_ATTEMPTS), MAX_ATTEMPTS);
  assertEquals(nextAttempt(MAX_ATTEMPTS + 40), MAX_ATTEMPTS);
});

Deno.test("exhausted is the ceiling and not before it", () => {
  assertEquals(isExhausted(MAX_ATTEMPTS - 1), false);
  assertEquals(isExhausted(MAX_ATTEMPTS), true);
  assertEquals(isExhausted(MAX_ATTEMPTS + 1), true);
});

Deno.test("a document nothing has tried is not exhausted", () => {
  assertEquals(isExhausted(0), false);
  assertEquals(isExhausted(null), false);
  assertEquals(isExhausted(undefined), false);
});

Deno.test("the ceiling and the picker agree", () => {
  // `submit.ts` filters the bulk path with `.lt("retry_count",
  // MAX_ATTEMPTS)`. `lt` and `isExhausted` are the same line drawn from
  // two sides, so a document the picker skips must be one this calls
  // exhausted and the other way about. If one of them ever moves, the
  // sweep either gives up early or never gives up.
  for (let n = 0; n <= MAX_ATTEMPTS + 2; n++) {
    assertEquals(n < MAX_ATTEMPTS, !isExhausted(n), `at ${n}`);
  }
});

Deno.test("a stopped document says so, and says what to do", () => {
  const note = exhaustedNote(MAX_ATTEMPTS);
  assertEquals(note !== null, true);
  // The number, so nobody has to guess how many times it was tried.
  assertEquals(note!.includes(String(MAX_ATTEMPTS)), true);
  // And the way out. A document that stops being retried looks exactly
  // like a document that is fine, and the point of stopping is that
  // somebody has to go and look at it.
  assertEquals(note!.includes("submit it from the document"), true);
});

Deno.test("and a document still being tried says nothing", () => {
  assertEquals(exhaustedNote(0), null);
  assertEquals(exhaustedNote(MAX_ATTEMPTS - 1), null);
  assertEquals(exhaustedNote(null), null);
});

Deno.test("five, not zero and not one", () => {
  // A ceiling of zero stops every document including the first
  // attempt; a ceiling of one gives up on a token that expired
  // mid-batch. The number is a judgement and it is written down in
  // `retry.ts`, but it must at least be a number that lets a
  // transient failure through.
  assertEquals(MAX_ATTEMPTS > 1, true);
  assertEquals(MAX_ATTEMPTS, 5);
});
