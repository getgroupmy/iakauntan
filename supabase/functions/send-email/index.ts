/**
 * send-email
 *
 * Drains `public.email_outbox` through Resend. The only thing in the
 * system that holds a mail provider key, and the only thing that can
 * actually send: the database queues rows and never waits on a third
 * party.
 *
 * POST {}                     -> drain up to `limit` queued messages
 * POST { "id": "<uuid>" }     -> send one, for retrying a failure
 *
 * Called on a schedule by `.github/workflows/send-email.yml`, and by
 * hand from the outbox screen when somebody has just fixed whatever was
 * wrong.
 *
 * Those two callers are not the same and are not treated the same. The
 * scheduler drains every organization. Anybody else drains only their
 * own, because the rows to send are chosen under *their* token and
 * `email_outbox` carries `app.is_org_member(org_id)` — so one company's
 * staff cannot push another company's mail out early, which is what this
 * function used to allow anyone holding the publishable key to do.
 *
 * What marks a caller as the scheduler is in `_shared/scheduler.ts`.
 *
 * Secrets, none of which are in the repository:
 *   RESEND_API_KEY   from resend.com, the one thing that can send
 *   MAIL_FROM        the verified sender, e.g. "billing@iakauntan.com"
 *   SCHEDULER_SECRET any random string, shared with the workflow
 */
import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, fail, json } from "../_shared/cors.ts";
import { isSchedulerCall } from "../_shared/scheduler.ts";

const RESEND_ENDPOINT = "https://api.resend.com/emails";

/** Past this a message stops being retried and starts being a problem. */
const MAX_ATTEMPTS = 5;

interface OutboxRow {
  id: string;
  to_email: string;
  subject: string;
  body: string;
  reply_to: string | null;
  from_name: string | null;
  attempts: number;
  attachment_path: string | null;
  attachment_name: string | null;
}

/** Resend takes attachments as base64 in the JSON body. */
interface Attachment {
  filename: string;
  content: string;
}

/**
 * Fetches the attachment out of the `attachments` bucket.
 *
 * With the service role, because the bucket is private and the message
 * is being sent on behalf of somebody who is not in the room. The path
 * was checked against the organization and the document when the row was
 * queued, so what arrives here is already pinned to one document.
 *
 * Returns null rather than throwing: a message with a missing attachment
 * should go out as a link-only message rather than not go out at all,
 * and the row records which it was.
 */
async function loadAttachment(
  // The named type, not `ReturnType<typeof createClient>`: the latter
  // resolves to a fully-defaulted generic that the client built with a
  // schema does not satisfy, so it reads as the safer choice and is the
  // one that does not compile.
  db: SupabaseClient,
  row: OutboxRow,
): Promise<Attachment | null> {
  if (!row.attachment_path) return null;
  const { data, error } = await db.storage
    .from("attachments")
    .download(row.attachment_path);
  if (error || !data) {
    console.error("attachment missing", row.attachment_path, error?.message);
    return null;
  }

  // Chunked rather than String.fromCharCode(...bytes): spreading a
  // whole PDF into an argument list blows the stack somewhere north of
  // 100kB, which is an ordinary invoice with a logo on it.
  const bytes = new Uint8Array(await data.arrayBuffer());
  let binary = "";
  for (let i = 0; i < bytes.length; i += 8192) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  }

  return {
    filename: row.attachment_name ?? row.attachment_path.split("/").pop()!,
    content: btoa(binary),
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return fail("Use POST", 405);

  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const url = Deno.env.get("SUPABASE_URL");
  if (!serviceKey || !url) return fail("Function is missing its own keys", 500);

  const auth = req.headers.get("Authorization") ?? "";
  const isScheduler = isSchedulerCall(req, {
    secret: Deno.env.get("SCHEDULER_SECRET"),
    serviceKey,
  });

  const apiKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("MAIL_FROM");
  if (!apiKey || !from) {
    // Deliberately explicit. The alternative is messages sitting queued
    // with nobody able to say why.
    //
    // It names which of the two is missing, and it reports `scheduler`
    // even though nothing was sent. Without that flag this 503 hides the
    // credential: the scheduler would be told "mail is not configured"
    // every run, and whether its secret was even accepted would stay
    // unknown until the day Resend was set up and somebody expected mail
    // to start moving. Two problems discovered one at a time, the second
    // only after it looked finished.
    const missing = [
      !apiKey ? "RESEND_API_KEY" : null,
      !from ? "MAIL_FROM" : null,
    ].filter(Boolean);
    return fail(
      `Mail is not configured: set ${missing.join(" and ")} on this ` +
        "function before anything can be sent.",
      503,
      { scheduler: isScheduler, missing },
    );
  }

  // Sending and marking rows sent is always done with the service key:
  // nobody but this function may write to the outbox.
  const db = createClient(url, serviceKey, {
    auth: { persistSession: false },
  });

  // *Choosing* the rows is a different question, and the answer is the
  // caller's. The scheduler reads with the service key and sees every
  // organization — note that this is the function's own copy of that key,
  // not one the caller had to present. Anyone else reads under their own
  // token, so the
  // `app.is_org_member(org_id)` policy on `email_outbox` decides what
  // they can push out — and a caller presenting nothing but the
  // publishable key is `anon`, matches no organization, and drains
  // nothing at all. That last case is why no explicit 403 is needed.
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const reader = isScheduler ? db : createClient(url, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: auth } },
  });

  const body = await req.json().catch(() => ({}));
  const one = typeof body?.id === "string" ? body.id : null;
  const limit = Math.min(Math.max(Number(body?.limit ?? 25), 1), 100);

  let query = reader
    .from("email_outbox")
    .select("id, to_email, subject, body, reply_to, from_name, attempts, " +
      "attachment_path, attachment_name")
    .eq("status", "queued")
    .lt("attempts", MAX_ATTEMPTS)
    .order("queued_at", { ascending: true })
    .limit(one ? 1 : limit);
  if (one) query = query.eq("id", one);

  const { data, error } = await query;
  if (error) return fail(`Could not read the outbox: ${error.message}`, 500);

  // Through `unknown`: the client types a failed select's `data` as
  // GenericStringError[], which does not overlap with OutboxRow, so the
  // direct cast is the one TypeScript refuses. `error` is handled above,
  // so by here `data` is rows.
  const rows = (data ?? []) as unknown as OutboxRow[];
  let sent = 0;
  let failed = 0;

  for (const row of rows) {
    try {
      const attachment = await loadAttachment(db, row);
      const response = await fetch(RESEND_ENDPOINT, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
          // Resend deduplicates on this, so a retry after a timeout we
          // never saw the answer to does not send the message twice.
          "Idempotency-Key": row.id,
        },
        body: JSON.stringify({
          from: row.from_name ? `${row.from_name} <${from}>` : from,
          to: [row.to_email],
          subject: row.subject,
          text: row.body,
          ...(row.reply_to ? { reply_to: row.reply_to } : {}),
          ...(attachment ? { attachments: [attachment] } : {}),
        }),
      });

      const payload = await response.json().catch(() => ({}));

      if (!response.ok) {
        const message = payload?.message ?? `HTTP ${response.status}`;
        // 4xx other than rate limiting will not come right on a retry,
        // so it is marked failed now rather than five times over.
        const permanent = response.status >= 400 && response.status < 500 &&
          response.status !== 429;
        await db
          .from("email_outbox")
          .update({
            status: permanent || row.attempts + 1 >= MAX_ATTEMPTS
              ? "failed"
              : "queued",
            attempts: row.attempts + 1,
            last_error: String(message).slice(0, 500),
          })
          .eq("id", row.id);
        failed++;
        continue;
      }

      await db
        .from("email_outbox")
        .update({
          status: "sent",
          attempts: row.attempts + 1,
          sent_at: new Date().toISOString(),
          provider_id: payload?.id ?? null,
          last_error: null,
        })
        .eq("id", row.id);
      sent++;
    } catch (err) {
      // A network failure is worth retrying; it says nothing about the
      // message.
      await db
        .from("email_outbox")
        .update({
          status: row.attempts + 1 >= MAX_ATTEMPTS ? "failed" : "queued",
          attempts: row.attempts + 1,
          last_error: String(err).slice(0, 500),
        })
        .eq("id", row.id);
      failed++;
    }
  }

  // `scheduler` is reported because the alternative is a silent failure
  // with a long fuse. An unrecognised caller is not refused here — it
  // reads the outbox under its own token, matches no organization, and
  // drains nothing. So a scheduler with the wrong secret returns
  // `considered: 0`, which is exactly what an empty queue returns, and
  // the mail would pile up for weeks behind a green tick.
  return json({ scheduler: isScheduler, considered: rows.length, sent, failed });
});
