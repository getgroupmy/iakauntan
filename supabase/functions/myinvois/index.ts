/**
 * myinvois
 *
 * Single entry point for every LHDN MyInvois operation. Routing on an
 * `action` field (rather than one function per operation) keeps the
 * access-token cache warm across calls and gives us one place to do
 * authentication and audit logging.
 *
 * POST { action, org_id, ...payload }
 *   action = "submit"      -> render queued documents to UBL and send
 *   action = "status"      -> poll validation outcomes
 *   action = "cancel"      -> cancel a validated document within 72h
 *   action = "validate-tin"-> confirm a TIN matches an identifier
 */
import { corsHeaders, fail, json } from "../_shared/cors.ts";
import { buildContext, HttpError } from "../_shared/context.ts";
import { submit } from "./submit.ts";
import { checkStatus } from "./status.ts";
import { cancel } from "./cancel.ts";
import { validateTin } from "./tin.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return fail("Use POST", 405);
  }

  try {
    const ctx = await buildContext(req);
    const action = String(ctx.body.action ?? "").toLowerCase();

    switch (action) {
      case "submit":
        return json(await submit(ctx));
      case "status":
        return json(await checkStatus(ctx));
      case "cancel":
        return json(await cancel(ctx));
      case "validate-tin":
      case "validate_tin":
        return json(await validateTin(ctx));
      default:
        return fail(
          `Unknown action "${action}". Expected submit, status, cancel or validate-tin.`,
        );
    }
  } catch (err) {
    if (err instanceof HttpError) {
      return fail(err.message, err.status, err.details);
    }
    console.error("myinvois function failed", err);
    return fail(err instanceof Error ? err.message : "Unexpected error", 500);
  }
});
