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

-- ---------------------------------------------------------------------
-- 6: TWO YEARS, closed in order and reopened in order
--
-- A sweep of both functions found fifteen mutants nothing here could
-- kill, and most of them had one cause: **every block above closes
-- exactly one year.** Both ordering rules have three conjuncts each --
-- the company, the status, and the date comparison -- and only the date
-- comparison can be stood on by a fixture that never closes a second
-- year.
--
--   close:  no EARLIER year of THIS company may still be OPEN
--   reopen: no LATER year of THIS company may still be CLOSED
--
-- Dropping `status` from the first means an earlier year that is
-- properly CLOSED blocks for ever -- a company could never close its
-- second year. Dropping the reopen rule entirely means a 2025 can be
-- reopened under a closed 2026, which is the state the rule's own
-- message describes: "a later year was closed on the strength of this
-- one being shut".
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_clerk uuid;
  v_early_org uuid; v_late_org uuid;
  v_fy25 uuid; v_fy26 uuid;
  v_bank uuid; v_cap uuid; v_sales uuid; v_exp uuid;
  v_e25 uuid; v_e26 uuid; v_rev uuid;
  v_moved int;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe Year End Two');
  v_fy25 := public.create_fiscal_year(v_org, date '2025-01-01');
  v_fy26 := public.create_fiscal_year(v_org, date '2026-01-01');

  v_bank  := pg_temp.yec_acct(v_org, 'bank');
  v_cap   := pg_temp.yec_acct(v_org, 'share_capital');
  v_sales := pg_temp.yec_acct(v_org, 'sales');
  v_exp   := pg_temp.yec_acct(v_org, 'operating_expense');

  perform pg_temp.yec_jv(v_org, 'TW-1', date '2025-01-02', v_bank, v_cap, 100000);
  perform pg_temp.yec_jv(v_org, 'TW-2', date '2025-06-30', v_bank, v_sales, 90000);
  perform pg_temp.yec_jv(v_org, 'TW-3', date '2025-06-30', v_exp, v_bank, 30000);
  perform pg_temp.yec_jv(v_org, 'TW-4', date '2026-06-30', v_bank, v_sales, 50000);
  perform pg_temp.yec_jv(v_org, 'TW-5', date '2026-06-30', v_exp, v_bank, 20000);

  -- Another company whose year starts STRICTLY EARLIER than ours and is
  -- still open. Every other company in this file has a year starting
  -- 2025-01-01, which is not `< 2025-01-01`, so dropping the org scope
  -- from the earlier-year rule changed nothing anybody could see. A
  -- 2024 belonging to somebody else does.
  v_early_org := pg_temp.test_org('Probe Year End Stranger Early');
  perform public.create_fiscal_year(v_early_org, date '2024-01-01');
  perform pg_temp.sign_in_as(v_owner);

  -- ------------------------------------------------------------------
  -- 2025 closes, then 2026 closes BEHIND it
  -- ------------------------------------------------------------------
  -- Counted BEFORE the close, because the close is what empties the
  -- report: after it the row count is zero and "one line per account
  -- that moved" would read as one.
  select count(*) into v_moved
    from public.report_profit_loss(v_org, date '2025-01-01', date '2025-12-31');

  v_e25 := public.close_fiscal_year(v_fy25);
  perform pg_temp.check_true('the first year closes', v_e25 is not null);

  -- The assertion the earlier-year rule's `status` conjunct needs: a
  -- company must be able to close its SECOND year once the first is
  -- properly shut. Nothing in this file had ever done it.
  v_e26 := public.close_fiscal_year(v_fy26);
  perform pg_temp.check_true(
    'and the second closes behind it, because the first is shut and not merely gone',
    v_e26 is not null);
  perform pg_temp.check_eq('each year holds its own result',
    (select credit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_e25 and a.code = '3300'), 60000.00);
  perform pg_temp.check_eq('and the second holds only its own',
    (select credit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_e26 and a.code = '3300'), 30000.00);

  -- ------------------------------------------------------------------
  -- The closing journal's own shape
  -- ------------------------------------------------------------------
  -- The DATE. A close dated the first day of the year puts the sweep in
  -- a period the year's own trading had not happened in yet, and every
  -- figure asserted above would be identical.
  perform pg_temp.check_eq('the close is dated the last day of the year',
    (select entry_date from public.gl_entries where id = v_e25)::text,
    '2025-12-31');
  perform pg_temp.check_eq('and names the year it closed',
    (select description from public.gl_entries where id = v_e25),
    'Year-end close: 2025');

  -- The LINE COUNT, which is the only thing that can see a line of two
  -- zeroes: such a line BALANCES, so no figure asserted anywhere else
  -- could tell. 2025 traded through exactly two P&L accounts, so the
  -- journal is those two plus the result.
  perform pg_temp.check_eq('the sweep is one line per account that MOVED',
    (select count(*) from public.gl_lines where entry_id = v_e25),
    v_moved + 1);
  perform pg_temp.check_eq('which for this year is two accounts and a result',
    v_moved + 1, 3);
  -- What this does NOT prove, said here so the next sweep does not
  -- re-chase it: `close_fiscal_year`'s own `where p.amount <> 0` is an
  -- EQUIVALENT mutation target. `report_profit_loss` already ends in
  -- `having sum(l.debit - l.credit) <> 0`, and the report's `amount` is
  -- that same sum with the sign flipped for revenue -- a flip that
  -- cannot change whether something is zero. So the filter can never
  -- exclude a row the report returned, and widening it changes nothing.
  --
  -- It is still worth having, and this count is still worth asserting,
  -- because the filter is belt-and-braces resting on a property of a
  -- DIFFERENT function. Drop the `having` from report_profit_loss and
  -- the filter starts mattering the same day -- which is exactly the
  -- sort of coupling a line count notices and a balance check cannot.

  -- WHO and WHEN, neither of which anything read back. A year that says
  -- it is closed and cannot say when or by whom is a year nobody can
  -- be held to.
  perform pg_temp.check_true('a closed year records when it was closed',
    (select closed_at is not null from public.fiscal_years where id = v_fy25));
  perform pg_temp.check_true('and who closed it',
    (select closed_by from public.fiscal_years where id = v_fy25) = v_owner);

  -- ------------------------------------------------------------------
  -- And it reopens in the opposite order
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused(
    'the earlier year cannot reopen under a later one still closed',
    format('select public.reopen_fiscal_year(%L)', v_fy25),
    'Reopen 2026 first. A later year was closed on the strength of this '
    'one being shut.', '23514');

  -- Another company whose year starts STRICTLY LATER than ours and is
  -- CLOSED, for the same reason as the 2024 above: without one,
  -- dropping the org scope from the later-year rule finds nothing.
  v_late_org := pg_temp.test_org('Probe Year End Stranger Late');
  perform public.close_fiscal_year(
    public.create_fiscal_year(v_late_org, date '2027-01-01'));
  perform pg_temp.sign_in_as(v_owner);

  v_rev := public.reopen_fiscal_year(v_fy26);
  perform pg_temp.check_true('the later year reopens', v_rev is not null);
  perform pg_temp.check_eq('and its reversal is dated the year end too',
    (select entry_date from public.gl_entries where id = v_rev)::text,
    '2026-12-31');
  perform pg_temp.check_true('a reopened year no longer says when it was closed',
    (select closed_at is null from public.fiscal_years where id = v_fy26));
  perform pg_temp.check_true('nor who closed it',
    (select closed_by is null from public.fiscal_years where id = v_fy26));
  perform pg_temp.check_true('nor points at the journal that closed it',
    (select closing_entry_id is null
       from public.fiscal_years where id = v_fy26));

  perform pg_temp.check_true('and then the earlier one reopens',
    public.reopen_fiscal_year(v_fy25) is not null);
  perform pg_temp.check_eq('with both years open again',
    (select count(*) from public.fiscal_years
      where org_id = v_org and status = 'open'), 2);

  -- ------------------------------------------------------------------
  -- Who may reopen
  -- ------------------------------------------------------------------
  -- The close's admin guard was asserted; the reopen's was not, and a
  -- reopen posts a journal and unlocks a filed year, so it is the more
  -- dangerous of the two.
  v_clerk := pg_temp.another_user('yec-two-clerk@iakauntan.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'accounts_clerk') on conflict do nothing;
  perform public.close_fiscal_year(v_fy25);
  perform pg_temp.sign_in_as(v_clerk);
  begin
    perform public.reopen_fiscal_year(v_fy25);
    perform pg_temp.sign_in_as(v_owner);
    raise exception 'FAIL: a clerk reopened a closed year'
      using errcode = 'P0004';
  exception
    when sqlstate 'P0004' then raise;
    when insufficient_privilege then
      perform pg_temp.sign_in_as(v_owner);
      raise notice 'ok   a clerk cannot reopen a year either';
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('and the year is still closed',
    (select status from public.fiscal_years where id = v_fy25), 'closed');

  raise notice 'ok   two years, in order, and back out of it in the other order';
end $$;

-- ---------------------------------------------------------------------
-- 7: a BREAK-EVEN year
--
-- `if v_profit <> 0` is what keeps a result line off the journal when a
-- year made neither a profit nor a loss. Every other block here traded
-- at a profit or a loss, so widening that test to `is not null` -- which
-- posts a line of two zeroes to equity -- changed no figure and no
-- balance. The journal still balances. Only the line count sees it.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_fy uuid; v_entry uuid;
  v_bank uuid; v_cap uuid; v_sales uuid; v_exp uuid;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Probe Year End Break Even');
  v_fy := public.create_fiscal_year(v_org, date '2025-01-01');

  v_bank  := pg_temp.yec_acct(v_org, 'bank');
  v_cap   := pg_temp.yec_acct(v_org, 'share_capital');
  v_sales := pg_temp.yec_acct(v_org, 'sales');
  v_exp   := pg_temp.yec_acct(v_org, 'operating_expense');

  perform pg_temp.yec_jv(v_org, 'BE-1', date '2025-01-02', v_bank, v_cap, 50000);
  perform pg_temp.yec_jv(v_org, 'BE-2', date '2025-04-30', v_bank, v_sales, 80000);
  perform pg_temp.yec_jv(v_org, 'BE-3', date '2025-04-30', v_exp, v_bank, 80000);

  v_entry := public.close_fiscal_year(v_fy);
  perform pg_temp.check_true('a break-even year closes and posts a journal',
    v_entry is not null);
  perform pg_temp.check_eq('with a line for each account that traded',
    (select count(*) from public.gl_lines where entry_id = v_entry), 2);
  perform pg_temp.check_eq('and NO line to equity, because there is no result',
    (select count(*) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '3300'), 0);
  perform pg_temp.check_eq('equity is untouched',
    pg_temp.yec_equity(v_org, date '2025-12-31')::text, '0.00');
  perform pg_temp.check_eq('and the profit and loss accounts are nil',
    (select count(*) from public.report_profit_loss(
       v_org, date '2025-01-01', date '2025-12-31'))::text, '0');

  raise notice 'ok   a year that broke even sweeps two accounts and no result';
end $$;


rollback;
