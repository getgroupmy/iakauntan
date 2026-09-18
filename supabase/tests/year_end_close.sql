-- =====================================================================
-- iAkauntan :: the year-end close
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/year_end_close.sql
--
-- Bringing a year's revenue and expenses to nil and putting the result
-- in equity is the one piece of arithmetic every set of books does, and
-- there are five ways to get it wrong that nothing else would report:
--
--   1. **The sign.** A loss credited to equity instead of debited reads
--      as a profitable year on the face of the balance sheet, and the
--      sheet still balances, because the closing entry balances against
--      itself either way.
--   2. **Counting it twice.** `app.fs_cumulative_profit` sums the
--      profit and loss FROM 1900 so that the statutory accounts balance
--      in a ledger with no close. If a close leaves anything behind in
--      the P&L accounts, the MBRS filing shows the year's profit in
--      retained earnings AND again underneath it.
--   3. **Out of order.** Closing 2026 while 2025 is still open sweeps
--      two years of trading into one year's result.
--   4. **Twice.** A second close doubles the year's profit in equity.
--   5. **Undone by deletion.** Reopening by deleting the journal leaves
--      a ledger whose history disagrees with what was filed on it.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.yec_jv(
  p_org uuid, p_no text, p_date date,
  p_dr uuid, p_cr uuid, p_amount numeric)
returns void language plpgsql as $$
declare v_entry uuid;
begin
  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, status, description)
  values (p_org, p_no, p_date, 'manual', 'posted', p_no)
  returning id into v_entry;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id, debit, credit)
  values (p_org, v_entry, 1, p_dr, p_amount, 0),
         (p_org, v_entry, 2, p_cr, 0, p_amount);
end $$;

create or replace function pg_temp.yec_acct(p_org uuid, p_subtype text)
returns uuid language sql as $$
  select id from public.accounts
   where org_id = p_org and account_subtype = p_subtype::app.account_subtype
     and not is_group
   order by code limit 1;
$$;

-- The balance of one account as the balance sheet reports it.
create or replace function pg_temp.yec_equity(p_org uuid, p_as_at date)
returns numeric language sql as $$
  select round(coalesce(sum(b.balance), 0), 2)
    from public.report_balance_sheet(p_org, p_as_at) b
    join public.accounts a on a.id = b.account_id
   where a.code = '3300';
$$;

-- ---------------------------------------------------------------------
-- A profitable year
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_fy uuid; v_next uuid;
  v_bank uuid; v_cap uuid; v_sales uuid; v_exp uuid;
  v_entry uuid; v_rows integer; v_src text;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe Year End');
  v_fy := public.create_fiscal_year(v_org, date '2025-01-01');

  v_bank  := pg_temp.yec_acct(v_org, 'bank');
  v_cap   := pg_temp.yec_acct(v_org, 'share_capital');
  v_sales := pg_temp.yec_acct(v_org, 'sales');
  v_exp   := pg_temp.yec_acct(v_org, 'operating_expense');

  perform pg_temp.yec_jv(v_org, 'YE-1', date '2025-01-02', v_bank, v_cap, 100000);
  perform pg_temp.yec_jv(v_org, 'YE-2', date '2025-06-30', v_bank, v_sales, 250000);
  perform pg_temp.yec_jv(v_org, 'YE-3', date '2025-06-30', v_exp, v_bank, 180000);

  -- Before: the year's result is in the profit and loss accounts and
  -- nowhere else, which is the state every one of this repository's
  -- statutory workarounds was written for.
  perform pg_temp.check_eq('before the close, equity carries nothing',
    pg_temp.yec_equity(v_org, date '2025-12-31')::text, '0.00');
  perform pg_temp.check_eq('and the profit is in the P&L accounts',
    app.fs_cumulative_profit(v_org, date '2025-12-31')::text, '70000.00');

  v_entry := public.close_fiscal_year(v_fy);
  perform pg_temp.check_true('closing posts a journal', v_entry is not null);

  select count(*) into v_rows
    from public.report_profit_loss(v_org, date '2025-01-01', date '2025-12-31');
  perform pg_temp.check_eq('every profit and loss account is brought to nil',
    v_rows::text, '0');

  perform pg_temp.check_eq('and the result is in Current Year Earnings',
    pg_temp.yec_equity(v_org, date '2025-12-31')::text, '70000.00');

  -- 2: the assertion the whole file exists for. `fs_cumulative_profit`
  -- sums the P&L from 1900 so the statutory accounts balance WITHOUT a
  -- close; if the close leaves anything behind there, the MBRS filing
  -- shows the year's profit in retained earnings and again under it.
  perform pg_temp.check_eq('and is not counted a second time',
    app.fs_cumulative_profit(v_org, date '2025-12-31')::text, '0.00');

  select e.source::text into v_src
    from public.gl_entries e where e.id = v_entry;
  perform pg_temp.check_eq('the journal says what it is', v_src, 'year_end_close');

  perform pg_temp.check_eq('and the year records which journal closed it',
    (select closing_entry_id from public.fiscal_years where id = v_fy)::text,
    v_entry::text);

  -- 4: not twice.
  begin
    perform public.close_fiscal_year(v_fy);
    raise exception 'a year was closed twice';
  exception when check_violation then
    raise notice 'ok   and a year already closed cannot be closed again';
  end;

  -- 3: not out of order. A later year refuses while this one is open
  -- again, and the earlier-year rule is what says so.
  perform public.reopen_fiscal_year(v_fy);
  v_next := public.create_fiscal_year(v_org, date '2026-01-01');
  begin
    perform public.close_fiscal_year(v_next);
    raise exception 'a year closed while an earlier one was open';
  exception when check_violation then
    raise notice 'ok   and one cannot close while an earlier year is open';
  end;

  -- 5: reopening reverses rather than deletes, so the figures come
  -- back and the history keeps both entries.
  perform pg_temp.check_eq('reopening puts the profit back where it was',
    app.fs_cumulative_profit(v_org, date '2025-12-31')::text, '70000.00');
  perform pg_temp.check_eq('and takes it out of equity',
    pg_temp.yec_equity(v_org, date '2025-12-31')::text, '0.00');
  perform pg_temp.check_true('while both journals are still on the ledger',
    (select count(*) from public.gl_entries
      where org_id = v_org and source = 'year_end_close') = 2);
  perform pg_temp.check_eq('and the year is open again',
    (select status from public.fiscal_years where id = v_fy), 'open');

  raise notice 'year end: closed, not twice, not out of order, and reversible';
end $$;

-- ---------------------------------------------------------------------
-- 1: a loss goes the other way
--
-- The sign is the one that balances either way. A loss credited to
-- equity rather than debited reads as a profitable year on the face of
-- the balance sheet, and the sheet still adds up.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_fy uuid;
  v_bank uuid; v_cap uuid; v_sales uuid; v_exp uuid;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe Year End Loss');
  v_fy := public.create_fiscal_year(v_org, date '2025-01-01');

  v_bank  := pg_temp.yec_acct(v_org, 'bank');
  v_cap   := pg_temp.yec_acct(v_org, 'share_capital');
  v_sales := pg_temp.yec_acct(v_org, 'sales');
  v_exp   := pg_temp.yec_acct(v_org, 'operating_expense');

  perform pg_temp.yec_jv(v_org, 'LS-1', date '2025-01-02', v_bank, v_cap, 100000);
  perform pg_temp.yec_jv(v_org, 'LS-2', date '2025-03-31', v_bank, v_sales, 40000);
  perform pg_temp.yec_jv(v_org, 'LS-3', date '2025-03-31', v_exp, v_bank, 65000);

  perform public.close_fiscal_year(v_fy);

  perform pg_temp.check_eq('a loss lands in equity as a negative figure',
    pg_temp.yec_equity(v_org, date '2025-12-31')::text, '-25000.00');
  perform pg_temp.check_eq('and the profit and loss accounts are still nil',
    (select count(*) from public.report_profit_loss(
       v_org, date '2025-01-01', date '2025-12-31'))::text, '0');
end $$;

-- ---------------------------------------------------------------------
-- Who may, and a year with nothing in it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_clerk uuid; v_fy uuid; v_entry uuid;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe Year End Empty');
  v_clerk := pg_temp.another_user('yec-clerk@iakauntan.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'accounts_clerk') on conflict do nothing;
  v_fy := public.create_fiscal_year(v_org, date '2025-01-01');

  perform pg_temp.sign_in_as(v_clerk);
  begin
    perform public.close_fiscal_year(v_fy);
    raise exception 'a clerk closed the year';
  exception when insufficient_privilege then
    raise notice 'ok   a clerk cannot close a year';
  end;

  -- A year nobody traded in. It closes, and posts nothing -- an empty
  -- journal would be a line in the ledger saying nothing happened,
  -- which is what the absence of a line already says.
  perform pg_temp.sign_in_as(v_owner);
  v_entry := public.close_fiscal_year(v_fy);
  perform pg_temp.check_true('a year with no trading closes',
    (select status from public.fiscal_years where id = v_fy) = 'closed');
  perform pg_temp.check_true('and posts no journal at all', v_entry is null);
  perform pg_temp.check_eq('so nothing was added to the ledger',
    (select count(*) from public.gl_entries where org_id = v_org)::text, '0');

  -- And reopening one that posted nothing has nothing to reverse.
  perform pg_temp.check_true('reopening it reverses nothing',
    public.reopen_fiscal_year(v_fy) is null);
  perform pg_temp.check_eq('and it is open again',
    (select status from public.fiscal_years where id = v_fy), 'open');
end $$;

-- ---------------------------------------------------------------------
-- And the statement of changes in equity still adds up
--
-- `report_changes_in_equity` (0100) shows every equity account's
-- movement AND, separately, "Profit for the financial period" summed
-- from the profit and loss accounts. A closing journal moves BOTH of
-- those at once -- it credits equity and it zeroes the P&L -- so the
-- result could plausibly come out twice, or not at all.
--
-- It comes out once, because the two halves cancel exactly: the
-- closing entry's P&L legs net the period's trading to nil, so the
-- separate profit line falls away at the same moment Current Year
-- Earnings picks the figure up. The audit said this report was
-- "written around the closing journal existing"; this is the
-- assertion that it was, and that it still is.
--
-- Worth its own block because nothing else would report it. The
-- statement would simply be wrong by one line, on a document a
-- director signs.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_fy uuid;
  v_bank uuid; v_cap uuid; v_sales uuid; v_exp uuid;
  v_before numeric; v_after numeric; v_lines_before integer;
  v_profit_line integer; v_equity_line integer;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe Year End Equity');
  v_fy := public.create_fiscal_year(v_org, date '2025-01-01');

  v_bank  := pg_temp.yec_acct(v_org, 'bank');
  v_cap   := pg_temp.yec_acct(v_org, 'share_capital');
  v_sales := pg_temp.yec_acct(v_org, 'sales');
  v_exp   := pg_temp.yec_acct(v_org, 'operating_expense');

  perform pg_temp.yec_jv(v_org, 'EQ-1', date '2025-01-02', v_bank, v_cap, 100000);
  perform pg_temp.yec_jv(v_org, 'EQ-2', date '2025-06-30', v_bank, v_sales, 250000);
  perform pg_temp.yec_jv(v_org, 'EQ-3', date '2025-06-30', v_exp, v_bank, 180000);

  select coalesce(sum(closing_balance), 0), count(*)
    into v_before, v_lines_before
    from public.report_changes_in_equity(v_org, date '2025-01-01',
                                         date '2025-12-31');
  perform pg_temp.check_eq('before the close, equity plus the result',
    v_before::text, '170000.00');

  perform public.close_fiscal_year(v_fy);

  select coalesce(sum(closing_balance), 0) into v_after
    from public.report_changes_in_equity(v_org, date '2025-01-01',
                                         date '2025-12-31');
  perform pg_temp.check_eq('and the same total after it',
    v_after::text, v_before::text);

  -- Once, and under its own name. Counted rather than summed, because
  -- a report showing the result twice and a report showing it not at
  -- all both add up to something -- one to double and one to the bare
  -- capital -- and only the count says which.
  select count(*) filter (where name = 'Profit for the financial period'),
         count(*) filter (where code = '3300')
    into v_profit_line, v_equity_line
    from public.report_changes_in_equity(v_org, date '2025-01-01',
                                         date '2025-12-31');
  perform pg_temp.check_eq('the result is carried by Current Year Earnings',
    v_equity_line::text, '1');
  perform pg_temp.check_eq('and no longer by a separate profit line',
    v_profit_line::text, '0');
  perform pg_temp.check_eq('so the statement has the lines it had before',
    (select count(*)::text from public.report_changes_in_equity(
       v_org, date '2025-01-01', date '2025-12-31')),
    v_lines_before::text);
end $$;

-- ---------------------------------------------------------------------
-- And a closed year can still be filed
--
-- The statutory one. `fs_balance_check` is what the MBRS screen draws
-- its verdict from, and `supabase/tests/mbrs.sql` opens by explaining
-- that it balances IN A LEDGER WITH NO CLOSE -- `app.fs_cumulative_profit`
-- supplies the result that no equity account is holding yet.
--
-- A close moves that result into equity. If both halves then reported
-- it, a filing would be out by exactly one year's profit, and out in
-- the direction that reads as a healthier company. This is a document
-- lodged with SSM.
--
-- It is not out, because the two are complementary rather than
-- additive: the closing entry is posted ON the profit and loss
-- accounts, so `fs_cumulative_profit` falls to nil at the moment
-- equity picks the figure up. Asserted at the FILING rather than at
-- either half, because the filing is the thing somebody signs.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_fy uuid; v_filing uuid;
  v_bank uuid; v_cap uuid; v_sales uuid; v_exp uuid;
  b record; a record;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe Year End Filing');
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'mbrs', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  v_fy := public.create_fiscal_year(v_org, date '2025-01-01');

  v_bank  := pg_temp.yec_acct(v_org, 'bank');
  v_cap   := pg_temp.yec_acct(v_org, 'share_capital');
  v_sales := pg_temp.yec_acct(v_org, 'sales');
  v_exp   := pg_temp.yec_acct(v_org, 'operating_expense');

  perform pg_temp.yec_jv(v_org, 'FL-1', date '2025-01-02', v_bank, v_cap, 100000);
  perform pg_temp.yec_jv(v_org, 'FL-2', date '2025-06-30', v_bank, v_sales, 250000);
  perform pg_temp.yec_jv(v_org, 'FL-3', date '2025-06-30', v_exp, v_bank, 180000);

  insert into public.fs_filings
    (org_id, fy_start, fy_end, framework, audit_status, employee_count)
  values (v_org, date '2025-01-01', date '2025-12-31', 'mpers', 'audited', 3)
  returning id into v_filing;

  select * into b from public.fs_balance_check(v_filing);
  perform pg_temp.check_true('the filing balances before the close', b.balances);

  perform public.close_fiscal_year(v_fy);

  select * into a from public.fs_balance_check(v_filing);
  perform pg_temp.check_true('and still balances after it', a.balances);
  perform pg_temp.check_eq('with the same equity, not twice the profit',
    a.equity::text, b.equity::text);
  perform pg_temp.check_eq('and the same assets behind it',
    a.assets::text, b.assets::text);
  perform pg_temp.check_eq('so the difference is still nil',
    a.difference::text, '0.00');
end $$;

rollback;
