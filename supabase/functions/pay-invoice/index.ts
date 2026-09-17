/**
 * pay-invoice
 *
 * A customer holding a share link presses Pay. This creates the bill at
 * the *tenant's own* acquirer and hands back where to send them.
 *
 * POST { token, gateway, email?, name? }
 *   -> { url, payment_id, mode }
 *
 * ## Why this has no session, and what stands in for one
 *
 * The payer is a customer, not a user. They have no account and never
 * will: the whole point of `open_shared_document` is that a company can
 * send an invoice to somebody who does not sign in. So there is no
 * Authorization header to build a caller-scoped client from, and
 * `scripts/check_edge_authorization.py` carries this function in
 * NO_CALLER with that reason.
 *
 * The share token is the credential, and it is checked in SQL rather
 * than here. `app.shared_payment_intent` resolves the token, applies
 * the same rules `open_shared_document` applies (a valid, unrevoked,
 * unexpired link on a document that has not been withdrawn), and
 * refuses if there is nothing left to pay. Nothing in this file decides
 * whether the payer may pay: a rule enforced only in TypeScript is not
 * enforced.
 *
 * ## The amount is not a parameter
 *
 * `begin_shared_payment` takes no amount. It reads the balance off the
 * document, and `0413` asserts that its signature has no amount to
 * take. A checkout for a figure the browser chose is how an invoice
 * gets settled for a ringgit, and the browser is the payer's.
 *
 * ## Credentials
 *
 * The tenant's, not the platform's. `app.shared_payment_intent` hands
 * back the API key and collection for the organization that issued the
 * invoice, and that function is revoked from every client role — only
 * the service role reaches it. The key is used once, here, and never
 * logged: a Billplz error body can quote the key back, so the failure
 * path returns a sentence and puts the detail in the function log.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { json, logFailure, serveFunction } from "../_shared/cors.ts";
import { requireEnv } from "../_shared/env.ts";
import {
  billplzApiBase,
  createBillplzBill,
  toSen,
} from "../_shared/billplz.ts";

interface PayIntent {
  org_id: string;
  document_id: string;
  doc_no: string;
  amount: number;
  currency: string;
  gateway_code: string;
  mode: string;
  api_key: string;
  collection_ref: string | null;
  signature_key: string | null;
}

serveFunction("pay-invoice", async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  let body: { token?: string; gateway?: string; email?: string; name?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Send a JSON body" }, 400);
  }

  const token = (body.token ?? "").trim();
  const gateway = (body.gateway ?? "").trim().toLowerCase();
  if (!token || !gateway) {
    return json({ error: "Which invoice, and paid how?" }, 400);
  }

  // Only Billplz is wired to an acquirer so far. The other acquirers in
  // `payment_gateways` are registered and not implemented, and saying
  // so is better than a bill that never appears.
  if (gateway !== "billplz") {
    return json({ error: "That way of paying is not available yet." }, 400);
  }

  const url = requireEnv("SUPABASE_URL");
  const admin = createClient(url, requireEnv("SUPABASE_SERVICE_ROLE_KEY"));

  const { data: rows, error: intentError } = await admin
    .schema("app")
    .rpc("shared_payment_intent", { p_token: token, p_gateway: gateway });

  if (intentError) {
    // The message can name the document; the payer gets the sentence
    // the database wrote for them, which is already customer-facing —
    // "That link is no longer open", "There is nothing left to pay".
    logFailure(intentError, "pay-invoice", { gateway });
    return json({ error: intentError.message }, 400);
  }

  const intent = (rows as PayIntent[] | null)?.[0];
  if (!intent) {
    return json({ error: "That way of paying is not available." }, 404);
  }
  if (!intent.collection_ref) {
    return json(
      { error: "This company has not finished setting up online payment." },
      400,
    );
  }

  let bill;
  try {
    bill = await createBillplzBill({
      apiBase: billplzApiBase(intent.mode),
      secretKey: intent.api_key,
      collectionId: intent.collection_ref,
      // Billplz wants somewhere to send the receipt. The payer's own
      // address if they gave one; otherwise the invoice number, which
      // Billplz accepts as a name and which at least identifies the
      // bill in the acquirer's dashboard.
      email: (body.email ?? "").trim(),
      name: (body.name ?? "").trim() || intent.doc_no,
      amountSen: toSen(Number(intent.amount)),
      description: `${intent.doc_no}`,
      // The callback settles the invoice. The redirect is a courtesy to
      // the browser and settles nothing — the same division
      // `billplz-checkout` makes, and for the same reason: a payer who
      // closes the tab has still paid.
      callbackUrl: `${url}/functions/v1/pay-invoice-callback`,
      reference: intent.doc_no,
    });
  } catch (e) {
    // The acquirer's error body can quote the key back. It goes to the
    // log and never to the payer.
    logFailure(e, "pay-invoice", { doc_no: intent.doc_no, gateway });
    return json({ error: "The payment could not be started." }, 502);
  }

  const { data: paymentId, error } = await admin.rpc("begin_shared_payment", {
    p_token: token,
    p_gateway: gateway,
    p_provider_ref: bill.id,
    p_checkout_url: bill.url,
  });

  // The bill exists at the acquirer whatever happens next, so failing
  // to record it has to be loud: without the row, the callback cannot
  // tell what the payment was for and `settle_shared_payment` will
  // answer `unknown` to a real payment.
  if (error) {
    logFailure(error, "pay-invoice", {
      provider_ref: bill.id,
      doc_no: intent.doc_no,
    });
    return json({
      error:
        "The bill was created but could not be recorded. Do not pay it; " +
        "quote this reference to the company that sent you the invoice.",
      provider_ref: bill.id,
    }, 500);
  }

  return json({ url: bill.url, payment_id: paymentId, mode: intent.mode });
});
