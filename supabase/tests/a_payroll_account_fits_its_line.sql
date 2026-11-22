-- =====================================================================
-- iAkauntan :: a payroll account fits its line (0919)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/a_payroll_account_fits_its_line.sql
--
-- `post_payroll_run` posts to whatever account `payroll_settings` names
-- for a line, and falls back to a numbered account only where none is
-- named. Before `0919` the EPF payable could be the bank and the net
-- salary payable a revenue account: a payroll of RM5,000 then posted no
-- salary expense and no EPF owed, RM3,800 into a bank that never
-- received it and RM4,415 of sales nobody made. As the owner with the
-- role `authenticated`, and once as the database's owner: the rule is
-- for every writer.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_pa (
  org uuid, other uuid, old_org uuid,
  bank uuid, sales uuid, head uuid, capital uuid, rent uuid, accrual uuid,
  wages uuid, kwsp uuid, shut_exp uuid, shut_lia uuid,
  theirs uuid, old_bank uuid, old_kwsp uuid);
grant select on t_pa to authenticated;

do $$
declare r t_pa;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Gaji Akaun Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 400, pg_temp.today() + 30);
  r.other   := pg_temp.test_org('Syarikat Lain Sdn Bhd');
  r.old_org := pg_temp.test_org('Gaji Lama Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  select o, m, true
    from unnest(array[r.org, r.other, r.old_org]) o,
         unnest(array['payroll', 'hr', 'accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  select id into r.bank    from public.accounts where org_id = r.org and code = '1120';
  select id into r.sales   from public.accounts where org_id = r.org and code = '4100';
  select id into r.head    from public.accounts where org_id = r.org and code = '2100';
  select id into r.capital from public.accounts where org_id = r.org and code = '3100';
  select id into r.rent    from public.accounts where org_id = r.org and code = '6200';
  select id into r.accrual from public.accounts where org_id = r.org and code = '2120';

  -- Accounts of the company's own, of the right kind for a line.
  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id)
  select r.org, '6105', 'Gaji Pengarah', 'expense', 'payroll_expense', a.parent_id
    from public.accounts a where a.org_id = r.org and a.code = '6100'
  returning id into r.wages;
  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id)
  select r.org, '2155', 'KWSP Belum Bayar', 'liability', 'current_liability', a.parent_id
    from public.accounts a where a.org_id = r.org and a.code = '2150'
  returning id into r.kwsp;
  -- And two of the right kind that are no longer in use.
  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id, is_active)
  select r.org, '6106', 'Gaji Lama', 'expense', 'payroll_expense', a.parent_id, false
    from public.accounts a where a.org_id = r.org and a.code = '6100'
  returning id into r.shut_exp;
  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id, is_active)
  select r.org, '2156', 'KWSP Lama', 'liability', 'current_liability', a.parent_id, false
    from public.accounts a where a.org_id = r.org and a.code = '2150'
  returning id into r.shut_lia;

  -- Another company's EPF payable: the right kind, the wrong company.
  select id into r.theirs from public.accounts where org_id = r.other and code = '2150';

  -- A company whose settings named the bank before the rule: written
  -- with the trigger off, since `0919` refuses it for every writer.
  select id into r.old_bank from public.accounts where org_id = r.old_org and code = '1120';
  select id into r.old_kwsp from public.accounts where org_id = r.old_org and code = '2150';
  alter table public.payroll_settings disable trigger a_payroll_account_fits_its_line;
  insert into public.payroll_settings (org_id, epf_payable_account_id, pay_day)
  values (r.old_org, r.old_bank, 25);
  alter table public.payroll_settings enable trigger a_payroll_account_fits_its_line;

  insert into t_pa select r.*;
end $$;

set local role authenticated;

-- What a company's ledger holds in the accounts asked about. Only those:
-- the rest of a payroll's journal moves with the month it is run in --
-- PCB spreads a year's tax over the months left in it -- and this file
-- is about where two of its lines land.
create or replace function pg_temp.pa_gl(p_org uuid, p_codes text[]) returns text language sql as $$
  select string_agg(a.code || ' ' || x.amt::text, ', ' order by a.code)
    from (select l.account_id, sum(l.debit - l.credit) amt
            from public.gl_lines l join public.gl_entries e on e.id = l.entry_id
           where e.org_id = p_org group by l.account_id having sum(l.debit - l.credit) <> 0) x
    join public.accounts a on a.id = x.account_id
   where a.code = any (p_codes);
$$;

do $$
declare
  d t_pa; v_line text[]; v_run uuid; v_period uuid;
  v_start date := date_trunc('month', pg_temp.today())::date;
begin
  select * into d from t_pa;

  -- -------------------------------------------------------------------
  -- Named for the first time
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('settings first written do not name the bank for EPF owed',
    format('insert into public.payroll_settings (org_id, epf_payable_account_id) values (%L, %L)',
           d.org, d.bank),
    'The EPF payable belongs in an active liability account that is not a heading, and 1120 Bank Accounts is an asset account. Payroll would post it there every month. Leave it unset to use the chart''s own account.',
    '23514');

  insert into public.payroll_settings (org_id) values (d.org);

  -- -------------------------------------------------------------------
  -- Every line asks, and each asks for its own kind
  -- -------------------------------------------------------------------
  -- An expense line offered a liability account, and a payable line an
  -- expense account: each is right for the other half and wrong here.
  foreach v_line slice 1 in array array[
    ['salary_expense', 'The salary expense'],
    ['epf_expense',    'The employer''s EPF expense'],
    ['socso_expense',  'The employer''s SOCSO expense'],
    ['eis_expense',    'The employer''s EIS expense'],
    ['hrdf_expense',   'The HRD Corp levy expense']] loop
    perform pg_temp.check_refused(v_line[1] || ' is not kept in a liability account',
      format('update public.payroll_settings set %I = %L where org_id = %L',
             v_line[1] || '_account_id', d.accrual, d.org),
      v_line[2] || ' belongs in an active expense account that is not a heading, and 2120 Other Payables and Accruals is a liability account.%',
      '23514');
  end loop;
  foreach v_line slice 1 in array array[
    ['salary_payable', 'The net salary payable'],
    ['epf_payable',    'The EPF payable'],
    ['socso_payable',  'The SOCSO payable'],
    ['eis_payable',    'The EIS payable'],
    ['pcb_payable',    'The PCB payable'],
    ['zakat_payable',  'The zakat payable']] loop
    perform pg_temp.check_refused(v_line[1] || ' is not kept in an expense account',
      format('update public.payroll_settings set %I = %L where org_id = %L',
             v_line[1] || '_account_id', d.rent, d.org),
      v_line[2] || ' belongs in an active liability account that is not a heading, and 6200 Rental is an expense account.%',
      '23514');
  end loop;

  -- The measured ones, and the rest of the kinds.
  perform pg_temp.check_refused('the salary expense is not the bank',
    format('update public.payroll_settings set salary_expense_account_id = %L where org_id = %L',
           d.bank, d.org),
    'The salary expense belongs in an active expense account that is not a heading, and 1120 Bank Accounts is an asset account.%',
    '23514');
  perform pg_temp.check_refused('net salaries owed are not sales',
    format('update public.payroll_settings set salary_payable_account_id = %L where org_id = %L',
           d.sales, d.org),
    'The net salary payable belongs in an active liability account that is not a heading, and 4100 Sales is a revenue account.%',
    '23514');
  perform pg_temp.check_refused('zakat owed is not share capital',
    format('update public.payroll_settings set zakat_payable_account_id = %L where org_id = %L',
           d.capital, d.org),
    'The zakat payable belongs in an active liability account that is not a heading, and 3100 Share Capital is an equity account.%',
    '23514');

  -- Of the right kind, and still not an account payroll can post to.
  perform pg_temp.check_refused('PCB owed is not a heading',
    format('update public.payroll_settings set pcb_payable_account_id = %L where org_id = %L',
           d.head, d.org),
    'The PCB payable belongs in an active liability account that is not a heading, and 2100 Current Liabilities is a heading.%',
    '23514');
  perform pg_temp.check_refused('the employer''s EPF is not a retired expense account',
    format('update public.payroll_settings set epf_expense_account_id = %L where org_id = %L',
           d.shut_exp, d.org),
    'The employer''s EPF expense belongs in an active expense account that is not a heading, and 6106 Gaji Lama is retired.%',
    '23514');
  perform pg_temp.check_refused('nor SOCSO owed a retired liability account',
    format('update public.payroll_settings set socso_payable_account_id = %L where org_id = %L',
           d.shut_lia, d.org),
    'The SOCSO payable belongs in an active liability account that is not a heading, and 2156 KWSP Lama is retired.%',
    '23514');

  -- Another company's account is the foreign key's to refuse, whatever
  -- kind it is -- and the refusal does not describe it.
  perform pg_temp.check_refused('another company''s EPF payable is refused by the tenant key',
    format('update public.payroll_settings set epf_payable_account_id = %L where org_id = %L',
           d.theirs, d.org),
    '%violates foreign key constraint%', '23503');
  perform pg_temp.check_refused('and so is its bank, without being named',
    format('update public.payroll_settings set epf_payable_account_id = %L where org_id = %L',
           d.old_bank, d.org),
    '%violates foreign key constraint%', '23503');
  perform pg_temp.check_refused('as is an account that does not exist',
    format('update public.payroll_settings set epf_payable_account_id = %L where org_id = %L',
           gen_random_uuid(), d.org),
    '%violates foreign key constraint%', '23503');

  perform pg_temp.check_eq('and after all of that the company names no account',
    (select count(*) from public.payroll_settings s
      where s.org_id = d.org
        and num_nonnulls(s.salary_expense_account_id, s.epf_expense_account_id,
              s.socso_expense_account_id, s.eis_expense_account_id, s.hrdf_expense_account_id,
              s.salary_payable_account_id, s.epf_payable_account_id, s.socso_payable_account_id,
              s.eis_payable_account_id, s.pcb_payable_account_id, s.zakat_payable_account_id) = 0),
    1::bigint);

  -- -------------------------------------------------------------------
  -- An account that fits is taken, and payroll posts to it
  -- -------------------------------------------------------------------
  update public.payroll_settings
     set salary_expense_account_id = d.wages, epf_payable_account_id = d.kwsp
   where org_id = d.org;

  insert into public.employees (org_id, employee_no, full_name, hire_date, basic_salary,
                                date_of_birth, marital_status, residency_status)
  values (d.org, 'W1', 'Pekerja Satu', date '2020-01-01', 5000, date '1992-04-15', 'single', 'citizen');
  v_period := public.ensure_pay_period(d.org, extract(year from v_start)::int,
                                       extract(month from v_start)::int);
  v_run := public.create_payroll_run(d.org, v_period, 'PAY-AKAUN-1');
  perform public.calculate_payroll_run(v_run);
  perform public.post_payroll_run(v_run);
  -- Salaries of 5,000 and EPF of 1,200 (11% and 13%), each in the
  -- account named and neither in the numbered one it would have gone to.
  perform pg_temp.check_eq('salaries go to the account named and EPF owed to the one named',
    pg_temp.pa_gl(d.org, array['6100', '6105', '2150', '2155']),
    '2155 -1200.00, 6105 5000.00');
  perform pg_temp.check_eq('and a line with no account named still goes to its numbered one',
    pg_temp.pa_gl(d.org, array['6110', '6120', '6130']),
    '6110 650.00, 6120 87.50, 6130 10.00');

  -- Saved whole, the accounts sent back as they were: the trigger fires
  -- and has to see that nothing was renamed.
  update public.payroll_settings
     set pay_day = 28, salary_expense_account_id = d.wages, epf_payable_account_id = d.kwsp
   where org_id = d.org;
  perform pg_temp.check_eq('the rest of the settings are still written',
    (select pay_day from public.payroll_settings where org_id = d.org), 28);

  -- -------------------------------------------------------------------
  -- Settings that named the bank before the rule
  -- -------------------------------------------------------------------
  update public.payroll_settings
     set pay_day = 27, epf_payable_account_id = d.old_bank
   where org_id = d.old_org;
  perform pg_temp.check_eq('are still saved whole, the old account sent back as it was',
    (select pay_day from public.payroll_settings where org_id = d.old_org), 27);
  perform pg_temp.check_refused('but a line is not given the bank afresh',
    format('update public.payroll_settings set socso_payable_account_id = %L where org_id = %L',
           d.old_bank, d.old_org),
    'The SOCSO payable belongs in an active liability account that is not a heading, and 1120 Bank Accounts is an asset account.%',
    '23514');
  update public.payroll_settings set epf_payable_account_id = d.old_kwsp where org_id = d.old_org;
  perform pg_temp.check_eq('and are put right by naming an account that fits',
    (select epf_payable_account_id from public.payroll_settings where org_id = d.old_org), d.old_kwsp);
  update public.payroll_settings set epf_payable_account_id = null where org_id = d.old_org;
  perform pg_temp.check_true('or by naming none',
    (select epf_payable_account_id is null from public.payroll_settings where org_id = d.old_org));
end $$;

-- The rule is for every writer, not only the app.
reset role;
select pg_temp.check_refused('the database''s owner is refused too',
  format('update public.payroll_settings set eis_payable_account_id = %L where org_id = %L',
         (select bank from t_pa), (select org from t_pa)),
  'The EIS payable belongs in an active liability account that is not a heading, and 1120 Bank Accounts is an asset account.%',
  '23514');

rollback;
