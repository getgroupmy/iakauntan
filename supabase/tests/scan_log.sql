-- =====================================================================
-- iAkauntan :: the log that makes the reference mean something
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scan_log.sql
--
-- A scan that fails tells the person scanning:
--
--     The document could not be read. Quote this reference if you get
--     in touch.  {ref: e5b6506c-..., scan_id: 6e50da40-...}
--
-- The vagueness is deliberate and stays -- a Document AI failure
-- quotes the project, the processor and sometimes the page it choked
-- on, and none of that belongs in a response body. What was missing is
-- anywhere to redeem the reference: `grep -rn ocr_scans app/lib`
-- returned NOTHING, so "get in touch" resolved to hand-written SQL
-- against production.
--
-- Two of the assertions below are the ones that would go stale
-- quietly:
--
--   * the reference is searchable AT ALL. `logFailure` mints it with
--     `crypto.randomUUID()` and, until `0680`, wrote it only to the
--     function's stdout -- so of the two identifiers in that message,
--     the one labelled "reference" was the one nothing could look up.
--
--   * a scan stuck `pending` is counted as a PROBLEM. It does not look
--     like one: the status reads as "still going" for ever, and the
--     charge behind it was taken and never refunded.
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
  v_owner   uuid := pg_temp.test_user();
  v_other   uuid;
  v_entity  uuid;
  v_file    uuid;
  v_failed  uuid;
  v_stuck   uuid;
  v_ok      uuid;
  v_health  jsonb;
  v_n       integer;
  v_row     record;
begin
  v_org := pg_temp.test_org('Sinar Teknologi');

  v_entity := gen_random_uuid();
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (v_org, 'expenses', v_entity, 'bil-september.jpg',
          format('%s/expenses/%s/bil-september.jpg', v_org, v_entity),
          'image/jpeg', 120000)
  returning id into v_file;

  -- Three scans, one of each shape that matters. Written straight
  -- rather than through `ocr_begin`, because what is under test is the
  -- READING of them and a fixture that had to succeed at scanning
  -- first would be a fixture that fails for the wrong reason.
  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged, refunded, error, log_ref, created_at, finished_at)
  values (v_org, v_file,
          format('%s/expenses/%s/bil-september.jpg', v_org, v_entity),
          'claude', 'platform', 'failed', 0.30, false,
          'Anthropic returned 401: invalid x-api-key',
          'e5b6506c-856f-4a76-b62f-d58504065d3e',
          now() - interval '10 minutes', now() - interval '10 minutes')
  returning id into v_failed;

  -- Pending, and old. The function died between `ocr_begin` and
  -- `ocr_finish`.
  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged, refunded, created_at)
  values (v_org, v_file,
          format('%s/expenses/%s/bil-september.jpg', v_org, v_entity),
          'claude', 'platform', 'pending', 0.30, false,
          now() - interval '3 hours')
  returning id into v_stuck;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged, refunded, created_at, finished_at)
  values (v_org, v_file,
          format('%s/expenses/%s/bil-september.jpg', v_org, v_entity),
          'claude', 'platform', 'ok', 0.30, false,
          now() - interval '5 minutes', now() - interval '5 minutes')
  returning id into v_ok;

  -- -------------------------------------------------------------------
  -- Not for the company whose scans these are
  --
  -- They may read their own `ocr_scans` row -- the policy has said so
  -- since `0111` -- but this function joins every company on the
  -- platform, and an administrator of one company reading the reasons
  -- another company's scans failed is a list of who uses what.
  -- -------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_owner);
  select count(*) into v_n from public.platform_scan_log(50, null, null);
  perform pg_temp.check_eq(
    'an administrator of the company gets no rows from the console log',
    v_n, 0);
  perform pg_temp.check_true(
    'and no numbers either',
    public.platform_scan_health() = '{}'::jsonb);

  -- -------------------------------------------------------------------
  -- For a platform administrator
  -- -------------------------------------------------------------------
  perform pg_temp.make_platform_admin(v_owner);
  perform pg_temp.sign_in_as(v_owner);

  select * into v_row from public.platform_scan_log(50, 'failed', null);
  perform pg_temp.check_eq(
    'the failure carries the vendor''s own sentence',
    v_row.error, 'Anthropic returned 401: invalid x-api-key');
  perform pg_temp.check_eq(
    'and the company by name, not by uuid',
    v_row.org_name, 'Sinar Teknologi');
  perform pg_temp.check_eq(
    'and the reader by name',
    v_row.provider_name, 'Claude');
  perform pg_temp.check_eq(
    'and the document, without the path around it',
    v_row.file_name, 'bil-september.jpg');
  perform pg_temp.check_true(
    'and says the money did not come back',
    v_row.amount_charged = 0.30 and not v_row.refunded);

  -- -------------------------------------------------------------------
  -- The reference, which is the whole point
  --
  -- Both identifiers off the message, and a prefix of either, because
  -- nobody types out a uuid and nobody should have to know which of
  -- the two the system can use.
  -- -------------------------------------------------------------------
  select count(*) into v_n from public.platform_scan_log(
    50, null, 'e5b6506c-856f-4a76-b62f-d58504065d3e');
  perform pg_temp.check_eq('the reference finds the scan', v_n, 1);

  select count(*) into v_n from public.platform_scan_log(50, null, 'e5b6506c');
  perform pg_temp.check_eq('a prefix of it is enough', v_n, 1);

  select count(*) into v_n
    from public.platform_scan_log(50, null, left(v_stuck::text, 8));
  perform pg_temp.check_eq('and so is a prefix of the scan id', v_n, 1);

  -- Upper case, because a uuid copied off a screenshot or retyped by
  -- somebody reading it aloud arrives in whatever case it arrives in.
  select count(*) into v_n from public.platform_scan_log(50, null, 'E5B6506C');
  perform pg_temp.check_eq('and case is not the user''s problem', v_n, 1);

  -- A search crosses the status filter. Somebody who has pasted a
  -- reference wants THAT scan, and a filter that silently excluded it
  -- would be the screen refusing the question it was opened for.
  select count(*) into v_n
    from public.platform_scan_log(50, null, left(v_ok::text, 8));
  perform pg_temp.check_eq('a scan that SUCCEEDED can still be found', v_n, 1);

  -- And a search is not a way to read everything.
  select count(*) into v_n
    from public.platform_scan_log(50, null, 'ffffffff');
  perform pg_temp.check_eq('a reference that matches nothing finds nothing',
    v_n, 0);
  -- An empty string is "no search", not "match everything with a
  -- prefix of nothing" -- which happens to be the same set here, so it
  -- is asserted against the count rather than assumed.
  select count(*) into v_n from public.platform_scan_log(50, null, '   ');
  perform pg_temp.check_eq('blank means no filter', v_n, 3);

  -- -------------------------------------------------------------------
  -- The three numbers, and the one that is money
  -- -------------------------------------------------------------------
  v_health := public.platform_scan_health();
  perform pg_temp.check_eq('read today',   (v_health ->> 'ok_24h')::int, 1);
  perform pg_temp.check_eq('failed today', (v_health ->> 'failed_24h')::int, 1);
  perform pg_temp.check_eq(
    'and the one still pending three hours on is counted as stuck',
    (v_health ->> 'unsettled')::int, 1);
  perform pg_temp.check_eq(
    'with what it took and never gave back',
    (v_health ->> 'unsettled_charged')::numeric, 0.30::numeric);

  -- A scan that started a minute ago is IN PROGRESS, not stuck. Without
  -- this the count would be "every pending scan", and a console that
  -- cried about every scan while it was running would be a console
  -- nobody reads.
  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged, created_at)
  values (v_org, v_file,
          format('%s/expenses/%s/bil-september.jpg', v_org, v_entity),
          'claude', 'platform', 'pending', 0.30, now());
  perform pg_temp.check_eq(
    'a scan that started just now is not stuck',
    (public.platform_scan_health() ->> 'unsettled')::int, 1);

  -- -------------------------------------------------------------------
  -- Recording the reference is the service role's alone
  --
  -- It writes to a row belonging to a company, keyed on a scan id, and
  -- a scan id is not a secret -- so anybody who could call this could
  -- overwrite the reference on somebody else's failure and make it
  -- unfindable.
  -- -------------------------------------------------------------------
  perform pg_temp.check_true(
    'only the service role records a reference',
    not has_function_privilege('authenticated',
          'public.ocr_note_log_ref(uuid, text)', 'execute')
      and not has_function_privilege('anon',
          'public.ocr_note_log_ref(uuid, text)', 'execute')
      and has_function_privilege('service_role',
          'public.ocr_note_log_ref(uuid, text)', 'execute'));

  perform public.ocr_note_log_ref(v_stuck, 'abcd1234-0000-0000-0000-000000000000');
  perform pg_temp.check_eq(
    'and recording one makes that scan findable by it',
    (select count(*) from public.platform_scan_log(50, null, 'abcd1234')), 1);

  -- -------------------------------------------------------------------
  -- Nobody signed in reads any of it
  -- -------------------------------------------------------------------
  v_other := pg_temp.another_user('outsider@example.test');
  perform pg_temp.sign_in_as(v_other);
  select count(*) into v_n from public.platform_scan_log(50, null, null);
  perform pg_temp.check_eq('a stranger gets nothing', v_n, 0);

  perform pg_temp.sign_out();
  perform pg_temp.check_true(
    'and anon cannot call either function',
    not has_function_privilege('anon',
          'public.platform_scan_log(integer, text, text)', 'execute')
      and not has_function_privilege('anon',
          'public.platform_scan_health()', 'execute'));

  raise notice 'scan_log: all assertions passed';
end;
$$;

rollback;
