-- =====================================================================
-- iAkauntan :: 0865 the fixed asset register is the ledger's
--
-- `0156` gave the schedule an auditor asks for -- `report_depreciation_
-- history` and `report_asset_movements` -- a refusal for anybody who
-- does not read the ledger. The register those reports are built from
-- was still read by every member with the module: `fixed_assets`,
-- `depreciation_runs` and `depreciation_entries` were `is_org_member`,
-- and so were `depreciation_preview` and `capital_allowance_schedule`.
-- The register screen's totals are, in its own words, "the three
-- figures that have to agree with the balance sheet" -- the balance
-- sheet `0855` withheld.
--
-- Measured on 13 October 2026, locally, as a `sales` member with the
-- role `authenticated`: the director's car at a cost of 240,000.00,
-- accumulated depreciation 48,000.00 and a net book value of
-- 192,000.00, the run's 48,000.00 charge and its entry, and the
-- preview, while both reports refused. And writes asked only
-- `can_write`, so a salesman or a purchaser could register an asset
-- with its cost, or capitalise a bill line.
--
-- Production held 7 assets in 2 companies, and no member outside the
-- ledger roles in either.
--
-- Answered "register to ledger roles":
--
--   * The three select policies ask `app.can_read_ledger`. The
--     restrictive module gates stay as they were.
--   * Registering or editing an asset asks `can_write` and
--     `can_read_ledger` -- the owner, an admin, an accountant or the
--     accounts clerk -- on the policies and in `capitalise_bill_line`,
--     which inserts as its owner and so past them. Deleting one asked
--     `can_admin` already, and disposing of one and running
--     depreciation `can_post`.
--   * `depreciation_preview` and `capital_allowance_schedule` keep
--     their membership refusal, wording and all, and a second follows
--     it: "Insufficient privileges to read the ledger", as `0855`'s.
--     `report_uncapitalised_purchases`, written in SQL, gives nothing.
--
-- Not changed: `create_ticket` asks whether an asset id names one of
-- the company's assets, as its owner. It answers that one question and
-- shows nothing of the asset, and the app never sends one.
--
-- Each function is restated from the migration named above it, its
-- text unchanged but for the guard; `create or replace` keeps its
-- grants.
-- =====================================================================

alter policy fixed_assets_select on public.fixed_assets
  using (app.can_read_ledger(org_id));

alter policy depreciation_runs_select on public.depreciation_runs
  using (app.can_read_ledger(org_id));

alter policy depreciation_entries_select on public.depreciation_entries
  using (app.can_read_ledger(org_id));

alter policy fixed_assets_insert on public.fixed_assets
  with check (app.can_write(org_id) and app.can_read_ledger(org_id)
              and app.has_module(org_id, 'fixed_assets'));

alter policy fixed_assets_update on public.fixed_assets
  using (app.can_write(org_id) and app.can_read_ledger(org_id)
         and app.has_module(org_id, 'fixed_assets'))
  with check (app.can_write(org_id) and app.can_read_ledger(org_id)
              and app.has_module(org_id, 'fixed_assets'));

-- ---------------------------------------------------------------------
-- public.capitalise_bill_line, from `0780`
-- ---------------------------------------------------------------------
create or replace function public.capitalise_bill_line(
  p_line               uuid,
  p_asset_no           text,
  p_name               text default null,
  p_category           text default null,
  p_method             text default 'straight_line',
  p_useful_life_months integer default null,
  p_rate_percent       numeric default null,
  p_residual_value     numeric default 0)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_line  public.purchase_document_lines;
  v_doc   public.purchase_documents;
  v_acct  public.accounts;
  v_cost  numeric(18, 2);
  v_asset uuid;
begin
  select * into v_line from public.purchase_document_lines where id = p_line;
  if v_line.id is null then
    raise exception 'No such bill line.' using errcode = 'P0002';
  end if;
  -- `0865`: the register is the ledger's, so is what goes into it.
  if not (app.can_write(v_line.org_id)
          and app.can_read_ledger(v_line.org_id)) then
    raise exception 'not permitted to capitalise a purchase'
      using errcode = '42501';
  end if;
  if not app.has_module(v_line.org_id, 'fixed_assets') then
    raise exception 'The fixed assets module is not enabled.'
      using errcode = '42501';
  end if;

  select * into v_doc from public.purchase_documents
   where id = v_line.document_id;
  -- `0780`: paid in part or in full is still posted. Its journal is in
  -- the ledger and paying the supplier did not take the cost out.
  if v_doc.status not in ('posted', 'partial', 'completed') then
    raise exception
      '% has not been posted. An asset whose cost is not in the ledger '
      'is one the register can never be reconciled to it.', v_doc.doc_no
      using errcode = '23514';
  end if;

  if exists (select 1 from public.fixed_assets
              where purchase_line_id = p_line and deleted_at is null) then
    raise exception
      'That line has already been capitalised. One line is one lot of '
      'money, and a second asset from it is the same cost depreciated '
      'twice.' using errcode = '23505';
  end if;

  -- The account the line was actually posted to, which is what makes
  -- the register and the ledger agree by construction.
  select * into v_acct from public.accounts where id = v_line.account_id;
  if v_acct.id is null then
    raise exception
      'That line names no account, so there is nothing to say the cost '
      'is sitting in.' using errcode = '23514';
  end if;
  if v_acct.account_subtype <> 'fixed_asset' then
    raise exception
      'That line was coded to % (%), which is not a fixed asset '
      'account. Correct the coding on % first: putting it in the '
      'register now is the register and the ledger disagreeing on '
      'purpose.', v_acct.name, v_acct.code, v_doc.doc_no
      using errcode = '23514';
  end if;

  -- The line's own net amount, in the company's own money. Tax is not
  -- part of cost where it is recoverable, and `line_subtotal` is the
  -- figure the posting used.
  v_cost := round(v_line.line_subtotal * v_doc.exchange_rate, 2);
  if v_cost <= 0 then
    raise exception 'A line worth nothing is not an asset.'
      using errcode = '23514';
  end if;
  if coalesce(p_residual_value, 0) > v_cost then
    raise exception
      'A residual value of % is more than the % the asset cost.',
      p_residual_value, v_cost using errcode = '23514';
  end if;

  insert into public.fixed_assets
    (org_id, asset_no, name, category, asset_account_id,
     acquisition_date, cost, residual_value, method,
     useful_life_months, rate_percent, supplier_id,
     purchase_document_id, purchase_line_id, created_by)
  values (v_line.org_id, btrim(p_asset_no),
          coalesce(nullif(btrim(coalesce(p_name, '')), ''),
                   nullif(v_line.description, ''), btrim(p_asset_no)),
          p_category, v_acct.id,
          v_doc.doc_date, v_cost, coalesce(p_residual_value, 0),
          p_method, p_useful_life_months, p_rate_percent,
          v_doc.contact_id, v_doc.id, v_line.id, auth.uid())
  returning id into v_asset;

  return v_asset;
end $$;

-- ---------------------------------------------------------------------
-- public.depreciation_preview, from `0739`
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.depreciation_preview(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(asset_id uuid, asset_no text, name text, cost numeric, accumulated numeric, charge numeric, net_book_value numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges to read the ledger'
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
$function$;

-- ---------------------------------------------------------------------
-- public.report_uncapitalised_purchases, from `0780`
-- ---------------------------------------------------------------------
create or replace function public.report_uncapitalised_purchases(
  p_org   uuid,
  p_as_at date default null)
returns table (
  line_id       uuid,
  document_id   uuid,
  doc_no        text,
  doc_date      date,
  supplier_name text,
  description   text,
  account_code  text,
  account_name  text,
  amount        numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select l.id, d.id, d.doc_no, d.doc_date, c.name, l.description,
         a.code, a.name,
         round(l.line_subtotal * d.exchange_rate, 2)
    from public.purchase_document_lines l
    join public.purchase_documents d on d.id = l.document_id
    join public.accounts a on a.id = l.account_id
    join public.contacts c on c.id = d.contact_id
   where l.org_id = p_org
     and app.can_read_module(p_org, 'fixed_assets')
     and app.can_read_ledger(p_org)
     and d.status in ('posted', 'partial', 'completed')
     and d.doc_type = 'bill'
     and a.account_subtype = 'fixed_asset'
     and (p_as_at is null or d.doc_date <= p_as_at)
     and not exists (select 1 from public.fixed_assets f
                      where f.purchase_line_id = l.id
                        and f.deleted_at is null)
   order by d.doc_date, d.doc_no, l.line_no;
$$;

-- ---------------------------------------------------------------------
-- public.capital_allowance_schedule, from `0664`
-- ---------------------------------------------------------------------
create or replace function public.capital_allowance_schedule(
  p_org_id uuid,
  p_year   integer)
returns table (
  asset_id       uuid,
  asset_no       text,
  name           text,
  class_code     text,
  class_label    text,
  acquired       date,
  cost           numeric,
  qualifying     numeric,
  initial        numeric,
  annual         numeric,
  prior_claimed  numeric,
  balancing_allowance numeric,
  balancing_charge    numeric,
  claimed        numeric,
  residual       numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  return query
  -- The class is joined LATERALLY and its columns are named one by one.
  -- `(app.ca_class_at(...)).*` would expand the whole composite, which
  -- carries its own `id`, `label`, `notes` and `source` -- and
  -- `fixed_assets` has an `id` too, so every later reference to `id`
  -- would be ambiguous and the function would not compile.
  with asset as (
    select a.id            as asset_id,
           a.asset_no,
           a.name,
           a.acquisition_date,
           a.cost,
           a.ca_class_code,
           a.disposal_date,
           a.disposal_proceeds,
           c.label         as class_label,
           c.initial_rate,
           c.annual_rate,
           c.cost_cap,
           c.small_value_threshold,
           c.aggregate_cap
      from public.fixed_assets a
      join lateral app.ca_class_at(a.ca_class_code, a.acquisition_date) c
        on true
     where a.org_id = p_org_id
       and a.deleted_at is null
       and a.ca_class_code is not null
       -- Not yet bought as at the end of this year of assessment.
       and extract(year from a.acquisition_date) <= p_year
       -- Sold in an EARLIER year: out of the schedule entirely. The year
       -- it was sold in still appears, carrying the balancing
       -- adjustment, which is the row a reviewer looks for.
       and (a.disposal_date is null
            or extract(year from a.disposal_date) >= p_year)
  ),
  base as (
    select s.*,
           app.ca_qualifying_expenditure(s.cost, s.cost_cap) as qe,
           (extract(year from s.acquisition_date))::integer   as first_ya,
           (s.disposal_date is not null
            and extract(year from s.disposal_date) = p_year)  as sold_now,
           (s.small_value_threshold is not null)             as in_small_class,
           (s.small_value_threshold is not null
            and app.ca_qualifying_expenditure(s.cost, s.cost_cap)
                  < s.small_value_threshold)                  as is_small
      from asset s
  ),
  flagged as (
    select b.*,
           (b.first_ya = p_year) as is_first
      from base b
  ),
  -- The aggregate cap on small value assets, which cannot be decided
  -- one row at a time: para 19A writes each asset off in full, but only
  -- up to RM20,000 across all of them in a year.
  --
  -- Allocated in acquisition order, and an asset that does not fit gets
  -- what is left of the cap and no more. What the law then allows is
  -- for the remainder to be claimed at ORDINARY rates instead; that is
  -- not modelled, so this UNDER-claims rather than over-claims for a
  -- company buying more than RM20,000 of small items in a year. The
  -- direction is deliberate and the screen says so. Note also that the
  -- cap does not apply to a resident SME at all.
  allocated as (
    select f.*,
           case
             when not (f.is_small and f.is_first) then null
             else greatest(
                    least(
                      f.qe,
                      f.aggregate_cap
                        - (sum(f.qe) filter (where f.is_small and f.is_first)
                             over (order by f.acquisition_date, f.asset_no
                                   rows between unbounded preceding
                                            and current row)
                           - f.qe)),
                    0)
           end as small_allowed
      from flagged f
  ),
  amounts as (
    select a.*,
           case
             -- Filed under a small value class and NOT under the
             -- threshold, which is not a small value asset at all. It
             -- gets nothing rather than the class's 100%: an asset of
             -- exactly RM2,000 is not under RM2,000, and writing it off
             -- in full because somebody picked the wrong class is the
             -- one direction this must never fail in.
             --
             -- The residual then sits at the whole cost, which is loud
             -- on the schedule and is how somebody notices to reclassify
             -- it. `<` rather than `<=` is one asset's entire treatment.
             when a.in_small_class and not a.is_small then 0
             when a.is_small and a.is_first then a.small_allowed
             when a.is_small then 0
             when a.is_first then round(a.qe * a.initial_rate, 2)
             else 0
           end as ia_raw,
           -- No annual allowance in the year of disposal: the balancing
           -- adjustment replaces it. None at all on a small value asset,
           -- whose whole rate is the initial one.
           case
             when a.in_small_class or a.sold_now then 0
             else round(a.qe * a.annual_rate, 2)
           end as aa_raw,
           -- What the earlier years already gave: the initial allowance
           -- once, and an annual allowance for each year elapsed.
           case
             when a.is_first then 0
             when a.in_small_class and not a.is_small then 0
             when a.is_small then a.qe
             else round(a.qe * a.initial_rate, 2)
                  + round(a.qe * a.annual_rate, 2) * (p_year - a.first_ya)
           end as prior_raw
      from allocated a
  ),
  capped as (
    select m.*,
           -- Nothing may be claimed beyond the qualifying expenditure.
           -- Without this an asset past the end of its life keeps
           -- claiming a full annual allowance every year and the
           -- residual goes negative.
           least(m.prior_raw, m.qe) as prior_capped
      from amounts m
  ),
  final as (
    select c.*,
           least(c.ia_raw, greatest(c.qe - c.prior_capped, 0)) as ia
      from capped c
  ),
  final2 as (
    select f.*,
           least(f.aa_raw, greatest(f.qe - f.prior_capped - f.ia, 0)) as aa
      from final f
  ),
  balancing as (
    select f.*,
           -- Proceeds are restricted in the same proportion the cost
           -- was. Selling the RM300,000 car for RM150,000 is a disposal
           -- of a RM100,000 asset for RM50,000, or the restriction would
           -- be given with one hand and taken back with the other.
           case
             when not f.sold_now then null
             when f.cost > 0 then
               round(coalesce(f.disposal_proceeds, 0) * f.qe / f.cost, 2)
             else 0
           end as restricted_proceeds,
           greatest(f.qe - f.prior_capped - f.ia - f.aa, 0) as residual_before
      from final2 f
  )
  select b.asset_id, b.asset_no, b.name, b.ca_class_code, b.class_label,
         b.acquisition_date, b.cost, b.qe,
         b.ia, b.aa, b.prior_capped,
         case when b.sold_now
              then greatest(b.residual_before - b.restricted_proceeds, 0)
              else 0 end,
         case when b.sold_now
              -- A balancing charge claws back allowances already given
              -- and can never exceed them. Selling a fully written down
              -- lorry for more than it cost is a capital gain, which is
              -- not taxed here.
              then least(
                     greatest(b.restricted_proceeds - b.residual_before, 0),
                     b.prior_capped + b.ia + b.aa)
              else 0 end,
         b.ia + b.aa,
         case when b.sold_now then 0 else b.residual_before end
    from balancing b
   order by b.acquisition_date, b.asset_no;
end; $$;
