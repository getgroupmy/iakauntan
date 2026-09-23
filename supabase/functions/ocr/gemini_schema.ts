/**
 * Our extraction schema, in the dialect Gemini's `responseSchema` reads.
 *
 * `0701`. AI SmartScan called Gemini through Google's
 * OPENAI-COMPATIBILITY endpoint — `/v1beta/openai/chat/completions` —
 * whose message parts are text and `image_url` and nothing else. So a
 * PDF was refused by name, and everybody was told "this reader takes
 * photographs, not PDFs". Which was true of the road we took and false
 * of the model: Gemini's own `generateContent` takes `inline_data` with
 * `application/pdf` and reads documents directly.
 *
 * Moving to the native endpoint means moving to the native schema
 * dialect, and it differs from JSON Schema in two ways that matter
 * here. Both are silent: Gemini answers 400 with a message about the
 * schema, which reads like our prompt is wrong rather than our
 * translation.
 *
 *   * NO `additionalProperties`. It is how OpenAI's strict mode is
 *     told the shape is closed, and Gemini rejects the key outright.
 *   * NO UNION TYPES. Every field in `SCHEMA` is `["string", "null"]`
 *     or `["number", "null"]`, because a reader that cannot find a
 *     figure must say so rather than guess a zero — that distinction is
 *     the whole of `showScanResult`'s "absent rather than zero". Gemini
 *     spells it `type: "string", nullable: true`.
 *
 * Pure, and its own module, because a translation that is wrong is a
 * 400 from a vendor at scan time and there is nothing in the answer
 * that says which key did it.
 */

/** A JSON-Schema-ish node, as `SCHEMA` and the platform's targets write them. */
export type SchemaNode = Record<string, unknown>;

/**
 * Keys Gemini understands. Anything else is dropped rather than passed
 * through: the platform can add a field to a scan target (`0681`) and
 * whatever it writes reaches this function, so an unknown key is a
 * question of when rather than whether.
 */
const KEPT = new Set([
  "type",
  "format",
  "description",
  "nullable",
  "enum",
  "items",
  "properties",
  "required",
  "minItems",
  "maxItems",
]);

/**
 * The whole schema, translated. Typed as a node in and a node out,
 * because that is what the caller has and what `responseSchema` wants;
 * the recursion below carries `unknown` because a child may be a
 * string, a list or a node.
 */
export function geminiSchema(node: SchemaNode): SchemaNode {
  return translate(node) as SchemaNode;
}

function translate(node: unknown): unknown {
  if (Array.isArray(node)) return node.map(translate);
  if (node === null || typeof node !== "object") return node;

  const src = node as SchemaNode;
  const out: SchemaNode = {};

  for (const [key, value] of Object.entries(src)) {
    if (!KEPT.has(key)) continue;

    if (key === "type") {
      // `["string", "null"]` -> `"string"` + `nullable: true`. The
      // order is not guaranteed and `null` may be the only member of a
      // one-element union, so this reads the list rather than
      // indexing it.
      if (Array.isArray(value)) {
        const named = value.filter((t) => t !== "null");
        if (value.includes("null")) out.nullable = true;
        // A type that is ONLY null has no Gemini spelling. `string`
        // plus nullable is the honest reading: a field that can only
        // be absent.
        out.type = named.length > 0 ? String(named[0]) : "string";
      } else {
        out.type = value;
      }
      continue;
    }

    if (key === "properties") {
      const props: SchemaNode = {};
      for (const [name, child] of Object.entries(value as SchemaNode)) {
        props[name] = translate(child);
      }
      out.properties = props;
      continue;
    }

    out[key] = key === "items" ? translate(value) : value;
  }

  // `required` naming a property that is not there is a 400. It can
  // happen honestly: `requiredWith` in `index.ts` adds every extra
  // field a platform configures, and a target could name one and then
  // be edited.
  if (Array.isArray(out.required) && out.properties) {
    const have = new Set(Object.keys(out.properties as SchemaNode));
    out.required = (out.required as unknown[]).filter(
      (r) => typeof r === "string" && have.has(r),
    );
  }

  return out;
}
