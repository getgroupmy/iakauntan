-- =====================================================================
-- iAkauntan :: reading the same file again, with a reader you name
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ocr_rescan.sql
--
-- `0698`. Asked for from the SmartScan screen, looking at a scan that
-- had come back wrong: read it again, and read it with something else.
-- The second is the one that matters -- a reader that refused a PDF or
-- made `Page 1 of 2` out of a supplier name will not do better on the
-- second try.
--
-- `p_provider` is a caller-supplied string that decides WHICH VENDOR
-- GETS THE DOCUMENT and WHAT THE COMPANY IS CHARGED, so what it is
-- allowed to be is the whole of this file:
--
--   * absent or empty means the company's own reader, unchanged -- the
--     behaviour every caller written before `0698` depends on, and the
--     one the deployed edge function still uses while the migration is
--     applied and before it is redeployed;
--   * a named reader is USED, and the scan row says so, or the inbox
--     cannot tell somebody which reader produced which reading;
--   * the charge is the NAMED reader's price. A company on a free
--     reader that asks for a chargeable one pays for it;
--   * a reader that is retired, unready, unknown, or runs on the
--     device is refused BEFORE anything is charged;
--   * AND A COMPANY ON ITS OWN KEY CANNOT NAME A READER IT HAS NO KEY
--     FOR. That is the hole worth having a file for: without it, an
--     org bringing its own Claude key could name Gemini and have the
--     platform's pool pay for the call.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.a_file(p_org uuid, p_name text)
returns uuid language plpgsql as $$
declare
  v_entity uuid := gen_random_uuid();
  v_id     uuid;
begin
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (p_org, 'expenses', v_entity, p_name,
          format('%s/expenses/%s/%s', p_org, v_entity, p_name),
          'application/pdf', 90000)
  returning id into v_id;
  return v_id;
end;
$$;

do $$
declare
  v_org    uuid;
  v_file   uuid;
  v_begun  jsonb;
  v_scan   uuid;
  v_code   text;
  v_charge numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org  := pg_temp.test_org('Pembaca Sdn Bhd');
  v_file := pg_temp.a_file(v_org, 'bil.pdf');

  -- Two server readers at different prices, so "which one was charged"
  -- is answerable rather than a coincidence of equal numbers.
  update public.ocr_providers
     set is_active = true, price = 0.10, model = 'x', endpoint = 'https://e'
   where code = 'gemini';
  update public.ocr_providers
     set is_active = true, price = 0.45, model = 'y',
         endpoint = 'https://a'
   where code = 'claude';

  perform public.set_ocr_settings(v_org, true, 'gemini', 'platform');
  perform app.move_credit(v_org, 'topup', 100, 'fixture', null, null, true);

  -- -------------------------------------------------------------------
  -- 1. No choice is the company's reader, and its price
  -- -------------------------------------------------------------------
  v_begun := public.ocr_begin(v_org, v_file);
  perform pg_temp.check_eq('no choice uses the company''s reader',
    v_begun ->> 'provider', 'gemini');
  perform pg_temp.check_eq('and charges its price',
    (v_begun ->> 'charged')::numeric, 0.10);

  -- An empty string is somebody clearing a picker, not an unknown
  -- reader. Looking `''` up in the catalog would refuse it.
  v_begun := public.ocr_begin(v_org, v_file, '');
  perform pg_temp.check_eq('an empty choice is no choice',
    v_begun ->> 'provider', 'gemini');

  -- -------------------------------------------------------------------
  -- 2. A named reader is used, recorded, and charged for
  -- -------------------------------------------------------------------
  v_begun := public.ocr_begin(v_org, v_file, 'claude');
  v_scan  := (v_begun ->> 'scan_id')::uuid;
  perform pg_temp.check_eq('a named reader is the one handed the document',
    v_begun ->> 'provider', 'claude');
  perform pg_temp.check_eq('at the NAMED reader''s price, not the company''s',
    (v_begun ->> 'charged')::numeric, 0.45);

  -- On the row, or the inbox cannot say which reader produced which
  -- reading -- which is the entire point of offering a second one.
  select provider, amount_charged into v_code, v_charge
    from public.ocr_scans where id = v_scan;
  if v_code is distinct from 'claude' then
    raise exception 'the scan row records % rather than claude', v_code;
  end if;
  if v_charge is distinct from 0.45 then
    raise exception 'the scan row was charged % rather than 0.45', v_charge;
  end if;

  -- And the company's SETTING is untouched. A rescan is one document,
  -- not a change of reader -- the next capture goes to gemini.
  perform pg_temp.check_eq('naming a reader does not change the setting',
    public.ocr_status(v_org) ->> 'provider', 'gemini');

  -- -------------------------------------------------------------------
  -- 3. What a named reader may not be
  -- -------------------------------------------------------------------
  begin
    perform public.ocr_begin(v_org, v_file, 'mlkit');
    raise exception 'the on-device reader was accepted for a server scan';
  exception
    when sqlstate '0A000' then null;
  end;

  begin
    perform public.ocr_begin(v_org, v_file, 'no-such-reader');
    raise exception 'an unknown reader was accepted';
  exception
    when sqlstate '23514' then null;
  end;

  update public.ocr_providers set is_active = false where code = 'claude';
  begin
    perform public.ocr_begin(v_org, v_file, 'claude');
    raise exception 'a retired reader was accepted';
  exception
    when sqlstate '42501' then null;
  end;
  update public.ocr_providers set is_active = true where code = 'claude';

  -- Unready: on the catalog, switched on, and the platform has not
  -- finished setting it up. `set_ocr_settings` refuses it, so offering
  -- it here would be one screen contradicting another.
  update public.ocr_providers
     set model = null, endpoint = null where code = 'claude';
  begin
    perform public.ocr_begin(v_org, v_file, 'claude');
    raise exception 'a reader the platform never finished was accepted';
  exception
    when sqlstate '42501' then
      if sqlerrm not like '%not been set up%' then
        raise exception 'refused for the wrong reason: %', sqlerrm;
      end if;
  end;
  update public.ocr_providers
     set model = 'y', endpoint = 'https://a' where code = 'claude';

  raise notice 'ocr rescan: a named reader is used, recorded and charged';
end $$;

-- ---------------------------------------------------------------------
-- The company's own key, and the reader it has no key for
--
-- The hole this file exists for. On `key_source = 'own'` the platform
-- pays for nothing and the company's own credential is used -- so a
-- named reader it holds no key for must be refused, or the call falls
-- through to whatever the platform has.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_file uuid;
  v_n    integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org  := pg_temp.test_org('Kunci Sendiri Sdn Bhd');
  v_file := pg_temp.a_file(v_org, 'invois.pdf');

  update public.ocr_providers
     set is_active = true, model = 'x', endpoint = 'https://e'
   where code in ('gemini', 'claude');

  -- Claude and not Gemini, and that is not arbitrary:
  -- `set_ocr_credentials` (`0111`) still refuses every provider but
  -- `claude` and `google`, so a company CANNOT store its own key for
  -- Gemini, ChatGPT or Grok -- which `0675` added and that allowlist
  -- never heard about. Recorded here rather than worked around
  -- silently, because it is a real gap and it is not this migration's
  -- to close.
  perform public.set_ocr_settings(v_org, true, 'claude', 'platform');
  perform public.set_ocr_credentials(v_org, 'claude', 'sk-test-claude');
  perform public.set_ocr_settings(v_org, true, 'claude', 'own');

  -- Its own reader still works, or the assertion below proves nothing.
  perform pg_temp.check_true('a company on its own key can scan with it',
    (public.ocr_begin(v_org, v_file) ->> 'provider') = 'claude');

  begin
    perform public.ocr_begin(v_org, v_file, 'gemini');
    raise exception
      'a company on its own key named a reader it has no key for';
  exception
    when sqlstate '42501' then
      if sqlerrm not like '%key has been removed%' then
        raise exception 'refused for the wrong reason: %', sqlerrm;
      end if;
  end;

  -- And nothing was charged for the refusal. The insert and the charge
  -- both sit after the guard, so a refusal that had written a row
  -- would be a scan somebody paid for and never got.
  select count(*) into v_n from public.ocr_scans
   where org_id = v_org and provider = 'gemini';
  if v_n <> 0 then
    raise exception '% gemini scans were recorded for a refused call', v_n;
  end if;

  -- `0702`. The attachment deleted after a screen read its id, which
  -- is the ordinary way somebody reaches this refusal -- and it used to
  -- answer "That attachment is not on this organization", a sentence
  -- about TENANCY that sends them to check which company they are in.
  --
  -- The composite key is what makes the old wording almost always
  -- false: a non-null `attachment_id` HAD a row on this organization,
  -- and deleting the attachment nulls the column. So the id in a
  -- client's hand naming nothing means it went stale, not that it
  -- belongs to somebody else.
  declare
    v_stale uuid := gen_random_uuid();
  begin
    begin
      perform public.ocr_begin(v_org, v_stale);
      raise exception 'a scan was opened against an attachment that is gone';
    exception
      when sqlstate '42704' then
        if sqlerrm like '%not on this organization%' then
          raise exception
            'a deleted file is still described as a tenancy problem: %',
            sqlerrm;
        end if;
        if sqlerrm not like '%no longer on file%' then
          raise exception 'refused for the wrong reason: %', sqlerrm;
        end if;
    end;
  end;

  raise notice 'ocr rescan: own key means own reader';
end $$;

rollback;
