/**
 * The two wire shapes the assistant speaks.
 *
 * `ai_providers.wire` is either `anthropic` or `openai`, and these are
 * the parts of the difference that are pure enough to assert without a
 * network. They live in their own file for exactly that reason:
 * `index.ts` calls `serveFunction` at module load, so a test that
 * imported it would start a server rather than run an assertion.
 *
 * What is here is the shape of a tool declaration on each side, the two
 * ways a tool call's arguments arrive, and where a chat-completions
 * request goes given a base URL somebody typed into a console.
 */

export interface ToolSpec {
  name: string;
  description: string;
  arguments: {
    name: string;
    type: string;
    required?: boolean;
    description?: string;
  }[];
}

/**
 * The catalogue's arguments as a JSON Schema object.
 *
 * Every argument is a string on the wire and cast to its declared type
 * inside `ai_run_tool`; describing them as strings here rather than as
 * numbers or dates is deliberate, because the cast that matters is the
 * one the database makes and a second opinion about the type would only
 * be a second place for it to be wrong.
 */
function schemaFor(t: ToolSpec): Record<string, unknown> {
  const properties: Record<string, unknown> = {};
  const required: string[] = [];
  for (const a of t.arguments ?? []) {
    properties[a.name] = {
      type: "string",
      description: a.description ??
        `${a.name} (${a.type}), passed through as written`,
    };
    if (a.required) required.push(a.name);
  }
  return { type: "object", properties, required };
}

/** The catalogue in the shape the Messages API wants. */
export function anthropicTools(specs: ToolSpec[]): unknown[] {
  return specs.map((t) => ({
    name: t.name,
    description: t.description,
    input_schema: schemaFor(t),
  }));
}

/**
 * The same catalogue in the shape chat-completions wants.
 *
 * The only differences are the `function` wrapper and that the schema
 * is called `parameters` rather than `input_schema`, which is exactly
 * the kind of difference that is worth one function rather than a
 * dependency.
 */
export function openAiTools(specs: ToolSpec[]): unknown[] {
  return specs.map((t) => ({
    type: "function",
    function: {
      name: t.name,
      description: t.description,
      parameters: schemaFor(t),
    },
  }));
}

/**
 * A tool call's arguments, whichever shape they arrived in.
 *
 * Anthropic sends an object. The OpenAI shape sends a JSON string, and
 * a model that has produced a malformed one should be told so rather
 * than crash the round: an unparseable argument list becomes an empty
 * one, and `ai_run_tool` refuses it in a sentence the model can read
 * and act on. Throwing here would take the whole question down instead.
 */
export function parseArgs(raw: unknown): Record<string, unknown> {
  if (raw && typeof raw === "object") return raw as Record<string, unknown>;
  if (typeof raw !== "string" || !raw.trim()) return {};
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}

/**
 * Where a chat-completions request goes, given a base URL.
 *
 * The trailing slash is trimmed because a person keying an address into
 * the console types it the way it is printed in the documentation, and
 * that is sometimes with one.
 */
export function chatUrl(baseUrl: string): string {
  return `${baseUrl.replace(/\/+$/, "")}/chat/completions`;
}
