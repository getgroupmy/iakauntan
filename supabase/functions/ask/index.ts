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
 * Five things, all of them decided in the database and none of them
 * overridable from here:
 *
 *   * whether the caller belongs to the company at all;
 *   * whether the company holds the `ai` module;
 *   * whether there is credit to pay for the question — `ai_ask` takes
 *     the charge before a byte leaves the building, because the model
 *     bills for the attempt and charging afterwards would let a company
 *     at nil ask for ever;
 *   * what the assistant may read. Every tool call goes back through
 *     `public.ai_run_tool` on the *caller's* client, so RLS applies as
 *     the person asking;
 *   * which model answers, at whose expense, and with which key.
 *     `public.ai_call_config` decides that from `org_ai_settings` and
 *     the platform default, and 0536 is the argument for why.
 *
 * The fourth is the whole design. A clerk who cannot open the general
 * ledger cannot ask the assistant to read it out, and a tool name the
 * catalogue does not list is refused rather than run.
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
 * The one thing the service role is held for
 *
 * An earlier version of this file said it never held the service key,
 * and that was true while the provider key came out of the environment.
 * It now holds one, for a single call: `public.ai_call_config`, whose
 * EXECUTE is granted to the service role and to nobody else, and which
 * returns the address, the model and the key for one company.
 *
 * Nothing else uses it. Every tool the assistant runs still goes
 * through the caller's client, so what the assistant may READ is still
 * decided by the caller's own row policies. Fetching a credential and
 * reading a ledger are different jobs and this function is trusted with
 * the smaller one.
 *
 * ---------------------------------------------------------------------
 * Two wire shapes, and why that is all
 *
 * `ai_providers.wire` is either `anthropic` or `openai`.
 *
 * Anthropic's Messages API is its own thing: `system` is a top-level
 * field, the assistant turn comes back as content blocks that have to
 * be echoed whole, tool results go back as `tool_result` blocks in a
 * user turn, and the key goes in `x-api-key`.
 *
 * Everything else in the catalogue speaks the OpenAI chat-completions
 * shape: `system` is a role inside `messages`, tools are wrapped in a
 * `function` object, a tool call comes back on `message.tool_calls`
 * with its arguments as a JSON *string*, each result goes back as its
 * own `tool` message, and the key is a bearer token. OpenRouter,
 * DeepSeek, Qwen on DashScope, Cerebras, NVIDIA NIM and Gemini's
 * compatibility endpoint are all that shape, which is why one adapter
 * reaches all six.
 *
 * ---------------------------------------------------------------------
 * Why raw HTTP rather than a vendor SDK
 *
 * The same reason `ocr/index.ts` gives at length: every provider in this
 * directory is called with `fetch`, an unpinned `npm:` specifier would
 * let a library release change what a deployed function does without a
 * commit, and `supabase/functions/_local_check` type-checks this
 * directory offline with `--no-remote` against a stub for supabase-js
 * alone. It matters more now than it did with one provider, not less.
 */
import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { fail, json, logFailure, serveFunction } from "../_shared/cors.ts";
import {
  anthropicTools,
  chatUrl,
  openAiTools,
  parseArgs,
  type ToolSpec,
} from "./wire.ts";

const ANTHROPIC_VERSION = "2023-06-01";

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

interface OpenAiToolCall {
  id?: string;
  type?: string;
  function?: { name?: string; arguments?: string };
}

interface OpenAiMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | null;
  tool_calls?: OpenAiToolCall[];
  tool_call_id?: string;
}

/** What `public.ai_call_config` hands back. */
interface CallConfig {
  provider_code: string;
  wire: string;
  base_url: string;
  model_id: string;
  api_key: string;
  key_source: string;
}

/** A turn of the conversation as it is stored, before any wire shape. */
interface Turn {
  role: "user" | "assistant";
  content: string;
}

/** One tool the model asked for, and what came back. */
interface ToolOutcome {
  ok: boolean;
  content: string;
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

/**
 * A provider that would not answer.
 *
 * 429 and 529 are the two a person can do something about (wait); the
 * rest are ours. The provider is named in the log line and not in the
 * sentence, because "OpenRouter returned 502" is our problem to read
 * and "the assistant could not be reached" is what the person asking
 * needs to know.
 */
function providerFailure(
  provider: string,
  status: number,
  hadDetail: boolean,
): Response {
  const ref = logFailure(
    new Error(`${provider} ${status}`),
    "ask",
    { provider, status, had_detail: hadDetail },
  );
  const retryable = status === 429 || status === 529 || status === 503;
  return fail(
    retryable
      ? "The assistant is busy just now. Try again in a moment."
      : `The assistant could not be reached (reference ${ref}).`,
    retryable ? 503 : 502,
  );
}

/** Runs one tool on the caller's client. A refusal is content. */
async function runTool(
  caller: SupabaseClient,
  orgId: string,
  name: string,
  args: Record<string, unknown>,
): Promise<ToolOutcome> {
  const ran = await caller.rpc("ai_run_tool", {
    p_org_id: orgId,
    p_tool: name,
    p_args: args,
  });
  return ran.error
    ? { ok: false, content: ran.error.message }
    : { ok: true, content: JSON.stringify(ran.data ?? null) };
}

interface Loop {
  answer: string;
  used: { tool: string; arguments: Record<string, unknown> }[];
  failure?: Response;
}

/** The Messages API, with its content blocks echoed back whole. */
async function askAnthropic(
  cfg: CallConfig,
  specs: ToolSpec[],
  turns: Turn[],
  today: string,
  caller: SupabaseClient,
  orgId: string,
): Promise<Loop> {
  const tools = anthropicTools(specs);
  const messages: AnthropicMessage[] = turns.map((t) => ({
    role: t.role,
    content: t.content,
  }));
  const used: { tool: string; arguments: Record<string, unknown> }[] = [];
  let answer = "";

  for (let round = 0; round < MAX_ROUNDS; round++) {
    const last = round === MAX_ROUNDS - 1;
    const res = await fetch(cfg.base_url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": cfg.api_key,
        "anthropic-version": ANTHROPIC_VERSION,
      },
      body: JSON.stringify({
        model: cfg.model_id,
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
      return {
        answer,
        used,
        failure: providerFailure(cfg.provider_code, res.status, detail.length > 0),
      };
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
      const args = parseArgs(call.input);
      used.push({ tool: name, arguments: args });
      const out = await runTool(caller, orgId, name, args);
      results.push({
        type: "tool_result",
        tool_use_id: call.id,
        // A refusal is content, not an exception. Handed back with
        // `is_error` so the model treats it as "you may not read this"
        // rather than as data.
        is_error: !out.ok,
        content: out.content,
      });
    }
    messages.push({ role: "user", content: results });
  }

  return { answer, used };
}

/**
 * Chat completions, which is every other provider in the catalogue.
 *
 * The system prompt is a message rather than a field, each tool result
 * is its own `tool` message rather than a block inside a user turn, and
 * the assistant turn is echoed back as the object that arrived so that
 * a provider carrying extra fields on it does not lose them.
 */
async function askOpenAi(
  cfg: CallConfig,
  specs: ToolSpec[],
  turns: Turn[],
  today: string,
  caller: SupabaseClient,
  orgId: string,
): Promise<Loop> {
  const tools = openAiTools(specs);
  const messages: OpenAiMessage[] = [
    { role: "system", content: systemPrompt(today) },
    ...turns.map((t) => ({ role: t.role, content: t.content } as OpenAiMessage)),
  ];
  const used: { tool: string; arguments: Record<string, unknown> }[] = [];
  let answer = "";

  for (let round = 0; round < MAX_ROUNDS; round++) {
    const last = round === MAX_ROUNDS - 1;
    const res = await fetch(chatUrl(cfg.base_url), {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${cfg.api_key}`,
      },
      body: JSON.stringify({
        model: cfg.model_id,
        max_tokens: MAX_TOKENS,
        tools,
        // Same reasoning as the Anthropic branch: the conversation by
        // now carries tool calls and their results, and a request
        // carrying those with no tools declared is rejected by several
        // of these providers.
        tool_choice: last ? "none" : "auto",
        messages,
      }),
    });

    if (!res.ok) {
      const detail = await res.text().catch(() => "");
      return {
        answer,
        used,
        failure: providerFailure(cfg.provider_code, res.status, detail.length > 0),
      };
    }

    const reply = await res.json() as {
      choices?: {
        message?: OpenAiMessage;
        finish_reason?: string;
      }[];
    };
    const choice = reply.choices?.[0];
    const message = choice?.message;
    if (!message) break;

    messages.push(message);
    const text = typeof message.content === "string"
      ? message.content.trim()
      : "";
    if (text) answer = text;

    const calls = message.tool_calls ?? [];
    if (calls.length === 0) break;

    for (const call of calls) {
      const name = call.function?.name ?? "";
      const args = parseArgs(call.function?.arguments);
      used.push({ tool: name, arguments: args });
      const out = await runTool(caller, orgId, name, args);
      // There is no `is_error` on this shape, so a refusal has to say
      // in words that it is one — otherwise a model reads "not
      // permitted" as a report that came back empty, which is the whole
      // thing 0470 exists to stop.
      messages.push({
        role: "tool",
        tool_call_id: call.id ?? "",
        content: out.ok ? out.content : `REFUSED: ${out.content}`,
      });
    }
  }

  return { answer, used };
}

serveFunction("ask", async (req) => {
  if (req.method !== "POST") return fail("POST a question", 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) {
    return fail("This function is not configured", 500);
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

  // The one service-role call in this function, for the one thing the
  // caller must not be able to read: which provider, at which address,
  // with whose key.
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false },
  });
  const conf = await admin.rpc("ai_call_config", { p_org_id: orgId });
  if (conf.error) return fail(conf.error.message, 503);
  const cfg = (Array.isArray(conf.data) ? conf.data[0] : conf.data) as
    | CallConfig
    | undefined;
  if (!cfg?.api_key || !cfg?.base_url || !cfg?.model_id) {
    return fail(
      "The assistant has no provider set up on this deployment yet.",
      503,
    );
  }

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
  const turns: Turn[] = [];
  for (const m of stored) {
    if (m.role !== "user" && m.role !== "assistant") continue;
    const content = typeof m.content === "string" ? m.content : "";
    if (!content) continue;
    turns.push({ role: m.role === "user" ? "user" : "assistant", content });
  }

  // `ai_ask` has already stored this question, so it is in `stored`
  // above — unless this is a brand new conversation read back before
  // the insert was visible, which the belt-and-braces below covers.
  if (
    turns.length === 0 ||
    turns[turns.length - 1].content !== question.trim()
  ) {
    turns.push({ role: "user", content: question.trim() });
  }

  const today = new Date().toISOString().slice(0, 10);
  const loop = cfg.wire === "anthropic"
    ? await askAnthropic(cfg, specs, turns, today, caller, orgId)
    : await askOpenAi(cfg, specs, turns, today, caller, orgId);
  if (loop.failure) return loop.failure;

  const answer = loop.answer ||
    "I could not get to an answer for that one. Try asking for " +
      "a particular report, or a narrower period.";

  // Stored under the caller's token, in the conversation they own.
  const said = await caller.rpc("ai_answer", {
    p_conversation: conversationId,
    p_content: answer,
    p_tool_calls: loop.used,
  });
  if (said.error) {
    // The answer exists and was paid for; failing to file it should not
    // also lose it.
    logFailure(new Error(said.error.message), "ask", { stage: "store" });
  }

  return json(
    { conversation_id: conversationId, answer, tool_calls: loop.used },
    200,
    req,
  );
});
