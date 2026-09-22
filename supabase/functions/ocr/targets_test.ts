import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { targetPrompt, targetSchema, usableTargets } from "./targets.ts";

// What a platform configures in the console becomes part of the schema
// every reader is sent. Three things can go wrong quietly there and
// every one of them looks like the reader being stupid:
//
//   * a target with no fields becomes a choice the model can make and
//     then have nothing to fill, which reads as the scan having
//     understood the document and lost it;
//   * a missing `null` in the enum turns "I cannot place this" into a
//     guess, and a document placed wrongly costs more than one placed
//     nowhere;
//   * a field with no description becomes a column name shown to a
//     model and answered from the name alone.

Deno.test("a target with no fields is not offered", () => {
  const got = usableTargets([
    { key: "purchases.bill", label: "A bill", fields: [] },
    { key: "accounting.expense", label: "An expense", fields: null },
    {
      key: "contacts.contact",
      label: "A contact",
      fields: [{ name: "name" }],
    },
  ]);
  assertEquals(got.map((t) => t.key), ["contacts.contact"]);
});

Deno.test("a field with no name is not a field", () => {
  const got = usableTargets([
    { key: "purchases.bill", label: "A bill", fields: [{ name: "" }] },
  ]);
  assertEquals(got.length, 0);
});

Deno.test("nonsense off the wire is no targets, not a throw", () => {
  // The rpc can answer null on a database older than 0681, and the
  // whole point is that such a deployment scans exactly as it did.
  assertEquals(usableTargets(null), []);
  assertEquals(usableTargets("[]"), []);
  assertEquals(usableTargets([null, 3, "x"]), []);
});

Deno.test("no targets means no schema, so nothing is added", () => {
  assertEquals(targetSchema([]), null);
  assertEquals(targetPrompt([]), "");
});

Deno.test("the enum can say it does not know", () => {
  const schema = targetSchema([
    { key: "purchases.bill", label: "A bill", fields: [{ name: "doc_no" }] },
  ])!;
  const target = schema.target as { enum: (string | null)[] };
  // Null LAST and null PRESENT. A model with no way to say "none of
  // these" picks the closest one, and the closest one becomes a record
  // somebody has to find and undo.
  assertEquals(target.enum, ["purchases.bill", null]);
});

Deno.test("every field of every target is askable, flat", () => {
  const schema = targetSchema([
    {
      key: "purchases.bill",
      label: "A bill",
      fields: [{ name: "doc_no" }, { name: "total" }],
    },
    {
      key: "contacts.contact",
      label: "A contact",
      fields: [{ name: "email" }],
    },
  ])!;
  const fields = schema.fields as { properties: Record<string, unknown> };
  assertEquals(
    Object.keys(fields.properties).sort(),
    ["doc_no", "email", "total"],
  );
});

Deno.test("a column two targets share is described once", () => {
  // Two descriptions of one field is a field with contradictory
  // instructions, which is worse than one imperfect sentence.
  const schema = targetSchema([
    {
      key: "purchases.bill",
      label: "A bill",
      fields: [{ name: "doc_no", description: "The bill number." }],
    },
    {
      key: "purchases.purchase_order",
      label: "An order",
      fields: [{ name: "doc_no", description: "The order number." }],
    },
  ])!;
  const fields = schema.fields as {
    properties: Record<string, { description: string }>;
  };
  assertEquals(Object.keys(fields.properties), ["doc_no"]);
  assertEquals(fields.properties.doc_no.description, "The bill number.");
});

Deno.test("a field with no description still gets a question", () => {
  // A bare column name handed to a model is answered from the name
  // alone. This is a poor question and it is a question.
  const schema = targetSchema([
    { key: "purchases.bill", label: "A bill", fields: [{ name: "total_amount" }] },
  ])!;
  const fields = schema.fields as {
    properties: Record<string, { description: string }>;
  };
  assertStringIncludes(fields.properties.total_amount.description, "total amount");
  assertStringIncludes(fields.properties.total_amount.description, "as printed");
});

Deno.test("every field is nullable, because a page may not print it", () => {
  const schema = targetSchema([
    { key: "purchases.bill", label: "A bill", fields: [{ name: "doc_no" }] },
  ])!;
  const fields = schema.fields as {
    properties: Record<string, { type: string[] }>;
  };
  assertEquals(fields.properties.doc_no.type, ["string", "null"]);
});

Deno.test("the prompt names the kinds of paper that land there", () => {
  const said = targetPrompt([
    {
      key: "purchases.bill",
      label: "A supplier's bill",
      hint: "Becomes a bill.",
      kinds: ["Supplier's bill or invoice", "Receipt"],
      fields: [{ name: "doc_no", description: "The bill number." }],
    },
  ]);
  assertStringIncludes(said, "purchases.bill");
  assertStringIncludes(said, "A supplier's bill");
  // The kinds are the operator's own words for the paper, and they are
  // what a model recognises a letterhead against.
  assertStringIncludes(said, "Supplier's bill or invoice");
  assertStringIncludes(said, "doc_no — The bill number.");
  // And the instruction that keeps a bad guess out of the books.
  assertStringIncludes(said, "`target` is null");
});
