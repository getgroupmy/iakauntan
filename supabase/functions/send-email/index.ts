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
 * Called on a schedule by pg_cron and by hand from the outbox screen.
 * Requires the service role key, so a signed-in user cannot invoke it
 * to send arbitrary mail — what they can do is queue a row, which is
 * what `email_document` is for.
 *
 * Secrets, none of which are in the repository:
 *   RESEND_API_KEY   from resend.com, the one thing that can send
 *   MAIL_FROM        the verified sender, e.g. "billing@iakauntan.com"
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, fail, json } from "../_shared/cors.ts";

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
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return fail("Use POST", 405);

  const apiKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("MAIL_FROM");
  if (!apiKey || !from) {
    // Deliberately explicit. The alternative is messages sitting queued
    // with nobody able to say why.
    return fail(
      "Mail is not configured: set RESEND_API_KEY and MAIL_FROM on this " +
        "function before anything can be sent.",
      503,
    );
  }

  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const url = Deno.env.get("SUPABASE_URL");
  if (!serviceKey || !url) return fail("Function is missing its own keys", 500);

  const db = createClient(url, serviceKey, {
    auth: { persistSession: false },
  });

  const body = await req.json().catch(() => ({}));
  const one = typeof body?.id === "string" ? body.id : null;
  const limit = Math.min(Math.max(Number(body?.limit ?? 25), 1), 100);

  let query = db
    .from("email_outbox")
    .select("id, to_email, subject, body, reply_to, from_name, attempts")
    .eq("status", "queued")
    .lt("attempts", MAX_ATTEMPTS)
    .order("queued_at", { ascending: true })
    .limit(one ? 1 : limit);
  if (one) query = query.eq("id", one);

  const { data, error } = await query;
  if (error) return fail(`Could not read the outbox: ${error.message}`, 500);

  const rows = (data ?? []) as OutboxRow[];
  let sent = 0;
  let failed = 0;

  for (const row of rows) {
    try {
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

  return json({ considered: rows.length, sent, failed });
});
