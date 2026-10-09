-- =====================================================================
-- iAkauntan :: ledger and fiscal period tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ledger.sql
--
-- The rules that stop the books drifting: a journal must balance, it
-- must land inside a period, and a closed period must refuse it. Runs
-- inside a transaction that is rolled back at the end.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A fiscal year, and the runway after it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_fy1 uuid;
  v_fy2 uuid;
  v_start date;
begin
  v_org := pg_temp.test_org('Ledger Co');

  -- create_organization is not used here, so the first year is explicit.
  v_fy1 := public.create_fiscal_year(v_org, date '2026-01-01');
  perform pg_temp.check_eq('a fiscal year gets twelve periods',
    (select count(*) from public.fiscal_periods where fiscal_year_id = v_fy1), 12);
  perform pg_temp.check_true('and it ends a day short of a year',
    (select end_date = date '2026-12-31' from public.fiscal_years where id = v_fy1));

  -- With no date given, the next year continues from the last one rather
  -- than recomputing from the organization's year end and colliding.
  v_fy2 := public.create_fiscal_year(v_org);
  select start_date into v_start from public.fiscal_years where id = v_fy2;
  perform pg_temp.check_true('the next year starts the day the last one ends',
    v_start = date '2027-01-01');

  -- An overlap would give one date two periods, and app.period_for_date
  -- would then pick between them arbitrarily.
  begin
    perform public.create_fiscal_year(v_org, date '2027-06-01');
    raise exception 'FAIL: an overlapping fiscal year was accepted';
  exception when sqlstate '23505' then
    raise notice 'ok   an overlapping fiscal year is refused';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Posting
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_ar  uuid;
  v_rev uuid;
  v_per uuid;
  v_e   uuid;
begin
  v_org := pg_temp.test_org('Posting Co');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  select id into v_ar  from public.accounts where org_id = v_org and code = '1210';
  select id into v_rev from public.accounts where org_id = v_org and code = '4100';

  -- A date no period covers used to post with a null fiscal_period_id,
  -- which put the entry beyond the reach of period locking entirely.
  begin
    perform public.create_gl_entry(v_org, date '2030-05-05',
      'manual'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_ar,  'debit', 100, 'credit', 0),
        jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 100)),
      'outside every fiscal year');
    raise exception 'FAIL: posted to a date no fiscal period covers';
  exception when sqlstate '23514' then
    raise notice 'ok   a date outside every fiscal year is refused';
  end;

  -- An unbalanced journal never reaches the ledger.
  begin
    perform public.create_gl_entry(v_org, date '2026-02-10',
      'manual'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_ar,  'debit', 100, 'credit', 0),
        jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 90)),
      'unbalanced');
    raise exception 'FAIL: an unbalanced journal posted';
  exception when sqlstate '23514' then
    raise notice 'ok   an unbalanced journal is refused';
  end;

  -- A good one lands, and carries the period it belongs to.
  v_e := public.create_gl_entry(v_org, date '2026-02-10',
    'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar,  'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 100)),
    'good entry');
  perform pg_temp.check_true('a posted entry carries its fiscal period',
    (select fiscal_period_id is not null from public.gl_entries where id = v_e));

  -- Closing a period is what makes the rule above worth anything.
  select id into v_per from public.fiscal_periods
   where org_id = v_org and start_date = date '2026-02-01';
  perform public.set_fiscal_period_status(v_per, 'closed');
  begin
    perform public.create_gl_entry(v_org, date '2026-02-11',
      'manual'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_ar,  'debit', 5, 'credit', 0),
        jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 5)),
      'into a closed period');
    raise exception 'FAIL: posted into a closed period';
  exception when sqlstate '23514' then
    raise notice 'ok   a closed period refuses a posting';
  end;

  -- Closed reopens; locked is year-end sign-off and does not.
  perform public.set_fiscal_period_status(v_per, 'open');
  perform public.set_fiscal_period_status(v_per, 'locked');
  begin
    perform public.set_fiscal_period_status(v_per, 'open');
    raise exception 'FAIL: a locked period was reopened';
  exception when sqlstate '22023' then
    raise notice 'ok   a locked period cannot be reopened';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Who may do any of this
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_per uuid;
begin
  v_org := pg_temp.test_org('Guarded Co');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  select id into v_per from public.fiscal_periods
   where org_id = v_org and period_no = 1;

  perform pg_temp.sign_out();

  begin
    perform public.create_fiscal_year(v_org, date '2028-01-01');
    raise exception 'FAIL: a non-member created a fiscal year';
  exception when sqlstate '42501' then
    raise notice 'ok   a non-member cannot create a fiscal year';
  end;

  begin
    perform public.set_fiscal_period_status(v_per, 'closed');
    raise exception 'FAIL: a non-member closed a period';
  exception when sqlstate '42501' then
    raise notice 'ok   a non-member cannot close a period';
  end;

  -- The scheduler's posting path must not be reachable from an API key,
  -- or the permission check on the public one is decoration.
  perform pg_temp.check_true('the unchecked poster is not exposed to the API',
    not has_function_privilege('authenticated',
      'app.create_gl_entry_internal(uuid,date,app.journal_source,jsonb,text,'
      || 'text,uuid,text,character,numeric)', 'execute'));
  perform pg_temp.check_true('nor is the unchecked numbering',
    not has_function_privilege('authenticated',
      'app.next_document_number_internal(uuid,text)', 'execute'));
end $$;

-- ---------------------------------------------------------------------
-- Reversal
--
-- A reversal is a posting like any other, and used to escape the period
-- rules that every other posting answers to.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_ar uuid; v_rev uuid; v_e uuid; v_r uuid; v_per uuid;
  v_dr numeric; v_cr numeric;
begin
  v_org := pg_temp.test_org('Reversal Co');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  select id into v_ar  from public.accounts where org_id = v_org and code = '1210';
  select id into v_rev from public.accounts where org_id = v_org and code = '4100';

  v_e := public.create_gl_entry(v_org, date '2026-05-10',
    'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar,  'debit', 900, 'credit', 0),
      jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 900)),
    'to be reversed');

  begin
    perform public.reverse_gl_entry(v_e, date '2031-01-01');
    raise exception 'FAIL: reversed into a date no fiscal period covers';
  exception when sqlstate '23514' then
    raise notice 'ok   a reversal cannot escape into an uncovered date';
  end;

  select id into v_per from public.fiscal_periods
   where org_id = v_org and start_date = date '2026-06-01';
  perform public.set_fiscal_period_status(v_per, 'closed');
  begin
    perform public.reverse_gl_entry(v_e, date '2026-06-15');
    raise exception 'FAIL: reversed into a closed period';
  exception when sqlstate '23514' then
    raise notice 'ok   a reversal cannot reopen a closed month by the back door';
  end;

  v_r := public.reverse_gl_entry(v_e, date '2026-05-31');
  select sum(debit), sum(credit) into v_dr, v_cr
    from public.gl_lines where entry_id = v_r;
  perform pg_temp.check_eq('the reversal mirrors the original, debits', v_dr, 900);
  perform pg_temp.check_eq('and credits', v_cr, 900);
  -- Contra-ed, not deleted and not voided either. Voiding the original
  -- *as well* as mirroring it would take it out of every report — they
  -- all filter on `posted` — leaving the mirror standing alone, which
  -- is the opposite of the entry rather than nothing. That is what 0102
  -- fixed and `supabase/tests/reversal.sql` covers caller by caller.
  perform pg_temp.check_true('the original stays posted, contra-ed not hidden',
    (select status = 'posted' from public.gl_entries where id = v_e));
  perform pg_temp.check_true('and the mirror says what it reverses',
    (select is_reversal and reversed_entry_id = v_e
       from public.gl_entries where id = v_r));
  perform pg_temp.check_eq('so the two of them come to nothing',
    coalesce((select sum(l.debit - l.credit)
                from public.gl_lines l
                join public.gl_entries e on e.id = l.entry_id
               where e.id in (v_e, v_r) and e.status = 'posted'
                 and l.account_id = v_ar), 0), 0);

  begin
    perform public.reverse_gl_entry(v_e, date '2026-05-31');
    raise exception 'FAIL: a reversed journal was reversed again';
  exception when sqlstate '22023' then
    raise notice 'ok   reversing the contra would put the entry back';
  end;
end $$;

-- ---------------------------------------------------------------------
-- The periodic jobs
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_emp uuid; v_type uuid; v_exp uuid; v_ap uuid;
  v_rj uuid; v_n integer; v_bal record; v_next date; v_err text; v_per uuid;
begin
  v_org := pg_temp.test_org('Scheduled Co');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  select id into v_exp from public.accounts
   where org_id = v_org and is_group = false and account_type = 'expense' limit 1;
  select id into v_ap from public.accounts where org_id = v_org and code = '2110';

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary, residency_status)
  values (v_org, 'S1', 'Leave Taker', date '2020-01-01', 5000, 'citizen')
  returning id into v_emp;

  insert into public.leave_types
    (org_id, code, name, default_days, max_carry_forward, is_active)
  values (v_org, 'AL', 'Annual leave', 16, 5, true)
  returning id into v_type;

  -- 16 entitled, 9 taken: 7 unused, but only 5 may be carried.
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year, entitled_days, taken_days)
  values (v_org, v_emp, v_type, 2025, 16, 9);

  perform app.roll_leave_year(v_org, 2026);
  select * into v_bal from public.leave_balances
   where employee_id = v_emp and leave_type_id = v_type and leave_year = 2026;
  perform pg_temp.check_eq('next year opens with the full entitlement',
    v_bal.entitled_days, 16);
  perform pg_temp.check_eq('and carries only what the type allows',
    v_bal.carried_forward, 5);

  -- Running the roll twice must not double anybody's leave.
  perform app.roll_leave_year(v_org, 2026);
  select count(*) into v_n from public.leave_balances
   where employee_id = v_emp and leave_type_id = v_type and leave_year = 2026;
  perform pg_temp.check_eq('rolling the year again changes nothing', v_n, 1);

  insert into public.recurring_journals
    (org_id, name, description, frequency, interval_count, start_date,
     next_run_date, auto_post, is_active, template, created_by)
  values (v_org, 'Office rent', 'Monthly rent', 'monthly', 1,
          date '2026-01-01', date '2026-03-01', true, true,
          jsonb_build_object('lines', jsonb_build_array(
            jsonb_build_object('account_id', v_exp, 'debit', 3500, 'credit', 0),
            jsonb_build_object('account_id', v_ap,  'debit', 0, 'credit', 3500))),
          pg_temp.test_user())
  returning id into v_rj;

  v_n := app.run_recurring_journals(date '2026-03-05');
  select last_error into v_err from public.recurring_journals where id = v_rj;
  if v_n <> 1 then
    raise exception 'FAIL: % recurring journals ran. last_error = %', v_n, v_err;
  end if;

  select next_run_date into v_next from public.recurring_journals where id = v_rj;
  perform pg_temp.check_true('the schedule advances by its own frequency',
    v_next = date '2026-04-01');
  perform pg_temp.check_eq('and exactly one journal was posted',
    (select count(*) from public.gl_entries
      where org_id = v_org and source_id = v_rj), 1);

  perform pg_temp.check_eq('running again the same day posts nothing',
    app.run_recurring_journals(date '2026-03-05'), 0);

  -- A journal that cannot post records why and stays due, rather than
  -- disappearing from the run with no explanation.
  select id into v_per from public.fiscal_periods
   where org_id = v_org and start_date = date '2026-04-01';
  perform public.set_fiscal_period_status(v_per, 'closed');
  perform pg_temp.check_eq('a blocked journal does not count as run',
    app.run_recurring_journals(date '2026-04-02'), 0);
  select last_error, next_run_date into v_err, v_next
    from public.recurring_journals where id = v_rj;
  perform pg_temp.check_true('it records why it was skipped', v_err is not null);
  perform pg_temp.check_true('and stays due so it retries',
    v_next = date '2026-04-01');
end $$;


-- ---------------------------------------------------------------------
-- The door: who may write a journal through the API
--
-- `public.create_gl_entry` is the API's way into the ledger, and the
-- whole of it is one permission check in front of the internal writer.
-- Eight files call it and every one called it as an OWNER, so the
-- 2026-10-06 sweep deleted the check outright -- and then pointed it at
-- "any company I can post in" instead of the one named -- and both
-- survived the suite. Either would let a viewer, or an accountant of a
-- different company, write journals into somebody's books.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org   uuid := pg_temp.test_org('Pintu Lejar Sdn Bhd');
  v_other uuid;
  v_viewer uuid; v_acct uuid;
  v_cash  uuid; v_sales uuid; v_lines jsonb; v_n integer;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  select id into v_cash  from public.accounts where org_id = v_org and code = '1210';
  select id into v_sales from public.accounts where org_id = v_org and code = '4100';
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_cash,  'debit', 10, 'credit', 0),
    jsonb_build_object('account_id', v_sales, 'debit', 0,  'credit', 10));

  -- The positive control: the owner may.
  perform public.create_gl_entry(v_org, pg_temp.today(), 'manual', v_lines, 'owner posts');
  perform pg_temp.check_eq('the owner may post a journal',
    (select count(*)::integer from public.gl_entries
      where org_id = v_org and description = 'owner posts'), 1);

  -- A viewer of this company may not.
  v_viewer := pg_temp.another_user('lejar-viewer@example.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_viewer, 'viewer', 'active', now());
  perform pg_temp.sign_in_as(v_viewer);
  begin
    perform public.create_gl_entry(v_org, pg_temp.today(), 'manual', v_lines, 'viewer posts');
    perform pg_temp.check_true('a viewer may not post a journal', false);
  exception when insufficient_privilege then
    perform pg_temp.check_true('a viewer may not post a journal', true);
  end;

  -- An accountant of ANOTHER company may not post into this one, though
  -- they may post in their own.
  perform pg_temp.sign_in_as(v_owner);
  v_other := pg_temp.test_org('Syarikat Lain Sdn Bhd');
  v_acct := pg_temp.another_user('lejar-accountant@example.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_other, v_acct, 'accountant', 'active', now());
  -- A member of their own company ONLY. Were they also a viewer here,
  -- a check that looked up "some company of mine" could land on this
  -- one's viewer row first and refuse them by luck.
  perform pg_temp.sign_in_as(v_acct);
  begin
    perform public.create_gl_entry(v_org, pg_temp.today(), 'manual', v_lines, 'stranger posts');
    perform pg_temp.check_true(
      'posting rights in one company do not carry into another', false);
  exception when insufficient_privilege then
    perform pg_temp.check_true(
      'posting rights in one company do not carry into another', true);
  end;

  perform pg_temp.sign_in_as(v_owner);
  select count(*)::integer into v_n from public.gl_entries
   where org_id = v_org and description in ('viewer posts', 'stranger posts');
  perform pg_temp.check_eq('and neither left a journal behind', v_n, 0);
end $$;

-- ---------------------------------------------------------------------
-- 0765: a heading holds no line of its own
--
-- Every report adds up LEAVES (`and not a.is_group`), so a line on a
-- heading left the trial balance with no error anywhere. The guard is
-- on `gl_lines` itself, so it is asserted there first -- a line written
-- straight into the ledger, by nothing that might have its own guard --
-- and then through the two document posters, which had none.
--
-- The control beside each refusal is the same thing on a leaf, and the
-- trial balance is read afterwards: the leaves balance, which is what
-- the heading line broke.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_cust uuid; v_supp uuid; v_inv uuid; v_bill uuid; v_e uuid;
  v_rev_head uuid; v_cos_head uuid; v_sales uuid; v_cash uuid;
  v_today date := pg_temp.today();
  v_dr numeric; v_cr numeric;
begin
  v_org := pg_temp.test_org('Kepala Akaun Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', v_today)::date);
  select id into v_rev_head from public.accounts where org_id = v_org and code = '4000';
  select id into v_cos_head from public.accounts where org_id = v_org and code = '5000';
  select id into v_sales    from public.accounts where org_id = v_org and code = '4100';
  select id into v_cash     from public.accounts where org_id = v_org and code = '1210';
  perform pg_temp.check_true('the fixture''s 4000 and 5000 are headings',
    (select bool_and(is_group) from public.accounts where id in (v_rev_head, v_cos_head)));
  perform pg_temp.check_true('and 4100 and 1210 are not',
    (select not bool_or(is_group) from public.accounts where id in (v_sales, v_cash)));

  -- Straight into the ledger.
  v_e := public.create_gl_entry(v_org, v_today, 'manual',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash,  'debit', 10, 'credit', 0),
      jsonb_build_object('account_id', v_sales, 'debit', 0,  'credit', 10)),
    'a leaf journal');
  perform pg_temp.check_eq('a journal on two leaves posts',
    (select count(*)::integer from public.gl_lines where entry_id = v_e), 2);
  perform pg_temp.check_refused(
    'a line written straight onto a heading is refused',
    format($q$insert into public.gl_lines (org_id, entry_id, line_no, account_id, debit, credit)
              values (%L, %L, 3, %L, 0, 5)$q$, v_org, v_e, v_rev_head),
    'Account 4000 (REVENUE) is a heading.%drop out of the trial balance%',
    '23514');
  perform pg_temp.check_refused(
    'and so is a line moved onto one',
    format($q$update public.gl_lines set account_id = %L
               where entry_id = %L and account_id = %L$q$, v_rev_head, v_e, v_sales),
    'Account 4000 (REVENUE) is a heading.%', '23514');
  perform pg_temp.check_eq('and the journal still credits the leaf',
    (select account_id from public.gl_lines where entry_id = v_e and credit > 0), v_sales);

  -- An invoice, the way the app writes one, on the revenue heading.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-KPL', 'Pelanggan Kepala', 'customer') returning id into v_cust;
  insert into public.sales_documents (org_id, doc_type, doc_no, doc_date, due_date,
    contact_id, currency, exchange_rate, status)
  values (v_org, 'invoice', 'INV-KPL-1', v_today, v_today, v_cust, 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines (org_id, document_id, line_no, line_type,
    description, quantity, unit_price, account_id, tax_rate)
  values (v_org, v_inv, 1, 'item', 'Yuran', 1, 70, v_rev_head, 0);
  perform pg_temp.check_refused(
    'an invoice line on the revenue heading does not post',
    format('select public.post_sales_document(%L)', v_inv),
    'Account 4000 (REVENUE) is a heading.%', '23514');
  perform pg_temp.check_true('and the invoice is still a draft, with no journal',
    (select status = 'draft' and gl_entry_id is null
       from public.sales_documents where id = v_inv));

  -- The control: the same invoice on a leaf.
  update public.sales_document_lines set account_id = v_sales where document_id = v_inv;
  perform public.post_sales_document(v_inv);
  perform pg_temp.check_true('on 4100 the same invoice posts',
    (select gl_entry_id is not null from public.sales_documents where id = v_inv));

  -- A bill on the cost-of-sales heading.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-KPL', 'Pembekal Kepala', 'supplier') returning id into v_supp;
  insert into public.purchase_documents (org_id, doc_type, doc_no, doc_date, due_date,
    contact_id, currency, exchange_rate, status)
  values (v_org, 'bill', 'B-KPL-1', v_today, v_today, v_supp, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines (org_id, document_id, line_no, line_type,
    description, quantity, unit_price, account_id, tax_rate)
  values (v_org, v_bill, 1, 'item', 'Bekalan', 1, 50, v_cos_head, 0);
  perform pg_temp.check_refused(
    'a bill line on the cost-of-sales heading does not post',
    format('select public.post_purchase_document(%L)', v_bill),
    'Account 5000 (COST OF SALES) is a heading.%', '23514');
  perform pg_temp.check_true('and the bill is still a draft, with no journal',
    (select status = 'draft' and gl_entry_id is null
       from public.purchase_documents where id = v_bill));

  -- What the heading line broke: the trial balance adds up leaves, and
  -- the leaves balance.
  select sum(debit), sum(credit) into v_dr, v_cr
    from public.report_trial_balance(v_org);
  perform pg_temp.check_eq('the trial balance''s debits are the ledger''s',
    v_dr, (select sum(debit) from public.gl_lines where org_id = v_org));
  perform pg_temp.check_eq('and its credits are too', v_cr,
    (select sum(credit) from public.gl_lines where org_id = v_org));
  perform pg_temp.check_eq('so it balances, at the 80 posted', v_dr, 80.00::numeric);
end $$;

rollback;
