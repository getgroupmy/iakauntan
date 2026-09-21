/**
 * Reads a MyInvois UBL 2.1 JSON document into the fields of a bill.
 *
 * The other direction from `ubl.ts`, and the half this product has never
 * had: `einvoice_*` is entirely outbound. The OCA audit's A17 puts it
 * fourth of ten and says why — MyInvois makes every supplier send one,
 * so receiving is the half that removes the most typing.
 *
 * ## JSON, not XML
 *
 * The audit calls this "UBL 2.1", which usually means XML. MyInvois uses
 * the UBL-2.1-**JSON**-v2.0 binding: every element is an ARRAY of
 * objects, the element's text sits under `_`, and attributes sit beside
 * it. `ubl.ts` writes exactly that, so this reads exactly that, and the
 * two can be tested against each other — build a document, read it back,
 * and the fields must survive. That round trip is the strongest
 * assertion available here, because it needs no sample from LHDN and no
 * credentials.
 *
 * ## Defensive in a way `ubl.ts` does not have to be
 *
 * The builder writes a document from our own rows and may assume them.
 * This reads a document SOMEBODY ELSE WROTE. Every difference follows
 * from that:
 *
 *   * **Nothing throws.** A malformed document returns what could be
 *     read plus a list of problems. A parser that throws takes out the
 *     screen that was going to show the supplier what arrived, which is
 *     the one place the trouble could have been explained.
 *   * **"NA" comes back as null.** MyInvois wants "NA" rather than an
 *     empty string for an absent identifier, and `ubl.ts` writes it. A
 *     parser that did not undo it would file a supplier whose SST
 *     number is the literal string NA, and that string would go onto
 *     documents.
 *   * **Numbers may be strings.** The binding allows either and real
 *     documents use both.
 *
 * ## What this does NOT do
 *
 * It does not FETCH anything. Retrieving documents addressed to a
 * company needs live MyInvois credentials and a sandbox, neither of
 * which is reachable from here, and a fetcher written against a
 * documented API nobody has called is a fetcher nobody has tested. This
 * reads a document once it is in hand — which is already useful, because
 * a supplier can send the JSON directly and many do.
 */

/** One line of a received document. */
export interface ReceivedLine {
  lineNo: number;
  classificationCode: string | null;
  description: string;
  quantity: number;
  uomCode: string | null;
  unitPrice: number;
  discountAmount: number;
  taxTypeCode: string | null;
  taxRate: number;
  taxAmount: number;
  taxExemptionReason: string | null;
  totalExclTax: number;
  totalInclTax: number;
  productTariffCode: string | null;
  countryOfOrigin: string | null;
}

/** A party, as far as the document names one. */
export interface ReceivedParty {
  name: string | null;
  tin: string | null;
  idType: string | null;
  idValue: string | null;
  sstNo: string | null;
  email: string | null;
  phone: string | null;
  address: {
    line1: string | null;
    line2: string | null;
    line3: string | null;
    city: string | null;
    postcode: string | null;
    state: string | null;
    country: string | null;
  };
}

/** Everything read out of one document. */
export interface ReceivedInvoice {
  docNo: string | null;
  issueDate: string | null;
  issueTime: string | null;
  typeCode: string | null;
  version: string | null;
  currency: string;
  exchangeRate: number;
  supplier: ReceivedParty;
  buyer: ReceivedParty;
  totalExclTax: number;
  totalInclTax: number;
  totalDiscount: number;
  totalCharges: number;
  totalTax: number;
  roundingAmount: number;
  payableAmount: number;
  originalDocNo: string | null;
  originalUuid: string | null;
  lines: ReceivedLine[];
  /**
   * What is wrong with the document, in the words of somebody who has to
   * decide whether to trust it.
   *
   * Empty is not a promise that the figures are right — only that
   * nothing structural was missing. `receivedTotalsAgree` is the
   * arithmetic question and it is asked separately, because a document
   * can be perfectly well formed and not add up.
   */
  problems: string[];
}

// ---------------------------------------------------------------------
// Reading the binding
// ---------------------------------------------------------------------

type Node = Record<string, unknown>;

/** The first object under an element name, or null. */
function node(parent: unknown, name: string): Node | null {
  if (parent === null || typeof parent !== "object") return null;
  const raw = (parent as Node)[name];
  if (!Array.isArray(raw) || raw.length === 0) return null;
  const first = raw[0];
  return first !== null && typeof first === "object" ? first as Node : null;
}

/** Every object under an element name. */
function nodes(parent: unknown, name: string): Node[] {
  if (parent === null || typeof parent !== "object") return [];
  const raw = (parent as Node)[name];
  if (!Array.isArray(raw)) return [];
  return raw.filter((n): n is Node => n !== null && typeof n === "object");
}

/**
 * The text of an element.
 *
 * "NA" becomes null. That is not a convenience: `ubl.ts` writes "NA"
 * wherever MyInvois refuses an empty string, and every other producer
 * does the same because the schema requires it. A parser that kept it
 * would put the string NA into a supplier's SST number, from where it
 * would reach an invoice.
 */
export function text(parent: unknown, name: string): string | null {
  const n = node(parent, name);
  if (n === null) return null;
  const raw = n["_"];
  if (raw === null || raw === undefined) return null;
  const s = String(raw).trim();
  if (s === "" || s === "NA") return null;
  return s;
}

/**
 * The number in an element, or 0.
 *
 * Zero rather than null, because every caller of this is a money or
 * quantity field where absent and nil mean the same thing to the
 * arithmetic — and a null propagating into a total produces `NaN`,
 * which reaches a screen as the word NaN beside a supplier's name.
 *
 * A value that is present and NOT a number is a different matter: it is
 * recorded as a problem by [parseUblDocument] rather than quietly
 * becoming 0.
 */
export function num(parent: unknown, name: string): number {
  const n = node(parent, name);
  if (n === null) return 0;
  const raw = n["_"];
  if (raw === null || raw === undefined || raw === "") return 0;
  const value = Number(raw);
  return Number.isFinite(value) ? value : 0;
}

/** Whether an element is present but unreadable as a number. */
function isBadNumber(parent: unknown, name: string): boolean {
  const n = node(parent, name);
  if (n === null) return false;
  const raw = n["_"];
  if (raw === null || raw === undefined || raw === "") return false;
  return !Number.isFinite(Number(raw));
}

/** An attribute on an element, such as `currencyID` or `schemeID`. */
export function attr(
  parent: unknown,
  name: string,
  attribute: string,
): string | null {
  const n = node(parent, name);
  if (n === null) return null;
  const raw = n[attribute];
  if (raw === null || raw === undefined) return null;
  const s = String(raw).trim();
  return s === "" || s === "NA" ? null : s;
}

// ---------------------------------------------------------------------
// The parties
// ---------------------------------------------------------------------

/**
 * The identifiers, which arrive as a LIST of `ID` elements distinguished
 * only by their `schemeID`.
 *
 * `ubl.ts` writes four in a fixed order — TIN, then BRN or whichever id
 * type, then SST, then TTX — and reading them by POSITION would work
 * against our own documents and fail against everybody else's. They are
 * read by scheme.
 */
function identifiers(party: Node): Map<string, string> {
  const out = new Map<string, string>();
  for (const block of nodes(party, "PartyIdentification")) {
    const scheme = attr(block, "ID", "schemeID");
    const value = text(block, "ID");
    if (scheme && value && !out.has(scheme)) out.set(scheme, value);
  }
  return out;
}

function parseParty(holder: Node | null): ReceivedParty {
  const empty: ReceivedParty = {
    name: null,
    tin: null,
    idType: null,
    idValue: null,
    sstNo: null,
    email: null,
    phone: null,
    address: {
      line1: null,
      line2: null,
      line3: null,
      city: null,
      postcode: null,
      state: null,
      country: null,
    },
  };
  if (holder === null) return empty;
  const party = node(holder, "Party");
  if (party === null) return empty;

  const ids = identifiers(party);
  // Whichever scheme is not one of the three known ones is the
  // registration identifier: BRN for a company, NRIC for a person,
  // PASSPORT or ARMY for the rest. Taking "the second one" would be
  // reading by position again.
  const idType = [...ids.keys()].find(
    (k) => k !== "TIN" && k !== "SST" && k !== "TTX",
  ) ?? null;

  const address = node(party, "PostalAddress");
  const lines = nodes(address, "AddressLine")
    .map((l) => text(l, "Line"))
    .filter((l): l is string => l !== null);

  const contact = node(party, "Contact");
  const legal = node(party, "PartyLegalEntity");

  return {
    name: text(legal, "RegistrationName"),
    tin: ids.get("TIN") ?? null,
    idType,
    idValue: idType ? ids.get(idType) ?? null : null,
    sstNo: ids.get("SST") ?? null,
    email: text(contact, "ElectronicMail"),
    phone: text(contact, "Telephone"),
    address: {
      line1: lines[0] ?? null,
      line2: lines[1] ?? null,
      line3: lines[2] ?? null,
      city: text(address, "CityName"),
      postcode: text(address, "PostalZone"),
      state: text(address, "CountrySubentityCode"),
      country: text(node(address, "Country"), "IdentificationCode"),
    },
  };
}

// ---------------------------------------------------------------------
// The document
// ---------------------------------------------------------------------

/**
 * Reads one document. Never throws.
 *
 * `raw` is whatever arrived: a parsed object, or something that is not
 * one at all. Both are answered with a result carrying `problems`.
 */
export function parseUblDocument(raw: unknown): ReceivedInvoice {
  const problems: string[] = [];
  const blank = parseParty(null);

  const empty = (why: string): ReceivedInvoice => ({
    docNo: null,
    issueDate: null,
    issueTime: null,
    typeCode: null,
    version: null,
    currency: "MYR",
    exchangeRate: 1,
    supplier: blank,
    buyer: blank,
    totalExclTax: 0,
    totalInclTax: 0,
    totalDiscount: 0,
    totalCharges: 0,
    totalTax: 0,
    roundingAmount: 0,
    payableAmount: 0,
    originalDocNo: null,
    originalUuid: null,
    lines: [],
    problems: [why],
  });

  if (raw === null || typeof raw !== "object") {
    return empty("This is not a document: the payload is not an object.");
  }

  const invoice = node(raw, "Invoice");
  if (invoice === null) {
    return empty(
      "No Invoice element. A MyInvois document has one, whatever its " +
        "type code — a credit note is an Invoice with a different " +
        "InvoiceTypeCode.",
    );
  }

  const docNo = text(invoice, "ID");
  if (docNo === null) {
    problems.push("The document has no number, so it cannot be referred to.");
  }

  const issueDate = text(invoice, "IssueDate");
  if (issueDate === null) {
    problems.push("The document has no issue date.");
  }

  const supplier = parseParty(node(invoice, "AccountingSupplierParty"));
  if (supplier.name === null && supplier.tin === null) {
    problems.push(
      "The document names no supplier — neither a registration name nor " +
        "a TIN — so there is nobody to record the bill against.",
    );
  }

  const currency = text(invoice, "DocumentCurrencyCode") ?? "MYR";
  const totals = node(invoice, "LegalMonetaryTotal");
  if (totals === null) {
    problems.push("The document carries no totals (LegalMonetaryTotal).");
  }

  for (const [where, holder, name] of [
    ["the payable amount", totals, "PayableAmount"],
    ["the tax-exclusive total", totals, "TaxExclusiveAmount"],
    ["the tax-inclusive total", totals, "TaxInclusiveAmount"],
  ] as const) {
    if (isBadNumber(holder, name)) {
      problems.push(`${where} is present but is not a number.`);
    }
  }

  const rate = node(invoice, "TaxExchangeRate");
  const lines = nodes(invoice, "InvoiceLine").map(parseLine);
  if (lines.length === 0) {
    problems.push("The document has no lines.");
  }

  const reference = node(node(invoice, "BillingReference"), "InvoiceDocumentReference");

  return {
    docNo,
    issueDate,
    issueTime: text(invoice, "IssueTime"),
    typeCode: text(invoice, "InvoiceTypeCode"),
    version: attr(invoice, "InvoiceTypeCode", "listVersionID"),
    currency,
    // Only present on a foreign-currency document, and 1 is right for
    // the rest — a ringgit invoice with no rate is not a fault.
    exchangeRate: rate === null ? 1 : num(rate, "CalculationRate") || 1,
    supplier,
    buyer: parseParty(node(invoice, "AccountingCustomerParty")),
    totalExclTax: num(totals, "TaxExclusiveAmount"),
    totalInclTax: num(totals, "TaxInclusiveAmount"),
    totalDiscount: num(totals, "AllowanceTotalAmount"),
    totalCharges: num(totals, "ChargeTotalAmount"),
    totalTax: num(node(invoice, "TaxTotal"), "TaxAmount"),
    roundingAmount: num(totals, "PayableRoundingAmount"),
    payableAmount: num(totals, "PayableAmount"),
    originalDocNo: text(reference, "ID"),
    originalUuid: text(reference, "UUID"),
    lines,
    problems,
  };
}

function parseLine(line: Node): ReceivedLine {
  const item = node(line, "Item");
  const quantity = node(line, "InvoicedQuantity");

  // The classifications arrive as a list distinguished by `listID`:
  // CLASS is LHDN's own classification and PTC is the product tariff
  // code. Read by listID rather than by position, for the reason
  // `identifiers` gives.
  let classificationCode: string | null = null;
  let productTariffCode: string | null = null;
  for (const c of nodes(item, "CommodityClassification")) {
    const listId = attr(c, "ItemClassificationCode", "listID");
    const value = text(c, "ItemClassificationCode");
    if (value === null) continue;
    if (listId === "PTC") productTariffCode ??= value;
    else classificationCode ??= value;
  }

  const taxTotal = node(line, "TaxTotal");
  const subtotal = node(taxTotal, "TaxSubtotal");
  const category = node(subtotal, "TaxCategory");
  const taxableAmount = num(subtotal, "TaxableAmount");
  const taxAmount = num(taxTotal, "TaxAmount");

  // Discounts and charges share one element, told apart by
  // `ChargeIndicator`. Reading an allowance as a charge would add a
  // discount to the bill instead of taking it off.
  let discountAmount = 0;
  for (const ac of nodes(line, "AllowanceCharge")) {
    const isCharge = String(node(ac, "ChargeIndicator")?.["_"] ?? "false") ===
      "true";
    if (!isCharge) discountAmount += num(ac, "Amount");
  }

  const totalExclTax = num(line, "LineExtensionAmount");

  return {
    lineNo: Number(text(line, "ID") ?? "0") || 0,
    classificationCode,
    description: text(item, "Description") ?? "",
    quantity: quantity === null ? 0 : Number(quantity["_"] ?? 0) || 0,
    uomCode: attr(line, "InvoicedQuantity", "unitCode"),
    unitPrice: num(node(line, "Price"), "PriceAmount"),
    discountAmount,
    taxTypeCode: text(category, "ID"),
    // DERIVED, because the binding does not carry a rate on the line.
    // `ubl.ts` writes the amounts and not the percentage, so a parser
    // that reported a rate read from the document would be reporting
    // one that is not there.
    taxRate: taxableAmount === 0
      ? 0
      : round2((taxAmount / taxableAmount) * 100),
    taxAmount,
    taxExemptionReason: text(category, "TaxExemptionReason"),
    totalExclTax,
    totalInclTax: round2(totalExclTax + taxAmount),
    productTariffCode,
    countryOfOrigin: text(node(item, "OriginCountry"), "IdentificationCode"),
  };
}

function round2(n: number): number {
  return Math.round((Number(n) + Number.EPSILON) * 100) / 100;
}

/**
 * Whether the document's own totals agree with its lines.
 *
 * Asked separately from parsing, because a document can be perfectly
 * well formed and not add up — and the two failures want different
 * answers. A document that will not parse cannot be shown; a document
 * that does not add up must be shown, with the difference named, so
 * somebody can decide whether to take it.
 *
 * Tolerant to the sen, because a supplier's rounding is their own and
 * the last cent of a fifty-line invoice is not a reason to refuse it.
 */
export function receivedTotalsAgree(
  doc: ReceivedInvoice,
  tolerance = 0.01,
): boolean {
  if (doc.lines.length === 0) return false;
  const lineTotal = doc.lines.reduce((sum, l) => sum + l.totalExclTax, 0);
  // The DIFFERENCE is rounded, not only the two sides. Rounding each
  // side and subtracting leaves the binary residue in the answer:
  // 100.01 less 100 is 0.010000000000005 in IEEE 754, which is greater
  // than a tolerance of 0.01, so a one-sen rounding was refused as a
  // wrong figure. Found by the assertion for exactly that case.
  return round2(Math.abs(round2(lineTotal) - round2(doc.totalExclTax))) <=
    tolerance;
}

/**
 * What to say about a document that does not add up.
 *
 * Null when it does. The figures are in the message because "the totals
 * do not agree" sends somebody to a calculator; the difference sends
 * them to the line that is wrong.
 */
export function receivedTotalsProblem(doc: ReceivedInvoice): string | null {
  if (doc.lines.length === 0) return null;
  if (receivedTotalsAgree(doc)) return null;
  const lineTotal = round2(
    doc.lines.reduce((sum, l) => sum + l.totalExclTax, 0),
  );
  const stated = round2(doc.totalExclTax);
  return `The lines add up to ${lineTotal.toFixed(2)} but the document ` +
    `states ${stated.toFixed(2)}, a difference of ` +
    `${Math.abs(round2(lineTotal - stated)).toFixed(2)}.`;
}
