import { assertEquals } from "jsr:@std/assert@1.0.19";
import { submissionManifest } from "./manifest.ts";
import { SubmissionDocument } from "../_shared/myinvois.ts";

// `einvoice_submissions.request_payload` was a column nothing wrote to,
// beside `response_payload` which was written -- so a rejected
// submission recorded the rejection and not the request that caused it.

function doc(
  codeNumber: string,
  body: string,
  documentHash = `hash-${codeNumber}`,
): SubmissionDocument {
  return { format: "JSON", document: body, documentHash, codeNumber };
}

Deno.test("the manifest names every document in the batch", () => {
  const m = submissionManifest([
    doc("INV-1", "aaaa"),
    doc("INV-2", "bbbbbb"),
  ]);

  assertEquals(m.documentCount, 2);
  assertEquals(m.documents.map((d) => d.codeNumber), ["INV-1", "INV-2"]);
});

Deno.test("and carries the hash LHDN was given", () => {
  // The load-bearing field. `einvoice_documents.payload_hash` holds
  // the same hash for the document we stored, so the pair is the only
  // way to say that the copy kept is the copy submitted -- which is
  // what a dispute about a rejected e-Invoice turns into.
  const m = submissionManifest([doc("INV-1", "aaaa", "abc123")]);

  assertEquals(m.documents[0].documentHash, "abc123");
});

Deno.test("and the format, because 1.0 and 1.1 are not the same request", () => {
  const m = submissionManifest([doc("INV-1", "aaaa")]);

  assertEquals(m.documents[0].format, "JSON");
});

Deno.test("it does NOT carry the documents", () => {
  // The decision this module exists for. A submission is up to 100
  // documents and 5 MB, and the documents are already stored one per
  // row in `einvoice_documents.ubl_payload`. A manifest that quietly
  // included the base64 would make this the largest table here inside
  // a year, holding a second copy.
  const body = "QUJDREVGRw".repeat(500);
  const m = submissionManifest([doc("INV-1", body)]);

  assertEquals(JSON.stringify(m).includes(body), false);
  // And the whole manifest stays small whatever the document weighed.
  assertEquals(JSON.stringify(m).length < 200, true);
});

Deno.test("but it does carry the size, so a size dispute has a number", () => {
  const m = submissionManifest([doc("INV-1", "aaaa"), doc("INV-2", "bbbbbb")]);

  assertEquals(m.documents[0].encodedBytes, 4);
  assertEquals(m.documents[1].encodedBytes, 6);
  assertEquals(m.totalEncodedBytes, 10);
});

Deno.test("the total is the batch, against the 5 MB MyInvois allows", () => {
  const m = submissionManifest([
    doc("A", "x".repeat(1000)),
    doc("B", "y".repeat(2000)),
    doc("C", "z".repeat(3000)),
  ]);

  assertEquals(m.totalEncodedBytes, 6000);
  assertEquals(m.documentCount, 3);
});

Deno.test("an empty batch is an empty manifest, not a crash", () => {
  // `submit` returns early on nothing queued, so this should not
  // happen -- and a reduce over an empty array with no initial value
  // throws, which is the shape of mistake that turns a quiet no-op
  // into a 500.
  const m = submissionManifest([]);

  assertEquals(m.documentCount, 0);
  assertEquals(m.totalEncodedBytes, 0);
  assertEquals(m.documents, []);
});

Deno.test("the manifest describes what was SENT, in order", () => {
  // It is built from the same array handed to `submitDocuments`, so it
  // cannot describe a batch that differs from the request. Order
  // matters because MyInvois matches its answers back by code number
  // and a manifest in another order reads as a different batch.
  const payloads = [doc("C-3", "c"), doc("A-1", "a"), doc("B-2", "b")];
  const m = submissionManifest(payloads);

  assertEquals(
    m.documents.map((d) => d.codeNumber),
    payloads.map((p) => p.codeNumber),
  );
});
