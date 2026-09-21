/**
 * What was in a submission, without what it weighed.
 *
 * `einvoice_submissions.request_payload` has been a column since
 * `0007`, beside `response_payload`, and only the response was ever
 * written. So a rejected submission recorded the rejection and not the
 * request that caused it -- the one thing anybody wants when LHDN
 * refuses a document and the message is a code.
 *
 * ## Not the documents themselves, and that is the decision
 *
 * A submission carries up to 100 documents and MyInvois caps it at
 * 5 MB, so storing the request verbatim means up to 5 MB of base64 in
 * one jsonb, per submission, for ever. On a company filing a few
 * hundred invoices a month that is the largest table in the database
 * inside a year, holding a second copy of something already stored.
 *
 * Because the documents ARE already stored, one per row, in
 * `einvoice_documents.ubl_payload` with `payload_hash` beside it. What
 * was missing from the submission row is not the bytes -- it is which
 * documents went in this batch, and whether the copy we kept is the
 * copy LHDN hashed.
 *
 * So this is a manifest: the code number, the hash, the format and the
 * size of each document, and nothing that grows with the invoice. Fixed
 * at roughly a hundred bytes per document however large the document.
 *
 * `documentHash` is the load-bearing field. `einvoice_documents.
 * payload_hash` holds the same hash for the document we stored, so a
 * mismatch between the two says the stored UBL is not the one that was
 * submitted -- which is otherwise unanswerable, and is exactly the
 * question a dispute about a rejected e-Invoice turns into.
 */
import { SubmissionDocument } from "../_shared/myinvois.ts";

/** One document's line in the manifest. */
export interface ManifestEntry {
  codeNumber: string;
  documentHash: string;
  format: string;
  /** Bytes of base64 as sent, so a size dispute has a number in it. */
  encodedBytes: number;
}

export interface SubmissionManifest {
  documents: ManifestEntry[];
  documentCount: number;
  /** The whole request as sent, against the 5 MB MyInvois allows. */
  totalEncodedBytes: number;
}

/**
 * The manifest for a batch about to be submitted.
 *
 * Takes what was actually sent rather than what was intended: the same
 * array handed to `submitDocuments`, so the manifest cannot describe a
 * batch that differs from the request.
 */
export function submissionManifest(
  payloads: SubmissionDocument[],
): SubmissionManifest {
  const documents = payloads.map((p) => ({
    codeNumber: p.codeNumber,
    documentHash: p.documentHash,
    format: p.format,
    encodedBytes: p.document.length,
  }));
  return {
    documents,
    documentCount: documents.length,
    totalEncodedBytes: documents.reduce((n, d) => n + d.encodedBytes, 0),
  };
}
