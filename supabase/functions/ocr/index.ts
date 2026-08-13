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
import { corsHeaders, fail, json } from "../_shared/cors.ts";
import { googleAccessToken, ServiceAccount } from "../_shared/google_auth.ts";

const ANTHROPIC_VERSION = "2023-06-01";

/** A phone photo of a receipt is well under this. A scan of a lease is not. */
const MAX_BYTES = 5 * 1024 * 1024;

/** What both providers are flattened into. */
interface Extraction {
  supplier_name: string | null;
  supplier_tax_id: string | null;
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
}

interface BeginResult {
  scan_id: string;
  /** The catalog code — `claude`, `openai`, `grok`, and whatever else
   * has been added since. Only ever used for the secret's name and the
   * log; what to *do* is decided by `kind`. */
  provider: string;
  provider_name: string;
  /** The protocol, which is the only thing this function switches on. */
  kind: "anthropic" | "openai" | "google_docai" | "device";
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
        "SST registration number, GST number or TIN if one is printed.",
    },
    document_no: {
      type: ["string", "null"],
      description: "Invoice, bill or receipt number.",
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
        "One entry per printed line. Empty if the document is a single " +
        "undifferentiated total.",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["description", "quantity", "unit_price", "amount"],
        properties: {
          description: { type: ["string", "null"] },
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
      system: SYSTEM,
      // No extended thinking. This is a bounded transcription with a
      // fixed output shape, and the tenant is paying per scan for an
      // answer while somebody stands at a counter holding the receipt.
      output_config: { format: { type: "json_schema", schema: SCHEMA } },
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
    throw new Error(
      `Claude refused the document: ${
        body?.error?.message ?? `HTTP ${response.status}`
      }`,
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
        json_schema: { name: "purchase_document", strict: true, schema: SCHEMA },
      },
      messages: [
        { role: "system", content: SYSTEM },
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
    throw new Error(
      `The reader refused the document: ${
        body?.error?.message ?? `HTTP ${response.status}`
      }`,
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
    throw new Error(
      `Document AI refused the document: ${
        body?.error?.message ?? `HTTP ${response.status}`
      }`,
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
    supplier_tax_id: pick("supplier_tax_id", "supplier_registration"),
    document_no: pick("invoice_id", "receipt_id", "purchase_order"),
    document_date: pick("invoice_date", "receipt_date", "due_date"),
    currency: pick("currency"),
    subtotal: toNumber(pick("net_amount")),
    tax_amount: toNumber(pick("total_tax_amount", "vat/tax_amount")),
    total_amount: toNumber(pick("total_amount")),
    lines,
    note: null,
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
    document_no: str(raw.document_no),
    document_date: str(raw.document_date),
    currency: str(raw.currency)?.toUpperCase() ?? null,
    subtotal: toNumber(raw.subtotal),
    tax_amount: toNumber(raw.tax_amount),
    total_amount: toNumber(raw.total_amount),
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
  };
}

/**
 * The key the scan runs on.
 *
 * Read here with the service role, which is the only reader
 * `org_ocr_credentials` has — the table's grants to `anon` and
 * `authenticated` are revoked, so this is not merely the convention.
 */
async function credentialFor(
  db: SupabaseClient,
  begin: BeginResult,
  orgId: string,
): Promise<OwnCredential> {
  if (begin.key_source === "own") {
    const { data, error } = await db
      .from("org_ocr_credentials")
      .select("api_key, project_id, location, processor_id")
      .eq("org_id", orgId)
      .eq("provider", begin.provider)
      .maybeSingle();
    if (error || !data) {
      throw new Error("The key for this organization could not be read.");
    }
    return data as unknown as OwnCredential;
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

  const key = Deno.env.get(generic) ??
    (legacy ? Deno.env.get(legacy) : undefined);
  if (!key) {
    throw new Error(
      `${begin.provider_name} is not configured on the platform: set ` +
        `${generic} on this function, or ask the organization to supply ` +
        "its own key.",
    );
  }

  if (begin.kind !== "google_docai") {
    return { api_key: key, project_id: null, location: null, processor_id: null };
  }
  return {
    api_key: key,
    project_id: Deno.env.get("OCR_GOOGLE_PROJECT") ?? null,
    location: Deno.env.get("OCR_GOOGLE_LOCATION") ?? "us",
    processor_id: Deno.env.get("OCR_GOOGLE_PROCESSOR") ?? null,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
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
    const bytes = new Uint8Array(await file.data.arrayBuffer());
    if (bytes.byteLength > MAX_BYTES) {
      throw new Error(
        "That file is too large to scan. Photograph the document rather " +
          "than attaching a full-resolution scan of it.",
      );
    }

    const mime = begin.mime_type ?? file.data.type ?? "image/jpeg";
    if (!mime.startsWith("image/") && mime !== "application/pdf") {
      throw new Error(`There is nothing to read in a ${mime} file.`);
    }

    const credential = await credentialFor(db, begin, orgId);
    // On `kind`, never on the provider's name. That is what lets a
    // reader be added as a row: a new ChatGPT-shaped endpoint arrives
    // here already understood.
    let extraction: Extraction;
    switch (begin.kind) {
      case "anthropic":
        extraction = await readClaude(
          credential.api_key,
          begin.endpoint ?? "https://api.anthropic.com/v1/messages",
          begin.model ?? "",
          bytes,
          mime,
        );
        break;
      case "openai":
        extraction = await readOpenAiShaped(
          credential.api_key,
          begin.endpoint ?? "",
          begin.model ?? "",
          bytes,
          mime,
        );
        break;
      case "google_docai":
        extraction = await readGoogle(
          credential.api_key,
          credential.project_id ?? "",
          credential.location ?? "us",
          credential.processor_id ?? "",
          bytes,
          mime,
        );
        break;
      default:
        // `device` never reaches here — ocr_begin refuses it — and an
        // unknown kind means the catalog has outrun this function.
        throw new Error(
          `This deployment does not know how to talk to a ${begin.kind} ` +
            "reader. It needs updating before that one can be used.",
        );
    }

    const { error } = await db.rpc("ocr_finish", {
      p_scan_id: begin.scan_id,
      p_status: "ok",
      p_extracted: extraction,
      p_error: null,
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
    return fail(message, 502, {
      scan_id: begin.scan_id,
      refunded: begin.charged > 0 && !error,
    });
  }
});
