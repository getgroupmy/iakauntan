/**
 * billplz-callback
 *
 * Billplz posts here when a bill has been paid, and this is the only
 * thing on the platform that marks an invoice settled by machine.
 *
 * POST (application/x-www-form-urlencoded)
 *   id, collection_id, paid, state, amount, paid_amount, due_at,
 *   email, mobile, name, url, paid_at, x_signature
 *
 * Secret, in Supabase → Edge Functions → Secrets and nowhere else:
 *
 *   BILLPLZ_XSIGNATURE_KEY   the X Signature key from the Billplz
 *                            dashboard, under Settings → Payment
 *
 * ## This one has no JWT, and that is deliberate
 *
 * Every other function in this project is `verify_jwt = true`. This one
 * cannot be: Billplz's servers hold no session with us, and a payment
 * confirmation that could only arrive with a JWT would never arrive.
 *
 * So the signature is the credential, and everything about how it is
 * checked is in `_shared/billplz.ts` with its assertions in
 * `_shared/billplz_test.ts` — on the shared side precisely because CI
 * runs those and only type-checks this file. Code that decides whether
 * a stranger may mark an invoice paid belongs where it is executed.
 *
 * Two rules follow from being open to the internet:
 *
 *   * an unverified request is told nothing. Not which invoice, not
 *     whether the reference exists, not whether the amount was close.
 *     A 401 and a line in the log.
 *   * a verified request is answered 200 even when nothing happened.
 *     Billplz retries anything that is not 2xx, and a callback for a
 *     bill we do not recognise would otherwise be retried for ever.
 *
 * What is actually decided — whether the amount covers the invoice,
 * whether the invoice was still outstanding, whether this is a retry of
 * one already settled — is `public.settle_gateway_payment` in 0297.
 * None of it is decided here, because a rule enforced only in
 * TypeScript is not enforced.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { json, logFailure, serveFunction } from "../_shared/cors.ts";
import { requireEnv } from "../_shared/env.ts";
import { verifyBillplzSignature } from "../_shared/billplz.ts";

serveFunction("billplz-callback", async (req) => {
  if (req.method !== "POST") {
    return json({ error: "POST only" }, 405);
  }

  // Form encoded, which is what Billplz sends. Read as text first so a
  // body that is not a form is a refusal rather than an exception.
  const raw = await req.text();
  const form = new URLSearchParams(raw);

  const params: Record<string, string> = {};
  for (const [key, value] of form.entries()) params[key] = value;

  const supplied = params.x_signature ?? null;
  const key = Deno.env.get("BILLPLZ_XSIGNATURE_KEY");

  const ok = await verifyBillplzSignature(params, supplied, key);
  if (!ok) {
    // The log gets the bill reference so a genuine misconfiguration can
    // be traced; the caller gets a sentence. Which of the two went
    // wrong — no key configured, wrong key, forged payload — is not a
    // thing to tell whoever is on the other end.
    logFailure(
      new Error("Billplz callback signature did not verify"),
      "billplz-callback",
      { provider_ref: params.id ?? "(none)" },
    );
    return json({ error: "Signature did not verify" }, 401);
  }

  const url = requireEnv("SUPABASE_URL");
  const admin = createClient(url, requireEnv("SUPABASE_SERVICE_ROLE_KEY"));

  // Billplz counts in sen. The invoice is in ringgit, and the
  // comparison happens in SQL, so the conversion happens here — once,
  // where the unit changes.
  const paidSen = Number(params.paid_amount ?? "0");
  const paidRinggit = Number.isFinite(paidSen) ? paidSen / 100 : 0;

  const { data: outcome, error } = await admin.rpc("settle_gateway_payment", {
    p_gateway: "billplz",
    p_provider_ref: params.id ?? "",
    p_paid: params.paid === "true",
    p_paid_amount: paidRinggit,
    p_payload: params,
  });

  if (error) {
    // A 500 here is correct: the signature was good, so this really is
    // Billplz, and a retry is what we want. This is the one path where
    // being retried is the useful outcome.
    logFailure(error, "billplz-callback", { provider_ref: params.id ?? "" });
    return json({ error: "Could not record the payment" }, 500);
  }

  // 200 whatever was decided, including "unknown". See the header.
  console.log(JSON.stringify({
    event: "billplz-callback",
    provider_ref: params.id ?? "",
    outcome,
  }));
  return json({ outcome });
});
