-- =====================================================================
-- iAkauntan :: what the reader actually said
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scan_exchanges.sql
--
-- `0704`. The console could show one sentence -- `ocr_scans.error` --
-- written by us out of whichever field of the vendor's JSON the edge
-- function reached for. The raw reply was read once inside the reader
-- and dropped, so the day a reader answers something the code did not
-- anticipate, the log says `HTTP 400` and nothing else.
--
-- Three things are asserted here and the middle one is the reason the
-- file exists:
--
--   * every call is a row, in the order it happened. A scan can be
--     three requests to two vendors -- the attempt, the retry and the
--     fallback -- and "which of them said what" was unanswerable;
--
--   * A TENANT CANNOT READ IT. They can read their own `ocr_scans`
--     rows, and this table deliberately does not work that way: a
--     vendor's failure quotes the project and the processor, and a
--     successful reply contains the document. RLS is on with no policy,
--     and the only door is guarded by `app.is_platform_admin()`;
--
--   * it is thrown away again. Raw bodies are the largest thing this
--     system keeps, and a log with no end is a table nobody notices
--     until it is the reason a backup takes an hour.
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

create or replace function pg_temp.a_scan(p_org uuid)
returns uuid language plpgsql as $$
declare
  v_entity uuid := gen_random_uuid();
  v_file   uuid;
  v_scan   uuid;
begin
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path, mime_type,
     file_size)
  values (p_org, 'expenses', v_entity, 'resit.jpg',
          format('%s/expenses/%s/resit.jpg', p_org, v_entity),
          'image/jpeg', 120000)
  returning id into v_file;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged, error)
  values (p_org, v_file,
          format('%s/expenses/%s/resit.jpg', p_org, v_entity),
          'gemini', 'platform', 'failed', 0.10,
          'Nothing was read. Gemini refused the document.')
  returning id into v_scan;
  return v_scan;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. Every call, in order, with its own answer
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_scan uuid;
  v_n    integer;
  v_row  record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org  := pg_temp.test_org('Sinar Teknologi Sdn Bhd');
  v_scan := pg_temp.a_scan(v_org);
  perform pg_temp.make_platform_admin(pg_temp.test_user());

  -- The shape the edge function sends: the first attempt, the retry
  -- `459d3716` makes inside one invocation, and `0679`'s fallback to a
  -- different vendor.
  v_n := public.ocr_record_exchanges(v_scan, jsonb_build_array(
    jsonb_build_object(
      'provider', 'gemini',
      'endpoint', 'https://generativelanguage.googleapis.com/v1beta/models/x',
      'status', 503, 'ms', 812, 'ok', false,
      'body', '{"error":{"message":"This model is currently experiencing high demand."}}',
      'truncated', false),
    jsonb_build_object(
      'provider', 'gemini',
      'endpoint', 'https://generativelanguage.googleapis.com/v1beta/models/x',
      'status', 503, 'ms', 640, 'ok', false,
      'body', '{"error":{"message":"This model is currently experiencing high demand."}}',
      'truncated', false),
    jsonb_build_object(
      'provider', 'claude',
      'endpoint', 'https://api.anthropic.com/v1/messages',
      'status', 200, 'ms', 2100, 'ok', true,
      'body', '{"content":[{"type":"text","text":"99 Speedmart"}]}',
      'truncated', false)));
  perform pg_temp.check_eq('three calls are three rows', v_n, 3);

  perform pg_temp.check_eq('and the console sees all three',
    (select count(*) from public.platform_scan_exchanges(v_scan)), 3);

  -- IN ORDER, which the console draws in the order it is handed. A
  -- mutant that reversed the sort survived the first sweep, because
  -- every assertion below picks its row by attempt number and none of
  -- them cared what came first.
  perform pg_temp.check_eq('the first row is the first call',
    (select attempt from public.platform_scan_exchanges(v_scan) limit 1), 1);
  perform pg_temp.check_eq('and the last is the last',
    (select attempt from public.platform_scan_exchanges(v_scan)
      offset 2 limit 1), 3);

  -- The order IS the point: which one answered what.
  select * into v_row from public.platform_scan_exchanges(v_scan)
   where attempt = 1;
  perform pg_temp.check_eq('the first call was the chosen reader',
    v_row.provider, 'gemini');
  perform pg_temp.check_eq('and it refused', v_row.http_status, 503);
  perform pg_temp.check_true('with the vendor''s own words, raw',
    v_row.body like '%experiencing high demand%');

  select * into v_row from public.platform_scan_exchanges(v_scan)
   where attempt = 3;
  perform pg_temp.check_eq('the third was the fallback',
    v_row.provider, 'claude');
  perform pg_temp.check_true('and it read the document', v_row.ok);
  perform pg_temp.check_true('with the reply kept whole',
    v_row.body like '%99 Speedmart%');

  -- Nothing answering at all is a different fault from answering no,
  -- and the console could not tell them apart before this.
  perform public.ocr_record_exchanges(v_scan, jsonb_build_array(
    jsonb_build_object('provider', 'gemini', 'endpoint', 'https://x.test/v1',
                       'status', 0, 'ms', 30000, 'ok', false,
                       'body', 'TypeError: error sending request')));
  perform pg_temp.check_eq('a call nothing answered is still a row',
    (select count(*) from public.platform_scan_exchanges(v_scan)
      where http_status = 0), 1);

  raise notice 'scan exchanges: every call is a row, in order';
end $$;

-- ---------------------------------------------------------------------
-- 2. The tenant cannot read it
-- ---------------------------------------------------------------------
--
-- The assertion this file exists for. A company can read its own
-- `ocr_scans`; it must not be able to read what the vendor said about
-- the document, on any road.
do $$
declare
  v_org  uuid;
  v_scan uuid;
  v_them uuid;
  v_role text;
  v_seen integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org  := pg_temp.test_org('Tiada Akses Sdn Bhd');
  v_scan := pg_temp.a_scan(v_org);
  perform pg_temp.make_platform_admin(pg_temp.test_user());
  perform public.ocr_record_exchanges(v_scan, jsonb_build_array(
    jsonb_build_object('provider', 'gemini', 'endpoint', 'https://x.test/v1',
                       'status', 401, 'ok', false,
                       'body', 'project iakauntan-prod processor 7f3a')));

  -- The OWNER of the scan, signed in, not a platform administrator.
  v_them := pg_temp.another_user('bukan-admin@contoh.my');
  perform pg_temp.sign_in_as(v_them);

  perform pg_temp.check_eq('a member of the company sees no rows',
    (select count(*) from public.platform_scan_exchanges(v_scan)), 0);

  -- And not through the table either. Under the role it applies to:
  -- `psql` runs as the table's OWNER, who is exempt from row level
  -- security, and the first draft of this assertion happily read 5
  -- rows and would have passed the day the policy was dropped.
  --
  -- Two ways it can be refused and both are the right answer. HERE the
  -- select is refused outright, because `run_locally.sh`'s stack grants
  -- `authenticated` nothing on a new table. On the real Supabase,
  -- whose default privileges DO grant every new table in `public` to
  -- `authenticated`, the grant exists and row level security with no
  -- policy is what returns nothing. So this accepts either, and the
  -- structural assertion below is what pins the mechanism that matters
  -- in production.
  begin
    set local role authenticated;
    v_role := current_user;
    begin
      v_seen := (select count(*) from public.ocr_exchanges);
    exception when insufficient_privilege then
      v_seen := 0;
    end;
  end;
  reset role;
  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('nor by reading the table', v_seen, 0);

  -- The mechanism itself, which the check above cannot see on a stack
  -- that refuses the select for a different reason: row level security
  -- ON, and NO policy. A policy added here later would open the table
  -- to the tenant, and that is the change this is watching for.
  perform pg_temp.check_true('row level security is on',
    (select c.relrowsecurity from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'ocr_exchanges'));
  perform pg_temp.check_eq('and no policy lets anybody in',
    (select count(*) from pg_policies
      where schemaname = 'public' and tablename = 'ocr_exchanges'), 0);

  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_eq('while the platform still sees it',
    (select count(*) from public.platform_scan_exchanges(v_scan)), 1);
end $$;

-- ---------------------------------------------------------------------
-- 3. A scan that has gone is not an error
-- ---------------------------------------------------------------------
--
-- This is a log written AFTER the work: the reading is done, the charge
-- is settled, the caller is holding an answer. Losing the note must not
-- turn any of that into a failed function.
do $$
declare
  v_org  uuid;
  v_scan uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_eq('a scan that no longer exists records nothing',
    public.ocr_record_exchanges(gen_random_uuid(), jsonb_build_array(
      jsonb_build_object('status', 200, 'body', 'x'))), 0);

  -- Against a REAL scan, which is the only way this reaches the array
  -- at all. Asked of a random uuid it returned 0 for the other reason
  -- and a mutant that dropped the shape check survived the first sweep.
  v_org  := pg_temp.test_org('Bentuk Salah Sdn Bhd');
  v_scan := pg_temp.a_scan(v_org);
  perform pg_temp.make_platform_admin(pg_temp.test_user());
  perform pg_temp.check_eq('and neither does a body that is not an array',
    public.ocr_record_exchanges(v_scan, '{"a":1}'::jsonb), 0);
  perform pg_temp.check_eq('nor is anything left behind by trying',
    (select count(*) from public.platform_scan_exchanges(v_scan)), 0);
end $$;

-- ---------------------------------------------------------------------
-- 4. And it is thrown away again
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_scan uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org  := pg_temp.test_org('Buang Lama Sdn Bhd');
  v_scan := pg_temp.a_scan(v_org);
  perform pg_temp.make_platform_admin(pg_temp.test_user());
  perform public.ocr_record_exchanges(v_scan, jsonb_build_array(
    jsonb_build_object('status', 200, 'ok', true, 'body', 'recent')));

  -- One from long enough ago to be past any sensible window.
  update public.ocr_exchanges
     set at = now() - interval '90 days'
   where scan_id = v_scan;
  perform public.ocr_record_exchanges(v_scan, jsonb_build_array(
    jsonb_build_object('status', 200, 'ok', true, 'body', 'today')));

  perform pg_temp.check_eq('the purge drops the old one',
    app.purge_ocr_exchanges(30), 1);
  perform pg_temp.check_eq('and keeps the recent one',
    (select count(*) from public.platform_scan_exchanges(v_scan)), 1);
  perform pg_temp.check_true('which is the one from today',
    (select body = 'today' from public.platform_scan_exchanges(v_scan)));
end $$;

rollback;
