-- =====================================================================
-- iAkauntan :: the provider list, and the model a company may name
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/ai_provider_catalogue.sql
--
-- 0541 lengthened the provider list and changed one rule: a company on
-- the PLATFORM'S key may only choose a model the platform lists, and a
-- company on ITS OWN key may name any model its provider serves.
--
-- The rule is about whose money is being spent. The catalogue exists so
-- that a company cannot spend the platform's key on a model the
-- platform has not sanctioned or priced. A company paying its own
-- provider directly has nothing to sanction — and holding it to a list
-- only a platform administrator may add to made it wait on somebody
-- else to use an account it already pays for.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- 1. Every row on the list can actually be called
-- ---------------------------------------------------------------------
do $$
begin
  -- The `ask` function has two adapters and no more. A provider whose
  -- wire is neither is a row nothing can call, and it would fail at the
  -- moment somebody asked a question rather than here.
  perform pg_temp.check_eq('every provider speaks a wire the app has',
    (select count(*) from public.ai_providers
      where wire not in ('anthropic', 'openai')), 0);

  -- A provider with no model behind it cannot be chosen: set_ai_settings
  -- refuses the model, and a provider without one is a dead row on a
  -- list. Every switched-on provider carries at least one model that
  -- answers rather than draws.
  perform pg_temp.check_eq(
    'every provider on offer has a model that can be chosen',
    (select count(*) from public.ai_providers p
      where p.is_active
        and not exists (select 1 from public.ai_models m
                         where m.provider_code = p.code
                           and m.is_active and m.kind <> 'image')), 0);

  -- The third arm of 0541's invariant, from the other side: a provider
  -- that says its address comes from the account must not also carry
  -- one, or the flag is decoration and the company's own address would
  -- be the second choice rather than the only one.
  perform pg_temp.check_eq(
    'a provider addressed by the account carries no address of its own',
    (select count(*) from public.ai_providers
      where address_from_account and base_url is not null), 0);

  perform pg_temp.check_true('and there are some of each kind on the list',
    (select count(*) from public.ai_providers where address_from_account) >= 3
    and (select count(*) from public.ai_providers
          where is_active and base_url is not null) >= 10);
end $$;

-- ---------------------------------------------------------------------
-- 2. Whose key decides whether the catalogue is a gate
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Model Sendiri Sdn Bhd');
  v_st  record;
begin
  -- ON THE PLATFORM'S KEY the list is a gate.
  perform pg_temp.check_refused(
    'on the platform''s key an unlisted model is refused',
    format($q$select public.set_ai_settings(
             %L, true, 'mistral', 'mistral-medium-2506', 'platform')$q$, v_org),
    'That model is not one mistral answers to.%', '23514');

  -- ON ITS OWN KEY it is a list of suggestions.
  perform public.set_ai_settings(
    v_org, true, 'mistral', 'mistral-medium-2506', 'own');
  select * into v_st from public.ai_status(v_org);
  perform pg_temp.check_eq('on its own key the company names the model',
    v_st.model_id, 'mistral-medium-2506');
  perform pg_temp.check_eq('at the provider it chose',
    v_st.provider_code, 'mistral');
  perform pg_temp.check_eq('and it is the company''s key that pays',
    v_st.key_source, 'own');

  -- A model the platform DOES list is still fine on either key, which
  -- is what says the assertion above is about the list and not about
  -- own-key companies being refused everything.
  perform public.set_ai_settings(
    v_org, true, 'mistral', 'mistral-small-latest', 'platform');
  select * into v_st from public.ai_status(v_org);
  perform pg_temp.check_eq('a listed model is fine on the platform''s key',
    v_st.model_id, 'mistral-small-latest');

  -- WHAT IS STILL REFUSED ON BOTH. A model id goes into a JSON body and
  -- at some providers into a URL; it is one line of text and a short
  -- one, whoever is paying.
  perform pg_temp.check_refused('a model id with a line break in it',
    format($q$select public.set_ai_settings(
             %L, true, 'mistral', %L, 'own')$q$, v_org,
           'mistral-small' || chr(10) || 'X-Injected: yes'),
    'A model id is one line of text.%', '23514');
  perform pg_temp.check_refused('and one far too long to be an id',
    format($q$select public.set_ai_settings(
             %L, true, 'mistral', %L, 'own')$q$, v_org, repeat('m', 201)),
    'A model id of 201 characters is not a model id.%', '23514');
  perform pg_temp.check_refused('a model with no provider, own key or not',
    format($q$select public.set_ai_settings(
             %L, true, null, 'whatever-i-like', 'own')$q$, v_org),
    'A model belongs to a provider.%', '23514');
  perform pg_temp.check_refused('and a provider that is switched off',
    format($q$select public.set_ai_settings(
             %L, true, 'puter', 'anything', 'own')$q$, v_org),
    'That provider is not switched on.%', '23514');

  -- Two hundred exactly is an id; two hundred and one is not.
  perform public.set_ai_settings(
    v_org, true, 'mistral', repeat('m', 200), 'own');
  perform pg_temp.check_eq('two hundred characters is still an id',
    (select length(model_id) from public.org_ai_settings
      where org_id = v_org), 200);
end $$;

-- ---------------------------------------------------------------------
-- 3. A provider whose address belongs to the account
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Alamat Sendiri Sdn Bhd');
  v_st  record;
begin
  perform public.set_ai_settings(v_org, true, 'azure_openai', 'gpt-4o', 'own');

  -- A key with no address beside it is refused where the address is the
  -- account's, because the alternative is a company that looks set up
  -- and fails at the first question.
  perform pg_temp.check_refused('a key without the address it needs',
    format($q$select public.set_ai_credentials(%L, 'azure_openai', 'k-123')$q$,
           v_org),
    'Azure OpenAI is called at an address that belongs to your account%',
    '23514');

  -- With the address, it takes.
  perform public.set_ai_credentials(
    v_org, 'azure_openai', 'k-123',
    'https://iakauntan.openai.azure.com/openai/deployments/gpt4o');
  select * into v_st from public.ai_status(v_org);
  perform pg_temp.check_true('a key and an address together are ready',
    v_st.is_ready);
  perform pg_temp.check_true('and the key is on file', v_st.has_own_key);

  -- A provider that carries its own address does not need one keyed in.
  perform public.set_ai_settings(v_org, true, 'groq',
                                 'llama-3.3-70b-versatile', 'own');
  perform public.set_ai_credentials(v_org, 'groq', 'gsk_123');
  select * into v_st from public.ai_status(v_org);
  perform pg_temp.check_true('a provider with its own address needs none',
    v_st.is_ready);

  -- And the key still never comes back out, whoever asks.
  perform pg_temp.check_eq('no status column could carry a key',
    (select count(*) from information_schema.columns
      where table_schema = 'public'
        and table_name in ('ai_providers', 'ai_models')
        and column_name in ('api_key', 'key')), 0);
end $$;

rollback;
