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

  /**
   * The fields describe ONE ROW of many. `0682`.
   *
   * A bank statement is what this exists for: a date, a description, an
   * amount and a balance, the same four on every printed line. Asking
   * for one object would get the first line, or an average of them, or
   * whichever the model thought was most important — all three of which
   * look like an answer.
   */
  repeats?: boolean;
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
      repeats: (t as ScanTarget).repeats === true,
      kinds: Array.isArray((t as ScanTarget).kinds)
        ? (t as ScanTarget).kinds!.filter((k) => typeof k === "string")
        : [],
      fields: named,
    });
  }
  return out;
}

/**
 * The one destination the CALLER already knows, where they named it.
 *
 * ## The failure this exists for
 *
 * Somebody presses "Upload" inside the bank statement importer, beside
 * a named bank account. There is no ambiguity left: they have said what
 * the document is and where it goes. And the reader was still asked to
 * pick from seven destinations with no hint — so a statement that read
 * perfectly could come back classified as a bill, with `rows` null and
 * nothing to import, reported to the person as "nothing on that
 * document read as statement lines".
 *
 * Narrowing does three things at once: `rows` is certainly in the
 * schema, the prompt stops describing six destinations that are not
 * this one, and every field of those six stops being asked for — which
 * on a long statement is output budget spent on nulls.
 *
 * ## Null is still sayable, and that is deliberate
 *
 * The enum becomes "this key, or null". Somebody who pressed Upload on
 * the wrong file has said something untrue, and the reader must be able
 * to disagree — `targetPrompt` tells it so in as many words. What it
 * must NOT do is quietly pick a different destination, because the
 * screen that asked has nowhere to put one.
 *
 * ## An unknown key widens rather than narrows
 *
 * A caller naming a destination this platform has not configured is a
 * caller out of step with the database, and the right answer is the
 * behaviour it had before — every target offered — not a reader with
 * nothing to choose from at all.
 */
export function narrowToTarget(
  targets: ScanTarget[],
  key: string | null | undefined,
): ScanTarget[] {
  const wanted = (key ?? "").trim();
  if (wanted === "") return targets;
  const found = targets.filter((t) => t.key === wanted);
  return found.length === 0 ? targets : found;
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
    // A repeating target's columns belong in `rows` and NOWHERE ELSE.
    // Offered in both, a model is invited to answer both — and a
    // statement's running balance filled in once at the top and again
    // per line is two answers that disagree, with nothing to say which
    // was meant.
    if (t.repeats) continue;
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

  const schema: Record<string, unknown> = {
    target: {
      type: ["string", "null"],
      description:
        "Which of these this document is, by key: " +
        targets.map((t) => `${t.key} (${t.label})`).join("; ") +
        ". Null if it is none of them — a document you cannot place is " +
        "better placed nowhere than placed wrongly.",
      enum: [...targets.map((t) => t.key), null],
    },
  };

  // Only where some target takes one record. A `fields` with no
  // properties is a key that can never be anything but `{}`, which is
  // one more thing for a model to think about and fill in wrongly.
  if (Object.keys(properties).length > 0) {
    schema.fields = {
      type: ["object", "null"],
      additionalProperties: false,
      // As above. `additionalProperties: false` without `required` is
      // what a vendor in strict mode rejects, and the rejection reads
      // as the document being unreadable.
      required: Object.keys(properties),
      description:
        "Values for the chosen destination, as printed. Every key is " +
        "required and null means it is not on the document. Leave this " +
        "whole object null when the destination you chose takes rows " +
        "instead.",
      properties,
    };
  }

  // `rows` exists only where some target repeats. A bank statement is
  // not one record with fields, it is forty of them with the same four
  // — and a schema that offered only `fields` would get the first line,
  // or an average, or whichever line the model thought mattered. All
  // three look like an answer.
  if (targets.some((t) => t.repeats)) {
    const rowProps = rowProperties(targets);
    schema.rows = {
      type: ["array", "null"],
      description:
        "One entry per printed line, for a destination that takes rows: " +
        targets.filter((t) => t.repeats).map((t) => t.key).join(", ") +
        ". In the order printed, every line, including the ones that " +
        "look like a running total — a statement with lines missing " +
        "reconciles to nothing. Null when the destination takes one " +
        "record instead.",
      items: {
        type: "object",
        additionalProperties: false,
        // Every property named, here as at the top level. Strict mode
        // applies to NESTED objects too, and a row schema missing this
        // is the same 400 one level down.
        required: Object.keys(rowProps),
        properties: rowProps,
      },
    };
  }

  return schema;
}

/** The columns a repeating target wants, per row. */
function rowProperties(targets: ScanTarget[]): Record<string, unknown> {
  const properties: Record<string, unknown> = {};
  for (const t of targets) {
    if (!t.repeats) continue;
    for (const f of t.fields ?? []) {
      if (properties[f.name]) continue;
      const line = f.description?.trim();
      properties[f.name] = {
        type: ["string", "null"],
        description: line && line !== ""
          ? line
          : `This line's ${f.name.replace(/_/g, " ")}, exactly as ` +
            "printed. Null if the line does not carry it.",
      };
    }
  }
  return properties;
}

/**
 * The lines added to the system prompt, or "" when nothing is set up.
 *
 * [known] says the CALLER already named the destination — see
 * `narrowToTarget`. The wording changes completely, and it has to: "one
 * of these seven, you decide" and "this is a bank statement, transcribe
 * it" are different jobs, and a reader told the second does the second
 * far better than a reader left to infer it.
 */
export function targetPrompt(targets: ScanTarget[], known = false): string {
  if (targets.length === 0) return "";
  const lines = known && targets.length === 1
    ? [
      "",
      `This document has ALREADY BEEN IDENTIFIED as: ${targets[0].label}.`,
      "The person handing it to you said so, on a screen that does",
      "nothing else. Do not spend effort deciding what it is — fill in",
      "what it needs, from the page.",
      "",
      "If the page is plainly NOT that — they picked the wrong file —",
      "`target` is null and you say why in `note`. Do not quietly",
      "choose something else instead: the screen that asked has nowhere",
      "to put a different answer, so it would be thrown away.",
      "",
    ]
    : [
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
        (t.hint ? `. ${t.hint}` : "") +
        (t.repeats
          ? ". ONE ENTRY PER PRINTED LINE, in `rows` rather than " +
            "`fields`. Every line, in the order printed."
          : ""),
    );
    for (const f of t.fields ?? []) {
      lines.push(
        `    ${f.name}${f.description ? ` — ${f.description}` : ""}`,
      );
    }
  }
  if (!known) {
    lines.push(
      "",
      "If it is none of them, `target` is null and `fields` is null. A",
      "document placed wrongly costs more than one placed nowhere: the",
      "first becomes a record somebody has to find and undo.",
    );
  }
  return lines.join("\n");
}

/**
 * The `required` list a schema needs once the target properties are in
 * it.
 *
 * Its own function, and tested, because getting it wrong is silent at
 * every layer this repository controls and loud only at the vendor:
 * `SCHEMA` is `strict: true` with `additionalProperties: false`, and
 * OpenAI's strict mode rejects a schema whose `properties` are not all
 * named in `required`. The rejection arrives as a 400 that the edge
 * function reports as "The document could not be read", which is what
 * it says about everything.
 *
 * Deduplicated: a repeated name is accepted by some vendors and
 * rejected by others, and that is cheaper to make impossible than to
 * find out.
 */
export function requiredWith(
  base: readonly string[],
  extra: Record<string, unknown> | null,
): string[] {
  return [...new Set([...base, ...Object.keys(extra ?? {})])];
}

/**
 * How many output tokens to allow for one reading.
 *
 * ## Why this is not a constant
 *
 * It was 4000 at all three readers, and 4000 is right for what this
 * function was built to read: a receipt has fourteen fields and a
 * handful of lines, and a bigger budget on it buys nothing but a longer
 * wait if the model rambles.
 *
 * A BANK STATEMENT is not that. It is one record per printed line, and
 * a line of this JSON — a date, a narration a bank wrote, a reference,
 * an amount and a running balance — costs somewhere around fifty-five
 * tokens. So 4000 tokens is about SEVENTY LINES, and a one-month
 * business current account routinely runs to two or three hundred.
 *
 * What happened then was not a partial answer. It was
 * `stop_reason: max_tokens`, which this function turns into "The
 * document was too long to read in one pass" — reported to somebody who
 * had just photographed their statement as the scan having failed, with
 * advice ("attach the page with the totals on it") that means nothing
 * for a statement.
 *
 * ## Read off the schema rather than passed down
 *
 * `rows` is in the schema exactly when some target repeats, which is
 * exactly when the answer is many records instead of one. So the budget
 * follows the question without a flag to set, and a destination marked
 * `repeats` in the console gets the room it needs on the next scan.
 *
 * The cap is the VENDOR'S, because exceeding it is a 400 rather than a
 * truncation: Gemini 2.0 Flash tops out at 8192 output tokens where
 * Claude and the OpenAI-shaped endpoints go far higher. Asking for more
 * than the model can give turns a long statement into a refusal, which
 * is the failure this exists to remove.
 *
 * ## It looks under `properties`, and that is the whole of the bug it
 * ## was written with
 *
 * `targetSchema` returns `{ target, fields, rows }` — `rows` at the top.
 * What the READERS are handed is not that. `index.ts` spreads it into
 * the base schema's properties:
 *
 *     { ...SCHEMA, properties: { ...SCHEMA.properties, ...extra } }
 *
 * so by the time a reader sees it, `rows` is at `schema.properties.rows`
 * and `"rows" in schema` is FALSE. Written the obvious way, this
 * returned 4000 for every statement in production while its test —
 * which asked `targetSchema` directly — passed.
 *
 * Both shapes are accepted because both are real: the assembled one is
 * what ships, and the bare one is what a caller building a schema by
 * hand has. The test asserts the ASSEMBLED shape, because that is the
 * one that was wrong.
 */
export function outputBudget(
  schema: Record<string, unknown>,
  cap: number,
): number {
  const props = (schema.properties ?? schema) as Record<string, unknown>;
  const wanted = "rows" in props ? 16000 : 4000;
  return Math.min(wanted, cap);
}

/**
 * What to say when the reader ran out of room.
 *
 * Two different sentences because they are two different situations
 * with two different remedies. "Attach the page with the totals on it"
 * is sound advice about a forty-page lease and useless about a bank
 * statement, where every page is the point and the totals page is the
 * one part nobody needs.
 */
export function tooLongMessage(schema: Record<string, unknown>): string {
  const props = (schema.properties ?? schema) as Record<string, unknown>;
  if ("rows" in props) {
    return "The statement was too long to read in one pass. Send it a " +
      "few pages at a time, or export it as CSV or MT940 from online " +
      "banking — those are read here rather than by a model, and have " +
      "no length limit.";
  }
  return "The document was too long to read in one pass. Attach the page " +
    "with the totals on it.";
}
