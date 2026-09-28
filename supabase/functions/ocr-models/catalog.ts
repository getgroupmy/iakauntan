/**
 * Where a vendor keeps its list of models, and how to read the answer.
 *
 * Its own module, importing nothing, for the reason `ocr/pool.ts` and
 * `platform-users/rules.ts` are their own modules: importing `index.ts`
 * pulls in `_shared/cors.ts`, which reads `ALLOWED_ORIGINS` at load, so
 * asserting how a URL is derived would need `--allow-env` and would be
 * importing an HTTP handler to ask it a question about string handling.
 *
 * ## Why this exists at all
 *
 * `0113` seeded `ocr_providers` with `model` null on ChatGPT and Grok
 * and said why, and the reason is still good:
 *
 *   > Guessing an identifier would produce a migration that looks
 *   > finished and a 404 at the first scan, blamed on the feature
 *   > rather than on the guess.
 *
 * So no model is invented here either. What was wrong was not the null
 * — it was leaving an operator to type an identifier they had to
 * already know, from a vendor that renames its models every few months,
 * into a field that accepts anything and only fails at the first scan.
 *
 * Every one of these vendors will say what the key in front of it can
 * actually reach. Asking is strictly better than both guessing and
 * typing: the answer is current by construction, and it is scoped to
 * the account rather than to the vendor's marketing page.
 *
 * ## The list endpoint is DERIVED, not another column
 *
 * `ocr_providers.endpoint` already holds where to send a document. A
 * second column for where to ask about models would be a second thing
 * to get wrong when somebody adds a reader in the console, and it would
 * be blank on every row that exists today. The two URLs differ by their
 * last path segment on all three shapes, so the one we have determines
 * the one we want.
 *
 * That derivation is the part worth asserting, which is why it is here
 * and not inline in a fetch call.
 */

/** A reader's kind, as `ocr_providers.kind` spells it. */
export type Kind =
  | "anthropic"
  | "openai"
  | "google_gemini"
  | "google_docai"
  | "device"
  | "self_hosted";

/** What to ask, and how to be allowed to ask it. */
export interface ModelQuery {
  url: string;
  headers: Record<string, string>;
}

/**
 * The version header Anthropic requires on every request, including
 * this one. Same value as `ocr/index.ts`; duplicated rather than
 * shared because importing it would drag the whole reader in.
 */
const ANTHROPIC_VERSION = "2023-06-01";

/** A vendor that has no list to give, and the sentence to say so. */
const NO_LIST: Partial<Record<Kind, string>> = {
  google_docai:
    "Document AI has processors rather than models — the processor is " +
    "set up in your Google project and named in this function's " +
    "secrets, not chosen here.",
  device: "The on-device reader is the app's own and has no model to choose.",
  self_hosted:
    "A self-hosted reader is whatever you deployed; it has no catalog " +
    "to ask. Type the name your own service answers to.",
};

/** Why this reader cannot be asked, or null if it can. */
export function cannotAsk(kind: string): string | null {
  return NO_LIST[kind as Kind] ?? null;
}

/**
 * The base a list URL is built on.
 *
 * Trailing slashes come off first: an operator who pasted the endpoint
 * with one would otherwise produce `//models`, which some gateways
 * route and others 404 — a difference that shows up as "it works on
 * staging".
 */
function trimmed(endpoint: string): string {
  return endpoint.trim().replace(/\/+$/, "");
}

/**
 * Where to ask, per shape.
 *
 * Throws rather than returning null for an unknown kind, because a kind
 * that reaches here unhandled is a reader whose `kind` check constraint
 * grew without this function growing with it, and a silent empty list
 * would read to an operator as "your key has no models".
 */
export function modelQuery(
  kind: string,
  endpoint: string,
  apiKey: string,
): ModelQuery {
  const why = cannotAsk(kind);
  if (why) throw new Error(why);

  const base = trimmed(endpoint);

  switch (kind as Kind) {
    case "anthropic":
      // `.../v1/messages` -> `.../v1/models`. Anchored at the END so a
      // self-hosted proxy mounted under a path that happens to contain
      // the word `messages` is not rewritten in the middle.
      return {
        url: base.replace(/\/messages$/, "/models") ||
          "https://api.anthropic.com/v1/models",
        headers: {
          "x-api-key": apiKey,
          "anthropic-version": ANTHROPIC_VERSION,
        },
      };

    case "openai":
      // `.../v1/chat/completions` -> `.../v1/models`, which is where
      // OpenAI, xAI and every gateway that has copied the shape keep
      // it. A row whose endpoint is already just the base still works.
      return {
        url: base.replace(/\/chat\/completions$/, "") + "/models",
        headers: { Authorization: `Bearer ${apiKey}` },
      };

    case "google_gemini":
      // The endpoint on this row is a BASE — `readGemini` appends
      // `/models/<model>:generateContent` to it — so the list is the
      // same path without a model.
      return {
        url: (base || "https://generativelanguage.googleapis.com/v1beta") +
          "/models",
        headers: { "x-goog-api-key": apiKey },
      };
  }

  throw new Error(`There is no model list for a ${kind} reader.`);
}

/** One model, as the console shows it. */
export interface ModelChoice {
  id: string;
  label: string;
}

function str(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

/**
 * The ids out of a vendor's answer.
 *
 * Three shapes, and the differences are not cosmetic:
 *
 *   anthropic  `{ data: [{ id, display_name }] }`
 *   openai     `{ data: [{ id }] }` — no display name, and the list
 *              includes embeddings, moderation and audio models that
 *              cannot read a document
 *   gemini     `{ models: [{ name: "models/x", displayName,
 *              supportedGenerationMethods: [...] }] }` — the id is
 *              PREFIXED with `models/`, and the prefix is not part of
 *              the identifier `generateContent` wants
 *
 * Nothing is filtered by guessing at a name. Gemini publishes which
 * methods each model supports, so that one is filtered on the vendor's
 * own statement; the other two are handed over whole, because a list
 * that quietly drops the model somebody is looking for is worse than a
 * long list they can read.
 */
export function modelsFrom(kind: string, body: unknown): ModelChoice[] {
  const b = (body ?? {}) as Record<string, unknown>;

  if (kind === "google_gemini") {
    const rows = Array.isArray(b.models) ? b.models : [];
    const out: ModelChoice[] = [];
    for (const r of rows) {
      const row = (r ?? {}) as Record<string, unknown>;
      const name = str(row.name).replace(/^models\//, "");
      if (name === "") continue;
      // Asked of the vendor, not inferred from the name. An embedding
      // model is in this list too and cannot read a document.
      const methods = Array.isArray(row.supportedGenerationMethods)
        ? row.supportedGenerationMethods.map(str)
        : [];
      if (methods.length > 0 && !methods.includes("generateContent")) continue;
      out.push({ id: name, label: str(row.displayName) || name });
    }
    return out;
  }

  const rows = Array.isArray(b.data) ? b.data : [];
  const out: ModelChoice[] = [];
  for (const r of rows) {
    const row = (r ?? {}) as Record<string, unknown>;
    const id = str(row.id);
    if (id === "") continue;
    out.push({ id, label: str(row.display_name) || id });
  }
  return out;
}

/**
 * The list in the order somebody reads it.
 *
 * Alphabetical, and deliberately not "newest first": these lists carry
 * no reliable date — OpenAI's `created` is the base model's, not the
 * snapshot's — and sorting by a field that means something different
 * per vendor produces an order that looks meaningful and is not.
 * Alphabetical at least groups a family together, which is what
 * somebody scanning for `gpt-4o` or `claude-opus` is doing.
 */
export function sorted(models: ModelChoice[]): ModelChoice[] {
  return [...models].sort((a, b) => a.id.localeCompare(b.id));
}
