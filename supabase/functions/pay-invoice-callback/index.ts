/**
 * pay-invoice-callback
 *
 * The acquirer posts here when a customer has paid a *tenant's*
 * invoice. This is the only thing that settles one by machine.
 *
 * POST (application/x-www-form-urlencoded)
 *   id, collection_id, paid, state, amount, paid_amount, due_at,
 *   email, mobile, name, url, paid_at, x_signature
 *
 * ## The key is the shop's, not the platform's
 *
 * `billplz-callback` verifies against `BILLPLZ_XSIGNATURE_KEY`, one
 * Edge Function secret for one Billplz account, because the platform
 * has exactly one. A tenant's bills do not work that way: every
 * organization has its own account and its own X Signature key, so the
 * key depends on which confirmation this is — and the only thing
 * identifying that before verification is the reference in an
 * unverified body.
 *
 * `app.shared_payment_signature_key` looks it up. Looking a key up by
 * an unverified reference is not a decision: finding a row decides
 * nothing, and the signature is still checked before a single field is
 * believed. What the caller must not learn is which of the two
 * happened, so **a reference nobody has heard of and a signature that
 * did not verify are answered identically** — 401, one line in the log.
 * Answering them differently makes this an oracle for guessing
 * references.
 *
 * ## No JWT, deliberately
 *
 * The acquirer's servers hold no session with us. A confirmation that
 * could only arrive with a JWT would never arrive. The signature is the
 * credential, and it is verified by `_shared/billplz.ts`, whose
 * assertions run in CI — code that decides whether a stranger may mark
 * an invoice paid belongs where it is tested.
 *
 * ## What is decided here: nothing
 *
 * Whether the amount covers the balance, whether this is a retry of one
 * already settled, whether the invoice was paid by other means while
 * the acquirer was thinking — all of it is
 * `public.settle_shared_payment` in `0413`, with the receipt it posts.
 * A verified request is answered 200 even when the outcome is
 * `unknown`, because acquirers retry anything that is not 2xx.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { json, logFailure, serveFunction } from "../_shared/cors.ts";
import { requireEnv } from "../_shared/env.ts";
import { verifyBillplzSignature } from "../_shared/billplz.ts";

serveFunction("pay-invoice-callback", async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const raw = await req.text();
  const form = new URLSearchParams(raw);

  const params: Record<string, string> = {};
  for (const [key, value] of form.entries()) params[key] = value;

  const providerRef = params.id ?? "";
  const url = requireEnv("SUPABASE_URL");
  const admin = createClient(url, requireEnv("SUPABASE_SERVICE_ROLE_KEY"));

  // The shop's own key, found from the reference. See the header: this
  // is a lookup and not a decision.
  const { data: key, error: keyError } = await admin
    .schema("app")
    .rpc("shared_payment_signature_key", {
      p_gateway: "billplz",
      p_provider_ref: providerRef,
    });

  if (keyError) {
    logFailure(keyError, "pay-invoice-callback", { provider_ref: providerRef });
    return json({ error: "Could not record the payment" }, 500);
  }

  const ok = await verifyBillplzSignature(
    params,
    params.x_signature ?? null,
    typeof key === "string" ? key : null,
  );

  // One answer for three different situations: no such reference, no
  // key configured, signature did not verify. Which one it was goes to
  // the log and not to whoever is on the other end.
  if (!ok) {
    logFailure(
      new Error("Payment callback did not verify"),
      "pay-invoice-callback",
      { provider_ref: providerRef || "(none)", had_key: Boolean(key) },
    );
    return json({ error: "Signature did not verify" }, 401);
  }

  // Billplz counts in sen; the invoice is in ringgit and the comparison
  // happens in SQL, so the unit changes once, here.
  const paidSen = Number(params.paid_amount ?? "0");
  const paidRinggit = Number.isFinite(paidSen) ? paidSen / 100 : 0;

  const { data: outcome, error } = await admin.rpc("settle_shared_payment", {
    p_gateway: "billplz",
    p_provider_ref: providerRef,
    p_paid: params.paid === "true",
    p_paid_amount: paidRinggit,
    p_payload: params,
  });

  if (error) {
    // A 500 is correct: the signature was good, so this really is the
    // acquirer, and a retry is what we want.
    logFailure(error, "pay-invoice-callback", { provider_ref: providerRef });
    return json({ error: "Could not record the payment" }, 500);
  }

  console.log(JSON.stringify({
    event: "pay-invoice-callback",
    provider_ref: providerRef,
    outcome,
  }));
  return json({ outcome });
});
