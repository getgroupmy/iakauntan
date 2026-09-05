/**
 * The two wire shapes, asserted without a network.
 *
 *   deno test supabase/functions/ask/wire_test.ts
 *
 * `ask/index.ts` reaches nine providers through two request shapes, and
 * the difference between them is small enough to get wrong quietly: a
 * `function` wrapper, a schema under a different key, and arguments
 * that arrive as a JSON string on one shape and an object on the other.
 *
 * NO IMPORTS BUT THE ONE BEING TESTED, and that is deliberate rather
 * than austere. `jsr.io` is unreachable from some of the machines this
 * gets worked on — `_local_check/check_locally.sh` exists because of
 * it, and a `jsr:@std/assert` import here would make this file one that
 * only CI can run. A four-line `eq` is a smaller price than a test
 * nobody can run before pushing.
 *
 * What these cannot check is the call itself. Green here is not green
 * against a live provider; it is only proof that what we send is the
 * shape we meant to send.
 */
import {
  anthropicTools,
  chatUrl,
  openAiTools,
  parseArgs,
} from "./wire.ts";

function eq(actual: unknown, expected: unknown, what: string): void {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) throw new Error(`${what}: expected ${b}, got ${a}`);
}

const specs = [
  {
    name: "trial_balance",
    description: "Every account and what it stands at",
    arguments: [
      { name: "as_of", type: "date", required: true, description: "The day" },
      { name: "dimension", type: "text" },
    ],
  },
];

Deno.test("the Messages API gets its schema under input_schema", () => {
  const tool = anthropicTools(specs)[0] as Record<string, unknown>;
  eq(tool.name, "trial_balance", "the tool keeps its name");
  const schema = tool.input_schema as Record<string, unknown>;
  eq(schema.type, "object", "the schema is an object");
  eq(schema.required, ["as_of"], "and says which argument is needed");
});

Deno.test("chat completions gets the same schema, wrapped", () => {
  const tool = openAiTools(specs)[0] as Record<string, unknown>;
  eq(tool.type, "function", "the OpenAI shape wraps a tool in a function");
  const fn = tool.function as Record<string, unknown>;
  eq(fn.name, "trial_balance", "which carries the name");
  const schema = fn.parameters as Record<string, unknown>;
  eq(schema.type, "object", "and the schema under `parameters`");
  eq(schema.required, ["as_of"], "with the same one argument needed");
});

Deno.test("every argument is described as a string on both shapes", () => {
  // The cast that matters is the one `ai_run_tool` makes. A second
  // opinion about the type here would only be a second place for it to
  // be wrong, so both shapes say `string` and mean it.
  const anth = (anthropicTools(specs)[0] as Record<string, unknown>)
    .input_schema as { properties: Record<string, { type: string }> };
  const open = ((openAiTools(specs)[0] as Record<string, unknown>)
    .function as Record<string, unknown>)
    .parameters as { properties: Record<string, { type: string }> };
  eq(anth.properties.as_of.type, "string", "a date is a string to the model");
  eq(open.properties.as_of.type, "string", "on the other shape too");
  eq(open.properties.dimension.type, "string", "and so is a text argument");
});

Deno.test("an argument with no description of its own still gets one", () => {
  // A catalogue row that has not been written up yet should not reach a
  // model as a bare name: the type it will be cast to is the least that
  // can be said about it.
  const open = ((openAiTools(specs)[0] as Record<string, unknown>)
    .function as Record<string, unknown>)
    .parameters as { properties: Record<string, { description: string }> };
  eq(
    open.properties.dimension.description,
    "dimension (text), passed through as written",
    "the fallback names the declared type",
  );
  eq(
    open.properties.as_of.description,
    "The day",
    "and a written one is left alone",
  );
});

Deno.test("arguments arrive as an object on one shape", () => {
  eq(parseArgs({ as_of: "2026-06-30" }), { as_of: "2026-06-30" }, "object");
});

Deno.test("and as a JSON string on the other", () => {
  eq(parseArgs('{"as_of":"2026-06-30"}'), { as_of: "2026-06-30" }, "string");
});

Deno.test("a malformed argument list is empty rather than a crash", () => {
  // The round is not lost: `ai_run_tool` refuses an empty argument list
  // in a sentence, and the model reads the sentence and tries again.
  // Throwing here would take the whole question down instead.
  eq(parseArgs("{not json"), {}, "unparseable");
  eq(parseArgs(""), {}, "empty");
  eq(parseArgs("   "), {}, "blank");
  eq(parseArgs(undefined), {}, "absent");
  eq(parseArgs(null), {}, "null");
});

Deno.test("a JSON value that is not an object is not an argument list", () => {
  eq(parseArgs('"as_of"'), {}, "a string");
  eq(parseArgs("42"), {}, "a number");
  eq(parseArgs("[1,2]"), {}, "an array");
  eq(parseArgs("null"), {}, "a null");
});

Deno.test("the chat endpoint hangs off the base URL", () => {
  eq(
    chatUrl("https://openrouter.ai/api/v1"),
    "https://openrouter.ai/api/v1/chat/completions",
    "the documented address",
  );
});

Deno.test("and a trailing slash does not double up", () => {
  // A person keying an address into the console types it the way it is
  // printed in the documentation, which is sometimes with a slash.
  eq(
    chatUrl("https://api.cerebras.ai/v1/"),
    "https://api.cerebras.ai/v1/chat/completions",
    "one slash",
  );
  eq(
    chatUrl("https://api.deepseek.com///"),
    "https://api.deepseek.com/chat/completions",
    "several",
  );
});
