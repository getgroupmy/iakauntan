import { assertEquals, assertNotEquals } from "jsr:@std/assert@1.0.19";
import {
  type AddressJson,
  buildUblDocument,
  type EinvoiceLineRow,
  type EinvoiceRow,
} from "./ubl.ts";
import {
  parseUblDocument,
  receivedTotalsAgree,
  receivedTotalsProblem,
} from "./ubl_parse.ts";

/**
 * Reading a supplier's e-Invoice, and the round trip that proves it.
 *
 * `ubl.ts` writes the MyInvois binding and `ubl_parse.ts` reads it, so
 * the strongest assertion available is that a document survives both:
 * build one from a known row, read it back, and every field has to
 * arrive. That needs no sample from LHDN, no credentials and no
 * sandbox, and it fails the moment either side drifts.
 *
 * The round trip is not the whole of it. It can only ever prove that
 * the two agree with EACH OTHER, so the rest of this file is about a
 * document SOMEBODY ELSE wrote: missing elements, numbers as strings,
 * "NA" where an identifier should be, identifiers in a different order,
 * and a payload that is not a document at all. The parser must not
 * throw on any of them, because the screen that throws is the one that
 * was going to explain what arrived.
 */

const addr: AddressJson = {
  line1: "12 Jalan Satu",
  line2: "Taman Dua",
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
    supplier_sst_no: "W10-1808-32000123",
    supplier_msic_code: "47111",
    supplier_business_activity: "Retail sale in stores",
    supplier_email: "akaun@sinar.test",
    supplier_phone: "+60312345678",
    supplier_address: addr,
    buyer_name: "Bumi Maju Enterprise",
    buyer_tin: "C9999999999",
    buyer_id_type: "BRN",
    buyer_id_value: "202401234567",
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
    charge_amount: 0,
    tax_type_code: "01",
    tax_rate: 8,
    tax_amount: 8,
    tax_exemption_reason: null,
    tax_exempted_amount: 0,
    total_excl_tax: 100,
    total_incl_tax: 108,
    product_tariff_code: null,
    country_of_origin: "MYS",
    ...over,
  };
}

/** Build and read back, which is what most of these assert. */
function roundTrip(
  d: Partial<EinvoiceRow> = {},
  ls: EinvoiceLineRow[] = [line()],
) {
  return parseUblDocument(buildUblDocument(doc(d), ls));
}

// ---------------------------------------------------------------------

Deno.test("the round trip keeps the document's identity", () => {
  const got = roundTrip();
  assertEquals(got.docNo, "INV-001");
  assertEquals(got.issueDate, "2026-03-04");
  assertEquals(got.typeCode, "01");
  assertEquals(got.version, "1.0");
  assertEquals(got.currency, "MYR");
  assertEquals(got.problems, []);
});

Deno.test("the round trip keeps the supplier, which is who the bill is for", () => {
  const { supplier } = roundTrip();
  assertEquals(supplier.name, "Kedai Sinar Sdn Bhd");
  assertEquals(supplier.tin, "C1234567890");
  assertEquals(supplier.idType, "BRN");
  assertEquals(supplier.idValue, "202301234567");
  assertEquals(supplier.sstNo, "W10-1808-32000123");
  assertEquals(supplier.email, "akaun@sinar.test");
  assertEquals(supplier.phone, "+60312345678");
});

Deno.test("and the supplier's address, line by line", () => {
  // The lines arrive as a list with no numbering, so the only thing
  // keeping line 2 out of line 1 is their order.
  const { supplier } = roundTrip();
  assertEquals(supplier.address.line1, "12 Jalan Satu");
  assertEquals(supplier.address.line2, "Taman Dua");
  assertEquals(supplier.address.line3, null);
  assertEquals(supplier.address.city, "Shah Alam");
  assertEquals(supplier.address.postcode, "40000");
  assertEquals(supplier.address.state, "10");
  assertEquals(supplier.address.country, "MYS");
});

Deno.test("the buyer is read from the OTHER party, not the supplier", () => {
  // Both parties are built by the same function into the same shape.
  // Reading the wrong one files every received bill against ourselves.
  const got = roundTrip();
  assertEquals(got.buyer.name, "Bumi Maju Enterprise");
  assertNotEquals(got.buyer.name, got.supplier.name);
});

Deno.test("the round trip keeps the totals", () => {
  const got = roundTrip();
  assertEquals(got.totalExclTax, 100);
  assertEquals(got.totalInclTax, 108);
  assertEquals(got.totalTax, 8);
  assertEquals(got.payableAmount, 108);
});

Deno.test("the round trip keeps the line", () => {
  const [l] = roundTrip().lines;
  assertEquals(l.lineNo, 1);
  assertEquals(l.description, "Kopi");
  assertEquals(l.quantity, 2);
  assertEquals(l.uomCode, "C62");
  assertEquals(l.unitPrice, 50);
  assertEquals(l.totalExclTax, 100);
  assertEquals(l.taxAmount, 8);
  assertEquals(l.taxTypeCode, "01");
  assertEquals(l.classificationCode, "022");
  assertEquals(l.countryOfOrigin, "MYS");
});

Deno.test("the tax RATE is derived, because the binding does not carry it", () => {
  // `ubl.ts` writes amounts and not a percentage. A parser reporting a
  // rate it read from the document would be reporting one that is not
  // there.
  const [l] = roundTrip().lines;
  assertEquals(l.taxRate, 8);
});

Deno.test("and a nil taxable amount does not divide by zero", () => {
  const [l] = roundTrip({}, [
    line({ total_excl_tax: 0, tax_amount: 0, subtotal: 0, quantity: 0 }),
  ]).lines;
  assertEquals(l.taxRate, 0);
});

Deno.test("several lines survive, in order", () => {
  const got = roundTrip({ total_excl_tax: 300, payable_amount: 324 }, [
    line({ line_no: 1, description: "Kopi" }),
    line({ line_no: 2, description: "Teh" }),
    line({ line_no: 3, description: "Roti" }),
  ]);
  assertEquals(got.lines.map((l) => l.description), ["Kopi", "Teh", "Roti"]);
  assertEquals(got.lines.map((l) => l.lineNo), [1, 2, 3]);
});

Deno.test("a discount is read as a discount and not as a charge", () => {
  // Both live in `AllowanceCharge`, told apart only by
  // `ChargeIndicator`. Reading an allowance as a charge adds the
  // discount to the bill instead of taking it off.
  const [l] = roundTrip({}, [
    line({ discount_amount: 10, discount_rate: 10 }),
  ]).lines;
  assertEquals(l.discountAmount, 10);
});

Deno.test("a product tariff code is told apart from the classification", () => {
  // Both are `ItemClassificationCode`, distinguished by `listID`.
  // Reading by position puts the tariff code in the classification
  // field, and LHDN's classification is what decides the tax treatment.
  const [l] = roundTrip({}, [
    line({ classification_code: "022", product_tariff_code: "9999.00.00" }),
  ]).lines;
  assertEquals(l.classificationCode, "022");
  assertEquals(l.productTariffCode, "9999.00.00");
});

Deno.test("an exemption keeps its reason", () => {
  const [l] = roundTrip({ total_tax: 0 }, [
    line({
      tax_type_code: "E",
      tax_amount: 0,
      tax_exemption_reason: "Exempt under Schedule A",
      tax_exempted_amount: 100,
    }),
  ]).lines;
  assertEquals(l.taxTypeCode, "E");
  assertEquals(l.taxExemptionReason, "Exempt under Schedule A");
});

Deno.test("a foreign currency keeps its rate", () => {
  const got = roundTrip({ currency: "USD", exchange_rate: 4.7 });
  assertEquals(got.currency, "USD");
  assertEquals(got.exchangeRate, 4.7);
});

Deno.test("and a ringgit document has a rate of one, not nil", () => {
  // `ubl.ts` writes no `TaxExchangeRate` for MYR. A parser returning 0
  // would multiply every figure on a domestic bill by nothing.
  const got = roundTrip();
  assertEquals(got.exchangeRate, 1);
});

Deno.test("a credit note keeps its reference to the original", () => {
  const got = roundTrip({
    einvoice_type_code: "02",
    original_doc_no: "INV-001",
    original_uuid: "abc-123",
  });
  assertEquals(got.typeCode, "02");
  assertEquals(got.originalDocNo, "INV-001");
  assertEquals(got.originalUuid, "abc-123");
});

// --- a document somebody else wrote -----------------------------------

Deno.test('"NA" comes back as null, not as the string NA', () => {
  // MyInvois wants "NA" rather than an empty string, and `ubl.ts`
  // writes it. A parser that kept it would file a supplier whose SST
  // number is the literal string NA, and that string would reach an
  // invoice.
  const got = roundTrip({ supplier_sst_no: null, buyer_email: null });
  assertEquals(got.supplier.sstNo, null);
  assertEquals(got.buyer.email, null);
});

Deno.test("identifiers are read by scheme, not by position", () => {
  // `ubl.ts` writes four in a fixed order. Another producer need not,
  // and reading by position against theirs puts an SST number in the
  // TIN field.
  const shuffled = {
    Invoice: [{
      ID: [{ _: "INV-9" }],
      AccountingSupplierParty: [{
        Party: [{
          PartyIdentification: [
            { ID: [{ _: "W10-SST", schemeID: "SST" }] },
            { ID: [{ _: "202301234567", schemeID: "BRN" }] },
            { ID: [{ _: "C1234567890", schemeID: "TIN" }] },
          ],
          PartyLegalEntity: [{ RegistrationName: [{ _: "Kedai Sinar" }] }],
        }],
      }],
    }],
  };
  const got = parseUblDocument(shuffled);
  assertEquals(got.supplier.tin, "C1234567890");
  assertEquals(got.supplier.sstNo, "W10-SST");
  assertEquals(got.supplier.idType, "BRN");
  assertEquals(got.supplier.idValue, "202301234567");
});

Deno.test("numbers written as strings are read as numbers", () => {
  // The binding allows either and real documents use both. A figure
  // left as a string propagates into a total as string concatenation.
  const got = parseUblDocument({
    Invoice: [{
      ID: [{ _: "INV-9" }],
      IssueDate: [{ _: "2026-03-04" }],
      AccountingSupplierParty: [{
        Party: [{ PartyLegalEntity: [{ RegistrationName: [{ _: "X" }] }] }],
      }],
      LegalMonetaryTotal: [{
        TaxExclusiveAmount: [{ _: "100.50", currencyID: "MYR" }],
        PayableAmount: [{ _: "108.54", currencyID: "MYR" }],
      }],
      InvoiceLine: [{ ID: [{ _: "1" }] }],
    }],
  });
  assertEquals(got.totalExclTax, 100.5);
  assertEquals(got.payableAmount, 108.54);
});

Deno.test("a number that is not a number is reported, not silently nil", () => {
  const got = parseUblDocument({
    Invoice: [{
      ID: [{ _: "INV-9" }],
      IssueDate: [{ _: "2026-03-04" }],
      AccountingSupplierParty: [{
        Party: [{ PartyLegalEntity: [{ RegistrationName: [{ _: "X" }] }] }],
      }],
      LegalMonetaryTotal: [{ PayableAmount: [{ _: "one hundred" }] }],
      InvoiceLine: [{ ID: [{ _: "1" }] }],
    }],
  });
  assertEquals(got.payableAmount, 0);
  assertEquals(
    got.problems.some((p) => p.includes("payable amount")),
    true,
    `problems were ${JSON.stringify(got.problems)}`,
  );
});

Deno.test("a payload that is not a document is answered, not thrown at", () => {
  for (const bad of [null, undefined, 42, "not json", [], {}]) {
    const got = parseUblDocument(bad);
    assertEquals(got.lines, []);
    assertNotEquals(got.problems.length, 0, `nothing said about ${bad}`);
  }
});

Deno.test("a document with no Invoice element says which element", () => {
  const got = parseUblDocument({ CreditNote: [{}] });
  assertEquals(got.problems.length, 1);
  assertEquals(got.problems[0].includes("No Invoice element"), true);
});

Deno.test("a document naming no supplier says so", () => {
  const got = parseUblDocument({
    Invoice: [{ ID: [{ _: "INV-9" }], IssueDate: [{ _: "2026-03-04" }] }],
  });
  assertEquals(
    got.problems.some((p) => p.includes("names no supplier")),
    true,
    `problems were ${JSON.stringify(got.problems)}`,
  );
});

Deno.test("a document with no lines says so", () => {
  const got = parseUblDocument({ Invoice: [{ ID: [{ _: "INV-9" }] }] });
  assertEquals(
    got.problems.some((p) => p.includes("no lines")),
    true,
    `problems were ${JSON.stringify(got.problems)}`,
  );
});

Deno.test("missing optional elements are null rather than a throw", () => {
  const got = parseUblDocument({
    Invoice: [{
      ID: [{ _: "INV-9" }],
      IssueDate: [{ _: "2026-03-04" }],
      AccountingSupplierParty: [{
        Party: [{ PartyLegalEntity: [{ RegistrationName: [{ _: "X" }] }] }],
      }],
      InvoiceLine: [{ ID: [{ _: "1" }] }],
    }],
  });
  assertEquals(got.supplier.address.city, null);
  assertEquals(got.supplier.phone, null);
  assertEquals(got.buyer.name, null);
  assertEquals(got.lines[0].description, "");
  assertEquals(got.lines[0].uomCode, null);
});

// --- the arithmetic, asked separately ---------------------------------

Deno.test("a document that adds up is said to", () => {
  const got = roundTrip();
  assertEquals(receivedTotalsAgree(got), true);
  assertEquals(receivedTotalsProblem(got), null);
});

Deno.test("one that does not says by how much", () => {
  // A document can be perfectly well formed and not add up. That has to
  // be SHOWN rather than refused, with the difference named, so
  // somebody can decide whether to take it -- and "the totals do not
  // agree" sends them to a calculator while the figures send them to
  // the line that is wrong.
  const got = roundTrip({ total_excl_tax: 250 }, [line()]);
  assertEquals(receivedTotalsAgree(got), false);
  const said = receivedTotalsProblem(got) ?? "";
  assertEquals(said.includes("100.00"), true, said);
  assertEquals(said.includes("250.00"), true, said);
  assertEquals(said.includes("150.00"), true, said);
});

Deno.test("a sen of rounding is tolerated", () => {
  // A supplier's rounding is their own, and the last cent of a
  // fifty-line invoice is not a reason to refuse the bill.
  const got = roundTrip({ total_excl_tax: 100.01 }, [line()]);
  assertEquals(receivedTotalsAgree(got), true);
});

Deno.test("but two sen is not", () => {
  // The tolerance is for rounding, not for a wrong figure.
  const got = roundTrip({ total_excl_tax: 100.02 }, [line()]);
  assertEquals(receivedTotalsAgree(got), false);
});

Deno.test("a document with no lines does not add up", () => {
  const got = parseUblDocument({ Invoice: [{ ID: [{ _: "X" }] }] });
  assertEquals(receivedTotalsAgree(got), false);
  // And says nothing about the arithmetic, because "no lines" is
  // already in `problems` and saying it twice in different words is
  // two faults where there is one.
  assertEquals(receivedTotalsProblem(got), null);
});
