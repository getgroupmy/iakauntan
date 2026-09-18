import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  type AddressJson,
  buildUblDocument,
  type EinvoiceLineRow,
  type EinvoiceRow,
} from "../_shared/ubl.ts";
import { parseUblDocument } from "../_shared/ubl_parse.ts";
import {
  addressedElsewhere,
  documentFromBody,
  MAX_DOCUMENT_BYTES,
  parsedForStorage,
} from "./receive.ts";
import { HttpError } from "../_shared/context.ts";

/**
 * The join between the parser and the table.
 *
 * `receiveDocument` itself needs a Supabase client and a signed-in
 * caller, so what is asserted here is everything AROUND that call --
 * the three pure functions it is made of. Each exists because of a
 * specific way the request can arrive wrong, and each is the kind of
 * thing that would otherwise be found by a supplier's file failing to
 * import with no explanation.
 *
 * The shapes are built with `ubl.ts`, the same builder the parser is
 * asserted against, so a field that moves in the binding moves here
 * too rather than being frozen into a fixture nobody updates.
 */

const addr: AddressJson = {
  line1: "12 Jalan Perusahaan",
  line2: null,
  line3: null,
  city: "Shah Alam",
  postcode: "40000",
  state: "10",
  country: "MYS",
};

function row(over: Partial<EinvoiceRow> = {}): EinvoiceRow {
  return {
    id: "r1",
    einvoice_type_code: "01",
    einvoice_version: "1.1",
    internal_doc_no: "INV-9001",
    issue_date: "2026-03-15",
    issue_time: "10:30:00",
    currency: "MYR",
    exchange_rate: 1,
    supplier_name: "Pembekal Jaya Sdn Bhd",
    supplier_tin: "C1234567890",
    supplier_id_type: "BRN",
    supplier_id_value: "201901234567",
    supplier_sst_no: "W10-1808-31000001",
    supplier_msic_code: "46900",
    supplier_business_activity: "Wholesale",
    supplier_email: "akaun@pembekaljaya.test",
    supplier_phone: "+60312345678",
    supplier_address: addr,
    buyer_name: "Kedai Kita Sdn Bhd",
    buyer_tin: "C9876543210",
    buyer_id_type: "BRN",
    buyer_id_value: "202001234567",
    buyer_sst_no: null,
    buyer_email: null,
    buyer_phone: null,
    buyer_address: addr,
    total_excl_tax: 200,
    total_incl_tax: 212,
    total_discount: 0,
    total_tax: 12,
    total_charges: 0,
    rounding_amount: 0,
    payable_amount: 212,
    ...over,
  } as EinvoiceRow;
}

function lines(): EinvoiceLineRow[] {
  return [
    {
      line_no: 1,
      classification_code: "022",
      description: "Kertas A4 80gsm",
      quantity: 10,
      uom_code: "C62",
      unit_price: 12,
      subtotal: 120,
      discount_rate: 0,
      discount_amount: 0,
      charge_amount: 0,
      tax_type_code: "01",
      tax_rate: 6,
      tax_amount: 7.2,
      tax_exemption_reason: null,
      tax_exempted_amount: 0,
      total_excl_tax: 120,
      total_incl_tax: 127.2,
      product_tariff_code: null,
      country_of_origin: "MYS",
    } as EinvoiceLineRow,
  ];
}

function parsed(over: Partial<EinvoiceRow> = {}) {
  return parseUblDocument(buildUblDocument(row(over), lines()));
}

Deno.test("a document sent as an object arrives as one", () => {
  const doc = { Invoice: [{ ID: [{ _: "INV-1" }] }] };
  assertEquals(documentFromBody({ document: doc }), doc);
});

Deno.test("a document sent as a JSON string is parsed", () => {
  // Both arrive in practice: an app that has decoded the file sends an
  // object, one that has merely read it sends the text.
  const doc = { Invoice: [{ ID: [{ _: "INV-1" }] }] };
  assertEquals(documentFromBody({ document: JSON.stringify(doc) }), doc);
});

Deno.test("`raw` is accepted as well as `document`", () => {
  assertEquals(documentFromBody({ raw: { a: 1 } }), { a: 1 });
});

Deno.test("a file that is not JSON says what it should have been", () => {
  // The likeliest wrong file by a wide margin is the XML binding, and
  // "unexpected token" would send somebody to the wrong problem.
  const e = assertThrows(
    () => documentFromBody({ document: "<Invoice><ID>1</ID></Invoice>" }),
    HttpError,
  ) as HttpError;
  assertEquals(e.status, 400);
  assertEquals(e.message.includes("UBL 2.1 JSON"), true);
  assertEquals(e.message.includes("XML"), true);
});

Deno.test("no document at all is refused rather than stored empty", () => {
  for (const body of [{}, { document: null }]) {
    const e = assertThrows(() => documentFromBody(body), HttpError) as HttpError;
    assertEquals(e.status, 400);
  }
});

Deno.test("a document that is a number is refused", () => {
  const e = assertThrows(
    () => documentFromBody({ document: 42 }),
    HttpError,
  ) as HttpError;
  assertEquals(e.status, 400);
});

Deno.test("an enormous document is refused with 413, not stored", () => {
  // One caller must not be able to put a hundred megabytes in a row
  // that every screen listing what arrived then reads back.
  const e = assertThrows(
    () => documentFromBody({ document: "x".repeat(MAX_DOCUMENT_BYTES + 1) }),
    HttpError,
  ) as HttpError;
  assertEquals(e.status, 413);
});

Deno.test("and a real document is nowhere near the limit", () => {
  // The positive control for the limit above: a refusal nobody can
  // trip over by accident is only a refusal if a real document passes.
  const size = JSON.stringify(buildUblDocument(row(), lines())).length;
  assertEquals(size < MAX_DOCUMENT_BYTES / 100, true);
});

Deno.test("the stored payload carries every field the RPC reads", () => {
  // `0650` reads these with `->>` by exactly these names. Spelled out
  // rather than passed through, so a field added to ReceivedInvoice
  // cannot start silently writing itself under a name nothing reads --
  // and so a field REMOVED here fails this assertion rather than
  // quietly storing null.
  const stored = parsedForStorage(parsed());
  for (
    const key of [
      "docNo",
      "issueDate",
      "issueTime",
      "typeCode",
      "version",
      "currency",
      "exchangeRate",
      "supplier",
      "buyer",
      "totalExclTax",
      "totalInclTax",
      "totalDiscount",
      "totalCharges",
      "totalTax",
      "roundingAmount",
      "payableAmount",
      "originalDocNo",
      "originalUuid",
      "lines",
      "problems",
    ]
  ) {
    assertEquals(key in stored, true, `${key} is not stored`);
  }
});

Deno.test("and the values survive the round trip to storage", () => {
  const stored = parsedForStorage(parsed());
  assertEquals(stored.docNo, "INV-9001");
  assertEquals(stored.issueDate, "2026-03-15");
  assertEquals(stored.typeCode, "01");
  assertEquals(stored.payableAmount, 212);
  assertEquals((stored.supplier as { tin: string }).tin, "C1234567890");
  assertEquals((stored.lines as unknown[]).length, 1);
});

Deno.test("a document addressed to somebody else is named, not refused", () => {
  // A supplier sending one company's invoice to another happens, and
  // "it would not import" is the worst way to find out. So it imports
  // and says who it was for.
  assertEquals(addressedElsewhere(parsed(), "C1111111111"), "Kedai Kita Sdn Bhd");
});

Deno.test("our own document raises nothing", () => {
  assertEquals(addressedElsewhere(parsed(), "C9876543210"), null);
});

Deno.test("a TIN differing only by case or spaces is ours", () => {
  // Typed into two systems, a TIN differs by a space far more often
  // than by a digit, and a warning on every one of those is a warning
  // nobody reads.
  assertEquals(addressedElsewhere(parsed(), "  c9876543210 "), null);
});

Deno.test("nothing to compare against reports nothing", () => {
  // A company that has not filled in its own TIN, and a document whose
  // issuer could not identify the buyer. Both are ordinary.
  assertEquals(addressedElsewhere(parsed(), null), null);
  assertEquals(addressedElsewhere(parsed(), ""), null);
  assertEquals(addressedElsewhere(parsed({ buyer_tin: "NA" }), "C9876543210"), null);
});

Deno.test("a buyer with no name falls back to the TIN it names", () => {
  // The warning has to identify SOMEBODY, and an unnamed buyer with a
  // TIN is still a document addressed elsewhere.
  const doc = parsed({ buyer_name: "" });
  doc.buyer.name = null;
  assertEquals(addressedElsewhere(doc, "C1111111111"), "C9876543210");
});
