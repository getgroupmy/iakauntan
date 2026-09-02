/**
 * ask
 *
 * "Ask about your books." A question in a sentence, answered from the
 * company's own posted figures rather than from a model's memory of
 * what accounting usually looks like.
 *
 * POST { "org_id": "<uuid>", "question": "...", "conversation_id"?: "<uuid>" }
 *   -> { conversation_id, answer, tool_calls: [{ tool, arguments }] }
 *
 * ---------------------------------------------------------------------
 * What this function is not allowed to decide
 *
 * Four things, all of them decided in the database under the *caller's*
 * own token, and none of them overridable from here:
 *
 *   * whether the caller belongs to the company at all;
 *   * whether the company holds the `ai` module;
 *   * whether there is credit to pay for the question — `ai_ask` takes
 *     the charge before a byte leaves the building, because the model
 *     bills for the attempt and charging afterwards would let a company
 *     at nil ask for ever;
 *   * what the assistant may read. Every tool call goes back through
 *     `public.ai_run_tool` on the caller's client, so RLS applies as
 *     the person asking. This function never holds the service key.
 *
 * That last one is the whole design. A clerk who cannot open the
 * general ledger cannot ask the assistant to read it out, and a tool
 * name the catalogue does not list is refused rather than run.
 *
 * `ai_run_tool` *raises* when the caller may not read something, rather
 * than returning an empty list — 0470's note on that is worth
 * repeating here, because this file is the reason it matters: a model
 * handed `[]` does not say "you may not see this", it says "there is
 * nothing outstanding", confidently, about books it was never shown.
 * The refusal is passed to the model verbatim as a tool result, so it
 * says what actually happened.
 *
 * ---------------------------------------------------------------------
 * Why raw HTTP rather than the Anthropic SDK
 *
 * The same reason `ocr/index.ts` gives at length, and the same wire
 * version pinned the same way: every provider in this directory is
 * called with `fetch`, an unpinned `npm:` specifier would let a library
 * release change what a deployed function does without a commit, and
 * `supabase/functions/_local_check` type-checks this directory offline
 * with `--no-remote` against a stub for supabase-js alone.
 *
 * Secrets, none of which are in the repository or the database:
 *   AI_ANTHROPIC_API_KEY   the key this function calls Claude with.
 *                          `OCR_KEY_CLAUDE` is read as a fallback so a
 *                          deployment that already has one key does not
 *                          need two.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { fail, json, logFailure, serveFunction } from "../_shared/cors.ts";

const ANTHROPIC_VERSION = "2023-06-01";
const MODEL = "claude-opus-5";

/**
 * How many times the model may go round asking for another report.
 *
 * A real question takes two or three: read the trial balance, then the
 * ledger for the one account that looks wrong. The cap is not a
 * performance decision — it is what stops a loop that has misread its
 * own tool result from spending the company's credit on the same call
 * forever. When it is reached the model is told so and asked to answer
 * with what it has, which is a worse answer than it might have given
 * and a much better one than no answer and a silent bill.
 */
const MAX_ROUNDS = 8;

/** Long enough for a question that reads three reports. */
const MAX_TOKENS = 4096;

interface ToolSpec {
  name: string;
  description: string;
  arguments: {
    name: string;
    type: string;
    required?: boolean;
    description?: string;
  }[];
}

interface ContentBlock {
  type: string;
  text?: string;
  id?: string;
  name?: string;
  input?: Record<string, unknown>;
  [key: string]: unknown;
}

interface AnthropicMessage {
  role: "user" | "assistant";
  content: string | ContentBlock[];
}

/**
 * The catalogue, in the shape the Messages API wants.
 *
 * Every argument is a string on the wire and cast to its declared type
 * inside `ai_run_tool`; describing them as strings here rather than as
 * numbers or dates is deliberate, because the cast that matters is the
 * one the database makes and a second opinion about the type would only
 * be a second place for it to be wrong.
 */
function toolsFor(specs: ToolSpec[]): unknown[] {
  return specs.map((t) => {
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
    return {
      name: t.name,
      description: t.description,
      input_schema: { type: "object", properties, required },
    };
  });
}

/** What the model is told about the job, once. */
function systemPrompt(today: string): string {
  return [
    "You answer questions about one Malaysian company's own accounting",
    "records, using only the tools provided. Today is " + today + ".",
    "",
    "Read before you answer. Do not estimate a figure you could fetch,",
    "and do not carry a number from one answer into the next without",
    "re-reading it — the books change while you are talking.",
    "",
    "Every figure you state must come from a tool result in this",
    "conversation. If the tools cannot answer the question, say which",
    "part you could not get and why, rather than filling the gap. If a",
    "tool refuses — it will say so plainly — that means the person",
    "asking is not allowed to see it: tell them that, and never present",
    "a refusal as an empty result or as 'nothing outstanding'.",
    "",
    "Amounts are Malaysian ringgit unless a report says otherwise; write",
    "them as RM 1,234.56. Be brief. A number and the one sentence that",
    "explains it beats a paragraph of hedging.",
  ].join("\n");
}

serveFunction("ask", async (req) => {
  if (req.method !== "POST") return fail("POST a question", 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const apiKey = Deno.env.get("AI_ANTHROPIC_API_KEY") ??
    Deno.env.get("OCR_KEY_CLAUDE");
  if (!url || !anonKey) return fail("This function is not configured", 500);
  if (!apiKey) {
    return fail("The assistant has no key configured on this deployment", 503);
  }

  const body = await req.json().catch(() => ({}));
  const orgId = typeof body?.org_id === "string" ? body.org_id : null;
  const question = typeof body?.question === "string" ? body.question : null;
  const priorId = typeof body?.conversation_id === "string"
    ? body.conversation_id
    : null;
  if (!orgId || !question?.trim()) {
    return fail("Say which company, and ask something", 400);
  }

  // The caller's own token, and nothing else. Somebody presenting only
  // the publishable key is `anon`, belongs to no company, and is
  // refused by the guards inside every function called below.
  const caller = createClient(url, anonKey, {
    auth: { persistSession: false },
    global: {
      headers: { Authorization: req.headers.get("Authorization") ?? "" },
    },
  });

  // Records the question, charges for it, and refuses when the module
  // is off, the credit is gone, or the conversation belongs to somebody
  // else. Its refusals are already written for a person to read, so
  // they are passed through rather than flattened.
  const asked = await caller.rpc("ai_ask", {
    p_org_id: orgId,
    p_question: question,
    p_conversation: priorId,
  });
  if (asked.error) return fail(asked.error.message, 403);
  const conversationId = asked.data as unknown as string;

  const [cat, convo] = await Promise.all([
    caller.rpc("ai_tool_catalogue", { p_org_id: orgId }),
    caller.rpc("ai_conversation", { p_id: conversationId }),
  ]);
  if (cat.error) return fail(cat.error.message, 403);
  if (convo.error) return fail(convo.error.message, 403);

  const specs = (cat.data ?? []) as unknown as ToolSpec[];
  const stored = ((convo.data as { messages?: unknown[] })?.messages ??
    []) as { role: string; content: string }[];

  // The conversation so far, as plain turns. Tool results are not
  // replayed: they are yesterday's figures, and a model shown them
  // would quote a balance that has since moved. What is kept is what
  // was asked and what was said.
  const messages: AnthropicMessage[] = [];
  for (const m of stored) {
    if (m.role !== "user" && m.role !== "assistant") continue;
    const content = typeof m.content === "string" ? m.content : "";
    if (!content) continue;
    messages.push({ role: m.role === "user" ? "user" : "assistant", content });
  }

  // `ai_ask` has already stored this question, so it is in `stored`
  // above — unless this is a brand new conversation read back before
  // the insert was visible, which the belt-and-braces below covers.
  if (
    messages.length === 0 ||
    messages[messages.length - 1].content !== question.trim()
  ) {
    messages.push({ role: "user", content: question.trim() });
  }

  const today = new Date().toISOString().slice(0, 10);
  const tools = toolsFor(specs);
  const used: { tool: string; arguments: Record<string, unknown> }[] = [];
  let answer = "";

  for (let round = 0; round < MAX_ROUNDS; round++) {
    const last = round === MAX_ROUNDS - 1;
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": ANTHROPIC_VERSION,
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: MAX_TOKENS,
        system: systemPrompt(today),
        // Adaptive: the model decides how much thinking a question is
        // worth. "What is my cash balance" is one call; "why is my
        // gross margin down" is three reports and an argument about
        // what changed between them.
        thinking: { type: "adaptive" },
        // On the last round the model is told to answer with what it
        // holds rather than reach for another report.
        //
        // `tool_choice: none` rather than dropping `tools`, which is
        // what this did first and was wrong: by the last round the
        // conversation already carries `tool_use` and `tool_result`
        // blocks, and a request containing those with no `tools`
        // defined is rejected. So the one round that exists to salvage
        // an answer would have been the one that failed outright —
        // and only on the long questions, which is exactly when it
        // matters.
        tools,
        ...(last ? { tool_choice: { type: "none" } } : {}),
        messages,
      }),
    });

    if (!res.ok) {
      const detail = await res.text().catch(() => "");
      const ref = logFailure(
        new Error(`Anthropic ${res.status}`),
        "ask",
        { status: res.status, had_detail: detail.length > 0 },
      );
      // 429 and 529 are the two a person can do something about
      // (wait); the rest are ours.
      const retryable = res.status === 429 || res.status === 529;
      return fail(
        retryable
          ? "The assistant is busy just now. Try again in a moment."
          : `The assistant could not be reached (reference ${ref}).`,
        retryable ? 503 : 502,
      );
    }

    const reply = await res.json() as {
      content?: ContentBlock[];
      stop_reason?: string;
    };
    const blocks = reply.content ?? [];

    // Kept whole, including any thinking blocks: the API requires the
    // assistant turn to be echoed back exactly as it came, and trimming
    // it to the text is how a tool-use loop starts failing on the
    // second round.
    messages.push({ role: "assistant", content: blocks });

    const text = blocks
      .filter((b) => b.type === "text" && typeof b.text === "string")
      .map((b) => b.text as string)
      .join("\n")
      .trim();
    if (text) answer = text;

    const calls = blocks.filter((b) => b.type === "tool_use");
    if (reply.stop_reason !== "tool_use" || calls.length === 0) break;

    const results: ContentBlock[] = [];
    for (const call of calls) {
      const name = call.name ?? "";
      const args = (call.input ?? {}) as Record<string, unknown>;
      used.push({ tool: name, arguments: args });

      // On the caller's client. This is the line that makes the
      // assistant see exactly what the person asking may see.
      const ran = await caller.rpc("ai_run_tool", {
        p_org_id: orgId,
        p_tool: name,
        p_args: args,
      });

      results.push({
        type: "tool_result",
        tool_use_id: call.id,
        // A refusal is content, not an exception. Handed back with
        // `is_error` so the model treats it as "you may not read this"
        // rather than as data.
        is_error: Boolean(ran.error),
        content: ran.error
          ? ran.error.message
          : JSON.stringify(ran.data ?? null),
      });
    }
    messages.push({ role: "user", content: results });
  }

  if (!answer) {
    answer = "I could not get to an answer for that one. Try asking for " +
      "a particular report, or a narrower period.";
  }

  // Stored under the caller's token, in the conversation they own.
  const said = await caller.rpc("ai_answer", {
    p_conversation: conversationId,
    p_content: answer,
    p_tool_calls: used,
  });
  if (said.error) {
    // The answer exists and was paid for; failing to file it should not
    // also lose it.
    logFailure(new Error(said.error.message), "ask", { stage: "store" });
  }

  return json(
    { conversation_id: conversationId, answer, tool_calls: used },
    200,
    req,
  );
});
