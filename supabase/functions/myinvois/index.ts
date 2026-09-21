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
 *   action = "certificate" -> read a XAdES signing certificate, prove the
 *                             key matches it, and put it on file
 *   action = "receive"     -> read a document a SUPPLIER sent us and
 *                             keep it. The only inbound action here;
 *                             every other one pushes.
 *
 * And one caller that is not a person at all:
 *
 *   action = "file-consolidations" -> file every consolidated e-Invoice
 *                             coming due, for every company. Only the
 *                             scheduler may ask, and it is answered
 *                             before `buildContext` runs, because that
 *                             resolves a signed-in user and a timer is
 *                             not one.
 */
import { fail, failUnexpected, json, serveFunction } from "../_shared/cors.ts";
import { buildContext, HttpError } from "../_shared/context.ts";
import { submit } from "./submit.ts";
import { checkStatus } from "./status.ts";
import { cancel } from "./cancel.ts";
import { validateTin } from "./tin.ts";
import { saveCertificate } from "./certificate.ts";
import { fileConsolidations } from "./consolidations.ts";
import { receiveDocument } from "./receive.ts";
import { isSchedulerCall } from "../_shared/scheduler.ts";

serveFunction("myinvois.failed", async (req: Request) => {
  if (req.method !== "POST") {
    return fail("Use POST", 405);
  }

  // Hoisted so the failure log below can name it. Everything else about
  // the request stays inside the try.
  let action = "";

  try {
    // The scheduler, before anything tries to resolve a person. Its
    // body is read here and nowhere else, so a signed-in caller cannot
    // reach this action by naming it: `buildContext` below does not
    // route to it at all.
    const peeked = (await req.clone().json().catch(() => ({}))) as
      Record<string, unknown>;
    const asked = String(peeked.action ?? "").toLowerCase();
    if (asked === "file-consolidations") {
      action = asked;
      if (
        !isSchedulerCall(req, {
          secret: Deno.env.get("SCHEDULER_SECRET"),
          serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
        })
      ) {
        return fail("Only the scheduler files consolidations", 403);
      }
      return json(await fileConsolidations(peeked));
    }

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
      case "certificate":
        return json(await saveCertificate(ctx));
      case "receive":
        return json(await receiveDocument(ctx));
      default:
        return fail(
          `Unknown action "${action}". Expected submit, status, cancel, ` +
            `validate-tin, certificate or receive.`,
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
