/**
 * receive-email
 *
 * Takes delivery of mail sent to a reserved address on the platform's
 * domain and files it against the company that reserved it.
 *
 * POST { to, from, from_name?, message_id, subject?, text?, html?,
 *         attachments?: [{ filename, content_type, content_base64 }] }
 *   -> 200 { stored: true, id, attachments: n }  filed
 *   -> 200 { stored: false }                     nobody's address, or
 *                                                the module is off
 *
 * ## Attachments
 *
 * Added in `0354`. Before it the worker dropped every part it did not
 * recognise as text, so a supplier's PDF invoice reached the covering
 * note and stopped — with nothing saying so, which is worse than a
 * failure because a failure would be noticed.
 *
 * Bytes go to the `mail` bucket under `<org_id>/<email_id>/`, and
 * `record_inbound_attachment` writes the row. Both are service-role
 * only: a client that could write either could invent a document that
 * appears to have arrived from somebody.
 *
 * A file that fails to store does not fail the delivery. The message is
 * already filed by then, and rejecting here would make the mail router
 * send the whole thing again — which lands the message once (its
 * Message-ID sees to that) and retries the same broken upload forever.
 * The count in the reply is what actually stored.
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
import { createClient } from "jsr:@supabase/supabase-js@2.117.0";
import { fail, json, serveFunction } from "../_shared/cors.ts";
import { attachmentPath, decodeBase64 } from "../_shared/mail_files.ts";

interface Delivery {
  to?: string;
  from?: string;
  from_name?: string | null;
  message_id?: string;
  subject?: string | null;
  text?: string | null;
  html?: string | null;
  attachments?: Attachment[] | null;
}

interface Attachment {
  filename?: string;
  content_type?: string | null;
  content_base64?: string;
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
  if (data === null) return json({ stored: false });

  const filed = await fileAttachments(db, data.org_id, data.id, body.attachments);
  return json({ stored: true, id: data.id, attachments: filed });
});

/**
 * Puts each attachment in the bucket and records it.
 *
 * Returns how many actually landed. Failures are counted out rather
 * than thrown: see the note above about why a broken file must not fail
 * the delivery.
 */
async function fileAttachments(
  // deno-lint-ignore no-explicit-any
  db: any,
  orgId: string,
  emailId: string,
  attachments: Attachment[] | null | undefined,
): Promise<number> {
  if (!Array.isArray(attachments) || attachments.length === 0) return 0;

  let filed = 0;
  for (let i = 0; i < attachments.length; i++) {
    const a = attachments[i];
    const path = attachmentPath(orgId, emailId, i + 1, a.filename ?? "");
    if (!a.content_base64 || !path) continue;

    let bytes: Uint8Array;
    try {
      bytes = decodeBase64(a.content_base64);
    } catch {
      continue;
    }

    const up = await db.storage.from("mail").upload(path, bytes, {
      contentType: a.content_type ?? "application/octet-stream",
      upsert: true,
    });
    if (up.error) continue;

    const { error } = await db.rpc("record_inbound_attachment", {
      p_email_id: emailId,
      p_filename: a.filename,
      p_content_type: a.content_type ?? null,
      p_size_bytes: bytes.length,
      p_storage_path: path,
    });
    if (!error) filed++;
  }
  return filed;
}
