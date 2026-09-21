-- =====================================================================
-- Form C: the company tax computation
--
-- `0664` produces the Schedule 3 working. This is what subtracts it.
--
-- A tax computation is not a report of the ledger. It STARTS at the
-- profit the accounts show and then argues with them, line by line,
-- until it arrives at a figure Parliament taxes:
--
--     Profit before taxation (per accounts)
--     Add:  non-deductible expenses
--     Less: non-taxable income
--     = Adjusted income / (adjusted loss)
--     Less: capital allowances (Schedule 3)
--     = Statutory income
--     Less: losses brought forward
--     = Chargeable income
--     Tax at the SME bands, or at 24%
--     Less: zakat rebate, s.110 deductions, CP204 instalments
--     = Tax payable / (refundable)
--
-- ---------------------------------------------------------------------
-- Where the add-backs come from, and why it is the chart of accounts
--
-- The alternative is a form somebody types twenty figures into once a
-- year from a printed profit and loss. That is how it is done in
-- practice and it is the reason computations disagree with the accounts
-- they came from: the ledger moves, the typed figure does not, and
-- nothing anywhere says they were ever the same.
--
-- So a treatment is tagged on the ACCOUNT, once, by whoever set up the
-- chart. "Fines and penalties" is non-deductible for as long as that
-- account exists. The computation then reads the profit and loss and
-- applies the tags, which means it is recomputed from the ledger every
-- time it is opened and cannot silently drift from it.
--
-- What cannot be tagged is what is left: a director's private mileage
-- inside a motor expenses account that is otherwise perfectly
-- deductible. Those are rows in `tax_adjustments`, typed, with a reason
-- beside each -- and they are visibly the exceptions rather than the
-- whole computation.
--
-- ---------------------------------------------------------------------
-- What this does NOT do
--
-- It does not file. There is no e-Filing submission here and no CP204
-- estimate. It produces the computation and its working, which is the
-- document an accountant reviews and then keys or attaches.
--
-- It also models ONE basis period per year of assessment. A company
-- changing its accounting date has a basis period that is not twelve
-- months, and apportioning Schedule 3 across it is a real rule that is
-- deliberately absent -- `0664` says the same thing about the same
-- case. The computation is keyed to a fiscal year rather than to a
-- calendar year so that when somebody does model it, there is a period
-- to hang it on.
-- =====================================================================

-- ---------------------------------------------------------------------
-- How a class of expense is treated
-- ---------------------------------------------------------------------
create table public.tax_treatments (
  code        text primary key,
  label       text not null,

  -- 'add_back' increases the adjusted income, 'deduct' reduces it.
  -- Two kinds rather than a signed fraction, because the computation
  -- prints them under two different headings and a reader checks the
  -- two subtotals separately.
  kind        text not null check (kind in ('add_back', 'deduct')),

  -- How much of the account's balance the treatment applies to.
  -- Entertainment is half; a penalty is all of it. A fraction rather
  -- than a boolean because half is a real rule and hard-coding it
  -- would make the next fraction a migration.
  fraction    numeric(6, 4) not null default 1
                check (fraction > 0 and fraction <= 1),

  -- Which side of the ledger this can sensibly be put on. An expense
  -- treatment on a revenue account is a mistake nobody spots, because
  -- the figure still adds up.
  applies_to  text not null default 'expense'
                check (applies_to in ('expense', 'revenue')),

  sort_order  integer not null default 0,
  reference   text,
  notes       text
);

comment on table public.tax_treatments is
  'What a tax computation does with the balance on an account: add it '
  'back, or take it out, and how much of it. Platform data -- the '
  'rules are the Act''s, not a tenant''s.';

alter table public.tax_treatments enable row level security;

create policy tax_treatments_read on public.tax_treatments
  for select to authenticated using (true);
create policy tax_treatments_write on public.tax_treatments
  for all to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());

-- A policy is not a grant. `0662`, `0663` and `0664` each learned this.
grant select on public.tax_treatments to authenticated;
grant insert, update, delete on public.tax_treatments to authenticated;

insert into public.tax_treatments
  (code, label, kind, fraction, applies_to, sort_order, reference, notes)
values
  ('depreciation', 'Depreciation', 'add_back', 1, 'expense', 10,
   'ITA 1967 s.33(1)',
   'Added back in full and replaced by capital allowances. This is the '
   'single largest line in most computations and the reason the tax '
   'figure and the accounts figure are never the same.'),
  ('entertainment', 'Entertainment', 'add_back', 0.5, 'expense', 20,
   'ITA 1967 s.33(1), Public Ruling 3/2008',
   'Half disallowed. Entertainment wholly for the promotion of '
   'business can be fully deductible -- where an account is only ever '
   'that, tag it deductible and say so.'),
  ('penalties', 'Penalties and fines', 'add_back', 1, 'expense', 30,
   'ITA 1967 s.33(1)',
   'Not incurred in the production of income.'),
  ('private', 'Private and domestic expenses', 'add_back', 1, 'expense', 40,
   'ITA 1967 s.39(1)(a)', null),
  ('club', 'Club membership', 'add_back', 1, 'expense', 50,
   'ITA 1967 s.39(1)(l)', null),
  ('general_provision', 'General provisions', 'add_back', 1, 'expense', 60,
   'ITA 1967 s.34(2)',
   'A general provision for doubtful debts is added back; a SPECIFIC '
   'one is allowed. If an account carries both, split it or use an '
   'adjustment.'),
  ('donation_unapproved', 'Donations to unapproved bodies',
   'add_back', 1, 'expense', 70, 'ITA 1967 s.44(6)', null),
  ('zakat_expense', 'Zakat perniagaan', 'add_back', 1, 'expense', 80,
   'ITA 1967 s.6A(3)',
   'Not a deduction. It is a REBATE against the tax charged, and the '
   'computation applies it there -- so the expense is added back here '
   'and the same money comes off at the bottom.'),
  ('capital', 'Capital expenditure written off', 'add_back', 1,
   'expense', 90, 'ITA 1967 s.33(1)', null),
  ('exempt_income', 'Exempt income', 'deduct', 1, 'revenue', 100,
   'ITA 1967 Schedule 6',
   'Income the accounts show and the Act does not tax. Taken out '
   'rather than added back, which is why it is a deduction.');

-- ---------------------------------------------------------------------
-- The tag on the account
-- ---------------------------------------------------------------------

-- Nullable, and null means ordinary -- deductible if it is an expense,
-- taxable if it is revenue. That is what almost every account is, and a
-- column whose blank reads as "not done yet" would make a chart of four
-- hundred accounts look like four hundred outstanding decisions.
alter table public.accounts
  add column tax_treatment text references public.tax_treatments (code);

comment on column public.accounts.tax_treatment is
  'How a tax computation treats this account. Null means ordinary: an '
  'expense is deductible, revenue is taxable. Not a to-do.';

create index accounts_tax_treatment_idx
  on public.accounts (org_id, tax_treatment)
  where tax_treatment is not null;

-- ---------------------------------------------------------------------
-- The rates
-- ---------------------------------------------------------------------
create table public.company_tax_rates (
  id             uuid primary key default gen_random_uuid(),
  year_of_assessment integer not null unique,

  -- The preferential band, and what it takes to qualify for it.
  sme_band_limit numeric(18, 2) not null,
  sme_rate       numeric(6, 4) not null,
  standard_rate  numeric(6, 4) not null,
  sme_capital_limit numeric(18, 2) not null,
  sme_turnover_limit numeric(18, 2) not null,

  source         text,
  is_verified    boolean not null default false,
  notes          text,
  created_at     timestamptz not null default now(),

  constraint company_tax_rates_are_rates check (
    sme_rate >= 0 and sme_rate <= 1
    and standard_rate >= 0 and standard_rate <= 1)
);

comment on table public.company_tax_rates is
  'Company income tax rates by year of assessment. is_verified false '
  'means the figures came from published summaries rather than from '
  'the Act -- the same flag and the same meaning as `0025` and `0664`.';

alter table public.company_tax_rates enable row level security;
create policy company_tax_rates_read on public.company_tax_rates
  for select to authenticated using (true);
create policy company_tax_rates_write on public.company_tax_rates
  for all to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());

grant select on public.company_tax_rates to authenticated;
grant insert, update, delete on public.company_tax_rates to authenticated;

insert into public.company_tax_rates
  (year_of_assessment, sme_band_limit, sme_rate, standard_rate,
   sme_capital_limit, sme_turnover_limit, source, notes)
select y, 150000, 0.17, 0.24, 2500000, 50000000,
       'Published rates for YA ' || y,
       'Seeded unverified. Check against the Act before filing.'
  from generate_series(2020, 2030) as y;

-- ---------------------------------------------------------------------
-- The computation itself
-- ---------------------------------------------------------------------
create table public.tax_computations (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null
                   references public.organizations (id) on delete cascade,
  fiscal_year_id uuid not null
                   references public.fiscal_years (id) on delete cascade,
  -- The company as well as the row. Without it a computation could name
  -- ANOTHER company's financial year and read its ledger through the
  -- period -- `tenant_foreign_keys.sql` refuses a single-column link to
  -- a tenant-scoped table for exactly that reason, and refused this.
  constraint tax_computations_year_same_org
    foreign key (org_id, fiscal_year_id)
    references public.fiscal_years (org_id, id) on delete cascade,

  -- Derived from the fiscal year when the computation is created, and
  -- then held. A basis period ending in 2026 is year of assessment
  -- 2026, and a company that later renames its fiscal year must not
  -- silently move which year it filed under.
  year_of_assessment integer not null,

  -- The SME test, which is two facts about the company rather than
  -- anything in the ledger: paid-up ordinary share capital at the
  -- BEGINNING of the basis period, and gross business income for it.
  -- Typed, because neither is a balance this system holds -- and left
  -- null rather than guessed, which makes the computation say it does
  -- not know instead of quietly charging 24%.
  paid_up_capital       numeric(18, 2),
  gross_business_income numeric(18, 2),

  capital_allowance_bf  numeric(18, 2) not null default 0
                          check (capital_allowance_bf >= 0),
  loss_bf               numeric(18, 2) not null default 0
                          check (loss_bf >= 0),
  zakat_paid            numeric(18, 2) not null default 0
                          check (zakat_paid >= 0),
  s110_tax_deducted     numeric(18, 2) not null default 0
                          check (s110_tax_deducted >= 0),
  cp204_paid            numeric(18, 2) not null default 0
                          check (cp204_paid >= 0),

  status     text not null default 'draft'
               check (status in ('draft', 'final')),
  notes      text,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- One per basis period. A second computation for the same year is
  -- two answers to one question.
  unique (org_id, fiscal_year_id)
);

comment on table public.tax_computations is
  'One Form C working per basis period. Holds only what the ledger '
  'cannot know -- the SME test figures, amounts brought forward, and '
  'tax already paid. Everything else is recomputed from the accounts '
  'every time it is read.';

-- What the adjustments' composite key points at.
alter table public.tax_computations
  add constraint tax_computations_org_id_id_key unique (org_id, id);

create index tax_computations_org_idx
  on public.tax_computations (org_id, year_of_assessment desc);

alter table public.tax_computations enable row level security;

create policy tax_computations_select on public.tax_computations
  for select to authenticated using (app.is_org_member(org_id));
create policy tax_computations_insert on public.tax_computations
  for insert to authenticated with check (app.can_post(org_id));
create policy tax_computations_update on public.tax_computations
  for update to authenticated
  using (app.can_post(org_id)) with check (app.can_post(org_id));
create policy tax_computations_delete on public.tax_computations
  for delete to authenticated using (app.can_admin(org_id));

grant select, insert, update, delete on public.tax_computations
  to authenticated;

-- ---------------------------------------------------------------------
-- The adjustments a tag cannot make
-- ---------------------------------------------------------------------
create table public.tax_adjustments (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null
                   references public.organizations (id) on delete cascade,
  computation_id uuid not null
                   references public.tax_computations (id) on delete cascade,
  constraint tax_adjustments_computation_same_org
    foreign key (org_id, computation_id)
    references public.tax_computations (org_id, id) on delete cascade,
  kind           text not null check (kind in ('add_back', 'deduct')),
  label          text not null,
  amount         numeric(18, 2) not null check (amount > 0),

  -- Not optional in spirit and not enforced in SQL: an adjustment
  -- without a reason is the line a reviewer stops at, and refusing it
  -- outright would only produce reasons that say "adjustment".
  reason         text,
  sort_order     integer not null default 0,
  created_at     timestamptz not null default now(),

  constraint tax_adjustment_has_a_label
    check (nullif(btrim(label), '') is not null)
);

create index tax_adjustments_computation_idx
  on public.tax_adjustments (computation_id, sort_order);

alter table public.tax_adjustments enable row level security;

create policy tax_adjustments_select on public.tax_adjustments
  for select to authenticated using (app.is_org_member(org_id));
create policy tax_adjustments_write on public.tax_adjustments
  for all to authenticated
  using (app.can_post(org_id)) with check (app.can_post(org_id));

grant select, insert, update, delete on public.tax_adjustments
  to authenticated;

-- ---------------------------------------------------------------------
-- The working, line by line
-- ---------------------------------------------------------------------

-- Every line the computation adds or deducts, and where it came from:
-- an account with a treatment on it, or a typed adjustment. The
-- `source` column is what makes the computation reviewable -- a
-- reviewer's first question about any add-back is "which account".
create or replace function public.tax_computation_lines(
  p_computation_id uuid)
returns table (
  kind       text,
  code       text,
  label      text,
  source     text,
  gross      numeric,
  fraction   numeric,
  amount     numeric,
  reference  text)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  c record;
  v_from date;
  v_to   date;
begin
  select tc.*, fy.start_date, fy.end_date into c
    from public.tax_computations tc
    join public.fiscal_years fy on fy.id = tc.fiscal_year_id
   where tc.id = p_computation_id;

  if c is null then
    raise exception 'No such computation' using errcode = 'P0002';
  end if;
  if not app.is_org_member(c.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  v_from := c.start_date;
  v_to   := c.end_date;

  return query
  -- Tagged accounts, from the profit and loss of the basis period.
  select t.kind,
         pl.code,
         t.label,
         'Account ' || pl.code || ' ' || pl.name,
         pl.amount,
         t.fraction,
         round(pl.amount * t.fraction, 2),
         t.reference
    from public.report_profit_loss(c.org_id, v_from, v_to) pl
    join public.accounts a on a.id = pl.account_id
    join public.tax_treatments t on t.code = a.tax_treatment
   -- A treatment meant for an expense account, sitting on a revenue
   -- one, would still produce a figure that adds up. It is dropped
   -- rather than applied, and `tax_computation_misfiled` is what says
   -- so on the screen.
   where t.applies_to = pl.account_type::text
     and round(pl.amount * t.fraction, 2) <> 0

  union all

  -- Typed adjustments.
  select adj.kind, null, adj.label,
         coalesce(nullif(btrim(adj.reason), ''), 'No reason given'),
         adj.amount, 1::numeric, adj.amount, null
    from public.tax_adjustments adj
   where adj.computation_id = p_computation_id

  order by 1, 2 nulls last, 3;
end; $$;

revoke all on function public.tax_computation_lines(uuid) from public, anon;
grant execute on function public.tax_computation_lines(uuid)
  to authenticated;

comment on function public.tax_computation_lines(uuid) is
  'Every add-back and deduction in a computation, with the account or '
  'the typed adjustment it came from. A reviewer''s first question '
  'about any line is which account, so the answer is a column.';

-- A treatment on the wrong side of the ledger. Silent otherwise: the
-- line is dropped, the computation still balances, and the figure is
-- simply wrong by whatever that account holds.
create or replace function public.tax_computation_misfiled(p_org_id uuid)
returns table (account_id uuid, code text, name text, treatment text)
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select a.id, a.code, a.name, a.tax_treatment
    from public.accounts a
    join public.tax_treatments t on t.code = a.tax_treatment
   where a.org_id = p_org_id
     and a.deleted_at is null
     and t.applies_to <> a.account_type::text
     and app.is_org_member(p_org_id)
   order by a.code;
$$;

revoke all on function public.tax_computation_misfiled(uuid)
  from public, anon;
grant execute on function public.tax_computation_misfiled(uuid)
  to authenticated;

comment on function public.tax_computation_misfiled(uuid) is
  'Accounts whose tax treatment is for the other side of the ledger -- '
  'an expense rule on a revenue account. Those lines are DROPPED from '
  'the computation rather than applied, so nothing else would show it.';

-- ---------------------------------------------------------------------
-- The computation
--
-- Every figure derived, none stored. The row holds what the ledger
-- cannot know; everything below is arithmetic over the accounts, the
-- Schedule 3 working and the rates, so a computation opened a year
-- later still agrees with the books it came from.
--
-- The order of operations is the Act's and is not interchangeable:
--
--   * Capital allowances are set against ADJUSTED INCOME and cannot
--     create a loss. What they do not absorb is carried forward as
--     unabsorbed capital allowance, which is a different thing from a
--     loss and carries forward under different rules.
--   * Losses brought forward are set against STATUTORY INCOME, after
--     the allowances, and likewise cannot take it below nothing.
--   * The zakat rebate comes off the TAX, not off the income, and is
--     capped at the tax charged -- s.6A(3). A company that paid more
--     zakat than it owes tax does not get the difference back.
-- ---------------------------------------------------------------------
create or replace function public.tax_computation(p_computation_id uuid)
returns table (
  year_of_assessment   integer,
  period_from          date,
  period_to            date,
  profit_before_tax    numeric,
  add_backs            numeric,
  deductions           numeric,
  balancing_charge     numeric,
  adjusted_income      numeric,
  adjusted_loss        numeric,
  ca_current           numeric,
  ca_brought_forward   numeric,
  ca_used              numeric,
  ca_carried_forward   numeric,
  statutory_income     numeric,
  loss_brought_forward numeric,
  loss_used            numeric,
  loss_carried_forward numeric,
  chargeable_income    numeric,
  is_sme               boolean,
  sme_known            boolean,
  tax_charged          numeric,
  zakat_rebate         numeric,
  s110_tax_deducted    numeric,
  cp204_paid           numeric,
  tax_payable          numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  c        record;
  r        record;
  v_pbt    numeric := 0;
  v_add    numeric := 0;
  v_ded    numeric := 0;
  v_bc     numeric := 0;
  v_ca_cur numeric := 0;
  v_adj    numeric;
  v_loss   numeric := 0;
  v_ca_av  numeric;
  v_ca_use numeric;
  v_si     numeric;
  v_lu     numeric;
  v_ci     numeric;
  v_sme    boolean;
  v_known  boolean;
  v_tax    numeric;
  v_zakat  numeric;
begin
  select tc.*, fy.start_date, fy.end_date into c
    from public.tax_computations tc
    join public.fiscal_years fy on fy.id = tc.fiscal_year_id
   where tc.id = p_computation_id;

  if c is null then
    raise exception 'No such computation' using errcode = 'P0002';
  end if;
  if not app.is_org_member(c.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  -- The profit the accounts show. Revenue less expenses over the basis
  -- period, which is what `report_profit_loss` already signs correctly
  -- for each side.
  select coalesce(sum(case when pl.account_type = 'revenue'
                           then pl.amount else -pl.amount end), 0)
    into v_pbt
    from public.report_profit_loss(c.org_id, c.start_date, c.end_date) pl;

  select coalesce(sum(case when l.kind = 'add_back' then l.amount end), 0),
         coalesce(sum(case when l.kind = 'deduct'   then l.amount end), 0)
    into v_add, v_ded
    from public.tax_computation_lines(p_computation_id) l;

  -- Schedule 3. A balancing charge is taxable and belongs with the
  -- add-backs; a balancing allowance is relief and belongs with the
  -- allowances, so the two halves of `0664`'s disposal row go to
  -- opposite ends of this computation and must not be netted on the
  -- way in.
  select coalesce(sum(s.claimed + s.balancing_allowance), 0),
         coalesce(sum(s.balancing_charge), 0)
    into v_ca_cur, v_bc
    from public.capital_allowance_schedule(
           c.org_id, c.year_of_assessment) s;

  v_adj := round(v_pbt + v_add + v_bc - v_ded, 2);

  -- An adjusted LOSS. Capital allowances cannot be set against it --
  -- they would only deepen it -- so the whole claim carries forward,
  -- and the loss itself carries forward beside it.
  if v_adj < 0 then
    v_loss := -v_adj;
    v_adj  := 0;
  end if;

  v_ca_av  := round(v_ca_cur + c.capital_allowance_bf, 2);
  v_ca_use := least(v_ca_av, v_adj);
  v_si     := round(v_adj - v_ca_use, 2);

  v_lu := least(c.loss_bf, v_si);
  v_ci := round(v_si - v_lu, 2);

  -- The SME test, and whether it can be taken at all. Null in either
  -- figure means unknown, and unknown charges the standard rate while
  -- SAYING it is unknown -- rather than quietly assuming the company
  -- does not qualify, which is the same number with none of the
  -- warning.
  v_known := c.paid_up_capital is not null
             and c.gross_business_income is not null;

  select r2.* into r
    from public.company_tax_rates r2
   where r2.year_of_assessment = c.year_of_assessment;

  if r is null then
    raise exception
      'No company tax rates for year of assessment %', c.year_of_assessment
      using errcode = 'P0002';
  end if;

  v_sme := v_known
           and c.paid_up_capital <= r.sme_capital_limit
           and c.gross_business_income <= r.sme_turnover_limit;

  if v_sme then
    v_tax := round(least(v_ci, r.sme_band_limit) * r.sme_rate, 2)
             + round(greatest(v_ci - r.sme_band_limit, 0)
                       * r.standard_rate, 2);
  else
    v_tax := round(v_ci * r.standard_rate, 2);
  end if;

  -- s.6A(3): a rebate against the tax, capped at it. Paying more zakat
  -- than the tax charged does not produce a refund.
  v_zakat := least(c.zakat_paid, v_tax);

  return query select
    c.year_of_assessment,
    c.start_date,
    c.end_date,
    round(v_pbt, 2),
    round(v_add, 2),
    round(v_ded, 2),
    round(v_bc, 2),
    v_adj,
    round(v_loss, 2),
    round(v_ca_cur, 2),
    round(c.capital_allowance_bf, 2),
    round(v_ca_use, 2),
    round(v_ca_av - v_ca_use, 2),
    v_si,
    round(c.loss_bf, 2),
    round(v_lu, 2),
    -- What carries forward is what was not used, PLUS this year's own
    -- adjusted loss if there was one.
    round(c.loss_bf - v_lu + v_loss, 2),
    v_ci,
    v_sme,
    v_known,
    v_tax,
    v_zakat,
    round(c.s110_tax_deducted, 2),
    round(c.cp204_paid, 2),
    round(v_tax - v_zakat - c.s110_tax_deducted - c.cp204_paid, 2);
end; $$;

revoke all on function public.tax_computation(uuid) from public, anon;
grant execute on function public.tax_computation(uuid) to authenticated;

comment on function public.tax_computation(uuid) is
  'The Form C working for one basis period, every figure derived from '
  'the ledger, the Schedule 3 schedule and the rates. Not a filing.';

-- ---------------------------------------------------------------------
-- Opening one
-- ---------------------------------------------------------------------

-- The year of assessment comes from the basis period rather than being
-- asked for: a period ending in 2026 is assessed in 2026, and letting
-- somebody type it is letting somebody type it wrongly.
create or replace function public.open_tax_computation(
  p_org_id uuid,
  p_fiscal_year_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id   uuid;
  v_ends date;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select fy.end_date into v_ends
    from public.fiscal_years fy
   where fy.id = p_fiscal_year_id and fy.org_id = p_org_id;

  if v_ends is null then
    raise exception 'No such financial year' using errcode = 'P0002';
  end if;

  -- Opening the same year twice hands back the one that exists rather
  -- than refusing: the button is on a screen, and somebody pressing it
  -- again means "show me it".
  select tc.id into v_id
    from public.tax_computations tc
   where tc.org_id = p_org_id and tc.fiscal_year_id = p_fiscal_year_id;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.tax_computations
    (org_id, fiscal_year_id, year_of_assessment, created_by)
  values
    (p_org_id, p_fiscal_year_id,
     extract(year from v_ends)::integer, auth.uid())
  returning id into v_id;

  return v_id;
end; $$;

revoke all on function public.open_tax_computation(uuid, uuid)
  from public, anon;
grant execute on function public.open_tax_computation(uuid, uuid)
  to authenticated;

comment on function public.open_tax_computation(uuid, uuid) is
  'Starts, or reopens, the computation for a basis period. The year of '
  'assessment is taken from the period''s end date rather than typed.';

-- ---------------------------------------------------------------------
-- On the live feed
--
-- `live_change_feed.sql` asks for a trigger on every table with an
-- `org_id`, and these earn it: a computation is the one document in
-- this product that two people open together at year end, one keying
-- adjustments while the other reads the figures, and a total that only
-- moves on reload is how they disagree about what it says.
-- ---------------------------------------------------------------------
create trigger live_change_insert after insert on public.tax_computations
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.tax_computations
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.tax_computations
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

create trigger live_change_insert after insert on public.tax_adjustments
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.tax_adjustments
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.tax_adjustments
  referencing old table as old_rows
  for each statement execute function app.note_live_change();
