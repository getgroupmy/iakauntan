-- ---------------------------------------------------------------------
-- 0455  Two months, and the month after
-- ---------------------------------------------------------------------
-- Measured: this schema knows a company is SST-registered, knows what
-- rate every line was taxed at, and has `report_sst_summary(org, from,
-- to)` -- which takes **any two dates somebody types**. Searched for a
-- taxable period, a return, or a filing deadline: nothing. Compare
-- `corp_filings`, `fs_deadlines` and `property_statutory_due`, which
-- all exist because SSM and LHDN dates were treated as arithmetic
-- rather than as something the user remembers.
--
-- SST is not remembered. It is bi-monthly, which is a rhythm nobody
-- keeps in their head, and it is late the day after the deadline with a
-- penalty attached.
--
-- ### The rule, as this implements it
--
-- Sales Tax Act 2018 and Service Tax Act 2018, and RMCD's own guide:
--
--   * A **taxable period** is two calendar months ending on the last
--     day of a month.
--   * A registered person's **first** taxable period begins on the day
--     they are registered and ends on the last day of the *following*
--     month. Every period after that is a two-month block, so the
--     cycle a company is on is decided by when it registered -- there
--     is nothing to choose and nothing to type. Registered on 15 April
--     gives 15 Apr - 31 May, then Jun-Jul, Aug-Sep, and so on.
--   * The **return and the payment** are due not later than the last
--     day of the month following the end of the taxable period. The
--     period ending 31 May is due 30 June.
--
-- Two things are settable because the law allows them and the
-- arithmetic cannot know:
--
--   * `sst_period_months` -- one, for a person approved to file
--     monthly. Two otherwise, which is everybody else.
--   * `sst_period_ends_month` -- the month a period ends on, for a
--     person the Director General put on a different cycle. Null
--     means "work it out from the registration date", which is the
--     answer for almost every company. Only the **parity** of this is
--     read: a two-month cycle has exactly two possible alignments.
--
-- ### What the return declares, and what it does not
--
-- Output tax only. SST is a single-stage tax with **no input tax
-- credit** -- a registered manufacturer gets relief by buying exempt,
-- not by claiming back -- so a return that netted purchases off sales
-- the way a GST return does would understate the liability by exactly
-- the amount of tax the company paid its own suppliers. That is a
-- refund the company is not entitled to, calculated for them. The
-- summary here therefore reports the output side, and purchases stay
-- where `report_sst_summary` already puts them: on a report, not in a
-- return.
--
-- ### The clock this asks
--
-- `app.today()`, never `current_date`. `malaysian_clock.sql` scans
-- every function in `public` and `app` for a date taken from the
-- session, and it caught all three of the readers here on the first
-- full run -- which is what that assertion is for. A tax deadline read
-- in the caller's time zone is wrong for a company in Kuala Lumpur
-- being looked at from anywhere else, and it is wrong by exactly one
-- day, on the day it matters.
--
-- ### Deadlines that land on a Sunday
--
-- They stay on the Sunday. RMCD does not extend the SST-02 date for a
-- weekend or a public holiday the way some filing regimes do, and a
-- system that quietly moved the date would be telling a company it had
-- longer than it has. Where this schema does roll a date -- the SLA
-- clock in ticketing -- it is because the contract says so.
--
-- ### Mutants
--
-- Seven, restated into a built database and run against
-- `supabase/tests/sst_taxable_period.sql`. Seven kills, each on a
-- different assertion, and every one of them a mistake somebody could
-- make in good faith:
--
--   * the return due on the last day of the period rather than a month
--     after -- killed by "the return is due a month after the period",
--     which read 2026-05-31 for 2026-06-30. A company told this would
--     file a month early every time, which is not a penalty but is a
--     month of working capital;
--   * the cycle pinned to the calendar -- periods always ending in an
--     even month -- rather than to the registration date. Killed by
--     "and ends with the month after that", 2026-04-30 for 2026-05-31.
--     **This is the plausible wrong answer**: it is what most software
--     does, and it is right for exactly half of all registrants;
--   * three-month periods, the quarter that is not one here -- killed
--     by "the next day is in the next one", 2026-07-01 for 2026-06-01;
--   * input tax brought into the return, GST-style -- killed by "and
--     tax the company paid its own suppliers is not deducted", which
--     read **560 where 400 was owed**. Written as a sum over both
--     directions it inflates rather than deflates; either way the
--     return stops being the amount due;
--   * a return filed against any date at all rather than the end of a
--     period -- killed by "a return can only be filed for a whole
--     period";
--   * filing open to anybody in the company -- killed by "but not
--     everybody can file it". An SST-02 is a statement to the Customs
--     Department about what the company owes;
--   * a period filed before it has ended -- killed by "nor before the
--     period has ended".
-- ---------------------------------------------------------------------

alter table public.organizations
  add column sst_period_months    smallint not null default 2,
  add column sst_period_ends_month smallint;

alter table public.organizations
  add constraint sst_period_months_is_one_or_two
  check (sst_period_months in (1, 2));

alter table public.organizations
  add constraint sst_period_ends_month_is_a_month
  check (sst_period_ends_month is null
         or sst_period_ends_month between 1 and 12);

-- ---------------------------------------------------------------------
-- Which period a date falls in
-- ---------------------------------------------------------------------
create or replace function app.sst_period_for(p_org_id uuid, p_on date)
returns table (
  period_start date,
  period_end   date,
  due_date     date,
  is_first     boolean)
language plpgsql stable
set search_path = public, app, pg_temp
as $$
declare
  v_org    public.organizations;
  v_anchor date;      -- last day of the first taxable period
  v_m0     integer;   -- that month, as a month index
  v_m      integer;   -- the asked-about month, likewise
  v_k      integer;
  v_endm   integer;
  v_end    date;
  v_start  date;
begin
  select * into v_org from public.organizations o where o.id = p_org_id;
  if v_org.id is null or not coalesce(v_org.is_sst_registered, false)
     or v_org.sst_registered_from is null
     or p_on < v_org.sst_registered_from
  then
    return;   -- nothing to declare, and no period to declare it in
  end if;

  -- Monthly, for a person approved to file that way.
  if v_org.sst_period_months = 1 then
    v_end   := (date_trunc('month', p_on)
                + interval '1 month - 1 day')::date;
    v_start := greatest(date_trunc('month', p_on)::date,
                        v_org.sst_registered_from);
    return query select
      v_start, v_end,
      (date_trunc('month', v_end) + interval '2 months - 1 day')::date,
      v_start = v_org.sst_registered_from;
    return;
  end if;

  -- The first period ends on the last day of the month *after* the one
  -- the company registered in -- which is what sets the cycle. An
  -- explicit month from the Director General overrides it, and only
  -- its parity matters: a two-month cycle has two alignments and no
  -- more.
  if v_org.sst_period_ends_month is not null then
    v_m0 := extract(year from v_org.sst_registered_from)::integer * 12
          + v_org.sst_period_ends_month;
    if v_m0 < extract(year from v_org.sst_registered_from)::integer * 12
            + extract(month from v_org.sst_registered_from)::integer then
      v_m0 := v_m0 + 12;
    end if;
    -- Step back to the first such month-end on or after registration.
    while v_m0 - 2 >= extract(year from v_org.sst_registered_from)::integer * 12
                    + extract(month from v_org.sst_registered_from)::integer
    loop
      v_m0 := v_m0 - 2;
    end loop;
  else
    v_m0 := extract(year from v_org.sst_registered_from)::integer * 12
          + extract(month from v_org.sst_registered_from)::integer + 1;
  end if;

  v_anchor := (make_date((v_m0 - 1) / 12, ((v_m0 - 1) % 12) + 1, 1)
               + interval '1 month - 1 day')::date;

  if p_on <= v_anchor then
    return query select
      v_org.sst_registered_from, v_anchor,
      (date_trunc('month', v_anchor) + interval '2 months - 1 day')::date,
      true;
    return;
  end if;

  v_m := extract(year from p_on)::integer * 12
       + extract(month from p_on)::integer;

  -- Whole two-month blocks between the first period and this date.
  v_k    := (v_m - v_m0 - 1) / 2;
  v_endm := v_m0 + 2 * (v_k + 1);

  v_end := (make_date((v_endm - 1) / 12, ((v_endm - 1) % 12) + 1, 1)
            + interval '1 month - 1 day')::date;
  v_start := make_date((v_endm - 2) / 12, ((v_endm - 2) % 12) + 1, 1);

  return query select
    v_start, v_end,
    (date_trunc('month', v_end) + interval '2 months - 1 day')::date,
    false;
end;
$$;

-- ---------------------------------------------------------------------
-- Where a return goes once it has been filed
-- ---------------------------------------------------------------------
create table public.sst_returns (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id)
                  on delete cascade,
  period_start  date not null,
  period_end    date not null,
  due_date      date not null,
  tax_declared  numeric(18,2) not null default 0,
  reference     text,
  filed_at      timestamptz not null default now(),
  filed_by      uuid references auth.users (id) on delete set null,
  created_at    timestamptz not null default now(),
  unique (org_id, period_end),
  constraint sst_return_period_runs_forwards check (period_end >= period_start)
);

create index sst_returns_due_idx on public.sst_returns (org_id, due_date desc);

alter table public.sst_returns enable row level security;

create policy sst_returns_select on public.sst_returns
  for select using (app.is_org_member(org_id));

-- Written only through `file_sst_return`, which is what stamps who and
-- when. A return that could be inserted directly could be inserted
-- with somebody else's name on it.
revoke all on public.sst_returns from public;
grant select on public.sst_returns to authenticated;

create trigger audit_changes
  after insert or delete or update on public.sst_returns
  for each row execute function app.write_audit_log();

-- ---------------------------------------------------------------------
-- The periods, with what is owed and whether it went in
-- ---------------------------------------------------------------------
create or replace function public.sst_taxable_periods(
  p_org_id uuid,
  p_from   date default null,
  p_to     date default null)
returns table (
  period_start date,
  period_end   date,
  due_date     date,
  is_first     boolean,
  output_tax   numeric,
  filed_at     timestamptz,
  reference    text)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org   public.organizations;
  v_from  date;
  v_to    date;
  v_cur   date;
  r       record;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of this organization' using errcode = '42501';
  end if;

  select * into v_org from public.organizations o where o.id = p_org_id;
  if v_org.id is null or not coalesce(v_org.is_sst_registered, false)
     or v_org.sst_registered_from is null then
    return;
  end if;

  v_from := greatest(coalesce(p_from, v_org.sst_registered_from),
                     v_org.sst_registered_from);
  v_to   := coalesce(p_to, app.today());

  v_cur := v_from;
  while v_cur <= v_to loop
    select * into r from app.sst_period_for(p_org_id, v_cur);
    -- No period covers this date, which can only mean it is before
    -- registration. Stopping is the honest answer, and it is also what
    -- keeps this loop finite: `v_cur` advances off the period, so a
    -- date with no period would otherwise never move.
    exit when r.period_end is null;

    period_start := r.period_start;
    period_end   := r.period_end;
    due_date     := r.due_date;
    is_first     := r.is_first;

    select coalesce(sum(s.tax_amount), 0) into output_tax
      from public.report_sst_summary(p_org_id, r.period_start, r.period_end) s
     where s.direction = 'output';

    select f.filed_at, f.reference into filed_at, reference
      from public.sst_returns f
     where f.org_id = p_org_id and f.period_end = r.period_end;

    return next;
    v_cur := r.period_end + 1;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Filing one
-- ---------------------------------------------------------------------
create or replace function public.file_sst_return(
  p_org_id     uuid,
  p_period_end date,
  p_amount     numeric,
  p_reference  text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_p  record;
  v_id uuid;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Only somebody who may post the books may file a return'
      using errcode = '42501';
  end if;

  select * into v_p from app.sst_period_for(p_org_id, p_period_end);
  if v_p.period_end is null or v_p.period_end <> p_period_end then
    raise exception
      'That is not the end of a taxable period for this company. '
      'A taxable period ends on the last day of a month, and which '
      'months is decided by when the company registered.'
      using errcode = '22007';
  end if;

  -- A period cannot be filed before it has finished. The return
  -- declares what was charged in it, and that is not known yet.
  if p_period_end >= app.today() then
    raise exception 'That period has not ended yet.' using errcode = '22007';
  end if;

  insert into public.sst_returns
    (org_id, period_start, period_end, due_date, tax_declared, reference,
     filed_by)
  values (p_org_id, v_p.period_start, v_p.period_end, v_p.due_date,
          round(coalesce(p_amount, 0), 2), nullif(btrim(p_reference), ''),
          auth.uid())
  on conflict (org_id, period_end) do update
     set tax_declared = excluded.tax_declared,
         reference    = excluded.reference,
         filed_at     = now(),
         filed_by     = excluded.filed_by
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- What is due, for the compliance list
-- ---------------------------------------------------------------------
create or replace function public.report_sst_due(
  p_org_id     uuid,
  p_within_days integer default 60)
returns table (
  period_start date,
  period_end   date,
  due_date     date,
  days_left    integer,
  output_tax   numeric,
  is_overdue   boolean)
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select p.period_start, p.period_end, p.due_date,
         (p.due_date - app.today())::integer,
         p.output_tax,
         p.due_date < app.today()
    from public.sst_taxable_periods(
           p_org_id,
           (app.today() - interval '1 year')::date,
           app.today()) p
   where p.filed_at is null
     and p.period_end < app.today()
     and p.due_date <= app.today() + coalesce(p_within_days, 60)
   order by p.due_date;
$$;

revoke all on function public.sst_taxable_periods(uuid, date, date) from public;
revoke all on function public.file_sst_return(uuid, date, numeric, text)
  from public;
revoke all on function public.report_sst_due(uuid, integer) from public;

grant execute on function public.sst_taxable_periods(uuid, date, date)
  to authenticated;
grant execute on function public.file_sst_return(uuid, date, numeric, text)
  to authenticated;
grant execute on function public.report_sst_due(uuid, integer)
  to authenticated;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(
    to_regprocedure('app.sst_period_for(uuid, date)'));
  v_per text := pg_get_functiondef(
    to_regprocedure('public.sst_taxable_periods(uuid, date, date)'));
begin
  -- The deadline is the month after the period, not the period itself.
  if position('interval ''2 months - 1 day''' in v_src) = 0 then
    raise exception '0455: the return is due before the tax is known';
  end if;

  -- Output only. Netting purchases off would compute a refund nobody is
  -- entitled to, SST having no input tax credit.
  if position('''output''' in v_per) = 0 then
    raise exception '0455: the return claims input tax that does not exist';
  end if;

  if not exists (select 1 from pg_constraint
                  where conname = 'sst_period_months_is_one_or_two') then
    raise exception '0455: a taxable period may be any number of months';
  end if;
end
$do$;

comment on function app.sst_period_for(uuid, date) is
  'Which SST taxable period a date falls in, and when its return is '
  'due. Two calendar months, the cycle set by the registration date, '
  'the return due on the last day of the month after. See 0455.';
