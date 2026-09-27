/**
 * billplz-checkout
 *
 * Turns an outstanding platform invoice into somewhere to send the
 * payer.
 *
 * POST { "invoice_id": "<uuid>" }
 *   -> { url, payment_id, mode }
 *
 * Secrets, which live only in Supabase → Edge Functions → Secrets:
 *
 *   BILLPLZ_SECRET_KEY     the API key, used as the HTTP Basic username
 *   BILLPLZ_COLLECTION_ID  which collection the bill is raised in
 *
 * Neither may appear in a migration, a table, or the Flutter bundle.
 * `payment_gateways.secret_ref` names the first of them and holds
 * nothing, and every signed-in user on the platform can read that
 * table — which is exactly why it holds nothing.
 *
 * ## Who may ask
 *
 * `verify_jwt = true`, and then the invoice is read through the
 * caller's own token so RLS decides whether it is theirs. A JWT alone
 * proves very little here: the publishable key ships inside the web
 * bundle, so anybody who has loaded the site has one. What stops
 * somebody paying attention to another company's invoice — or, more to
 * the point, learning its amount — is the read policy on
 * `platform_invoices`, not this function.
 *
 * ## What it does not decide
 *
 * Whether the invoice is payable, and what the payment is worth. Both
 * are `app.begin_gateway_payment`'s, in 0297, because a rule enforced
 * only here is not enforced.
 */
import { createClient } from "jsr:@supabase/supabase-js@2.117.0";
import { fail, json, serveFunction } from "../_shared/cors.ts";
import { requireEnv } from "../_shared/env.ts";
import {
  billplzApiBase,
  createBillplzBill,
  toSen,
} from "../_shared/billplz.ts";

serveFunction("billplz-checkout", async (req) => {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return fail("Missing Authorization header", 401);

  const url = requireEnv("SUPABASE_URL");
  const anonKey = requireEnv("SUPABASE_ANON_KEY");
  const serviceKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const admin = createClient(url, serviceKey);

  const { data: userData } = await userClient.auth.getUser();
  if (!userData?.user) return fail("Not authenticated", 401);

  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const invoiceId = body.invoice_id as string | undefined;
  if (!invoiceId) return fail("invoice_id is required", 400);

  // Through the caller's own client: a forged invoice id belonging to
  // another company returns nothing rather than its amount.
  const { data: invoice } = await userClient
    .from("platform_invoices")
    .select("id, invoice_no, org_id, description, total_amount, currency, status")
    .eq("id", invoiceId)
    .maybeSingle();

  if (!invoice) return fail("No such invoice", 404);
  if (invoice.status !== "issued") {
    return fail(`Invoice ${invoice.invoice_no} is ${invoice.status}`, 409);
  }
  if (invoice.currency !== "MYR") {
    // Billplz settles in ringgit. Sending it a figure denominated in
    // something else would charge the right number of the wrong unit.
    return fail("Billplz can only take ringgit", 400);
  }

  // Sandbox unless a platform administrator has said live, and read
  // from the gateway row rather than from an environment variable so
  // the console is the one place it is decided.
  const { data: gateway } = await admin
    .from("payment_gateways")
    .select("mode, is_active")
    .eq("code", "billplz")
    .maybeSingle();

  if (!gateway?.is_active) {
    return fail("Billplz is not switched on for this platform", 409);
  }
  const mode = gateway.mode === "live" ? "live" : "sandbox";

  // Who to put on the bill. The member asking is the one who will be
  // looking at their own card, so their address is the right one.
  const { data: profile } = await userClient
    .from("profiles")
    .select("full_name")
    .eq("id", userData.user.id)
    .maybeSingle();

  const { data: siteSetting } = await admin
    .from("platform_settings")
    .select("value")
    .eq("key", "site_url")
    .maybeSingle();
  const siteUrl = typeof siteSetting?.value === "string"
    ? siteSetting.value
    : "https://iakauntan.com";

  const bill = await createBillplzBill({
    apiBase: billplzApiBase(mode),
    secretKey: requireEnv("BILLPLZ_SECRET_KEY"),
    collectionId: requireEnv("BILLPLZ_COLLECTION_ID"),
    email: userData.user.email ?? "",
    name: profile?.full_name ?? invoice.invoice_no,
    amountSen: toSen(Number(invoice.total_amount)),
    description: `${invoice.invoice_no} — ${invoice.description}`,
    // Billplz posts here when the payer has paid. It is the only thing
    // that settles an invoice; the redirect below is a courtesy to the
    // browser and settles nothing.
    callbackUrl: `${url}/functions/v1/billplz-callback`,
    redirectUrl: `${siteUrl}/#/billing`,
    reference: invoice.invoice_no,
  });

  const { data: paymentId, error } = await admin.rpc(
    "begin_gateway_payment",
    {
      p_invoice: invoice.id,
      p_gateway: "billplz",
      p_provider_ref: bill.id,
      p_checkout_url: bill.url,
      p_created_by: userData.user.id,
    },
  );

  // The bill exists at Billplz whatever happens next, so a failure to
  // record it locally has to be loud rather than swallowed: without the
  // row, the callback will not know what the payment was for.
  if (error) {
    return fail(
      "The bill was created but could not be recorded. Do not pay it; " +
        "quote this reference to support.",
      500,
      { provider_ref: bill.id },
    );
  }

  return json({ url: bill.url, payment_id: paymentId, mode });
});
