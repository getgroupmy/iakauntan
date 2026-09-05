-- =====================================================================
-- 0541. More providers, and a model a company may name for itself
--
-- Two things 0536 and 0537 left short, both asked for directly.
--
-- FIRST, THE LIST WAS NINE. 0537 seeded the providers there was good
-- reason to be confident of and said so. This adds the rest of the ones
-- a Malaysian business is likely to already hold an account with, and
-- every one of them speaks the OpenAI chat-completions shape — so
-- `askOpenAi()` in the `ask` function reaches all of them with no code
-- change at all. That is what 0537's two-wire design was for.
--
-- SECOND, AND THIS IS THE REAL GAP. `set_ai_settings` refuses a model
-- that is not in `public.ai_models`, and `upsert_ai_model` is platform
-- staff only. So a company that brings its OWN OpenAI account — pays
-- its own bill, holds its own key — still could not use a model unless
-- a platform administrator had listed it first. The company was paying
-- and waiting on somebody else.
--
-- The catalogue check exists for a reason, and the reason does not
-- reach that company. It stops a company spending the PLATFORM'S key on
-- a model the platform has not sanctioned or priced. On its own key
-- there is nothing to sanction: the provider bills them, the model is
-- theirs to choose, and a wrong id comes back from the provider as a
-- plain error the same afternoon.
--
-- So the check now applies to `key_source = 'platform'` and not to
-- `'own'`. A company on its own key may name any model its provider
-- answers to, and the catalogue becomes what it should always have
-- been for them: a list of suggestions rather than a gate.
--
-- What is still checked on both paths: the provider must exist and be
-- switched on, a model may not be named without a provider, and the id
-- has to look like an id — trimmed, one line, and short enough to be
-- one. A model id is not free-form prose and a newline in it would be
-- a header injection waiting for a careless adapter.
--
-- ON THE MODEL IDS BELOW, the same caveat 0537 wrote and for the same
-- reason: the machine this was written on cannot reach any provider's
-- documentation, and a model catalogue is stale the week it is
-- written. The ids are the ones with the best claim to stability —
-- mostly the providers' own `-latest` aliases, which exist precisely so
-- that a caller does not have to chase a version string. The catalogue
-- is a TABLE, `upsert_ai_model` corrects a row in ten seconds, and a
-- company on its own key can now type past it entirely. Task #228
-- still stands: confirm these against each provider's live catalogue.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A provider whose address belongs to the account, not to the provider
-- ---------------------------------------------------------------------
-- `ai_providers.sql` holds an invariant worth keeping: a provider with
-- no address is switched off, because a provider that cannot be called
-- should not be on the list. It was written for Puter, whose server
-- route could not be confirmed, and it is right about that.
--
-- It is too strong for Azure OpenAI, for Cloudflare Workers AI, and for
-- a gateway of a company's own. Those CAN be called — their address is
-- simply a property of the account rather than of the provider: an
-- Azure resource and deployment, a Cloudflare account id, whatever host
-- somebody runs LiteLLM on. `ai_call_config` already reads
-- `coalesce(<the company's own address>, <the provider's>)`, so a
-- company that keys one in is fully served.
--
-- So the invariant gains its third arm rather than being dropped: a
-- provider is switched off, OR carries an address, OR says plainly that
-- the address comes from the account. Puter still fails the first two
-- and is still switched off.
alter table public.ai_providers
  add column if not exists address_from_account boolean not null default false;

comment on column public.ai_providers.address_from_account is
  'True where the address is a property of the account rather than of the provider — an Azure deployment, a Cloudflare account id, a gateway of your own. Such a provider may be active with no base_url of its own, and the company keys one in beside its key.';

-- ---------------------------------------------------------------------
-- The providers
-- ---------------------------------------------------------------------
-- `base_url` is left null for the three whose address is not a constant
-- but a property of the account — an Azure resource and deployment, a
-- Cloudflare account id, and whatever host a company's own gateway
-- runs on. `ai_status` already says so in words for those
-- ("... has no address to call. It needs one keyed in beside the key"),
-- and the settings sheet already has the field.
insert into public.ai_providers
  (code, name, wire, base_url, docs_url, key_hint, needs_key, is_active,
   sort_order)
values
  ('mistral', 'Mistral AI', 'openai',
   'https://api.mistral.ai/v1',
   'https://docs.mistral.ai/api/',
   'A key from console.mistral.ai. The free tier is generous enough to '
   'try the assistant on.',
   true, true, 100),

  ('groq', 'Groq', 'openai',
   'https://api.groq.com/openai/v1',
   'https://console.groq.com/docs/openai',
   'A key from console.groq.com, beginning gsk_. Groq serves open '
   'models very fast rather than serving its own.',
   true, true, 110),

  ('xai', 'xAI (Grok)', 'openai',
   'https://api.x.ai/v1',
   'https://docs.x.ai/docs/api-reference',
   'A key from console.x.ai, beginning xai-.',
   true, true, 120),

  ('together', 'Together AI', 'openai',
   'https://api.together.xyz/v1',
   'https://docs.together.ai/docs/openai-api-compatibility',
   'A key from api.together.xyz/settings/api-keys.',
   true, true, 130),

  ('fireworks', 'Fireworks AI', 'openai',
   'https://api.fireworks.ai/inference/v1',
   'https://docs.fireworks.ai/tools-sdks/openai-compatibility',
   'A key from fireworks.ai, beginning fw_.',
   true, true, 140),

  ('perplexity', 'Perplexity', 'openai',
   'https://api.perplexity.ai',
   'https://docs.perplexity.ai/api-reference/chat-completions',
   'A key from perplexity.ai/settings/api, beginning pplx-. Its models '
   'search the web as they answer, which is not what reading a ledger '
   'needs — useful for a question about the world, not about the books.',
   true, true, 150),

  ('deepinfra', 'DeepInfra', 'openai',
   'https://api.deepinfra.com/v1/openai',
   'https://deepinfra.com/docs/openai_api',
   'A key from deepinfra.com/dash/api_keys.',
   true, true, 160),

  ('sambanova', 'SambaNova Cloud', 'openai',
   'https://api.sambanova.ai/v1',
   'https://docs.sambanova.ai/cloud/docs/get-started/overview',
   'A key from cloud.sambanova.ai.',
   true, true, 170),

  ('hyperbolic', 'Hyperbolic', 'openai',
   'https://api.hyperbolic.xyz/v1',
   'https://docs.hyperbolic.xyz/docs/rest-api',
   'A key from app.hyperbolic.xyz/settings.',
   true, true, 180),

  ('novita', 'Novita AI', 'openai',
   'https://api.novita.ai/v3/openai',
   'https://novita.ai/docs/guides/llm-api',
   'A key from novita.ai/settings/key-management.',
   true, true, 190),

  ('moonshot', 'Moonshot AI (Kimi)', 'openai',
   'https://api.moonshot.ai/v1',
   'https://platform.moonshot.ai/docs/api/chat',
   'A key from platform.moonshot.ai, beginning sk-. Companies billing '
   'in renminbi use api.moonshot.cn instead — key that in as the '
   'address beside the key.',
   true, true, 200),

  ('zhipu', 'Zhipu AI (GLM)', 'openai',
   'https://open.bigmodel.cn/api/paas/v4',
   'https://open.bigmodel.cn/dev/api',
   'A key from open.bigmodel.cn. GLM-4-Flash costs nothing.',
   true, true, 210),

  ('cohere', 'Cohere', 'openai',
   'https://api.cohere.ai/compatibility/v1',
   'https://docs.cohere.com/docs/compatibility-api',
   'A key from dashboard.cohere.com/api-keys. This is Cohere''s '
   'OpenAI-compatible endpoint, not its own Chat API.',
   true, true, 220),

  ('github_models', 'GitHub Models', 'openai',
   'https://models.inference.ai.azure.com',
   'https://docs.github.com/en/github-models',
   'A GitHub personal access token with the models scope. The free '
   'allowance is small and rate-limited — good for trying it, not for '
   'a month of questions.',
   true, true, 230),

  -- The three whose address belongs to the account rather than to the
  -- provider.
  ('azure_openai', 'Azure OpenAI', 'openai',
   null,
   'https://learn.microsoft.com/azure/ai-services/openai/reference',
   'The key from your Azure resource, and the address is the one Azure '
   'gives that deployment — https://<resource>.openai.azure.com/openai/'
   'deployments/<deployment>. The model is the DEPLOYMENT name you '
   'chose, not the model name Azure lists.',
   true, true, 240),

  ('cloudflare', 'Cloudflare Workers AI', 'openai',
   null,
   'https://developers.cloudflare.com/workers-ai/configuration/'
   'open-ai-compatibility/',
   'An API token from the Cloudflare dashboard, and the address carries '
   'your account id — https://api.cloudflare.com/client/v4/accounts/'
   '<account id>/ai/v1.',
   true, true, 250),

  ('openai_compatible', 'Any OpenAI-compatible endpoint', 'openai',
   null,
   'https://platform.openai.com/docs/api-reference/chat',
   'For a provider this list does not name, or a gateway of your own '
   'such as LiteLLM. Key in its address and its key, and name the '
   'model it serves. Anything answering POST /chat/completions in the '
   'OpenAI shape works.',
   true, true, 900)
on conflict (code) do nothing;

update public.ai_providers set address_from_account = true
 where code in ('azure_openai', 'cloudflare', 'openai_compatible');

-- ---------------------------------------------------------------------
-- A model apiece, so every provider on the list can be chosen
-- ---------------------------------------------------------------------
-- `set_ai_settings` refuses a provider with no model behind it, so a
-- provider seeded without one is a row that cannot be used. These are
-- the ids with the best claim to stability at each: where a provider
-- publishes a `-latest` alias, that is what is here, because an alias
-- is the provider's own promise not to break the caller.
insert into public.ai_models
  (provider_code, model_id, name, kind, is_free, context_tokens, notes,
   is_active, sort_order)
values
  -- OPENAI HAS BEEN ON THE LIST SINCE 0537 WITH NO MODEL BEHIND IT.
  -- `set_ai_settings` refuses a provider whose model is not on the
  -- catalogue, so the best-known provider in the product was one no
  -- company could actually choose. The new invariant in
  -- `ai_provider_catalogue.sql` — every switched-on provider carries a
  -- model that answers — is what found it, and is what stops the next
  -- one being seeded the same way.
  ('openai', 'gpt-4o', 'GPT-4o', 'chat', false, 128000, null, true, 10),
  ('openai', 'gpt-4o-mini', 'GPT-4o mini', 'chat', false, 128000,
   'Cheaper, and enough for most questions about a ledger.', true, 20),

  ('mistral', 'mistral-large-latest', 'Mistral Large', 'chat', false,
   128000, 'Mistral''s own alias for its current large model.', true, 10),
  ('mistral', 'mistral-small-latest', 'Mistral Small', 'chat', false,
   128000, 'Cheaper, and enough for most questions about a ledger.',
   true, 20),

  ('groq', 'llama-3.3-70b-versatile', 'Llama 3.3 70B', 'chat', false,
   128000, 'Open weights served very fast.', true, 10),
  ('groq', 'llama-3.1-8b-instant', 'Llama 3.1 8B', 'chat', false,
   128000, 'Small and quick. Weak at arithmetic over a long report.',
   true, 20),

  ('xai', 'grok-2-latest', 'Grok 2', 'chat', false,
   131072, 'xAI''s alias for its current model.', true, 10),

  ('together', 'meta-llama/Llama-3.3-70B-Instruct-Turbo',
   'Llama 3.3 70B Turbo', 'chat', false, 128000, null, true, 10),
  ('together', 'Qwen/Qwen2.5-72B-Instruct-Turbo', 'Qwen 2.5 72B Turbo',
   'chat', false, 32768, null, true, 20),

  ('fireworks', 'accounts/fireworks/models/llama-v3p3-70b-instruct',
   'Llama 3.3 70B', 'chat', false, 128000,
   'Fireworks ids carry the account path in front of the model.',
   true, 10),

  ('perplexity', 'sonar', 'Sonar', 'chat', false, 127072,
   'Answers with a web search behind it.', true, 10),
  ('perplexity', 'sonar-pro', 'Sonar Pro', 'chat', false, 200000,
   null, true, 20),

  ('deepinfra', 'meta-llama/Meta-Llama-3.1-70B-Instruct',
   'Llama 3.1 70B', 'chat', false, 128000, null, true, 10),

  ('sambanova', 'Meta-Llama-3.3-70B-Instruct', 'Llama 3.3 70B', 'chat',
   false, 128000, null, true, 10),

  ('hyperbolic', 'meta-llama/Meta-Llama-3.1-70B-Instruct',
   'Llama 3.1 70B', 'chat', false, 128000, null, true, 10),

  ('novita', 'meta-llama/llama-3.1-70b-instruct', 'Llama 3.1 70B',
   'chat', false, 128000, null, true, 10),

  ('moonshot', 'moonshot-v1-32k', 'Moonshot v1 32k', 'chat', false,
   32768, null, true, 10),
  ('moonshot', 'moonshot-v1-128k', 'Moonshot v1 128k', 'chat', false,
   131072, 'For a question that reads a long report.', true, 20),

  ('zhipu', 'glm-4-flash', 'GLM-4-Flash', 'chat', true, 128000,
   'Free on Zhipu''s own pricing.', true, 10),
  ('zhipu', 'glm-4-plus', 'GLM-4-Plus', 'chat', false, 128000, null,
   true, 20),

  ('cohere', 'command-r-plus', 'Command R+', 'chat', false, 128000,
   null, true, 10),

  ('github_models', 'gpt-4o', 'GPT-4o', 'chat', false, 128000,
   'Rate-limited by GitHub rather than billed.', true, 10),

  ('azure_openai', 'gpt-4o', 'Your deployment', 'chat', false, 128000,
   'On Azure the model id is the DEPLOYMENT name you chose. Rename '
   'this row, or bring your own key and type the name in.', true, 10),

  ('cloudflare', '@cf/meta/llama-3.1-70b-instruct', 'Llama 3.1 70B',
   'chat', false, 128000, 'Cloudflare ids begin @cf/.', true, 10),

  ('openai_compatible', 'gpt-4o-mini', 'Whatever your endpoint serves',
   'chat', false, 128000,
   'A placeholder so the provider can be chosen. On your own key, type '
   'the model your endpoint actually serves.', true, 10)
on conflict (provider_code, model_id) do nothing;

-- ---------------------------------------------------------------------
-- A model a company on its own key may name for itself
-- ---------------------------------------------------------------------
create or replace function public.set_ai_settings(
  p_org_id uuid, p_enabled boolean, p_provider text default null,
  p_model text default null, p_key_source text default 'platform')
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_provider text := nullif(btrim(coalesce(p_provider, '')), '');
  v_model    text := nullif(btrim(coalesce(p_model, '')), '');
  v_source   text := coalesce(p_key_source, 'platform');
begin
  if not app.can_admin(p_org_id) then
    raise exception 'not permitted to set up the assistant'
      using errcode = '42501';
  end if;
  if v_source not in ('platform', 'own') then
    raise exception 'A key is the platform''s or the company''s own.'
      using errcode = '23514';
  end if;

  -- Naming a model without a provider is naming a model at whichever
  -- provider the platform happens to be using this week, which is a
  -- setting that changes meaning underneath the company that set it.
  if v_model is not null and v_provider is null then
    raise exception
      'A model belongs to a provider. Choose the provider as well, or '
      'leave both empty to follow the platform.' using errcode = '23514';
  end if;
  if v_provider is not null
     and not exists (select 1 from public.ai_providers
                      where code = v_provider and is_active) then
    raise exception 'That provider is not switched on.' using errcode = '23514';
  end if;

  -- WHATEVER THE SOURCE, A MODEL ID HAS TO LOOK LIKE ONE. It goes into
  -- a JSON body and, at some providers, into a URL path; a newline or
  -- a carriage return in it is the shape header injection takes when
  -- an adapter is careless with string building. Nothing in this
  -- codebase builds a header out of it today and nothing should have
  -- to remember not to.
  if v_model is not null then
    if v_model ~ '[[:cntrl:]]' then
      raise exception
        'A model id is one line of text. That one has a line break in it.'
        using errcode = '23514';
    end if;
    if length(v_model) > 200 then
      raise exception
        'A model id of % characters is not a model id.', length(v_model)
        using errcode = '23514';
    end if;
  end if;

  -- AND THE CATALOGUE, ON THE PLATFORM'S KEY ONLY.
  --
  -- The list exists to stop a company spending the platform's money on
  -- a model the platform has not sanctioned or priced. A company on
  -- its own key is spending its own: the provider bills it directly,
  -- the model is its to choose, and a wrong id comes back from the
  -- provider as a plain error the same afternoon. Holding that company
  -- to a list only a platform administrator can add to made it wait on
  -- somebody else to use an account it already pays for.
  if v_model is not null and v_source = 'platform'
     and not exists (select 1 from public.ai_models
                      where provider_code = v_provider and model_id = v_model
                        and is_active and kind <> 'image') then
    raise exception
      'That model is not one % answers to. The list is the platform''s '
      'rather than the provider''s: bring your own key for this company '
      'and you may name any model % serves.',
      v_provider, v_provider using errcode = '23514';
  end if;

  insert into public.org_ai_settings
    (org_id, is_enabled, provider_code, model_id, key_source, updated_by,
     updated_at)
  values (p_org_id, coalesce(p_enabled, false), v_provider, v_model,
          v_source, auth.uid(), now())
  on conflict (org_id) do update
    set is_enabled = excluded.is_enabled,
        provider_code = excluded.provider_code,
        model_id = excluded.model_id,
        key_source = excluded.key_source,
        updated_by = excluded.updated_by,
        updated_at = now();
end;
$$;

revoke all on function public.set_ai_settings(
  uuid, boolean, text, text, text) from public, anon;
grant execute on function public.set_ai_settings(
  uuid, boolean, text, text, text) to authenticated;

comment on function public.set_ai_settings(uuid, boolean, text, text, text) is
  'One company''s choice of provider, model and whose key pays. The model must be one the platform lists when the platform''s key pays for it, and may be any the provider answers to when the company brings its own.';


-- ---------------------------------------------------------------------
-- And a key for one of those needs the address beside it
-- ---------------------------------------------------------------------
-- The address is the whole point of the flag, and without it the
-- failure arrives much later — at the moment somebody asks a question,
-- as `ai_call_config`'s "There is no address on file to call % at."
-- Said here it arrives while the person is still looking at the field
-- they left empty.
create or replace function public.set_ai_credentials(
  p_org_id uuid, p_provider text, p_api_key text,
  p_base_url text default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_prov public.ai_providers;
  v_url  text := nullif(btrim(coalesce(p_base_url, '')), '');
begin
  if not app.can_admin(p_org_id) then
    raise exception 'not permitted to set up the assistant'
      using errcode = '42501';
  end if;
  select * into v_prov from public.ai_providers where code = p_provider;
  if v_prov.code is null then
    raise exception 'No such provider.' using errcode = 'P0002';
  end if;
  if btrim(coalesce(p_api_key, '')) = '' then
    raise exception
      'A key of no characters is not a key. Use the clear button if the '
      'intention was to remove it.' using errcode = '23514';
  end if;
  if v_prov.address_from_account and v_url is null
     and v_prov.base_url is null then
    raise exception
      '% is called at an address that belongs to your account rather '
      'than to the provider. Key the address in beside the key.',
      v_prov.name using errcode = '23514';
  end if;

  insert into public.ai_provider_credentials
    (provider_code, org_id, api_key, base_url, updated_by, updated_at)
  values (p_provider, p_org_id, btrim(p_api_key), v_url, auth.uid(), now())
  on conflict (provider_code, org_id) where org_id is not null
  do update set api_key = excluded.api_key,
                base_url = excluded.base_url,
                updated_by = excluded.updated_by,
                updated_at = now();
end;
$$;

revoke all on function public.set_ai_credentials(uuid, text, text, text)
  from public, anon;
grant execute on function public.set_ai_credentials(uuid, text, text, text)
  to authenticated;
