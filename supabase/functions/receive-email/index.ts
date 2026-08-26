/**
 * receive-email
 *
 * Takes delivery of mail sent to a reserved address on the platform's
 * domain and files it against the company that reserved it.
 *
 * POST { to, from, from_name?, message_id, subject?, text?, html? }
 *   -> 200 { stored: true, id }    filed
 *   -> 200 { stored: false }       nobody's address, or the module is off
 *
 * ## Where the mail comes from
 *
 * Cloudflare Email Routing holds the MX records for the domain and
 * hands each message to a worker; `cloudflare/email-router/worker.js`
 * in this repository is that worker, and this is what it posts to.
 * Nothing else is expected to call this.
 *
 * ## Why "nobody's address" is a 200 and not a 404
 *
 * The caller is a mail router, not a person. A 404 makes it retry, and
 * retrying delivery of a message nobody wants is how a spam run turns
 * into a bill. Told the message was not stored, the worker drops it and
 * moves on.
 *
 * ## What stops anybody else posting here
 *
 * A shared secret in the `x-inbound-secret` header, compared in
 * constant time, and the service-role key that lets this write at all.
 * Neither is in the repository:
 *
 *   INBOUND_SECRET              any random string, shared with the worker
 *   SUPABASE_SERVICE_ROLE_KEY   set for every function by the platform
 *
 * The write goes through `public.receive_email`, which is granted to
 * the service role and to nobody else — so even a client holding the
 * publishable key cannot invent a message that appears to have arrived
 * from somebody. It is in `public` because PostgREST exposes no other
 * schema; the grant is what keeps it private, not the schema.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { fail, json, serveFunction } from "../_shared/cors.ts";

interface Delivery {
  to?: string;
  from?: string;
  from_name?: string | null;
  message_id?: string;
  subject?: string | null;
  text?: string | null;
  html?: string | null;
}

/**
 * Compares two secrets without letting the clock say how much of the
 * guess was right.
 *
 * `a === b` on strings returns as soon as two bytes differ, which over
 * enough attempts tells an attacker the secret one character at a time.
 * This looks at every byte whatever it finds.
 */
function sameSecret(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  // Length is not a secret worth hiding — but comparing different
  // lengths byte by byte would read past the end of one of them.
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= left[i] ^ right[i];
  return diff === 0;
}

/** `"A Customer" <customer@example.com>` -> the two halves. */
function splitAddress(raw: string): { email: string; name: string | null } {
  const angled = raw.match(/^\s*(.*?)\s*<([^>]+)>\s*$/);
  if (angled) {
    const name = angled[1].replace(/^"(.*)"$/, "$1").trim();
    return { email: angled[2].trim().toLowerCase(), name: name || null };
  }
  return { email: raw.trim().toLowerCase(), name: null };
}

serveFunction("receive-email.failed", async (req: Request) => {
  const secret = Deno.env.get("INBOUND_SECRET") ?? "";
  if (!secret) {
    // Refusing rather than accepting: an unset secret would otherwise
    // mean anybody who finds the URL can file mail as anybody.
    return fail("Inbound mail is not configured", 503);
  }

  const offered = req.headers.get("x-inbound-secret") ?? "";
  if (!sameSecret(offered, secret)) return fail("Not this way", 401);

  let body: Delivery;
  try {
    body = await req.json();
  } catch {
    return fail("Expected JSON", 400);
  }

  if (!body.to || !body.from || !body.message_id) {
    return fail("A delivery needs to, from and message_id", 400);
  }

  const to = splitAddress(body.to);
  const from = splitAddress(body.from);

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  const { data, error } = await db.rpc("receive_email", {
    p_to: to.email,
    p_from: from.email,
    p_from_name: body.from_name ?? from.name,
    p_message_id: body.message_id,
    p_subject: body.subject ?? null,
    p_body_text: body.text ?? null,
    p_body_html: body.html ?? null,
    p_raw_path: null,
  });

  if (error) return fail(error.message, 500);

  // No row means the address belongs to nobody, or to a company that
  // has switched the module off. Neither is this function's problem and
  // neither is worth a retry.
  return json({ stored: data !== null, id: data?.id ?? null });
});
