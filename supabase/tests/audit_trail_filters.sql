-- =====================================================================
-- iAkauntan :: the trail you can actually search
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/audit_trail_filters.sql
--
-- `0634`. The change history is capped at 500 rows newest first, so
-- "who changed the bank details in March" was unanswerable once five
-- hundred things had happened since. Two filters fix it, and four
-- things have to hold:
--
--   * **the person filter means a person.** `audit_logs.user_id` is
--     null for the database's own writes, and asking for somebody must
--     not return the rows nobody did.
--   * **the day is a Malaysian day.** `created_at` is `timestamptz`,
--     and comparing it in the server's zone answers about a different
--     day — which is what `malaysian_clock.sql` exists to catch.
--   * **`p_to` includes its own day**, because "to the 3rd" said by a
--     person includes the 3rd.
--   * **the filters do not widen who may read it.** It is still owner
--     or admin, and still a read that writes.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A row in the trail, dated and attributed exactly.
--
-- `pg_temp.test_org` seeds a chart of accounts, and every one of those
-- inserts writes its own `audit_logs` row -- around a hundred of them
-- before this file has done anything. So every count here is SCOPED to
-- a table name the seed never writes, and the fixture defaults to one.
-- A count of "everything" in this file would have been a count of the
-- seed.
create or replace function pg_temp.trail_row(
  p_org uuid, p_table text, p_actor uuid, p_at timestamptz)
returns bigint language plpgsql as $$
declare v_id bigint;
begin
  insert into public.audit_logs
    (org_id, user_id, action, table_name, record_id, old_data, new_data,
     created_at)
  values (p_org, p_actor, 'update', p_table, gen_random_uuid(),
          '{"a": 1}'::jsonb, '{"a": 2}'::jsonb, p_at)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. By person, and the database is not a person
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Jejak Audit Sdn Bhd');
  v_me    uuid := pg_temp.test_user();
  v_other uuid := pg_temp.another_user('other@iakauntan.test');
begin
  insert into public.profiles (id, email, full_name)
  values (v_other, 'other@iakauntan.test', 'Siti Rahman')
  on conflict (id) do update set full_name = excluded.full_name;
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_other, 'admin');

  perform pg_temp.trail_row(v_org, 'bank_accounts', v_me,
                            timestamptz '2026-03-02 10:00+08');
  perform pg_temp.trail_row(v_org, 'bank_accounts', v_other,
                            timestamptz '2026-03-02 11:00+08');
  -- The database's own write. It has no user.
  perform pg_temp.trail_row(v_org, 'bank_accounts', null,
                            timestamptz '2026-03-02 12:00+08');

  perform pg_temp.check_eq('all three are there without a person filter',
    (select count(*) from public.audit_trail(
       v_org, 'bank_accounts')), 3);

  perform pg_temp.check_eq('one person''s changes are theirs alone',
    (select count(*) from public.audit_trail(
       v_org, 'bank_accounts', null, 100, v_other)), 1);
  perform pg_temp.check_eq('and the name comes back with them',
    (select actor from public.audit_trail(
       v_org, 'bank_accounts', null, 100, v_other)), 'Siti Rahman');

  -- The one that `is not distinct from` would get wrong: asking for a
  -- PERSON must not hand back the rows nobody did.
  perform pg_temp.check_eq(
    'asking for a person does not return the database''s own writes',
    (select count(*) from public.audit_trail(
       v_org, 'bank_accounts', null, 100, v_me)), 1);
  perform pg_temp.check_eq('and a stranger''s changes are none',
    (select count(*) from public.audit_trail(
       v_org, 'bank_accounts', null, 100, gen_random_uuid())), 0);

  -- And the filter composes with the one that was already there: this
  -- person changed a bank account and never touched a tax code.
  perform pg_temp.check_eq('the person and the table together',
    (select count(*) from public.audit_trail(
       v_org, 'tax_codes', null, 100, v_other)), 0);
end $$;

-- ---------------------------------------------------------------------
-- 2. The day is a Malaysian day
-- ---------------------------------------------------------------------
-- 16:30 UTC on the 2nd is half past midnight on the 3rd in Kuala
-- Lumpur. Somebody asking for the 3rd means the Malaysian 3rd, and a
-- comparison in the server's zone answers about a different day.
do $$
declare
  v_org uuid := pg_temp.test_org('Waktu Malaysia Sdn Bhd');
  v_me  uuid := pg_temp.test_user();
begin
  perform pg_temp.trail_row(v_org, 'bank_accounts', v_me,
                            timestamptz '2026-03-02 16:30+00');

  perform pg_temp.check_eq('it is on the Malaysian 3rd',
    (select count(*) from public.audit_trail(
       v_org, 'bank_accounts', null, 100, null, date '2026-03-03', date '2026-03-03')),
    1);
  perform pg_temp.check_eq('and not on the 2nd',
    (select count(*) from public.audit_trail(
       v_org, 'bank_accounts', null, 100, null, date '2026-03-02', date '2026-03-02')),
    0);
end $$;

-- ---------------------------------------------------------------------
-- 3. A range, with both ends inclusive
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Julat Tarikh Sdn Bhd');
  v_me  uuid := pg_temp.test_user();
begin
  perform pg_temp.trail_row(v_org, 'bank_accounts', v_me,
                            timestamptz '2026-03-01 09:00+08');
  perform pg_temp.trail_row(v_org, 'bank_accounts', v_me,
                            timestamptz '2026-03-02 09:00+08');
  -- Late on the last day of the range. The end of a range said by a
  -- person includes the whole of that day.
  perform pg_temp.trail_row(v_org, 'bank_accounts', v_me,
                            timestamptz '2026-03-03 23:45+08');
  perform pg_temp.trail_row(v_org, 'bank_accounts', v_me,
                            timestamptz '2026-03-04 09:00+08');

  perform pg_temp.check_eq('a range takes both its ends',
    (select count(*) from public.audit_trail(
       v_org, 'bank_accounts', null, 100, null, date '2026-03-01', date '2026-03-03')),
    3);
  perform pg_temp.check_eq('an open end runs to the present',
    (select count(*) from public.audit_trail(
       v_org, 'bank_accounts', null, 100, null, date '2026-03-02')), 3);
  perform pg_temp.check_eq('an open start runs from the beginning',
    (select count(*) from public.audit_trail(
       v_org, 'bank_accounts', null, 100, null, null, date '2026-03-02')), 2);
  perform pg_temp.check_eq('and one day is one day',
    (select count(*) from public.audit_trail(
       v_org, 'bank_accounts', null, 100, null, date '2026-03-02', date '2026-03-02')),
    1);
end $$;

-- ---------------------------------------------------------------------
-- 4. Who there is to filter by
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Senarai Nama Sdn Bhd');
  v_me    uuid := pg_temp.test_user();
  v_other uuid := pg_temp.another_user('busy@iakauntan.test');
begin
  insert into public.profiles (id, email, full_name)
  values (v_other, 'busy@iakauntan.test', 'Ahmad Busy')
  on conflict (id) do update set full_name = excluded.full_name;
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_other, 'admin');

  perform pg_temp.trail_row(v_org, 'bank_accounts', v_me,
                            timestamptz '2026-03-02 09:00+08');
  perform pg_temp.trail_row(v_org, 'bank_accounts', v_other,
                            timestamptz '2026-03-02 10:00+08');
  perform pg_temp.trail_row(v_org, 'bank_accounts', v_other,
                            timestamptz '2026-03-02 11:00+08');
  perform pg_temp.trail_row(v_org, 'bank_accounts', null,
                            timestamptz '2026-03-02 12:00+08');

  -- Two people, and the database is not one of them. The fixture user
  -- also carries the chart seed's hundred-odd rows, so the COUNTS here
  -- are the seed's as well as this file's -- which is why what is
  -- asserted is who appears and in what order, not how many rows each
  -- has.
  perform pg_temp.check_eq('the list is of people, not of the database',
    (select count(*) from public.audit_trail_actors(v_org)), 2);
  perform pg_temp.check_eq('and the second person is on it by name',
    (select name from public.audit_trail_actors(v_org)
      where user_id = v_other), 'Ahmad Busy');
  perform pg_temp.check_eq('with how often they appear',
    (select entries from public.audit_trail_actors(v_org)
      where user_id = v_other), 2::bigint);
  -- Busiest first, which is what makes the list useful when it is
  -- long. `row_number() over ()` with no ORDER BY reads the order the
  -- FUNCTION emitted -- the first spelling of this sorted inside its
  -- own window and so asserted nothing about the function at all,
  -- which the mutation sweep said by leaving `order by 2` alive.
  perform pg_temp.check_true('busiest first',
    (select bool_and(entries >= coalesce(next_entries, entries))
       from (select entries,
                    lead(entries) over (order by rn) as next_entries
               from (select entries, row_number() over () as rn
                       from public.audit_trail_actors(v_org)) a) b));

  -- Drawing a dropdown is not a sensitive read. Recording one would
  -- fill the security log with events nobody caused.
  perform pg_temp.check_eq(
    'and listing the names records no sensitive read',
    (select count(*) from public.security_events
      where org_id = v_org and kind = 'sensitive_read'), 0);
  -- While reading the trail itself does, which is what 0583 put it on
  -- the undocumented-writes list for.
  perform public.audit_trail(v_org);
  perform pg_temp.check_true('but reading the trail does',
    (select count(*) from public.security_events
      where org_id = v_org and kind = 'sensitive_read') > 0);
end $$;

-- ---------------------------------------------------------------------
-- 5. The filters do not widen who may read it
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Kebenaran Jejak Sdn Bhd');
  v_clerk uuid := pg_temp.another_user('clerk3@iakauntan.test');
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'accountant');
  perform pg_temp.sign_in_as(v_clerk);

  perform pg_temp.check_refused(
    'an accountant may not read the change history',
    format('select public.audit_trail(%L, null, null, 100, null, %L, %L)',
           v_org, date '2026-03-01', date '2026-03-31'),
    '%Only an owner or admin%', '42501');
  perform pg_temp.check_refused(
    'nor the list of who is in it',
    format('select public.audit_trail_actors(%L)', v_org),
    '%Only an owner or admin%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- 6. The old four-argument call still works
-- ---------------------------------------------------------------------
-- Every existing caller passes four arguments. The new parameters
-- default to null, so the signature change is invisible to them --
-- which is the whole reason the old form was dropped rather than
-- overloaded, since a four-argument call matching two functions is
-- refused as ambiguous.
do $$
declare
  v_org uuid := pg_temp.test_org('Panggilan Lama Sdn Bhd');
  v_me  uuid := pg_temp.test_user();
begin
  perform pg_temp.trail_row(v_org, 'bank_accounts', v_me,
                            timestamptz '2026-03-02 09:00+08');
  perform pg_temp.check_eq('four arguments still answer',
    (select count(*) from public.audit_trail(v_org, 'bank_accounts', null, 100)), 1);
  perform pg_temp.check_true('and one argument still answers at all',
    (select count(*) from public.audit_trail(v_org)) > 0);

  -- And there is exactly one of it, which is what makes the above
  -- unambiguous rather than lucky.
  perform pg_temp.check_eq('there is one audit_trail, not two',
    (select count(*) from pg_proc p join pg_namespace n
       on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'audit_trail'), 1);
end $$;

rollback;
