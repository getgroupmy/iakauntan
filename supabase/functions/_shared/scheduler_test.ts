/**
 * deno test supabase/functions/_shared/scheduler_test.ts
 *
 * `isSchedulerCall` decides whether a caller may act for every
 * organization at once. Getting it wrong in the permissive direction
 * does not fail — it quietly hands the outbox to whoever asks, which is
 * the shape of the bug `send-email` already had once.
 *
 * So the assertions that matter here are the negative ones, and above
 * all the unconfigured cases: a function deployed without a secret must
 * refuse everybody rather than match "" against a missing header.
 */
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { isSchedulerCall } from "./scheduler.ts";

const SECRET = "s3cr3t-value-from-the-dashboard";
const SERVICE = "service-role-key-abcdefghijklmnop";

function req(headers: Record<string, string> = {}): Request {
  return new Request("https://example.test/", { method: "POST", headers });
}

Deno.test("the scheduler's secret is accepted", () => {
  assertEquals(
    isSchedulerCall(req({ "X-Scheduler-Secret": SECRET }), { secret: SECRET }),
    true,
  );
});

Deno.test("the header name is matched case-insensitively", () => {
  // Headers are case-insensitive by specification, but the lookup is
  // written in lower case and curl sends what the workflow wrote.
  assertEquals(
    isSchedulerCall(req({ "x-scheduler-secret": SECRET }), { secret: SECRET }),
    true,
  );
});

Deno.test("the service role key still works as the bearer token", () => {
  assertEquals(
    isSchedulerCall(
      req({ Authorization: `Bearer ${SERVICE}` }),
      { secret: SECRET, serviceKey: SERVICE },
    ),
    true,
  );
});

Deno.test("either credential alone is enough", () => {
  assertEquals(
    isSchedulerCall(req({ "X-Scheduler-Secret": SECRET }), {
      secret: SECRET,
      serviceKey: SERVICE,
    }),
    true,
  );
});

Deno.test("a wrong secret is refused", () => {
  assertEquals(
    isSchedulerCall(req({ "X-Scheduler-Secret": "nope" }), { secret: SECRET }),
    false,
  );
});

Deno.test("a prefix of the secret is refused", () => {
  assertEquals(
    isSchedulerCall(
      req({ "X-Scheduler-Secret": SECRET.slice(0, -1) }),
      { secret: SECRET },
    ),
    false,
  );
});

Deno.test("the publishable key as bearer is not the scheduler", () => {
  // The case that matters most: this key ships inside the web bundle, so
  // if `verify_jwt` were the only gate every visitor would qualify.
  assertEquals(
    isSchedulerCall(
      req({ Authorization: "Bearer sb_publishable_anyone_has_this" }),
      { secret: SECRET, serviceKey: SERVICE },
    ),
    false,
  );
});

Deno.test("a caller presenting nothing is refused", () => {
  assertEquals(
    isSchedulerCall(req(), { secret: SECRET, serviceKey: SERVICE }),
    false,
  );
});

Deno.test("no secret configured does not make everybody the scheduler", () => {
  // The empty-string trap. An absent header reads as "", an unset env
  // var reads as "", and "" === "" would open the door to the internet.
  assertEquals(isSchedulerCall(req(), {}), false);
  assertEquals(isSchedulerCall(req({ "X-Scheduler-Secret": "" }), {}), false);
  assertEquals(
    isSchedulerCall(req({ "X-Scheduler-Secret": "" }), { secret: "" }),
    false,
  );
  assertEquals(
    isSchedulerCall(req({ Authorization: "Bearer " }), { serviceKey: "" }),
    false,
  );
});

Deno.test("whitespace does not become a match", () => {
  assertEquals(
    isSchedulerCall(req({ "X-Scheduler-Secret": "   " }), { secret: "   " }),
    false,
  );
});

Deno.test("the bearer prefix is optional and case-insensitive", () => {
  assertEquals(
    isSchedulerCall(req({ Authorization: SERVICE }), { serviceKey: SERVICE }),
    true,
  );
  assertEquals(
    isSchedulerCall(
      req({ Authorization: `bearer ${SERVICE}` }),
      { serviceKey: SERVICE },
    ),
    true,
  );
});
