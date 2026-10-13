-- =====================================================================
-- iAkauntan :: ledger reports need ledger access (0855)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ledger_reports_need_ledger.sql
--
-- The journals are readable by the roles `app.can_read_ledger` names --
-- owner, admin, accountant, accounts clerk, auditor -- and by nobody
-- else (`0019`). Before `0855` every report built from them asked only
-- whether the reader was a member, so a salesman or an employee who
-- could not read one line of `gl_lines` was handed all of them by
-- `report_general_ledger`. Asked with the role `authenticated`, as the
-- reports screen asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_lr (org uuid, sister uuid,
  sales uuid, staff uuid, viewer uuid, buyer uuid, hr uuid,
  clerk uuid, auditor uuid, split uuid,
  bank uuid, txn uuid, comp uuid, est uuid, filing uuid, frozen uuid);
grant select on t_lr to authenticated;

do $$
declare r t_lr; v_fy uuid; v_group uuid; a_exp uuid; a_eq uuid; s_exp uuid; s_eq uuid;
  v_ic uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Lejar Terhad Sdn Bhd');
  r.sister := pg_temp.test_org('Lejar Saudara Sdn Bhd');
  perform pg_temp.open_years(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.sister, date_trunc('year', pg_temp.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (r.org, 'mbrs', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;

  r.sales   := pg_temp.another_user('sales@lejarterhad.test');
  r.staff   := pg_temp.another_user('staff@lejarterhad.test');
  r.viewer  := pg_temp.another_user('viewer@lejarterhad.test');
  r.buyer   := pg_temp.another_user('buyer@lejarterhad.test');
  r.hr      := pg_temp.another_user('hr@lejarterhad.test');
  r.clerk   := pg_temp.another_user('clerk@lejarterhad.test');
  r.auditor := pg_temp.another_user('auditor@lejarterhad.test');
  -- Keeps this company's books, and sells for the sister.
  r.split   := pg_temp.another_user('split@lejarterhad.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.sales, 'sales', 'active'), (r.org, r.staff, 'employee', 'active'),
         (r.org, r.viewer, 'viewer', 'active'), (r.org, r.buyer, 'purchaser', 'active'),
         (r.org, r.hr, 'hr_manager', 'active'), (r.org, r.clerk, 'accounts_clerk', 'active'),
         (r.org, r.auditor, 'auditor', 'active'),
         (r.org, r.split, 'accountant', 'active'), (r.sister, r.split, 'sales', 'active');

  insert into public.company_groups (name, created_by)
  values ('Kumpulan Lejar', pg_temp.test_user()) returning id into v_group;
  update public.organizations set group_id = v_group where id in (r.org, r.sister);

  select id into a_exp from public.accounts where org_id = r.org and not is_group
     and account_type = 'expense' order by code limit 1;
  select id into a_eq from public.accounts where org_id = r.org and not is_group
     and account_type = 'equity' order by code limit 1;
  select id into s_exp from public.accounts where org_id = r.sister and not is_group
     and account_type = 'expense' order by code limit 1;
  select id into s_eq from public.accounts where org_id = r.sister and not is_group
     and account_type = 'equity' order by code limit 1;
  perform public.post_manual_journal(r.org, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('account_id', a_exp, 'debit', 4321.09, 'credit', 0,
                         'department_code', 'HQ', 'project_code', 'P-1'),
      jsonb_build_object('account_id', a_eq, 'debit', 0, 'credit', 4321.09)),
    'Directors'' remuneration');
  -- The sister's cost is charged by this company: a line against a
  -- contact linked to it, which is what the intercompany report reads.
  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (r.sister, 'IC-LT', 'Lejar Terhad', 'supplier', r.org) returning id into v_ic;
  perform public.post_manual_journal(r.sister, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('account_id', s_exp, 'debit', 1234, 'credit', 0,
                         'contact_id', v_ic),
      jsonb_build_object('account_id', s_eq, 'debit', 0, 'credit', 1234)),
    'The sister''s own');

  r.bank := pg_temp.test_bank_account(r.org);
  insert into public.bank_transactions (org_id, bank_account_id, transaction_date, amount)
  values (r.org, r.bank, pg_temp.today(), -4321.09) returning id into r.txn;

  select id into v_fy from public.fiscal_years
   where org_id = r.org and pg_temp.today() between start_date and end_date;
  r.comp := public.open_tax_computation(r.org, v_fy);
  r.est := public.open_tax_estimate(r.org, v_fy, 1000);
  insert into public.fs_filings (org_id, fy_start, fy_end, audit_status)
  select r.org, start_date, end_date, 'audited' from public.fiscal_years where id = v_fy
  returning id into r.filing;
  -- And last year's, frozen: `fs_export` answers a frozen filing from
  -- `fs_figures` without calling `fs_prepare`, so it is the case that
  -- tests `fs_export`'s own refusal rather than the one behind it.
  insert into public.fs_filings (org_id, fy_start, fy_end, framework, audit_status, employee_count)
  values (r.org, (date_trunc('year', pg_temp.today()) - interval '1 year')::date,
          (date_trunc('year', pg_temp.today()) - interval '1 day')::date,
          'mpers', 'unaudited', 3)
  returning id into r.frozen;
  perform public.fs_freeze(r.frozen);

  insert into t_lr select r.*;
end $$;

-- Every road to the ledger, asked by one person. A report written in SQL
-- answers a reader it does not serve with nothing, as it always answered
-- a stranger; one written in PL/pgSQL refuses.
create or replace function pg_temp.every_road_closed(p_who text)
returns void language plpgsql as $$
declare d t_lr; v_to date := pg_temp.today(); v_from date := date_trunc('year', pg_temp.today())::date;
  v_msg constant text := 'Insufficient privileges to read the ledger';
begin
  select * into d from t_lr;
  perform pg_temp.check_eq(p_who || ': the premise -- a member, and the journals refused',
    app.is_org_member(d.org)::text || ' / '
      || (select count(*) from public.gl_lines where org_id = d.org)::text,
    'true / 0');

  -- What was measured.
  perform pg_temp.check_eq(p_who || ': the general ledger gives nothing',
    (select count(*) from public.report_general_ledger(d.org, null, v_to, null))::int, 0);
  perform pg_temp.check_eq(p_who || ': nor the trial balance',
    (select count(*) from public.report_trial_balance(d.org, null, v_to))::int, 0);
  perform pg_temp.check_eq(p_who || ': nor the profit and loss',
    (select count(*) from public.report_profit_loss(d.org, v_from, v_to))::int, 0);
  perform pg_temp.check_eq(p_who || ': nor the balance sheet',
    (select count(*) from public.report_balance_sheet(d.org, v_to))::int, 0);
  perform pg_temp.check_eq(p_who || ': nor the cash flow',
    (select count(*) from public.report_cash_flow(d.org, v_from, v_to))::int, 0);
  perform pg_temp.check_eq(p_who || ': nor the changes in equity',
    (select count(*) from public.report_changes_in_equity(d.org, v_from, v_to))::int, 0);
  perform pg_temp.check_eq(p_who || ': nor the profit and loss by department',
    (select count(*) from public.report_profit_loss_by_dimension(d.org, v_from, v_to, null, 'HQ'))::int, 0);
  perform pg_temp.check_eq(p_who || ': nor the departments the ledger names',
    (select count(*) from public.ledger_dimensions(d.org))::int, 0);

  perform pg_temp.check_refused(p_who || ': a laid-out profit and loss is refused',
    format('select * from public.report_with_layout(%L, ''profit_loss'', %L, %L, null, null, null)',
           d.org, v_from, v_to), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': the group trial balance',
    format('select * from public.report_group_trial_balance(%L, null, %L)', d.org, v_to), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': the group''s intercompany balances',
    format('select * from public.report_group_intercompany(%L, null, %L)', d.org, v_to), v_msg, '42501');
  -- Masked twice, and equivalent: `app.group_orgs` lists nothing for
  -- this reader, and `report_group_trial_balance` refuses in the same
  -- words.
  perform pg_temp.check_refused(p_who || ': the consolidated trial balance',
    format('select * from public.report_group_consolidated_trial_balance(%L, null, %L)', d.org, v_to), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': the elimination check',
    format('select * from public.report_group_elimination_check(%L, null, %L)', d.org, v_to), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': the deferred revenue schedule',
    format('select * from public.report_deferred_revenue(%L, %L)', d.org, v_to), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': the ledger lines a statement line might match',
    format('select * from public.suggest_bank_matches(%L, 5)', d.txn), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': the bank account''s ledger balance',
    format('select public.bank_reconciliation_status(%L, %L, 0)', d.bank, v_to), v_msg, '42501');
  -- The four below reach `tax_computation_lines` through
  -- `app.tax_business_income` on every path, and it refuses in the same
  -- words, so each one's own refusal survives being deleted: an
  -- equivalent mutant, masked by the assertion above it. They say it at
  -- their top so that the refusal does not depend on how a computation
  -- is assembled. `tax_estimate_exposure` has a road that does not.
  perform pg_temp.check_refused(p_who || ': the tax computation''s lines',
    format('select * from public.tax_computation_lines(%L)', d.comp), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': the tax computation',
    format('select public.tax_computation(%L)', d.comp), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': an individual''s',
    format('select public.tax_computation_individual(%L)', d.comp), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': a partnership''s allocation',
    format('select public.tax_partnership_allocation(%L)', d.comp), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': and its summary',
    format('select public.tax_partnership_summary(%L)', d.comp), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': the estimate''s exposure',
    format('select public.tax_estimate_exposure(%L)', d.est), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': the financial statements',
    format('select public.fs_prepare(%L)', d.filing), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': their export, once frozen',
    format('select public.fs_export(%L)', d.frozen), v_msg, '42501');
  perform pg_temp.check_refused(p_who || ': and the audit exemption, which reads revenue and assets',
    format('select public.fs_audit_exemption(%L)', d.filing), v_msg, '42501');
end $$;
grant execute on function pg_temp.every_road_closed(text) to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub', (select sales from t_lr), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.every_road_closed('sales');
reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', (select staff from t_lr), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.every_road_closed('an employee');
reset role;

-- The other three roles the picker says are not the ledger's: the same
-- answer from the report that was measured.
do $$
declare d t_lr; v_who text; v_id uuid; v_n int;
begin
  select * into d from t_lr;
  foreach v_who in array array['viewer', 'buyer', 'hr'] loop
    v_id := case v_who when 'viewer' then d.viewer when 'buyer' then d.buyer else d.hr end;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_id, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select count(*) into v_n from public.report_general_ledger(d.org, null, pg_temp.today(), null);
    reset role;
    perform pg_temp.check_eq(v_who || ': the general ledger gives nothing', v_n, 0);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- And the roles that read the ledger still read it all
-- ---------------------------------------------------------------------
-- Every refusal above would also hold if the reports had simply stopped
-- working.
create or replace function pg_temp.every_road_open(p_who text)
returns void language plpgsql as $$
declare d t_lr; v_to date := pg_temp.today(); v_from date := date_trunc('year', pg_temp.today())::date;
begin
  select * into d from t_lr;
  perform pg_temp.check_eq(p_who || ': the general ledger carries the journal',
    (select sum(debit) from public.report_general_ledger(d.org, null, v_to, null)), 4321.09);
  perform pg_temp.check_eq(p_who || ': and the trial balance',
    (select sum(debit) from public.report_trial_balance(d.org, null, v_to)), 4321.09);
  perform pg_temp.check_eq(p_who || ': and the profit and loss',
    (select count(*) from public.report_profit_loss(d.org, v_from, v_to))::int, 1);
  perform pg_temp.check_true(p_who || ': and the balance sheet, the capital moved',
    (select count(*) from public.report_balance_sheet(d.org, v_to) where balance <> 0) > 0);
  perform pg_temp.check_true(p_who || ': and the cash flow',
    (select count(*) from public.report_cash_flow(d.org, v_from, v_to)) > 0);
  perform pg_temp.check_true(p_who || ': and the changes in equity',
    (select count(*) from public.report_changes_in_equity(d.org, v_from, v_to)) > 0);
  perform pg_temp.check_eq(p_who || ': and the department''s profit and loss',
    (select count(*) from public.report_profit_loss_by_dimension(d.org, v_from, v_to, null, 'HQ'))::int, 1);
  perform pg_temp.check_eq(p_who || ': and the department and the project',
    (select string_agg(code, ',') from public.ledger_dimensions(d.org)), 'HQ,P-1');
  perform pg_temp.check_true(p_who || ': and the laid-out profit and loss',
    (select count(*) from public.report_with_layout(d.org, 'profit_loss', v_from, v_to, null, null, null)) > 0);
  perform pg_temp.check_true(p_who || ': and the deferred revenue schedule, empty as it is',
    (select count(*) from public.report_deferred_revenue(d.org, v_to)) >= 0);
  perform pg_temp.check_true(p_who || ': and the bank account''s ledger balance',
    public.bank_reconciliation_status(d.bank, v_to, 0) is not null);
  perform pg_temp.check_true(p_who || ': and the lines a statement line might match',
    (select count(*) from public.suggest_bank_matches(d.txn, 5)) >= 0);
  perform pg_temp.check_true(p_who || ': and the tax computation''s lines are answered, not refused',
    (select count(*) from public.tax_computation_lines(d.comp)) >= 0);
  perform pg_temp.check_eq(p_who || ': and the tax computation',
    (select count(*) from public.tax_computation(d.comp))::int, 1);
  perform pg_temp.check_true(p_who || ': and the estimate''s exposure is answered, not refused',
    (select count(*) from public.tax_estimate_exposure(d.est)) >= 0);
  perform pg_temp.check_true(p_who || ': and the financial statements are answered, not refused',
    (select count(*) from public.fs_prepare(d.filing)) >= 0);
  perform pg_temp.check_true(p_who || ': and the frozen export is answered, not refused',
    (select count(*) from public.fs_export(d.frozen)) >= 0);
  perform pg_temp.check_true(p_who || ': and the audit exemption',
    (select count(*) from public.fs_audit_exemption(d.filing)) > 0);
end $$;
grant execute on function pg_temp.every_road_open(text) to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub', (select clerk from t_lr), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.every_road_open('the clerk');
reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', (select auditor from t_lr), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.every_road_open('the auditor');
reset role;

-- ---------------------------------------------------------------------
-- A group shows the companies whose ledger you may read
-- ---------------------------------------------------------------------
-- The accountant of this company sells for its sister. The group trial
-- balance they ask for is this company's alone; the owner of both sees
-- both.
--
-- `app.group_orgs` asks it of each company in the group, and that is
-- what the intercompany assertion below kills: the trial balance would
-- not, since `report_trial_balance` gives the sister nothing anyway. It
-- asks it of the company the report is asked from as well, and that
-- half is an equivalent mutant: every report that calls it has refused
-- such a reader already.
select set_config('request.jwt.claims',
  json_build_object('sub', (select split from t_lr), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_lr;
begin
  select * into d from t_lr;
  perform pg_temp.check_eq('the premise: a member of both companies, reading one ledger',
    app.is_org_member(d.sister)::text || ' / ' || app.can_read_ledger(d.sister)::text,
    'true / false');
  perform pg_temp.check_eq('the group trial balance leaves out the company they only sell for',
    (select sum(debit) from public.report_group_trial_balance(d.org, null, pg_temp.today())), 4321.09);
  perform pg_temp.check_eq('nor the sister''s line against this company in the intercompany report',
    (select count(*) from public.report_group_intercompany(d.org, null, pg_temp.today()))::int, 0);
  perform pg_temp.check_refused('and asked from the sister, it is refused',
    format('select * from public.report_group_trial_balance(%L, null, %L)', d.sister, pg_temp.today()),
    'Insufficient privileges to read the ledger', '42501');
end $$;

reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_lr;
begin
  select * into d from t_lr;
  perform pg_temp.check_eq('while the owner of both sees both',
    (select sum(debit) from public.report_group_trial_balance(d.org, null, pg_temp.today())), 5555.09);
  perform pg_temp.check_eq('and the sister''s intercompany line',
    (select sum(expense) from public.report_group_intercompany(d.org, null, pg_temp.today())), 1234);
end $$;

reset role;

rollback;
