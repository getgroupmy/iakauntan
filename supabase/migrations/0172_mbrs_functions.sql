-- Preparing a set of accounts: map, check, freeze, lodge, export.
--
-- Two pieces of statutory arithmetic live here and both are asserted in
-- `supabase/tests/mbrs.sql`.
--
-- **Sections 258 and 259, Companies Act 2016.** A private company sends
-- its audited accounts to every member within six months of the
-- financial year end, and lodges them with the Registrar within thirty
-- days of that circulation. A public company lays them before the AGM
-- within six months (s.340) and lodges within thirty days of the meeting.
-- The outside limit is therefore six months **plus thirty days**, and it
-- is *not* a fixed 210 days: six months from 31 January is 31 July, and
-- from 31 August is 28 or 29 February. `corp_filing_types` already
-- carries 210 as the worst-case reminder offset, which is right for a
-- diary and wrong for the actual due date, so this computes the date.
--
-- **Practice Directive 3/2018.** Audit exemption on any one of three
-- grounds — dormant, zero-revenue, or threshold-qualified. Each is
-- tested over the current financial year *and the immediate past two*,
-- which is the part people get wrong: one good year does not exempt you.

-- ---------------------------------------------------------------------
-- The default mapping
--
-- `accounts.account_subtype` is already very nearly the taxonomy. This
-- is why `fs_account_map` is usually empty: it holds the deviations, and
-- a standard chart of accounts has none.
-- ---------------------------------------------------------------------
create or replace function app.fs_default_element(
  p_type app.account_type,
  p_subtype app.account_subtype)
returns text language sql immutable
set search_path = pg_catalog, public, app, pg_temp as $$
  select case p_subtype
    -- Assets. `accumulated_depreciation` deliberately lands on the same
    -- element as the cost it relieves: the face of the statement shows
    -- carrying amount, and the cost/depreciation split is a note.
    when 'fixed_asset'              then 'PropertyPlantAndEquipment'
    when 'accumulated_depreciation' then 'PropertyPlantAndEquipment'
    when 'other_asset'              then 'OtherNonCurrentAssets'
    when 'inventory'                then 'Inventories'
    when 'accounts_receivable'      then 'TradeAndOtherReceivables'
    when 'bank'                     then 'CashAndCashEquivalents'
    when 'cash'                     then 'CashAndCashEquivalents'
    when 'current_asset'            then 'OtherCurrentAssets'
    -- Liabilities
    when 'accounts_payable'         then 'TradeAndOtherPayables'
    when 'tax_payable'              then 'CurrentTaxLiabilities'
    when 'current_liability'        then 'OtherCurrentLiabilities'
    when 'long_term_liability'      then 'LoansAndBorrowings'
    when 'other_liability'          then 'OtherNonCurrentLiabilities'
    -- Equity. Drawings are a debit-natural equity account, so they come
    -- back negative from the balance sheet and correctly reduce retained
    -- earnings rather than needing a sign of their own.
    when 'share_capital'            then 'ShareCapital'
    when 'reserves'                 then 'Reserves'
    when 'retained_earnings'        then 'RetainedEarnings'
    when 'drawings'                 then 'RetainedEarnings'
    -- Profit or loss
    when 'sales'                    then 'Revenue'
    when 'cost_of_sales'            then 'CostOfSales'
    when 'other_income'             then 'OtherIncome'
    when 'operating_expense'        then 'AdministrativeExpenses'
    when 'payroll_expense'          then 'StaffCosts'
    when 'depreciation_expense'     then 'DepreciationAndAmortisation'
    when 'finance_cost'             then 'FinanceCosts'
    when 'other_expense'            then 'OtherOperatingExpenses'
    when 'tax_expense'              then 'TaxExpense'
    -- No subtype at all. Fall back on the type, so an account somebody
    -- created without one still lands somewhere defensible rather than
    -- vanishing off the face of the statement.
    else case p_type
      when 'asset'     then 'OtherCurrentAssets'
      when 'liability' then 'OtherCurrentLiabilities'
      when 'equity'    then 'Reserves'
      when 'revenue'   then 'OtherIncome'
      when 'expense'   then 'OtherOperatingExpenses'
    end
  end;
$$;

-- Which element an account actually reports under: the company's
-- override if it wrote one, the default otherwise.
create or replace function app.fs_element_for(
  p_org_id uuid, p_account_id uuid,
  p_type app.account_type, p_subtype app.account_subtype)
returns text language sql stable
set search_path = pg_catalog, public, app, pg_temp as $$
  select coalesce(
    (select m.element_code from public.fs_account_map m
      where m.org_id = p_org_id and m.account_id = p_account_id),
    app.fs_default_element(p_type, p_subtype));
$$;

-- ---------------------------------------------------------------------
-- Retained earnings as *presented*
--
-- There is no year-end close in this ledger — no routine sweeps revenue
-- and expense into retained earnings — so `report_balance_sheet` on its
-- own never balances. It is out by exactly the profit accumulated since
-- the company started trading.
--
-- That is fine for a management balance sheet and fatal for a statutory
-- one: a Statement of Financial Position lodged with SSM whose assets do
-- not equal its equity and liabilities is a rejected filing. So retained
-- earnings on the face of these accounts is the posted balance of the
-- retained-earnings accounts **plus** cumulative profit to the year end.
--
-- The early date is not a magic number, it is "before this company
-- existed" — `report_profit_loss` bounds on `entry_date between`, and no
-- Malaysian company on this deployment has a journal older than 1900.
-- ---------------------------------------------------------------------
create or replace function app.fs_cumulative_profit(
  p_org_id uuid, p_as_at date)
returns numeric language sql stable
set search_path = pg_catalog, public, app, pg_temp as $$
  select round(coalesce(sum(
           case when p.account_type = 'revenue' then p.amount else -p.amount end
         ), 0), 2)
    from public.report_profit_loss(p_org_id, date '1900-01-01', p_as_at) p;
$$;

-- ---------------------------------------------------------------------
-- The statements, built from the ledger
--
-- Read through `report_balance_sheet` and `report_profit_loss` rather
-- than counting `gl_lines` again. Those two decide what "balance" and
-- "for the period" mean, and a set of statutory accounts quoting a
-- different figure from the management reports is worse than no
-- statutory accounts at all.
-- ---------------------------------------------------------------------
create or replace function app.fs_figures_at(
  p_org_id uuid, p_fy_start date, p_fy_end date)
returns table (element_code text, amount numeric)
language sql stable
set search_path = pg_catalog, public, app, pg_temp as $$
  with sofp as (
    select app.fs_element_for(p_org_id, b.account_id,
                              b.account_type, b.account_subtype) as element,
           b.balance as amount
      from public.report_balance_sheet(p_org_id, p_fy_end) b),
  pl as (
    select app.fs_element_for(p_org_id, p.account_id,
                              p.account_type, p.account_subtype) as element,
           p.amount
      from public.report_profit_loss(p_org_id, p_fy_start, p_fy_end) p),
  -- The undistributed profit that no close has swept anywhere.
  undistributed as (
    select 'RetainedEarnings'::text as element,
           app.fs_cumulative_profit(p_org_id, p_fy_end) as amount),
  everything as (
    select * from sofp union all select * from pl
    union all select * from undistributed)
  select element, round(sum(amount), 2)
    from everything
   where element is not null
   group by element
  having round(sum(amount), 2) <> 0;
$$;

-- What the accounts will say, current year beside prior. Read-only: this
-- is the preview, and it moves when the ledger moves.
create or replace function public.fs_prepare(p_filing_id uuid)
returns table (
  element_code text, statement app.fs_statement, section text,
  label text, sort_order integer,
  current_amount numeric, prior_amount numeric)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare f public.fs_filings;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.is_org_member(f.org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    select e.code, e.statement, e.section, e.label, e.sort_order,
           round(coalesce(c.amount, 0), 2),
           round(coalesce(p.amount, 0), 2)
      from public.mbrs_elements e
      left join app.fs_figures_at(f.org_id, f.fy_start, f.fy_end) c
             on c.element_code = e.code
      -- The comparative: the twelve months ending the day before this
      -- year began. Not "last calendar year" — a company with a June
      -- year end compares against the June before.
      left join app.fs_figures_at(f.org_id,
                  (f.fy_start - interval '1 year')::date,
                  (f.fy_start - interval '1 day')::date) p
             on p.element_code = e.code
     where e.is_active
       and (e.framework is null or e.framework = f.framework)
       and (c.amount is not null or p.amount is not null)
     order by e.sort_order;
end $$;

-- ---------------------------------------------------------------------
-- Does it balance?
--
-- Asked before freezing rather than after lodging.
-- ---------------------------------------------------------------------
create or replace function public.fs_balance_check(p_filing_id uuid)
returns table (assets numeric, liabilities numeric, equity numeric,
               difference numeric, balances boolean)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare v_a numeric := 0; v_l numeric := 0; v_e numeric := 0;
begin
  select
    coalesce(sum(case when e.section in ('non_current_assets','current_assets')
                      then r.current_amount else 0 end), 0),
    coalesce(sum(case when e.section in ('current_liabilities',
                                         'non_current_liabilities')
                      then r.current_amount else 0 end), 0),
    coalesce(sum(case when e.section = 'equity'
                      then r.current_amount else 0 end), 0)
    into v_a, v_l, v_e
    from public.fs_prepare(p_filing_id) r
    join public.mbrs_elements e on e.code = r.element_code
   where e.statement = 'sofp';

  return query select v_a, v_l, v_e,
    round(v_a - v_l - v_e, 2), round(v_a - v_l - v_e, 2) = 0;
end $$;

-- ---------------------------------------------------------------------
-- Freeze
--
-- Copies the ledger's answer into `fs_figures` and stops asking. After
-- this the accounts say what they said on the day they were approved,
-- whatever anybody posts into the closed year afterwards.
-- ---------------------------------------------------------------------
create or replace function public.fs_freeze(p_filing_id uuid)
returns integer language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  f public.fs_filings;
  v_diff numeric;
  v_rows integer;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.can_write(f.org_id) or not app.has_module(f.org_id, 'mbrs') then
    raise exception 'You may not prepare these accounts'
      using errcode = '42501';
  end if;
  if f.status = 'lodged' then
    raise exception 'These accounts have been lodged' using errcode = '22023';
  end if;

  -- Refuse to freeze accounts that do not balance. A rejected MBRS
  -- submission is a wasted fee and a missed deadline, and the difference
  -- is almost always a journal posted after the year was reviewed.
  select difference into v_diff from public.fs_balance_check(p_filing_id);
  if v_diff <> 0 then
    raise exception
      'These accounts do not balance — assets differ from equity plus '
      'liabilities by %. Find it before freezing them.', v_diff
      using errcode = '22023';
  end if;

  -- Audited accounts need an auditor and an opinion. Exempt and
  -- unaudited ones do not, and asking for them would be asking somebody
  -- to invent an audit that did not happen.
  if f.audit_status = 'audited'
     and (f.auditor_name is null or f.opinion is null
          or f.audit_report_date is null) then
    raise exception
      'Audited accounts need the auditor, the opinion and the date of '
      'the audit report.' using errcode = '22023';
  end if;

  perform set_config('app.fs_writing', 'on', true);

  delete from public.fs_figures where filing_id = p_filing_id;
  insert into public.fs_figures
    (org_id, filing_id, element_code, current_amount, prior_amount)
  select f.org_id, p_filing_id, r.element_code,
         r.current_amount, r.prior_amount
    from public.fs_prepare(p_filing_id) r;
  get diagnostics v_rows = row_count;

  update public.fs_filings
     set status = 'frozen', frozen_at = now(), frozen_by = auth.uid()
   where id = p_filing_id;

  perform set_config('app.fs_writing', 'off', true);
  return v_rows;
end $$;

create or replace function public.fs_unfreeze(p_filing_id uuid)
returns void language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare f public.fs_filings;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  -- Deliberately stricter than freezing. Unfreezing is how a mistake
  -- gets fixed and also how a reviewed set of accounts quietly becomes a
  -- different set of accounts, so it is an administrator's decision.
  if not app.can_admin(f.org_id) then
    raise exception 'Only an administrator can reopen these accounts'
      using errcode = '42501';
  end if;
  if f.status = 'lodged' then
    raise exception
      'These accounts have been lodged with SSM and cannot be reopened. '
      'A correction is a fresh set, not an edit to this one.'
      using errcode = '42501';
  end if;

  perform set_config('app.fs_writing', 'on', true);
  delete from public.fs_figures where filing_id = p_filing_id;
  update public.fs_filings
     set status = 'draft', frozen_at = null, frozen_by = null
   where id = p_filing_id;
  perform set_config('app.fs_writing', 'off', true);
end $$;

-- ---------------------------------------------------------------------
-- Lodge
--
-- Records what happened at mPortal. Nothing here talks to SSM — see the
-- header of `0171` — so this is a person writing down a reference they
-- were given, and the only evidence in the system that a filing exists.
-- ---------------------------------------------------------------------
create or replace function public.fs_lodge(
  p_filing_id uuid, p_reference text, p_lodged_on date default current_date)
returns void language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare f public.fs_filings;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.can_write(f.org_id) or not app.has_module(f.org_id, 'mbrs') then
    raise exception 'You may not lodge these accounts' using errcode = '42501';
  end if;
  if f.status <> 'frozen' then
    raise exception
      'Freeze the accounts before recording the lodgement — what was '
      'filed has to be a fixed set of figures.' using errcode = '22023';
  end if;
  if coalesce(trim(p_reference), '') = '' then
    raise exception 'Record the MBRS reference mPortal gave you'
      using errcode = '22023';
  end if;

  perform set_config('app.fs_writing', 'on', true);
  update public.fs_filings
     set status = 'lodged', lodged_on = p_lodged_on,
         mbrs_reference = trim(p_reference)
   where id = p_filing_id;
  perform set_config('app.fs_writing', 'off', true);
end $$;

-- ---------------------------------------------------------------------
-- The export
--
-- The rows that go into mTool. From `fs_figures` once frozen — which is
-- the point of freezing — and live before that, so a preparer can see
-- the shape of it while still working.
-- ---------------------------------------------------------------------
create or replace function public.fs_export(p_filing_id uuid)
returns table (
  statement app.fs_statement, section text, element_code text,
  label text, current_amount numeric, prior_amount numeric, is_frozen boolean)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare f public.fs_filings;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.is_org_member(f.org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  if f.status = 'draft' then
    return query
      select r.statement, r.section, r.element_code, r.label,
             r.current_amount, r.prior_amount, false
        from public.fs_prepare(p_filing_id) r
       order by r.sort_order;
  else
    return query
      select e.statement, e.section, g.element_code, e.label,
             g.current_amount, g.prior_amount, true
        from public.fs_figures g
        join public.mbrs_elements e on e.code = g.element_code
       where g.filing_id = p_filing_id
       order by e.sort_order;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Sections 258 and 259
--
-- Six calendar months, then thirty days. Written as an interval rather
-- than a day count because six months is not a fixed number of days and
-- a deadline that is out by a day is a deadline that is out.
-- ---------------------------------------------------------------------
create or replace function public.fs_deadlines(p_filing_id uuid)
returns table (
  circulate_by date, lodge_by date, outside_limit date,
  circulated_on date, lodged_on date,
  days_left integer, is_late boolean, basis text)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  f public.fs_filings;
  v_public boolean;
  v_circulate date;
  v_lodge date;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.is_org_member(f.org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  select o.entity_type = 'bhd' into v_public
    from public.organizations o where o.id = f.org_id;

  v_circulate := (f.fy_end + interval '6 months')::date;

  -- Thirty days from what actually happened, falling back to thirty days
  -- from the deadline when it has not happened yet. A company that
  -- circulated early owes its lodgement early — the clock runs from the
  -- act, not from the entitlement.
  v_lodge := coalesce(f.circulated_on, v_circulate) + 30;

  return query select
    v_circulate,
    v_lodge,
    (v_circulate + 30)::date,
    f.circulated_on,
    f.lodged_on,
    (v_lodge - current_date)::integer,
    f.lodged_on is null and current_date > v_lodge,
    case when coalesce(v_public, false)
      then 'CA 2016 s.340 — laid at the AGM within six months of the year '
           'end — and s.259, lodged within thirty days of that meeting.'
      else 'CA 2016 s.258 — circulated to members within six months of the '
           'year end — and s.259, lodged within thirty days of circulation.'
    end;
end $$;

-- ---------------------------------------------------------------------
-- Practice Directive 3/2018
--
-- Three grounds, each tested across the current financial year and the
-- immediate past two. One row per ground, so the screen can show why the
-- two that do not apply do not apply — which is the question an
-- accountant actually asks.
--
-- Thresholds, for the record: zero-revenue companies need total assets
-- not exceeding RM300,000 in all three years; threshold-qualified
-- companies need revenue not exceeding RM100,000, total assets not
-- exceeding RM300,000, and not more than five employees at the end of
-- each of the three years.
-- ---------------------------------------------------------------------
create or replace function public.fs_audit_exemption(p_filing_id uuid)
returns table (ground text, qualifies boolean, reason text)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  f public.fs_filings;
  v_start date; v_end date;
  v_rev numeric; v_assets numeric; v_staff integer;
  v_max_rev numeric := 0; v_max_assets numeric := 0; v_max_staff integer := 0;
  v_any_movement boolean := false;
  v_staff_known boolean := true;
  i integer;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.is_org_member(f.org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  -- This year and the two before it.
  for i in 0..2 loop
    v_start := (f.fy_start - (i || ' years')::interval)::date;
    v_end := (f.fy_end - (i || ' years')::interval)::date;

    select coalesce(sum(p.amount), 0) into v_rev
      from public.report_profit_loss(f.org_id, v_start, v_end) p
     where p.account_type = 'revenue';

    select coalesce(sum(b.balance), 0) into v_assets
      from public.report_balance_sheet(f.org_id, v_end) b
     where b.account_type = 'asset';

    -- Dormancy is about *any* accounting transaction, not about revenue.
    -- A company that paid a filing fee out of its bank account had a
    -- transaction and is not dormant.
    if exists (select 1 from public.gl_entries e
                where e.org_id = f.org_id and e.status = 'posted'
                  and e.entry_date between v_start and v_end) then
      v_any_movement := true;
    end if;

    -- Headcount comes off each year's own filing row. Guessing it from
    -- today's employee list would answer a question about 2023 with a
    -- fact about 2026.
    select g.employee_count into v_staff
      from public.fs_filings g
     where g.org_id = f.org_id and g.fy_end = v_end;
    if v_staff is null then v_staff_known := false;
                       else v_max_staff := greatest(v_max_staff, v_staff);
    end if;

    v_max_rev := greatest(v_max_rev, v_rev);
    v_max_assets := greatest(v_max_assets, v_assets);
  end loop;

  return query values
    ('dormant',
     not v_any_movement,
     case when not v_any_movement
       then 'No accounting transaction in this financial year or the two '
            'before it.'
       else 'There were accounting transactions in the three years to '
            || f.fy_end || '.' end),

    ('zero_revenue',
     v_max_rev = 0 and v_max_assets <= 300000,
     case when v_max_rev = 0 and v_max_assets <= 300000
       then 'No revenue in any of the three years, and total assets never '
            'above RM300,000.'
       when v_max_rev > 0
       then 'Revenue reached ' || to_char(v_max_rev, 'FM999,999,999.00')
            || ' in one of the three years.'
       else 'Total assets reached '
            || to_char(v_max_assets, 'FM999,999,999.00')
            || ', above the RM300,000 ceiling.' end),

    ('threshold_qualified',
     v_staff_known and v_max_rev <= 100000
       and v_max_assets <= 300000 and v_max_staff <= 5,
     case when not v_staff_known
       then 'Cannot tell — the headcount at the year end is missing on '
            'one of the three years. Record it on each filing.'
       when v_max_rev > 100000
       then 'Revenue reached ' || to_char(v_max_rev, 'FM999,999,999.00')
            || ', above the RM100,000 ceiling.'
       when v_max_assets > 300000
       then 'Total assets reached '
            || to_char(v_max_assets, 'FM999,999,999.00')
            || ', above the RM300,000 ceiling.'
       when v_max_staff > 5
       then 'Headcount reached ' || v_max_staff || ', above the five '
            'employee ceiling.'
       else 'Revenue, total assets and headcount were all within the '
            'thresholds in each of the three years.' end);
end $$;

-- ---------------------------------------------------------------------
-- Grants
--
-- `0165`'s event trigger has already stripped PUBLIC and anon from every
-- function above. These put back what `authenticated` needs.
-- ---------------------------------------------------------------------
grant execute on function public.fs_prepare(uuid) to authenticated;
grant execute on function public.fs_balance_check(uuid) to authenticated;
grant execute on function public.fs_freeze(uuid) to authenticated;
grant execute on function public.fs_unfreeze(uuid) to authenticated;
grant execute on function public.fs_lodge(uuid, text, date) to authenticated;
grant execute on function public.fs_export(uuid) to authenticated;
grant execute on function public.fs_deadlines(uuid) to authenticated;
grant execute on function public.fs_audit_exemption(uuid) to authenticated;
