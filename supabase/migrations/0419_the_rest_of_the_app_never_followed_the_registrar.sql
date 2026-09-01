-- ---------------------------------------------------------------------
-- The rest of the app never followed the Registrar into Malaysian time
--
-- `0305` pinned `corp_upcoming_filings` to `Asia/Kuala_Lumpur` and
-- explained why: `current_date` in Postgres is not "today", it is today
-- *in the session's time zone*, and on Supabase the session is UTC.
-- Malaysia is UTC+8, so between midnight in Kuala Lumpur and midnight
-- in London every function that reads `current_date` is a day behind
-- the country it serves.
--
-- `0305` fixed one function. Eighteen more had the same line in them,
-- and nothing was watching for the next one. This pins all eighteen and
-- gives the project the helper it never had, so the correction is a
-- word rather than a paste.
--
-- ## How this was found
--
-- Not by reading. `supabase/tests/vacancies.sql` dates a requisition
-- forty-five days before the *Malaysian* today and asserts that
-- `report_open_vacancies` says forty-five. It went red at 02:02 in
-- Kuala Lumpur — 18:02 UTC, still the previous day in London — with
-- "expected 45, got 44". The fixture was already keeping Malaysian
-- time; the report was not.
--
-- Asking Postgres which other functions read the clock turned up
-- seventeen more, and one clean line between the ones that are wrong
-- and the ones that are a separate question.
--
-- ## Where the line is drawn: STABLE, and only STABLE
--
-- The eighteen restated below are every `STABLE` function in `public`
-- and `app` that reads `current_date`. A `STABLE` function computes an
-- answer and returns it; being a day out means a number on a screen is
-- wrong, and correcting it corrects the screen and nothing else.
--
-- The `VOLATILE` ones — `complete_pos_sale`, `credit_sales_invoice`,
-- `post_manufacturing_order`, `next_document_number_internal` and about
-- thirty others — read the clock to *stamp a date on a row they are
-- writing*. Those are wrong too: a sale rung up at half past midnight
-- in a mamak posts to yesterday's ledger, and at a month end it posts
-- to the wrong month and takes the document number's `YYYYMM` with it.
-- But changing what date a posting carries runs into fiscal period
-- control, into `0053`'s rollover, and into every document number
-- already issued. That is its own migration with its own reasoning, and
-- guessing at it here would bury a real decision inside a correction.
-- So this one stops at the reports and says so.
--
-- ## This changes what the functions return
--
-- Not a refactor, and the same eight-hour window `0305` described. For
-- the eight hours between midnight and eight in the morning in Kuala
-- Lumpur, every one of these eighteen moves its answer by a day:
--
--   * a permit that expired this morning stops reading as expiring
--     tomorrow,
--   * an invoice that fell due today joins the overdue figure,
--   * a post-dated cheque that matured today shows as bankable,
--   * a board resolution generated at seven in the morning is dated the
--     day it was signed rather than the day before,
--   * on the first of the month, the dashboard and the revenue trend
--     agree with `module_dashboard`, which `0306` had already pinned —
--     until now they disagreed about which month it was.
--
-- The previous behaviour was the defect in every case.
--
-- ## Why a function and not another paste
--
-- `Asia/Kuala_Lumpur` is spelled out in fifty-two migrations. Every one
-- of them is a place where somebody had to know to do it, and the
-- eighteen below are the places where nobody did. `app.today()` makes
-- the correct thing shorter than the incorrect one, which is the only
-- version of this that survives the next hundred migrations.
--
-- The zone is fixed rather than read from the organization. This is a
-- Malaysian product implementing Malaysian statute — `0305` made the
-- same call, and a per-organization zone is a product decision nobody
-- has asked for. When somebody does ask, this is the one place to
-- change.
--
-- ## The guard
--
-- `supabase/tests/malaysian_clock.sql` asserts the property rather than
-- the value, for the reason `secretarial.sql` gives at length: a test
-- comparing UTC against Kuala Lumpur can only fail during the eight
-- hours they differ, and a suite that is green all morning and red all
-- afternoon teaches people to ignore it. So each function is called
-- under two session time zones twenty-six hours apart — never on the
-- same date, at any instant — and must give the same answer.
--
-- It also asserts the rule, mechanically: no `STABLE` function in
-- `public` or `app` reads `current_date`. That is what makes the
-- nineteenth one loud instead of silent.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Today, in the country the books are kept in
-- ---------------------------------------------------------------------
create or replace function app.today() returns date
language sql
stable
set search_path = pg_catalog, public, app, pg_temp
as $$ select (now() at time zone 'Asia/Kuala_Lumpur')::date $$;

comment on function app.today() is
  'Today in Asia/Kuala_Lumpur. Postgres'' current_date is today in the '
  'session time zone, which on Supabase is UTC -- eight hours behind '
  'the country whose Act this software implements. Read this instead.';

grant execute on function app.today() to authenticated, service_role;

-- ---------------------------------------------------------------------
-- The Registrar, the Commissioner and the Director General
-- ---------------------------------------------------------------------

-- The date printed on a resolution that goes to SSM.
create or replace function app.corp_merge_context(p_entity_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  e public.corp_entities;
  v jsonb;
  v_directors text;
  v_secretaries text;
  v_members text;
  v_capital text;
begin
  select * into e from public.corp_entities where id = p_entity_id;
  if e.id is null then
    raise exception 'Entity not found' using errcode = 'P0002';
  end if;

  select string_agg(p.full_name || coalesce(' (' || p.nric || ')', ''), E'\n')
    into v_directors
    from public.corp_officers o
    join public.corp_persons p on p.id = o.person_id
   where o.entity_id = p_entity_id and o.role = 'director'
     and o.resigned_on is null;

  select string_agg(p.full_name ||
           coalesce(' (' || o.licence_body || ' ' || o.licence_no || ')', ''), E'\n')
    into v_secretaries
    from public.corp_officers o
    join public.corp_persons p on p.id = o.person_id
   where o.entity_id = p_entity_id and o.role = 'secretary'
     and o.resigned_on is null;

  select string_agg(format('%s — %s %s shares (%s%%)',
           r.member_name, to_char(r.shares, 'FM999,999,999,990'),
           r.share_class, to_char(r.percent, 'FM990.00')), E'\n')
    into v_members
    from public.corp_register_of_members(p_entity_id) r;

  select string_agg(format('%s: %s shares for %s',
           c.share_class, to_char(c.shares, 'FM999,999,999,990'),
           to_char(c.consideration, 'FM"RM "999,999,999,990.00')), E'\n')
    into v_capital
    from public.corp_issued_capital(p_entity_id) c;

  -- FM on the date masks: to_char pads month names to nine characters,
  -- so a plain 'DD Month YYYY' produces "12 March     2024" in the
  -- middle of a resolution.
  v := jsonb_build_object(
    'company_name',        e.name,
    'registration_no',     coalesce(e.registration_no, ''),
    'old_registration_no', coalesce(e.old_registration_no, ''),
    'entity_type',         case e.entity_type
                             when 'sdn_bhd' then 'Private company limited by shares (Sdn Bhd)'
                             when 'berhad'  then 'Public company (Berhad)'
                             when 'llp'     then 'Limited liability partnership (PLT)'
                             when 'clbg'    then 'Company limited by guarantee'
                             else initcap(replace(e.entity_type::text, '_', ' ')) end,
    'incorporated_on',     coalesce(to_char(e.incorporated_on, 'FMDD FMMonth YYYY'), ''),
    'registered_office',   coalesce(e.registered_office, ''),
    'business_address',    coalesce(e.business_address, ''),
    'nature_of_business',  coalesce(e.nature_of_business, ''),
    'financial_year_end',  coalesce(
        to_char(app.corp_fye(e, extract(year from app.today())::int),
                'FMDD FMMonth'), ''),
    'directors',           coalesce(v_directors, ''),
    'secretaries',         coalesce(v_secretaries, ''),
    'members',             coalesce(v_members, ''),
    'issued_capital',      coalesce(v_capital, ''),
    'today',               to_char(app.today(), 'FMDD FMMonth YYYY'),
    'today_iso',           to_char(app.today(), 'YYYY-MM-DD'));

  return v;
end;
$$;

-- CA 2016 s.258: how long is left to lodge, and whether it is late.
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
    (v_lodge - app.today())::integer,
    f.lodged_on is null and app.today() > v_lodge,
    case when coalesce(v_public, false)
      then 'CA 2016 s.340 — laid at the AGM within six months of the year '
           'end — and s.259, lodged within thirty days of that meeting.'
      else 'CA 2016 s.258 — circulated to members within six months of the '
           'year end — and s.259, lodged within thirty days of circulation.'
    end;
end $$;

-- The same deadlines, windowed for the screen.
create or replace function public.report_fs_deadlines(
  p_org_id uuid,
  p_within_days integer default 60)
returns table (
  filing_id uuid,
  company text,
  registration_no text,
  fy_end date,
  status app.fs_filing_status,
  approved_on date,
  circulated_on date,
  lodged_on date,
  circulate_by date,
  lodge_by date,
  days_left integer,
  is_late boolean)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) or not app.has_module(p_org_id, 'mbrs')
  then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    select f.id,
           -- The entity when one is named, and the organization's own
           -- name when it is not: a company keeping its own books here
           -- has no `corp_entities` row and its accounts are still its
           -- accounts.
           coalesce(e.name, o.name),
           e.registration_no,
           f.fy_end, f.status,
           f.directors_approval_date, f.circulated_on, f.lodged_on,
           d.circulate_by, d.lodge_by, d.days_left, d.is_late
      from public.fs_filings f
      join public.organizations o on o.id = f.org_id
      left join public.corp_entities e on e.id = f.corp_entity_id
      cross join lateral public.fs_deadlines(f.id) d
     where f.org_id = p_org_id
       and f.status <> 'lodged'
       and d.lodge_by <= app.today() + coalesce(p_within_days, 60)
     order by d.lodge_by, coalesce(e.name, o.name);
end $$;

-- LHDN gives seven days after the month to consolidate.
create or replace function public.pos_einvoice_outstanding(p_org uuid)
returns table (
  period_start   date,
  period_end     date,
  due_date       date,
  sales_waiting  integer,
  total_amount   numeric,
  consolidation_status text,
  days_left      integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  with months as (
    select date_trunc('month', d.doc_date)::date as period_start,
           (date_trunc('month', d.doc_date) + interval '1 month - 1 day')::date as period_end,
           count(*)::integer as sales_waiting,
           coalesce(sum(d.total_amount), 0) as total_amount
      from public.pos_sales s
      join public.sales_documents d on d.id = s.invoice_id
     where s.org_id = p_org
       and s.status = 'completed'
       and d.einvoice_id is null
       and app.pos_invoice_is_anonymous(d.id)
       and not exists (select 1 from public.einvoice_consolidation_items i
                        where i.sales_document_id = d.id)
     group by 1, 2
  )
  select m.period_start, m.period_end, (m.period_end + 7)::date,
         m.sales_waiting, m.total_amount,
         coalesce(c.status, 'not started'),
         ((m.period_end + 7) - app.today())::integer
    from months m
    left join public.einvoice_consolidations c
      on c.org_id = p_org and c.period_start = m.period_start
   where app.can_read_module(p_org, 'einvoice')
   order by m.period_start;
$$;

-- How many days late the remittance to LHDN is.
create or replace function public.report_withholding(
  p_org_id uuid,
  p_from date default null,
  p_to date default app.today())
returns table (
  certificate_id uuid, certificate_no text, cert_date date,
  contact_name text, section text, form_code text,
  currency char(3), gross_amount numeric, rate numeric,
  tax_amount numeric, base_tax_amount numeric,
  due_date date, remitted_on date, days_late integer,
  penalty_if_unpaid numeric)
language sql stable security definer set search_path = public, app, pg_temp as $$
  select c.id, c.certificate_no, c.cert_date, ct.name, c.section, c.form_code,
         c.currency, c.gross_amount, c.rate, c.tax_amount,
         round(c.tax_amount * coalesce(c.exchange_rate, 1), 2),
         c.due_date, c.remitted_on,
         greatest(0, coalesce(c.remitted_on, app.today()) - c.due_date)::integer,
         case
           when c.remitted_on is null and app.today() > c.due_date
           then round(c.tax_amount * coalesce(c.exchange_rate, 1) * 0.10, 2)
           else 0
         end
    from public.withholding_certificates c
    join public.contacts ct on ct.id = c.contact_id
   where c.org_id = p_org_id
     and c.deleted_at is null
     and c.status <> 'void'
     and (p_from is null or c.cert_date >= p_from)
     and c.cert_date <= p_to
     and app.is_org_member(p_org_id)
   order by c.form_code, c.cert_date, c.certificate_no;
$$;

-- Quit rent and assessment: due, and overdue.
create or replace function public.property_statutory_due(
  p_org_id uuid,
  p_within_days integer default 60)
returns table (
  charge_id uuid,
  site_id uuid,
  site_name text,
  kind app.statutory_property_charge,
  authority text,
  account_no text,
  period text,
  amount numeric,
  due_date date,
  days_until integer,
  is_overdue boolean)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id)
     or not app.has_property_module(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    select ch.id, s.id, s.name, ch.kind, ch.authority, ch.account_no,
           case when ch.period_half is null then ch.period_year::text
                else ch.period_year::text || ' H' || ch.period_half::text end,
           ch.amount, ch.due_date,
           (ch.due_date - app.today())::integer,
           ch.due_date < app.today()
      from public.property_statutory_charges ch
      join public.property_sites s on s.id = ch.site_id
     where ch.org_id = p_org_id
       and ch.paid_on is null
       and ch.due_date <= app.today() + coalesce(p_within_days, 60)
     order by ch.due_date, s.name;
end $$;

-- ---------------------------------------------------------------------
-- Money that is late, or about to be
-- ---------------------------------------------------------------------

-- Overdue receivables, and what is due tomorrow.
create or replace function public.dashboard_summary(
  p_org_id uuid, p_from date default null, p_to date default app.today())
returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_from date := coalesce(p_from, date_trunc('month', app.today())::date);
  v_result jsonb;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of this organization' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'revenue', (
      select coalesce(sum(base_total_amount), 0) from public.sales_documents
       where org_id = p_org_id and doc_type = 'invoice'
         and status not in ('draft', 'void') and deleted_at is null
         and doc_date between v_from and p_to),
    'expenses', (
      select coalesce(sum(base_total_amount), 0) from public.purchase_documents
       where org_id = p_org_id and doc_type = 'bill'
         and status not in ('draft', 'void') and deleted_at is null
         and doc_date between v_from and p_to),
    'receivables', (
      select coalesce(sum(balance_amount), 0) from public.sales_documents
       where org_id = p_org_id and doc_type = 'invoice'
         and status not in ('draft', 'void') and deleted_at is null),
    'payables', (
      select coalesce(sum(balance_amount), 0) from public.purchase_documents
       where org_id = p_org_id and doc_type = 'bill'
         and status not in ('draft', 'void') and deleted_at is null),
    'overdue_receivables', (
      select coalesce(sum(balance_amount), 0) from public.sales_documents
       where org_id = p_org_id and doc_type = 'invoice'
         and status not in ('draft', 'void') and deleted_at is null
         and due_date < app.today() and balance_amount > 0),
    'bank_balance', (
      select coalesce(sum(current_balance), 0) from public.bank_accounts
       where org_id = p_org_id and is_active),
    'draft_invoices', (
      select count(*) from public.sales_documents
       where org_id = p_org_id and doc_type = 'invoice'
         and status = 'draft' and deleted_at is null),
    'einvoice_pending', (
      select count(*) from public.einvoice_documents
       where org_id = p_org_id and status in ('draft', 'queued', 'submitted')),
    'einvoice_invalid', (
      select count(*) from public.einvoice_documents
       where org_id = p_org_id and status in ('invalid', 'failed')),
    'open_opportunities', (
      select coalesce(sum(amount), 0) from public.opportunities
       where org_id = p_org_id and status = 'open' and deleted_at is null),
    'weighted_pipeline', (
      select coalesce(sum(weighted_amount), 0) from public.opportunities
       where org_id = p_org_id and status = 'open' and deleted_at is null),
    'activities_due', (
      select count(*) from public.activities
       where org_id = p_org_id and status = 'pending'
         and due_date <= app.today() + interval '1 day'),
    'low_stock', (
      select count(*) from public.items
       where org_id = p_org_id and deleted_at is null and track_inventory
         and reorder_level > 0 and quantity_on_hand <= reorder_level)
  ) into v_result;

  return v_result;
end;
$$;

-- How many days until a post-dated cheque matures.
create or replace function public.pdc_list(
  p_org uuid, p_direction text default null, p_status text default null)
returns table (
  id           uuid,
  pdc_no       text,
  direction    text,
  status       text,
  party        text,
  cheque_no    text,
  cheque_date  date,
  bank_name    text,
  amount       numeric,
  received_on  date,
  days_to_go   integer,
  settles      bigint,
  bounce_reason text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_read_module(p_org, 'sales')
     and not app.can_read_module(p_org, 'purchases') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select c.id, c.pdc_no, c.direction::text, c.status::text, ct.name,
           c.cheque_no, c.cheque_date, c.bank_name, c.amount, c.received_on,
           (c.cheque_date - app.today())::integer,
           (select count(*) from public.payment_allocations a
             where a.pdc_id = c.id),
           c.bounce_reason
      from public.post_dated_cheques c
      join public.contacts ct on ct.id = c.contact_id
     where c.org_id = p_org
       and (p_direction is null or c.direction::text = p_direction)
       and (p_status is null or c.status::text = p_status)
       and ((c.direction = 'incoming' and app.can_read_module(p_org, 'sales'))
         or (c.direction = 'outgoing' and app.can_read_module(p_org, 'purchases')))
     order by c.cheque_date, c.pdc_no;
end;
$$;

-- Which cheques have matured and should be banked.
create or replace function public.pdc_maturing(
  p_org uuid, p_from date default null, p_to date default null)
returns table (
  id          uuid,
  pdc_no      text,
  direction   text,
  status      text,
  party       text,
  cheque_no   text,
  cheque_date date,
  amount      numeric,
  overdue     boolean)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_from date := coalesce(p_from, app.today());
  v_to   date := coalesce(p_to, app.today() + 30);
begin
  if not app.can_read_module(p_org, 'sales')
     and not app.can_read_module(p_org, 'purchases') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
    select c.id, c.pdc_no, c.direction::text, c.status::text, ct.name,
           c.cheque_no, c.cheque_date, c.amount,
           -- A cheque whose date has passed and which has not cleared is
           -- the one somebody has forgotten to bank, and it is the whole
           -- reason to look at this list.
           c.cheque_date < app.today()
      from public.post_dated_cheques c
      join public.contacts ct on ct.id = c.contact_id
     where c.org_id = p_org
       and c.status in ('held', 'deposited')
       and (c.cheque_date <= v_to)
       and (c.cheque_date >= v_from or c.cheque_date < app.today())
       and ((c.direction = 'incoming' and app.can_read_module(p_org, 'sales'))
         or (c.direction = 'outgoing' and app.can_read_module(p_org, 'purchases')))
     order by c.cheque_date, c.pdc_no;
end;
$$;

-- How many days late a delivery is.
create or replace function public.report_late_orders(
  p_org_id uuid, p_as_at date default null)
returns table (
  document_id uuid, doc_no text, doc_date date, delivery_date date,
  days_late integer, contact_name text,
  ordered numeric, fulfilled numeric, outstanding numeric, amount numeric)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  with asked as (
    select d.id, d.doc_no, d.doc_date, d.delivery_date, d.total_amount,
           c.name as contact_name,
           coalesce(sum(l.quantity), 0) as ordered,
           coalesce(sum(l.quantity_fulfilled), 0) as fulfilled
      from public.sales_documents d
      left join public.contacts c on c.id = d.contact_id
      left join public.sales_document_lines l on l.document_id = d.id
     where d.org_id = p_org_id
       and d.doc_type = 'sales_order'
       and d.deleted_at is null
       and d.status not in ('draft', 'void')
       and d.delivery_date is not null
       and d.delivery_date < coalesce(p_as_at, app.today())
     group by d.id, d.doc_no, d.doc_date, d.delivery_date, d.total_amount, c.name)
  select a.id, a.doc_no, a.doc_date, a.delivery_date,
         (coalesce(p_as_at, app.today()) - a.delivery_date)::integer,
         a.contact_name, a.ordered, a.fulfilled, a.ordered - a.fulfilled,
         a.total_amount
    from asked a
   where a.ordered - a.fulfilled > 0
     and app.is_org_member(p_org_id)
   order by a.delivery_date;
$$;

-- The forecast starts today, so today decides every week in it.
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
  v_from  date := app.today();
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

-- Which month is the current month.
create or replace function public.report_revenue_trend(
  p_org_id uuid, p_months integer default 12)
returns table (period date, revenue numeric, expenses numeric)
language sql stable security definer set search_path = public, app, pg_temp as $$
  with months as (
    select generate_series(
      date_trunc('month', app.today()) - ((p_months - 1) || ' months')::interval,
      date_trunc('month', app.today()), '1 month')::date as period)
  select m.period,
         coalesce((select sum(d.base_total_amount) from public.sales_documents d
                    where d.org_id = p_org_id and d.doc_type = 'invoice'
                      and d.status not in ('draft', 'void') and d.deleted_at is null
                      and date_trunc('month', d.doc_date) = m.period), 0),
         coalesce((select sum(d.base_total_amount) from public.purchase_documents d
                    where d.org_id = p_org_id and d.doc_type = 'bill'
                      and d.status not in ('draft', 'void') and d.deleted_at is null
                      and date_trunc('month', d.doc_date) = m.period), 0)
    from months m
   where app.is_org_member(p_org_id)
   order by m.period;
$$;

-- ---------------------------------------------------------------------
-- Things that expire
-- ---------------------------------------------------------------------

-- A permit that expired this morning.
create or replace function public.report_expiring_documents(
  p_org_id uuid,
  p_within_days integer default 60)
returns table (
  document_id uuid,
  employee_id uuid,
  employee_no text,
  employee_name text,
  doc_type text,
  title text,
  issued_date date,
  expires_date date,
  days_until integer,
  is_expired boolean,
  consequence text)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if not app.can_manage_hr(p_org_id) then
    raise exception 'not permitted to read employee documents'
      using errcode = '42501';
  end if;

  return query
    select d.id, e.id, e.employee_no,
           e.full_name,
           d.doc_type, d.title, d.issued_date, d.expires_date,
           (d.expires_date - app.today())::integer,
           d.expires_date < app.today(),
           case
             when d.doc_type = 'permit'
              and e.residency_status in ('expatriate', 'foreign_worker')
              and d.expires_date < app.today()
               then 'offence'
             when d.doc_type = 'permit'
              and e.residency_status in ('expatriate', 'foreign_worker')
               then 'permit'
             else 'renewal'
           end
      from public.employee_documents d
      join public.employees e on e.id = d.employee_id
     where d.org_id = p_org_id
       and d.expires_date is not null
       and e.employment_status not in ('resigned', 'terminated', 'retired')
       and not exists (select 1 from public.employee_documents s
                        where s.supersedes_id = d.id)
       and d.expires_date <= app.today() + coalesce(p_within_days, 60)
     order by
       case
         when d.doc_type = 'permit'
          and e.residency_status in ('expatriate', 'foreign_worker')
          and d.expires_date < app.today() then 0
         when d.doc_type = 'permit'
          and e.residency_status in ('expatriate', 'foreign_worker') then 1
         else 2
       end,
       d.expires_date, e.full_name;
end $$;

-- Stock you may no longer sell.
create or replace function public.report_expiring_stock(
  p_org_id uuid,
  p_within_days integer default 90)
returns table (
  item_code   text,
  item_name   text,
  lot_ref     text,
  expiry_date date,
  days_to_expiry integer,
  warehouse   text,
  quantity    numeric,
  value_at_average numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select i.code, i.name, b.lot_ref, b.expiry_date,
         (b.expiry_date - app.today())::integer,
         w.name, b.quantity,
         -- At the item's weighted average, because that is what this
         -- stock is carried at. It is what would be written off, not a
         -- cost specific to the batch — see the header.
         round(b.quantity * coalesce(i.average_cost, 0), 2)
    from public.v_lot_balances b
    join public.items i on i.id = b.item_id
    left join public.warehouses w on w.id = b.warehouse_id
   where b.org_id = p_org_id
     and b.expiry_date is not null
     and b.expiry_date <= app.today() + p_within_days
     and b.quantity > 0
   order by b.expiry_date, i.code;
end;
$$;

-- Days of shelf life left on a lot.
create or replace function public.report_lot_balances(
  p_org_id uuid,
  p_item_id uuid default null,
  p_warehouse_id uuid default null)
returns table (
  lot_id      uuid,
  item_code   text,
  item_name   text,
  lot_ref     text,
  kind        text,
  expiry_date date,
  days_to_expiry integer,
  warehouse   text,
  quantity    numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select b.lot_id, i.code, i.name, b.lot_ref, b.kind, b.expiry_date,
         case when b.expiry_date is null then null
              else (b.expiry_date - app.today())::integer end,
         w.name, b.quantity
    from public.v_lot_balances b
    join public.items i on i.id = b.item_id
    left join public.warehouses w on w.id = b.warehouse_id
   where b.org_id = p_org_id
     and (p_item_id is null or b.item_id = p_item_id)
     and (p_warehouse_id is null or b.warehouse_id = p_warehouse_id)
   order by i.code, b.expiry_date asc nulls last, b.lot_ref;
end;
$$;

-- ---------------------------------------------------------------------
-- Periods, and people
-- ---------------------------------------------------------------------

-- Which membership period the member is in now.
create or replace function public.membership_balance(p_subscription uuid)
returns table (
  membership   text,
  status       app.pos_membership_status,
  period_start date,
  period_end   date,
  included     integer,
  used         integer,
  remaining    integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select m.name, s.status, p.period_start, p.period_end,
         m.sessions_included,
         (select count(*)::integer from public.pos_membership_sessions x
           where x.subscription_id = s.id
             and x.used_on between p.period_start and p.period_end),
         case when m.sessions_included is null then null
              else greatest(m.sessions_included
                   - (select count(*)::integer from public.pos_membership_sessions x
                       where x.subscription_id = s.id
                         and x.used_on between p.period_start and p.period_end), 0)
         end
    from public.pos_membership_subscriptions s
    join public.pos_memberships m on m.id = s.membership_id
    cross join lateral app.membership_period(s.id, app.today()) p
   where s.id = p_subscription
     and app.can_read_module(s.org_id, 'memberships');
$$;

-- And which ones were never billed.
create or replace function public.membership_billing_gaps(p_org uuid)
returns table (
  subscription_id uuid,
  member          text,
  membership      text,
  started_on      date,
  next_period_starts date)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select s.id, c.name, m.name, s.started_on, (p.period_end + 1)::date
    from public.pos_membership_subscriptions s
    join public.pos_memberships m on m.id = s.membership_id
    join public.contacts c on c.id = s.contact_id
    cross join lateral app.membership_period(s.id, app.today()) p
   where s.org_id = p_org
     and s.status = 'active'
     and s.recurring_document_id is null
     and app.can_read_module(p_org, 'memberships')
   order by s.started_on;
$$;

-- How long a vacancy has been open.
create or replace function public.report_open_vacancies(p_org_id uuid)
returns table (
  requisition_id uuid,
  requisition_no text,
  title text,
  department text,
  hiring_manager text,
  status app.requisition_status,
  opened_date date,
  target_start_date date,
  days_open integer,
  headcount integer,
  hired integer,
  remaining integer,
  applicants integer)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if not app.can_manage_hr(p_org_id) then
    raise exception 'not permitted to read the vacancies'
      using errcode = '42501';
  end if;

  return query
    select r.id, r.requisition_no, r.title, d.name, e.full_name, r.status,
           r.opened_date, r.target_start_date,
           case when r.opened_date is null then null
                else (app.today() - r.opened_date)::integer end,
           r.headcount,
           coalesce(h.hired, 0)::integer,
           greatest(r.headcount - coalesce(h.hired, 0), 0)::integer,
           coalesce(a.n, 0)::integer
      from public.job_requisitions r
      left join public.departments d on d.id = r.department_id
      left join public.employees e on e.id = r.hiring_manager_id
      left join lateral (
        select count(*) as hired from public.applicants x
         where x.requisition_id = r.id and x.hired_employee_id is not null
      ) h on true
      left join lateral (
        select count(*) as n from public.applicants x
         where x.requisition_id = r.id
      ) a on true
     where r.org_id = p_org_id
       and r.status in ('open', 'on_hold')
     order by r.opened_date nulls last, r.requisition_no;
end $$;

-- ---------------------------------------------------------------------
-- The rule, asserted here as well as in the tests
--
-- If a nineteenth STABLE function reads the clock and this migration
-- misses it, the miss should stop the deploy rather than wait for
-- somebody to notice a date. The pattern is wider than `current_date`
-- because `current_date` is not the only way to ask the session what
-- day it is; `localtimestamp`, `current_timestamp::date` and
-- `now()::date` all do, and all of them mean UTC on Supabase.
--
-- Comments are stripped first: `0306` left the word `current_date` in a
-- comment in `module_dashboard`, explaining why it no longer reads it,
-- and that sentence is not a defect. The same predicate is asserted
-- independently in `supabase/tests/malaysian_clock.sql`, along with a
-- check that it matches what it claims to.
-- ---------------------------------------------------------------------
do $$
declare
  v_left text[];
begin
  select array_agg(n.nspname || '.' || p.proname order by 1)
    into v_left
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app')
     and p.provolatile in ('s', 'i')
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~*
         '(\mcurrent_date\M)|(\mlocaltimestamp\M)'
         '|(\mcurrent_timestamp\M\s*::\s*date)|(\mnow\M\s*\(\s*\)\s*::\s*date)';

  if v_left is not null then
    raise exception
      'FAIL 0419 left % STABLE function(s) reading the session clock: %. '
      'Either pin them to app.today() here, or -- if the function truly '
      'wants the caller''s clock -- say so where it reads it.',
      cardinality(v_left), array_to_string(v_left, ', ')
      using errcode = '23514';
  end if;
end $$;
