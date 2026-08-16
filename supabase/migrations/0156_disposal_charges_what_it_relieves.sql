-- =====================================================================
-- iAkauntan :: 0156 a disposal charges what it relieves
--
-- `docs/unreachable.md` has carried this line for some time:
--
--   **Depreciation schedule.** `depreciation_runs` and
--   `depreciation_entries` are written by the run and never read, so the
--   per-asset history the auditor asks for is not printable.
--
-- 0084's own header said the same thing on the day it landed — "the
-- auditor asks for the schedule by name" — and then did not build it.
-- Going to build it is what turned up the reason it matters.
--
-- ---------------------------------------------------------------------
-- What the schedule would have shown
--
-- A van costing 12,000 over five years, depreciated to 31 March and sold
-- on 30 June for 10,000. `dispose_fixed_asset` brings the charge up to
-- the day it left — 1,200 rather than the 600 posted in March — and
-- relieves account 1590 of the full 1,200. Only 600 was ever credited
-- there.
--
--   1590 Accumulated Depreciation   600 debit, against no asset
--   6400 Depreciation                600, for six months of ownership
--   Total charged to profit        1,400, on a van that cost 2,000 to own
--
-- The 600 is not misclassified. It is missing: the catch-up is relieved
-- from the balance sheet without ever being charged to the profit and
-- loss, so profit is overstated by exactly the amount left stranded in
-- 1590. Every disposal of an asset not depreciated right up to its
-- disposal date does this, which in practice is every disposal that does
-- not happen to fall on a run date.
--
-- The fix is one pair of lines. The catch-up is charged to depreciation
-- expense and credited to accumulated depreciation before the disposal
-- relieves it, so 1590 is relieved of what it holds and the profit and
-- loss carries six months of van. The gain or loss is unchanged: it was
-- always computed from the caught-up figure, which was the one honest
-- part of the arrangement.
--
-- The catch-up is also written to `depreciation_entries` against a run
-- of its own, dated the day of disposal and pointing at the disposal
-- journal. Without that the per-asset history below has a hole in it
-- precisely where somebody would be looking — the last thing that
-- happened to the asset — and the movement schedule's charge for the
-- year would not tie to the sum of its own entries.
--
-- ---------------------------------------------------------------------
-- Gains and losses had their own accounts, and they were not these
--
-- 0084 posts a gain on disposal to 4920 and a loss to 6500. In the
-- seeded chart those are Foreign Exchange Gain and Foreign Exchange
-- Loss. Selling a van at a loss has been landing in foreign exchange,
-- which is wrong twice over: the disposal result is invisible and the
-- foreign exchange disclosure is overstated by it.
--
-- 4930 and 6510 are created on demand rather than added to the seeded
-- chart, following `app.opening_balance_account` in 0150 — an account
-- that appears when a company first needs it, rather than in every
-- company's chart against the day it might.
--
-- Nothing to repair: no organization has a fixed asset yet.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Where a disposal result belongs
-- ---------------------------------------------------------------------
create or replace function app.disposal_account(p_org_id uuid, p_gain boolean)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id     uuid;
  v_code   text := case when p_gain then '4930' else '6510' end;
  v_parent text := case when p_gain then '4000' else '6000' end;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = v_code and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts (
    org_id, code, name, description, account_type, account_subtype,
    parent_id, is_group, is_system, is_active, sort_order)
  values (
    p_org_id, v_code,
    case when p_gain then 'Gain on Disposal of Assets'
         else 'Loss on Disposal of Assets' end,
    'What an asset fetched, against what the books still carried it at. '
    'Separate from foreign exchange, which is where this used to land.',
    case when p_gain then 'revenue' else 'expense' end::app.account_type,
    case when p_gain then 'other_income' else 'other_expense' end::app.account_subtype,
    (select id from public.accounts
      where org_id = p_org_id and code = v_parent and deleted_at is null),
    false, true, true, v_code::integer)
  returning id into v_id;

  return v_id;
end $$;

revoke all on function app.disposal_account(uuid, boolean) from public, anon;

-- ---------------------------------------------------------------------
-- What has actually been charged by a given date
--
-- Deliberately not `app.accumulated_depreciation_at`, which answers a
-- different question: that one computes what the accumulated
-- depreciation *ought* to be under the asset's method and life, and is
-- what the run charges towards. This one reads what was in fact posted,
-- which is what a schedule has to report and what the ledger agrees
-- with. The two differ for every asset between run dates, and the
-- difference is the next run's charge.
--
-- Two runs can share a date — a run, then a correction — so the tie is
-- broken on when they were posted rather than left to chance.
-- ---------------------------------------------------------------------
create or replace function app.accumulated_charged_at(
  p_asset_id uuid, p_as_at date)
returns numeric
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select coalesce((
    select e.closing_accumulated
      from public.depreciation_entries e
      join public.depreciation_runs r on r.id = e.run_id
     where e.asset_id = p_asset_id and r.run_date <= p_as_at
     order by r.run_date desc, r.posted_at desc
     limit 1), 0);
$$;

revoke all on function app.accumulated_charged_at(uuid, date) from public, anon;

-- ---------------------------------------------------------------------
-- Disposal, charging the catch-up it relieves
-- ---------------------------------------------------------------------
create or replace function public.dispose_fixed_asset(
  p_asset_id uuid,
  p_date date,
  p_proceeds numeric default 0,
  p_bank_account_id uuid default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  a          public.fixed_assets;
  v_entries  jsonb := '[]'::jsonb;
  v_accum    numeric(18, 2);
  v_catchup  numeric(18, 2);
  v_nbv      numeric(18, 2);
  v_result   numeric(18, 2);
  v_asset_ac uuid; v_accum_ac uuid; v_cash_ac uuid; v_expense_ac uuid;
  v_entry_id uuid;
  v_run_id   uuid;
begin
  select * into a from public.fixed_assets where id = p_asset_id;
  if not found then
    raise exception 'Asset % not found', p_asset_id using errcode = 'P0002';
  end if;
  if not app.can_post(a.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if a.status = 'disposed' then
    raise exception 'Asset % has already been disposed of', a.asset_no
      using errcode = '23514';
  end if;
  if p_date < a.acquisition_date then
    raise exception 'Asset % was acquired on %, after the disposal date %',
      a.asset_no, a.acquisition_date, p_date using errcode = '23514';
  end if;

  -- Catch the charge up to the day it left, and remember by how much:
  -- that part has not been posted anywhere yet.
  v_accum := greatest(app.accumulated_depreciation_at(a, p_date),
                      a.accumulated_depreciation);
  v_catchup := greatest(v_accum - a.accumulated_depreciation, 0);
  v_nbv := a.cost - v_accum;
  v_result := round(coalesce(p_proceeds, 0) - v_nbv, 2);

  -- 1510, not 1500: 1500 is the "Non-Current Assets" header in the
  -- seeded chart and nothing may post to a header.
  v_asset_ac := coalesce(a.asset_account_id,
    (select id from public.accounts where org_id = a.org_id and code = '1510'));
  v_accum_ac := coalesce(a.accumulated_account_id,
    (select id from public.accounts where org_id = a.org_id and code = '1590'));
  v_cash_ac := coalesce(
    (select ac.id from public.bank_accounts b
       join public.accounts ac on ac.id = b.account_id
      where b.id = p_bank_account_id),
    (select id from public.accounts where org_id = a.org_id and code = '1120'));

  if v_asset_ac is null or v_accum_ac is null then
    raise exception
      'No fixed asset (1510) or accumulated depreciation (1590) account in '
      'the chart. Add them, or name accounts on the asset.'
      using errcode = 'P0002';
  end if;

  -- The months between the last run and the disposal. Charged here or
  -- charged nowhere — and if nowhere, relieved from the balance sheet
  -- below without ever reaching the profit and loss.
  if v_catchup > 0 then
    v_expense_ac := coalesce(a.expense_account_id,
      (select id from public.accounts where org_id = a.org_id and code = '6400'));
    if v_expense_ac is null then
      raise exception
        'No depreciation expense (6400) account in the chart, and % has '
        'not been depreciated up to %. Add the account, or name one on '
        'the asset.', a.asset_no, p_date
        using errcode = 'P0002';
    end if;
    v_entries := v_entries
      || jsonb_build_object(
           'account_id', v_expense_ac,
           'description', 'Depreciation of ' || a.asset_no || ' to disposal',
           'debit', v_catchup, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0)
      || jsonb_build_object(
           'account_id', v_accum_ac,
           'description', 'Depreciation of ' || a.asset_no || ' to disposal',
           'debit', 0, 'credit', v_catchup, 'fc_debit', 0, 'fc_credit', 0);
  end if;

  -- Dr accumulated depreciation, Dr proceeds, Cr the asset at cost, and
  -- the difference to gain or loss.
  if v_accum > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_accum_ac, 'description', 'Disposal of ' || a.asset_no,
      'debit', v_accum, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
  end if;

  if coalesce(p_proceeds, 0) > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_cash_ac, 'description', 'Proceeds on ' || a.asset_no,
      'debit', p_proceeds, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
  end if;

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_asset_ac, 'description', 'Disposal of ' || a.asset_no,
    'debit', 0, 'credit', a.cost, 'fc_debit', 0, 'fc_credit', 0);

  if v_result > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.disposal_account(a.org_id, true),
      'description', 'Gain on disposal of ' || a.asset_no,
      'debit', 0, 'credit', v_result, 'fc_debit', 0, 'fc_credit', 0);
  elsif v_result < 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.disposal_account(a.org_id, false),
      'description', 'Loss on disposal of ' || a.asset_no,
      'debit', -v_result, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
  end if;

  v_entry_id := app.create_gl_entry_internal(
    a.org_id, p_date, 'depreciation'::app.journal_source, v_entries,
    'Disposal of ' || a.asset_no || ' — ' || a.name,
    'fixed_assets', a.id, null, app.base_currency(a.org_id), 1);

  -- The catch-up recorded where every other charge is recorded, so the
  -- asset's history is whole and the schedule's charge for the period
  -- ties to the entries behind it. The run points at the disposal
  -- journal because that is the journal that carried it.
  if v_catchup > 0 then
    insert into public.depreciation_runs
      (org_id, run_date, gl_entry_id, total_amount, posted_by)
    values (a.org_id, p_date, v_entry_id, v_catchup, auth.uid())
    returning id into v_run_id;

    insert into public.depreciation_entries
      (org_id, run_id, asset_id, amount,
       opening_accumulated, closing_accumulated)
    values (a.org_id, v_run_id, a.id, v_catchup,
            a.accumulated_depreciation, v_accum);
  end if;

  update public.fixed_assets
     set status = 'disposed', disposal_date = p_date,
         disposal_proceeds = coalesce(p_proceeds, 0),
         disposal_entry_id = v_entry_id,
         accumulated_depreciation = v_accum,
         depreciated_to = p_date,
         updated_at = now()
   where id = a.id;

  return v_entry_id;
end $$;

-- ---------------------------------------------------------------------
-- One asset's history
--
-- Every charge against it in order, which is what somebody holds beside
-- the asset register when asked where a net book value came from. The
-- disposal is named as such rather than appearing as an unexplained
-- final run: its journal is the disposal's, and that is how it is told
-- apart.
-- ---------------------------------------------------------------------
create or replace function public.report_depreciation_history(
  p_org_id uuid, p_asset_id uuid)
returns table (
  run_date            date,
  source              text,
  charge              numeric,
  opening_accumulated numeric,
  closing_accumulated numeric,
  net_book_value      numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  return query
  select r.run_date,
         case when r.gl_entry_id is not null
               and r.gl_entry_id = fa.disposal_entry_id
              then 'Disposal' else 'Depreciation run' end,
         e.amount, e.opening_accumulated, e.closing_accumulated,
         round(fa.cost - e.closing_accumulated, 2)
    from public.depreciation_entries e
    join public.depreciation_runs r on r.id = e.run_id
    join public.fixed_assets fa on fa.id = e.asset_id
   where e.org_id = p_org_id and e.asset_id = p_asset_id
     and fa.deleted_at is null
   order by r.run_date, r.posted_at;
end $$;

revoke all on function public.report_depreciation_history(uuid, uuid)
  from public, anon;
grant execute on function public.report_depreciation_history(uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- The fixed asset note
--
-- Cost and accumulated depreciation brought forward, what came in, what
-- went out, what was charged, and what is carried forward — by category,
-- because that is how the note is presented and how anybody checks it
-- against the balance sheet.
--
-- Two things make this checkable rather than merely plausible:
--
--   * Cost carried forward must equal brought forward plus additions
--     less disposals, and the closing figure is derived independently of
--     the three that are supposed to add up to it.
--   * The same must hold of accumulated depreciation, where the charge
--     comes from `depreciation_entries` and the closing figure from what
--     each surviving asset has actually been charged. That identity only
--     holds if every movement in accumulated depreciation was recorded
--     as an entry — which is what the disposal above now does and did
--     not before, and is why this report could not have been trusted
--     until it did.
-- ---------------------------------------------------------------------
create or replace function public.report_asset_movements(
  p_org_id uuid,
  p_from date default null,
  p_to date default current_date)
returns table (
  category            text,
  assets              integer,
  cost_opening        numeric,
  additions           numeric,
  disposals_cost      numeric,
  cost_closing        numeric,
  accum_opening       numeric,
  charge              numeric,
  disposals_accum     numeric,
  accum_closing       numeric,
  net_book_value      numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_from date := coalesce(p_from, date '0001-01-01');
begin
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  return query
  with asset as (
    select fa.id, coalesce(nullif(trim(fa.category), ''), 'Uncategorised')
             as category,
           fa.cost, fa.accumulated_depreciation,
           -- On the books at the start of the period, and at the end.
           (fa.acquisition_date < v_from
            and (fa.disposal_date is null or fa.disposal_date >= v_from))
             as was_held,
           (fa.acquisition_date <= p_to
            and (fa.disposal_date is null or fa.disposal_date > p_to))
             as still_held,
           (fa.acquisition_date >= v_from and fa.acquisition_date <= p_to)
             as came_in,
           (fa.disposal_date is not null
            and fa.disposal_date >= v_from and fa.disposal_date <= p_to)
             as went_out,
           -- Per asset, so the outer query is plain sums. What was
           -- charged during the period, what had been charged before it
           -- opened, and what has been charged by the time it closed.
           (select coalesce(sum(e.amount), 0)
              from public.depreciation_entries e
              join public.depreciation_runs r on r.id = e.run_id
             where e.asset_id = fa.id
               and r.run_date >= v_from and r.run_date <= p_to)
             as period_charge,
           app.accumulated_charged_at(fa.id, v_from - 1) as accum_before,
           app.accumulated_charged_at(fa.id, p_to) as accum_after
      from public.fixed_assets fa
     where fa.org_id = p_org_id and fa.deleted_at is null
       and fa.acquisition_date <= p_to
       -- Gone before the period opened: it belongs to an earlier note,
       -- and listing it here would put a row of nils under its category.
       and (fa.disposal_date is null or fa.disposal_date >= v_from))
  select a.category,
         (count(*) filter (where a.still_held))::integer,
         coalesce(sum(a.cost) filter (where a.was_held), 0),
         coalesce(sum(a.cost) filter (where a.came_in), 0),
         coalesce(sum(a.cost) filter (where a.went_out), 0),
         coalesce(sum(a.cost) filter (where a.still_held), 0),
         coalesce(sum(a.accum_before) filter (where a.was_held), 0),
         coalesce(sum(a.period_charge), 0),
         -- What left with the asset. Frozen on the row by the disposal,
         -- which is also the last thing it charged.
         coalesce(sum(a.accumulated_depreciation) filter (where a.went_out), 0),
         coalesce(sum(a.accum_after) filter (where a.still_held), 0),
         coalesce(sum(a.cost) filter (where a.still_held), 0)
           - coalesce(sum(a.accum_after) filter (where a.still_held), 0)
    from asset a
   group by a.category
   order by a.category;
end $$;

revoke all on function public.report_asset_movements(uuid, date, date)
  from public, anon;
grant execute on function public.report_asset_movements(uuid, date, date)
  to authenticated;

comment on function public.report_asset_movements(uuid, date, date) is
  'The fixed asset note by category: cost and accumulated depreciation '
  'brought forward, additions, disposals, the charge for the period and '
  'the carrying amount. The closing figures are derived independently '
  'of the movements that should reconcile to them.';
