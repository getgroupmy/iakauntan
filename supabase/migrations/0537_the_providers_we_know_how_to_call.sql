-- =====================================================================
-- The providers we know how to call, and a starting list of models
--
-- 0536 made the provider a row. This is the first set of rows.
--
-- TWO WIRE SHAPES cover all of them. Anthropic's Messages API is its
-- own thing — `system` is a top-level field, tool results come back as
-- content blocks, and the key goes in `x-api-key`. Everything else here
-- speaks the OpenAI chat-completions shape: `messages` with a `system`
-- role in the array, `tools` with a `function` wrapper, tool calls on
-- `message.tool_calls`, and a bearer token. OpenRouter, Nvidia NIM,
-- Cerebras, DeepSeek, Qwen on DashScope and Gemini's compatibility
-- endpoint are all the second shape, which is why one adapter reaches
-- all six.
--
-- ON THE MODEL LIST, and this is worth being straight about. A model
-- catalogue is stale the week it is written, and the machine this
-- migration was written on could not reach any provider's
-- documentation — the network refused every one of them. So the ids
-- below are the ones there was good reason to be confident of, the
-- catalogue is a TABLE rather than a constant, and
-- `public.upsert_ai_model` puts a new one in from the console in ten
-- seconds. A model id that turns out to be wrong is a row to correct,
-- not a deployment to wait for. That is the whole reason 0536 is shaped
-- the way it is.
--
-- PUTER is the one provider seeded WITHOUT an address. Its published
-- API is browser-first — a JavaScript SDK where the person using the
-- page pays for their own calls — and the server-side route needs an
-- application token and an endpoint that could not be confirmed from
-- here. It is in the list, switched off, with the address left for
-- whoever sets it up to key in, rather than guessed at and shipped
-- broken.
-- =====================================================================

insert into public.ai_providers
  (code, name, wire, base_url, docs_url, key_hint, needs_key, is_active,
   sort_order)
values
  ('anthropic', 'Anthropic', 'anthropic',
   'https://api.anthropic.com/v1/messages',
   'https://docs.anthropic.com/en/api/messages',
   'A key from console.anthropic.com. It begins sk-ant-.',
   true, true, 10),

  ('openrouter', 'OpenRouter', 'openai',
   'https://openrouter.ai/api/v1',
   'https://openrouter.ai/docs',
   'A key from openrouter.ai/keys, beginning sk-or-. One key reaches '
   'every model OpenRouter lists, and the ones whose id ends :free cost '
   'nothing.',
   true, true, 20),

  ('openai', 'OpenAI', 'openai',
   'https://api.openai.com/v1',
   'https://platform.openai.com/docs/api-reference/chat',
   'A key from platform.openai.com, beginning sk-.',
   true, true, 30),

  ('deepseek', 'DeepSeek', 'openai',
   'https://api.deepseek.com',
   'https://api-docs.deepseek.com',
   'A key from platform.deepseek.com.',
   true, true, 40),

  ('qwen', 'Qwen (Alibaba DashScope)', 'openai',
   'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
   'https://qwen.ai',
   'A DashScope key. The address above is the international endpoint; '
   'a mainland China account uses dashscope.aliyuncs.com instead, which '
   'goes in the address field beside the key.',
   true, true, 50),

  ('cerebras', 'Cerebras', 'openai',
   'https://api.cerebras.ai/v1',
   'https://inference-docs.cerebras.ai',
   'A key from cloud.cerebras.ai.',
   true, true, 60),

  ('nvidia_nim', 'NVIDIA NIM', 'openai',
   'https://integrate.api.nvidia.com/v1',
   'https://build.nvidia.com',
   'A key from build.nvidia.com, beginning nvapi-.',
   true, true, 70),

  ('google', 'Google Gemini', 'openai',
   'https://generativelanguage.googleapis.com/v1beta/openai',
   'https://ai.google.dev/gemini-api/docs/openai',
   'A key from aistudio.google.com. This is Gemini''s OpenAI-compatible '
   'endpoint, which is why it is set up like the others.',
   true, true, 80),

  ('puter', 'Puter', 'openai',
   null,
   'https://developer.puter.com/tutorials/free-unlimited-ai-api/',
   'Puter''s published API is a browser SDK where the person using the '
   'page pays for their own calls. Calling it from a server needs an '
   'application token and an endpoint, and neither could be confirmed '
   'when this row was written — so key in the address as well as the '
   'token, and switch it on once a question comes back.',
   true, false, 90)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- A starting list. Everything here is `upsert_ai_model`-able from the
-- console, and `is_active` retires one without losing who used it.
-- ---------------------------------------------------------------------
insert into public.ai_models
  (provider_code, model_id, name, kind, is_free, context_tokens, notes,
   sort_order)
values
  ('anthropic', 'claude-opus-5', 'Claude Opus 5', 'chat', false, 1000000,
   'The one the assistant was built against.', 10),
  ('anthropic', 'claude-sonnet-5', 'Claude Sonnet 5', 'chat', false, 1000000,
   null, 20),
  ('anthropic', 'claude-haiku-4-5', 'Claude Haiku 4.5', 'chat', false, 200000,
   'The cheapest of the three, and quick enough for a question about one '
   'report.', 30),

  ('openrouter', 'openrouter/auto', 'OpenRouter Auto', 'chat', false, null,
   'OpenRouter picks the model. Any id from its catalogue can be added '
   'here instead; the ones ending :free cost nothing.', 10),

  ('deepseek', 'deepseek-chat', 'DeepSeek Chat', 'chat', false, null, null, 10),
  ('deepseek', 'deepseek-reasoner', 'DeepSeek Reasoner', 'chat', false, null,
   'Thinks before it answers, and bills for the thinking.', 20),

  ('qwen', 'qwen-plus', 'Qwen Plus', 'chat', false, null, null, 10),
  ('qwen', 'qwen-turbo', 'Qwen Turbo', 'chat', false, null, null, 20),
  ('qwen', 'qwen-max', 'Qwen Max', 'chat', false, null, null, 30),
  ('qwen', 'qwen3-coder-plus', 'Qwen3 Coder Plus', 'chat', false, null,
   'The model behind Qwen Code.', 40),
  ('qwen', 'qwen-vl-plus', 'Qwen VL Plus', 'vision', false, null,
   'Reads pictures as well as words, through the same chat shape.', 50),

  ('cerebras', 'llama-3.3-70b', 'Llama 3.3 70B', 'chat', false, null,
   'Cerebras runs it fast; the model is Meta''s.', 10),
  ('cerebras', 'llama3.1-8b', 'Llama 3.1 8B', 'chat', false, null, null, 20),

  ('nvidia_nim', 'meta/llama-3.3-70b-instruct', 'Llama 3.3 70B Instruct',
   'chat', false, null, null, 10),
  ('nvidia_nim', 'deepseek-ai/deepseek-r1', 'DeepSeek R1', 'chat', false, null,
   null, 20),

  ('google', 'gemini-2.0-flash', 'Gemini 2.0 Flash', 'chat', false, null,
   null, 10)
on conflict (provider_code, model_id) do nothing;

comment on column public.ai_models.model_id is
  'What goes on the wire. If a provider renames a model this is the column that changes, and nothing in the code has to.';
