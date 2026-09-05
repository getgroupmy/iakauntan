-- =====================================================================
-- iAkauntan :: the AI key you can type, and the model you can choose
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ai_providers.sql
--
-- Until 0536 the assistant read one key out of the environment and
-- called one model named in a `const`. There was nowhere to key an API
-- key in, no company could bring its own, and a new model was a
-- deployment.
--
-- The assertion this file is built around is the one that decides
-- whether any of that is safe to have: THE KEY IS NEVER RETURNED. Not
-- to a tenant, and not to a platform administrator either. The console
-- is told whether a key is on file and when it was set, and the only
-- reader of the key itself is `public.ai_call_config`, whose EXECUTE is
-- granted to the service role alone.
--
-- The second is that a company follows the platform until it says
-- otherwise, and that "otherwise" is checked rather than trusted: a
-- model that belongs to another provider, or an image model handed to
-- something that holds a conversation, is refused when it is chosen
-- rather than when somebody asks a question.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- The platform's own staff, which every setter below re-checks for.
create or replace function pg_temp.ai_platform_admin(p_user uuid)
returns void language sql as $$
  insert into public.platform_admins (user_id) values (p_user)
  on conflict do nothing;
$$;

do $$
declare
  v_org    uuid := pg_temp.test_org('Kedai Tanya Sdn Bhd');
  v_owner  uuid := pg_temp.test_user();
  v_other  uuid;
  v_stray  uuid;
  v_st     record;
  v_conf   record;
  v_n      integer;
begin
  perform pg_temp.ai_platform_admin(v_owner);

  -- ------------------------------------------------------------------
  -- The catalogue everybody may read
  --
  -- Choosing a provider is a thing a company does for itself, so the
  -- list is readable. There is nothing private in it: not one key.
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('the catalogue knows both wire shapes',
    (select count(distinct wire) from public.ai_providers) = 2);
  perform pg_temp.check_eq('and every provider speaks one of them',
    (select count(*) from public.ai_providers
      where wire not in ('anthropic', 'openai')), 0);
  perform pg_temp.check_true('a provider with no address is switched off',
    not exists (select 1 from public.ai_providers
                 where base_url is null and is_active));
  perform pg_temp.check_eq('every model belongs to a provider on file',
    (select count(*) from public.ai_models m
      where not exists (select 1 from public.ai_providers p
                         where p.code = m.provider_code)), 0);

  -- ------------------------------------------------------------------
  -- The key nobody may read
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq(
    'the credentials table is granted to nobody who logs in',
    (select count(*) from information_schema.role_table_grants
      where table_name = 'ai_provider_credentials'
        and grantee in ('anon', 'authenticated')), 0);
  perform pg_temp.check_true('and has row security on with no policy at all',
    (select relrowsecurity from pg_class
      where oid = 'public.ai_provider_credentials'::regclass)
    and not exists (select 1 from pg_policies
                     where tablename = 'ai_provider_credentials'));
  perform pg_temp.check_eq('the key reader is the service role''s alone',
    (select count(*) from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'ai_call_config'
       and p.proacl::text like '%service_role=X%'
       and p.proacl::text not like '%authenticated=X%'
       and p.proacl::text not like '%anon=X%'), 1);

  -- ------------------------------------------------------------------
  -- Keying one in
  -- ------------------------------------------------------------------
  perform public.set_platform_ai_key('openrouter', 'sk-or-not-a-real-key');
  select * into v_st from public.platform_ai_providers()
   where code = 'openrouter';
  perform pg_temp.check_true('the console is told a key is on file',
    v_st.has_key);
  perform pg_temp.check_true('and when it was set', v_st.key_set_at is not null);
  -- The row the console reads has no column that could carry a key.
  perform pg_temp.check_eq('and the console''s own row cannot carry one',
    (select count(*) from information_schema.columns
      where table_name = 'platform_ai_providers'
        and column_name in ('api_key', 'key')), 0);

  perform pg_temp.check_refused('a key of no characters is not a key',
    $q$select public.set_platform_ai_key('openrouter', '   ')$q$,
    'A key of no characters is not a key.%', '23514');
  perform pg_temp.check_refused('and a provider nobody has heard of',
    $q$select public.set_platform_ai_key('nosuchthing', 'sk-x')$q$,
    'No such provider.%', 'P0002');

  perform public.clear_platform_ai_key('openrouter');
  perform pg_temp.check_true('a key can be taken off again',
    not (select has_key from public.platform_ai_providers()
          where code = 'openrouter'));

  -- ------------------------------------------------------------------
  -- Choosing the default, and what it will not accept
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused(
    'a default naming a model the provider does not answer to',
    $q$select public.set_platform_ai_default('deepseek', 'claude-opus-5')$q$,
    'That model is not one deepseek answers to.%', '23514');
  perform pg_temp.check_refused('or a provider that is switched off',
    $q$select public.set_platform_ai_default('puter', 'anything')$q$,
    'That provider is not switched on.%', '23514');

  perform public.set_platform_ai_default('deepseek', 'deepseek-chat');
  perform pg_temp.check_eq('the default is the pair, not two settings',
    app.ai_default() ->> 'provider', 'deepseek');
  perform pg_temp.check_eq('and the model beside it',
    app.ai_default() ->> 'model', 'deepseek-chat');

  -- ------------------------------------------------------------------
  -- A company that has not chosen follows the platform, and keeps
  -- following it
  -- ------------------------------------------------------------------
  perform public.set_ai_settings(v_org, true);
  select * into v_st from public.ai_status(v_org);
  perform pg_temp.check_true('a company that has not chosen follows',
    v_st.follows_platform);
  perform pg_temp.check_eq('so it is on the platform''s provider',
    v_st.provider_code, 'deepseek');
  perform pg_temp.check_eq('and its model', v_st.model_id, 'deepseek-chat');
  perform pg_temp.check_true('but is not ready, because there is no key',
    not v_st.is_ready);
  perform pg_temp.check_true('and the screen says which key is missing',
    v_st.not_ready_reason like 'The platform has no key on file%');

  perform public.set_platform_ai_key('deepseek', 'sk-deepseek-not-real');
  select * into v_st from public.ai_status(v_org);
  perform pg_temp.check_true('with a key on file it is ready', v_st.is_ready);
  perform pg_temp.check_true('and nothing to say about it',
    v_st.not_ready_reason is null);

  -- When the platform changes its mind, a company that never chose
  -- moves with it. That is what "follows" has to mean to be worth
  -- having.
  perform public.set_platform_ai_default('qwen', 'qwen-plus');
  perform public.set_platform_ai_key('qwen', 'sk-qwen-not-real');
  select * into v_st from public.ai_status(v_org);
  perform pg_temp.check_eq('and moves when the platform does',
    v_st.provider_code, 'qwen');
  perform pg_temp.check_eq('model and all', v_st.model_id, 'qwen-plus');

  -- ------------------------------------------------------------------
  -- A company that chooses for itself
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused('a model with no provider beside it',
    format($q$select public.set_ai_settings(%L, true, null, 'qwen-plus')$q$,
           v_org),
    'A model belongs to a provider.%', '23514');
  perform pg_temp.check_refused('a model belonging to another provider',
    format($q$select public.set_ai_settings(%L, true, 'cerebras', 'qwen-plus')$q$,
           v_org),
    'That model is not one cerebras answers to.%', '23514');
  perform pg_temp.check_refused('a key that is neither the platform''s nor its own',
    format($q$select public.set_ai_settings(%L, true, null, null, 'somebody else''s')$q$,
           v_org),
    'A key is the platform''s or the company''s own.%', '23514');

  -- An image model is not a choice for something that holds a
  -- conversation, and it is refused at the moment it is chosen rather
  -- than at the moment somebody asks a question.
  perform public.upsert_ai_model('qwen', 'a-picture-model', 'A picture model',
                                 'image');
  perform pg_temp.check_refused('nor a model that draws rather than answers',
    format($q$select public.set_ai_settings(%L, true, 'qwen', 'a-picture-model')$q$,
           v_org),
    'That model is not one qwen answers to.%', '23514');

  perform public.set_ai_settings(v_org, true, 'deepseek', 'deepseek-reasoner');
  select * into v_st from public.ai_status(v_org);
  perform pg_temp.check_true('a company that chose does not follow',
    not v_st.follows_platform);
  perform pg_temp.check_eq('it is on its own provider',
    v_st.provider_code, 'deepseek');
  perform pg_temp.check_eq('and its own model',
    v_st.model_id, 'deepseek-reasoner');
  perform pg_temp.check_eq('read out by the name a person chose it by',
    v_st.model_name, 'DeepSeek Reasoner');

  -- And it stays where it was put when the platform moves again.
  perform public.set_platform_ai_default('cerebras', 'llama-3.3-70b');
  select * into v_st from public.ai_status(v_org);
  perform pg_temp.check_eq('and stays there when the platform moves on',
    v_st.provider_code, 'deepseek');

  -- ------------------------------------------------------------------
  -- Its own key
  -- ------------------------------------------------------------------
  perform public.set_ai_settings(v_org, true, 'deepseek', 'deepseek-chat',
                                 'own');
  select * into v_st from public.ai_status(v_org);
  perform pg_temp.check_true('a company on its own key with none is not ready',
    not v_st.is_ready);
  perform pg_temp.check_true('and is told exactly that',
    v_st.not_ready_reason like 'This company is set to use its own key%');

  perform public.set_ai_credentials(v_org, 'deepseek', 'sk-theirs-not-real');
  select * into v_st from public.ai_status(v_org);
  perform pg_temp.check_true('with one, it is ready', v_st.is_ready);
  perform pg_temp.check_true('and the screen says it has one',
    v_st.has_own_key);
  -- The screen says a key exists. It does not say what it is, and there
  -- is no column on that row where it could.
  perform pg_temp.check_eq('while still having nowhere to put the key itself',
    (select count(*) from information_schema.columns
      where table_name = 'ai_status'
        and column_name in ('api_key', 'key')), 0);

  -- ------------------------------------------------------------------
  -- What the edge function is handed
  -- ------------------------------------------------------------------
  select * into v_conf from public.ai_call_config(v_org);
  perform pg_temp.check_eq('the call config names the company''s provider',
    v_conf.provider_code, 'deepseek');
  perform pg_temp.check_eq('its wire shape', v_conf.wire, 'openai');
  perform pg_temp.check_eq('the address to call',
    v_conf.base_url, 'https://api.deepseek.com');
  perform pg_temp.check_eq('the model', v_conf.model_id, 'deepseek-chat');
  perform pg_temp.check_eq('and the company''s OWN key, because it said so',
    v_conf.api_key, 'sk-theirs-not-real');

  -- Switch it back to the platform's key and the same call hands over a
  -- different one. Which key pays is a setting, and this is the line
  -- that proves the setting reaches the call.
  perform public.set_ai_settings(v_org, true, 'deepseek', 'deepseek-chat');
  select * into v_conf from public.ai_call_config(v_org);
  perform pg_temp.check_eq('and the platform''s when it says that instead',
    v_conf.api_key, 'sk-deepseek-not-real');

  -- An override address travels with the key it was keyed in beside,
  -- which is what a company behind its own gateway needs.
  perform public.set_platform_ai_key(
    'deepseek', 'sk-deepseek-not-real', 'https://gateway.example/v1');
  select * into v_conf from public.ai_call_config(v_org);
  perform pg_temp.check_eq('an address keyed in beside the key wins',
    v_conf.base_url, 'https://gateway.example/v1');

  -- ------------------------------------------------------------------
  -- The company next door
  -- ------------------------------------------------------------------
  v_other := pg_temp.test_org('Kedai Sebelah Tanya Sdn Bhd');
  perform public.set_ai_settings(v_other, true, 'qwen', 'qwen-turbo', 'own');
  perform public.set_ai_credentials(v_other, 'qwen', 'sk-next-door-not-real');

  select * into v_conf from public.ai_call_config(v_org);
  perform pg_temp.check_eq(
    'one company''s settings do not reach another''s call',
    v_conf.model_id, 'deepseek-chat');
  select * into v_conf from public.ai_call_config(v_other);
  perform pg_temp.check_eq('and each gets its own key',
    v_conf.api_key, 'sk-next-door-not-real');

  -- ------------------------------------------------------------------
  -- Somebody who is not a platform administrator, and somebody who is
  -- not a member
  -- ------------------------------------------------------------------
  v_stray := pg_temp.another_user('stray@ai.test');
  perform pg_temp.sign_in_as(v_stray);
  perform pg_temp.check_refused('a stranger does not see the provider list',
    'select * from public.platform_ai_providers()',
    'not a platform administrator%', '42501');
  perform pg_temp.check_refused('nor key one in',
    $q$select public.set_platform_ai_key('deepseek', 'sk-mine')$q$,
    'not a platform administrator%', '42501');
  perform pg_temp.check_refused('nor choose what everybody uses',
    $q$select public.set_platform_ai_default('deepseek', 'deepseek-chat')$q$,
    'not a platform administrator%', '42501');
  perform pg_temp.check_refused('nor add a provider of their own',
    $q$select public.upsert_ai_provider('mine', 'Mine', 'openai',
                                        'https://example.test/v1')$q$,
    'not a platform administrator%', '42501');
  perform pg_temp.check_refused('nor add a model to somebody else''s',
    $q$select public.upsert_ai_model('qwen', 'mine', 'Mine')$q$,
    'not a platform administrator%', '42501');
  perform pg_temp.check_refused('nor read a company they do not belong to',
    format('select * from public.ai_status(%L)', v_org),
    'not a member of this company%', '42501');
  perform pg_temp.check_refused('nor set that company''s assistant up',
    format('select public.set_ai_settings(%L, true)', v_org),
    'not permitted to set up the assistant%', '42501');
  perform pg_temp.check_refused('nor give it a key',
    format($q$select public.set_ai_credentials(%L, 'qwen', 'sk-x')$q$, v_org),
    'not permitted to set up the assistant%', '42501');

  perform pg_temp.sign_in_as(v_owner);

  -- ------------------------------------------------------------------
  -- A provider the catalogue did not list
  --
  -- A gateway on the company's own network, or one that shipped after
  -- 0537. Both are OpenAI-shaped nine times in ten, and neither should
  -- need a migration.
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused('a provider code that is not a code',
    $q$select public.upsert_ai_provider('Not A Code!', 'X', 'openai')$q$,
    'A provider code is lower case letters, digits and underscores.%',
    '23514');

  perform public.upsert_ai_provider(
    'inhouse', 'The gateway in the server room', 'openai',
    'https://llm.internal.example/v1');
  perform public.upsert_ai_model('inhouse', 'house-model', 'The house model');
  perform public.set_platform_ai_key('inhouse', 'sk-inhouse-not-real');
  perform public.set_ai_settings(v_org, true, 'inhouse', 'house-model');
  select * into v_conf from public.ai_call_config(v_org);
  perform pg_temp.check_eq('a provider added from the console is callable',
    v_conf.base_url, 'https://llm.internal.example/v1');
  perform pg_temp.check_eq('with the model added beside it',
    v_conf.model_id, 'house-model');

  -- A model retired stops being choosable without taking the history of
  -- who used it away.
  perform public.upsert_ai_model('inhouse', 'house-model', 'The house model',
                                 'chat', false, null, null, false);
  perform pg_temp.check_refused('a retired model cannot be chosen again',
    format($q$select public.set_ai_settings(%L, true, 'inhouse', 'house-model')$q$,
           v_org),
    'That model is not one inhouse answers to.%', '23514');
  perform pg_temp.check_eq('and the row it was chosen by is still there',
    (select count(*) from public.ai_models
      where provider_code = 'inhouse' and model_id = 'house-model'), 1);

  -- ------------------------------------------------------------------
  -- A company that never opened the screen
  -- ------------------------------------------------------------------
  select count(*) into v_n from public.org_ai_settings
   where org_id = pg_temp.test_org('Kedai Diam Sdn Bhd');
  perform pg_temp.check_eq('a company that never chose has no row', v_n, 0);
  select * into v_st from public.ai_status(pg_temp.test_org('Kedai Diam Sdn Bhd'));
  perform pg_temp.check_true('and the assistant is off for it',
    not v_st.is_enabled);
end $$;

rollback;
