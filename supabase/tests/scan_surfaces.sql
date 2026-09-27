-- =====================================================================
-- iAkauntan :: the five scanning surface switches
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scan_surfaces.sql
--
-- `0718` put a Settings page under Console → Document scanning, with a
-- toggle for the Scan button, the Upload button, "My own key", the
-- Upload button on Bank statements, and whether "Send documents to a
-- reader" is ON BY DEFAULT.
--
-- Three of those are presentation and two are rules, and the two rules
-- are what is asserted here. A switch that only moves a widget is
-- checked by the widget tests; a switch that decides whose money pays
-- and whose paperwork is sent to a model is checked in the place that
-- enforces it.
--
-- THE ONE WORTH THE FILE is the default. `org_ocr_settings` has no row
-- for a company that has never chosen, and THREE functions read that
-- absence:
--
--     ocr_status        what the screen draws
--     ocr_begin         what lets a document go to a reader
--     ocr_record_local  what lets a reading made on the device be filed
--
-- Changing one and not the others would put a switch reading "on"
-- above a server refusing every document. All three are walked below,
-- in both positions.
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

create or replace function pg_temp.receipt(p_org uuid, p_file text)
returns uuid language plpgsql as $$
declare
  v_entity uuid := gen_random_uuid();
  v_id     uuid;
begin
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (p_org, 'expenses', v_entity, p_file,
          format('%s/expenses/%s/%s', p_org, v_entity, p_file),
          'image/jpeg', 120000)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- What ships, and it is today's behaviour in every position
-- ---------------------------------------------------------------------
do $$
declare v_now jsonb;
begin
  v_now := public.scan_surfaces();

  perform pg_temp.check_true('the Scan button ships on',
    (v_now ->> 'scan_button')::boolean);
  perform pg_temp.check_true('the Upload button ships on',
    (v_now ->> 'upload_button')::boolean);
  perform pg_temp.check_true('reading on your own key ships allowed',
    (v_now ->> 'own_key')::boolean);
  perform pg_temp.check_true('the statements Upload button ships on',
    (v_now ->> 'statements_upload')::boolean);

  -- The one that ships the other way, and deliberately: scanning is
  -- off for a new company today, and a migration that turned it on for
  -- everybody would start sending paperwork to a model on nobody's say-so.
  perform pg_temp.check_true('but sending to a reader ships OFF',
    (v_now ->> 'reader_on_default')::boolean = false);

  raise notice 'ok   the five switches ship as the product already behaves';
end $$;

-- ---------------------------------------------------------------------
-- Who may move one, and what it refuses
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid := pg_temp.test_user();
  v_org  uuid;
begin
  v_org := pg_temp.test_org('Switch Flipper Sdn Bhd');
  perform pg_temp.sign_in_as(v_user);

  begin
    perform public.set_scan_surface('scan_show_scan_button', false);
    raise exception 'FAIL: an ordinary user moved a platform switch';
  exception when sqlstate '42501' then
    raise notice 'ok   an ordinary user cannot move a platform switch';
  end;

  perform pg_temp.make_platform_admin(v_user);

  -- `0678`'s lesson in another corner: a setter that took any string
  -- would write a row nothing reads, and the sweep would find it a
  -- year later.
  begin
    perform public.set_scan_surface('scan_show_the_moon', false);
    raise exception 'FAIL: wrote a switch nothing reads';
  exception when sqlstate '23514' then
    raise notice 'ok   a switch nobody reads cannot be created by typo';
  end;

  begin
    perform public.set_scan_surface('scan_show_scan_button', null);
    raise exception 'FAIL: a switch was set to neither';
  exception when sqlstate '23514' then
    raise notice 'ok   a switch is on or off, not neither';
  end;

  perform public.set_scan_surface('scan_show_scan_button', false);
  perform pg_temp.check_true('a platform administrator can turn one off',
    (public.scan_surfaces() ->> 'scan_button')::boolean = false);
  perform public.set_scan_surface('scan_show_scan_button', true);
  perform pg_temp.check_true('and back on again',
    (public.scan_surfaces() ->> 'scan_button')::boolean);

  -- A row somebody deleted must not take a surface off the product.
  -- The exception is the one whose safe answer is off.
  delete from public.platform_settings where key = 'scan_show_scan_button';
  delete from public.platform_settings where key = 'scan_reader_on_by_default';
  perform pg_temp.check_true('a missing row leaves a surface on',
    (public.scan_surfaces() ->> 'scan_button')::boolean);
  perform pg_temp.check_true('but leaves the reader default off',
    (public.scan_surfaces() ->> 'reader_on_default')::boolean = false);

  raise notice 'ok   only the platform moves these, and only these';
end $$;

-- ---------------------------------------------------------------------
-- The default, in all three places that read the absent row
-- ---------------------------------------------------------------------
do $$
declare
  v_user  uuid := pg_temp.test_user();
  v_org   uuid;
  v_file  uuid;
  v_file2 uuid;
  v_said  text;
begin
  v_org := pg_temp.test_org('Never Chose Sdn Bhd');
  perform pg_temp.sign_in_as(v_user);
  perform pg_temp.make_platform_admin(v_user);
  v_file  := pg_temp.receipt(v_org, 'tenaga-jun.jpg');
  v_file2 := pg_temp.receipt(v_org, 'tenaga-jul.jpg');

  perform pg_temp.check_true('the company has never touched the switch',
    not exists (select 1 from public.org_ocr_settings where org_id = v_org));

  -- OFF, which is where the product is today.
  perform public.set_scan_surface('scan_reader_on_by_default', false);
  perform pg_temp.check_true('with the default off, the screen says off',
    (public.ocr_status(v_org) ->> 'enabled')::boolean = false);
  begin
    perform public.ocr_begin(v_org, v_file);
    raise exception 'FAIL: sent a document to a reader while off';
  exception when sqlstate '42501' then
    raise notice 'ok   and the server refuses the document';
  end;
  begin
    perform public.ocr_record_local(v_org, v_file, '{}'::jsonb);
    raise exception 'FAIL: filed a device reading while off';
  exception when sqlstate '42501' then
    raise notice 'ok   and a reading made on the device is refused too';
  end;

  -- ON. All three have to move together, which is the whole point.
  perform public.set_scan_surface('scan_reader_on_by_default', true);
  perform pg_temp.check_true('with the default on, the screen says on',
    (public.ocr_status(v_org) ->> 'enabled')::boolean);

  -- A company on the default has NO provider of its own. Before `0718`
  -- read this far, the first one to get here would have been told
  -- "There is no reader called <null>".
  perform pg_temp.check_true('and it is handed the platform''s reader',
    coalesce(public.ocr_status(v_org) ->> 'provider', '') <> '');
  perform pg_temp.check_eq('which it is told is not its own choice',
    (public.ocr_status(v_org) ->> 'chosen'), 'false');

  perform public.platform_topup_credit(v_org, 10);
  perform pg_temp.check_true('the server accepts the document',
    (public.ocr_begin(v_org, v_file) ->> 'scan_id') is not null);
  perform pg_temp.check_eq('and files it against the platform''s key',
    (select key_source from public.ocr_scans where attachment_id = v_file),
    'platform');

  perform pg_temp.check_true('and a device reading is filed too',
    public.ocr_record_local(v_org, v_file2, '{}'::jsonb) is not null);

  raise notice 'ok   the default reaches the screen, the server and the device';
end $$;

-- ---------------------------------------------------------------------
-- A row is a choice. Its absence is not
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid := pg_temp.test_user();
  v_org  uuid;
  v_file uuid;
begin
  v_org := pg_temp.test_org('Said No Sdn Bhd');
  perform pg_temp.sign_in_as(v_user);
  perform pg_temp.make_platform_admin(v_user);
  v_file := pg_temp.receipt(v_org, 'bill.jpg');

  -- Turned on, then off. That is an answer, and it has to survive the
  -- platform changing its mind -- otherwise this is an override wearing
  -- the word "default", and it would switch scanning back on for a
  -- company that had deliberately switched it off.
  perform public.set_ocr_settings(v_org, true);
  perform public.set_ocr_settings(v_org, false);
  perform public.set_scan_surface('scan_reader_on_by_default', true);

  perform pg_temp.check_true('a company that chose off stays off',
    (public.ocr_status(v_org) ->> 'enabled')::boolean = false);
  begin
    perform public.ocr_begin(v_org, v_file);
    raise exception 'FAIL: the default overrode a company''s own answer';
  exception when sqlstate '42501' then
    raise notice 'ok   and the server still refuses its documents';
  end;

  perform public.set_scan_surface('scan_reader_on_by_default', false);
  raise notice 'ok   a default speaks for silence, not over an answer';
end $$;

-- ---------------------------------------------------------------------
-- "My own key" is a rule, so it is refused in the database
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid := pg_temp.test_user();
  v_org  uuid;
  v_kept uuid;
  v_code text;
begin
  v_org := pg_temp.test_org('Own Key Sdn Bhd');
  v_kept := pg_temp.test_org('Already Own Sdn Bhd');
  perform pg_temp.sign_in_as(v_user);
  perform pg_temp.make_platform_admin(v_user);

  select code into v_code from public.ocr_providers
   where is_active and takes_key and app.ocr_provider_ready(public.ocr_providers.*)
   order by sort_order limit 1;

  -- A company that got there while it was allowed.
  perform public.set_ocr_credentials(v_kept, v_code, 'sk-test-key');
  perform public.set_ocr_settings(v_kept, true, v_code, 'own');

  perform public.set_scan_surface('scan_allow_own_key', false);

  begin
    perform public.set_ocr_credentials(v_org, v_code, 'sk-test-key');
    perform public.set_ocr_settings(v_org, true, v_code, 'own');
    raise exception 'FAIL: chose its own key while the platform forbids it';
  exception when sqlstate '42501' then
    raise notice 'ok   a new company cannot choose its own key';
  end;

  -- Hiding it on the screen would have left this call working, which is
  -- the difference between a rule and a decoration.
  perform pg_temp.check_true('the screen is told the choice is withdrawn',
    (public.ocr_status(v_org) ->> 'own_key_allowed')::boolean = false);

  -- The company already on it is NOT stranded: withdrawing the option
  -- must not trap somebody on a key they can no longer move off, and
  -- moving them to platform credit unasked would spend their money.
  perform public.set_ocr_settings(v_kept, true, v_code, 'own');
  perform pg_temp.check_eq('a company already on its own key keeps it',
    (select key_source from public.org_ocr_settings where org_id = v_kept),
    'own');
  perform public.set_ocr_settings(v_kept, true, v_code, 'platform');
  perform pg_temp.check_eq('and can still move back to platform credit',
    (select key_source from public.org_ocr_settings where org_id = v_kept),
    'platform');

  perform public.set_scan_surface('scan_allow_own_key', true);
  raise notice 'ok   whose key pays is decided in the database';
end $$;

rollback;
