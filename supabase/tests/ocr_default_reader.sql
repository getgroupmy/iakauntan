-- =====================================================================
-- iAkauntan :: the reader a company that chose nothing is handed
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ocr_default_reader.sql
--
-- This file exists because of one sentence on a live screen:
--
--     PostgrestException(message: Claude is not available, code: 23514)
--
-- shown to a company whose administrator had switched Gemini ON and
-- Claude OFF in the console and then went to switch scanning on.
--
-- Nothing about that was a coding slip. `ocr_status` (0113) answered
-- `coalesce(s.provider, 'claude')` for a company that had never chosen
-- a reader, the settings card echoed it back on the toggle, and
-- `set_ocr_settings` refused it -- correctly, since Claude had just
-- been retired. The console had no way to say which reader a company
-- falls back to, because that reader was a string literal in a
-- function body. Switching readers on and off changed what was ON
-- OFFER and never changed what anybody GOT.
--
-- So what is asserted here is the gap itself, in both directions:
--
--   * retiring a reader MOVES the company that never chose one, and
--   * does NOT move the company that did.
--
-- The second is not a nicety. Moving a company that deliberately
-- picked Claude would send its bills and bank statements to a
-- different vendor's servers on the strength of somebody else's
-- console toggle. It keeps its choice, the save is refused with a
-- sentence that says what to do, and the screen asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.make_platform_admin(p_user uuid)
returns void language sql as $$
  insert into public.platform_admins (user_id) values (p_user)
  on conflict do nothing;
$$;

do $$
declare
  v_org     uuid;
  v_other   uuid;
  v_owner   uuid := pg_temp.test_user();
  v_status  jsonb;
  v_txt     text;
begin
  v_org := pg_temp.test_org('Sinar Teknologi');

  -- -------------------------------------------------------------------
  -- The state the report came from, reproduced exactly
  --
  -- Claude off, Gemini on, and a company with no `org_ocr_settings`
  -- row at all. Before 0678 the next two assertions both failed: the
  -- status said `claude`, and turning the switch on raised 23514.
  -- -------------------------------------------------------------------
  update public.ocr_providers set is_active = false where code = 'claude';
  update public.ocr_providers set is_active = true  where code = 'gemini';

  perform pg_temp.check_true(
    'a company that never chose is not handed a retired reader',
    (public.ocr_status(v_org) ->> 'provider') <> 'claude');

  perform pg_temp.check_eq(
    'it is handed the first active, ready reader instead',
    public.ocr_status(v_org) ->> 'provider', 'gemini');

  perform pg_temp.check_true(
    'and it is told that is the platform''s suggestion, not its own',
    (public.ocr_status(v_org) ->> 'chosen')::boolean = false
      and public.ocr_status(v_org) ->> 'default_provider' = 'gemini');

  -- The toggle itself. Naming nothing is the whole fix: the screen
  -- moves the switch and says nothing about the reader.
  perform public.set_ocr_settings(v_org, true);
  perform pg_temp.check_eq(
    'switching scanning on with no reader named lands on the default',
    (select provider from public.org_ocr_settings where org_id = v_org),
    'gemini');
  perform pg_temp.check_true(
    'and it is on',
    (select is_enabled from public.org_ocr_settings where org_id = v_org));

  -- Having landed there it is now a CHOICE, and says so. The screen
  -- reads this to decide whether to explain where the reader came
  -- from.
  perform pg_temp.check_true(
    'once stored, the reader is the company''s own answer',
    (public.ocr_status(v_org) ->> 'chosen')::boolean);

  -- -------------------------------------------------------------------
  -- A company that DID choose keeps its choice when it is retired
  --
  -- The opposite of the case above, and the reason `ocr_status` does
  -- not simply substitute the default whenever the stored reader is
  -- inactive. This company said Claude. Nobody gets to un-say it by
  -- toggling a switch in the console.
  -- -------------------------------------------------------------------
  update public.ocr_providers set is_active = true where code = 'claude';
  perform public.set_ocr_settings(v_org, true, 'claude', 'platform');
  update public.ocr_providers set is_active = false where code = 'claude';

  perform pg_temp.check_eq(
    'a retired reader that was chosen is still what the screen shows',
    public.ocr_status(v_org) ->> 'provider', 'claude');

  -- And it is shown as retired, which is what lets the screen draw the
  -- reader list while the switch is off. `ocr_status` lists the active
  -- readers PLUS this one, so a false `is_active` in that list means
  -- exactly one thing.
  perform pg_temp.check_true(
    'and it is marked retired in the list the screen draws from',
    exists (select 1
              from jsonb_array_elements(public.ocr_status(v_org) -> 'providers') p
             where p ->> 'code' = 'claude'
               and (p ->> 'is_active')::boolean = false));

  -- Switching it off is allowed -- you can always stop. Switching it
  -- back ON is refused, and the sentence says what to do about it.
  perform public.set_ocr_settings(v_org, false);
  begin
    perform public.set_ocr_settings(v_org, true);
    perform pg_temp.check_true(
      'switching on a retired reader is refused', false);
  exception when check_violation then
    get stacked diagnostics v_txt = message_text;
    perform pg_temp.check_true(
      'and the refusal names a next step rather than a fact',
      v_txt like '%Choose another reader%');
  end;

  -- Choosing another one fixes it, WITHOUT switching scanning on. The
  -- screen draws this control while the switch is off, so a reader
  -- change that quietly switched scanning on would be the screen doing
  -- something nobody asked for.
  perform public.set_ocr_settings(v_org, false, 'gemini', 'platform');
  perform pg_temp.check_true(
    'changing reader while scanning is off leaves it off',
    (select not is_enabled from public.org_ocr_settings where org_id = v_org));
  perform pg_temp.check_eq(
    'and the reader did change',
    (select provider from public.org_ocr_settings where org_id = v_org),
    'gemini');

  -- -------------------------------------------------------------------
  -- What the platform sets, and what it cannot set
  -- -------------------------------------------------------------------
  perform pg_temp.make_platform_admin(v_owner);
  perform pg_temp.sign_in_as(v_owner);

  -- A reader with no model is listed in the catalog and refused as a
  -- default, because a default that cannot be switched on is the bug
  -- this file is about wearing a different hat. `openai` ships with a
  -- null model on purpose (0113).
  perform pg_temp.check_refused(
    'a reader with no model cannot be the default',
    'select public.platform_set_default_ocr_provider(''openai'')',
    '%No model is set%', '23514');

  perform pg_temp.check_refused(
    'a switched-off reader cannot be the default',
    'select public.platform_set_default_ocr_provider(''claude'')',
    '%switched off%', '23514');

  perform public.platform_set_default_ocr_provider('mlkit');
  perform pg_temp.check_eq(
    'what the platform set is what an unchosen company is offered',
    public.ocr_default_provider(), 'mlkit');

  -- The stale default, which is the same failure one layer up. Retire
  -- the reader named in the setting and the setting must not keep
  -- handing out its name -- otherwise 0678 would have moved the bug
  -- from a function body into a row.
  update public.ocr_providers set is_active = false where code = 'mlkit';
  perform pg_temp.check_true(
    'a default that has since been retired is not handed out',
    public.ocr_default_provider() <> 'mlkit');
  perform pg_temp.check_eq(
    'the first active ready reader is handed out instead',
    public.ocr_default_provider(), 'gemini');

  -- And with nothing usable at all there is still an answer rather
  -- than a null. A null here would reach `ocr_status` as a missing
  -- provider and the settings screen would draw an empty dropdown with
  -- no explanation.
  update public.ocr_providers set is_active = false;
  perform pg_temp.check_true(
    'an empty catalog still answers with something',
    coalesce(public.ocr_default_provider(), '') <> '');

  -- -------------------------------------------------------------------
  -- Not everybody's setting to make
  -- -------------------------------------------------------------------
  v_other := pg_temp.another_user('outsider@example.test');
  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_refused(
    'a signed-in stranger cannot choose the platform''s default',
    'select public.platform_set_default_ocr_provider(''gemini'')',
    '%Platform administrator%', '42501');

  raise notice 'ocr_default_reader: all assertions passed';
end;
$$;

-- =====================================================================
-- Free, chargeable, and a key the guard had never heard of
--
-- `price = 0` already meant free -- `ocr_begin` writes a scan charged
-- at zero and never touches the credit ledger -- and the console had
-- no way to SAY it: the only control was a price box somebody had to
-- think to type `0` into. Asserted here so the word and the ledger
-- cannot come apart.
--
-- And the guard `0675` left behind: a company keeping its own keys in
-- the POOL, with nothing in the single-key field, was refused every
-- scan by a check written before the pool existed.
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_owner uuid := pg_temp.test_user();
  v_file   uuid;
  v_entity uuid;
  v_out    jsonb;
begin
  v_org := pg_temp.test_org('Percuma Sdn Bhd');

  -- The path's third segment must BE the entity id; a fresh uuid in
  -- each place is two records as far as the constraint is concerned.
  v_entity := gen_random_uuid();
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (v_org, 'expenses', v_entity, 'bil.jpg',
          format('%s/expenses/%s/bil.jpg', v_org, v_entity),
          'image/jpeg', 120000)
  returning id into v_file;

  update public.ocr_providers
     set is_active = true, price = 0.30 where code = 'gemini';
  perform public.set_ocr_settings(v_org, true, 'gemini', 'platform');

  -- Chargeable, with no credit: the scan is refused for want of money.
  -- Asserted first so that the free case below cannot pass merely
  -- because nothing was ever being charged.
  perform pg_temp.check_refused(
    'a chargeable reader is refused with no credit',
    format('select public.ocr_begin(%L, %L)', v_org, v_file),
    '%credit%');

  -- The same reader, the same empty balance, marked free.
  update public.ocr_providers set price = 0 where code = 'gemini';
  v_out := public.ocr_begin(v_org, v_file);
  perform pg_temp.check_eq(
    'a free reader charges nothing', (v_out ->> 'charged')::numeric, 0::numeric);
  perform pg_temp.check_true(
    'and takes nothing off a balance that has nothing on it',
    coalesce((select balance from public.org_credits where org_id = v_org), 0)
      = 0);
  perform pg_temp.check_true(
    'and writes no ledger movement to explain a charge it did not make',
    not exists (select 1 from public.credit_ledger l
                 where l.org_id = v_org and l.amount <> 0));

  -- The tenant is told the price is zero, which is what lets the
  -- settings card say "free" rather than print `RM0.00 a scan`.
  perform pg_temp.check_eq(
    'and the settings screen is told so',
    (public.ocr_status(v_org) ->> 'price')::numeric, 0::numeric);

  -- -------------------------------------------------------------------
  -- Own keys, kept in the pool
  -- -------------------------------------------------------------------
  perform public.set_ocr_settings(v_org, false);
  insert into public.ocr_provider_keys (provider, org_id, label, api_key)
  values ('gemini', v_org, 'Ours', 'AIza-not-a-real-key-0001');

  -- Switching on with `own` and only a pool key. Before 0678 both this
  -- and the scan below were refused by a check that predates the pool.
  perform public.set_ocr_settings(v_org, true, 'gemini', 'own');
  perform pg_temp.check_eq(
    'a pool key is a key for switching scanning on',
    (select key_source from public.org_ocr_settings where org_id = v_org),
    'own');

  v_out := public.ocr_begin(v_org, v_file);
  perform pg_temp.check_eq(
    'and a key for running a scan',
    v_out ->> 'key_source', 'own');
  perform pg_temp.check_eq(
    'charged nothing, because own keys never were',
    (v_out ->> 'charged')::numeric, 0::numeric);

  -- Empty the pool and it is refused again, so the assertion above is
  -- about the pool rather than about the guard having been removed.
  delete from public.ocr_provider_keys where org_id = v_org;
  perform pg_temp.check_refused(
    'no key anywhere is still no scan',
    format('select public.ocr_begin(%L, %L)', v_org, v_file),
    '%key has been removed%', '42501');

  -- -------------------------------------------------------------------
  -- Retired between switching on and pressing Scan
  -- -------------------------------------------------------------------
  insert into public.ocr_provider_keys (provider, org_id, label, api_key)
  values ('gemini', v_org, 'Ours', 'AIza-not-a-real-key-0002');
  update public.ocr_providers set is_active = false where code = 'gemini';
  -- And the sentence says where the reader is changed, because "no
  -- longer offered" without "in Settings" is a dead end on a screen
  -- that has no scanning controls on it at all.
  perform pg_temp.check_refused(
    'a reader retired after the fact stops the scan',
    format('select public.ocr_begin(%L, %L)', v_org, v_file),
    '%no longer offered. An administrator chooses another reader in Settings.%',
    '42501');

  raise notice 'ocr_default_reader: charging and pool assertions passed';
end;
$$;

-- =====================================================================
-- The reader a failed scan is retried on
--
-- `0679`. A company's reader has an afternoon and every scan in the
-- company stops. There is a reader sitting there that would work -- the
-- one the platform hands to a company that has chosen nothing -- so a
-- failed scan tries it once.
--
-- Two of these assertions are about when it must NOT happen, and they
-- are the important ones. The fallback runs WITHOUT ASKING: nobody
-- chose this vendor for this company and nobody was shown its price.
-- A chargeable fallback bills for a decision the company did not make,
-- and a fallback on the company's own key spends that key at a vendor
-- it may have deliberately avoided.
-- =====================================================================
do $$
declare
  v_org    uuid;
  v_entity uuid;
  v_file   uuid;
  v_scan   uuid;
  v_out    jsonb;
begin
  v_org := pg_temp.test_org('Gagal Sdn Bhd');

  v_entity := gen_random_uuid();
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (v_org, 'expenses', v_entity, 'bil.jpg',
          format('%s/expenses/%s/bil.jpg', v_org, v_entity),
          'image/jpeg', 120000)
  returning id into v_file;

  -- Claude chosen and chargeable; Gemini free and the platform default.
  update public.ocr_providers
     set is_active = true, price = 0.30 where code = 'claude';
  update public.ocr_providers
     set is_active = true, price = 0 where code = 'gemini';
  insert into public.platform_settings (key, value)
  values ('ocr_default_provider', to_jsonb('gemini'::text))
  on conflict (key) do update set value = excluded.value;

  -- The key first: switching on with `own` and nothing on file is
  -- refused, and rightly.
  insert into public.org_ocr_credentials (org_id, provider, api_key)
  values (v_org, 'claude', 'sk-ant-not-a-real-key');
  perform public.set_ocr_settings(v_org, true, 'claude', 'own');

  v_scan := (public.ocr_begin(v_org, v_file) ->> 'scan_id')::uuid;

  v_out := public.ocr_fallback(v_scan);
  perform pg_temp.check_eq(
    'a failed scan is offered the platform''s free reader',
    v_out ->> 'provider', 'gemini');
  perform pg_temp.check_true(
    'with everything needed to actually call it',
    coalesce(v_out ->> 'endpoint', '') <> ''
      and coalesce(v_out ->> 'model', '') <> ''
      and coalesce(v_out ->> 'kind', '') <> '');
  perform pg_temp.check_true(
    'and nothing that would let it be charged or keyed to this company',
    not (v_out ? 'key_source') and not (v_out ? 'api_key')
      and not (v_out ? 'price'));

  perform pg_temp.check_eq(
    'and the scan records which reader actually read it',
    (select fell_back_to from public.ocr_scans where id = v_scan), 'gemini');

  -- Once. A second ask gets nothing, so a retry loop cannot become a
  -- tour of every vendor the platform has an account with.
  perform pg_temp.check_true(
    'a scan falls back once and once only',
    public.ocr_fallback(v_scan) is null);

  -- -------------------------------------------------------------------
  -- When it must not happen
  -- -------------------------------------------------------------------
  v_scan := (public.ocr_begin(v_org, v_file) ->> 'scan_id')::uuid;
  update public.ocr_providers set price = 0.20 where code = 'gemini';
  perform pg_temp.check_true(
    'a chargeable default is not a fallback; nobody chose it',
    public.ocr_fallback(v_scan) is null);
  perform pg_temp.check_true(
    'and refusing it records nothing on the scan',
    (select fell_back_to from public.ocr_scans where id = v_scan) is null);

  update public.ocr_providers set price = 0 where code = 'gemini';
  update public.ocr_providers set is_active = false where code = 'gemini';
  perform pg_temp.check_true(
    'a retired default is not a fallback',
    public.ocr_fallback(v_scan) is null);

  -- The company's own reader as the default. Retrying the reader that
  -- just failed is not a fallback, it is the same request again.
  update public.ocr_providers set is_active = true where code = 'gemini';
  insert into public.platform_settings (key, value)
  values ('ocr_default_provider', to_jsonb('claude'::text))
  on conflict (key) do update set value = excluded.value;
  update public.ocr_providers set price = 0 where code = 'claude';
  perform pg_temp.check_true(
    'the reader that just failed is not its own fallback',
    public.ocr_fallback(v_scan) is null);

  -- And the on-device reader, which a server cannot run at all.
  update public.ocr_providers set price = 0.30 where code = 'claude';
  update public.ocr_providers set is_active = true, price = 0 where code = 'mlkit';
  insert into public.platform_settings (key, value)
  values ('ocr_default_provider', to_jsonb('mlkit'::text))
  on conflict (key) do update set value = excluded.value;
  perform pg_temp.check_true(
    'an on-device default is not a fallback a server can use',
    public.ocr_fallback(v_scan) is null);

  -- -------------------------------------------------------------------
  -- What the two screens are told
  -- -------------------------------------------------------------------
  update public.ocr_providers set is_active = true, price = 0 where code = 'gemini';
  insert into public.platform_settings (key, value)
  values ('ocr_default_provider', to_jsonb('gemini'::text))
  on conflict (key) do update set value = excluded.value;

  perform pg_temp.check_eq(
    'the settings card can name the reader that would step in',
    public.ocr_status(v_org) ->> 'fallback', 'gemini');
  perform pg_temp.check_true(
    'and the console is told the default is doing both jobs',
    (public.ocr_default_state() ->> 'is_fallback')::boolean
      and (public.ocr_default_state() ->> 'is_free')::boolean);

  -- Price it and both sentences must stop promising a retry, in step.
  -- Two screens reading one rule out of two places is two chances for
  -- one of them to go on saying a scan will be retried after the day
  -- it stopped being true.
  update public.ocr_providers set price = 0.20 where code = 'gemini';
  perform pg_temp.check_true(
    'pricing the default withdraws the promise from the settings card',
    public.ocr_status(v_org) ->> 'fallback' is null);
  perform pg_temp.check_true(
    'and from the console, in the same breath',
    not (public.ocr_default_state() ->> 'is_fallback')::boolean);

  -- -------------------------------------------------------------------
  -- Not a function a tenant may call
  --
  -- It hands back an endpoint and a model for a reader this company
  -- never chose, off a scan id, and a scan id is not a secret.
  -- -------------------------------------------------------------------
  perform pg_temp.check_true(
    'ocr_fallback is the service role''s alone',
    not has_function_privilege('authenticated', 'public.ocr_fallback(uuid)',
                               'execute')
      and not has_function_privilege('anon', 'public.ocr_fallback(uuid)',
                                     'execute')
      and has_function_privilege('service_role', 'public.ocr_fallback(uuid)',
                                 'execute'));

  raise notice 'ocr_default_reader: fallback assertions passed';
end;
$$;

-- =====================================================================
-- No key comes back, by any road
--
-- Every reader key in this system is somebody else's money: a leaked
-- Gemini key is billed to the platform until it is noticed, and a
-- leaked tenant key is billed to that company. The tables are shut --
-- RLS on, grants revoked from `anon` and `authenticated` -- so the
-- question is not whether they can be SELECTed but whether anything
-- ELSE hands one out: a function, a view, a log, an error message.
--
-- Asserted rather than reasoned about, because every one of these was
-- true when it was written and the next person to add a column to a
-- returning function will not have read this file.
-- =====================================================================
do $$
declare
  v_bad text;
begin
  -- 1. Nothing but the service role reaches either table.
  perform pg_temp.check_true(
    'the key tables are shut to every signed-in role',
    not has_table_privilege('authenticated', 'public.ocr_provider_keys',
                            'select')
      and not has_table_privilege('anon', 'public.ocr_provider_keys', 'select')
      and not has_table_privilege('authenticated',
                                  'public.org_ocr_credentials', 'select')
      and not has_table_privilege('anon', 'public.org_ocr_credentials',
                                  'select'));

  -- 2. RLS is on, so a future grant does not silently open them.
  perform pg_temp.check_true(
    'and row level security is on underneath that',
    (select bool_and(relrowsecurity) from pg_class
      where oid in ('public.ocr_provider_keys'::regclass,
                    'public.org_ocr_credentials'::regclass)));

  -- 3. The one function that lists keys returns no column that could
  --    carry one. Asserted on the SIGNATURE rather than on a row: a
  --    pool with no key in it returns nothing, and a test that looked
  --    only at rows would pass on an empty table for ever.
  perform pg_temp.check_true(
    'no column of ocr_keys_for could carry a key',
    not exists (
      select 1 from unnest(string_to_array(
               pg_get_function_result('public.ocr_keys_for(text, uuid)'::regprocedure),
               ',')) col
       where col ilike '%api_key%' or col ilike '%secret%'
         or (col ilike '%key%' and col not ilike '%key_tail%'
             and col not ilike '%key_id%')));

  -- 4. Nothing anywhere in `public` hands a key back to a signed-in
  --    caller. The sweep is the point: the three functions above are
  --    the ones anybody would think to check, and the one that leaks
  --    will be the fourth somebody adds in a hurry.
  --    A COLUMN CALLED `api_key`, of a type that could hold one. Not
  --    the substring: `org_payment_gateway_status` returns
  --    `has_api_key boolean`, which is the opposite of a leak -- it is
  --    how a screen says a key is on file without being shown it --
  --    and a test that failed on it would be a test somebody turns off.
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('authenticated', p.oid, 'execute')
     and pg_get_function_result(p.oid) ~*
         '(^|[^a-z_])(api_key|api_secret|secret_key|private_key|client_secret)[[:space:]]+(text|character varying|varchar|bytea)';
  perform pg_temp.check_true(
    format('no function a tenant may call returns an api_key (%s)',
           coalesce(v_bad, 'none')),
    v_bad is null);

  -- 5. And the pool's own read path is scoped. A member of one company
  --    asking for the PLATFORM's pool -- a null org id, which is the
  --    console's own argument -- gets nothing rather than a listing.
  --    Asserted in `ocr_key_pool.sql` against rows; asserted here
  --    against the grant, so that a change to either is caught by one
  --    of the two.
  perform pg_temp.check_true(
    'claiming a key is the service role''s alone',
    not has_function_privilege('authenticated',
          'public.claim_ocr_key(text, uuid)', 'execute')
      and not has_function_privilege('anon',
          'public.claim_ocr_key(text, uuid)', 'execute'));

  raise notice 'ocr_default_reader: no key comes back by any road';
end;
$$;

rollback;
