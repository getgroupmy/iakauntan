/**
 * Cancels a validated e-Invoice with LHDN.
 *
 * MyInvois only accepts a cancellation within 72 hours of validation;
 * past that the correct remedy is a credit note, so we refuse early with
 * a clear message rather than letting the API reject it.
 *
 * Payload: { einvoice_id, reason }
 */
import {
  Ctx,
  HttpError,
  loadCredentials,
  persistLogs,
  requirePostingRole,
} from "../_shared/context.ts";
import { MyInvoisClient } from "../_shared/myinvois.ts";

export async function cancel(ctx: Ctx) {
  requirePostingRole(ctx, "cancel e-Invoices");

  const einvoiceId = ctx.body.einvoice_id as string | undefined;
  const reason = String(ctx.body.reason ?? "").trim();

  if (!einvoiceId) throw new HttpError(400, "einvoice_id is required");
  if (reason.length < 3) {
    throw new HttpError(400, "A cancellation reason is required by LHDN");
  }

  const { data: doc } = await ctx.admin
    .from("einvoice_documents")
    .select("id, myinvois_uuid, status, cancel_deadline, internal_doc_no")
    .eq("id", einvoiceId)
    .eq("org_id", ctx.orgId)
    .maybeSingle();

  if (!doc) throw new HttpError(404, "e-Invoice not found");
  if (doc.status !== "valid") {
    throw new HttpError(
      400,
      `Only a validated e-Invoice can be cancelled (current status: ${doc.status})`,
    );
  }
  if (!doc.myinvois_uuid) {
    throw new HttpError(400, "This e-Invoice has no MyInvois UUID");
  }
  if (doc.cancel_deadline && new Date(doc.cancel_deadline) < new Date()) {
    throw new HttpError(
      409,
      `The 72-hour cancellation window for ${doc.internal_doc_no} closed on ` +
        `${new Date(doc.cancel_deadline).toISOString()}. Issue a credit note instead.`,
    );
  }

  const creds = await loadCredentials(ctx);
  const client = new MyInvoisClient(creds);

  const { status, data } = await client.setDocumentState(
    doc.myinvois_uuid,
    "cancelled",
    reason.slice(0, 300),
  );

  const ok = status >= 200 && status < 300;

  if (ok) {
    await ctx.admin
      .from("einvoice_documents")
      .update({
        status: "cancelled",
        cancelled_at: new Date().toISOString(),
        cancellation_reason: reason.slice(0, 300),
      })
      .eq("id", einvoiceId);
  }

  await persistLogs(ctx, client.calls, { einvoiceId });

  if (!ok) {
    throw new HttpError(502, "MyInvois rejected the cancellation", data);
  }

  return { cancelled: true, einvoice_id: einvoiceId };
}
