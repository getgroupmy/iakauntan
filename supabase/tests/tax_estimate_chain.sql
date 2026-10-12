-- =====================================================================
-- iAkauntan :: a revision leaves the estimate it replaced (0827)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tax_estimate_chain.sql
--
-- Each CP204 instalment is payable at whatever the estimate in force on
-- its due date said, so the estimate a revision replaced is still the
-- record of what was payable before it. Before `0827` a client could
-- rewrite it: RM120,000 revised to RM240,000 in the ninth month, and
-- the original set to RM0 by hand put instalments one to seven at RM0.
-- The form, the revision month and the rest of what opening and
-- revising decide were the client's too. Asked as the owner, with the
-- role `authenticated`.
--
-- The basis period is the calendar year today is in, and the revision
-- month is pinned by the session, as `tax_estimate_revision_spread.sql`
-- does: nothing here asserts a date, only what is payable.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_te (org uuid, fy uuid, est uuid, rev uuid, rev2 uuid);
grant select, update on t_te to authenticated;

do $$
declare
  r t_te;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Anggaran Kekal Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  select id into r.fy from public.fiscal_years
   where org_id = r.org and pg_temp.today() between start_date and end_date;
  -- RM120,000, revised to RM240,000 in the ninth month, RM10,000 paid
  -- on the first instalment.
  r.est := public.open_tax_estimate(r.org, r.fy, 120000);
  r.rev := public.revise_tax_estimate(r.est, 240000);
  update public.tax_estimates set revision_month = 9 where id = r.rev;
  perform public.record_tax_instalment(r.est, 1, null, 10000);
  insert into t_te select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d t_te;
  r record;
begin
  select * into d from t_te;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  perform pg_temp.check_eq('seven instalments of RM10,000 and five of RM34,000',
    (select string_agg(amount::text, ',' order by instalment_no)
       from public.tax_estimate_schedule(d.rev)),
    '10000.00,10000.00,10000.00,10000.00,10000.00,10000.00,10000.00,'
    '34000.00,34000.00,34000.00,34000.00,34000.00');

  -- What was measured: the estimate the revision replaced, rewritten.
  perform pg_temp.check_refused('the replaced estimate is not rewritten to RM0',
    format('update public.tax_estimates set estimated_tax = 0 where id = %L', d.est),
    'This CP204 for year of assessment % was replaced by a revision%', '42501');
  -- Nor anything else on it, nor set live again.
  perform pg_temp.check_refused('nor its prior year''s figure',
    format('update public.tax_estimates set prior_estimate = 1 where id = %L', d.est),
    'This CP204 for year of assessment % was replaced by a revision%', '42501');
  perform pg_temp.check_refused('nor is it set live again',
    format($q$update public.tax_estimates set status = 'draft' where id = %L$q$, d.est),
    'This CP204 for year of assessment % was replaced by a revision%', '42501');

  -- What opening and revising decide, each on its own, on the live one.
  -- The trigger answers before a foreign key or a check does, so any
  -- value will do.
  for r in select * from (values
      ('org_id', 'gen_random_uuid()'),
      ('fiscal_year_id', 'gen_random_uuid()'),
      ('year_of_assessment', '2031'),
      ('form', '''CP500'''),
      ('revises_id', 'null'),
      ('revision_month', '2'),
      ('status', '''submitted'''),
      ('created_by', 'gen_random_uuid()'))
      as t(col, val)
  loop
    perform pg_temp.check_refused(format('the revision''s %s is not typed', r.col),
      format('update public.tax_estimates set %s = %s where id = %L', r.col, r.val, d.rev),
      format('The %s of this CP204 for year of assessment %% is set when it is opened or revised, not by hand.', r.col),
      '42501');
  end loop;

  -- Nor made or taken away by hand.
  perform pg_temp.check_refused('an estimate is not inserted by hand',
    format($q$insert into public.tax_estimates
                (org_id, fiscal_year_id, year_of_assessment, form, estimated_tax, status)
              values (%L, %L, 2031, 'CP500', 5, 'superseded')$q$, d.org, d.fy),
    'permission denied for table tax_estimates', '42501');
  perform pg_temp.check_refused('nor deleted',
    format('delete from public.tax_estimates where id = %L', d.rev),
    'permission denied for table tax_estimates', '42501');

  -- So what was payable before the revision is what it was.
  perform pg_temp.check_eq('so instalments one to seven are still RM10,000 each, RM240,000 in all',
    (select sum(amount) filter (where instalment_no <= 7) || '/' || sum(amount)
       from public.tax_estimate_schedule(d.rev)), '70000.00/240000.00');
  perform pg_temp.check_eq('and the RM10,000 paid is against RM10,000 due',
    (select amount || '/' || paid_amount || '/' || outstanding
       from public.tax_estimate_schedule(d.rev) where instalment_no = 1),
    '10000.00/10000.00/0.00');

  -- The dialog's six fields, on the live one, as before.
  update public.tax_estimates
     set estimated_tax = 250000, prior_estimate = 100000, first_period = true,
         commenced_on = date_trunc('year', pg_temp.today())::date,
         paid_up_capital = 500000, gross_business_income = 1000000,
         notes = 'Per the board, 3 October'
   where id = d.rev;
  perform pg_temp.check_eq('the dialog still changes the live estimate',
    (select estimated_tax || '/' || prior_estimate || '/' || first_period || '/'
            || paid_up_capital || '/' || gross_business_income
       from public.tax_estimates where id = d.rev),
    '250000.00/100000.00/true/500000.00/1000000.00');

  -- And revising is still revising: the function supersedes the live
  -- one and makes the next, and opening the year hands that one back.
  d.rev2 := public.revise_tax_estimate(d.rev, 300000);
  update t_te set rev2 = d.rev2;
  perform pg_temp.check_eq('revised again through the function',
    (select o.status || '/' || (n.revises_id = o.id) || '/' || n.estimated_tax
       from public.tax_estimates o, public.tax_estimates n
      where o.id = d.rev and n.id = d.rev2), 'superseded/true/300000.00');
  perform pg_temp.check_true('and opening the year hands back the newest',
    public.open_tax_estimate(d.org, d.fy) = d.rev2);
end $$;

reset role;

-- The database itself, as the owner, is not a client.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives as
-- an equivalent one: `open_tax_estimate` and `revise_tax_estimate`, the
-- only writers of the table, are definers, which run as the owner at
-- any depth. It is kept for the first trigger that writes an estimate on
-- a client's behalf.
do $$
declare d t_te;
begin
  select * into d from t_te;
  update public.tax_estimates set notes = 'Corrected by the platform' where id = d.est;
  perform pg_temp.check_eq('the owner, at the top, is not refused',
    (select notes from public.tax_estimates where id = d.est), 'Corrected by the platform');

  perform pg_temp.check_eq('no insert or delete policy is left on the estimates',
    (select count(*)::integer from pg_policies
      where schemaname = 'public' and tablename = 'tax_estimates'
        and cmd in ('INSERT', 'DELETE', 'ALL')), 0);
end $$;

rollback;
