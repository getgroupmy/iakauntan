/**
 * The decisions made before the service role key is touched.
 *
 *   deno test supabase/functions/platform-users/rules_test.ts
 *
 * `platform-users` holds the SERVICE ROLE KEY, which answers yes to
 * every row in the database with no policy in its way. Everything below
 * is about the checks in front of it being the ones we meant, because
 * getting one of them wrong is not a bug in a screen — it is an account
 * created by somebody who should not have been able to, or an
 * administrator locked out of the console that would have let them back
 * in.
 *
 * NO IMPORTS BUT THE ONE BEING TESTED, for the reason `ask/wire_test.ts`
 * gives: `jsr.io` is unreachable from some of the machines this gets
 * worked on, and a `jsr:@std/assert` import would make this a test only
 * CI can run.
 *
 * What these cannot check is the Admin API itself. Green here says the
 * request we build is the one we meant; it does not say GoTrue accepts
 * it.
 */
import {
  action,
  banDuration,
  MIN_PASSWORD,
  normalizeEmail,
  passwordProblem,
  suspendProblem,
  text,
} from "./rules.ts";

function eq(actual: unknown, expected: unknown, what: string): void {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) throw new Error(`${what}: expected ${b}, got ${a}`);
}

function ok(condition: boolean, what: string): void {
  if (!condition) throw new Error(what);
}

Deno.test("a field that is not a string is empty, not stringified", () => {
  eq(text("  hello  "), "hello", "trimmed");
  eq(text(""), "", "empty stays empty");
  // The one that matters: `{"email": {}}` must not become the address
  // `[object Object]`, and `{"user_id": 0}` must not become "0".
  eq(text({}), "", "an object");
  eq(text(0), "", "a number");
  eq(text(null), "", "null");
  eq(text(undefined), "", "absent");
  eq(text(true), "", "a boolean");
});

Deno.test("an address is lower-cased, so one person is not two", () => {
  eq(normalizeEmail(" Aisyah@Example.COM "), "aisyah@example.com", "folded");
  // GoTrue treats addresses case-insensitively. Leaving the case alone
  // would let the same account appear twice in the console's list.
  eq(
    normalizeEmail("AISYAH@EXAMPLE.COM"),
    normalizeEmail("aisyah@example.com"),
    "the same person either way",
  );
});

Deno.test("the password floor is ten, and the boundary is exact", () => {
  eq(MIN_PASSWORD, 10, "the floor");
  eq(passwordProblem("0123456789"), null, "exactly ten is enough");
  ok(passwordProblem("012345678") !== null, "nine is not");
  ok(passwordProblem("") !== null, "nothing is not");
});

Deno.test("creating says what the password is standing in front of", () => {
  const creating = passwordProblem("short", { creating: true }) ?? "";
  const resetting = passwordProblem("short") ?? "";

  ok(creating.includes("10"), "the number is in both");
  ok(resetting.includes("10"), "the number is in both");
  // The long sentence belongs to the create case: somebody typing
  // another person's password for the first time should be told what it
  // protects. A reset does not need it said twice.
  ok(
    creating.includes("typed by somebody other than its owner"),
    "creating explains",
  );
  ok(!resetting.includes("typed by somebody other"), "resetting does not");
});

Deno.test("a ban is a duration, and lifting one is 'none'", () => {
  // Not "0h": some GoTrue versions read that as a ban of no length and
  // others reject it. "none" is the documented way to lift one.
  eq(banDuration(false), "none", "lifted");
  eq(banDuration(true), "876000h", "a hundred years");
  ok(banDuration(true) !== banDuration(false), "the two are not the same");
});

Deno.test("an administrator cannot suspend themselves", () => {
  eq(
    suspendProblem("u1", "u1", true),
    "You cannot suspend yourself.",
    "the console's own staff stay able to undo it",
  );
  // Letting yourself back in is not the same act and needs no guard —
  // somebody suspended cannot sign in to ask for it.
  eq(suspendProblem("u1", "u1", false), null, "lifting your own");
  eq(suspendProblem("u2", "u1", true), null, "suspending somebody else");
  eq(suspendProblem("", "u1", true), "Which person?", "nobody named");
});

Deno.test("only the three actions are actions", () => {
  eq(action("create"), "create", "create");
  eq(action("password"), "password", "password");
  eq(action("suspend"), "suspend", "suspend");
  eq(action(" suspend "), "suspend", "trimmed");

  // A closed list, not a lookup on the body's own string. This is the
  // function that holds the service role key, and "call the method named
  // in the request" is how that key gets used for something nobody
  // wrote.
  eq(action("delete"), null, "not an action here");
  eq(action("Create"), null, "not case-insensitive");
  eq(action(""), null, "nothing");
  eq(action({ toString: () => "create" }), null, "not an object either");
});
