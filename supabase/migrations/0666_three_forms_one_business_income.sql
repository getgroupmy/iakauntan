-- =====================================================================
-- Form B and Form P, on the machinery Form C already has
--
-- `0665` computes a company's tax. A sole proprietor and a partnership
-- start from EXACTLY the same place -- the profit the accounts show,
-- the add-backs off the chart, the capital allowances from `0664` --
-- and then diverge completely:
--
--   * **Form C** taxes the company. Chargeable income at 17%/24%.
--   * **Form B** taxes a PERSON. The business is one source among
--     several; employment, rent and dividends join it, personal
--     reliefs come off, and the individual scale applies.
--   * **Form P** taxes NOBODY. A partnership is not a taxable person:
--     it computes a divisible income and allocates it to the partners,
--     each of whom then files their own Form B. The commonest mistake
--     in the whole of this is to charge a partnership tax.
--
-- ---------------------------------------------------------------------
-- One business income, shared by all three
--
-- The temptation is three functions that each recompute the profit and
-- the allowances. They would agree on the day they were written and
-- drift the first time somebody fixed a rounding in one of them -- and
-- a partner's Form B disagreeing with the Form P it came from is the
-- kind of error nobody finds until LHDN does.
--
-- So `app.tax_business_income` is extracted here and `0665`'s
-- `tax_computation` is rewritten to call it. The three forms now
-- cannot disagree about the business half, because there is only one.
--
-- ---------------------------------------------------------------------
-- What is reused rather than rebuilt
--
-- The individual scale and the reliefs catalogue already exist:
-- `0025` built `tax_brackets` and `tax_reliefs` for PCB, which is a
-- monthly estimate of this same annual liability. A second copy of the
-- individual rate scale is a second copy to forget when the Budget
-- moves it, so Form B reads the payroll one.
--
-- That is a real coupling and it is deliberate. If PCB's scale is
-- wrong, both are wrong -- which is better than one being wrong and
-- the other right, with nothing saying which.
--
-- ---------------------------------------------------------------------
-- What this does NOT do
--
-- It does not file, and it does not compute a partner's Form B FROM a
-- Form P automatically. The allocation is produced and the partner's
-- share is a figure somebody carries across, because the partner's own
-- return lives in their own books -- usually not in this system at all.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Which form a computation is
-- ---------------------------------------------------------------------
alter table public.tax_computations
  add column form text not null default 'C'
    check (form in ('C', 'B', 'P'));

comment on column public.tax_computations.form is
  'C for a company, B for an individual with business income, P for a '
  'partnership. The business half of the computation is identical for '
  'all three; everything after the statutory income differs.';

-- Approved donations, s.44(6). A deduction from AGGREGATE income
-- rather than from the business -- which is why it is not one of
-- `0665`'s adjustments: it comes off after the other sources have
-- been added in, and putting it in the wrong place changes the answer
-- whenever there are other sources.
alter table public.tax_computations
  add column approved_donations numeric(18, 2) not null default 0
    check (approved_donations >= 0);

-- ---------------------------------------------------------------------
-- The business half, once
-- ---------------------------------------------------------------------
create or replace function app.tax_business_income(p_computation_id uuid)
returns table (
  profit_before_tax  numeric,
  add_backs          numeric,
  deductions         numeric,
  balancing_charge   numeric,
  adjusted_income    numeric,
  adjusted_loss      numeric,
  ca_current         numeric,
  ca_brought_forward numeric,
  ca_used            numeric,
  ca_carried_forward numeric,
  statutory_income   numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  c        record;
  v_pbt    numeric := 0;
  v_add    numeric := 0;
  v_ded    numeric := 0;
  v_bc     numeric := 0;
  v_ca_cur numeric := 0;
  v_adj    numeric;
  v_loss   numeric := 0;
  v_ca_av  numeric;
  v_ca_use numeric;
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

  select coalesce(sum(case when pl.account_type = 'revenue'
                           then pl.amount else -pl.amount end), 0)
    into v_pbt
    from public.report_profit_loss(c.org_id, c.start_date, c.end_date) pl;

  select coalesce(sum(case when l.kind = 'add_back' then l.amount end), 0),
         coalesce(sum(case when l.kind = 'deduct'   then l.amount end), 0)
    into v_add, v_ded
    from public.tax_computation_lines(p_computation_id) l;

  select coalesce(sum(s.claimed + s.balancing_allowance), 0),
         coalesce(sum(s.balancing_charge), 0)
    into v_ca_cur, v_bc
    from public.capital_allowance_schedule(
           c.org_id, c.year_of_assessment) s;

  v_adj := round(v_pbt + v_add + v_bc - v_ded, 2);

  if v_adj < 0 then
    v_loss := -v_adj;
    v_adj  := 0;
  end if;

  v_ca_av  := round(v_ca_cur + c.capital_allowance_bf, 2);
  v_ca_use := least(v_ca_av, v_adj);

  return query select
    round(v_pbt, 2), round(v_add, 2), round(v_ded, 2), round(v_bc, 2),
    v_adj, round(v_loss, 2),
    round(v_ca_cur, 2), round(c.capital_allowance_bf, 2),
    round(v_ca_use, 2), round(v_ca_av - v_ca_use, 2),
    round(v_adj - v_ca_use, 2);
end; $$;

revoke all on function app.tax_business_income(uuid)
  from public, anon, authenticated;

comment on function app.tax_business_income(uuid) is
  'The business half of a tax computation: profit, add-backs, adjusted '
  'income, capital allowances, statutory income. Identical for Form C, '
  'Form B and Form P, and extracted so the three cannot disagree about '
  'it -- a partner''s Form B disagreeing with the Form P it came from '
  'is an error nobody finds until LHDN does.';

-- `0665`'s function, rewritten to call it. Same signature and same
-- answers; the arithmetic simply lives in one place now.
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
  c       record;
  b       record;
  r       record;
  v_lu    numeric;
  v_ci    numeric;
  v_sme   boolean;
  v_known boolean;
  v_tax   numeric;
  v_zakat numeric;
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

  select * into b from app.tax_business_income(p_computation_id);

  v_lu := least(c.loss_bf, b.statutory_income);
  v_ci := round(b.statutory_income - v_lu, 2);

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

  v_zakat := least(c.zakat_paid, v_tax);

  return query select
    c.year_of_assessment, c.start_date, c.end_date,
    b.profit_before_tax, b.add_backs, b.deductions, b.balancing_charge,
    b.adjusted_income, b.adjusted_loss,
    b.ca_current, b.ca_brought_forward, b.ca_used, b.ca_carried_forward,
    b.statutory_income,
    round(c.loss_bf, 2), round(v_lu, 2),
    round(c.loss_bf - v_lu + b.adjusted_loss, 2),
    v_ci, v_sme, v_known, v_tax, v_zakat,
    round(c.s110_tax_deducted, 2), round(c.cp204_paid, 2),
    round(v_tax - v_zakat - c.s110_tax_deducted - c.cp204_paid, 2);
end; $$;

revoke all on function public.tax_computation(uuid) from public, anon;
grant execute on function public.tax_computation(uuid) to authenticated;

-- =====================================================================
-- Form B: an individual with business income
-- =====================================================================

-- ---------------------------------------------------------------------
-- The other sources
--
-- A person's business is ONE source. Employment, rent, interest and a
-- share of a partnership join it at aggregate income, and none of them
-- is in this company's ledger -- they are facts about a person, typed.
-- ---------------------------------------------------------------------
create table public.tax_other_income (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null
                   references public.organizations (id) on delete cascade,
  computation_id uuid not null
                   references public.tax_computations (id) on delete cascade,
  constraint tax_other_income_computation_same_org
    foreign key (org_id, computation_id)
    references public.tax_computations (org_id, id) on delete cascade,

  kind   text not null check (kind in (
           'employment', 'rental', 'interest', 'dividend',
           'partnership', 'royalty', 'pension', 'other')),
  label  text,
  amount numeric(18, 2) not null check (amount >= 0),

  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

comment on table public.tax_other_income is
  'Income a person has that this company''s ledger does not: '
  'employment, rent, a share of a partnership. Joins the business at '
  'aggregate income. Form B only.';

create index tax_other_income_computation_idx
  on public.tax_other_income (computation_id, sort_order);

alter table public.tax_other_income enable row level security;
create policy tax_other_income_select on public.tax_other_income
  for select to authenticated using (app.is_org_member(org_id));
create policy tax_other_income_write on public.tax_other_income
  for all to authenticated
  using (app.can_post(org_id)) with check (app.can_post(org_id));
grant select, insert, update, delete on public.tax_other_income
  to authenticated;

-- ---------------------------------------------------------------------
-- What the person claims
--
-- `relief_code` points at `0025`'s catalogue where there is a row for
-- it, and is null for a claim that has no catalogue entry -- the
-- catalogue exists for PCB and does not carry every relief on a Form
-- B. The amount is always stated: a relief with a cap still has to be
-- claimed at a figure, and copying the cap in as the claim is how
-- somebody claims RM8,000 of medical expenses they did not incur.
-- ---------------------------------------------------------------------
create table public.tax_relief_claims (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null
                   references public.organizations (id) on delete cascade,
  computation_id uuid not null
                   references public.tax_computations (id) on delete cascade,
  constraint tax_relief_claims_computation_same_org
    foreign key (org_id, computation_id)
    references public.tax_computations (org_id, id) on delete cascade,

  -- Plain text, with no foreign key, and that is not laziness.
  -- `0025`'s `tax_reliefs` is unique on (schedule_id, code) because a
  -- relief is a fact about a YEAR -- the lifestyle cap has moved
  -- twice. A key on the code alone cannot exist, and a key on the pair
  -- would tie a claim to one year's schedule and break when the
  -- schedule for the next year arrives.
  relief_code text,
  label       text not null,
  amount      numeric(18, 2) not null check (amount >= 0),

  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),

  constraint tax_relief_claim_has_a_label
    check (nullif(btrim(label), '') is not null)
);

comment on table public.tax_relief_claims is
  'Personal reliefs claimed on a Form B. The amount is always stated '
  'even where the catalogue carries a cap: copying the cap in as the '
  'claim is how somebody claims relief they did not incur.';

create index tax_relief_claims_computation_idx
  on public.tax_relief_claims (computation_id, sort_order);

alter table public.tax_relief_claims enable row level security;
create policy tax_relief_claims_select on public.tax_relief_claims
  for select to authenticated using (app.is_org_member(org_id));
create policy tax_relief_claims_write on public.tax_relief_claims
  for all to authenticated
  using (app.can_post(org_id)) with check (app.can_post(org_id));
grant select, insert, update, delete on public.tax_relief_claims
  to authenticated;

-- ---------------------------------------------------------------------
-- The individual rebate
--
-- A flat amount off the TAX for a chargeable income at or under a
-- threshold. Not a relief and not a band: it comes off after the tax
-- is computed, like zakat, and is capped at the tax the same way.
-- ---------------------------------------------------------------------
create table public.individual_tax_rebates (
  year_of_assessment integer primary key,
  threshold          numeric(18, 2) not null,
  amount             numeric(18, 2) not null,
  source             text,
  is_verified        boolean not null default false,
  notes              text
);

alter table public.individual_tax_rebates enable row level security;
create policy individual_tax_rebates_read on public.individual_tax_rebates
  for select to authenticated using (true);
create policy individual_tax_rebates_write on public.individual_tax_rebates
  for all to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());
grant select on public.individual_tax_rebates to authenticated;
grant insert, update, delete on public.individual_tax_rebates
  to authenticated;

insert into public.individual_tax_rebates
  (year_of_assessment, threshold, amount, source, notes)
select y, 35000, 400, 'Published rates for YA ' || y,
       'Seeded unverified. Check against the Act before filing.'
  from generate_series(2020, 2030) as y;

-- ---------------------------------------------------------------------
-- Tax on a chargeable income, at the individual scale
--
-- Reads `0025`'s `tax_brackets`, which PCB already uses. Cumulative
-- tax plus the marginal slice, which is how the scale is published and
-- why the table carries a `cumulative_tax` column.
-- ---------------------------------------------------------------------
create or replace function app.individual_tax_on(
  p_chargeable numeric, p_on date)
returns numeric
language plpgsql stable
set search_path = public, app, pg_temp
as $$
declare b record;
begin
  if p_chargeable is null or p_chargeable <= 0 then
    return 0;
  end if;

  select tb.* into b
    from public.tax_brackets tb
    join public.statutory_schedules s on s.id = tb.schedule_id
   where s.body = 'pcb'
     and s.effective_from <= p_on
     and (s.effective_to is null or s.effective_to > p_on)
     and tb.chargeable_from <= p_chargeable
   order by s.effective_from desc, tb.chargeable_from desc
   limit 1;

  if b is null then
    raise exception 'No individual tax scale in force at %', p_on
      using errcode = 'P0002';
  end if;

  -- The band's own floor, not `chargeable_from`. The published scale
  -- starts each band a sen above the last -- 5,000.01 -- so the slice
  -- taxed at the marginal rate is measured from 5,000.
  --
  -- A mutant that drops the `floor` SURVIVES, and that is written down
  -- rather than left to be found: the sen is worth at most 0.003 of
  -- tax at the top rate, which rounds away at two decimal places in
  -- every band. It is kept because it is what the scale MEANS -- the
  -- band runs from five thousand, and the sen is an artefact of
  -- printing two adjacent bands without overlapping them.
  return round(
    b.cumulative_tax
    + (p_chargeable - floor(b.chargeable_from)) * b.rate_percent / 100,
    2);
end; $$;

revoke all on function app.individual_tax_on(numeric, date)
  from public, anon, authenticated;

comment on function app.individual_tax_on(numeric, date) is
  'Tax on a chargeable income at the resident individual scale, read '
  'from the same `tax_brackets` PCB uses. One scale, so PCB and the '
  'Form B it estimates cannot disagree.';

-- ---------------------------------------------------------------------
-- The Form B computation
-- ---------------------------------------------------------------------
create or replace function public.tax_computation_individual(
  p_computation_id uuid)
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
  ca_used              numeric,
  ca_carried_forward   numeric,
  statutory_business   numeric,
  other_income         numeric,
  aggregate_income     numeric,
  approved_donations   numeric,
  donations_allowed    numeric,
  total_income         numeric,
  reliefs_claimed      numeric,
  chargeable_income    numeric,
  tax_charged          numeric,
  rebate               numeric,
  zakat_rebate         numeric,
  s110_tax_deducted    numeric,
  instalments_paid     numeric,
  tax_payable          numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  c        record;
  b        record;
  v_other  numeric := 0;
  v_agg    numeric;
  v_don    numeric;
  v_total  numeric;
  v_rel    numeric := 0;
  v_ci     numeric;
  v_tax    numeric;
  v_reb    numeric := 0;
  v_zakat  numeric;
  v_thr    record;
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

  select * into b from app.tax_business_income(p_computation_id);

  select coalesce(sum(oi.amount), 0) into v_other
    from public.tax_other_income oi
   where oi.computation_id = p_computation_id;

  v_agg := round(b.statutory_income + v_other, 2);

  -- s.44(6): a deduction from AGGREGATE income, and it cannot take it
  -- below nothing. A donation larger than the income is not a loss to
  -- carry anywhere; the excess is simply lost.
  v_don := least(c.approved_donations, v_agg);
  v_total := round(v_agg - v_don, 2);

  select coalesce(sum(rc.amount), 0) into v_rel
    from public.tax_relief_claims rc
   where rc.computation_id = p_computation_id;

  -- Reliefs come off TOTAL income and stop at nothing. More relief
  -- than income is not a refund and not a carry-forward.
  v_ci := round(greatest(v_total - v_rel, 0), 2);

  v_tax := app.individual_tax_on(v_ci, c.end_date);

  select ir.* into v_thr
    from public.individual_tax_rebates ir
   where ir.year_of_assessment = c.year_of_assessment;

  if v_thr is not null and v_ci > 0 and v_ci <= v_thr.threshold then
    v_reb := least(v_thr.amount, v_tax);
  end if;

  -- Zakat after the rebate, and capped at what is left. Two reliefs
  -- against the same tax cannot between them exceed it.
  v_zakat := least(c.zakat_paid, greatest(v_tax - v_reb, 0));

  return query select
    c.year_of_assessment, c.start_date, c.end_date,
    b.profit_before_tax, b.add_backs, b.deductions, b.balancing_charge,
    b.adjusted_income, b.adjusted_loss,
    b.ca_current, b.ca_used, b.ca_carried_forward, b.statutory_income,
    round(v_other, 2), v_agg,
    round(c.approved_donations, 2), round(v_don, 2), v_total,
    round(v_rel, 2), v_ci,
    v_tax, round(v_reb, 2), round(v_zakat, 2),
    round(c.s110_tax_deducted, 2), round(c.cp204_paid, 2),
    round(v_tax - v_reb - v_zakat - c.s110_tax_deducted - c.cp204_paid, 2);
end; $$;

revoke all on function public.tax_computation_individual(uuid)
  from public, anon;
grant execute on function public.tax_computation_individual(uuid)
  to authenticated;

comment on function public.tax_computation_individual(uuid) is
  'The Form B working: the business as one source among several, less '
  'approved donations and personal reliefs, at the resident individual '
  'scale. `cp204_paid` carries CP500 instalments for an individual -- '
  'the column is older than the form.';

-- =====================================================================
-- Form P: a partnership, which is not a taxable person
-- =====================================================================

-- ---------------------------------------------------------------------
-- The partners
--
-- A salary to a partner and interest on their capital are NOT expenses
-- of the partnership -- a partner cannot employ themselves. They are
-- APPROPRIATIONS of profit: added back to reach the divisible income,
-- then handed to that partner as part of their own share.
--
-- The accounts almost always show them as expenses, because that is
-- how the partners think of them, which is exactly why they are held
-- here rather than being hunted for in the ledger.
-- ---------------------------------------------------------------------
create table public.tax_partners (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null
                   references public.organizations (id) on delete cascade,
  computation_id uuid not null
                   references public.tax_computations (id) on delete cascade,
  constraint tax_partners_computation_same_org
    foreign key (org_id, computation_id)
    references public.tax_computations (org_id, id) on delete cascade,

  name           text not null,
  tax_reference  text,

  -- Of the divisible income. Percent rather than a fraction because
  -- that is how a partnership deed writes it.
  share_percent  numeric(9, 4) not null default 0
                   check (share_percent >= 0 and share_percent <= 100),

  -- Appropriations, which belong to this partner alone.
  salary         numeric(18, 2) not null default 0 check (salary >= 0),
  interest_on_capital numeric(18, 2) not null default 0
                   check (interest_on_capital >= 0),

  sort_order     integer not null default 0,
  created_at     timestamptz not null default now(),

  constraint tax_partner_has_a_name
    check (nullif(btrim(name), '') is not null)
);

comment on table public.tax_partners is
  'Who shares a partnership''s income, in what ratio, and what they '
  'were appropriated. A salary to a partner is not an expense of the '
  'partnership -- it is added back and handed to that partner.';

create index tax_partners_computation_idx
  on public.tax_partners (computation_id, sort_order);

alter table public.tax_partners enable row level security;
create policy tax_partners_select on public.tax_partners
  for select to authenticated using (app.is_org_member(org_id));
create policy tax_partners_write on public.tax_partners
  for all to authenticated
  using (app.can_post(org_id)) with check (app.can_post(org_id));
grant select, insert, update, delete on public.tax_partners
  to authenticated;

-- ---------------------------------------------------------------------
-- The allocation
--
-- The partnership pays nothing. This produces what each partner
-- carries into their own Form B, which is the whole output of a Form P.
-- ---------------------------------------------------------------------
create or replace function public.tax_partnership_allocation(
  p_computation_id uuid)
returns table (
  partner_id       uuid,
  name             text,
  tax_reference    text,
  share_percent    numeric,
  salary           numeric,
  interest_on_capital numeric,
  share_of_divisible  numeric,
  capital_allowances  numeric,
  statutory_income    numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  c            record;
  b            record;
  v_divisible  numeric;
begin
  select tc.* into c from public.tax_computations tc
   where tc.id = p_computation_id;

  if c is null then
    raise exception 'No such computation' using errcode = 'P0002';
  end if;
  if not app.is_org_member(c.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select * into b from app.tax_business_income(p_computation_id);

  -- THE ASSUMPTION, stated because it decides every figure below: the
  -- accounts EXPENSED the partners' salaries and interest, which is
  -- what a partnership's books almost always do.
  --
  -- On that assumption the arithmetic collapses, and it is worth
  -- following once. The partnership's true adjusted income is what the
  -- accounts show PLUS the appropriations added back -- a partner
  -- cannot employ themselves. The divisible income is then that, LESS
  -- the appropriations handed to the partners who earned them. The two
  -- cancel, so:
  --
  --     divisible income = adjusted income, as the accounts computed it
  --
  -- and each partner takes their share of it plus their own salary and
  -- interest. The total allocated comes to the adjusted income plus the
  -- appropriations, which is the partnership's real figure --
  -- `tax_computation.sql` asserts exactly that.
  --
  -- Where a partnership does NOT expense them -- showing them below the
  -- line as an appropriation of profit -- this over-allocates by the
  -- appropriations. That case is not modelled, and the screen says so
  -- beside the total rather than leaving it to be discovered.
  --
  -- Left negative where it is negative. A divisible LOSS is shared in
  -- the same ratio and each partner sets their share against their own
  -- other income; clamping it at nothing would hand every partner a
  -- share of zero and lose the relief entirely.
  v_divisible := b.adjusted_income;

  return query
  select p.id, p.name, p.tax_reference, p.share_percent,
         p.salary, p.interest_on_capital,
         round(v_divisible * p.share_percent / 100, 2),
         -- Allowances follow the same ratio. They belong to the
         -- partners, not to the partnership, because the partnership
         -- has no income to set them against.
         round(b.ca_current * p.share_percent / 100, 2),
         round(p.salary + p.interest_on_capital
               + v_divisible * p.share_percent / 100
               - b.ca_current * p.share_percent / 100, 2)
    from public.tax_partners p
   where p.computation_id = p_computation_id
   order by p.sort_order, p.name;
end; $$;

revoke all on function public.tax_partnership_allocation(uuid)
  from public, anon;
grant execute on function public.tax_partnership_allocation(uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- On the live feed
--
-- `live_change_feed.sql` asks for a trigger on every table with an
-- `org_id`, and these three earn it for the reason `0665`'s did: a
-- computation is worked on by two people at once at year end, and a
-- partner allocation that only moves on reload is how they come to
-- disagree about what it says.
-- ---------------------------------------------------------------------
create trigger live_change_insert after insert on public.tax_other_income
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.tax_other_income
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.tax_other_income
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

create trigger live_change_insert after insert on public.tax_relief_claims
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.tax_relief_claims
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.tax_relief_claims
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

create trigger live_change_insert after insert on public.tax_partners
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.tax_partners
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.tax_partners
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

-- ---------------------------------------------------------------------
-- The head of a Form P
--
-- Separate from the allocation because the allocation is one row per
-- partner and these are one row for the partnership. It also carries
-- the two figures that catch a half-entered Form P:
--
--   * `shares_total`, which must be 100. A partnership whose ratios
--     come to 90 allocates nine tenths of its income and the missing
--     tenth appears nowhere -- the allocation still adds up, down its
--     own column, to the wrong number.
--   * `total_allocated`, which must equal the adjusted income plus the
--     appropriations. That is the identity the whole form rests on and
--     it is cheaper to state than to trust.
-- ---------------------------------------------------------------------
create or replace function public.tax_partnership_summary(
  p_computation_id uuid)
returns table (
  adjusted_income   numeric,
  appropriations    numeric,
  divisible_income  numeric,
  partnership_adjusted numeric,
  total_allocated   numeric,
  shares_total      numeric,
  partner_count     integer)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  c        record;
  b        record;
  v_approp numeric := 0;
  v_shares numeric := 0;
  v_count  integer := 0;
  v_total  numeric := 0;
begin
  select tc.* into c from public.tax_computations tc
   where tc.id = p_computation_id;

  if c is null then
    raise exception 'No such computation' using errcode = 'P0002';
  end if;
  if not app.is_org_member(c.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select * into b from app.tax_business_income(p_computation_id);

  select coalesce(sum(p.salary + p.interest_on_capital), 0),
         coalesce(sum(p.share_percent), 0),
         count(*)
    into v_approp, v_shares, v_count
    from public.tax_partners p
   where p.computation_id = p_computation_id;

  select coalesce(sum(a.statutory_income), 0) into v_total
    from public.tax_partnership_allocation(p_computation_id) a;

  return query select
    b.adjusted_income,
    round(v_approp, 2),
    -- The divisible income IS the adjusted income the accounts
    -- produced; see the allocation function for why the add-back and
    -- the hand-out cancel.
    b.adjusted_income,
    round(b.adjusted_income + v_approp, 2),
    round(v_total, 2),
    round(v_shares, 4),
    v_count;
end; $$;

revoke all on function public.tax_partnership_summary(uuid)
  from public, anon;
grant execute on function public.tax_partnership_summary(uuid)
  to authenticated;

comment on function public.tax_partnership_summary(uuid) is
  'The head of a Form P, and the two figures that catch a half-entered '
  'one: the shares must come to 100, and the total allocated must come '
  'to the adjusted income plus the appropriations.';
