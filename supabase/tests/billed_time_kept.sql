-- =====================================================================
-- iAkauntan :: billed time is kept as it was billed (0825)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/billed_time_kept.sql
--
-- `bill_project_time` puts unbilled time on an invoice and marks it
-- billed, and the next run reads that mark to know what has gone out.
-- Before `0825` a client could write it: two hours billed for RM600,
-- raised to eight by hand, marked unbilled, and billed again for
-- RM2,400 -- the customer invoiced twice for one day. Asked as the
-- owner, with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_bt (org uuid, u uuid, p1 uuid, p2 uuid, te uuid, inv uuid);
grant select, update on t_bt to authenticated;

do $$
declare
  r   t_bt;
  v_c uuid;
begin
  r.u := pg_temp.test_user();
  perform pg_temp.sign_in_as(r.u);
  r.org := pg_temp.test_org('Masa Dibil Sdn Bhd');
  perform public.create_fiscal_year(r.org, date '2026-01-01');
  perform pg_temp.open_years(r.org, date '2026-01-01');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Klien', 'customer') returning id into v_c;
  insert into public.projects (org_id, code, name, contact_id)
  values (r.org, 'P-1', 'Projek', v_c) returning id into r.p1;
  insert into public.projects (org_id, code, name, contact_id)
  values (r.org, 'P-2', 'Projek lain', v_c) returning id into r.p2;
  insert into t_bt select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d t_bt;
  r record;
begin
  select * into d from t_bt;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- Logged as the timesheet logs it, and corrected while unbilled.
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, is_billable)
  values (d.org, d.p1, d.u, date '2026-03-10', 'Build', 150, 300, true)
  returning id into d.te;
  update t_bt set te = d.te;
  update public.time_entries set minutes = 120 where id = d.te;
  perform pg_temp.check_eq('unbilled time is corrected as before: two hours, RM600',
    (select minutes || '/' || amount || '/' || is_billed from public.time_entries where id = d.te),
    '120/600.00/false');

  -- Its billed mark is the billing's, either way.
  perform pg_temp.check_refused('unbilled time is not marked billed by hand',
    format('update public.time_entries set is_billed = true where id = %L', d.te),
    'Time becomes billed by billing it%', '42501');
  perform pg_temp.check_refused('nor put on an invoice by hand',
    format('update public.time_entries set invoice_id = gen_random_uuid() where id = %L', d.te),
    'Time becomes billed by billing it%', '42501');
  perform pg_temp.check_refused('nor logged already billed',
    format($q$insert into public.time_entries
                (org_id, project_id, user_id, entry_date, description, minutes,
                 hourly_rate, is_billable, is_billed)
              values (%L, %L, %L, date '2026-03-11', 'Ghost', 60, 300, true, true)$q$,
           d.org, d.p1, d.u),
    'Time is logged unbilled.%', '42501');
  perform pg_temp.check_refused('nor logged on an invoice',
    format($q$insert into public.time_entries
                (org_id, project_id, user_id, entry_date, description, minutes,
                 hourly_rate, is_billable, invoice_id)
              values (%L, %L, %L, date '2026-03-11', 'Ghost', 60, 300, true, gen_random_uuid())$q$,
           d.org, d.p1, d.u),
    'Time is logged unbilled.%', '42501');

  -- Billed by billing it.
  d.inv := public.bill_project_time(d.p1, date '2026-03-01', date '2026-03-31', null);
  update t_bt set inv = d.inv;
  perform pg_temp.check_eq('billed on an invoice for RM600',
    (select t.is_billed || '/' || s.total_amount
       from public.time_entries t join public.sales_documents s on s.id = t.invoice_id
      where t.id = d.te and s.id = d.inv), 'true/600.00');

  -- What was measured: the mark cleared, to bill it again.
  perform pg_temp.check_refused('billed time is not marked unbilled by hand',
    format('update public.time_entries set is_billed = false, invoice_id = null where id = %L', d.te),
    'Time becomes billed by billing it%', '42501');
  perform pg_temp.check_refused('nor taken off its invoice alone',
    format('update public.time_entries set invoice_id = null where id = %L', d.te),
    'Time becomes billed by billing it%', '42501');
  perform pg_temp.check_refused('nor deleted',
    format('delete from public.time_entries where id = %L', d.te),
    'Time of 120 minutes on 2026-03-10 has been billed%', '42501');

  -- Nor what the invoice was built from, each on its own.
  for r in select * from (values
      ('org_id', 'gen_random_uuid()'),
      ('user_id', 'gen_random_uuid()'),
      ('project_id', format('%L::uuid', d.p2)),
      ('matter_id', 'gen_random_uuid()'),
      ('entry_date', 'date ''2026-03-12'''),
      ('minutes', '480'),
      ('hourly_rate', '500'),
      ('is_billable', 'false'))
      as t(col, val)
  loop
    perform pg_temp.check_refused(format('nor its %s', r.col),
      format('update public.time_entries set %s = %s where id = %L', r.col, r.val, d.te),
      format('Time of 120 minutes on 2026-03-10 has been billed, and its %s is what the invoice was built from.%%', r.col),
      '42501');
  end loop;

  -- An amount typed in never reaches the row: it is the minutes times
  -- the rate, which is why the guard does not need to ask it.
  update public.time_entries set amount = 1 where id = d.te;
  perform pg_temp.check_eq('an amount typed in is worked out again from the hours',
    (select amount from public.time_entries where id = d.te), 600::numeric);

  -- What can still be put right.
  update public.time_entries
     set description = 'Build: the second floor', activity_code = 'DEV'
   where id = d.te;
  perform pg_temp.check_eq('its description and activity can still be put right',
    (select description || '/' || activity_code from public.time_entries where id = d.te),
    'Build: the second floor/DEV');

  -- So the project has one invoice, and nothing left to bill twice.
  perform pg_temp.check_eq('so the day is invoiced once',
    (select count(*)::integer from public.sales_documents
      where org_id = d.org and doc_type = 'invoice'), 1);

  -- Unbilled time is deleted as before.
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, is_billable)
  values (d.org, d.p2, d.u, date '2026-03-12', 'Typo', 30, 300, true);
  delete from public.time_entries where org_id = d.org and description = 'Typo';
  perform pg_temp.check_eq('unbilled time is deleted as before',
    (select count(*)::integer from public.time_entries where org_id = d.org and description = 'Typo'), 0);
end $$;

reset role;

-- The database itself, as the owner, is not a client.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives as
-- an equivalent one: the billing functions and `close_project`, the only
-- writers of `time_entries` beside the app, are definers, which run as
-- the owner at any depth. It is kept for the first trigger that writes
-- time on a client's behalf.
do $$
declare d t_bt;
begin
  select * into d from t_bt;
  update public.time_entries set activity_code = 'OWNER', is_billable = is_billable
   where id = d.te;
  update public.time_entries set minutes = 90 where id = d.te;
  perform pg_temp.check_eq('the owner, at the top, is not refused',
    (select minutes from public.time_entries where id = d.te), 90);
end $$;

rollback;
