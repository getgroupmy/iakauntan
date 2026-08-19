-- What a shop owes LHDN, and how it is not five hundred documents.
--
-- ## The problem this exists to avoid
--
-- Every sale is an invoice, and under e-Invoicing every invoice is a
-- submission. A convenience store doing five hundred sales a day would
-- owe LHDN five hundred e-Invoices a day, each with a buyer who bought
-- a drink and will never be identified.
--
-- The guideline's answer is the consolidated e-Invoice: where the buyer
-- does not request one, the seller aggregates the period's sales into a
-- single submission, due within seven days of month end. `0007` built
-- the tables for it — `einvoice_consolidations`, its items, and a
-- `due_date` generated as `period_end + 7` — and nothing has ever
-- filled them, because until there was a till there was nothing to
-- consolidate.
--
-- ## The rule, and where the line falls
--
-- A sale gets its own e-Invoice when the buyer asks for one. Otherwise
-- it rolls up. The test for "asked for one" is not a checkbox on a
-- screen — it is whether the sale is billed to somebody identifiable,
-- which in this schema means a contact with a TIN. The walk-in has
-- none, by construction, which is what makes it the walk-in.
--
-- So the split is derived rather than declared, and cannot drift from
-- what was actually invoiced.
--
-- ## Asking happens after paying
--
-- Deliberately a separate function rather than an argument to
-- `complete_pos_sale`. Across a real counter the request comes late:
-- the customer pays, then says "boss, I need it under the company
-- name", and produces a card with a TIN on it. A till that could only
-- take that instruction before tendering would be a till that makes
-- people queue twice.
--
-- Re-billing a posted invoice is a real change and is treated as one:
-- it is refused once the sale has been rolled into a consolidation,
-- because that submission has already told LHDN this sale had no
-- identified buyer.

-- ---------------------------------------------------------------------
-- Which sales are LHDN's problem individually
-- ---------------------------------------------------------------------
--
-- A POS invoice belongs in the consolidation when nobody identified
-- themselves. Written as a function rather than repeated in three
-- queries, because the definition of "anonymous" is exactly the thing
-- that must not differ between the roll-up, the count, and the screen
-- that shows what is outstanding.
create or replace function app.pos_invoice_is_anonymous(p_invoice uuid)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select coalesce(
    (select nullif(btrim(c.tin), '') is null
       from public.sales_documents d
       join public.contacts c on c.id = d.contact_id
      where d.id = p_invoice),
    true);
$$;

revoke all on function app.pos_invoice_is_anonymous(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- "Boss, I need it under the company name"
-- ---------------------------------------------------------------------
create or replace function public.request_einvoice_for_sale(
  p_sale    uuid,
  p_contact uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale public.pos_sales;
  v_tin  text;
  v_ei   uuid;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'completed' or v_sale.invoice_id is null then
    raise exception
      'That sale has not been completed, so there is no invoice to name.'
      using errcode = '23514';
  end if;

  -- Already told LHDN this sale had no identified buyer.
  if exists (select 1 from public.einvoice_consolidation_items ci
              where ci.sales_document_id = v_sale.invoice_id) then
    raise exception
      'This sale has already gone into a consolidated e-Invoice. Raise a '
      'credit note and re-issue it if the buyer needs their own.'
      using errcode = '23514';
  end if;

  select nullif(btrim(c.tin), '') into v_tin
    from public.contacts c
   where c.id = p_contact and c.org_id = v_sale.org_id;
  if v_tin is null then
    raise exception
      'That customer has no TIN on file. LHDN needs one before an '
      'e-Invoice can be raised in their name.'
      using errcode = '23514';
  end if;

  update public.sales_documents
     set contact_id = p_contact
   where id = v_sale.invoice_id;

  update public.pos_sales
     set contact_id = p_contact
   where id = p_sale;

  v_ei := public.prepare_einvoice(v_sale.invoice_id);
  return v_ei;
end;
$$;

revoke all on function public.request_einvoice_for_sale(uuid, uuid) from public, anon;
grant execute on function public.request_einvoice_for_sale(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The absorb step, on its own
-- ---------------------------------------------------------------------
--
-- Split out of the function below for a reason worth writing down: the
-- roll-up returns `consolidation_id`, and `consolidation_id` is also a
-- column of the table it inserts into. A plpgsql OUT parameter and a
-- column of the same name make the `on conflict` target ambiguous, and
-- unlike an ordinary column reference an arbiter list cannot be
-- qualified -- there is no alias to hang it off. plpgsql does not
-- notice at creation time either; it refuses on the first call.
--
-- So the insert is moved somewhere no parameter is named after a
-- column, rather than the conflict clause being dropped. It is the
-- clause that makes running this twice safe, which is the whole point.
create or replace function app.pos_consolidation_absorb(
  p_org  uuid,
  p_con  uuid,
  p_from date,
  p_to   date)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_rows integer;
begin
  with candidates as (
    select d.id, d.total_amount
      from public.pos_sales s
      join public.sales_documents d on d.id = s.invoice_id
     where s.org_id = p_org
       and s.status = 'completed'
       and d.doc_date between p_from and p_to
       and d.einvoice_id is null
       and app.pos_invoice_is_anonymous(d.id)
  )
  insert into public.einvoice_consolidation_items
    (org_id, consolidation_id, sales_document_id, amount)
  select p_org, p_con, c.id, c.total_amount
    from candidates c
  on conflict (consolidation_id, sales_document_id) do nothing;

  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

revoke all on function app.pos_consolidation_absorb(uuid, uuid, date, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The month's anonymous sales, as one submission
-- ---------------------------------------------------------------------
--
-- Idempotent by construction: the consolidation is keyed on
-- (org, period_start, period_end) and its items on
-- (consolidation, sales_document), so running it twice on the same
-- month adds nothing. That matters more than it sounds — this is the
-- kind of function somebody runs again because they are not sure the
-- first one worked.
--
-- Refuses once the submission has gone. A consolidation that keeps
-- absorbing sales after it was sent to LHDN is a return that no longer
-- matches what was filed.
create or replace function public.consolidate_pos_einvoices(
  p_org   uuid,
  p_month date default (date_trunc('month', current_date) - interval '1 month')::date)
returns table (
  consolidation_id uuid,
  period_start     date,
  period_end       date,
  due_date         date,
  document_count   integer,
  total_amount     numeric,
  added            integer)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_from   date := date_trunc('month', p_month)::date;
  v_to     date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_con    uuid;
  v_status text;
  v_added  integer := 0;
begin
  if not app.can_write_module(p_org, 'einvoice') then
    raise exception 'not permitted to file e-Invoices for this organization'
      using errcode = '42501';
  end if;

  select c.id, c.status into v_con, v_status
    from public.einvoice_consolidations c
   where c.org_id = p_org and c.period_start = v_from and c.period_end = v_to;

  if v_con is not null and v_status not in ('draft', 'generated') then
    raise exception
      'The consolidation for % has already been submitted. A sale that '
      'missed it needs its own e-Invoice.', to_char(v_from, 'Mon YYYY')
      using errcode = '23514';
  end if;

  if v_con is null then
    insert into public.einvoice_consolidations
      (org_id, period_start, period_end, status, created_by)
    values (p_org, v_from, v_to, 'draft', auth.uid())
    returning id into v_con;
  end if;

  -- Every completed counter sale in the month that nobody claimed, and
  -- that has not already been given its own e-Invoice.
  v_added := app.pos_consolidation_absorb(p_org, v_con, v_from, v_to);

  -- Totals recomputed from the items rather than accumulated, for the
  -- reason every other total in this database is derived: a counter is
  -- wrong the moment a row is removed.
  update public.einvoice_consolidations c
     set document_count = (select count(*) from public.einvoice_consolidation_items i
                            where i.consolidation_id = c.id),
         total_amount   = (select coalesce(sum(i.amount), 0)
                             from public.einvoice_consolidation_items i
                            where i.consolidation_id = c.id)
   where c.id = v_con;

  return query
    select c.id, c.period_start, c.period_end, c.due_date,
           c.document_count, c.total_amount, v_added
      from public.einvoice_consolidations c where c.id = v_con;
end;
$$;

revoke all on function public.consolidate_pos_einvoices(uuid, date) from public, anon;
grant execute on function public.consolidate_pos_einvoices(uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- What is owed, and by when
-- ---------------------------------------------------------------------
--
-- The screen this is for is a nag: seven days after month end is not
-- long, and a shop that only discovers the deadline by missing it has
-- been let down by its software rather than by itself.
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
         ((m.period_end + 7) - current_date)::integer
    from months m
    left join public.einvoice_consolidations c
      on c.org_id = p_org and c.period_start = m.period_start
   where app.can_read_module(p_org, 'einvoice')
   order by m.period_start;
$$;

grant execute on function public.pos_einvoice_outstanding(uuid) to authenticated;

comment on function public.consolidate_pos_einvoices(uuid, date) is
  'Rolls a month of anonymous counter sales into one consolidated '
  'e-Invoice, due seven days after month end. Idempotent — the unique '
  'keys mean running it twice adds nothing, which matters because this '
  'is the kind of function somebody runs again to be sure.';

comment on function public.request_einvoice_for_sale(uuid, uuid) is
  'The customer who asks after paying. Re-bills a completed counter '
  'sale to an identified buyer and raises their own e-Invoice — and '
  'refuses once the sale has been consolidated, because that submission '
  'has already told LHDN the buyer was anonymous.';
