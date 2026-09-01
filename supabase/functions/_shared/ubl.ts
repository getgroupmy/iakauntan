/**
 * Builds a MyInvois UBL 2.1 JSON document from an einvoice_documents row
 * and its lines.
 *
 * MyInvois uses the UBL-2.1-JSON-v2.0 binding: every element is an array
 * of objects, the element's text sits under the "_" key, and attributes
 * sit alongside it. All four document types (invoice, credit note, debit
 * note, refund note) share the Invoice root and are distinguished by
 * InvoiceTypeCode.
 */

export interface EinvoiceRow {
  id: string;
  einvoice_type_code: string;
  einvoice_version: string;
  internal_doc_no: string;
  issue_date: string;
  issue_time: string;
  currency: string;
  exchange_rate: number;
  supplier_name: string;
  supplier_tin: string;
  supplier_id_type: string | null;
  supplier_id_value: string | null;
  supplier_sst_no: string | null;
  supplier_msic_code: string | null;
  supplier_business_activity: string | null;
  supplier_email: string | null;
  supplier_phone: string | null;
  supplier_address: AddressJson;
  buyer_name: string;
  buyer_tin: string;
  buyer_id_type: string | null;
  buyer_id_value: string | null;
  buyer_sst_no: string | null;
  buyer_email: string | null;
  buyer_phone: string | null;
  buyer_address: AddressJson;
  total_excl_tax: number;
  total_incl_tax: number;
  total_discount: number;
  total_tax: number;
  total_charges: number;
  rounding_amount: number;
  payable_amount: number;
  original_doc_no?: string | null;
  original_uuid?: string | null;
}

export interface EinvoiceLineRow {
  line_no: number;
  classification_code: string;
  description: string;
  quantity: number;
  uom_code: string | null;
  unit_price: number;
  subtotal: number;
  discount_rate: number;
  discount_amount: number;
  charge_amount: number;
  tax_type_code: string;
  tax_rate: number;
  tax_amount: number;
  tax_exemption_reason: string | null;
  tax_exempted_amount: number;
  total_excl_tax: number;
  total_incl_tax: number;
  product_tariff_code: string | null;
  country_of_origin: string | null;
}

export interface AddressJson {
  line1?: string | null;
  line2?: string | null;
  line3?: string | null;
  city?: string | null;
  postcode?: string | null;
  state?: string | null;
  country?: string | null;
}

type Node = Record<string, unknown>;

const v = (value: unknown, attrs: Node = {}): Node[] => [{ _: value, ...attrs }];
const money = (amount: number, currency: string): Node[] =>
  [{ _: round2(amount), currencyID: currency }];

function round2(n: number): number {
  return Math.round((Number(n) + Number.EPSILON) * 100) / 100;
}

/** MyInvois wants "NA" rather than an empty string for absent identifiers. */
function na(value: string | null | undefined): string {
  const trimmed = (value ?? "").trim();
  return trimmed === "" ? "NA" : trimmed;
}

function buildAddress(addr: AddressJson): Node[] {
  const lines = [addr.line1, addr.line2, addr.line3]
    .map((l) => (l ?? "").trim())
    .filter((l) => l !== "");
  // At least one AddressLine is mandatory.
  if (lines.length === 0) lines.push("NA");

  return [{
    CityName: v(na(addr.city)),
    PostalZone: v(na(addr.postcode)),
    CountrySubentityCode: v(na(addr.state ?? "17")),
    AddressLine: lines.map((line) => ({ Line: v(line) })),
    Country: [{
      IdentificationCode: v(addr.country || "MYS", {
        listID: "ISO3166-1",
        listAgencyID: "6",
      }),
    }],
  }];
}

function buildParty(
  name: string,
  tin: string,
  idType: string | null,
  idValue: string | null,
  sstNo: string | null,
  address: AddressJson,
  phone: string | null,
  email: string | null,
  msicCode?: string | null,
  businessActivity?: string | null,
): Node {
  const identifications: Node[] = [
    { ID: v(tin, { schemeID: "TIN" }) },
    { ID: v(na(idValue), { schemeID: idType || "BRN" }) },
    { ID: v(na(sstNo), { schemeID: "SST" }) },
    { ID: v("NA", { schemeID: "TTX" }) },
  ];

  const party: Node = {
    PartyIdentification: identifications,
    PostalAddress: buildAddress(address),
    PartyLegalEntity: [{ RegistrationName: v(name) }],
    Contact: [{
      Telephone: v(na(phone)),
      ElectronicMail: v(na(email)),
    }],
  };

  // Only the supplier carries an MSIC industry classification.
  if (msicCode) {
    party.IndustryClassificationCode = v(msicCode, {
      name: businessActivity || "NA",
    });
  }

  return party;
}

/**
 * Tax categories map onto UN/ECE 5153 scheme "OTH", except exemptions
 * which MyInvois codes as "E" and require a reason.
 *
 * `exemptedAmount` is deliberately not emitted. Since `0431` an exempt
 * line's `tax_exempted_amount` is written equal to its taxable amount --
 * `tax_codes.is_exempt` is a boolean, so a partial exemption cannot be
 * expressed -- and `TaxableAmount` already carries that number. The
 * branch that used to substitute one for the other could only ever be a
 * no-op or, if a future writer read LHDN's "Amount Exempted from Tax"
 * as the tax forgone rather than the supply exempted, send 60.00 as the
 * taxable amount of a RM1,000 exempt supply. It is taken as a
 * parameter so the caller still names what it holds.
 */
function buildTaxSubtotal(
  taxableAmount: number,
  taxAmount: number,
  taxTypeCode: string,
  currency: string,
  exemptionReason: string | null,
  _exemptedAmount: number,
): Node {
  const category: Node = {
    ID: v(taxTypeCode),
    TaxScheme: [{
      ID: v("OTH", { schemeID: "UN/ECE 5153", schemeAgencyID: "6" }),
    }],
  };

  if (taxTypeCode === "E") {
    category.TaxExemptionReason = v(exemptionReason || "Exempt supply");
  }

  const subtotal: Node = {
    TaxableAmount: money(taxableAmount, currency),
    TaxAmount: money(taxAmount, currency),
    TaxCategory: [category],
  };

  return subtotal;
}

export function buildUblDocument(
  doc: EinvoiceRow,
  lines: EinvoiceLineRow[],
): Record<string, unknown> {
  const currency = doc.currency || "MYR";
  const isAdjustment = ["02", "03", "04", "12", "13", "14"]
    .includes(doc.einvoice_type_code);

  // Roll the line taxes up into one subtotal per tax type.
  const byTaxType = new Map<string, { taxable: number; tax: number; reason: string | null; exempted: number }>();
  for (const l of lines) {
    const key = l.tax_type_code || "06";
    const acc = byTaxType.get(key) ??
      { taxable: 0, tax: 0, reason: null, exempted: 0 };
    acc.taxable += Number(l.total_excl_tax);
    acc.tax += Number(l.tax_amount);
    acc.exempted += Number(l.tax_exempted_amount ?? 0);
    if (!acc.reason && l.tax_exemption_reason) acc.reason = l.tax_exemption_reason;
    byTaxType.set(key, acc);
  }

  const invoice: Node = {
    ID: v(doc.internal_doc_no),
    IssueDate: v(doc.issue_date),
    // MyInvois requires the issue time in UTC with a trailing Z.
    IssueTime: v(toUtcTime(doc.issue_date, doc.issue_time)),
    InvoiceTypeCode: v(doc.einvoice_type_code, {
      listVersionID: doc.einvoice_version || "1.0",
    }),
    DocumentCurrencyCode: v(currency),
    TaxCurrencyCode: v("MYR"),

    AccountingSupplierParty: [{
      Party: [buildParty(
        doc.supplier_name,
        doc.supplier_tin,
        doc.supplier_id_type,
        doc.supplier_id_value,
        doc.supplier_sst_no,
        doc.supplier_address,
        doc.supplier_phone,
        doc.supplier_email,
        doc.supplier_msic_code,
        doc.supplier_business_activity,
      )],
    }],

    AccountingCustomerParty: [{
      Party: [buildParty(
        doc.buyer_name,
        doc.buyer_tin,
        doc.buyer_id_type,
        doc.buyer_id_value,
        doc.buyer_sst_no,
        doc.buyer_address,
        doc.buyer_phone,
        doc.buyer_email,
      )],
    }],

    TaxTotal: [{
      TaxAmount: money(doc.total_tax, currency),
      TaxSubtotal: Array.from(byTaxType.entries()).map(([code, acc]) =>
        buildTaxSubtotal(acc.taxable, acc.tax, code, currency, acc.reason, acc.exempted)
      ),
    }],

    LegalMonetaryTotal: [{
      LineExtensionAmount: money(doc.total_excl_tax, currency),
      TaxExclusiveAmount: money(doc.total_excl_tax, currency),
      TaxInclusiveAmount: money(doc.total_incl_tax, currency),
      AllowanceTotalAmount: money(doc.total_discount, currency),
      ChargeTotalAmount: money(doc.total_charges, currency),
      PayableRoundingAmount: money(doc.rounding_amount, currency),
      PayableAmount: money(doc.payable_amount, currency),
    }],

    InvoiceLine: lines.map((l) => buildLine(l, currency)),
  };

  // Foreign currency invoices must carry the rate used to convert to MYR.
  if (currency !== "MYR") {
    invoice.TaxExchangeRate = [{
      SourceCurrencyCode: v(currency),
      TargetCurrencyCode: v("MYR"),
      CalculationRate: v(Number(doc.exchange_rate) || 1),
    }];
  }

  // Credit, debit and refund notes must reference the original invoice.
  if (isAdjustment && (doc.original_doc_no || doc.original_uuid)) {
    invoice.BillingReference = [{
      InvoiceDocumentReference: [{
        ID: v(doc.original_doc_no || "NA"),
        UUID: v(doc.original_uuid || "NA"),
      }],
    }];
  }

  return {
    _D: "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2",
    _A: "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2",
    _B: "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2",
    Invoice: [invoice],
  };
}

function buildLine(l: EinvoiceLineRow, currency: string): Node {
  const line: Node = {
    ID: v(String(l.line_no)),
    InvoicedQuantity: [{ _: Number(l.quantity), unitCode: l.uom_code || "C62" }],
    LineExtensionAmount: money(l.total_excl_tax, currency),
    TaxTotal: [{
      TaxAmount: money(l.tax_amount, currency),
      TaxSubtotal: [
        buildTaxSubtotal(
          l.total_excl_tax,
          l.tax_amount,
          l.tax_type_code || "06",
          currency,
          l.tax_exemption_reason,
          l.tax_exempted_amount ?? 0,
        ),
      ],
    }],
    Item: [{
      CommodityClassification: [{
        ItemClassificationCode: v(l.classification_code, { listID: "CLASS" }),
      }],
      Description: v(l.description || "Item"),
      OriginCountry: [{ IdentificationCode: v(l.country_of_origin || "MYS") }],
    }],
    Price: [{ PriceAmount: money(l.unit_price, currency) }],
    ItemPriceExtension: [{ Amount: money(l.subtotal, currency) }],
  };

  if (Number(l.discount_amount) > 0) {
    line.AllowanceCharge = [{
      ChargeIndicator: v(false),
      AllowanceChargeReason: v("Discount"),
      MultiplierFactorNumeric: v(Number(l.discount_rate) / 100),
      Amount: money(l.discount_amount, currency),
    }];
  }

  if (l.product_tariff_code) {
    (line.Item as Node[])[0].CommodityClassification = [
      { ItemClassificationCode: v(l.classification_code, { listID: "CLASS" }) },
      { ItemClassificationCode: v(l.product_tariff_code, { listID: "PTC" }) },
    ];
  }

  return line;
}

/**
 * MyInvois rejects local times. Malaysia has no DST, so the offset is a
 * fixed +08:00 and we can subtract it without a timezone database.
 */
function toUtcTime(issueDate: string, issueTime: string): string {
  const time = (issueTime || "00:00:00").split(".")[0];
  const iso = `${issueDate}T${time}+08:00`;
  const parsed = new Date(iso);
  if (Number.isNaN(parsed.getTime())) return "00:00:00Z";
  return `${parsed.toISOString().split("T")[1].split(".")[0]}Z`;
}
