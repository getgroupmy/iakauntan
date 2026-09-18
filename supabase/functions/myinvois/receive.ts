/**
 * The half of e-Invoice that receives.
 *
 * `_shared/ubl_parse.ts` can read a MyInvois document and `0650` gives
 * one somewhere to live. This is the join: parse here, store there.
 *
 * ## Why the parse is here and not in the app or in SQL
 *
 * Because it already exists here, tested, and a second implementation
 * of one contract is a contract that drifts -- silently, because both
 * halves go on passing their own tests. `ubl_parse.ts` is asserted
 * against `ubl.ts` by round trip: build a document from a known row,
 * read it back, and every field has to survive. Nothing written in Dart
 * or in plpgsql could be held to that, because the builder is here.
 *
 * ## It writes through the CALLER's client
 *
 * `record_received_einvoice` is SECURITY DEFINER and guards on
 * `app.can_write`, and that guard only means anything if the RPC is
 * called with the caller's own token. `ctx.admin` is the service role
 * and would walk straight past it -- which is exactly the shape of bug
 * that makes an edge function a hole in row level security rather than
 * a door through it.
 *
 * No role check is made here on top of that. `app.can_write` admits a
 * purchaser and a clerk, receiving a supplier's bill is their work, and
 * a stricter rule written in TypeScript would be a rule enforced only
 * in TypeScript.
 *
 * ## Three answers, and they are not the same question
 *
 *   * **problems** -- what the parser could not make sense of. The
 *     document is still stored; a reader decides whether to trust it.
 *   * **totalsProblem** -- whether it ADDS UP, which is asked
 *     separately because a document can be perfectly well formed and
 *     wrong, and the two want different responses.
 *   * **addressedTo** -- whether it was addressed to this company at
 *     all. A supplier sending one company's invoice to another is a
 *     thing that happens, and "it would not import" is the worst way
 *     to find out. So it imports, and says so.
 *
 * ## What this does NOT do
 *
 * It does not FETCH. Retrieving the documents addressed to a company
 * needs a MyInvois endpoint nobody here has called, and a fetcher
 * written against a documented API nobody has exercised is a fetcher
 * nobody has tested. This reads a document once it is in hand, which is
 * already most of the value: a supplier can send the JSON directly and
 * many do.
 */
import { Ctx, HttpError } from "../_shared/context.ts";
import {
  parseUblDocument,
  ReceivedInvoice,
  receivedTotalsProblem,
} from "../_shared/ubl_parse.ts";

/**
 * The largest document this will take, in bytes of JSON.
 *
 * A UBL invoice is a few kilobytes and a long one with a hundred lines
 * is tens. Four megabytes is far past any real document and well under
 * anything that would trouble a `jsonb` column, so it is not a limit
 * anybody will meet by accident -- it is there so that one caller
 * cannot put a hundred megabytes in a row that is then read back by
 * every screen listing what arrived.
 */
export const MAX_DOCUMENT_BYTES = 4 * 1024 * 1024;

/** What `receive` answers with. */
export interface ReceiveResult {
  id: string;
  duplicate: boolean;
  docNo: string | null;
  supplierName: string | null;
  payableAmount: number;
  problems: string[];
  totalsProblem: string | null;
  addressedTo: string | null;
}

/**
 * Read the document out of the request body.
 *
 * Accepts an object or a JSON string, because both are what arrives:
 * an app that has parsed the file sends the first, and one that has
 * merely read it sends the second. A string that will not parse is a
 * refusal rather than an empty document -- there is nothing to store
 * and nothing to describe.
 */
export function documentFromBody(body: Record<string, unknown>): unknown {
  const raw = body.document ?? body.raw;
  if (raw === undefined || raw === null) {
    throw new HttpError(400, "No document was sent");
  }
  if (typeof raw === "string") {
    if (raw.length > MAX_DOCUMENT_BYTES) {
      throw new HttpError(413, "That document is too large to accept");
    }
    try {
      return JSON.parse(raw);
    } catch {
      throw new HttpError(
        400,
        "That file is not JSON. MyInvois documents are the UBL 2.1 JSON " +
          "binding; an XML file has to be converted first.",
      );
    }
  }
  if (typeof raw !== "object") {
    throw new HttpError(400, "The document must be a JSON object");
  }
  return raw;
}

/**
 * The parsed document as the RPC wants it.
 *
 * Spelled out rather than passed through, so that adding a field to
 * `ReceivedInvoice` does not silently start writing it to the database
 * under a name nothing reads. The keys are the interface's own, because
 * `0650` reads them with `->>` by exactly these names.
 */
export function parsedForStorage(doc: ReceivedInvoice): Record<string, unknown> {
  return {
    docNo: doc.docNo,
    issueDate: doc.issueDate,
    issueTime: doc.issueTime,
    typeCode: doc.typeCode,
    version: doc.version,
    currency: doc.currency,
    exchangeRate: doc.exchangeRate,
    supplier: doc.supplier,
    buyer: doc.buyer,
    totalExclTax: doc.totalExclTax,
    totalInclTax: doc.totalInclTax,
    totalDiscount: doc.totalDiscount,
    totalCharges: doc.totalCharges,
    totalTax: doc.totalTax,
    roundingAmount: doc.roundingAmount,
    payableAmount: doc.payableAmount,
    originalDocNo: doc.originalDocNo,
    originalUuid: doc.originalUuid,
    lines: doc.lines,
    problems: doc.problems,
  };
}

/**
 * Whether the document names somebody else as the buyer.
 *
 * Returns the name it WAS addressed to, or null when it is ours or
 * when there is nothing to compare. Both identifiers are compared
 * case-insensitively and trimmed, because a TIN typed into two systems
 * differs by a space more often than by a digit.
 *
 * A document with no buyer TIN is not reported: plenty are issued to a
 * buyer the supplier could not identify, and a warning on every one of
 * those is a warning nobody reads.
 */
export function addressedElsewhere(
  doc: ReceivedInvoice,
  ourTin: string | null | undefined,
): string | null {
  const theirs = doc.buyer.tin?.trim().toUpperCase();
  const ours = ourTin?.trim().toUpperCase();
  if (!theirs || !ours || theirs === ours) return null;
  return doc.buyer.name ?? theirs;
}

/** Parse a document and keep it. */
export async function receiveDocument(ctx: Ctx): Promise<ReceiveResult> {
  const raw = documentFromBody(ctx.body);

  const serialised = JSON.stringify(raw);
  if (serialised.length > MAX_DOCUMENT_BYTES) {
    throw new HttpError(413, "That document is too large to accept");
  }

  const doc = parseUblDocument(raw);

  // The caller's own client, so `app.can_write` is the thing deciding.
  const { data, error } = await ctx.userClient.rpc("record_received_einvoice", {
    p_org_id: ctx.orgId,
    p_parsed: parsedForStorage(doc),
    p_raw: raw,
  });

  if (error) {
    throw new HttpError(
      error.code === "42501" ? 403 : 400,
      error.message ?? "The document could not be stored",
    );
  }

  const row = (data ?? {}) as { id?: string; duplicate?: boolean };
  if (!row.id) {
    throw new HttpError(500, "The document was not stored");
  }

  const { data: org } = await ctx.userClient
    .from("organizations")
    .select("tin")
    .eq("id", ctx.orgId)
    .maybeSingle();

  return {
    id: row.id,
    duplicate: row.duplicate === true,
    docNo: doc.docNo,
    supplierName: doc.supplier.name,
    payableAmount: doc.payableAmount,
    problems: doc.problems,
    totalsProblem: receivedTotalsProblem(doc),
    addressedTo: addressedElsewhere(doc, org?.tin as string | null | undefined),
  };
}
