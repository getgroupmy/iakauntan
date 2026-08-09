/**
 * Polls MyInvois for validation outcomes and writes back the long ID and
 * QR validation link. MyInvois validates asynchronously, so this is meant
 * to be called repeatedly — from the UI after a submit, or on a schedule.
 *
 * Payload: { einvoice_ids?: string[] }
 */
import { Ctx, loadCredentials, persistLogs } from "../_shared/context.ts";
import { MyInvoisClient, validationLink } from "../_shared/myinvois.ts";

export async function checkStatus(ctx: Ctx) {
  const creds = await loadCredentials(ctx);
  const einvoiceIds = ctx.body.einvoice_ids as string[] | undefined;

  let query = ctx.admin
    .from("einvoice_documents")
    .select("id, myinvois_uuid, internal_doc_no")
    .eq("org_id", ctx.orgId)
    .eq("status", "submitted")
    .not("myinvois_uuid", "is", null)
    .limit(100);

  if (einvoiceIds && einvoiceIds.length > 0) {
    query = query.in("id", einvoiceIds);
  }

  const { data: docs } = await query;
  if (!docs || docs.length === 0) {
    return { checked: 0, message: "No documents awaiting validation" };
  }

  const client = new MyInvoisClient(creds);
  let valid = 0;
  let invalid = 0;
  let pending = 0;

  for (const doc of docs) {
    const { status, data } = await client.getDocumentDetails(doc.myinvois_uuid!);
    if (status < 200 || status >= 300) {
      pending++;
      continue;
    }

    const detail = data as {
      longId?: string;
      status?: string;
      dateTimeValidated?: string;
      validationResults?: { validationSteps?: unknown[] };
    };

    // MyInvois reports Submitted / Valid / Invalid / Cancelled.
    switch ((detail.status ?? "").toLowerCase()) {
      case "valid": {
        const longId = detail.longId ?? "";
        const link = validationLink(creds.environment, doc.myinvois_uuid!, longId);
        await ctx.admin
          .from("einvoice_documents")
          .update({
            status: "valid",
            myinvois_long_id: longId,
            validated_at: detail.dateTimeValidated ?? new Date().toISOString(),
            validation_link: link,
            qr_code_data: link,
            validation_errors: [],
            error_code: null,
            error_message: null,
          })
          .eq("id", doc.id);
        valid++;
        break;
      }
      case "invalid": {
        const steps = (detail.validationResults?.validationSteps ?? []) as Array<
          { status?: string }
        >;
        await ctx.admin
          .from("einvoice_documents")
          .update({
            status: "invalid",
            validation_errors: steps.filter(
              (s) => (s.status ?? "").toLowerCase() !== "valid",
            ),
            error_message: "Rejected at validation by LHDN",
          })
          .eq("id", doc.id);
        invalid++;
        break;
      }
      case "cancelled":
        await ctx.admin
          .from("einvoice_documents")
          .update({ status: "cancelled" })
          .eq("id", doc.id);
        break;
      default:
        pending++;
    }
  }

  await persistLogs(ctx, client.calls);
  return { checked: docs.length, valid, invalid, pending };
}
