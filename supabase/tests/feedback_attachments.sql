-- =====================================================================
-- iAkauntan :: files on a feedback report
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/feedback_attachments.sql
--
-- `0660` lets somebody attach a screenshot to a bug report. Everything
-- worth asserting here is about WHO CAN SEE IT, because the read rule
-- is unusual in two ways and both are easy to get wrong in the
-- direction that leaks:
--
--   1. **Platform staff read across organizations.** That is the
--      feature — a bug reported by one company is read by the people
--      who can fix it, who are in none. An access rule copied from any
--      other table in this database would refuse them.
--   2. **The report's org can be null**, because platform staff file
--      bugs too, so a rule that reaches for `org_id` has to survive it
--      being absent rather than falling through to "allow".
--
-- And one that is easy to get wrong in the direction that breaks:
-- a storage policy that CASTS the first path segment closes the whole
-- bucket the moment one badly named object exists. `0405` is that
-- story; `app.uuid_or_null` is the fix, and it is asserted here.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Who may see the files on a report
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid; v_stranger uuid; v_admin uuid; v_platform uuid;
  v_org uuid; v_other_org uuid; v_report uuid;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe Feedback Files');

  v_report := public.report_feedback(
    p_title => 'The employer EPF column is blank',
    p_kind => 'bug',
    p_org_id => v_org);

  -- The reporter, obviously.
  perform pg_temp.check_eq('the reporter may see their own files',
                           app.can_see_feedback(v_report)::text, 'true');
  perform pg_temp.check_eq('and may attach to it',
                           app.can_attach_to_feedback(v_report)::text, 'true');

  -- Somebody unrelated: not in the org, not platform staff.
  v_stranger := pg_temp.another_user('stranger@iakauntan.test');
  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_eq('a stranger may not see the files',
                           app.can_see_feedback(v_report)::text, 'false');
  perform pg_temp.check_eq('nor attach to somebody else''s report',
                           app.can_attach_to_feedback(v_report)::text, 'false');

  -- Platform staff, who are in NO organization and must still see it.
  -- This is the assertion an access rule copied from another table
  -- fails, and it fails silently: the console lists the report and
  -- cannot open the screenshot on it.
  v_platform := pg_temp.another_user('staff@iakauntan.test');
  insert into public.platform_admins (user_id) values (v_platform)
    on conflict (user_id) do nothing;
  perform pg_temp.sign_in_as(v_platform);
  perform pg_temp.check_eq('platform staff see files across orgs',
                           app.can_see_feedback(v_report)::text, 'true');
  -- But reading is not writing. An administrator adding a document
  -- under somebody else's name, to a record they cannot edit, is not
  -- something the read rule should imply.
  perform pg_temp.check_eq('and still may not attach to it',
                           app.can_attach_to_feedback(v_report)::text, 'false');
end $$;

-- ---------------------------------------------------------------------
-- A report with NO organization, which platform staff file
-- ---------------------------------------------------------------------
do $$
declare v_staff uuid; v_stranger uuid; v_report uuid;
begin
  v_staff := pg_temp.another_user('lonestaff@iakauntan.test');
  insert into public.platform_admins (user_id) values (v_staff)
    on conflict (user_id) do nothing;
  perform pg_temp.sign_in_as(v_staff);

  -- No p_org_id at all.
  v_report := public.report_feedback(
    p_title => 'The console chart draws nothing', p_kind => 'bug');

  perform pg_temp.check_eq('a report can have no org',
    (select (org_id is null)::text from public.feedback_reports
      where id = v_report),
    'true');
  perform pg_temp.check_eq('and its reporter can still see its files',
                           app.can_see_feedback(v_report)::text, 'true');

  -- The rule must not fall through to "allow" because org_id is null.
  v_stranger := pg_temp.another_user('nobody@iakauntan.test');
  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_eq('a null org does not mean everybody',
                           app.can_see_feedback(v_report)::text, 'false');
end $$;

-- ---------------------------------------------------------------------
-- A report that does not exist
-- ---------------------------------------------------------------------
do $$
declare v_user uuid;
begin
  v_user := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_user);
  -- False, not null. A null would make the storage policy's `using`
  -- clause null, which Postgres treats as "no" — right by accident
  -- today and not something to rely on.
  perform pg_temp.check_eq('an unknown report is not visible',
                           app.can_see_feedback(gen_random_uuid())::text,
                           'false');
  perform pg_temp.check_eq('and cannot be attached to',
                           app.can_attach_to_feedback(gen_random_uuid())::text,
                           'false');
  perform pg_temp.check_eq('nor is a null report id',
                           coalesce(app.can_see_feedback(null), false)::text,
                           'false');
end $$;

-- ---------------------------------------------------------------------
-- The badly named object that closed a bucket once
-- ---------------------------------------------------------------------
do $$
declare v_result boolean;
begin
  -- `0405`: a storage policy that casts `split_part(name, '/', 1)` to
  -- uuid raises on any object whose first segment is not one, and a
  -- policy that raises does not skip that row — it fails the whole
  -- query, for everybody, for every object in the bucket.
  --
  -- So the thing to assert is that the expression the policy actually
  -- uses SURVIVES the bad name rather than that it returns false.
  -- No `when others` here, deliberately. Wrapping this in a handler
  -- that re-raises "a badly named object closes the bucket" was the
  -- first version, and it is worse: the file runs under
  -- ON_ERROR_STOP, so if the expression raises the test fails ANYWAY,
  -- and it fails carrying Postgres's own message -- which names the
  -- cast and the value, where the hand-written one named neither.
  -- A blind handler would also have been the 42nd in this suite
  -- against a budget of 41, and `scripts/check_blind_catches.py` was
  -- right to stop it.
  select app.can_see_feedback(app.uuid_or_null(
           split_part('not-a-uuid/screenshot.png', '/', 1)))
    into v_result;
  perform pg_temp.check_eq('a badly named object is refused, not fatal',
                           coalesce(v_result, false)::text, 'false');

  -- And the ordinary shape still resolves to the report id.
  perform pg_temp.check_eq('a well named object names its report',
    app.uuid_or_null(split_part(
      'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11/shot.png', '/', 1))::text,
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11');
end $$;

-- ---------------------------------------------------------------------
-- Recording a file
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid; v_stranger uuid; v_org uuid; v_report uuid;
  v_id uuid; v_count integer;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe Feedback Recording');
  v_report := public.report_feedback(
    p_title => 'Something is wrong', p_org_id => v_org);

  v_id := public.attach_feedback_file(
    v_report, v_report::text || '/shot.png', 'shot.png', 4096, 'image/png');
  perform pg_temp.check_eq('a file is recorded',
                           (v_id is not null)::text, 'true');

  select count(*) into v_count
    from public.feedback_files(v_report);
  perform pg_temp.check_eq('and reads back', v_count, 1);

  -- The path has to name its own report. Without the constraint, a row
  -- could point at another report's object and the storage policy --
  -- which reads the PATH, not this row -- would allow whoever can see
  -- THAT report to read it.
  begin
    perform public.attach_feedback_file(
      v_report, gen_random_uuid()::text || '/elsewhere.png',
      'elsewhere.png', 10, 'image/png');
    raise exception 'FAIL: recorded a path belonging to another report';
  exception when sqlstate '23514' then
    raise notice 'ok   a file must live under its own report';
  end;

  -- Five, then no more.
  for i in 2 .. 5 loop
    perform public.attach_feedback_file(
      v_report, v_report::text || '/shot' || i || '.png',
      'shot' || i || '.png', 4096, 'image/png');
  end loop;
  begin
    perform public.attach_feedback_file(
      v_report, v_report::text || '/shot6.png', 'shot6.png', 4096, 'image/png');
    raise exception 'FAIL: a sixth file was accepted';
  exception when sqlstate '23514' then
    raise notice 'ok   five files is the limit';
  end;

  -- Nobody else may record against it, whatever path they claim.
  v_stranger := pg_temp.another_user('interloper@iakauntan.test');
  perform pg_temp.sign_in_as(v_stranger);
  begin
    perform public.attach_feedback_file(
      v_report, v_report::text || '/mine.png', 'mine.png', 10, 'image/png');
    raise exception 'FAIL: a stranger attached to somebody else''s report';
  exception when sqlstate '42501' then
    raise notice 'ok   only the reporter may attach';
  end;

  -- And may not read them either. `feedback_files` is SECURITY
  -- DEFINER, so without its own check it would hand every report's
  -- files to anybody who asked.
  select count(*) into v_count from public.feedback_files(v_report);
  perform pg_temp.check_eq('nor read them', v_count, 0);
end $$;

-- ---------------------------------------------------------------------
-- Sizes, and who may execute
-- ---------------------------------------------------------------------
do $$
declare v_owner uuid; v_org uuid; v_report uuid;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe Feedback Sizes');
  v_report := public.report_feedback(
    p_title => 'Sizes', p_org_id => v_org);

  -- Eleven megabytes, against a bucket that stops at ten. The row
  -- constraint exists so a client cannot record a size the object does
  -- not have -- the bucket refuses the bytes, and this refuses the
  -- claim.
  begin
    perform public.attach_feedback_file(
      v_report, v_report::text || '/huge.png', 'huge.png', 11534336);
    raise exception 'FAIL: recorded a file larger than the bucket takes';
  exception when sqlstate '23514' then
    raise notice 'ok   a file larger than the bucket is refused';
  end;

  begin
    perform public.attach_feedback_file(
      v_report, v_report::text || '/empty.png', 'empty.png', 0);
    raise exception 'FAIL: recorded an empty file';
  exception when sqlstate '23514' then
    raise notice 'ok   an empty file is refused';
  end;
end $$;

-- ---------------------------------------------------------------------
-- The grants a storage policy needs, which 0660 forgot and 0661 added
-- ---------------------------------------------------------------------
do $$
declare v_missing text;
begin
  -- `0661`: a policy on `storage.objects` whose function the client
  -- role cannot EXECUTE does not evaluate to false. It RAISES, and a
  -- raise fails the whole statement -- for every bucket on the table,
  -- not just this one. `bucket_survives_a_bad_path.sql` caught it on
  -- its `mail` assertion, which is the collateral in one line.
  --
  -- Written as a sweep rather than two named checks: any `app`
  -- function a storage policy comes to depend on later needs the same
  -- grant, and would otherwise break every bucket on the day it lands.
  select string_agg(p.proname, ', ' order by p.proname) into v_missing
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and p.proname in ('can_see_feedback', 'can_attach_to_feedback',
                       'uuid_or_null', 'is_chat_participant',
                       'can_read_attachment')
     and not has_function_privilege('authenticated', p.oid, 'execute');
  perform pg_temp.check_eq(
    'every function a storage policy calls is callable by a client',
    coalesce(v_missing, ''), '');

  -- And the other direction, which is the `public` half of the same
  -- asymmetry: these answer questions about the caller, so `anon`
  -- must not be able to ask them.
  perform pg_temp.check_eq('anon cannot ask who may see a report',
    has_function_privilege('anon', 'app.can_see_feedback(uuid)',
                           'execute')::text,
    'false');
end $$;

do $$
begin
  if has_function_privilege('anon',
       'public.attach_feedback_file(uuid, text, text, integer, text)',
       'execute') then
    raise exception 'FAIL: anon can attach a file to a feedback report';
  end if;
  raise notice 'ok   anon cannot attach';

  if has_function_privilege('anon', 'public.feedback_files(uuid)',
                            'execute') then
    raise exception 'FAIL: anon can read feedback files';
  end if;
  raise notice 'ok   anon cannot read the file list';

  if not has_function_privilege('authenticated',
       'public.attach_feedback_file(uuid, text, text, integer, text)',
       'execute') then
    raise exception 'FAIL: nobody signed in can attach';
  end if;
  raise notice 'ok   a signed-in user may, subject to the guard';
end $$;

rollback;
