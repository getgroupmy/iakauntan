/**
 * Files the consolidated e-Invoices that are coming due, for every
 * company at once.
 *
 * Called on a schedule, and only by the scheduler: the caller proves it
 * is the timer with `SCHEDULER_SECRET` and gets no user session at all.
 * That is the whole reason this is a separate path from `submit` --
 * `buildContext` resolves a signed-in person and checks their
 * membership, and a timer is neither.
 *
 * ## What it is for
 *
 * Under the LHDN guideline a seller aggregates the month's sales to
 * buyers who did not ask for an invoice into one submission, due within
 * seven days of month end. `consolidate_pos_einvoices` gathers them and
 * `prepare_consolidated_einvoice` (0616) turns the gathering into a
 * document. Both were reachable only by somebody pressing a button, on
 * a deadline that falls on the eighth of the month whether or not
 * anybody remembered.
 *
 * ## What it deliberately does not do
 *
 * It does not consolidate. Rolling sales up is `app.run_daily_jobs`'s
 * work and it runs on the first of the month; this files what that
 * produced. Two timers doing one job each, so a failure in either is
 * about one thing.
 *
 * It does not touch a company that cannot submit. A company with no
 * credentials, or filing at 1.1 with no signing certificate, is
 * REPORTED rather than attempted -- an attempt would spend a MyInvois
 * call to be told what the database already knew, and bury the actual
 * problem in a transport error.
 *
 * It does not give up on the batch when one company fails. Every
 * organization is its own try: LHDN being unreachable for one taxpayer,
 * or one company's credentials having expired, must not stop the other
 * nine filing on the last day they can.
 */
import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { requireEnv } from "../_shared/env.ts";
import {
  MyInvoisClient,
  sha256Hex,
  SubmissionDocument,
  toBase64,
} from "../_shared/myinvois.ts";
import { buildUblDocument, EinvoiceLineRow, EinvoiceRow } from "../_shared/ubl.ts";
import { SIGNED_VERSION, signUblJsonDocument } from "../_shared/xades.ts";
import { nextAttempt } from "./retry.ts";

/** One row of `einvoice_consolidations_due`. */
export interface DueRow {
  org_id: string;
  org_name: string;
  consolidation_id: string;
  period_start: string;
  period_end: string;
  due_date: string;
  days_left: number;
  document_count: number;
  total_amount: number;
  status: string;
  einvoice_id: string | null;
  environment: string;
  einvoice_version: string;
  has_credentials: boolean;
  has_certificate: boolean;
}

export type Outcome =
  | { org: string; period: string; skipped: string }
  | { org: string; period: string; submitted: true; uuid: string | null }
  | { org: string; period: string; failed: string };

/**
 * Why this company cannot be filed for, in the words to report — or
 * null.
 *
 * Pure, and exported so it is asserted rather than inferred from a run
 * against MyInvois that nothing here can make. Each sentence names the
 * setup step, because the person who reads this report is the one who
 * has to do it.
 */
export function whyNot(row: DueRow): string | null {
  if (!row.has_credentials) {
    return `no MyInvois ${row.environment} credentials — add them under ` +
      `Settings > LHDN e-Invoice`;
  }
  if (row.einvoice_version === SIGNED_VERSION && !row.has_certificate) {
    return `filing at version ${SIGNED_VERSION} with no signing ` +
      `certificate for ${row.environment} — load one, or set the version ` +
      `back to 1.0`;
  }
  if (row.document_count === 0) {
    return "nothing rolled into it";
  }
  return null;
}

/** The period, as it reads in a report somebody skims. */
export function periodLabel(row: DueRow): string {
  return `${row.period_start} to ${row.period_end}`;
}

async function fileOne(
  admin: SupabaseClient,
  row: DueRow,
): Promise<Outcome> {
  const period = periodLabel(row);

  const { data: prepared, error: prepareError } = await admin.rpc(
    "scheduler_prepare_consolidated_einvoice",
    { p_consolidation_id: row.consolidation_id },
  );
  if (prepareError) {
    return { org: row.org_name, period, failed: prepareError.message };
  }

  const einvoiceId = String(prepared ?? row.einvoice_id ?? "");
  if (!einvoiceId) {
    return { org: row.org_name, period, failed: "nothing was prepared" };
  }

  const { data: doc } = await admin
    .from("einvoice_documents")
    .select("*")
    .eq("id", einvoiceId)
    .maybeSingle();
  if (!doc) {
    return { org: row.org_name, period, failed: "the prepared document vanished" };
  }
  // What this document has already cost. Read off the row this run
  // already fetched; see `retry.ts` for why it is counted at all.
  const attempts = (doc as { retry_count?: number }).retry_count ?? 0;

  const { data: lines } = await admin
    .from("einvoice_lines")
    .select("*")
    .eq("einvoice_id", einvoiceId)
    .order("line_no", { ascending: true });

  const { data: creds } = await admin
    .from("einvoice_credentials")
    .select("client_id, client_secret, cert_pem, cert_private_key_pem")
    .eq("org_id", row.org_id)
    .eq("environment", row.environment)
    .maybeSingle();
  if (!creds) {
    return { org: row.org_name, period, failed: "the credentials vanished" };
  }

  const built = buildUblDocument(
    doc as EinvoiceRow,
    (lines ?? []) as EinvoiceLineRow[],
  );
  let ubl: unknown = built;
  let raw = JSON.stringify(built);
  if (doc.einvoice_version === SIGNED_VERSION) {
    if (!creds.cert_pem || !creds.cert_private_key_pem) {
      return {
        org: row.org_name,
        period,
        failed: "the signing certificate vanished between the check and the send",
      };
    }
    const signed = await signUblJsonDocument(built, {
      certificatePem: creds.cert_pem,
      privateKeyPem: creds.cert_private_key_pem,
    });
    ubl = signed.document;
    raw = signed.minified;
  }

  const hash = await sha256Hex(raw);
  const payload: SubmissionDocument = {
    format: "JSON",
    document: toBase64(raw),
    documentHash: hash,
    codeNumber: doc.internal_doc_no,
  };

  const client = new MyInvoisClient({
    clientId: creds.client_id,
    clientSecret: creds.client_secret,
    environment: row.environment as "sandbox" | "production",
  });

  const { data: submission } = await admin
    .from("einvoice_submissions")
    .insert({
      org_id: row.org_id,
      environment: row.environment,
      document_count: 1,
      status: "in_progress",
      submitted_at: new Date().toISOString(),
    })
    .select()
    .single();

  const { status, data: response } = await client.submitDocuments([payload]);
  const result = response as {
    submissionUid?: string;
    acceptedDocuments?: Array<{ uuid: string; invoiceCodeNumber: string }>;
    rejectedDocuments?: Array<{
      invoiceCodeNumber: string;
      error?: { code?: string; message?: string; details?: unknown };
    }>;
  };
  const accepted = result?.acceptedDocuments ?? [];
  const rejected = result?.rejectedDocuments ?? [];
  const ok = status >= 200 && status < 300 && accepted.length > 0;

  await admin
    .from("einvoice_submissions")
    .update({
      submission_uid: result?.submissionUid ?? null,
      accepted_count: accepted.length,
      rejected_count: rejected.length,
      http_status: status,
      status: ok ? "valid" : "failed",
      response_payload: response as Record<string, unknown>,
      completed_at: new Date().toISOString(),
      error_message: ok ? null : JSON.stringify(response).slice(0, 1000),
    })
    .eq("id", submission!.id);

  if (!ok) {
    const why = rejected[0]?.error?.message ??
      `MyInvois returned HTTP ${status}`;
    await admin
      .from("einvoice_documents")
      .update({
        status: "invalid",
        submission_id: submission!.id,
        last_attempt_at: new Date().toISOString(),
        // Counted here too, for the same reason `submit.ts` counts.
        // The consolidation deliberately stays `generated` so the next
        // run tries again -- see the comment below -- and without a
        // count that is a rejection re-sent on every run until the
        // period closes.
        retry_count: nextAttempt(attempts),
        error_code: rejected[0]?.error?.code ?? null,
        error_message: why,
        validation_errors: rejected[0]?.error?.details ?? [],
      })
      .eq("id", einvoiceId);
    // The consolidation stays `generated`, deliberately. It is still
    // owed, the deadline has not moved, and the next run has to try
    // again rather than treat a rejection as a filing.
    return { org: row.org_name, period, failed: why };
  }

  await admin
    .from("einvoice_documents")
    .update({
      status: "submitted",
      submission_id: submission!.id,
      myinvois_uuid: accepted[0].uuid,
      submitted_at: new Date().toISOString(),
      last_attempt_at: new Date().toISOString(),
      retry_count: 0,
      ubl_payload: ubl as Record<string, unknown>,
      payload_hash: hash,
      validation_errors: [],
      error_code: null,
      error_message: null,
    })
    .eq("id", einvoiceId);

  await admin
    .from("einvoice_consolidations")
    .update({ status: "submitted" })
    .eq("id", row.consolidation_id);

  return {
    org: row.org_name,
    period,
    submitted: true,
    uuid: accepted[0].uuid,
  };
}

/**
 * Files every consolidation due within `within_days`, and every one
 * already late.
 */
export async function fileConsolidations(
  body: Record<string, unknown>,
): Promise<{ considered: number; submitted: number; results: Outcome[] }> {
  const admin = createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
  );

  const withinDays = Number(body.within_days ?? 3);
  const { data, error } = await admin.rpc("einvoice_consolidations_due", {
    p_within_days: Number.isFinite(withinDays) ? withinDays : 3,
  });
  if (error) throw new Error(error.message);

  const due = (data ?? []) as DueRow[];
  const results: Outcome[] = [];

  for (const row of due) {
    const blocked = whyNot(row);
    if (blocked) {
      results.push({
        org: row.org_name,
        period: periodLabel(row),
        skipped: blocked,
      });
      continue;
    }
    try {
      results.push(await fileOne(admin, row));
    } catch (err) {
      // One company's failure is one company's. The next may be filing
      // on the last day it can.
      results.push({
        org: row.org_name,
        period: periodLabel(row),
        failed: (err as Error).message,
      });
    }
  }

  return {
    considered: due.length,
    submitted: results.filter((r) => "submitted" in r).length,
    results,
  };
}
