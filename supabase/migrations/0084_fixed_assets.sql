-- A fixed asset register, and the depreciation nobody could post.
--
-- `app.journal_source` has carried a `depreciation` value since 0004 and
-- `account_subtype` has carried `fixed_asset`, `accumulated_depreciation`
-- and `depreciation_expense` since 0001. Nothing could produce any of
-- them: there was no asset, no life, no method and no run. Every company
-- with a vehicle or a machine needs this, and the auditor asks for the
-- schedule by name.
--
-- Depreciation is derived, not accumulated
-- ----------------------------------------
-- Each run works out what the accumulated depreciation *ought* to be at
-- the run date and charges the difference. It does not add a month's
-- worth to a running total. That makes a second run on the same date
-- charge nothing, a missed month catch itself up, and a corrected cost
-- or life restate cleanly — the same reasoning as the transfer counters
-- in 0081 and the revaluation in 0083.
--
-- What this is not
-- ----------------
-- Capital allowances. Schedule 3 of the Income Tax Act 1967 has its own
-- rates, its own initial and annual allowances and its own asset
-- classes, and they are not accounting depreciation. Mixing them would
-- put a tax computation in the ledger. This is the accounting charge;
-- the tax computation is a separate exercise on top of it.

-- ---------------------------------------------------------------------
-- The register
-- ---------------------------------------------------------------------
create table if not exists public.fixed_assets (
  id                 uuid primary key default gen_random_uuid(),
  org_id             uuid not null references public.organizations (id) on delete cascade,
  asset_no           text not null,
  name               text not null,
  description        text,
  category           text,

  -- Where the three sides of the entry land. Nullable so an org can lean
  -- on the standard chart, resolved at posting time.
  asset_account_id        uuid references public.accounts (id),
  accumulated_account_id  uuid references public.accounts (id),
  expense_account_id      uuid references public.accounts (id),

  acquisition_date   date not null,
  cost               numeric(18, 2) not null check (cost >= 0),
  residual_value     numeric(18, 2) not null default 0 check (residual_value >= 0),

  -- 'straight_line' uses useful_life_months; 'reducing_balance' uses
  -- rate_percent as an annual rate. Both are stored because an asset can
  -- be re-based from one to the other and the other figure should not be
  -- lost when it is.
  method             text not null default 'straight_line'
                       check (method in ('straight_line', 'reducing_balance')),
  useful_life_months integer check (useful_life_months > 0),
  rate_percent       numeric(9, 4) check (rate_percent > 0),

  -- Kept on the row rather than recomputed everywhere: the register has
  -- to show a net book value without running the engine for each line.
  -- Written only by the depreciation run and the disposal.
  accumulated_depreciation numeric(18, 2) not null default 0,
  depreciated_to     date,

  supplier_id        uuid references public.contacts (id) on delete set null,
  purchase_document_id uuid references public.purchase_documents (id) on delete set null,
  serial_no          text,
  location           text,

  status             text not null default 'active'
                       check (status in ('active', 'fully_depreciated',
                                         'disposed', 'written_off')),
  disposal_date      date,
  disposal_proceeds  numeric(18, 2),
  disposal_entry_id  uuid references public.gl_entries (id),

  notes              text,
  created_by         uuid references auth.users (id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz,
  unique (org_id, asset_no),

  -- A method without the figure it needs is an asset that cannot be
  -- depreciated, which is worse than one that is refused at entry.
  constraint fixed_assets_method_needs_its_figure check (
    (method = 'straight_line' and useful_life_months is not null)
    or (method = 'reducing_balance' and rate_percent is not null)),

  constraint fixed_assets_residual_below_cost check (residual_value <= cost)
);

create index if not exists fixed_assets_org_idx
  on public.fixed_assets (org_id, status);

-- Each posting, and what it charged against which asset. Without the
-- detail the schedule cannot be produced and a wrong month cannot be
-- traced back to the asset that caused it.
create table if not exists public.depreciation_runs (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations (id) on delete cascade,
  run_date     date not null,
  gl_entry_id  uuid references public.gl_entries (id),
  total_amount numeric(18, 2) not null default 0,
  posted_at    timestamptz not null default now(),
  posted_by    uuid references auth.users (id)
);

create table if not exists public.depreciation_entries (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations (id) on delete cascade,
  run_id       uuid not null references public.depreciation_runs (id) on delete cascade,
  asset_id     uuid not null references public.fixed_assets (id) on delete cascade,
  amount       numeric(18, 2) not null,
  opening_accumulated numeric(18, 2) not null,
  closing_accumulated numeric(18, 2) not null
);

create index if not exists depreciation_entries_run_idx
  on public.depreciation_entries (run_id);
create index if not exists depreciation_entries_asset_idx
  on public.depreciation_entries (asset_id);

-- ---------------------------------------------------------------------
-- Months held
--
-- The month of acquisition counts as a whole month, which is the
-- convention most Malaysian SMEs and their auditors use for anything
-- other than the largest assets. It is stated here rather than left
-- implicit because the alternative — pro-rating by days — gives a
-- different first-year charge and somebody will eventually check.
-- ---------------------------------------------------------------------
create or replace function app.months_held(p_from date, p_to date)
returns integer
language sql immutable as $$
  select greatest(
    0,
    (extract(year from age(date_trunc('month', p_to)::date,
                           date_trunc('month', p_from)::date)) * 12
     + extract(month from age(date_trunc('month', p_to)::date,
                              date_trunc('month', p_from)::date)))::integer
    + case when p_to >= p_from then 1 else 0 end);
$$;

-- ---------------------------------------------------------------------
-- What the accumulated depreciation should be by a given date
--
-- Closed form for both methods, so the answer does not depend on how
-- many times the run has been executed or whether a month was missed.
-- Never more than cost less residual: an asset is not depreciated past
-- what it is expected to be worth at the end.
-- ---------------------------------------------------------------------
create or replace function app.accumulated_depreciation_at(
  p_asset public.fixed_assets, p_as_at date)
returns numeric
language plpgsql immutable as $$
declare
  v_months     integer;
  v_depreciable numeric(18, 2);
  v_target     numeric(18, 2);
  v_nbv        numeric(18, 6);
begin
  if p_as_at < p_asset.acquisition_date then return 0; end if;

  v_months := app.months_held(p_asset.acquisition_date, p_as_at);
  v_depreciable := p_asset.cost - p_asset.residual_value;
  if v_depreciable <= 0 or v_months = 0 then return 0; end if;

  if p_asset.method = 'straight_line' then
    v_target := round(v_depreciable * v_months::numeric
                      / p_asset.useful_life_months::numeric, 2);
  else
    -- Reducing balance, compounded monthly at a twelfth of the annual
    -- rate. Closed form rather than a loop: same answer, and it does not
    -- take longer the older the asset is.
    v_nbv := p_asset.cost
             * power(1 - (p_asset.rate_percent / 100.0 / 12.0), v_months);
    v_target := round(p_asset.cost - v_nbv, 2);
  end if;

  return least(greatest(v_target, 0), v_depreciable);
end;
$$;

-- What a run would charge, per asset, before anything is posted.
create or replace function public.depreciation_preview(
  p_org_id uuid, p_as_at date default current_date)
returns table (
  asset_id uuid, asset_no text, name text, cost numeric,
  accumulated numeric, charge numeric, net_book_value numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select a.id, a.asset_no, a.name, a.cost, a.accumulated_depreciation,
         greatest(app.accumulated_depreciation_at(a, p_as_at)
                  - a.accumulated_depreciation, 0),
         a.cost - greatest(app.accumulated_depreciation_at(a, p_as_at),
                           a.accumulated_depreciation)
    from public.fixed_assets a
   where a.org_id = p_org_id and a.deleted_at is null
     and a.status = 'active'
     and a.acquisition_date <= p_as_at
   order by a.asset_no;
end;
$$;

-- ---------------------------------------------------------------------
-- Post the charge
--
-- One journal for the whole run, one line per expense account, so a
-- company with fifty assets does not get fifty pairs of lines it has to
-- scroll past. The per-asset detail lives in depreciation_entries, which
-- is where the schedule comes from.
-- ---------------------------------------------------------------------
create or replace function public.run_depreciation(
  p_org_id uuid, p_as_at date default current_date)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_run_id    uuid;
  v_entry_id  uuid;
  v_entries   jsonb := '[]'::jsonb;
  v_total     numeric(18, 2) := 0;
  v_default_expense uuid;
  v_default_accum   uuid;
  a           public.fixed_assets;
  v_charge    numeric(18, 2);
  v_target    numeric(18, 2);
  r           record;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;

  select id into v_default_expense from public.accounts
   where org_id = p_org_id and code = '6400';
  select id into v_default_accum from public.accounts
   where org_id = p_org_id and code = '1590';

  insert into public.depreciation_runs (org_id, run_date, posted_by)
  values (p_org_id, p_as_at, auth.uid()) returning id into v_run_id;

  for a in
    select * from public.fixed_assets
     where org_id = p_org_id and deleted_at is null
       and status = 'active' and acquisition_date <= p_as_at
     order by asset_no
  loop
    v_target := app.accumulated_depreciation_at(a, p_as_at);
    v_charge := round(v_target - a.accumulated_depreciation, 2);
    if v_charge <= 0 then continue; end if;

    insert into public.depreciation_entries
      (org_id, run_id, asset_id, amount, opening_accumulated, closing_accumulated)
    values (p_org_id, v_run_id, a.id, v_charge, a.accumulated_depreciation, v_target);

    update public.fixed_assets
       set accumulated_depreciation = v_target,
           depreciated_to = p_as_at,
           status = case when v_target >= a.cost - a.residual_value
                         then 'fully_depreciated' else 'active' end,
           updated_at = now()
     where id = a.id;

    v_total := v_total + v_charge;
  end loop;

  if v_total = 0 then
    delete from public.depreciation_runs where id = v_run_id;
    return null;
  end if;

  -- Grouped after the fact so each side of the journal names the account
  -- it actually belongs to, whether the asset carried its own or fell
  -- back to the chart.
  for r in
    -- Aliased `fa`, not `a`: the loop variable above is already `a` and
    -- plpgsql resolves the name to the variable, leaving `a.id` ambiguous
    -- against the join.
    select coalesce(fa.expense_account_id, v_default_expense) as expense_id,
           coalesce(fa.accumulated_account_id, v_default_accum) as accum_id,
           sum(e.amount) as amount
      from public.depreciation_entries e
      join public.fixed_assets fa on fa.id = e.asset_id
     where e.run_id = v_run_id
     group by 1, 2
  loop
    if r.expense_id is null or r.accum_id is null then
      raise exception
        'No depreciation expense (6400) or accumulated depreciation (1590) '
        'account in the chart. Add them, or name accounts on the asset.'
        using errcode = 'P0002';
    end if;
    v_entries := v_entries
      || jsonb_build_object('account_id', r.expense_id,
           'description', 'Depreciation to ' || p_as_at,
           'debit', r.amount, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0)
      || jsonb_build_object('account_id', r.accum_id,
           'description', 'Depreciation to ' || p_as_at,
           'debit', 0, 'credit', r.amount, 'fc_debit', 0, 'fc_credit', 0);
  end loop;

  v_entry_id := app.create_gl_entry_internal(
    p_org_id, p_as_at, 'depreciation'::app.journal_source, v_entries,
    'Depreciation to ' || p_as_at, 'depreciation_runs', v_run_id, null,
    app.base_currency(p_org_id), 1);

  update public.depreciation_runs
     set gl_entry_id = v_entry_id, total_amount = v_total
   where id = v_run_id;

  return v_run_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Disposal
--
-- Takes the cost and the accumulated depreciation off the books and
-- recognises the difference against the proceeds. Depreciation is
-- brought up to the disposal date first, because selling an asset in
-- June after depreciating it to March would otherwise report five months
-- of charge as a gain on sale.
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
  v_nbv      numeric(18, 2);
  v_result   numeric(18, 2);
  v_asset_ac uuid; v_accum_ac uuid; v_cash_ac uuid;
  v_entry_id uuid;
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

  -- Catch the charge up to the day it left.
  v_accum := greatest(app.accumulated_depreciation_at(a, p_date),
                      a.accumulated_depreciation);
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
      'account_id', (select id from public.accounts
                      where org_id = a.org_id and code = '4920'),
      'description', 'Gain on disposal of ' || a.asset_no,
      'debit', 0, 'credit', v_result, 'fc_debit', 0, 'fc_credit', 0);
  elsif v_result < 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', (select id from public.accounts
                      where org_id = a.org_id and code = '6500'),
      'description', 'Loss on disposal of ' || a.asset_no,
      'debit', -v_result, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
  end if;

  v_entry_id := app.create_gl_entry_internal(
    a.org_id, p_date, 'depreciation'::app.journal_source, v_entries,
    'Disposal of ' || a.asset_no || ' — ' || a.name,
    'fixed_assets', a.id, null, app.base_currency(a.org_id), 1);

  update public.fixed_assets
     set status = 'disposed', disposal_date = p_date,
         disposal_proceeds = coalesce(p_proceeds, 0),
         disposal_entry_id = v_entry_id,
         accumulated_depreciation = v_accum,
         updated_at = now()
   where id = a.id;

  return v_entry_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
alter table public.fixed_assets enable row level security;
alter table public.depreciation_runs enable row level security;
alter table public.depreciation_entries enable row level security;

create policy fixed_assets_select on public.fixed_assets
  for select to authenticated using (app.is_org_member(org_id));
create policy fixed_assets_insert on public.fixed_assets
  for insert to authenticated with check (app.can_write(org_id));
create policy fixed_assets_update on public.fixed_assets
  for update to authenticated
  using (app.can_write(org_id)) with check (app.can_write(org_id));
create policy fixed_assets_delete on public.fixed_assets
  for delete to authenticated using (app.can_admin(org_id));

-- The runs are written by the posting function and read by everyone who
-- can see the ledger. Nothing writes them from the API.
create policy depreciation_runs_select on public.depreciation_runs
  for select to authenticated using (app.is_org_member(org_id));
create policy depreciation_entries_select on public.depreciation_entries
  for select to authenticated using (app.is_org_member(org_id));

revoke all on function app.months_held(date, date) from public, anon, authenticated;
revoke all on function app.accumulated_depreciation_at(public.fixed_assets, date)
  from public, anon, authenticated;

revoke all on function public.depreciation_preview(uuid, date) from public, anon;
grant execute on function public.depreciation_preview(uuid, date) to authenticated;

revoke all on function public.run_depreciation(uuid, date) from public, anon;
grant execute on function public.run_depreciation(uuid, date) to authenticated;

revoke all on function public.dispose_fixed_asset(uuid, date, numeric, uuid)
  from public, anon;
grant execute on function public.dispose_fixed_asset(uuid, date, numeric, uuid)
  to authenticated;
