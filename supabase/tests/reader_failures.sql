-- =====================================================================
-- iAkauntan :: what a reader keeps saying
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/reader_failures.sql
--
-- `0685`. The scan log answers "what happened to THIS scan". This
-- answers the one nobody could ask: does this reader ever work.
--
-- The assertions that matter are about the NORMALISATION, because the
-- whole report is worthless without it in one direction and misleading
-- in the other:
--
--   * Group on the raw vendor text and every scan is its own group. A
--     reader that has failed identically four hundred times reads as
--     four hundred unrelated problems, which is the same as reading as
--     nothing.
--   * Normalise too hard and `HTTP 400` joins `HTTP 429`. Those are a
--     schema this code sent wrongly and a quota somebody has to go and
--     raise -- different people, different afternoons.
--
-- And the ordering: a reader that has NEVER succeeded sorts first,
-- because that is the reader somebody switched on and has been paying
-- for.
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

create or replace function pg_temp.failed_scan(
  p_org uuid, p_provider text, p_error text, p_ref text default null)
returns void language sql as $$
  insert into public.ocr_scans
    (org_id, storage_path, provider, key_source, status, error, log_ref)
  values (p_org, 'x/y/z/f.jpg', p_provider, 'platform', 'failed',
          p_error, p_ref);
$$;

create or replace function pg_temp.ok_scan(p_org uuid, p_provider text)
returns void language sql as $$
  insert into public.ocr_scans
    (org_id, storage_path, provider, key_source, status, extracted)
  values (p_org, 'x/y/z/f.jpg', p_provider, 'platform', 'ok', '{}'::jsonb);
$$;

do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org   uuid;
  v_row   record;
  v_n     integer;
begin
  perform pg_temp.make_platform_admin(v_owner);
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Reader Faults Sdn Bhd');

  -- -------------------------------------------------------------------
  -- The same fault, said four ways
  --
  -- What a vendor actually returns: one message, a different request
  -- id on every copy of it, and the payload fragment it objected to
  -- quoted back.
  -- -------------------------------------------------------------------
  perform pg_temp.failed_scan(v_org, 'gemini',
    $e$Invalid JSON payload received. Unknown name "strict" at 'response_format.json_schema': Cannot find field. [request 4f3c1a2b-9d8e-4f1a-b2c3-d4e5f6a7b8c9]$e$,
    'aaaa1111');
  perform pg_temp.failed_scan(v_org, 'gemini',
    $e$Invalid JSON payload received. Unknown name "strict" at 'response_format.json_schema': Cannot find field. [request 7a2b3c4d-1e2f-4a3b-8c9d-0e1f2a3b4c5d]$e$,
    'bbbb2222');
  perform pg_temp.failed_scan(v_org, 'gemini',
    $e$Invalid JSON payload received. Unknown name "max_completion_tokens" at 'generation_config': Cannot find field. [request 9f8e7d6c5b4a3210]$e$,
    'cccc3333');

  select count(*) into v_n
    from public.platform_reader_failures(30) where provider = 'gemini';
  perform pg_temp.check_eq(
    'two faults said three times group as two faults', v_n, 2);

  select * into v_row from public.platform_reader_failures(30)
   where provider = 'gemini' order by n desc limit 1;
  perform pg_temp.check_eq(
    'and the one that happened twice is counted twice', v_row.n, 2::bigint);
  perform pg_temp.check_true(
    'with the request id taken out of the message',
    v_row.fault not like '%4f3c1a2b%');
  perform pg_temp.check_true(
    'and the fault itself still legible',
    v_row.fault like '%unknown name%' and v_row.fault like '%strict%');
  perform pg_temp.check_true(
    'a reference is kept so the whole row can be looked up',
    v_row.example_ref in ('aaaa1111', 'bbbb2222'));

  -- -------------------------------------------------------------------
  -- Never once worked
  --
  -- The row that this function exists to put at the top. `read` is
  -- zero and `failed` is not, which is the difference between a reader
  -- with a problem and a reader that has never done anything.
  -- -------------------------------------------------------------------
  perform pg_temp.check_eq(
    'a reader that has never succeeded says so on every row of it',
    v_row.read, 0::bigint);
  perform pg_temp.check_eq(
    'beside what it did instead', v_row.failed, 3::bigint);

  -- -------------------------------------------------------------------
  -- A short number is a fact, not a reference
  --
  -- The over-normalisation that would quietly merge a rejected schema
  -- with an exhausted quota.
  -- -------------------------------------------------------------------
  perform pg_temp.failed_scan(v_org, 'openai', 'The reader refused: HTTP 400');
  perform pg_temp.failed_scan(v_org, 'openai', 'The reader refused: HTTP 429');
  select count(*) into v_n
    from public.platform_reader_failures(30) where provider = 'openai';
  perform pg_temp.check_eq(
    'HTTP 400 and HTTP 429 stay two different problems', v_n, 2);

  -- -------------------------------------------------------------------
  -- A reader that mostly works
  -- -------------------------------------------------------------------
  perform pg_temp.ok_scan(v_org, 'claude');
  perform pg_temp.ok_scan(v_org, 'claude');
  perform pg_temp.ok_scan(v_org, 'claude');
  perform pg_temp.failed_scan(v_org, 'claude',
    'The document was too long to read in one pass.');

  select * into v_row from public.platform_reader_failures(30)
   where provider = 'claude';
  perform pg_temp.check_eq(
    'a working reader carries what it read', v_row.read, 3::bigint);
  perform pg_temp.check_eq(
    'and its one bad day', v_row.failed, 1::bigint);
  perform pg_temp.check_true(
    'and is named as the console shows it, not by its code',
    v_row.provider_name = 'Claude');

  -- The reader that has never worked sorts above the one that mostly
  -- does, however loud the working one's occasional failure is.
  select provider into v_row from public.platform_reader_failures(30) limit 1;
  perform pg_temp.check_true(
    'a reader that never worked is the first thing an operator sees',
    v_row.provider = 'gemini');

  -- A scan that failed with nothing recorded is still a failure, and
  -- must not vanish from the count by grouping to null.
  perform pg_temp.failed_scan(v_org, 'grok', null);
  select * into v_row from public.platform_reader_failures(30)
   where provider = 'grok';
  perform pg_temp.check_true(
    'a failure with no message is still reported',
    v_row.fault = '(no message recorded)');
  perform pg_temp.check_eq('and counted', v_row.n, 1::bigint);

  -- Outside the window.
  update public.ocr_scans set created_at = now() - interval '400 days'
   where org_id = v_org and provider = 'grok';
  select count(*) into v_n
    from public.platform_reader_failures(30) where provider = 'grok';
  perform pg_temp.check_eq(
    'and a fault from last year is not this month''s problem', v_n, 0);
end $$;

do $$
declare
  v_other uuid := pg_temp.another_user('nobody-faults@example.com');
  v_n     integer;
begin
  perform pg_temp.sign_in_as(v_other);
  select count(*) into v_n from public.platform_reader_failures(30);
  perform pg_temp.check_eq(
    'somebody who is not a platform admin sees no faults at all', v_n, 0);
end $$;

rollback;
