/**
 * The schema dialect, asserted — because getting it wrong is a 400
 * from a vendor at scan time whose message names no key.
 *
 *   deno test supabase/functions/ocr/gemini_schema_test.ts
 */
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { geminiSchema } from "./gemini_schema.ts";

Deno.test("a nullable field becomes a type plus a flag", () => {
  const out = geminiSchema({
    type: "object",
    properties: {
      supplier_name: { type: ["string", "null"], description: "who" },
      total_amount: { type: ["number", "null"] },
    },
    required: ["supplier_name", "total_amount"],
  });
  const props = out.properties as Record<string, Record<string, unknown>>;
  assertEquals(props.supplier_name.type, "string");
  assertEquals(props.supplier_name.nullable, true);
  // The description is the reader's instruction for that field and is
  // most of what makes the answer right. Dropping it would leave a
  // schema that validates and reads worse.
  assertEquals(props.supplier_name.description, "who");
  assertEquals(props.total_amount.type, "number");
  assertEquals(props.total_amount.nullable, true);
});

Deno.test("a plain type keeps its type and gains no flag", () => {
  const out = geminiSchema({ type: "object", properties: {} });
  assertEquals(out.type, "object");
  assertEquals("nullable" in out, false);
});

// `additionalProperties: false` is how OpenAI's strict mode is told the
// shape is closed. Gemini rejects the key outright, and `SCHEMA` has it
// at the top level — so leaving it in fails every scan rather than some
// of them.
Deno.test("additionalProperties is dropped", () => {
  const out = geminiSchema({
    type: "object",
    additionalProperties: false,
    properties: { a: { type: ["string", "null"] } },
  });
  assertEquals("additionalProperties" in out, false);
});

// `0681` lets a platform add fields to a scan target, and whatever it
// writes arrives here. An unknown key is a question of when, not
// whether.
Deno.test("a key Gemini has never heard of is dropped", () => {
  const out = geminiSchema({
    type: "string",
    // deno-lint-ignore no-explicit-any
    ...({ $schema: "https://json-schema.org/draft-07", examples: ["x"] } as any),
  });
  assertEquals(out, { type: "string" });
});

Deno.test("lines are translated all the way down", () => {
  const out = geminiSchema({
    type: "object",
    properties: {
      lines: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          properties: {
            description: { type: ["string", "null"] },
            amount: { type: ["number", "null"] },
          },
          required: ["description", "amount"],
        },
      },
    },
  });
  const lines =
    (out.properties as Record<string, Record<string, unknown>>).lines;
  const items = lines.items as Record<string, unknown>;
  assertEquals("additionalProperties" in items, false);
  const props = items.properties as Record<string, Record<string, unknown>>;
  assertEquals(props.amount.type, "number");
  assertEquals(props.amount.nullable, true);
  assertEquals(items.required, ["description", "amount"]);
});

// `required` naming a property that is not there is a 400, and it can
// happen honestly: `requiredWith` adds every extra field a platform
// configures and a target could name one and then be edited.
Deno.test("required is narrowed to properties that exist", () => {
  const out = geminiSchema({
    type: "object",
    properties: { a: { type: "string" } },
    required: ["a", "b"],
  });
  assertEquals(out.required, ["a"]);
});

// A union of only `null` has no Gemini spelling. `string` plus the flag
// is the honest reading — a field that can only be absent — and the
// alternative is emitting `type: undefined`, which is a 400.
Deno.test("a type that is only null still names a type", () => {
  const out = geminiSchema({ type: ["null"] });
  assertEquals(out.type, "string");
  assertEquals(out.nullable, true);
});
