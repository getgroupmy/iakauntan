-- =====================================================================
-- The week the money runs out
--
-- A profitable company goes under by running out of cash on a Tuesday.
-- Everything in this system faces backwards -- the trial balance, the
-- P&L, the aged listings all say what happened -- and the one question
-- an owner asks on a Monday morning is what the bank will look like in
-- six weeks. There is no forward view of cash anywhere. The `forecast_*`
-- tables are inventory replenishment and have nothing to do with money.
--
-- ---------------------------------------------------------------------
-- Thirteen weeks, because that is the horizon people plan on
--
-- Far enough to see a quarter's payables and a tax instalment, near
-- enough that the numbers are real. The default is 13 and the caller
-- can ask for more.
--
-- ---------------------------------------------------------------------
-- A due date is not a payment date
--
-- An invoice due on the thirtieth from a customer who has taken
-- forty-five days every time for two years is not cash on the
-- thirtieth, and a forecast that says it is will be cheerfully wrong
-- every month. `app.contact_payment_lag` measures what each customer
-- has actually done -- the average of (settled on − due on) over their
-- last dozen invoices -- and the forecast shifts their invoices by it.
--
-- Our own bills are not shifted. Paying late is a decision somebody
-- makes under pressure, not a fact about the business, and a forecast
-- that quietly assumed the company would stretch its suppliers would
-- be forecasting a plan nobody agreed to. Bills land on their due date
-- and the forecast shows what that costs.
--
-- ---------------------------------------------------------------------
-- What it draws on
--
--   open invoices          due date plus the customer's measured lag
--   open bills             due date
--   post-dated cheques     the date on the cheque
--   recurring documents    each run date across the horizon, plus terms
--   payroll not yet paid   the pay day of its period
--   anything else          `cash_flow_items`, typed by a person
--
-- Nothing double-counts, because a post-dated cheque has already taken
-- its invoice off the receivable ledger -- 0275 saw to that -- so the
-- invoice arm cannot see it any more.
--
-- The last of the six matters as much as the rest. A tax instalment, a
-- dividend, a lorry somebody has decided to buy: the ledger has no way
-- to know about any of them, and a forecast that ignored them would be
-- confidently wrong in the direction that hurts.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Why none of this is called `cash_flow`
--
-- `public.report_cash_flow` already exists. It is the cash flow
-- statement -- one of the five financial statements, built in 0072, and
-- entirely about what has already happened. Postgres would happily let
-- this one overload the name on a different argument list, and the
-- first person to call the wrong one would get a plausible answer to a
-- question they did not ask. Everything here is `cash_forecast`.
-- ---------------------------------------------------------------------

create type app.cash_forecast_direction as enum ('in', 'out');
create type app.cash_forecast_recurrence as enum
  ('once', 'weekly', 'monthly', 'quarterly', 'yearly');

-- ---------------------------------------------------------------------
-- The things only a person knows
-- ---------------------------------------------------------------------
create table public.cash_forecast_items (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,
  direction   app.cash_forecast_direction not null,
  description text not null,
  amount      numeric(18, 2) not null check (amount > 0),
  expected_on date not null,
  recurrence  app.cash_forecast_recurrence not null default 'once',

  -- When a repeating item stops. Null runs to the end of any horizon
  -- asked for, which is right for rent and wrong for a loan — so a loan
  -- gets an end date and the forecast stops paying it off for ever.
  until_date  date,

  is_active   boolean not null default true,
  notes       text,
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index cash_forecast_items_org_idx
  on public.cash_forecast_items (org_id, expected_on) where is_active;

create trigger cash_forecast_items_touch before update on public.cash_forecast_items
  for each row execute function app.set_updated_at();

comment on table public.cash_forecast_items is
  'Expected money the ledger cannot know about: a tax instalment, a dividend, a lorry somebody has decided to buy.';

-- ---------------------------------------------------------------------
-- What a customer actually does
-- ---------------------------------------------------------------------
--
-- The average of (settled on − due on) across their last dozen settled
-- invoices. Clamped: one invoice settled two years late by a
-- bookkeeper catching up would otherwise push every future invoice off
-- the end of the forecast, and a single early payment should not pull
-- them all forward.
--
-- Zero when there is no history. A new customer gets the benefit of the
-- doubt because there is nothing else to give them, and the forecast
-- says so by using their terms as written.
create or replace function app.contact_payment_lag(p_contact uuid)
returns integer
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select coalesce(round(avg(greatest(least(lag, 180), -30)))::integer, 0)
    from (
      select (a.allocated_at::date - d.due_date) as lag
        from public.payment_allocations a
        join public.sales_documents d on d.id = a.invoice_id
       where d.contact_id = p_contact
         and d.doc_type = 'invoice'
         and d.due_date is not null
         and d.status = 'completed'
       order by a.allocated_at desc
       limit 12
    ) recent;
$$;

revoke all on function app.contact_payment_lag(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Every expected movement, from every source
-- ---------------------------------------------------------------------
--
-- One function so the weekly summary and the line-by-line detail cannot
-- disagree. The summary is a roll-up of exactly these rows.
create or replace function app.cash_forecast_movements(
  p_org uuid, p_from date, p_to date, p_use_history boolean default true)
returns table (
  expected_on date,
  direction   text,
  source      text,
  reference   text,
  party       text,
  amount      numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  -- Money owed to us, shifted by what the customer actually does.
  select greatest(d.due_date
           + case when p_use_history then app.contact_payment_lag(d.contact_id)
                  else 0 end, p_from),
         'in', 'invoice', d.doc_no, c.name, d.balance_amount
    from public.sales_documents d
    join public.contacts c on c.id = d.contact_id
   where d.org_id = p_org
     and d.doc_type = 'invoice'
     and d.deleted_at is null
     and d.status in ('posted', 'partial')
     and d.balance_amount > 0
     and greatest(d.due_date
           + case when p_use_history then app.contact_payment_lag(d.contact_id)
                  else 0 end, p_from) <= p_to

  union all

  -- What we owe, on the day it is due. Not shifted: see the header.
  select greatest(d.due_date, p_from), 'out', 'bill', d.doc_no, c.name,
         d.balance_amount
    from public.purchase_documents d
    join public.contacts c on c.id = d.contact_id
   where d.org_id = p_org
     and d.doc_type = 'bill'
     and d.deleted_at is null
     and d.status in ('posted', 'partial')
     and d.balance_amount > 0
     and greatest(d.due_date, p_from) <= p_to

  union all

  -- Cheques, on the date written on them. 0275 already took their
  -- documents off the ledgers above, so nothing is counted twice.
  select greatest(k.cheque_date, p_from),
         case when k.direction = 'incoming' then 'in' else 'out' end,
         'cheque', k.pdc_no, c.name, k.amount
    from public.post_dated_cheques k
    join public.contacts c on c.id = k.contact_id
   where k.org_id = p_org
     and k.status in ('held', 'deposited')
     and greatest(k.cheque_date, p_from) <= p_to

  union all

  -- Every run of a recurring document that falls in the horizon, plus
  -- its payment terms. The amount is the last one it actually raised,
  -- because that is the best estimate of the next one; a schedule that
  -- has never run is estimated from its template lines, which ignores
  -- tax and is therefore approximate and says so.
  select gs::date + coalesce(r.payment_terms_days, 0),
         case when r.kind = 'sales' then 'in' else 'out' end,
         'recurring', r.name, coalesce(c.name, r.name),
         coalesce(
           (select sd.total_amount from public.sales_documents sd
             where sd.id = r.last_document_id),
           (select pd.total_amount from public.purchase_documents pd
             where pd.id = r.last_document_id),
           (select coalesce(sum((l->>'quantity')::numeric
                              * (l->>'unit_price')::numeric), 0)
              from jsonb_array_elements(r.template -> 'lines') l))
    from public.recurring_documents r
    left join public.contacts c on c.id = r.contact_id
    cross join lateral generate_series(
      r.next_run_date::timestamp,
      least(coalesce(r.end_date, p_to), p_to)::timestamp,
      case r.frequency
        when 'weekly'    then (coalesce(r.interval_count, 1) || ' weeks')::interval
        when 'monthly'   then (coalesce(r.interval_count, 1) || ' months')::interval
        when 'quarterly' then (coalesce(r.interval_count, 1) * 3 || ' months')::interval
        when 'yearly'    then (coalesce(r.interval_count, 1) || ' years')::interval
        else (coalesce(r.interval_count, 1) || ' months')::interval
      end) gs
   where r.org_id = p_org
     and r.is_active
     and gs::date + coalesce(r.payment_terms_days, 0) between p_from and p_to

  union all

  -- Wages calculated or approved and not yet paid. A payroll further
  -- out than that is not a row anywhere, and belongs in cash_flow_items
  -- as a monthly item — which the header says plainly rather than
  -- inventing a schedule this system does not have.
  select greatest(
           make_date(extract(year from p.end_date)::integer,
                     extract(month from p.end_date)::integer,
                     least(coalesce(s.pay_day, 28),
                           extract(day from (date_trunc('month', p.end_date)
                             + interval '1 month - 1 day'))::integer)),
           p_from),
         'out', 'payroll', pr.run_no, 'Wages', pr.total_net
    from public.payroll_runs pr
    join public.fiscal_periods p on p.id = pr.period_id
    left join public.payroll_settings s on s.org_id = pr.org_id
   where pr.org_id = p_org
     and pr.status in ('calculated', 'approved', 'posted')
     and pr.paid_at is null
     and pr.total_net > 0

  union all

  -- And what only a person knows.
  select gs::date, i.direction::text, 'manual', i.description, null, i.amount
    from public.cash_forecast_items i
    cross join lateral generate_series(
      i.expected_on::timestamp,
      least(coalesce(i.until_date, p_to), p_to)::timestamp,
      case i.recurrence
        when 'weekly'    then interval '1 week'
        when 'monthly'   then interval '1 month'
        when 'quarterly' then interval '3 months'
        when 'yearly'    then interval '1 year'
        else interval '100 years'
      end) gs
   where i.org_id = p_org
     and i.is_active
     and gs::date between p_from and p_to;
$$;

revoke all on function app.cash_forecast_movements(uuid, date, date, boolean)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The forecast
-- ---------------------------------------------------------------------
--
-- Weekly buckets with a running balance. The opening position is what
-- the bank accounts actually hold, so week one starts from a real
-- number rather than from nothing.
create or replace function public.report_cash_forecast(
  p_org uuid,
  p_weeks integer default 13,
  p_use_history boolean default true)
returns table (
  week_no     integer,
  week_start  date,
  week_end    date,
  opening     numeric,
  money_in    numeric,
  money_out   numeric,
  net         numeric,
  closing     numeric,
  overdrawn   boolean)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_weeks integer := least(greatest(coalesce(p_weeks, 13), 1), 104);
  v_from  date := current_date;
  v_to    date;
  v_open  numeric(18, 2);
begin
  if not app.can_read_module(p_org, 'accounting') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  v_to := v_from + (v_weeks * 7 - 1);

  select coalesce(sum(b.current_balance), 0) into v_open
    from public.bank_accounts b
   where b.org_id = p_org and b.is_active;

  return query
  with weeks as (
    select generate_series(1, v_weeks) as n
  ),
  bounded as (
    select w.n,
           v_from + ((w.n - 1) * 7) as w_start,
           v_from + (w.n * 7 - 1)   as w_end
      from weeks w
  ),
  moved as (
    select b.n,
           coalesce(sum(m.amount) filter (where m.direction = 'in'), 0) as inflow,
           coalesce(sum(m.amount) filter (where m.direction = 'out'), 0) as outflow
      from bounded b
      left join app.cash_forecast_movements(p_org, v_from, v_to, p_use_history) m
        on m.expected_on between b.w_start and b.w_end
     group by b.n
  ),
  running as (
    select b.n, b.w_start, b.w_end, m.inflow, m.outflow,
           v_open + coalesce(sum(m.inflow - m.outflow)
             over (order by b.n rows between unbounded preceding
                                         and 1 preceding), 0) as opening,
           v_open + sum(m.inflow - m.outflow)
             over (order by b.n rows unbounded preceding) as closing
      from bounded b join moved m on m.n = b.n
  )
  select r.n, r.w_start, r.w_end,
         round(r.opening, 2), round(r.inflow, 2), round(r.outflow, 2),
         round(r.inflow - r.outflow, 2), round(r.closing, 2),
         r.closing < 0
    from running r
   order by r.n;
end;
$$;

revoke all on function public.report_cash_forecast(uuid, integer, boolean)
  from public, anon;
grant execute on function public.report_cash_forecast(uuid, integer, boolean)
  to authenticated;

comment on function public.report_cash_forecast(uuid, integer, boolean) is
  'Thirteen weeks of cash by default, from what the bank holds now plus what is expected in and out. Customer invoices are shifted by the lag that customer has actually taken; our own bills are not.';

-- ---------------------------------------------------------------------
-- The single number
-- ---------------------------------------------------------------------
--
-- The first week the closing balance goes below zero, or null when it
-- does not. Everything else on the report is context for this.
create or replace function public.cash_runs_out_on(
  p_org uuid, p_weeks integer default 13, p_use_history boolean default true)
returns date
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select min(r.week_start)
    from public.report_cash_forecast(p_org, p_weeks, p_use_history) r
   where r.overdrawn;
$$;

revoke all on function public.cash_runs_out_on(uuid, integer, boolean)
  from public, anon;
grant execute on function public.cash_runs_out_on(uuid, integer, boolean)
  to authenticated;

-- ---------------------------------------------------------------------
-- What makes up a week
-- ---------------------------------------------------------------------
create or replace function public.cash_forecast_detail(
  p_org uuid,
  p_from date,
  p_to date,
  p_use_history boolean default true)
returns table (
  expected_on date,
  direction   text,
  source      text,
  reference   text,
  party       text,
  amount      numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_read_module(p_org, 'accounting') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select m.expected_on, m.direction, m.source, m.reference, m.party,
           round(m.amount, 2)
      from app.cash_forecast_movements(p_org, p_from, p_to, p_use_history) m
     order by m.expected_on, m.direction desc, m.reference;
end;
$$;

revoke all on function public.cash_forecast_detail(uuid, date, date, boolean)
  from public, anon;
grant execute on function public.cash_forecast_detail(uuid, date, date, boolean)
  to authenticated;

-- What each customer actually does, so somebody can see why the
-- forecast moved an invoice and argue with it.
create or replace function public.customer_payment_lags(p_org uuid)
returns table (
  contact_id uuid,
  party      text,
  lag_days   integer,
  outstanding numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_read_module(p_org, 'sales') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select c.id, c.name, app.contact_payment_lag(c.id),
           coalesce((select sum(d.balance_amount)
                       from public.sales_documents d
                      where d.contact_id = c.id
                        and d.doc_type = 'invoice'
                        and d.deleted_at is null
                        and d.status in ('posted', 'partial')), 0)
      from public.contacts c
     where c.org_id = p_org
       and c.contact_type in ('customer', 'both')
       and c.deleted_at is null
       and exists (select 1 from public.sales_documents d
                    where d.contact_id = c.id and d.doc_type = 'invoice'
                      and d.deleted_at is null)
     order by 3 desc, 2;
end;
$$;

revoke all on function public.customer_payment_lags(uuid) from public, anon;
grant execute on function public.customer_payment_lags(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The things a person types
-- ---------------------------------------------------------------------
create or replace function public.upsert_cash_forecast_item(
  p_id         uuid,
  p_org        uuid,
  p_direction  text,
  p_description text,
  p_amount     numeric,
  p_expected_on date,
  p_recurrence text default 'once',
  p_until      date default null,
  p_notes      text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid := p_id;
begin
  if not app.can_write_module(p_org, 'accounting') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if coalesce(trim(p_description), '') = '' then
    raise exception 'Say what it is. "Payment" in a forecast is a line '
      'nobody can check.' using errcode = '23514';
  end if;
  if round(coalesce(p_amount, 0), 2) <= 0 then
    raise exception 'It has to be for something.' using errcode = '23514';
  end if;
  if p_recurrence <> 'once' and p_until is not null
     and p_until < p_expected_on then
    raise exception 'That stops before it starts.' using errcode = '23514';
  end if;

  if v_id is null then
    insert into public.cash_forecast_items
      (org_id, direction, description, amount, expected_on, recurrence,
       until_date, notes, created_by)
    values (p_org, p_direction::app.cash_forecast_direction, trim(p_description),
            round(p_amount, 2), p_expected_on,
            p_recurrence::app.cash_forecast_recurrence, p_until, p_notes,
            auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  update public.cash_forecast_items
     set direction = p_direction::app.cash_forecast_direction,
         description = trim(p_description),
         amount = round(p_amount, 2),
         expected_on = p_expected_on,
         recurrence = p_recurrence::app.cash_forecast_recurrence,
         until_date = p_until,
         notes = p_notes
   where id = v_id and org_id = p_org;
  if not found then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

revoke all on function public.upsert_cash_forecast_item(uuid, uuid, text, text, numeric, date, text, date, text)
  from public, anon;
grant execute on function public.upsert_cash_forecast_item(uuid, uuid, text, text, numeric, date, text, date, text)
  to authenticated;

create or replace function public.retire_cash_forecast_item(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select org_id into v_org from public.cash_forecast_items where id = p_id;
  if v_org is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'accounting') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  -- Switched off rather than deleted: a forecast circulated last month
  -- was run against these rows, and deleting one makes it impossible to
  -- explain why the figure was what it was.
  update public.cash_forecast_items set is_active = false where id = p_id;
  return true;
end;
$$;

revoke all on function public.retire_cash_forecast_item(uuid) from public, anon;
grant execute on function public.retire_cash_forecast_item(uuid) to authenticated;

create or replace function public.cash_forecast_items_list(p_org uuid)
returns table (
  id          uuid,
  direction   text,
  description text,
  amount      numeric,
  expected_on date,
  recurrence  text,
  until_date  date,
  is_active   boolean,
  notes       text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_read_module(p_org, 'accounting') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select i.id, i.direction::text, i.description, i.amount, i.expected_on,
           i.recurrence::text, i.until_date, i.is_active, i.notes
      from public.cash_forecast_items i
     where i.org_id = p_org
     order by i.is_active desc, i.expected_on;
end;
$$;

revoke all on function public.cash_forecast_items_list(uuid) from public, anon;
grant execute on function public.cash_forecast_items_list(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.cash_forecast_items enable row level security;

create policy cash_forecast_items_read on public.cash_forecast_items for select
  to authenticated using (app.can_read_module(org_id, 'accounting'));

-- No write policy. The forecast is only worth reading if the rows
-- behind it were put there deliberately by somebody who may write for
-- the company.
revoke all on public.cash_forecast_items from anon, authenticated;
grant select on public.cash_forecast_items to authenticated;
