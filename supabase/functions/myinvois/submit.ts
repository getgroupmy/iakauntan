/**
 * Renders queued e-Invoice documents to UBL 2.1 JSON and submits the
 * batch to MyInvois.
 *
 * Payload: { einvoice_ids?: string[], sales_document_id?: string,
 *            purchase_document_id?: string }
 * With none of them, everything queued for the org is sent, up to the
 * batch cap.
 *
 * `purchase_document_id` is the SELF-BILLED path (0611): the e-Invoice a
 * buyer owes LHDN for a supply the seller cannot file -- a foreign
 * supplier, an unregistered individual. Same submission, different
 * preparation, and the supplier block holds the supplier rather than
 * this company.
 */
import {
  Ctx,
  HttpError,
  loadCredentials,
  loadSigningMaterial,
  persistLogs,
  requirePostingRole,
} from "../_shared/context.ts";
import {
  MyInvoisClient,
  sha256Hex,
  SubmissionDocument,
  toBase64,
} from "../_shared/myinvois.ts";
import { buildUblDocument, EinvoiceLineRow, EinvoiceRow } from "../_shared/ubl.ts";
import { SIGNED_VERSION, signUblJsonDocument } from "../_shared/xades.ts";

// MyInvois caps a submission at 100 documents / 5 MB.
const BATCH_LIMIT = 100;

export async function submit(ctx: Ctx) {
  requirePostingRole(ctx, "submit e-Invoices");

  const salesDocumentId = ctx.body.sales_document_id as string | undefined;
  const purchaseDocumentId = ctx.body.purchase_document_id as
    | string
    | undefined;
  const einvoiceIds = ctx.body.einvoice_ids as string[] | undefined;

  if (salesDocumentId && purchaseDocumentId) {
    throw new HttpError(
      400,
      "Name a sales document or a purchase document, not both",
    );
  }

  // Snapshot the source document first when one was named.
  if (salesDocumentId) {
    const { error } = await ctx.userClient.rpc("prepare_einvoice", {
      p_sales_document_id: salesDocumentId,
    });
    if (error) throw new HttpError(400, `Could not prepare e-Invoice: ${error.message}`);
  }
  if (purchaseDocumentId) {
    const { error } = await ctx.userClient.rpc(
      "prepare_self_billed_einvoice",
      { p_purchase_document_id: purchaseDocumentId },
    );
    if (error) {
      throw new HttpError(
        400,
        `Could not prepare self-billed e-Invoice: ${error.message}`,
      );
    }
  }

  const { data: org } = await ctx.admin
    .from("organizations")
    .select("einvoice_enabled, einvoice_environment")
    .eq("id", ctx.orgId)
    .single();

  if (!org?.einvoice_enabled) {
    throw new HttpError(400, "e-Invoice is not enabled for this organization");
  }

  const creds = await loadCredentials(ctx);

  let query = ctx.admin
    .from("einvoice_documents")
    .select("*")
    .eq("org_id", ctx.orgId)
    .in("status", ["queued", "draft", "failed", "invalid"])
    .limit(BATCH_LIMIT);

  if (einvoiceIds && einvoiceIds.length > 0) {
    query = query.in("id", einvoiceIds);
  } else if (salesDocumentId) {
    query = query
      .eq("source_table", "sales_documents")
      .eq("source_id", salesDocumentId);
  } else if (purchaseDocumentId) {
    query = query
      .eq("source_table", "purchase_documents")
      .eq("source_id", purchaseDocumentId);
  }

  const { data: docs, error: docsError } = await query;
  if (docsError) throw new HttpError(500, docsError.message);
  if (!docs || docs.length === 0) {
    return { submitted: 0, message: "Nothing queued for submission" };
  }

  const client = new MyInvoisClient(creds);

  // A 1.1 document must be signed; a 1.0 one must not be. The version
  // is on each document rather than on the organization, because
  // `prepare_einvoice` snapshots it when the document is prepared —
  // so a company that switches to 1.1 does not retroactively make its
  // queued 1.0 documents invalid.
  const signing = (docs as EinvoiceRow[]).some(
      (d) => d.einvoice_version === SIGNED_VERSION,
    )
    ? await loadSigningMaterial(ctx, creds.environment)
    : null;

  // Before the batch rather than during it. Half a submission is worse
  // than none: the documents already sent are validated and immutable,
  // and the rest come back as "queued" with nothing saying why.
  if (!signing) {
    const unsigned = (docs as EinvoiceRow[]).filter(
      (d) => d.einvoice_version === SIGNED_VERSION,
    );
    if (unsigned.length > 0) {
      const which = unsigned.length === 1
        ? unsigned[0].internal_doc_no
        : `${unsigned.length} documents`;
      throw new HttpError(
        400,
        `${which} must be signed, because they are e-Invoice version ` +
          `${SIGNED_VERSION}, and no signing certificate is loaded for the ` +
          `${creds.environment} environment. Load one under ` +
          `Settings > e-Invoice, or set the version back to 1.0.`,
      );
    }
  }

  // Render every document, keeping the exact payload we hashed so the
  // stored copy always matches what LHDN validated.
  const payloads: SubmissionDocument[] = [];
  const rendered = new Map<string, { ubl: unknown; hash: string }>();

  for (const doc of docs as EinvoiceRow[]) {
    const { data: lines } = await ctx.admin
      .from("einvoice_lines")
      .select("*")
      .eq("einvoice_id", doc.id)
      // Said out loud because the two clients disagree: supabase-js
      // defaults `ascending` to true and postgrest-dart to false. The
      // lines of a document go on the invoice in the order they were
      // written, and LHDN is sent what the customer was sent.
      .order("line_no", { ascending: true });

    const built = buildUblDocument(doc, (lines ?? []) as EinvoiceLineRow[]);

    // The signature is over the FINAL document, and `documentHash`
    // below is over the same bytes — so the signed string is carried
    // forward rather than the object being stringified a second time.
    // Two `JSON.stringify` calls on one object give the same string
    // today; one edit that rebuilds it in between and they do not.
    let ubl: unknown = built;
    let raw = JSON.stringify(built);
    if (doc.einvoice_version === SIGNED_VERSION && signing) {
      const signed = await signUblJsonDocument(built, signing);
      ubl = signed.document;
      raw = signed.minified;
    }
    const hash = await sha256Hex(raw);

    rendered.set(doc.id, { ubl, hash });
    payloads.push({
      format: "JSON",
      document: toBase64(raw),
      documentHash: hash,
      codeNumber: doc.internal_doc_no,
    });
  }

  const { data: submission } = await ctx.admin
    .from("einvoice_submissions")
    .insert({
      org_id: ctx.orgId,
      environment: creds.environment,
      document_count: payloads.length,
      status: "in_progress",
      submitted_at: new Date().toISOString(),
      submitted_by: ctx.userId,
    })
    .select()
    .single();

  const { status, data: response } = await client.submitDocuments(payloads);
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
  const ok = status >= 200 && status < 300;

  await ctx.admin
    .from("einvoice_submissions")
    .update({
      submission_uid: result?.submissionUid ?? null,
      accepted_count: accepted.length,
      rejected_count: rejected.length,
      http_status: status,
      status: !ok
        ? "failed"
        : rejected.length === 0
        ? "valid"
        : accepted.length === 0
        ? "invalid"
        : "partial",
      response_payload: response as Record<string, unknown>,
      completed_at: new Date().toISOString(),
      error_message: ok ? null : JSON.stringify(response).slice(0, 1000),
    })
    .eq("id", submission!.id);

  // MyInvois echoes our document number, which is how we match rows back.
  const byCode = new Map<string, string>();
  for (const doc of docs as EinvoiceRow[]) byCode.set(doc.internal_doc_no, doc.id);

  for (const acc of accepted) {
    const id = byCode.get(acc.invoiceCodeNumber);
    if (!id) continue;
    const r = rendered.get(id);
    await ctx.admin
      .from("einvoice_documents")
      .update({
        status: "submitted",
        submission_id: submission!.id,
        myinvois_uuid: acc.uuid,
        submitted_at: new Date().toISOString(),
        last_attempt_at: new Date().toISOString(),
        ubl_payload: r?.ubl ?? null,
        payload_hash: r?.hash ?? null,
        validation_errors: [],
        error_code: null,
        error_message: null,
      })
      .eq("id", id);
  }

  for (const rej of rejected) {
    const id = byCode.get(rej.invoiceCodeNumber);
    if (!id) continue;
    await ctx.admin
      .from("einvoice_documents")
      .update({
        status: "invalid",
        submission_id: submission!.id,
        last_attempt_at: new Date().toISOString(),
        error_code: rej.error?.code ?? null,
        error_message: rej.error?.message ?? "Rejected by MyInvois",
        validation_errors: rej.error?.details ?? [],
      })
      .eq("id", id);
  }

  // A transport-level failure returns neither list; mark the batch failed
  // so it can be retried rather than silently stranded as "queued".
  if (!ok && accepted.length === 0 && rejected.length === 0) {
    await ctx.admin
      .from("einvoice_documents")
      .update({
        status: "failed",
        last_attempt_at: new Date().toISOString(),
        error_message: `Submission failed with HTTP ${status}`,
      })
      .in("id", Array.from(rendered.keys()));
  }

  await persistLogs(ctx, client.calls, { submissionId: submission!.id });

  if (!ok) {
    throw new HttpError(502, `MyInvois returned HTTP ${status}`, response);
  }

  return {
    submission_id: submission!.id,
    submission_uid: result?.submissionUid ?? null,
    submitted: payloads.length,
    accepted: accepted.length,
    rejected: rejected.length,
    errors: rejected,
  };
}
