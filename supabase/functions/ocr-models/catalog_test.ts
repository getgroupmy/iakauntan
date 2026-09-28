import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  cannotAsk,
  modelQuery,
  modelsFrom,
  sorted,
} from "./catalog.ts";

// ---------------------------------------------------------------------
// Where to ask
// ---------------------------------------------------------------------

Deno.test("the Anthropic list sits beside the messages endpoint", () => {
  const q = modelQuery(
    "anthropic",
    "https://api.anthropic.com/v1/messages",
    "sk-ant-x",
  );
  assertEquals(q.url, "https://api.anthropic.com/v1/models");
  assertEquals(q.headers["x-api-key"], "sk-ant-x");
  // Anthropic refuses a request with no version header, including this
  // one, and the refusal says nothing about the missing header.
  assertEquals(q.headers["anthropic-version"], "2023-06-01");
});

Deno.test("the chat-completions list drops both path segments", () => {
  assertEquals(
    modelQuery("openai", "https://api.openai.com/v1/chat/completions", "k").url,
    "https://api.openai.com/v1/models",
  );
  // Same shape, different vendor, no second code path.
  assertEquals(
    modelQuery("openai", "https://api.x.ai/v1/chat/completions", "k").url,
    "https://api.x.ai/v1/models",
  );
});

Deno.test("a chat-completions row that is already a base still works", () => {
  assertEquals(
    modelQuery("openai", "https://gateway.example/v1", "k").url,
    "https://gateway.example/v1/models",
  );
});

Deno.test("a pasted trailing slash does not become a double one", () => {
  // `//models` is routed by some gateways and 404s on others, which is
  // the kind of difference that only shows up in production.
  assertEquals(
    modelQuery("google_gemini", "https://generativelanguage.googleapis.com/v1beta/", "k")
      .url,
    "https://generativelanguage.googleapis.com/v1beta/models",
  );
  assertEquals(
    modelQuery("openai", "https://api.openai.com/v1/chat/completions/", "k").url,
    "https://api.openai.com/v1/models",
  );
});

Deno.test("the word messages inside a path is not rewritten", () => {
  // Anchored at the end: a proxy mounted under `/messages/v1/messages`
  // must lose only the last one.
  assertEquals(
    modelQuery("anthropic", "https://proxy.example/messages/v1/messages", "k")
      .url,
    "https://proxy.example/messages/v1/models",
  );
});

Deno.test("Gemini's key goes in a header, never the query string", () => {
  const q = modelQuery(
    "google_gemini",
    "https://generativelanguage.googleapis.com/v1beta",
    "AIza-secret",
  );
  assertEquals(q.headers["x-goog-api-key"], "AIza-secret");
  // A key in the URL is a key in every access log between here and
  // Google.
  assertEquals(q.url.includes("AIza-secret"), false);
});

// ---------------------------------------------------------------------
// The readers that have no list
// ---------------------------------------------------------------------

Deno.test("three kinds have nothing to ask, and say why", () => {
  for (const kind of ["google_docai", "device", "self_hosted"]) {
    const why = cannotAsk(kind);
    assertEquals(typeof why, "string", kind);
    assertEquals((why ?? "").length > 20, true, kind);
    // And asking anyway is refused with that same sentence rather than
    // an empty list, which an operator would read as "no models".
    assertThrows(() => modelQuery(kind, "https://x", "k"), Error, why ?? "");
  }
});

Deno.test("the three that can be asked are not refused", () => {
  for (const kind of ["anthropic", "openai", "google_gemini"]) {
    assertEquals(cannotAsk(kind), null, kind);
  }
});

Deno.test("a kind nobody has handled throws rather than returning nothing", () => {
  // A new `kind` added to the check constraint without being added here
  // must not present as a key with no models.
  assertThrows(() => modelQuery("mistral", "https://x/v1", "k"));
});

// ---------------------------------------------------------------------
// Reading the answer
// ---------------------------------------------------------------------

Deno.test("Anthropic's display name is preferred over the id", () => {
  const got = modelsFrom("anthropic", {
    data: [
      { id: "claude-opus-5", display_name: "Claude Opus 5" },
      { id: "claude-haiku-4-5" },
    ],
  });
  assertEquals(got, [
    { id: "claude-opus-5", label: "Claude Opus 5" },
    // No display name, so the id has to do both jobs.
    { id: "claude-haiku-4-5", label: "claude-haiku-4-5" },
  ]);
});

Deno.test("the chat-completions list is handed over whole", () => {
  // Including the models that cannot read a document. Dropping them
  // would mean guessing from names, and a list that quietly omits what
  // somebody is looking for is worse than a long one.
  const got = modelsFrom("openai", {
    data: [{ id: "gpt-4o" }, { id: "text-embedding-3-small" }],
  });
  assertEquals(got.map((m) => m.id), ["gpt-4o", "text-embedding-3-small"]);
});

Deno.test("Gemini's models/ prefix is not part of the identifier", () => {
  const got = modelsFrom("google_gemini", {
    models: [{
      name: "models/gemini-3.5-flash-lite",
      displayName: "Gemini 3.5 Flash Lite",
      supportedGenerationMethods: ["generateContent", "countTokens"],
    }],
  });
  // `readGemini` builds `/models/<id>:generateContent`, so an id that
  // still carried the prefix would produce `/models/models/...`.
  assertEquals(got, [{
    id: "gemini-3.5-flash-lite",
    label: "Gemini 3.5 Flash Lite",
  }]);
});

Deno.test("a Gemini model that cannot generateContent is left out", () => {
  const got = modelsFrom("google_gemini", {
    models: [
      { name: "models/gemini-3.5-flash-lite", supportedGenerationMethods: ["generateContent"] },
      { name: "models/text-embedding-004", supportedGenerationMethods: ["embedContent"] },
    ],
  });
  // Filtered on Google's own statement about the model, not on the
  // word "embedding" appearing in its name.
  assertEquals(got.map((m) => m.id), ["gemini-3.5-flash-lite"]);
});

Deno.test("a Gemini row that lists no methods is kept", () => {
  // Absent is not the same as empty: a vendor that stops publishing the
  // field must not empty the whole list.
  const got = modelsFrom("google_gemini", {
    models: [{ name: "models/gemini-experimental" }],
  });
  assertEquals(got.map((m) => m.id), ["gemini-experimental"]);
});

Deno.test("rubbish in place of a list is an empty list, not a throw", () => {
  // This runs on whatever the vendor actually sent, including an error
  // body that parsed as JSON.
  for (const body of [null, undefined, {}, { data: "no" }, { data: [null] }, [1, 2]]) {
    assertEquals(modelsFrom("openai", body), []);
  }
  for (const body of [null, {}, { models: {} }, { models: [{}] }]) {
    assertEquals(modelsFrom("google_gemini", body), []);
  }
});

Deno.test("an entry with no id is skipped rather than shown blank", () => {
  const got = modelsFrom("anthropic", {
    data: [{ id: "" }, { id: "   " }, { display_name: "Nameless" }, { id: "ok" }],
  });
  assertEquals(got.map((m) => m.id), ["ok"]);
});

Deno.test("whitespace around an id is not part of it", () => {
  assertEquals(
    modelsFrom("openai", { data: [{ id: "  gpt-4o  " }] }),
    [{ id: "gpt-4o", label: "gpt-4o" }],
  );
});

// ---------------------------------------------------------------------
// The order
// ---------------------------------------------------------------------

Deno.test("the list is alphabetical and leaves its input alone", () => {
  const input = [
    { id: "gpt-4o-mini", label: "gpt-4o-mini" },
    { id: "gpt-4o", label: "gpt-4o" },
    { id: "chatgpt-4o-latest", label: "chatgpt-4o-latest" },
  ];
  assertEquals(sorted(input).map((m) => m.id), [
    "chatgpt-4o-latest",
    "gpt-4o",
    "gpt-4o-mini",
  ]);
  // Sorting in place would reorder whatever the caller still holds.
  assertEquals(input[0].id, "gpt-4o-mini");
});
