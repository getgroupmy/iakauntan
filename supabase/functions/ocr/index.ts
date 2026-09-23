/**
 * ocr
 *
 * Reads a receipt or a bill that has already been filed as an
 * attachment, and hands back the fields somebody would otherwise retype.
 *
 * POST { "org_id": "<uuid>", "attachment_id": "<uuid>" }
 *   -> { scan_id, provider, charged, extraction: { … } }
 *
 * Three decisions are made in the database, not here, and this function
 * cannot override any of them:
 *
 *   * whether the organization has switched scanning on at all;
 *   * which reader, which protocol it speaks, where to reach it, and
 *     whose key;
 *   * whether there is credit to pay for it.
 *
 * `public.ocr_begin` answers all three under the *caller's* token, so
 * the permission that matters is theirs and not this function's, and it
 * takes the charge before a byte leaves the building. If anything below
 * fails, `public.ocr_finish` gives the charge back. Neither of those is
 * reachable from a browser: begin needs `can_write` on the organization,
 * and finish is granted to the service role alone, because finish is
 * what refunds.
 *
 * ---------------------------------------------------------------------
 * Why raw HTTP rather than a provider SDK
 *
 * Every reader is called with `fetch`, as Resend, MyInvois and Bank
 * Negara are elsewhere in this directory. With four protocols and a
 * catalog that can grow, an SDK per vendor would be four cold-start
 * costs and four release cadences to track; the wire formats are stable
 * and documented, and `anthropic-version: 2023-06-01` pins one of them
 * explicitly where an unpinned `npm:` specifier would let a library
 * release change what a deployed function does without a commit.
 *
 * Secrets, none of which are in the repository or in the database, and
 * only needed for organizations using the platform's key rather than
 * their own:
 *   OCR_KEY_<CODE>            the platform's key for that reader, by its
 *                             catalog code: OCR_KEY_CLAUDE, OCR_KEY_OPENAI,
 *                             OCR_KEY_GROK, and so on for whatever is
 *                             added next
 *   OCR_GOOGLE_CREDENTIALS    the platform's service account JSON
 *   OCR_GOOGLE_PROJECT        its project id
 *   OCR_GOOGLE_LOCATION       e.g. "us" or "eu"
 *   OCR_GOOGLE_PROCESSOR      the Document AI processor id
 *
 * `OCR_ANTHROPIC_API_KEY` from before the catalog existed is still read
 * as a fallback for Claude.
 */
import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { fail, json, logFailure, serveFunction } from "../_shared/cors.ts";
import { googleAccessToken, ServiceAccount } from "../_shared/google_auth.ts";
import { poolProblem } from "./pool.ts";
import { ReaderRefusal, withOneRetry } from "./retry.ts";
import {
  type ScanTarget,
  requiredWith,
  targetPrompt,
  targetSchema,
  usableTargets,
} from "./targets.ts";

const ANTHROPIC_VERSION = "2023-06-01";

/** A phone photo of a receipt is well under this. A scan of a lease is not. */
const MAX_BYTES = 5 * 1024 * 1024;

/** What both providers are flattened into. */
interface Extraction {
  supplier_name: string | null;
  supplier_tax_id: string | null;
  supplier_registration_no: string | null;
  supplier_email: string | null;
  supplier_phone: string | null;
  supplier_address: string | null;
  document_no: string | null;
  document_date: string | null;
  currency: string | null;
  subtotal: number | null;
  tax_amount: number | null;
  total_amount: number | null;
  lines: {
    description: string | null;
    quantity: number | null;
    unit_price: number | null;
    amount: number | null;
  }[];
  note: string | null;
  /**
   * The text of the page, where the reader gives it.
   *
   * Document AI returns it alongside the fields at no extra cost, so it
   * is passed through: it is what the app's "All data" screen lists, so
   * a field the parse missed can still be assigned by the person holding
   * the paper.
   *
   * Deliberately *not* asked of the two LLM readers. It is not in their
   * schema, so they answer with fields only — transcribing every
   * document in full would multiply the output tokens of every scan to
   * serve a screen most people never open.
   */
  raw_text: string | null;

  /**
   * Which destination the reader decided this document is, as
   * `module.action` — or null for "I could not place it", which has to
   * be sayable or it gets guessed. Null on every scan of a platform
   * that has configured no targets, which is every scan before `0681`.
   */
  target: string | null;

  /**
   * What it read for that destination's fields, keyed by column name.
   *
   * Values only, no types: everything comes back as a string, because
   * the schema asks for what is PRINTED and a date on a Malaysian
   * receipt is `03/09/2026` until somebody who knows the column decides
   * which way round that is. Coercion belongs where the column is
   * known, not here.
   */
  fields: Record<string, string> | null;

  /**
   * One entry per printed line, where the destination takes rows.
   *
   * A bank statement is forty records, not one. Null for every other
   * document and for every reader that is not asked — see `0682`.
   */
  rows: Record<string, string>[] | null;
}

interface BeginResult {
  scan_id: string;
  /** The catalog code — `claude`, `openai`, `grok`, and whatever else
   * has been added since. Only ever used for the secret's name and the
   * log; what to *do* is decided by `kind`. */
  provider: string;
  provider_name: string;
  /** The protocol, which is the only thing this function switches on. */
  kind: "anthropic" | "openai" | "google_docai" | "self_hosted" | "device";
  endpoint: string | null;
  model: string | null;
  key_source: "platform" | "own" | "device";
  storage_path: string;
  mime_type: string | null;
  charged: number;
}

interface OwnCredential {
  api_key: string;
  project_id: string | null;
  location: string | null;
  processor_id: string | null;
}

/**
 * Structured output, so the answer is the shape this says it is rather
 * than JSON-shaped prose that has to be repaired.
 *
 * Every field is required and nullable rather than optional. "The
 * supplier's tax number is not on this receipt" and "I forgot to look"
 * are different answers, and only the first one is useful; a null says
 * which.
 */
const SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: [
    "supplier_name",
    "supplier_tax_id",
    "supplier_registration_no",
    "supplier_email",
    "supplier_phone",
    "supplier_address",
    "document_no",
    "document_date",
    "currency",
    "subtotal",
    "tax_amount",
    "total_amount",
    "lines",
    "note",
  ],
  properties: {
    supplier_name: {
      type: ["string", "null"],
      description: "The business issuing the document, as printed.",
    },
    supplier_tax_id: {
      type: ["string", "null"],
      description:
        "SST registration number, GST number or TIN if one is printed. " +
        "Not the SSM company registration number, which has its own field.",
    },
    supplier_registration_no: {
      type: ["string", "null"],
      description:
        "The SSM company registration number. Malaysian companies carry " +
        "two: the twelve-digit number issued since 2019 (201901030189) " +
        "and the older form (571389-H). Where both are printed, return " +
        "the twelve-digit one.",
    },
    supplier_email: {
      type: ["string", "null"],
      description:
        "The supplier's email address as printed. Null unless one is " +
        "plainly there — a wrong address is where a remittance goes.",
    },
    supplier_phone: {
      type: ["string", "null"],
      description:
        "The supplier's telephone number as printed. Not an approval " +
        "code, a terminal id or a customer service number for somebody " +
        "else's product.",
    },
    supplier_address: {
      type: ["string", "null"],
      description:
        "The supplier's full address as printed, newlines preserved. Do " +
        "not split it into fields and do not reorder it.",
    },
    document_no: {
      type: ["string", "null"],
      description:
        "The document's own number — invoice, bill or receipt. Labelled " +
        "`Invoice No`, `Bill No`, `No. Resit`, `No. Invois`, or printed " +
        "under such a label rather than beside it. Not the approval code " +
        "or reference from a card terminal, not the SSM or SST number, " +
        "and not the customer's account number.",
    },
    document_date: {
      type: ["string", "null"],
      description:
        "The document date as YYYY-MM-DD. Malaysian receipts are usually " +
        "DD/MM/YYYY; read them that way unless the day exceeds 12 and " +
        "resolves the order for you.",
    },
    currency: {
      type: ["string", "null"],
      description:
        "ISO 4217 code. RM and MYR both mean MYR. Null if nothing says.",
    },
    subtotal: {
      type: ["number", "null"],
      description: "Total before tax, if the document separates it.",
    },
    tax_amount: {
      type: ["number", "null"],
      description:
        "Service tax or sales tax charged. Null if the document shows " +
        "none; zero only if it prints a zero.",
    },
    total_amount: {
      type: ["number", "null"],
      description: "The amount actually payable, tax included.",
    },
    lines: {
      type: "array",
      description:
        "One entry per item charged — NOT one per printed line. A " +
        "description that wraps onto a second or third printed line is " +
        "one entry whose description keeps every line of it, joined " +
        "with newlines, in the order printed. A continuation line, a " +
        "part number, a serial number or a period covered belongs in " +
        "the description of the item above it, never in an entry of " +
        "its own. Empty if the document is a single undifferentiated " +
        "total.",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["description", "quantity", "unit_price", "amount"],
        properties: {
          description: {
            type: ["string", "null"],
            description:
              "Everything printed about this item, newlines preserved. " +
              "Two printed lines describing one charge is one " +
              "description with a newline in it.",
          },
          quantity: { type: ["number", "null"] },
          unit_price: { type: ["number", "null"] },
          amount: { type: ["number", "null"] },
        },
      },
    },
    note: {
      type: ["string", "null"],
      description:
        "Anything a bookkeeper should check by hand: a figure that was " +
        "unreadable, a total that does not foot, a second currency.",
    },
  },
} as const;

const SYSTEM = [
  "You are reading a purchase document for a Malaysian bookkeeper: a",
  "receipt, a supplier invoice, a bill or a payment slip.",
  "",
  "Transcribe what is printed. Do not compute a missing figure and",
  "present it as read — if the subtotal is not on the document, that",
  "field is null, and if the arithmetic on the document does not foot,",
  "say so in `note` and report the printed figures unchanged.",
  "",
  "A charge often takes more than one printed line: the item on the",
  "first, the detail on the second — a part number, a period covered, a",
  "site address, a serial. That is one entry, and the second line goes",
  "in its description after a newline. Splitting it into a second entry",
  "with no price puts a phantom line on somebody's bill; dropping it",
  "loses what they are actually being charged for.",
  "",
  "Malaysian documents worth knowing: amounts are prefixed RM; service",
  "tax appears as SST, and older documents show GST; a tax-inclusive",
  "total is often printed as 'Total Inclusive of SST'. Thermal receipts",
  "fade — an amount you cannot read is null and a note, never a guess.",
].join("\n");

/** The base64 an API body wants, without blowing the stack on a big file. */
function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 8192) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  }
  return btoa(binary);
}

/** Numbers arrive as "1,234.50", "RM 1,234.50" or already as numbers. */
function toNumber(v: unknown): number | null {
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (typeof v !== "string") return null;
  const cleaned = v.replace(/[^0-9.\-]/g, "");
  if (cleaned === "" || cleaned === "-" || cleaned === ".") return null;
  const n = Number(cleaned);
  return Number.isFinite(n) ? n : null;
}

async function readClaude(
  apiKey: string,
  endpoint: string,
  model: string,
  bytes: Uint8Array,
  mime: string,
  // The schema and the prompt are ARGUMENTS since `0681`, not the
  // module constants, because what a platform asks a reader for is now
  // configuration. They default to the constants so a deployment that
  // has set up no targets behaves exactly as it did.
  schema: Record<string, unknown> = SCHEMA,
  system: string = SYSTEM,
): Promise<Extraction> {
  // A PDF is a document block and an image is an image block; the API
  // rejects each in the other's place, and a phone camera produces one
  // while a supplier's emailed invoice produces the other.
  const isPdf = mime === "application/pdf";
  const source = {
    type: "base64",
    media_type: isPdf ? "application/pdf" : mime,
    data: toBase64(bytes),
  };

  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": ANTHROPIC_VERSION,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      max_tokens: 4000,
      system,
      // No extended thinking. This is a bounded transcription with a
      // fixed output shape, and the tenant is paying per scan for an
      // answer while somebody stands at a counter holding the receipt.
      output_config: { format: { type: "json_schema", schema } },
      messages: [{
        role: "user",
        content: [
          { type: isPdf ? "document" : "image", source },
          { type: "text", text: "Read this document." },
        ],
      }],
    }),
  });

  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new ReaderRefusal(
      `Claude refused the document: ${
        body?.error?.message ?? `HTTP ${response.status}`
      }`,
      response.status,
    );
  }
  // A safety decline is a 200 with no usable content, so the stop
  // reason is checked before the content is indexed into.
  if (body?.stop_reason === "refusal") {
    throw new Error("Claude declined to read this document.");
  }
  if (body?.stop_reason === "max_tokens") {
    throw new Error(
      "The document was too long to read in one pass. Attach the page " +
        "with the totals on it.",
    );
  }

  const text = (body?.content ?? [])
    .filter((b: { type?: string }) => b?.type === "text")
    .map((b: { text?: string }) => b.text ?? "")
    .join("");
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error("Claude answered with something that was not the schema.");
  }
  return normalise(parsed);
}

/**
 * ChatGPT, Grok, and whatever else speaks chat-completions.
 *
 * Kept as one function rather than one per vendor because the vendors
 * differ by two strings — the endpoint and the model — and both are
 * columns on `ocr_providers`. Adding a reader that speaks this shape is
 * a row in the console and a secret; nothing here changes.
 *
 * The bearer token and the `messages` array are the parts they agree on.
 * `response_format` with a json_schema is the part they mostly agree on,
 * and where a particular one does not support it the schema is still
 * described in the system prompt, so the worst case is prose that
 * happens to parse rather than a hard failure.
 */
async function readOpenAiShaped(
  apiKey: string,
  endpoint: string,
  model: string,
  bytes: Uint8Array,
  mime: string,
  // The schema and the prompt are ARGUMENTS since `0681`, not the
  // module constants, because what a platform asks a reader for is now
  // configuration. They default to the constants so a deployment that
  // has set up no targets behaves exactly as it did.
  schema: Record<string, unknown> = SCHEMA,
  system: string = SYSTEM,
): Promise<Extraction> {
  // Chat-completions takes images, not documents. A PDF would have to go
  // through a different endpoint on every one of these, so it is refused
  // by name rather than sent and misread.
  if (mime === "application/pdf") {
    throw new Error(
      "This reader takes photographs, not PDFs. Photograph the document, " +
        "or switch to Claude, which reads PDFs.",
    );
  }

  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      max_completion_tokens: 4000,
      response_format: {
        type: "json_schema",
        json_schema: { name: "purchase_document", strict: true, schema },
      },
      messages: [
        { role: "system", content: system },
        {
          role: "user",
          content: [
            {
              type: "image_url",
              image_url: { url: `data:${mime};base64,${toBase64(bytes)}` },
            },
            { type: "text", text: "Read this document." },
          ],
        },
      ],
    }),
  });

  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new ReaderRefusal(
      `The reader refused the document: ${
        body?.error?.message ?? `HTTP ${response.status}`
      }`,
      response.status,
    );
  }

  const choice = body?.choices?.[0];
  if (choice?.finish_reason === "length") {
    throw new Error(
      "The document was too long to read in one pass. Attach the page " +
        "with the totals on it.",
    );
  }
  const text = choice?.message?.content;
  if (typeof text !== "string" || text.trim() === "") {
    // A refusal comes back as `message.refusal` with no content, and
    // indexing straight into `content` would turn that into a parse
    // error blamed on the schema.
    throw new Error(
      choice?.message?.refusal ??
        "The reader answered with nothing.",
    );
  }

  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error("The reader answered with something that was not the schema.");
  }
  return normalise(parsed);
}

/**
 * Document AI answers with a flat list of typed entities rather than a
 * shape of our choosing, so the mapping is by entity type. The names are
 * the Expense and Invoice processors' own; an entity a processor does
 * not emit simply never appears, which is the null this wants anyway.
 */
/**
 * A reader somebody runs themselves.
 *
 * MinerU, PaddleOCR, OCRmyPDF, docTR — none of them is a hosted API and
 * none can be embedded here: they are Python with model weights, and
 * this function is Deno. What they CAN be is a container behind an
 * endpoint, and that is all this asks for.
 *
 * One protocol rather than one branch per project, deliberately. The
 * four differ in how they read a page and not in what this needs back,
 * so a branch each would be four ways of saying the same thing and a
 * fifth project would need a fifth. `docs/ocr-self-hosted.md` is the
 * contract; anything that honours it is a catalog row.
 *
 * The request is `multipart/form-data` rather than base64 JSON, because
 * these services already accept file uploads and a bill photographed at
 * full resolution is several megabytes that base64 makes a third
 * larger again.
 *
 * The key is optional and sent as a bearer token. A service on a
 * private network may need none; one reachable from the internet
 * certainly does, and the catalog row says which by `takes_key`.
 */
async function readSelfHosted(
  apiKey: string,
  endpoint: string,
  model: string,
  bytes: Uint8Array,
  mime: string,
  // No schema and no prompt, unlike the two above. A self-hosted
  // reader is sent `schema=iakauntan.extraction.v1` — a NAME, which it
  // implements at its end — so there is nothing here to configure and
  // accepting the arguments in order to ignore them would be the
  // signature promising something it does not do. Per-target fields
  // reach an LLM reader and not this one, and `0681`'s console says so.
): Promise<Extraction> {
  if (!endpoint) {
    throw new Error(
      "This reader has no address. Set its endpoint in the platform " +
        "console before choosing it.",
    );
  }

  const form = new FormData();
  // `bytes.slice()` rather than `bytes`: a Uint8Array may be backed by
  // a SharedArrayBuffer, which is not a BlobPart. The copy is the
  // narrowing, and a receipt is small enough not to care.
  form.append(
    "file",
    new Blob([bytes.slice().buffer as ArrayBuffer], { type: mime }),
    "document",
  );
  // What the caller wants back, so one service can host several
  // pipelines behind one address and choose by this.
  if (model) form.append("model", model);
  form.append("schema", "iakauntan.extraction.v1");

  const headers: Record<string, string> = { accept: "application/json" };
  if (apiKey) headers.authorization = `Bearer ${apiKey}`;

  const res = await fetch(endpoint, {
    method: "POST",
    headers,
    body: form,
    // A self-hosted reader on a cold container can be slow, and slow is
    // not broken. But it cannot be unbounded: the charge is already
    // taken, and a request that never returns is a charge that is never
    // refunded.
    signal: AbortSignal.timeout(120_000),
  });

  if (!res.ok) {
    const detail = (await res.text()).slice(0, 300);
    throw new ReaderRefusal(
      `The reader at ${new URL(endpoint).host} answered ${res.status}. ` +
        (detail || "It sent no explanation."),
      res.status,
    );
  }

  let body: unknown;
  try {
    body = await res.json();
  } catch {
    throw new Error(
      `The reader at ${new URL(endpoint).host} did not answer with JSON. ` +
        "See docs/ocr-self-hosted.md for the shape this expects.",
    );
  }

  if (typeof body !== "object" || body === null) {
    throw new Error("The reader answered with something that is not a result.");
  }

  // `extraction` when the service wraps its answer, the body itself when
  // it does not. Both are common and neither is worth refusing over.
  const raw = (body as Record<string, unknown>).extraction ?? body;
  if (typeof raw !== "object" || raw === null) {
    throw new Error("The reader answered with no extraction in it.");
  }

  return normaliseExtraction(raw as Record<string, unknown>);
}

/**
 * Every field present, and null where the reader had nothing.
 *
 * A self-hosted service is not going to honour a JSON schema the way a
 * structured-output API does, so this fills the shape rather than
 * trusting it. The alternative is an extraction with holes in it
 * reaching `ocr_finish`, where a missing key and a null mean different
 * things to everything downstream.
 */
function normaliseExtraction(raw: Record<string, unknown>): Extraction {
  const str = (k: string): string | null => {
    const v = raw[k];
    if (typeof v === "string") return v.trim() === "" ? null : v.trim();
    if (typeof v === "number") return String(v);
    return null;
  };
  const num = (k: string): number | null => {
    const v = raw[k];
    if (typeof v === "number" && Number.isFinite(v)) return v;
    if (typeof v === "string") {
      // Same forgiveness the SQL importer gives: a reader that hands
      // back "RM 1,234.50" has read the page correctly.
      const cleaned = v.replace(/[,\s]/g, "").replace(/RM/gi, "");
      const n = Number(cleaned);
      if (Number.isFinite(n) && cleaned !== "") return n;
    }
    return null;
  };

  const lines = Array.isArray(raw.lines)
    ? raw.lines.filter((l): l is Record<string, unknown> =>
      typeof l === "object" && l !== null
    ).map((l) => ({
      description: typeof l.description === "string" ? l.description : null,
      quantity: numberFrom(l.quantity),
      unit_price: numberFrom(l.unit_price),
      amount: numberFrom(l.amount),
    }))
    : [];

  return {
    supplier_name: str("supplier_name"),
    supplier_tax_id: str("supplier_tax_id"),
    supplier_registration_no: str("supplier_registration_no"),
    supplier_email: str("supplier_email"),
    supplier_phone: str("supplier_phone"),
    supplier_address: str("supplier_address"),
    document_no: str("document_no"),
    document_date: str("document_date"),
    currency: str("currency"),
    subtotal: num("subtotal"),
    tax_amount: num("tax_amount"),
    total_amount: num("total_amount"),
    lines,
    note: str("note"),
    target: targetOf(raw),
    fields: fieldsOf(raw),
    rows: rowsOf(raw),
  } as Extraction;
}

/**
 * The per-line values, where a destination takes rows.
 *
 * A row that came back with nothing usable in it is dropped rather than
 * kept as an empty object: a statement with three blank lines in the
 * middle is worse than one with three lines missing, because the blanks
 * look like entries somebody has to go and explain.
 */
function rowsOf(raw: Record<string, unknown>): Record<string, string>[] | null {
  const v = raw.rows;
  if (!Array.isArray(v)) return null;
  const out: Record<string, string>[] = [];
  for (const entry of v) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    const row: Record<string, string> = {};
    for (const [k, value] of Object.entries(entry as Record<string, unknown>)) {
      if (typeof value === "string") {
        if (value.trim() !== "") row[k] = value.trim();
      } else if (typeof value === "number" && Number.isFinite(value)) {
        row[k] = String(value);
      }
    }
    if (Object.keys(row).length > 0) out.push(row);
  }
  return out.length === 0 ? null : out;
}

/** The destination the reader chose, if it chose a real one. */
function targetOf(raw: Record<string, unknown>): string | null {
  const v = raw.target;
  return typeof v === "string" && v.trim() !== "" ? v.trim() : null;
}

/**
 * The per-field values, flattened to strings.
 *
 * Everything the schema asks for is `["string", "null"]`, but a model
 * handed a column called `total_amount` returns a number often enough
 * that refusing one would drop the field silently. So a number is
 * taken and stringified, and anything else -- an object, an array, a
 * boolean -- is dropped, because there is no column this app has that
 * one of those is the honest value for.
 */
function fieldsOf(raw: Record<string, unknown>): Record<string, string> | null {
  const v = raw.fields;
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const out: Record<string, string> = {};
  for (const [k, value] of Object.entries(v as Record<string, unknown>)) {
    if (typeof value === "string") {
      if (value.trim() !== "") out[k] = value.trim();
    } else if (typeof value === "number" && Number.isFinite(value)) {
      out[k] = String(value);
    }
  }
  return Object.keys(out).length === 0 ? null : out;
}

/** The same number forgiveness, for a line. */
function numberFrom(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string") {
    const cleaned = v.replace(/[,\s]/g, "").replace(/RM/gi, "");
    const n = Number(cleaned);
    if (Number.isFinite(n) && cleaned !== "") return n;
  }
  return null;
}

async function readGoogle(
  credential: string,
  project: string,
  location: string,
  processor: string,
  bytes: Uint8Array,
  mime: string,
): Promise<Extraction> {
  let account: ServiceAccount;
  try {
    account = JSON.parse(credential) as ServiceAccount;
  } catch {
    throw new Error(
      "The Google credential is not JSON. Paste the whole service " +
        "account file, not just the key.",
    );
  }

  const token = await googleAccessToken(
    account,
    "https://www.googleapis.com/auth/cloud-platform",
  );
  const endpoint = `https://${location}-documentai.googleapis.com/v1/` +
    `projects/${project}/locations/${location}/processors/${processor}:process`;

  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      rawDocument: { content: toBase64(bytes), mimeType: mime },
    }),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new ReaderRefusal(
      `Document AI refused the document: ${
        body?.error?.message ?? `HTTP ${response.status}`
      }`,
      response.status,
    );
  }

  const entities: {
    type?: string;
    mentionText?: string;
    normalizedValue?: { text?: string; moneyValue?: unknown };
    properties?: unknown[];
  }[] = body?.document?.entities ?? [];

  const pick = (...types: string[]): string | null => {
    for (const t of types) {
      const hit = entities.find((e) => e.type === t);
      if (hit) return hit.normalizedValue?.text ?? hit.mentionText ?? null;
    }
    return null;
  };

  const lines = entities
    .filter((e) => e.type === "line_item")
    .map((e) => {
      const props = (e.properties ?? []) as {
        type?: string;
        mentionText?: string;
        normalizedValue?: { text?: string };
      }[];
      const prop = (t: string) => {
        const hit = props.find((p) => p.type === `line_item/${t}`);
        return hit?.normalizedValue?.text ?? hit?.mentionText ?? null;
      };
      return {
        description: prop("description"),
        quantity: toNumber(prop("quantity")),
        unit_price: toNumber(prop("unit_price")),
        amount: toNumber(prop("amount")),
      };
    });

  return {
    supplier_name: pick("supplier_name", "receiver_name"),
    supplier_tax_id: pick("supplier_tax_id"),
    // No `receiver_*` fallbacks on any of these, unlike the name above.
    // In Document AI the receiver is the *customer* — us — so falling
    // back to it would file our own address and email against the
    // supplier, and look entirely plausible doing it.
    supplier_registration_no: pick("supplier_registration"),
    supplier_email: pick("supplier_email"),
    supplier_phone: pick("supplier_phone"),
    supplier_address: pick("supplier_address"),
    document_no: pick("invoice_id", "receipt_id", "purchase_order"),
    document_date: pick("invoice_date", "receipt_date", "due_date"),
    currency: pick("currency"),
    subtotal: toNumber(pick("net_amount")),
    tax_amount: toNumber(pick("total_tax_amount", "vat/tax_amount")),
    total_amount: toNumber(pick("total_amount")),
    lines,
    note: null,
    // Null, and not a gap this can close. Document AI answers with the
    // entities its PROCESSOR was trained on, and a processor is
    // configured in Google's console rather than in ours — so the
    // per-target fields of `0681` do not reach it, and pretending
    // otherwise would put empty columns on a draft and blame the
    // reader. `raw_text` below is what Document AI offers instead: the
    // whole page, which the "All data" screen lets somebody assign by
    // hand.
    target: null,
    fields: null,
    rows: null,
    raw_text: typeof body?.document?.text === "string"
      ? body.document.text
      : null,
  };
}

/** Whatever the model returned, in the types the rest of this expects. */
function normalise(raw: Record<string, unknown>): Extraction {
  const rows = Array.isArray(raw.lines) ? raw.lines : [];
  const str = (v: unknown) =>
    typeof v === "string" && v.trim() !== "" ? v.trim() : null;
  return {
    supplier_name: str(raw.supplier_name),
    supplier_tax_id: str(raw.supplier_tax_id),
    supplier_registration_no: str(raw.supplier_registration_no),
    supplier_email: str(raw.supplier_email),
    supplier_phone: str(raw.supplier_phone),
    supplier_address: str(raw.supplier_address),
    document_no: str(raw.document_no),
    document_date: str(raw.document_date),
    currency: str(raw.currency)?.toUpperCase() ?? null,
    subtotal: toNumber(raw.subtotal),
    tax_amount: toNumber(raw.tax_amount),
    total_amount: toNumber(raw.total_amount),
    // Null by design: see `raw_text` on Extraction.
    raw_text: null,
    lines: rows.map((r) => {
      const row = (r ?? {}) as Record<string, unknown>;
      return {
        description: str(row.description),
        quantity: toNumber(row.quantity),
        unit_price: toNumber(row.unit_price),
        amount: toNumber(row.amount),
      };
    }),
    note: str(raw.note),
    target: targetOf(raw),
    fields: fieldsOf(raw),
    rows: rowsOf(raw),
  };
}

/**
 * A key taken out of a pool, and the row it came from.
 *
 * `key_id` is null for the two older ways of holding a key — the
 * single `org_ocr_credentials` row and the `OCR_KEY_<CODE>` secret —
 * which have no counters to spend and no row to blame when the
 * provider refuses them.
 */
interface ResolvedKey extends OwnCredential {
  key_id: string | null;
  key_label: string | null;
}

async function whyThePoolIsEmpty(
  db: SupabaseClient,
  provider: string,
  orgId: string | null,
): Promise<string> {
  const { data } = await db.rpc("ocr_key_pool_size", {
    p_provider: provider,
    p_org_id: orgId,
  });
  const pool = (data ?? {}) as { keys?: number; usable?: number };
  return poolProblem(pool.keys ?? 0, pool.usable ?? 0);
}

/**
 * The key the scan runs on.
 *
 * Read here with the service role, which is the only reader
 * `org_ocr_credentials` and `ocr_provider_keys` have — both tables have
 * their grants to `anon` and `authenticated` revoked, so this is not
 * merely the convention.
 *
 * The POOL is asked first, on both sides. `app.claim_ocr_key` picks the
 * next key that is inside its clock and under its caps and spends one
 * call of its budget in the same statement, so nothing here has to
 * decide anything about rate limits. Null back means the pool had
 * nothing, and then the two older arrangements are tried — a single
 * `org_ocr_credentials` row, or `OCR_KEY_<CODE>` — so that filling a
 * pool is something a deployment opts into rather than something that
 * breaks it on the way past.
 *
 * The order is deliberate and is the safe one: a platform that has
 * filled a pool means the pool to be used, and a platform that has not
 * carries on exactly as it did.
 */
async function credentialFor(
  db: SupabaseClient,
  begin: BeginResult,
  orgId: string,
): Promise<ResolvedKey> {
  const poolOwner = begin.key_source === "own" ? orgId : null;
  const { data: claimed, error: claimError } = await db.rpc(
    "claim_ocr_key",
    { p_provider: begin.provider, p_org_id: poolOwner },
  );
  if (claimError) {
    console.error("could not ask the key pool", begin.provider, claimError);
  }
  // A set-returning function comes back as an array, and an empty one
  // is the pool having nothing to give rather than an error.
  const key = Array.isArray(claimed) ? claimed[0] : claimed;
  if (key?.api_key) {
    return {
      api_key: key.api_key as string,
      key_id: (key.key_id as string) ?? null,
      key_label: (key.label as string) ?? null,
      // Document AI needs three more things, and they are not per-key:
      // a pool is for a key that is the whole credential.
      project_id: Deno.env.get("OCR_GOOGLE_PROJECT") ?? null,
      location: Deno.env.get("OCR_GOOGLE_LOCATION") ?? "us",
      processor_id: Deno.env.get("OCR_GOOGLE_PROCESSOR") ?? null,
    };
  }

  if (begin.key_source === "own") {
    const { data, error } = await db
      .from("org_ocr_credentials")
      .select("api_key, project_id, location, processor_id")
      .eq("org_id", orgId)
      .eq("provider", begin.provider)
      .maybeSingle();
    if (error || !data) {
      throw new Error(
        "The key for this organization could not be read: " +
          await whyThePoolIsEmpty(db, begin.provider, orgId) +
          ", and no single key is on file either.",
      );
    }
    return { ...(data as unknown as OwnCredential), key_id: null, key_label: null };
  }

  // `OCR_KEY_<CODE>` by convention, so a reader added as a row in the
  // console needs a secret beside it and no code at all. The two names
  // from before the catalog existed are still honoured, so turning this
  // on does not turn off what somebody already configured.
  const generic = `OCR_KEY_${begin.provider.toUpperCase()}`;
  const legacy = begin.kind === "google_docai"
    ? "OCR_GOOGLE_CREDENTIALS"
    : begin.provider === "claude"
    ? "OCR_ANTHROPIC_API_KEY"
    : null;

  const fromEnv = Deno.env.get(generic) ??
    (legacy ? Deno.env.get(legacy) : undefined);
  if (!fromEnv) {
    throw new Error(
      `${begin.provider_name} is not configured on the platform: its key ` +
        `pool is unusable because ` +
        await whyThePoolIsEmpty(db, begin.provider, null) +
        `, and ${generic} is not set on this function either.`,
    );
  }

  if (begin.kind !== "google_docai") {
    return {
      api_key: fromEnv,
      key_id: null,
      key_label: null,
      project_id: null,
      location: null,
      processor_id: null,
    };
  }
  return {
    api_key: fromEnv,
    key_id: null,
    key_label: null,
    project_id: Deno.env.get("OCR_GOOGLE_PROJECT") ?? null,
    location: Deno.env.get("OCR_GOOGLE_LOCATION") ?? "us",
    processor_id: Deno.env.get("OCR_GOOGLE_PROCESSOR") ?? null,
  };
}

/**
 * Sending the document to one reader.
 *
 * Switches on `kind`, never on the provider's name. That is what lets a
 * reader be added as a row in the console: a new ChatGPT-shaped
 * endpoint arrives here already understood.
 *
 * A function rather than the body of the handler since `0679`, because
 * it is now called twice — once for the reader the company chose, and
 * once more for the platform's free fallback when the first one will
 * not answer. Two copies of this switch would be two places for a
 * newly added `kind` to be half-supported.
 */
async function runReader(
  reader: Pick<BeginResult, "kind" | "endpoint" | "model">,
  credential: ResolvedKey,
  bytes: Uint8Array,
  mime: string,
  // What this platform has configured its readers to ask for. Empty
  // for a platform that has set none up, and then every call below
  // falls back to the schema and prompt this function shipped with.
  targets: ScanTarget[] = [],
): Promise<Extraction> {
  const extra = targetSchema(targets);
  // `required` grows with `properties`, and forgetting that broke every
  // scan on any platform that had configured a single field.
  //
  // `SCHEMA` is `strict: true` with `additionalProperties: false` and
  // an explicit `required` naming every property — "every field is
  // required and nullable rather than optional", which is its own
  // header's rule. OpenAI's strict mode enforces it: a property that is
  // not in `required` is an invalid schema and the call comes back 400.
  // That reached the caller as `The document could not be read`, which
  // is what this function says about everything, so it looked like the
  // reader having a bad day rather than us sending a malformed request.
  //
  // It bit only after somebody ticked a field in the console, because
  // an empty target list leaves the schema untouched — so it presented
  // as scanning that had worked all week and suddenly did not.
  const schema = extra === null ? SCHEMA : {
    ...SCHEMA,
    properties: { ...SCHEMA.properties, ...extra },
    required: requiredWith(SCHEMA.required, extra),
  };
  const system = extra === null ? SYSTEM : SYSTEM + "\n" + targetPrompt(targets);

  switch (reader.kind) {
    case "anthropic":
      return await readClaude(
        credential.api_key,
        reader.endpoint ?? "https://api.anthropic.com/v1/messages",
        reader.model ?? "",
        bytes,
        mime,
        schema,
        system,
      );
    case "openai":
      return await readOpenAiShaped(
        credential.api_key,
        reader.endpoint ?? "",
        reader.model ?? "",
        bytes,
        mime,
        schema,
        system,
      );
    case "self_hosted":
      return await readSelfHosted(
        credential.api_key,
        reader.endpoint ?? "",
        reader.model ?? "",
        bytes,
        mime,
      );
    case "google_docai":
      return await readGoogle(
        credential.api_key,
        credential.project_id ?? "",
        credential.location ?? "us",
        credential.processor_id ?? "",
        bytes,
        mime,
      );
    default:
      // `device` never reaches here — ocr_begin refuses it — and an
      // unknown kind means the catalog has outrun this function.
      throw new Error(
        `This deployment does not know how to talk to a ${reader.kind} ` +
          "reader. It needs updating before that one can be used.",
      );
  }
}

/** What `public.ocr_fallback` hands back, or null when there is none. */
interface FallbackReader {
  provider: string;
  provider_name: string;
  kind: BeginResult["kind"];
  endpoint: string | null;
  model: string | null;
}

/**
 * The reader a failed scan tries instead.
 *
 * The database decides whether there is one and records that there
 * was, in the same statement — see `0679`. Everything this function
 * adds is the running of it, and two rules that are its own:
 *
 *   the PLATFORM's keys, always. `key_source: "platform"` is written
 *   here rather than carried over, because a company's own key belongs
 *   to the reader that company chose. Spending it on a different
 *   vendor because ours timed out is a decision made with somebody
 *   else's money;
 *
 *   and a failure here is swallowed into null. The scan has already
 *   failed once; the caller's job is to report THAT failure, and a
 *   fallback that also failed must not replace the first reader's
 *   message with the second one's.
 */
async function tryFallback(
  db: SupabaseClient,
  scanId: string,
  orgId: string,
  bytes: Uint8Array,
  mime: string,
  targets: ScanTarget[],
): Promise<{ extraction: Extraction; reader: FallbackReader } | null> {
  try {
    const { data, error } = await db.rpc("ocr_fallback", { p_scan_id: scanId });
    if (error || !data) return null;
    const reader = data as unknown as FallbackReader;

    const credential = await credentialFor(db, {
      ...reader,
      scan_id: scanId,
      key_source: "platform",
      storage_path: "",
      mime_type: mime,
      charged: 0,
    }, orgId);
    return {
      extraction: await runReader(reader, credential, bytes, mime, targets),
      reader,
    };
  } catch (e) {
    // Logged, not raised, and not written against the scan either: the
    // scan's `error` column is about the reader the company chose.
    console.error("the fallback reader failed too", scanId, e);
    return null;
  }
}

serveFunction("ocr.failed", async (req: Request) => {
  if (req.method !== "POST") return fail("Use POST", 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (!url || !serviceKey) return fail("Function is missing its own keys", 500);

  const body = await req.json().catch(() => ({}));
  const orgId = typeof body?.org_id === "string" ? body.org_id : null;
  const attachmentId = typeof body?.attachment_id === "string"
    ? body.attachment_id
    : null;
  if (!orgId || !attachmentId) {
    return fail("Say which attachment, on which organization", 400);
  }

  // Under the caller's own token. Whether they may scan, whether the
  // organization has scanning on, and whether there is credit are all
  // decided there — a caller presenting nothing but the publishable key
  // is `anon`, belongs to no organization, and gets 403 from the guard.
  const caller = createClient(url, anonKey, {
    auth: { persistSession: false },
    global: {
      headers: { Authorization: req.headers.get("Authorization") ?? "" },
    },
  });
  const started = await caller.rpc("ocr_begin", {
    p_org_id: orgId,
    p_attachment_id: attachmentId,
  });
  if (started.error) {
    // These are the database's own refusals — scanning switched off, no
    // credit, not your organization — and they are already written for
    // somebody to read, so they are passed through rather than
    // flattened into "could not scan".
    return fail(started.error.message, 403);
  }
  const begin = started.data as unknown as BeginResult;

  const db = createClient(url, serviceKey, { auth: { persistSession: false } });

  // Which key out of the pool ran this scan, once one has been claimed.
  // Declared out here because both halves need it: the try spends it,
  // and the catch is where the provider's refusal gets written against
  // it. Null while no pool was involved -- a single `org_ocr_credentials`
  // row, or `OCR_KEY_<CODE>` -- and there is then no row to blame.
  let usedKey: string | null = null;

  // The document itself, hoisted for the same reason `usedKey` is: the
  // catch retries with it. Null while it has not been fetched, which is
  // one of the ways the first attempt can fail -- and a fallback cannot
  // read a file that was never downloaded, so the null is checked
  // rather than asserted away.
  let bytes: Uint8Array | null = null;
  let mime = begin.mime_type ?? "image/jpeg";

  // Where a document of this sort can go, and what each destination
  // wants filled in. `0681`. An error here is not a scan failure: a
  // platform that has configured nothing, or a database older than
  // this function, reads a document exactly as it always did.
  let targets: ScanTarget[] = [];
  {
    const { data, error } = await db.rpc("scan_extraction_targets");
    if (error) {
      console.error("could not read the scan targets", error);
    } else {
      targets = usableTargets(data);
    }
  }

  // From here on every exit settles the scan, because an unsettled scan
  // is a charge nobody gave back.
  try {
    const file = await db.storage.from("attachments").download(
      begin.storage_path,
    );
    if (file.error || !file.data) {
      throw new Error(
        `The file is no longer in storage: ${
          file.error?.message ?? "not found"
        }`,
      );
    }
    bytes = new Uint8Array(await file.data.arrayBuffer());
    if (bytes.byteLength > MAX_BYTES) {
      throw new Error(
        "That file is too large to scan. Photograph the document rather " +
          "than attaching a full-resolution scan of it.",
      );
    }

    mime = begin.mime_type ?? file.data.type ?? "image/jpeg";
    if (!mime.startsWith("image/") && mime !== "application/pdf") {
      throw new Error(`There is nothing to read in a ${mime} file.`);
    }

    const credential = await credentialFor(db, begin, orgId);
    // Remembered outside the try's scope below only in the sense that
    // the catch needs it: a provider's refusal belongs against the KEY
    // that caused it, and by the time we know it failed the credential
    // is the only thing that says which key that was.
    usedKey = credential.key_id;
    // Read once, with the service role, and passed to both attempts.
    // Configuration rather than a secret -- `scan_extraction_targets`
    // is granted to `authenticated` too -- but asking for it twice on
    // a fallback would be a second round trip to learn the same thing.
    //
    // Asked twice where the reader said "not now". A 503 is a model at
    // capacity and the same request a second later usually works;
    // before this, an overloaded vendor and an unreadable file were
    // written off identically. `retry.ts` has which statuses count.
    //
    // Inside the same invocation, so `ocr_begin` has already taken the
    // charge once and a second attempt cannot take another.
    // Collected rather than assigned: a `let` written only inside a
    // callback narrows to `never` here, and the compiler is right that
    // it cannot see the write.
    const blips: ReaderRefusal[] = [];
    const extraction = await withOneRetry(
      () => runReader(begin, credential, bytes as Uint8Array, mime, targets),
      { onRetry: (failure) => blips.push(failure) },
    );
    const firstFailure = blips.length > 0 ? blips[0] : null;

    const { error } = await db.rpc("ocr_finish", {
      p_scan_id: begin.scan_id,
      p_status: "ok",
      p_extracted: extraction,
      // Kept ON the successful row, the way a rescued scan keeps the
      // reader that failed it. A blip nobody saw is still a vendor
      // having a bad afternoon, and this row is the only place that
      // would record it -- the day the retry stops being enough is the
      // day somebody wants to know how long it had been shaky.
      //
      // The KEY is not blamed for it. `note_ocr_key_error` is about a
      // refusal the key caused, and a model at capacity is not the
      // key's doing; noting it would walk a pool towards standing keys
      // down over somebody else's outage.
      p_error: firstFailure === null
        ? null
        : `${begin.provider_name} answered ${firstFailure.status} and ` +
          `was asked again: ${firstFailure.message}`,
    });
    if (error) console.error("could not settle scan", begin.scan_id, error);

    return json({
      scan_id: begin.scan_id,
      provider: begin.provider,
      charged: begin.charged,
      extraction,
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    // Minted HERE rather than at the return, which is the whole of
    // `0680`. The reference is what the person scanning is told to
    // quote, and it used to be created after the scan had been settled
    // — so it went to this function's stdout and nowhere else, and the
    // one identifier the message pointed at was the one identifier
    // nothing could look up. Having it in hand before the settle is
    // all it takes to write it against the row.
    const ref = logFailure(e, "ocr.failed", { scan_id: begin.scan_id });
    const { error: refNoted } = await db.rpc("ocr_note_log_ref", {
      p_scan_id: begin.scan_id,
      p_ref: ref,
    });
    if (refNoted) {
      console.error("could not record the reference", begin.scan_id, refNoted);
    }
    // Against the key, when a key from a pool is what ran. A key
    // revoked at the provider's end has to read differently in the
    // console from one that is merely busy, and the console has no
    // other way to tell: it cannot see the key, so it cannot try it.
    //
    // Not a refusal and not a stand-down. The commonest error here is a
    // rate limit, which is the thing the caps exist to stop us causing
    // -- a key struck out of the pool for one of those would be a pool
    // that empties itself the first busy afternoon.
    if (usedKey) {
      const { error: noted } = await db.rpc("note_ocr_key_error", {
        p_key_id: usedKey,
        p_error: message,
      });
      if (noted) console.error("could not note the key error", usedKey, noted);
    }

    // 0679. Before the scan is written off, the platform's free reader
    // gets one attempt at it.
    //
    // After `note_ocr_key_error` on purpose: the key that failed
    // failed, and a fallback that rescues the document does not make
    // that untrue -- the console needs to see a vendor having a bad
    // afternoon even when nobody noticed, because the day the fallback
    // is also down is the day somebody wishes they had.
    //
    // Only when the file was actually read. A scan that failed on a
    // missing file, an oversized one or an unreadable type has nothing
    // to retry, and sending a second vendor a request that cannot
    // succeed is one more place the document has been.
    if (bytes) {
      const rescued = await tryFallback(
        db, begin.scan_id, orgId, bytes, mime, targets,
      );
      if (rescued) {
        const { error: settled } = await db.rpc("ocr_finish", {
          p_scan_id: begin.scan_id,
          p_status: "ok",
          p_extracted: rescued.extraction,
          // The first reader's failure is kept ON the successful row.
          // Losing it would hide the whole point: the company's chosen
          // reader is not working, and somebody has to be able to find
          // that out without a fallback that silently covers for it
          // for a month.
          p_error: `${begin.provider_name} failed and ` +
            `${rescued.reader.provider_name} read it instead: ${message}`,
        });
        if (settled) {
          console.error("could not settle a rescued scan", begin.scan_id, settled);
        }
        return json({
          scan_id: begin.scan_id,
          provider: begin.provider,
          // Named, not buried. The company is told which reader read
          // its document, because that is a different vendor from the
          // one it chose and it is entitled to know which.
          fell_back_to: rescued.reader.provider,
          fell_back_to_name: rescued.reader.provider_name,
          charged: begin.charged,
          extraction: rescued.extraction,
        });
      }
    }

    const { error } = await db.rpc("ocr_finish", {
      p_scan_id: begin.scan_id,
      p_status: "failed",
      p_extracted: null,
      p_error: message,
    });
    // Worth shouting about: the scan failed *and* the money did not come
    // back, which is the one combination nobody finds on their own.
    if (error) {
      console.error("scan failed and was not refunded", begin.scan_id, error);
    }
    // The provider's message goes to the log and to `ocr_scans.error`,
    // which is the organization's own row behind RLS, and to the
    // console's scan log. It does not go in the response: a Document
    // AI failure quotes the project, the processor and sometimes the
    // page it choked on.
    return fail(
      "The document could not be read. Quote this reference if you get in touch.",
      502,
      {
        ref,
        scan_id: begin.scan_id,
        refunded: begin.charged > 0 && !error,
      },
    );
  }
});
