-- =====================================================================
-- iAkauntan :: a filed statement's figures are the ledger's (0864)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fs_figures_withheld.sql
--
-- `fs_export` refuses a member who does not read the ledger (`0855`),
-- and answers a frozen filing from `fs_figures` -- which every member
-- with the MBRS add-on read for themselves. Asked with the role
-- `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_fs (org uuid, other uuid, sales uuid, viewer uuid,
  auditor uuid, filing uuid, other_filing uuid);
grant select on t_fs to authenticated;

-- A year of books with one journal in it, frozen into a filing.
create or replace function pg_temp.frozen_year(p_org uuid, p_amount numeric)
returns uuid language plpgsql as $$
declare v_fy uuid; a_exp uuid; a_eq uuid; v_filing uuid;
begin
  perform pg_temp.open_years(p_org, date_trunc('year', pg_temp.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (p_org, 'mbrs', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  select id into a_exp from public.accounts where org_id = p_org and not is_group
     and account_type = 'expense' order by code limit 1;
  select id into a_eq from public.accounts where org_id = p_org and not is_group
     and account_type = 'equity' order by code limit 1;
  perform public.post_manual_journal(p_org, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('account_id', a_exp, 'debit', p_amount, 'credit', 0),
      jsonb_build_object('account_id', a_eq, 'debit', 0, 'credit', p_amount)),
    'Directors'' remuneration');
  select id into v_fy from public.fiscal_years
   where org_id = p_org and pg_temp.today() between start_date and end_date;
  insert into public.fs_filings (org_id, fy_start, fy_end, audit_status, employee_count)
  select p_org, start_date, end_date, 'unaudited', 3
    from public.fiscal_years where id = v_fy
  returning id into v_filing;
  perform public.fs_freeze(v_filing);
  return v_filing;
end $$;

do $$
declare r t_fs;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Penyata Terhad Sdn Bhd');
  r.other := pg_temp.test_org('Penyata Lain Sdn Bhd');
  r.sales   := pg_temp.another_user('sales@penyata.test');
  r.viewer  := pg_temp.another_user('viewer@penyata.test');
  r.auditor := pg_temp.another_user('auditor@penyata.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.sales, 'sales', 'active'), (r.org, r.viewer, 'viewer', 'active'),
         (r.org, r.auditor, 'auditor', 'active');
  r.filing := pg_temp.frozen_year(r.org, 4321.09);
  r.other_filing := pg_temp.frozen_year(r.other, 555);
  insert into t_fs select r.*;
end $$;

-- What is withheld is the figures, and the add-on is not what withholds
-- them: the same reader is let through the module gate and sees the
-- filing itself.
create or replace function pg_temp.figures_withheld(p_who text)
returns void language plpgsql as $$
declare d t_fs;
begin
  select * into d from t_fs;
  perform pg_temp.check_true(p_who || ': the premise -- a member past the MBRS gate who does not read the ledger',
    app.is_org_member(d.org) and app.can_read_module(d.org, 'mbrs')
    and not app.can_read_ledger(d.org));
  perform pg_temp.check_eq(p_who || ': reads the filing, and that it is frozen',
    (select status::text from public.fs_filings where id = d.filing), 'frozen');
  perform pg_temp.check_eq(p_who || ': reads none of its figures',
    (select count(*) from public.fs_figures where filing_id = d.filing)::int, 0);
end $$;

select pg_temp.sign_in_as((select sales from t_fs));
set local role authenticated;
select pg_temp.figures_withheld('the salesman');
reset role;

select pg_temp.sign_in_as((select viewer from t_fs));
set local role authenticated;
select pg_temp.figures_withheld('the viewer');
reset role;

-- The auditor reads the ledger and posts nothing: the role the filing
-- is most for.
--
-- Not asserted here, because the MBRS module gate answers them before
-- this policy is asked: a suspended accountant, and a reader of another
-- company. The gate asks for a current member, so both read nothing
-- whatever `fs_figures_select` says -- and a mutant of the policy that
-- let either in survived, which is how that was found.
select pg_temp.sign_in_as((select auditor from t_fs));
set local role authenticated;

do $$
declare d t_fs;
begin
  select * into d from t_fs;
  perform pg_temp.check_eq('the auditor reads the frozen figures',
    (select current_amount::text from public.fs_figures
      where filing_id = d.filing and element_code = 'CostOfSales'), '4321.09');
end $$;

reset role;

select pg_temp.sign_in_as(pg_temp.test_user());
set local role authenticated;

do $$
declare d t_fs;
begin
  select * into d from t_fs;
  perform pg_temp.check_eq('the owner of both reads the other company''s figures as its own',
    (select current_amount::text from public.fs_figures
      where filing_id = d.other_filing and element_code = 'CostOfSales'), '555.00');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('anon reads no figure',
    not has_table_privilege('anon', 'public.fs_figures', 'select'));
end $$;

rollback;
