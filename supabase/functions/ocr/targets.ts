/**
 * Where a scanned paper can go, and what each destination needs.
 *
 * Its own module for the reason `pool.ts` is: importing `index.ts`
 * runs `_shared/cors.ts`, which reads `ALLOWED_ORIGINS` at load, so a
 * test of two pure functions over JSON would need `--allow-env` and
 * would be importing an HTTP handler to ask it a question about a
 * schema.
 */

/** One destination, as `public.scan_extraction_targets` describes it. */
export interface ScanTarget {
  key: string;
  label: string;
  hint?: string | null;
  kinds?: string[] | null;
  fields?: { name: string; description?: string | null }[] | null;
}

/**
 * Anything that is not a usable target, dropped.
 *
 * The database already refuses to return a target with no fields, and
 * this refuses one again — because the schema built below turns an
 * empty field list into an `enum` choice the model can make and then
 * have nothing to fill, which reads to a bookkeeper as the scan having
 * understood the document and lost it.
 */
export function usableTargets(raw: unknown): ScanTarget[] {
  if (!Array.isArray(raw)) return [];
  const out: ScanTarget[] = [];
  for (const t of raw) {
    if (!t || typeof t !== "object") continue;
    const key = (t as ScanTarget).key;
    const fields = (t as ScanTarget).fields;
    if (typeof key !== "string" || key === "") continue;
    if (!Array.isArray(fields) || fields.length === 0) continue;
    const named = fields.filter(
      (f) => f && typeof f.name === "string" && f.name !== "",
    );
    if (named.length === 0) continue;
    out.push({
      key,
      label: typeof (t as ScanTarget).label === "string"
        ? (t as ScanTarget).label
        : key,
      hint: (t as ScanTarget).hint ?? null,
      kinds: Array.isArray((t as ScanTarget).kinds)
        ? (t as ScanTarget).kinds!.filter((k) => typeof k === "string")
        : [],
      fields: named,
    });
  }
  return out;
}

/**
 * The part of the JSON schema that asks where this document goes.
 *
 * Two properties rather than one per target. `target` is the choice —
 * an enum, plus null, because "I do not know" has to be sayable or it
 * gets guessed — and `fields` is a FLAT map of every askable column
 * across every target.
 *
 * Flat on purpose. A schema nested per target would make the model
 * commit to a branch before it has read the page, and would repeat
 * every column that two targets share; flat, it fills what it can see
 * and the `target` says which set of them was the point. Column names
 * collide across targets on purpose too — `document_no` means the same
 * thing wherever it lands.
 */
export function targetSchema(
  targets: ScanTarget[],
): Record<string, unknown> | null {
  if (targets.length === 0) return null;

  const properties: Record<string, unknown> = {};
  for (const t of targets) {
    for (const f of t.fields ?? []) {
      const existing = properties[f.name] as { description?: string } | undefined;
      const line = f.description?.trim();
      if (existing) {
        // Two targets want the same column. Keep the first sentence and
        // do not concatenate: two descriptions of one field is a field
        // with contradictory instructions.
        continue;
      }
      properties[f.name] = {
        type: ["string", "null"],
        description: line && line !== ""
          ? line
          : `The document's ${f.name.replace(/_/g, " ")}, exactly as ` +
            "printed. Null if it is not on the page.",
      };
    }
  }

  return {
    target: {
      type: ["string", "null"],
      description:
        "Which of these this document is, by key: " +
        targets.map((t) => `${t.key} (${t.label})`).join("; ") +
        ". Null if it is none of them — a document you cannot place is " +
        "better placed nowhere than placed wrongly.",
      enum: [...targets.map((t) => t.key), null],
    },
    fields: {
      type: ["object", "null"],
      additionalProperties: false,
      description:
        "Values for the chosen destination, as printed. Every key is " +
        "optional and null means it is not on the document.",
      properties,
    },
  };
}

/** The lines added to the system prompt, or "" when nothing is set up. */
export function targetPrompt(targets: ScanTarget[]): string {
  if (targets.length === 0) return "";
  const lines = [
    "",
    "This document is going somewhere. Decide which of these it is and",
    "fill in what that one needs. Transcribe; do not infer a field from",
    "another field, and leave null anything the page does not print.",
    "",
  ];
  for (const t of targets) {
    const kinds = (t.kinds ?? []).filter((k) => k);
    lines.push(
      `${t.key} — ${t.label}` +
        (kinds.length > 0 ? ` (${kinds.join(", ")})` : "") +
        (t.hint ? `. ${t.hint}` : ""),
    );
    for (const f of t.fields ?? []) {
      lines.push(
        `    ${f.name}${f.description ? ` — ${f.description}` : ""}`,
      );
    }
  }
  lines.push(
    "",
    "If it is none of them, `target` is null and `fields` is null. A",
    "document placed wrongly costs more than one placed nowhere: the",
    "first becomes a record somebody has to find and undo.",
  );
  return lines.join("\n");
}
