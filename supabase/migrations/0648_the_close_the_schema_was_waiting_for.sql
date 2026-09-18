-- =====================================================================
-- The year-end close the schema was already waiting for
--
-- `docs/gap-analysis/oca-gap-report.md` lists A1, "Year-end closing
-- entries", as Partial: "Nothing posts the closing journal. The chart
-- and the equity report both anticipate one; it is a manual journal
-- today."
--
-- It is more than the chart and the equity report. FOUR separate places
-- were built for a close that was never written:
--
--   * `app.journal_source` has a `year_end_close` member. Nothing
--     writes it.
--   * `fiscal_years` has `status`, `closed_at` and `closed_by`. Nothing
--     sets any of them.
--   * the seeded chart carries `3300 Current Year Earnings` beside
--     `3200 Retained Earnings`. Nothing posts to 3300.
--   * `report_cash_flow` already excludes `e.source <> 'year_end_close'`
--     so that a closing journal would not read as a movement of cash.
--
-- And `supabase/tests/mbrs.sql` opens by naming the consequence: "There
-- is no year-end close in this ledger, so `report_balance_sheet` is out
-- by cumulative profit." `app.fs_cumulative_profit` exists to make the
-- statutory accounts balance in spite of it.
--
-- ## What a close does
--
-- Every revenue and expense account is brought to nil by an entry dated
-- the last day of the year, and the difference -- the year's profit or
-- loss -- lands in equity. After it, the balance sheet stands on its
-- own: retained earnings is a figure the ledger states rather than one
-- a report has to work out.
--
-- To 3300 and not straight to 3200, because that is what the seeded
-- chart's two accounts are FOR. The year's result sits in Current Year
-- Earnings where a director can see it as this year's; moving it into
-- Retained Earnings is a separate decision, usually taken with the
-- dividend, and is a manual journal on purpose -- it is an
-- appropriation, not arithmetic.
--
-- ## It composes with the statutory accounts rather than fighting them
--
-- `app.fs_cumulative_profit` sums the profit and loss FROM 1900, and a
-- closing entry is posted on the P&L accounts themselves. So a closed
-- year nets to nil there and is carried by the equity balance instead,
-- and `app.fs_figures_at` adds the two together. Nothing is counted
-- twice, whether a company closes its years or never does. That is not
-- luck: `report_cash_flow`'s exclusion says somebody meant it.
--
-- ## Closing in order, and reopening in reverse
--
-- A year cannot be closed while an earlier one is open -- the earlier
-- year's result would still be sitting in the P&L accounts and would be
-- swept into the wrong year. And a year cannot be reopened while a
-- later one is closed, for the same reason read backwards.
--
-- Reopening REVERSES rather than deletes. This ledger is append-only
-- everywhere else and there is no reason for the one entry a director
-- signed off to be the exception.
-- =====================================================================

-- Which entry closed this year, so reopening knows what to reverse.
--
-- On the year rather than found by searching for the last
-- `year_end_close` entry on the end date: a year closed, reopened and
-- closed again has several, and picking the wrong one reverses a
-- reversal.
-- The reference is COMPOSITE, on (org_id, closing_entry_id), and
-- `tenant_foreign_keys.sql` is what says it has to be: a bare
-- `references gl_entries(id)` names a row without saying whose company
-- it is, so a fiscal year could point at another tenant's journal and
-- nothing in the schema would object. The local runner refused this
-- migration on its first draft, which is the whole reason that gate
-- exists.
alter table public.fiscal_years
  add column if not exists closing_entry_id uuid;

do $fk$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'fiscal_years_closing_entry_same_org') then
    alter table public.fiscal_years
      add constraint fiscal_years_closing_entry_same_org
      foreign key (org_id, closing_entry_id)
      references public.gl_entries (org_id, id);
  end if;
end $fk$;

comment on column public.fiscal_years.closing_entry_id is
  'The journal that brought the year''s revenue and expenses to nil. '
  'Null on an open year, and on a closed year that had nothing to '
  'close. See 0648.';

-- ---------------------------------------------------------------------
-- Where the year's result goes
-- ---------------------------------------------------------------------
create or replace function app.current_year_earnings_account(p_org_id uuid)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare v_id uuid; v_parent uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '3300' and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  -- 0532's shape, as every other account resolver here uses it: a
  -- retired account of this code is brought back rather than posted
  -- to, because the chart holds one account per code and an insert
  -- would raise on the unique key.
  v_id := app.revive_account(p_org_id, '3300');
  if v_id is not null then
    return v_id;
  end if;

  select id into v_parent from public.accounts
   where org_id = p_org_id and code = '3000';

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, parent_id,
     is_group, is_system, is_active)
  values (p_org_id, '3300', 'Current Year Earnings', 'equity',
          'retained_earnings', v_parent, false, true, true)
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Close it
-- ---------------------------------------------------------------------
create or replace function public.close_fiscal_year(p_fiscal_year_id uuid)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  f public.fiscal_years;
  v_earlier text;
  v_equity uuid;
  v_lines jsonb := '[]'::jsonb;
  v_profit numeric(18,2) := 0;
  v_entry uuid;
  r record;
begin
  select * into f from public.fiscal_years where id = p_fiscal_year_id;
  if not found then
    raise exception 'No such fiscal year' using errcode = 'P0002';
  end if;

  -- An owner or an admin, the same pair `set_fiscal_period_status`
  -- requires. Closing a year is the same kind of act as locking a
  -- period and a larger one.
  if not app.can_admin(f.org_id) then
    raise exception 'Only an owner or an administrator may close a year'
      using errcode = '42501';
  end if;

  if f.status <> 'open' then
    raise exception '% is already %', f.name, f.status using errcode = '23514';
  end if;

  select string_agg(y.name, ', ' order by y.start_date) into v_earlier
    from public.fiscal_years y
   where y.org_id = f.org_id and y.status = 'open'
     and y.start_date < f.start_date;
  if v_earlier is not null then
    raise exception
      'Close % first. An earlier year still open holds its own result in '
      'the profit and loss accounts, and closing this one would sweep it '
      'into the wrong year.', v_earlier using errcode = '23514';
  end if;

  v_equity := app.current_year_earnings_account(f.org_id);

  -- One definition of what a profit and loss account is worth, shared
  -- with every report that says so. `report_profit_loss` returns
  -- revenue as credit-less-debit and expense as debit-less-credit, so
  -- both come back POSITIVE in their natural direction and each is
  -- brought to nil by an entry on the other side.
  for r in
    select p.account_id, p.code, p.account_type, p.amount
      from public.report_profit_loss(f.org_id, f.start_date, f.end_date) p
     where p.amount <> 0
     order by p.code
  loop
    v_lines := v_lines || jsonb_build_object(
      'account_id', r.account_id,
      'description', 'Year-end close ' || f.name,
      'debit',  case when r.account_type = 'revenue' then r.amount else 0 end,
      'credit', case when r.account_type = 'revenue' then 0 else r.amount end);
    v_profit := v_profit
      + case when r.account_type = 'revenue' then r.amount else -r.amount end;
  end loop;

  if jsonb_array_length(v_lines) > 0 then
    -- The result, on the other side of the same entry. A profit is a
    -- credit to equity and a loss a debit, which is the whole of the
    -- arithmetic: the revenue debits and expense credits already
    -- balance against each other except by exactly this figure.
    if v_profit <> 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', v_equity,
        'description', case when v_profit > 0 then 'Profit for ' || f.name
                            else 'Loss for ' || f.name end,
        'debit',  case when v_profit < 0 then -v_profit else 0 end,
        'credit', case when v_profit > 0 then v_profit else 0 end);
    end if;

    -- Through the ordinary door. The period has to be OPEN for this to
    -- post, which is the right order of operations -- close the year,
    -- then lock its periods -- and is enforced rather than assumed
    -- because `app.create_gl_entry_internal` refuses a period that is
    -- not open and this does not go around it.
    v_entry := app.create_gl_entry_internal(
      f.org_id, f.end_date, 'year_end_close', v_lines,
      'Year-end close: ' || f.name);
  end if;

  update public.fiscal_years
     set status = 'closed', closed_at = now(), closed_by = auth.uid(),
         closing_entry_id = v_entry, updated_at = now()
   where id = f.id;

  return v_entry;
end $$;

comment on function public.close_fiscal_year(uuid) is
  'Brings every revenue and expense account to nil at the year end and '
  'puts the result in 3300 Current Year Earnings. Refuses while an '
  'earlier year is open. Returns the journal, or null where the year '
  'had nothing to close. See 0648.';

grant execute on function public.close_fiscal_year(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- And undo it
-- ---------------------------------------------------------------------
create or replace function public.reopen_fiscal_year(p_fiscal_year_id uuid)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  f public.fiscal_years;
  v_later text;
  v_lines jsonb := '[]'::jsonb;
  v_entry uuid;
  r record;
begin
  select * into f from public.fiscal_years where id = p_fiscal_year_id;
  if not found then
    raise exception 'No such fiscal year' using errcode = 'P0002';
  end if;
  if not app.can_admin(f.org_id) then
    raise exception 'Only an owner or an administrator may reopen a year'
      using errcode = '42501';
  end if;
  if f.status <> 'closed' then
    raise exception '% is %, not closed', f.name, f.status
      using errcode = '23514';
  end if;

  select string_agg(y.name, ', ' order by y.start_date desc) into v_later
    from public.fiscal_years y
   where y.org_id = f.org_id and y.status = 'closed'
     and y.start_date > f.start_date;
  if v_later is not null then
    raise exception
      'Reopen % first. A later year was closed on the strength of this '
      'one being shut.', v_later using errcode = '23514';
  end if;

  -- Reversed, not deleted. Every other undo in this ledger posts the
  -- opposite entry and leaves both standing, and the one journal a
  -- director signed off on is the last place to start deleting.
  if f.closing_entry_id is not null then
    for r in
      select l.account_id, l.debit, l.credit
        from public.gl_lines l
       where l.entry_id = f.closing_entry_id
       order by l.line_no
    loop
      v_lines := v_lines || jsonb_build_object(
        'account_id', r.account_id,
        'description', 'Reopened ' || f.name,
        'debit', r.credit, 'credit', r.debit);
    end loop;

    v_entry := app.create_gl_entry_internal(
      f.org_id, f.end_date, 'year_end_close', v_lines,
      'Year-end close reversed: ' || f.name);
  end if;

  update public.fiscal_years
     set status = 'open', closed_at = null, closed_by = null,
         closing_entry_id = null, updated_at = now()
   where id = f.id;

  return v_entry;
end $$;

comment on function public.reopen_fiscal_year(uuid) is
  'Reverses the closing journal and opens the year again. Refuses while '
  'a later year is closed. See 0648.';

grant execute on function public.reopen_fiscal_year(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare v_body text;
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'fiscal_years'
       and column_name = 'closing_entry_id') then
    raise exception 'fiscal_years has nowhere to record the closing journal';
  end if;

  -- And that it names the company as well as the row. A single-column
  -- reference here is a fiscal year that can point at another tenant's
  -- journal.
  if not exists (
    select 1 from pg_constraint
     where conname = 'fiscal_years_closing_entry_same_org'
       and cardinality(conkey) = 2) then
    raise exception
      'the closing journal is referenced without naming the company';
  end if;

  v_body := pg_get_functiondef('public.close_fiscal_year(uuid)'::regprocedure);
  if v_body not like '%year_end_close%' then
    raise exception 'the close does not mark its journal as a year-end close';
  end if;
  if v_body not like '%create_gl_entry_internal%' then
    raise exception 'the close does not post through the ordinary door';
  end if;
  if v_body not like '%can_admin%' then
    raise exception 'anybody may close a year';
  end if;

  v_body := pg_get_functiondef('public.reopen_fiscal_year(uuid)'::regprocedure);
  if v_body like '%delete from public.gl_%' then
    raise exception 'reopening deletes rather than reverses';
  end if;

  foreach v_body in array array['close_fiscal_year', 'reopen_fiscal_year'] loop
    if not has_function_privilege('authenticated',
        'public.' || v_body || '(uuid)', 'execute') then
      raise exception '% is not executable by authenticated', v_body;
    end if;
  end loop;
end $do$;
