import { assertEquals, assertExists } from "jsr:@std/assert@1.0.19";
import {
  type AddressJson,
  buildUblDocument,
  type EinvoiceLineRow,
  type EinvoiceRow,
} from "./ubl.ts";

/**
 * What LHDN is sent, and what it rejects.
 *
 * `buildUblDocument` is pure and is the last thing that runs before an
 * invoice leaves for MyInvois. Everything it gets wrong is rejected at
 * validation time or, worse, accepted with the wrong number on it --
 * and neither is visible from the SQL suite, which stops at the
 * `einvoice_documents` row this reads.
 *
 * The assertions below are LHDN's rules rather than this function's
 * habits. A rewrite is free to build the document any way it likes and
 * is not free to drop an identifier, merge two tax types, or send a
 * local time.
 */

const addr: AddressJson = {
  line1: "12 Jalan Satu",
  line2: null,
  line3: null,
  city: "Shah Alam",
  postcode: "40000",
  state: "10",
  country: "MYS",
};

function doc(over: Partial<EinvoiceRow> = {}): EinvoiceRow {
  return {
    id: "d1",
    einvoice_type_code: "01",
    einvoice_version: "1.0",
    internal_doc_no: "INV-001",
    issue_date: "2026-03-04",
    issue_time: "14:30:00",
    currency: "MYR",
    exchange_rate: 1,
    supplier_name: "Kedai Sinar Sdn Bhd",
    supplier_tin: "C1234567890",
    supplier_id_type: "BRN",
    supplier_id_value: "202301234567",
    supplier_sst_no: null,
    supplier_msic_code: "47111",
    supplier_business_activity: "Retail sale in stores",
    supplier_email: "akaun@sinar.test",
    supplier_phone: "+60312345678",
    supplier_address: addr,
    buyer_name: "Puan Aminah",
    buyer_tin: "IG5555555555",
    buyer_id_type: "NRIC",
    buyer_id_value: "900101105555",
    buyer_sst_no: null,
    buyer_email: null,
    buyer_phone: null,
    buyer_address: addr,
    total_excl_tax: 100,
    total_incl_tax: 108,
    total_discount: 0,
    total_tax: 8,
    total_charges: 0,
    rounding_amount: 0,
    payable_amount: 108,
    ...over,
  };
}

function line(over: Partial<EinvoiceLineRow> = {}): EinvoiceLineRow {
  return {
    line_no: 1,
    classification_code: "022",
    description: "Kopi",
    quantity: 2,
    uom_code: "C62",
    unit_price: 50,
    subtotal: 100,
    discount_rate: 0,
    discount_amount: 0,
    total_excl_tax: 100,
    tax_type_code: "02",
    tax_amount: 8,
    tax_exempted_amount: 0,
    tax_exemption_reason: null,
    country_of_origin: "MYS",
    product_tariff_code: null,
    ...over,
  } as EinvoiceLineRow;
}

// The binding puts every element in an array with its text under "_".
// deno-lint-ignore no-explicit-any
const at = (node: any, path: string): any =>
  path.split(".").reduce((n, key) => {
    const next = n?.[key];
    return Array.isArray(next) ? next[0] : next;
  }, node);

// deno-lint-ignore no-explicit-any
const inv = (d: any) => d.Invoice[0];

Deno.test("the three namespace keys and one Invoice root", () => {
  const d = buildUblDocument(doc(), [line()]);
  assertEquals(
    d._D,
    "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2",
  );
  assertExists(d._A);
  assertExists(d._B);
  assertEquals((d.Invoice as unknown[]).length, 1);
});

Deno.test("an absent identifier is NA, never an empty string", () => {
  // MyInvois rejects "" and accepts "NA". A company with no SST
  // registration is the ordinary case, not an edge one.
  const d = buildUblDocument(doc({ supplier_sst_no: null }), [line()]);
  const ids = at(inv(d), "AccountingSupplierParty.Party")
    .PartyIdentification as Record<string, unknown>[];
  const sst = ids.find((i) =>
    // deno-lint-ignore no-explicit-any
    (i.ID as any)[0].schemeID === "SST"
  );
  // deno-lint-ignore no-explicit-any
  assertEquals((sst!.ID as any)[0]._, "NA");
});

Deno.test("both parties carry all four identifications, in order", () => {
  // MyInvois wants TIN, the registration id, SST and TTX on every
  // party, always four, always in this order. A missing one is a
  // rejection at validation; a reordered one is worse, because the
  // schemeID is what names each and a reader going by position gets
  // the SST number as the TIN.
  const d = buildUblDocument(doc(), [line()]);
  // deno-lint-ignore no-explicit-any
  const schemes = (side: string) =>
    (at(inv(d), `${side}.Party`).PartyIdentification as any[])
      .map((i) => i.ID[0].schemeID);

  // The second is the party's OWN id type, so the two differ here and
  // that difference is the point: a company is a BRN and a person is
  // an NRIC.
  assertEquals(schemes("AccountingSupplierParty"), [
    "TIN",
    "BRN",
    "SST",
    "TTX",
  ]);
  assertEquals(schemes("AccountingCustomerParty"), [
    "TIN",
    "NRIC",
    "SST",
    "TTX",
  ]);
});

Deno.test("a party with no id type falls back to BRN", () => {
  const d = buildUblDocument(doc({ buyer_id_type: null }), [line()]);
  // deno-lint-ignore no-explicit-any
  const ids = at(inv(d), "AccountingCustomerParty.Party")
    .PartyIdentification as any[];
  assertEquals(ids[1].ID[0].schemeID, "BRN");
});

Deno.test("only the supplier carries an MSIC classification", () => {
  const d = buildUblDocument(doc(), [line()]);
  assertExists(
    at(inv(d), "AccountingSupplierParty.Party").IndustryClassificationCode,
  );
  // A buyer with an industry code is a document LHDN refuses.
  assertEquals(
    at(inv(d), "AccountingCustomerParty.Party").IndustryClassificationCode,
    undefined,
  );
});

Deno.test("an address with no lines still has one, reading NA", () => {
  const blank: AddressJson = { ...addr, line1: "  ", line2: null, line3: null };
  const d = buildUblDocument(doc({ supplier_address: blank }), [line()]);
  const lines = at(inv(d), "AccountingSupplierParty.Party.PostalAddress")
    .AddressLine as Record<string, unknown>[];
  assertEquals(lines.length, 1);
  // deno-lint-ignore no-explicit-any
  assertEquals((lines[0].Line as any)[0]._, "NA");
});

Deno.test("lines of one tax type roll up into one subtotal", () => {
  const d = buildUblDocument(
    doc({ total_excl_tax: 200, total_tax: 16 }),
    [line(), line({ line_no: 2 })],
  );
  const subs = at(inv(d), "TaxTotal").TaxSubtotal as Record<string, unknown>[];
  assertEquals(subs.length, 1);
  // deno-lint-ignore no-explicit-any
  assertEquals((subs[0].TaxableAmount as any)[0]._, 200);
  // deno-lint-ignore no-explicit-any
  assertEquals((subs[0].TaxAmount as any)[0]._, 16);
});

Deno.test("and two tax types stay two", () => {
  // The control. One subtotal for two rates misstates the return, and
  // a roll-up keyed on the wrong thing looks identical to a correct
  // one until a second rate appears.
  const d = buildUblDocument(
    doc({ total_excl_tax: 200, total_tax: 14 }),
    [line(), line({ line_no: 2, tax_type_code: "01", tax_amount: 6 })],
  );
  const subs = at(inv(d), "TaxTotal").TaxSubtotal as Record<string, unknown>[];
  assertEquals(subs.length, 2);
});

Deno.test("an exempt line carries the category E and a reason", () => {
  const d = buildUblDocument(
    doc({ total_tax: 0 }),
    [line({
      tax_type_code: "E",
      tax_amount: 0,
      tax_exempted_amount: 100,
      tax_exemption_reason: "Schedule A item 12",
    })],
  );
  const cat = at(at(inv(d), "TaxTotal").TaxSubtotal[0], "TaxCategory");
  assertEquals(at(cat, "ID")._, "E");
  assertEquals(at(cat, "TaxExemptionReason")._, "Schedule A item 12");
});

Deno.test("an exempt line with no reason still gets one", () => {
  // MyInvois requires the element whenever the category is E, so an
  // empty reason is a rejection rather than a blank field.
  const d = buildUblDocument(
    doc({ total_tax: 0 }),
    [line({ tax_type_code: "E", tax_amount: 0, tax_exemption_reason: null })],
  );
  const cat = at(at(inv(d), "TaxTotal").TaxSubtotal[0], "TaxCategory");
  assertEquals(at(cat, "TaxExemptionReason")._, "Exempt supply");
});

Deno.test("the tax currency is MYR even when the invoice is not", () => {
  const d = buildUblDocument(doc({ currency: "SGD", exchange_rate: 3.5 }), [
    line(),
  ]);
  assertEquals(at(inv(d), "DocumentCurrencyCode")._, "SGD");
  // LHDN is owed ringgit whatever the invoice is written in.
  assertEquals(at(inv(d), "TaxCurrencyCode")._, "MYR");
  assertEquals(at(inv(d), "TaxExchangeRate.CalculationRate")._, 3.5);
});

Deno.test("and a ringgit invoice carries no exchange rate at all", () => {
  const d = buildUblDocument(doc(), [line()]);
  assertEquals(inv(d).TaxExchangeRate, undefined);
});

Deno.test("a credit note references the invoice it adjusts", () => {
  const d = buildUblDocument(
    doc({
      einvoice_type_code: "02",
      original_doc_no: "INV-001",
      original_uuid: "u-1",
    }),
    [line()],
  );
  const ref = at(inv(d), "BillingReference.InvoiceDocumentReference");
  assertEquals(at(ref, "ID")._, "INV-001");
  assertEquals(at(ref, "UUID")._, "u-1");
});

Deno.test("an ordinary invoice references nothing", () => {
  // The control: a BillingReference on a type 01 is a document about
  // an adjustment that never happened.
  const d = buildUblDocument(
    doc({ original_doc_no: "INV-000", original_uuid: "u-0" }),
    [line()],
  );
  assertEquals(inv(d).BillingReference, undefined);
});

Deno.test("the issue time is sent in UTC with a Z", () => {
  // Malaysia is +08:00 with no DST, so 14:30 local is 06:30 UTC.
  // MyInvois rejects a local time outright.
  const d = buildUblDocument(doc({ issue_time: "14:30:00" }), [line()]);
  assertEquals(at(inv(d), "IssueTime")._, "06:30:00Z");
});

Deno.test("an unparseable time falls back rather than sending rubbish", () => {
  const d = buildUblDocument(doc({ issue_time: "not a time" }), [line()]);
  assertEquals(at(inv(d), "IssueTime")._, "00:00:00Z");
});

Deno.test("money is rounded to the sen and carries its currency", () => {
  const d = buildUblDocument(
    doc({ payable_amount: 108.005, currency: "MYR" }),
    [line()],
  );
  const payable = at(inv(d), "LegalMonetaryTotal").PayableAmount;
  assertEquals(payable[0]._, 108.01);
  assertEquals(payable[0].currencyID, "MYR");
});

Deno.test("a discounted line says so as an allowance, not a charge", () => {
  const d = buildUblDocument(doc(), [
    line({ discount_amount: 10, discount_rate: 10 }),
  ]);
  const ac = at(inv(d).InvoiceLine[0], "AllowanceCharge");
  // ChargeIndicator false is what makes it a discount rather than a
  // surcharge, and the two differ by twenty ringgit on this line.
  assertEquals(at(ac, "ChargeIndicator")._, false);
  assertEquals(at(ac, "Amount")._, 10);
  assertEquals(at(ac, "MultiplierFactorNumeric")._, 0.1);
});

Deno.test("and an undiscounted line carries no allowance", () => {
  const d = buildUblDocument(doc(), [line()]);
  assertEquals(inv(d).InvoiceLine[0].AllowanceCharge, undefined);
});

Deno.test("a tariff code is added beside the classification, not over it", () => {
  const d = buildUblDocument(doc(), [line({ product_tariff_code: "1234.56" })]);
  const cc = at(inv(d).InvoiceLine[0], "Item")
    .CommodityClassification as Record<string, unknown>[];
  assertEquals(cc.length, 2);
  // deno-lint-ignore no-explicit-any
  assertEquals((cc[0].ItemClassificationCode as any)[0].listID, "CLASS");
  // deno-lint-ignore no-explicit-any
  assertEquals((cc[1].ItemClassificationCode as any)[0].listID, "PTC");
});

Deno.test("a line with no unit falls back to C62, which LHDN requires", () => {
  const d = buildUblDocument(doc(), [line({ uom_code: null })]);
  assertEquals(at(inv(d).InvoiceLine[0], "InvoicedQuantity").unitCode, "C62");
});
