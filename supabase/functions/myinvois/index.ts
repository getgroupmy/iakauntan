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
import { fail, failUnexpected, json, serveFunction } from "../_shared/cors.ts";
import { buildContext, HttpError } from "../_shared/context.ts";
import { submit } from "./submit.ts";
import { checkStatus } from "./status.ts";
import { cancel } from "./cancel.ts";
import { validateTin } from "./tin.ts";

serveFunction("myinvois.failed", async (req: Request) => {
  if (req.method !== "POST") {
    return fail("Use POST", 405);
  }

  // Hoisted so the failure log below can name it. Everything else about
  // the request stays inside the try.
  let action = "";

  try {
    const ctx = await buildContext(req);
    action = String(ctx.body.action ?? "").toLowerCase();

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
    // Not the error object, and not its message to the caller either. An
    // error thrown anywhere in this function may be carrying a MyInvois
    // request or response on it, and those hold the buyer's name, TIN,
    // address, email and every line of the invoice. Logs are read by
    // people who have no business seeing a particular company's
    // customers, and a stack trace is not a good enough reason to show
    // them; nor is a response body, which is one screenshot away from
    // anywhere.
    //
    // The full exchange is not lost: `persistLogs` writes it to
    // `einvoice_logs`, which is org-scoped and access-controlled, and
    // which LHDN requires to be kept for seven years anyway.
    return failUnexpected(err, "myinvois.failed", req, { action });
  }
});
