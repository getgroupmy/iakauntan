-- =====================================================================
-- iAkauntan :: 0014 reporting
--
-- Reports are functions rather than views so they can take a date range
-- and still be SECURITY DEFINER with an explicit membership check. The
-- ageing and stock views use security_invoker so plain RLS applies.
--
-- NOTE: report_trial_balance and report_balance_sheet are corrected in
-- migration 0016; the definitions here are the originals.
-- =====================================================================

create or replace function public.report_trial_balance(
  p_org_id uuid, p_from date default null, p_to date default current_date)
returns table (
  account_id uuid, code text, name text,
  account_type app.account_type, account_subtype app.account_subtype,
  opening_balance numeric, debit numeric, credit numeric, closing_balance numeric)
language sql stable security definer set search_path = public, app, pg_temp as $$
  with movements as (
    select l.account_id,
           sum(case when p_from is null or e.entry_date < p_from
                    then l.debit - l.credit else 0 end) as opening,
           sum(case when p_from is null or e.entry_date >= p_from then l.debit else 0 end) as dr,
           sum(case when p_from is null or e.entry_date >= p_from then l.credit else 0 end) as cr
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
     where l.org_id = p_org_id
       and e.status = 'posted'
       and e.entry_date <= p_to
     group by l.account_id)
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(coalesce(m.opening, 0) + case when a.account_type in ('asset','expense')
               then a.opening_balance else -a.opening_balance end, 2),
         round(coalesce(m.dr, 0), 2),
         round(coalesce(m.cr, 0), 2),
         round(coalesce(m.opening, 0) + coalesce(m.dr, 0) - coalesce(m.cr, 0)
               + case when a.account_type in ('asset','expense')
                      then a.opening_balance else -a.opening_balance end, 2)
    from public.accounts a
    left join movements m on m.account_id = a.id
   where a.org_id = p_org_id
     and a.deleted_at is null
     and not a.is_group
     and app.is_org_member(p_org_id)
   order by a.code;
$$;

create or replace function public.report_profit_loss(
  p_org_id uuid, p_from date, p_to date default current_date)
returns table (
  account_id uuid, code text, name text,
  account_type app.account_type, account_subtype app.account_subtype, amount numeric)
language sql stable security definer set search_path = public, app, pg_temp as $$
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(sum(case when a.account_type = 'revenue'
                        then l.credit - l.debit
                        else l.debit - l.credit end), 2) as amount
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
    join public.accounts a on a.id = l.account_id
   where l.org_id = p_org_id
     and e.status = 'posted'
     and e.entry_date between p_from and p_to
     and a.account_type in ('revenue', 'expense')
     and app.is_org_member(p_org_id)
   group by a.id, a.code, a.name, a.account_type, a.account_subtype
  having sum(l.debit - l.credit) <> 0
   order by a.code;
$$;

create or replace function public.report_balance_sheet(
  p_org_id uuid, p_as_at date default current_date)
returns table (
  account_id uuid, code text, name text,
  account_type app.account_type, account_subtype app.account_subtype, balance numeric)
language sql stable security definer set search_path = public, app, pg_temp as $$
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(coalesce(sum(case when a.account_type in ('asset', 'expense')
                                 then l.debit - l.credit
                                 else l.credit - l.debit end), 0)
               + a.opening_balance, 2) as balance
    from public.accounts a
    left join public.gl_lines l on l.account_id = a.id
    left join public.gl_entries e on e.id = l.entry_id
         and e.status = 'posted' and e.entry_date <= p_as_at
   where a.org_id = p_org_id
     and a.deleted_at is null
     and not a.is_group
     and a.account_type in ('asset', 'liability', 'equity')
     and app.is_org_member(p_org_id)
   group by a.id, a.code, a.name, a.account_type, a.account_subtype, a.opening_balance
   order by a.code;
$$;

-- ---------------------------------------------------------------------
-- Ageing and stock views (security_invoker set in 0010a hardening)
-- ---------------------------------------------------------------------
create or replace view public.v_ar_aging as
select d.org_id, d.id as invoice_id, d.doc_no, d.doc_date, d.due_date,
       d.contact_id, c.name as contact_name, c.code as contact_code,
       d.currency, d.total_amount, d.paid_amount, d.balance_amount,
       greatest(0, current_date - d.due_date) as days_overdue,
       case
         when d.due_date is null or current_date <= d.due_date then 'current'
         when current_date - d.due_date <= 30 then '1_30'
         when current_date - d.due_date <= 60 then '31_60'
         when current_date - d.due_date <= 90 then '61_90'
         else 'over_90'
       end as aging_bucket
  from public.sales_documents d
  join public.contacts c on c.id = d.contact_id
 where d.doc_type = 'invoice'
   and d.status not in ('draft', 'void')
   and d.deleted_at is null
   and d.balance_amount > 0;

create or replace view public.v_ap_aging as
select d.org_id, d.id as bill_id, d.doc_no, d.doc_date, d.due_date,
       d.contact_id, c.name as contact_name, c.code as contact_code,
       d.currency, d.total_amount, d.paid_amount, d.balance_amount,
       greatest(0, current_date - d.due_date) as days_overdue,
       case
         when d.due_date is null or current_date <= d.due_date then 'current'
         when current_date - d.due_date <= 30 then '1_30'
         when current_date - d.due_date <= 60 then '31_60'
         when current_date - d.due_date <= 90 then '61_90'
         else 'over_90'
       end as aging_bucket
  from public.purchase_documents d
  join public.contacts c on c.id = d.contact_id
 where d.doc_type = 'bill'
   and d.status not in ('draft', 'void')
   and d.deleted_at is null
   and d.balance_amount > 0;

create or replace view public.v_stock_valuation as
select sl.org_id, sl.item_id, i.code as item_code, i.name as item_name,
       i.uom_code, sl.warehouse_id, w.code as warehouse_code, w.name as warehouse_name,
       sl.quantity, sl.average_cost, sl.value,
       i.reorder_level,
       (sl.quantity <= i.reorder_level and i.reorder_level > 0) as needs_reorder
  from public.stock_levels sl
  join public.items i on i.id = sl.item_id
  join public.warehouses w on w.id = sl.warehouse_id
 where i.deleted_at is null;

-- ---------------------------------------------------------------------
-- SST return support (feeds the SST-02 form)
-- ---------------------------------------------------------------------
create or replace function public.report_sst_summary(
  p_org_id uuid, p_from date, p_to date)
returns table (
  tax_type_code text, tax_type_name text, direction text,
  taxable_amount numeric, tax_amount numeric)
language sql stable security definer set search_path = public, app, pg_temp as $$
  select t.tax_type_code, rt.description, 'output'::text,
         round(sum(l.line_subtotal), 2), round(sum(l.tax_amount), 2)
    from public.sales_document_lines l
    join public.sales_documents d on d.id = l.document_id
    join public.tax_codes t on t.id = l.tax_code_id
    join public.ref_tax_types rt on rt.code = t.tax_type_code
   where d.org_id = p_org_id
     and d.doc_type in ('invoice', 'debit_note')
     and d.status not in ('draft', 'void')
     and d.doc_date between p_from and p_to
     and app.is_org_member(p_org_id)
   group by t.tax_type_code, rt.description
  union all
  select t.tax_type_code, rt.description, 'input'::text,
         round(sum(l.line_subtotal), 2), round(sum(l.tax_amount), 2)
    from public.purchase_document_lines l
    join public.purchase_documents d on d.id = l.document_id
    join public.tax_codes t on t.id = l.tax_code_id
    join public.ref_tax_types rt on rt.code = t.tax_type_code
   where d.org_id = p_org_id
     and d.doc_type in ('bill', 'purchase_debit_note')
     and d.status not in ('draft', 'void')
     and d.doc_date between p_from and p_to
     and app.is_org_member(p_org_id)
   group by t.tax_type_code, rt.description;
$$;

-- ---------------------------------------------------------------------
-- Dashboard: every tile in one round trip
-- ---------------------------------------------------------------------
create or replace function public.dashboard_summary(
  p_org_id uuid, p_from date default null, p_to date default current_date)
returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_from date := coalesce(p_from, date_trunc('month', current_date)::date);
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
         and due_date < current_date and balance_amount > 0),
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
         and due_date <= current_date + interval '1 day'),
    'low_stock', (
      select count(*) from public.items
       where org_id = p_org_id and deleted_at is null and track_inventory
         and reorder_level > 0 and quantity_on_hand <= reorder_level)
  ) into v_result;

  return v_result;
end;
$$;

create or replace function public.report_revenue_trend(
  p_org_id uuid, p_months integer default 12)
returns table (period date, revenue numeric, expenses numeric)
language sql stable security definer set search_path = public, app, pg_temp as $$
  with months as (
    select generate_series(
      date_trunc('month', current_date) - ((p_months - 1) || ' months')::interval,
      date_trunc('month', current_date), '1 month')::date as period)
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
