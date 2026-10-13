-- =====================================================================
-- iAkauntan :: 0873 the company's reports are its staff's
--
-- `0871` and `0872` held an `employee` with no access type to her own
-- record, leave, claims and payslips: the module gates and the tables
-- refuse her. The definer functions do not ask either. A definer reads
-- past every policy, and 83 of them that `authenticated` may call ask
-- `is_org_member` and nothing narrower -- so she could still call
-- `report_ar_aging`, `report_sst_summary`, `customer_credit_status`,
-- `report_statement_of_account` and the rest and be given the
-- company's figures.
--
-- Measured on 13 October 2026, locally, after `0872`, as an `employee`
-- member with no access type, with the role `authenticated`:
-- `report_revenue_trend`, `document_numbering`, `contact_duplicates`
-- and `customer_credit_status` answered her exactly as they answer the
-- owner.
--
-- Production held no `employee` member on 13 October.
--
-- Answered "refuse her in each, by domain". `app.is_staff_member(org)`
-- is `is_org_member` for anybody who is not self-service only. This
-- migration re-creates the sales, purchases, tax and contact functions
-- among the 83 with that in place of `is_org_member` and nothing else
-- changed -- each body below is the body that was live, as
-- `pg_get_functiondef` gave it, with that one substitution, so what
-- each answers a member who is not self-service only, and how it
-- refuses one who is, is what it was. `0874` and `0875` take stock and
-- lots, and the corporate, property and people functions.
-- `employee_definers.sql` names the few left open to her and those not
-- yet done, and fails on any other definer that asks `is_org_member`
-- alone.
-- =====================================================================

create or replace function app.is_staff_member(p_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select app.is_org_member(p_org_id)
     and not app.is_self_service_only(p_org_id);
$$;

revoke all on function app.is_staff_member(uuid) from public, anon;
grant execute on function app.is_staff_member(uuid) to authenticated;

comment on function app.is_staff_member(uuid) is
  'A member of this company who is more than self-service: what a definer asks before it answers with the company''s records rather than the caller''s own (0873).';

-- report_ar_aging: 1 membership check
CREATE OR REPLACE FUNCTION public.report_ar_aging(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(contact_id uuid, contact_code text, contact_name text, doc_kind text, document_id uuid, doc_no text, doc_date date, due_date date, currency character, outstanding numeric, base_outstanding numeric, days_overdue integer, aging_bucket text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with allocations as (
    -- Only allocations whose two ends were both in the ledger by the
    -- as-at date. `discount_amount` is carried because the settlement
    -- trigger treats it as settling the invoice; nothing in the app
    -- writes it today, and if something ever does it will need a
    -- journal of its own before it can be trusted here.
    select a.invoice_id, a.receipt_id, a.credit_note_id,
           a.amount, a.discount_amount
      from public.payment_allocations a
      join public.sales_documents inv on inv.id = a.invoice_id
       and inv.gl_entry_id is not null and inv.deleted_at is null
       and inv.status <> 'void' and inv.doc_date <= p_as_at
      left join public.receipts r on r.id = a.receipt_id
       and r.gl_entry_id is not null and r.deleted_at is null
       and r.status <> 'void'
      left join public.sales_documents cn on cn.id = a.credit_note_id
       and cn.gl_entry_id is not null and cn.deleted_at is null
       and cn.status <> 'void'
      -- 0747. Three more ways a receivable is settled, each of which
      -- credits the control account and writes an allocation: a contra
      -- against the same party's bill (0272), a deposit applied (0273)
      -- and a post-dated cheque taken in (0275). Each counts from the
      -- day its journal is dated, and not once it is undone -- a void
      -- contra and a bounced or cancelled cheque delete their
      -- allocations anyway, and an applied deposit cannot be voided.
      left join public.contra_notes k on k.id = a.contra_id
       and k.gl_entry_id is not null and k.status <> 'void'
      left join public.deposit_notes n on n.id = a.deposit_id
       and n.gl_entry_id is not null and n.status <> 'void'
      left join public.post_dated_cheques q on q.id = a.pdc_id
       and q.gl_entry_id is not null
       and q.status in ('held', 'deposited', 'cleared')
     where a.org_id = p_org_id
       and coalesce(r.receipt_date, cn.doc_date, k.contra_date,
                    case when n.id is not null then a.applied_on end,
                    q.received_on) <= p_as_at
  ),
  -- Documents that moved the receivable: invoices and debit notes add
  -- to it, credit notes and refund notes take away.
  documents as (
    select d.contact_id, d.doc_type::text as doc_kind, d.id as document_id,
           d.doc_no, d.doc_date, d.due_date, d.currency,
           coalesce(d.exchange_rate, 1) as rate,
           case when d.doc_type in ('credit_note', 'refund_note')
                then -1 else 1 end
           * (d.total_amount - case
               when d.doc_type = 'credit_note' then
                 -- A credit note keeps its own full total in
                 -- `balance_amount` however much of it has been used,
                 -- so what is left has to be worked out here.
                 coalesce((select sum(al.amount) from allocations al
                            where al.credit_note_id = d.id), 0)
               when d.doc_type in ('invoice', 'debit_note') then
                 coalesce((select sum(al.amount + al.discount_amount)
                             from allocations al
                            where al.invoice_id = d.id), 0)
               -- A refund note has no way to be allocated against
               -- anything, so it stands until it is reversed.
               else 0 end) as outstanding
      from public.sales_documents d
     where d.org_id = p_org_id
       and d.doc_type in ('invoice', 'debit_note', 'credit_note', 'refund_note')
       and d.gl_entry_id is not null
       and d.status <> 'void'
       and d.deleted_at is null
       and d.doc_date <= p_as_at
    union all
    -- Cash received and not yet applied to anything. The receipt
    -- credited the receivable on the day it was banked whether or not
    -- anybody has matched it since, so it belongs on the listing.
    select r.contact_id, 'receipt', r.id, r.receipt_no,
           r.receipt_date, null::date, r.currency,
           coalesce(r.exchange_rate, 1),
           -(r.amount - coalesce((select sum(al.amount) from allocations al
                                   where al.receipt_id = r.id), 0))
      from public.receipts r
     where r.org_id = p_org_id
       and r.gl_entry_id is not null
       and r.status <> 'void'
       and r.deleted_at is null
       and r.receipt_date <= p_as_at
  )
  select d.contact_id, c.code, c.name,
         d.doc_kind, d.document_id, d.doc_no, d.doc_date, d.due_date,
         d.currency,
         round(d.outstanding, 2),
         round(d.outstanding * d.rate, 2),
         greatest(0, p_as_at - coalesce(d.due_date, d.doc_date))::integer,
         case
           when p_as_at <= coalesce(d.due_date, d.doc_date) then 'current'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 30 then '1_30'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 60 then '31_60'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 90 then '61_90'
           else 'over_90'
         end
    from documents d
    join public.contacts c on c.id = d.contact_id
   where round(d.outstanding, 2) <> 0
     and app.is_staff_member(p_org_id)
   order by c.name, d.doc_date, d.doc_no;
$function$;

-- report_ap_aging: 1 membership check
CREATE OR REPLACE FUNCTION public.report_ap_aging(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(contact_id uuid, contact_code text, contact_name text, doc_kind text, document_id uuid, doc_no text, doc_date date, due_date date, currency character, outstanding numeric, base_outstanding numeric, days_overdue integer, aging_bucket text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with allocations as (
    select a.bill_id, a.payment_id, a.amount, a.discount_amount
      from public.payment_allocations a
      join public.purchase_documents b on b.id = a.bill_id
       and b.gl_entry_id is not null and b.deleted_at is null
       and b.status <> 'void' and b.doc_date <= p_as_at
      left join public.purchase_payments p on p.id = a.payment_id
       and p.gl_entry_id is not null and p.deleted_at is null
       and p.status <> 'void'
      left join public.sales_documents cn on cn.id = a.credit_note_id
       and cn.gl_entry_id is not null and cn.deleted_at is null
       and cn.status <> 'void'
      left join public.withholding_certificates w on w.id = a.withholding_id
       and w.gl_entry_id is not null and w.deleted_at is null
       and w.status <> 'void'
      -- 0747. The same three as the receivables side: a contra, a
      -- deposit paid to the supplier and applied, and a post-dated
      -- cheque written out.
      left join public.contra_notes k on k.id = a.contra_id
       and k.gl_entry_id is not null and k.status <> 'void'
      left join public.deposit_notes n on n.id = a.deposit_id
       and n.gl_entry_id is not null and n.status <> 'void'
      left join public.post_dated_cheques q on q.id = a.pdc_id
       and q.gl_entry_id is not null
       and q.status in ('held', 'deposited', 'cleared')
     where a.org_id = p_org_id
       and coalesce(p.payment_date, cn.doc_date, w.cert_date, k.contra_date,
                    case when n.id is not null then a.applied_on end,
                    q.received_on) <= p_as_at
  ),
  documents as (
    select d.contact_id, d.doc_type::text as doc_kind, d.id as document_id,
           d.doc_no, d.doc_date, d.due_date, d.currency,
           coalesce(d.exchange_rate, 1) as rate,
           case when d.doc_type = 'purchase_credit_note' then -1 else 1 end
           * (d.total_amount - case
               when d.doc_type in ('bill', 'purchase_debit_note') then
                 coalesce((select sum(al.amount + al.discount_amount)
                             from allocations al where al.bill_id = d.id), 0)
               else 0 end) as outstanding
      from public.purchase_documents d
     where d.org_id = p_org_id
       and d.doc_type in ('bill', 'purchase_debit_note', 'purchase_credit_note')
       and d.gl_entry_id is not null
       and d.status <> 'void'
       and d.deleted_at is null
       and d.doc_date <= p_as_at
    union all
    select p.contact_id, 'payment', p.id, p.payment_no,
           p.payment_date, null::date, p.currency,
           coalesce(p.exchange_rate, 1),
           -(p.amount - coalesce((select sum(al.amount) from allocations al
                                   where al.payment_id = p.id), 0))
      from public.purchase_payments p
     where p.org_id = p_org_id
       and p.gl_entry_id is not null
       and p.status <> 'void'
       and p.deleted_at is null
       and p.payment_date <= p_as_at
  )
  select d.contact_id, c.code, c.name,
         d.doc_kind, d.document_id, d.doc_no, d.doc_date, d.due_date,
         d.currency,
         round(d.outstanding, 2),
         round(d.outstanding * d.rate, 2),
         greatest(0, p_as_at - coalesce(d.due_date, d.doc_date))::integer,
         case
           when p_as_at <= coalesce(d.due_date, d.doc_date) then 'current'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 30 then '1_30'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 60 then '31_60'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 90 then '61_90'
           else 'over_90'
         end
    from documents d
    join public.contacts c on c.id = d.contact_id
   where round(d.outstanding, 2) <> 0
     and app.is_staff_member(p_org_id)
   order by c.name, d.doc_date, d.doc_no;
$function$;

-- report_sst_summary: 2 membership checks
CREATE OR REPLACE FUNCTION public.report_sst_summary(p_org_id uuid, p_from date, p_to date)
 RETURNS TABLE(tax_type_code text, tax_type_name text, direction text, taxable_amount numeric, tax_amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with sales as (
    select t.tax_type_code as code, rt.description as descr,
           -- The signs app.post_sales_document uses, and for the same
           -- reason: a credit note undoes a sale.
           case when d.doc_type in ('credit_note', 'refund_note')
                then -1 else 1 end as sign,
           -- 0748. In ringgit, which is what the return is made in and
           -- what the ledger holds. Each line converted on its own, so
           -- a foreign document of several lines can differ from the
           -- ledger -- which converts the document's tax once -- by a
           -- sen of rounding, never by the rate.
           round(l.line_subtotal * coalesce(d.exchange_rate, 1), 2)
             as line_subtotal,
           round(l.tax_amount * coalesce(d.exchange_rate, 1), 2)
             as tax_amount
      from public.sales_document_lines l
      join public.sales_documents d on d.id = l.document_id
      join public.tax_codes t on t.id = l.tax_code_id
      join public.ref_tax_types rt on rt.code = t.tax_type_code
     where d.org_id = p_org_id
       and d.doc_type in ('invoice', 'credit_note', 'debit_note',
                          'refund_note')
       and d.status not in ('draft', 'void')
       and d.doc_date between p_from and p_to
  ),
  -- The tax a Malaysian restaurant charges on the ten per cent is
  -- service tax like any other, it is in the ledger at 2130, and until
  -- `0418` it was on the document's `tax_amount` with no tax code on it
  -- -- so a return built by tax type could not put it anywhere, and did
  -- not. Eighty sen in every hundred ringgit, undeclared, every taxable
  -- period.
  --
  -- Read from the header rather than the lines because that is where it
  -- is: the charge is not a line on the bill, it is a percentage of all
  -- of them.
  service_charge as (
    select t.tax_type_code as code, rt.description as descr,
           case when d.doc_type in ('credit_note', 'refund_note')
                then -1 else 1 end as sign,
           round(d.service_charge_amount * coalesce(d.exchange_rate, 1), 2)
             as line_subtotal,
           round(d.service_charge_tax * coalesce(d.exchange_rate, 1), 2)
             as tax_amount
      from public.sales_documents d
      join public.tax_codes t on t.id = d.service_charge_tax_code_id
      join public.ref_tax_types rt on rt.code = t.tax_type_code
     where d.org_id = p_org_id
       and d.doc_type in ('invoice', 'credit_note', 'debit_note',
                          'refund_note')
       and d.status not in ('draft', 'void')
       and d.doc_date between p_from and p_to
       -- A charge with no tax on it is still not nothing: the stall in
       -- `pos_service_charge.sql` adds ten per cent and is not
       -- registered, so the taxable value is right and the tax is zero.
       -- A document with no charge at all has nothing to declare.
       and coalesce(d.service_charge_amount, 0) <> 0
  ),
  purchases as (
    select t.tax_type_code as code, rt.description as descr,
           case when d.doc_type = 'purchase_credit_note'
                then -1 else 1 end as sign,
           round(l.line_subtotal * coalesce(d.exchange_rate, 1), 2)
             as line_subtotal,
           round(l.tax_amount * coalesce(d.exchange_rate, 1), 2)
             as tax_amount
      from public.purchase_document_lines l
      join public.purchase_documents d on d.id = l.document_id
      join public.tax_codes t on t.id = l.tax_code_id
      join public.ref_tax_types rt on rt.code = t.tax_type_code
     where d.org_id = p_org_id
       and d.doc_type in ('bill', 'purchase_credit_note',
                          'purchase_debit_note')
       and d.status not in ('draft', 'void')
       and d.doc_date between p_from and p_to
  )
  select o.code, o.descr, 'output'::text,
         round(sum(o.sign * o.line_subtotal), 2),
         round(sum(o.sign * o.tax_amount), 2)
    from (select * from sales
          union all
          select * from service_charge) o
   where app.is_staff_member(p_org_id)
   group by o.code, o.descr
  union all
  select p.code, p.descr, 'input'::text,
         round(sum(p.sign * p.line_subtotal), 2),
         round(sum(p.sign * p.tax_amount), 2)
    from purchases p
   where app.is_staff_member(p_org_id)
   group by p.code, p.descr;
$function$;

-- report_revenue_trend: 1 membership check
CREATE OR REPLACE FUNCTION public.report_revenue_trend(p_org_id uuid, p_months integer DEFAULT 12)
 RETURNS TABLE(period date, revenue numeric, expenses numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
   where app.is_staff_member(p_org_id)
   order by m.period;
$function$;

-- report_statement_of_account: 1 membership check
CREATE OR REPLACE FUNCTION public.report_statement_of_account(p_contact_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS TABLE(line_no integer, entry_date date, kind text, doc_no text, due_date date, currency character, debit numeric, credit numeric, base_debit numeric, base_credit numeric, balance numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org  uuid;
  v_from date := coalesce(p_from, date_trunc('month', app.today())::date);
  v_to   date := coalesce(p_to, app.today());
begin
  select c.org_id into v_org from public.contacts c where c.id = p_contact_id;
  if v_org is null then
    raise exception 'No such contact.' using errcode = '22023';
  end if;
  -- Asked here rather than left to a policy: this function is SECURITY
  -- DEFINER and reads two tables directly, so without this it would
  -- hand anybody holding a uuid a customer's whole ledger.
  if not app.is_staff_member(v_org) then
    raise exception 'Not your company' using errcode = '42501';
  end if;
  if v_to < v_from then
    raise exception 'The statement ends before it begins.'
      using errcode = '22023';
  end if;

  return query
  with movements as (
    select d.doc_date as entry_date,
           d.doc_type::text as kind,
           d.doc_no,
           d.due_date,
           d.currency,
           case when d.doc_type in ('invoice', 'debit_note')
                then d.total_amount else 0 end as debit,
           case when d.doc_type in ('credit_note', 'refund_note')
                then d.total_amount else 0 end as credit,
           coalesce(d.exchange_rate, 1) as rate
      from public.sales_documents d
     where d.contact_id = p_contact_id
       and d.org_id = v_org
       and d.doc_type in ('invoice', 'debit_note', 'credit_note',
                          'refund_note')
       and d.gl_entry_id is not null
       and d.status <> 'void'
       and d.deleted_at is null
    union all
    select r.receipt_date, 'receipt', r.receipt_no, null::date, r.currency,
           0, r.amount, coalesce(r.exchange_rate, 1)
      from public.receipts r
     where r.contact_id = p_contact_id
       and r.org_id = v_org
       and r.gl_entry_id is not null
       and r.status <> 'void'
       and r.deleted_at is null
    union all
    -- 0747. The other three ways the customer's account was credited:
    -- set off against what we owed him, his deposit applied, and his
    -- post-dated cheque taken in. One line for each, at what it settled
    -- of this customer's invoices, on the day its journal is dated.
    select coalesce(k.contra_date, a.applied_on, q.received_on),
           case when k.id is not null then 'contra'
                when n.id is not null then 'deposit'
                else 'cheque' end,
           coalesce(k.contra_no, n.deposit_no, q.pdc_no),
           null::date, d.currency,
           0, sum(a.amount), coalesce(d.exchange_rate, 1)
      from public.payment_allocations a
      join public.sales_documents d on d.id = a.invoice_id
       and d.contact_id = p_contact_id and d.org_id = v_org
       and d.gl_entry_id is not null and d.status <> 'void'
       and d.deleted_at is null
      left join public.contra_notes k on k.id = a.contra_id
       and k.gl_entry_id is not null and k.status <> 'void'
      left join public.deposit_notes n on n.id = a.deposit_id
       and n.gl_entry_id is not null and n.status <> 'void'
      left join public.post_dated_cheques q on q.id = a.pdc_id
       and q.gl_entry_id is not null
       and q.status in ('held', 'deposited', 'cleared')
     where a.org_id = v_org
       and (k.id is not null or n.id is not null or q.id is not null)
     group by k.id, k.contra_date, k.contra_no, n.id, n.deposit_no,
              a.applied_on, q.id, q.received_on, q.pdc_no, d.currency,
              d.exchange_rate
  ),
  -- Everything before the period, as one number. Not listed: a
  -- statement whose opening balance is itself a list is a statement
  -- for a different period.
  opening as (
    select coalesce(sum(round(m.debit * m.rate, 2)
                      - round(m.credit * m.rate, 2)), 0) as amount
      from movements m
     where m.entry_date < v_from
  ),
  inside as (
    select m.*,
           round(m.debit * m.rate, 2) as base_debit,
           round(m.credit * m.rate, 2) as base_credit
      from movements m
     where m.entry_date between v_from and v_to
  ),
  ordered as (
    select i.*,
           row_number() over (order by i.entry_date, i.kind, i.doc_no)
             as seq
      from inside i
  )
  select 0, v_from - 1, 'opening', null::text, null::date, null::char(3),
         0::numeric, 0::numeric, 0::numeric, 0::numeric, o.amount
    from opening o
  union all
  select r.seq::integer, r.entry_date, r.kind, r.doc_no, r.due_date,
         r.currency, r.debit, r.credit, r.base_debit, r.base_credit,
         (select o.amount from opening o)
           + sum(r.base_debit - r.base_credit) over (
               order by r.seq rows between unbounded preceding
                                       and current row)
    from ordered r
   order by 1;
end $function$;

-- report_withholding: 1 membership check
CREATE OR REPLACE FUNCTION public.report_withholding(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(certificate_id uuid, certificate_no text, cert_date date, contact_name text, section text, form_code text, currency character, gross_amount numeric, rate numeric, tax_amount numeric, base_tax_amount numeric, due_date date, remitted_on date, days_late integer, penalty_if_unpaid numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
     and app.is_staff_member(p_org_id)
   order by c.form_code, c.cert_date, c.certificate_no;
$function$;

-- report_late_orders: 1 membership check
CREATE OR REPLACE FUNCTION public.report_late_orders(p_org_id uuid, p_as_at date DEFAULT NULL::date)
 RETURNS TABLE(document_id uuid, doc_no text, doc_date date, delivery_date date, days_late integer, contact_name text, ordered numeric, fulfilled numeric, outstanding numeric, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
     and app.is_staff_member(p_org_id)
   order by a.delivery_date;
$function$;

-- report_win_loss: 1 membership check
CREATE OR REPLACE FUNCTION public.report_win_loss(p_org_id uuid, p_from date, p_to date)
 RETURNS TABLE(outcome text, reason text, deals integer, amount numeric, competitors text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select o.status,
         coalesce(nullif(trim(coalesce(o.won_reason, o.lost_reason)), ''),
                  'Not given'),
         count(*)::integer,
         coalesce(sum(o.amount), 0),
         -- Named rather than counted: a report saying "three
         -- competitors" tells nobody who to go and look at.
         nullif(string_agg(distinct nullif(trim(o.competitor), ''), ', '), '')
    from public.opportunities o
   where o.org_id = p_org_id
     and o.deleted_at is null
     and o.status in ('won', 'lost', 'abandoned')
     and o.actual_close_date between p_from and p_to
     and app.is_staff_member(p_org_id)
   group by 1, 2
   order by 1, 4 desc;
$function$;

-- customer_credit_status: 1 membership check
CREATE OR REPLACE FUNCTION public.customer_credit_status(p_contact_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org         uuid;
  v_limit       numeric(18, 2);
  v_outstanding numeric(18, 2);
  v_control     text;
  v_hold        boolean;
  v_name        text;
begin
  select c.org_id, coalesce(c.credit_limit, 0),
         coalesce(c.credit_hold, false), c.name
    into v_org, v_limit, v_hold, v_name
    from public.contacts c where c.id = p_contact_id;
  if v_org is null then
    raise exception 'Contact % not found', p_contact_id using errcode = 'P0002';
  end if;
  if not app.is_staff_member(v_org) then
    raise exception 'Not a member of organization %', v_org using errcode = '42501';
  end if;

  select credit_control into v_control
    from public.organizations where id = v_org;

  select coalesce(sum(d.balance_amount * coalesce(d.exchange_rate, 1)), 0)
    into v_outstanding
    from public.sales_documents d
   where d.org_id = v_org and d.contact_id = p_contact_id
     and d.gl_entry_id is not null and d.status <> 'void'
     and d.deleted_at is null;

  return jsonb_build_object(
    'control', coalesce(v_control, 'warn'),
    'credit_limit', v_limit,
    'outstanding', round(v_outstanding, 2),
    'available', case when v_limit <= 0 then null
                      else round(v_limit - v_outstanding, 2) end,
    'over_limit', v_limit > 0 and v_outstanding > v_limit,
    -- The hold, which this function did not report and
    -- `app.enforce_credit_limit` refuses on. Reported plainly rather
    -- than folded into `over_limit`: they are different facts with
    -- different answers -- a limit is raised or a payment taken, a hold
    -- is taken off by whoever put it on.
    'credit_hold', v_hold,
    'contact_name', v_name);
end;
$function$;

-- invoice_credit_remaining: 1 membership check
CREATE OR REPLACE FUNCTION public.invoice_credit_remaining(p_invoice uuid)
 RETURNS TABLE(line_id uuid, line_no integer, item_id uuid, description text, uom_code text, unit_price numeric, invoiced numeric, credited numeric, remaining numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_org uuid;
begin
  select d.org_id into v_org from public.sales_documents d
   where d.id = p_invoice and d.doc_type = 'invoice';
  if v_org is null then
    raise exception 'No such invoice.' using errcode = 'P0002';
  end if;
  if not app.is_staff_member(v_org) then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;

  return query
  with credited as (
    select cl.item_id, cl.description, sum(cl.quantity) as qty
      from public.sales_documents c
      join public.sales_document_lines cl on cl.document_id = c.id
     where c.original_invoice_id = p_invoice
       and c.doc_type = 'credit_note'
       and c.status = 'posted'
       and cl.line_type = 'item'
     group by cl.item_id, cl.description
  )
  select l.id, l.line_no, l.item_id, l.description, l.uom_code, l.unit_price,
         l.quantity,
         coalesce(c.qty, 0),
         greatest(l.quantity - coalesce(c.qty, 0), 0)
    from public.sales_document_lines l
    left join credited c
      on c.item_id is not distinct from l.item_id
     and c.description = l.description
   where l.document_id = p_invoice
     and l.line_type = 'item'
   order by l.line_no;
end;
$function$;

-- bill_credit_remaining: 1 membership check
CREATE OR REPLACE FUNCTION public.bill_credit_remaining(p_bill uuid)
 RETURNS TABLE(line_id uuid, line_no integer, item_id uuid, description text, uom_code text, unit_price numeric, billed numeric, credited numeric, remaining numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_org uuid;
begin
  select d.org_id into v_org from public.purchase_documents d
   where d.id = p_bill and d.doc_type = 'bill';
  if v_org is null then
    raise exception 'No such bill.' using errcode = 'P0002';
  end if;
  if not app.is_staff_member(v_org) then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;

  return query
  with credited as (
    select cl.item_id, cl.description, sum(cl.quantity) as qty
      from public.purchase_documents c
      join public.purchase_document_lines cl on cl.document_id = c.id
     where c.original_bill_id = p_bill
       and c.doc_type = 'purchase_credit_note'
       and c.status = 'posted'
       and cl.line_type = 'item'
     group by cl.item_id, cl.description
  )
  select l.id, l.line_no, l.item_id, l.description, l.uom_code, l.unit_price,
         l.quantity,
         coalesce(c.qty, 0),
         greatest(l.quantity - coalesce(c.qty, 0), 0)
    from public.purchase_document_lines l
    left join credited c
      on c.item_id is not distinct from l.item_id
     and c.description = l.description
   where l.document_id = p_bill
     and l.line_type = 'item'
   order by l.line_no;
end;
$function$;

-- open_items: 4 membership checks
CREATE OR REPLACE FUNCTION public.open_items(p_contact_id uuid)
 RETURNS TABLE(side text, kind text, item_id uuid, doc_no text, item_date date, due_date date, currency text, total numeric, remaining numeric, allocatable boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with me as (select c.* from public.contacts c where c.id = p_contact_id),
  -- 0477 links a company's records through `party_id`, so a customer
  -- filed twice is one account here. The portal draws the same circle
  -- for the same reason: a clerk knocking off against "the other
  -- record" is the mistake this is meant to prevent.
  family as (
    select c2.id from public.contacts c2, me
     where c2.org_id = me.org_id
       and (c2.id = me.id
            or (me.party_id is not null and c2.party_id = me.party_id))
  )
  select 'owes'::text, d.doc_type::text, d.id, d.doc_no, d.doc_date,
         d.due_date, d.currency::text, d.total_amount, d.balance_amount,
         true
    from public.sales_documents d, me
   where d.org_id = me.org_id
     and app.is_staff_member(me.org_id)
     and d.contact_id in (select id from family)
     and d.doc_type in ('invoice', 'debit_note')
     and d.gl_entry_id is not null
     and d.status <> 'void'
     and d.deleted_at is null
     and round(coalesce(d.balance_amount, 0), 2) > 0
  union all
  -- 0629 made this one real. `balance_amount` is what is left on it.
  select 'credit', 'credit_note', d.id, d.doc_no, d.doc_date, null,
         d.currency::text, d.total_amount, d.balance_amount, true
    from public.sales_documents d, me
   where d.org_id = me.org_id
     and app.is_staff_member(me.org_id)
     and d.contact_id in (select id from family)
     and d.doc_type = 'credit_note'
     and d.gl_entry_id is not null
     and d.status <> 'void'
     and d.deleted_at is null
     and round(coalesce(d.balance_amount, 0), 2) > 0
  union all
  select 'credit', 'receipt', r.id, r.receipt_no, r.receipt_date, null,
         r.currency::text, r.amount, r.unapplied_amount, true
    from public.receipts r, me
   where r.org_id = me.org_id
     and app.is_staff_member(me.org_id)
     and r.contact_id in (select id from family)
     and r.gl_entry_id is not null
     and round(coalesce(r.unapplied_amount, 0), 2) > 0
  union all
  -- Shown and NOT allocatable: applying one posts a journal, and
  -- `deposit_apply_sheet.dart` is where that decision is made. Left off
  -- this list entirely, a clerk would knock off what they could see and
  -- believe the account was clear.
  select 'credit', 'deposit', n.id, n.deposit_no, n.deposit_date, null,
         n.currency::text, n.amount, n.balance_amount, false
    from public.deposit_notes n, me
   where n.org_id = me.org_id
     and app.is_staff_member(me.org_id)
     and n.contact_id in (select id from family)
     and n.status not in ('void', 'settled')
     and round(coalesce(n.balance_amount, 0), 2) > 0
   order by 1 desc, 5, 4;
$function$;

-- sst_return_lines: 1 membership check
CREATE OR REPLACE FUNCTION public.sst_return_lines(p_org_id uuid, p_period_end date)
 RETURNS TABLE(tax_type_code text, tax_type_name text, basis text, taxable_amount numeric, tax_amount numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_p record;
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of this organization' using errcode = '42501';
  end if;

  select * into v_p from app.sst_period_for(p_org_id, p_period_end);
  if v_p.period_end is null then
    return;
  end if;

  return query
  select d.tax_type_code, rt.description, d.basis,
         d.taxable_amount, d.tax_amount
    from app.sst_output_due(p_org_id, v_p.period_start, v_p.period_end) d
    join public.ref_tax_types rt on rt.code = d.tax_type_code
   order by d.tax_type_code, d.basis;
end;
$function$;

-- sst_taxable_periods: 1 membership check
CREATE OR REPLACE FUNCTION public.sst_taxable_periods(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS TABLE(period_start date, period_end date, due_date date, is_first boolean, output_tax numeric, filed_at timestamp with time zone, reference text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org   public.organizations;
  v_from  date;
  v_to    date;
  v_cur   date;
  r       record;
begin
  if not app.is_staff_member(p_org_id) then
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
    exit when r.period_end is null;

    period_start := r.period_start;
    period_end   := r.period_end;
    due_date     := r.due_date;
    is_first     := r.is_first;

    -- Not `report_sst_summary`: that sums by document date, and
    -- service tax is due when the money arrives. See 0456.
    select coalesce(sum(s.tax_amount), 0) into output_tax
      from app.sst_output_due(p_org_id, r.period_start, r.period_end) s;

    select f.filed_at, f.reference into filed_at, reference
      from public.sst_returns f
     where f.org_id = p_org_id and f.period_end = r.period_end;

    return next;
    v_cur := r.period_end + 1;
  end loop;
end;
$function$;

-- tax_computation_misfiled: 1 membership check
CREATE OR REPLACE FUNCTION public.tax_computation_misfiled(p_org_id uuid)
 RETURNS TABLE(account_id uuid, code text, name text, treatment text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select a.id, a.code, a.name, a.tax_treatment
    from public.accounts a
    join public.tax_treatments t on t.code = a.tax_treatment
   where a.org_id = p_org_id
     and a.deleted_at is null
     and t.applies_to <> a.account_type::text
     and app.is_staff_member(p_org_id)
   order by a.code;
$function$;

-- tax_estimate_first_period: 1 membership check
CREATE OR REPLACE FUNCTION public.tax_estimate_first_period(p_estimate_id uuid)
 RETURNS TABLE(is_first_period boolean, form text, commenced_on date, filing_due date, ordinary_filing_due date, filing_due_known boolean, exempt_instalments boolean, exemption_known boolean, exempt_until_ya integer, paid_up_capital numeric, gross_business_income numeric, capital_limit numeric, turnover_limit numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  e        record;
  r        record;
  rates    record;
  v_known  boolean;
  v_exempt boolean;
begin
  select te.*, fy.start_date, fy.end_date into e
    from public.tax_estimates te
    join public.fiscal_years fy on fy.id = te.fiscal_year_id
   where te.id = p_estimate_id;

  if e is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.is_staff_member(e.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select * into r from public.tax_estimate_rules ru
   where ru.year_of_assessment = e.year_of_assessment
     and ru.form = e.form;
  if r is null then
    raise exception 'No % rules for year of assessment %',
      e.form, e.year_of_assessment using errcode = 'P0002';
  end if;

  -- The SME limits are READ from `0665`'s table rather than copied
  -- into this one. Two tables that both define what an SME is would
  -- agree on the day they were written.
  select * into rates from public.company_tax_rates cr
   where cr.year_of_assessment = e.year_of_assessment;

  -- Both figures, or the test was not taken. Same rule and the same
  -- reason as `0665`'s SME band: unknown says so rather than quietly
  -- coming out as "does not qualify", which is the same answer with
  -- none of the warning.
  v_known := e.first_period
             and e.paid_up_capital is not null
             and e.gross_business_income is not null
             and rates.year_of_assessment is not null;

  v_exempt := v_known
              and r.first_period_exempt_years > 0
              and e.paid_up_capital <= rates.sme_capital_limit
              and e.gross_business_income <= rates.sme_turnover_limit;

  return query select
    e.first_period,
    e.form,
    e.commenced_on,
    -- Three months from commencing operations, where the date is
    -- known. Null rather than a guess: a deadline computed from a
    -- date nobody supplied is a deadline somebody will trust.
    case when e.first_period and e.commenced_on is not null
              and r.first_period_filing_months is not null
         then (e.commenced_on
               + make_interval(months => r.first_period_filing_months)
               - interval '1 day')::date
         else null end,
    -- What it would have been under the ordinary rule, so the screen
    -- can show the two together. For a company incorporated partway
    -- through a year the ordinary one has usually already passed, and
    -- seeing that is the point.
    (e.start_date - coalesce(r.filing_days_before, 0))::date,
    (e.first_period and e.commenced_on is not null
       and r.first_period_filing_months is not null),
    v_exempt,
    v_known,
    case when v_exempt
         then e.year_of_assessment + r.first_period_exempt_years - 1
         else null end,
    e.paid_up_capital,
    e.gross_business_income,
    rates.sme_capital_limit,
    rates.sme_turnover_limit;
end; $function$;

-- tax_filing_history: 1 membership check
CREATE OR REPLACE FUNCTION public.tax_filing_history(p_org_id uuid, p_limit integer DEFAULT 100)
 RETURNS TABLE(filing_id uuid, filing_type text, filing_name text, form_label text, period_from date, period_to date, year_of_assessment integer, due_date date, status text, filed_on date, reference text, notes text, was_late boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select f.id, f.filing_type, t.name, t.form_label,
         f.period_from, f.period_to, f.year_of_assessment,
         f.due_date, f.status, f.filed_on, f.reference, f.notes,
         -- Recorded as filed AFTER the date it was due. Worth its own
         -- column rather than left to the reader to subtract, because
         -- it is the thing a penalty is assessed on and the two dates
         -- sit in different columns of the same row.
         (f.status = 'filed' and f.filed_on is not null
            and f.due_date is not null and f.filed_on > f.due_date)
    from public.tax_filings f
    join public.tax_filing_types t on t.code = f.filing_type
   where f.org_id = p_org_id
   order by f.period_to desc, t.sort_order
   limit greatest(coalesce(p_limit, 100), 1);
end;
$function$;

-- tax_upcoming_filings: 1 membership check
CREATE OR REPLACE FUNCTION public.tax_upcoming_filings(p_org_id uuid, p_within_days integer DEFAULT 240)
 RETURNS TABLE(filing_type text, filing_name text, form_label text, statute_ref text, fiscal_year_id uuid, period_from date, period_to date, year_of_assessment integer, due_date date, efiling_due_date date, days_left integer, is_overdue boolean, needs_employees boolean, description text, computation_id uuid, estimate_id uuid, status text, filing_id uuid)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_today date := app.today();
  v_entity text;
  v_has_staff boolean;
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  select o.entity_type into v_entity
    from public.organizations o where o.id = p_org_id;

  -- An employer for this purpose is anybody who has ever had somebody
  -- on the payroll: a company that let its last employee go in March
  -- still files a Form E for that year.
  select exists (
    select 1 from public.employees e where e.org_id = p_org_id
  ) into v_has_staff;

  return query
  select t.code,
         t.name,
         t.form_label,
         t.statute_ref,
         fy.id,
         -- Form E and Form EA cover a calendar year whatever the
         -- company's year end is, so they are labelled with one. The
         -- date below is the same either way; this is not.
         case when t.basis = 'month_day_after_year'
              then make_date(extract(year from fy.end_date)::integer, 1, 1)
              else fy.start_date end,
         case when t.basis = 'month_day_after_year'
              then make_date(extract(year from fy.end_date)::integer, 12, 31)
              else fy.end_date end,
         extract(year from fy.end_date)::integer,
         d.due,
         case when t.efiling_grace_months is null
                   and t.efiling_grace_days is null then null
              else (d.due
                    + make_interval(months => coalesce(t.efiling_grace_months, 0))
                    + make_interval(days => coalesce(t.efiling_grace_days, 0)))::date
         end,
         (d.due - v_today)::integer,
         d.due < v_today,
         t.needs_employees,
         t.description,
         tc.id,
         te.id,
         -- Nothing recorded reads as nothing recorded rather than as
         -- null, so a screen can switch on one value.
         coalesce(tf.status, 'not_started'),
         tf.id
    from public.fiscal_years fy
    join public.tax_filing_types t
      on coalesce(v_entity, 'other') = any (t.applies_to)
     and (not t.needs_employees or v_has_staff)
    left join public.tax_computations tc
      on tc.fiscal_year_id = fy.id and tc.org_id = fy.org_id
    -- The estimate still in force: a revision is a NEW row in `0667`
    -- that names the one it replaces, so the current one is whichever
    -- nothing has revised.
    left join public.tax_estimates te
      on te.fiscal_year_id = fy.id and te.org_id = fy.org_id
     and not exists (select 1 from public.tax_estimates r
                      where r.revises_id = te.id)
    cross join lateral (
      select coalesce(
        -- A first basis period's CP204 is due three months from
        -- commencing operations. Only for the CP204 rows: a Form C is
        -- seven months after the period's close whether the company
        -- is new or not.
        case when t.code = 'cp204'
                  and te.first_period
                  and te.commenced_on is not null
             then (select (te.commenced_on
                           + make_interval(
                               months => ru.first_period_filing_months)
                           - interval '1 day')::date
                     from public.tax_estimate_rules ru
                    where ru.year_of_assessment =
                            extract(year from fy.end_date)::integer
                      and ru.form = te.form
                      and ru.first_period_filing_months is not null)
             else null end,
        app.tax_filing_due(
          t.basis, t.days_before, t.months_after, t.period_month,
          t.due_month, t.due_day, fy.start_date, fy.end_date)) as due
    ) d
    -- Keyed on the obligation rather than the year -- see `0669`'s
    -- header. Joined on the period this row is FOR, which for Form E
    -- is the calendar year computed above, so the expression is
    -- repeated rather than referenced: a select-list alias is not in
    -- scope in the from clause.
    left join public.tax_filings tf
      on tf.org_id = fy.org_id and tf.filing_type = t.code
     and tf.period_to = case when t.basis = 'month_day_after_year'
              then make_date(extract(year from fy.end_date)::integer, 12, 31)
              else fy.end_date end
   where fy.org_id = p_org_id
     and d.due is not null
     -- Dealt with, one way or the other. An obligation still in
     -- preparation STAYS: somebody opening a Form C has not filed it,
     -- and a list that cleared on the intention to do something would
     -- be worse than one that never cleared at all.
     and coalesce(tf.status, 'not_started') not in
           ('filed', 'not_applicable')
     -- A year either side of the window: an obligation that is already
     -- late is the one somebody most needs to see, and dropping it the
     -- day after it was due is exactly backwards.
     and d.due between v_today - 365
                   and v_today + greatest(coalesce(p_within_days, 240), 1)
   order by d.due, t.sort_order;
end;
$function$;

-- pending_tax_submissions: 1 membership check
CREATE OR REPLACE FUNCTION public.pending_tax_submissions(p_org_id uuid)
 RETURNS TABLE(submission_id uuid, contact_id uuid, contact_name text, submitted_at timestamp with time zone, submitted_by_name text, submitted_by_email text, applied_fields text[], conflicts jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select s.id, s.contact_id, c.name, s.submitted_at,
         s.submitted_by_name, s.submitted_by_email, s.applied_fields,
         coalesce((
           select jsonb_agg(jsonb_build_object(
                    'field', k.field, 'theirs', k.theirs, 'ours', k.ours)
                  order by k.field)
             from (
               select f.field,
                      nullif(btrim(coalesce(to_jsonb(s) ->> f.field, '')), '')
                        as theirs,
                      nullif(btrim(coalesce(to_jsonb(c) ->> f.field, '')), '')
                        as ours
                 from unnest(array[
                        'tin', 'id_type', 'id_value', 'sst_registration_no',
                        'email', 'phone', 'address_line1', 'address_line2',
                        'address_line3', 'postcode', 'city', 'state_code',
                        'country_code']) as f(field)) k
            where k.theirs is not null
              and k.ours is not null
              and k.theirs is distinct from k.ours), '[]'::jsonb)
    from public.tax_detail_submissions s
    join public.contacts c on c.id = s.contact_id
   where s.org_id = p_org_id
     and app.is_staff_member(p_org_id)
     and s.dismissed_at is null
     and s.superseded_at is null
     and exists (
       select 1
         from unnest(array[
                'tin', 'id_type', 'id_value', 'sst_registration_no',
                'email', 'phone', 'address_line1', 'address_line2',
                'address_line3', 'postcode', 'city', 'state_code',
                'country_code']) as f(field)
        where nullif(btrim(coalesce(to_jsonb(s) ->> f.field, '')), '')
              is not null
          and nullif(btrim(coalesce(to_jsonb(c) ->> f.field, '')), '')
              is not null
          and nullif(btrim(coalesce(to_jsonb(s) ->> f.field, '')), '')
              is distinct from
              nullif(btrim(coalesce(to_jsonb(c) ->> f.field, '')), ''))
   order by s.submitted_at desc;
$function$;

-- revenue_schedule_due: 1 membership check
CREATE OR REPLACE FUNCTION public.revenue_schedule_due(p_org_id uuid)
 RETURNS TABLE(period_end date, amount numeric, lines integer, documents integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select p.period_end,
         round(sum(p.amount), 2),
         count(*)::integer,
         count(distinct p.document_id)::integer
    from public.revenue_schedule_periods p
   where p.org_id = p_org_id
     and p.gl_entry_id is null
   group by p.period_end
  having round(sum(p.amount), 2) <> 0
   order by p.period_end;
end;
$function$;

-- transfer_outstanding: 1 membership check
CREATE OR REPLACE FUNCTION public.transfer_outstanding(p_source_id uuid, p_target_type text)
 RETURNS TABLE(line_id uuid, line_no integer, description text, quantity numeric, taken numeric, outstanding numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org uuid; v_type text; v_counter text; v_is_sales boolean;
begin
  select org_id, doc_type::text into v_org, v_type
    from public.sales_documents where id = p_source_id;
  v_is_sales := found;

  if not v_is_sales then
    select org_id, doc_type::text into v_org, v_type
      from public.purchase_documents where id = p_source_id;
    if not found then
      raise exception 'Document % not found', p_source_id using errcode = 'P0002';
    end if;
  end if;

  if not app.is_staff_member(v_org) then
    raise exception 'Not a member of organization %', v_org using errcode = '42501';
  end if;

  v_counter := app.transfer_counter(v_type, p_target_type);

  if v_is_sales then
    return query
      select l.id, l.line_no, l.description, l.quantity,
             case v_counter when 'quantity_invoiced' then l.quantity_invoiced
                            else l.quantity_fulfilled end,
             greatest(l.quantity - case v_counter
               when 'quantity_invoiced' then l.quantity_invoiced
               else l.quantity_fulfilled end, 0)
        from public.sales_document_lines l
       where l.document_id = p_source_id
       order by l.line_no;
  else
    return query
      select l.id, l.line_no, l.description, l.quantity,
             case v_counter when 'quantity_billed' then l.quantity_billed
                            else l.quantity_received end,
             greatest(l.quantity - case v_counter
               when 'quantity_billed' then l.quantity_billed
               else l.quantity_received end, 0)
        from public.purchase_document_lines l
       where l.document_id = p_source_id
       order by l.line_no;
  end if;
end;
$function$;

-- fx_revaluation_preview: 1 membership check
CREATE OR REPLACE FUNCTION public.fx_revaluation_preview(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(currency character, closing_rate numeric, documents integer, booked numeric, restated numeric, difference numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_base character(3);
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;
  v_base := app.base_currency(p_org_id);

  return query
  with open_items as (
    select d.currency, d.balance_amount as amount,
           coalesce(d.exchange_rate, 1) as rate
      from public.sales_documents d
     where d.org_id = p_org_id and d.currency <> v_base
       and d.balance_amount <> 0 and d.doc_date <= p_as_at
       and d.deleted_at is null and d.gl_entry_id is not null
       and d.status <> 'void'
    union all
    select d.currency, -d.balance_amount, coalesce(d.exchange_rate, 1)
      from public.purchase_documents d
     where d.org_id = p_org_id and d.currency <> v_base
       and d.balance_amount <> 0 and d.doc_date <= p_as_at
       and d.deleted_at is null and d.gl_entry_id is not null
       and d.status <> 'void'
  )
  select o.currency,
         app.exchange_rate_for(p_org_id, o.currency, p_as_at),
         count(*)::integer,
         round(sum(o.amount * o.rate), 2),
         round(sum(o.amount * app.exchange_rate_for(p_org_id, o.currency, p_as_at)), 2),
         round(sum(o.amount * app.exchange_rate_for(p_org_id, o.currency, p_as_at))
             - sum(o.amount * o.rate), 2)
    from open_items o
   group by o.currency
   order by o.currency;
end;
$function$;

-- duplicate_purchase_documents: 1 membership check
CREATE OR REPLACE FUNCTION public.duplicate_purchase_documents(p_contact_id uuid, p_doc_type text DEFAULT 'bill'::text, p_supplier_doc_no text DEFAULT NULL::text, p_doc_date date DEFAULT NULL::date, p_total_amount numeric DEFAULT NULL::numeric, p_exclude_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, doc_no text, doc_date date, supplier_doc_no text, total_amount numeric, currency text, status text, reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with me as (select c.* from public.contacts c where c.id = p_contact_id)
  select d.id, d.doc_no, d.doc_date, d.supplier_doc_no, d.total_amount,
         d.currency::text, d.status::text,
         case
           when app.supplier_doc_key(p_supplier_doc_no) is not null
            and app.supplier_doc_key(d.supplier_doc_no)
                = app.supplier_doc_key(p_supplier_doc_no)
           then 'same number'
           else 'same amount on the same day'
         end
    from public.purchase_documents d
   cross join me
   where d.org_id = me.org_id
     and app.is_staff_member(me.org_id)
     and d.deleted_at is null
     -- A void or a rejected document is withdrawn. Counting one would
     -- mean that entering a bill, voiding it and entering it again --
     -- the ordinary way a mistake is corrected -- produced a warning
     -- about the mistake somebody had just fixed.
     and d.status not in ('void', 'rejected')
     and d.doc_type::text = p_doc_type
     and (p_exclude_id is null or d.id <> p_exclude_id)
     and d.contact_id in (
       select c2.id from public.contacts c2
        where c2.org_id = me.org_id
          and (c2.id = me.id
               or (me.party_id is not null and c2.party_id = me.party_id)))
     and (
       (app.supplier_doc_key(p_supplier_doc_no) is not null
        and app.supplier_doc_key(d.supplier_doc_no)
            = app.supplier_doc_key(p_supplier_doc_no))
       or (p_doc_date is not null
           and p_total_amount is not null
           and p_total_amount <> 0
           and d.doc_date = p_doc_date
           and d.total_amount = p_total_amount)
     )
   order by d.doc_date desc, d.doc_no;
$function$;

-- payment_batch_lines: 2 membership checks
CREATE OR REPLACE FUNCTION public.payment_batch_lines(p_batch uuid)
 RETURNS TABLE(org_id uuid, org_name text, kind text, settlement_id uuid, settlement_no text, paid_on date, contact_name text, currency character, amount numeric, reference text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select r.org_id, o.name, 'receipt', r.id, r.receipt_no, r.receipt_date,
         c.name, r.currency, r.amount, r.reference
    from public.receipts r
    join public.organizations o on o.id = r.org_id
    left join public.contacts c on c.id = r.contact_id
   where r.batch_id = p_batch
     and app.is_staff_member(r.org_id)
  union all
  select p.org_id, o.name, 'payment', p.id, p.payment_no, p.payment_date,
         c.name, p.currency, p.amount, p.reference
    from public.purchase_payments p
    join public.organizations o on o.id = p.org_id
    left join public.contacts c on c.id = p.contact_id
   where p.batch_id = p_batch
     and app.is_staff_member(p.org_id)
   order by 2, 5;
$function$;

-- payment_methods_for: 1 membership check
CREATE OR REPLACE FUNCTION public.payment_methods_for(p_org_id uuid)
 RETURNS SETOF payment_methods
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select * from public.payment_methods
   where org_id = p_org_id and deleted_at is null
     and app.is_staff_member(p_org_id)
   order by sort_order, name;
$function$;

-- suggested_charge: 1 membership check
CREATE OR REPLACE FUNCTION public.suggested_charge(p_payment_method_id uuid, p_amount numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_m public.payment_methods;
begin
  select * into v_m from public.payment_methods
   where id = p_payment_method_id and deleted_at is null;
  if not found then
    raise exception 'Payment method % not found', p_payment_method_id
      using errcode = 'P0002';
  end if;
  if not app.is_staff_member(v_m.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  -- A negative amount is a refund, and a provider does not pay a fee
  -- back. Clamped rather than signed, so the suggestion is never a
  -- credit somebody accepts without noticing.
  return round(
    greatest(coalesce(p_amount, 0), 0) * v_m.charge_percent / 100
      + v_m.charge_fixed, 2);
end;
$function$;

-- intercompany_inbox: 1 membership check
CREATE OR REPLACE FUNCTION public.intercompany_inbox(p_org_id uuid)
 RETURNS TABLE(sales_document_id uuid, from_org_id uuid, from_org text, doc_no text, doc_date date, currency text, subtotal numeric, tax_amount numeric, total_amount numeric, supplier_contact_id uuid, bill_id uuid, already_billed boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select d.id, issuer.id, issuer.name, d.doc_no, d.doc_date,
         d.currency::text, d.subtotal, d.tax_amount, d.total_amount,
         -- The supplier in *this* company that stands for the issuer.
         -- Null means somebody has to create one before a bill can be
         -- raised, and the screen says so.
         (select s.id from public.contacts s
           where s.org_id = p_org_id
             and s.linked_org_id = issuer.id
             and s.contact_type in ('supplier', 'both')
           order by s.created_at limit 1),
         bill.id,
         bill.id is not null
    from public.sales_documents d
    join public.contacts c on c.id = d.contact_id
    join public.organizations issuer on issuer.id = d.org_id
    join public.organizations mine on mine.id = p_org_id
    left join public.purchase_documents bill
           on bill.source_sales_document_id = d.id
   where app.is_staff_member(p_org_id)
     -- Addressed to me by name. This, not group membership, is what
     -- makes one of another company's documents readable here.
     and c.linked_org_id = p_org_id
     and issuer.group_id is not null
     and issuer.group_id = mine.group_id
     and issuer.id <> p_org_id
     and d.doc_type = 'invoice'
     and d.status = 'posted'
   order by d.doc_date desc, d.doc_no desc;
$function$;

-- bulk_email_documents: 1 membership check
CREATE OR REPLACE FUNCTION public.bulk_email_documents(p_ids uuid[], p_template_code text DEFAULT 'document_new'::text)
 RETURNS TABLE(id uuid, doc_no text, sent boolean, problem text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_id  uuid;
  v_no  text;
  v_org uuid;
begin
  if p_ids is null or array_length(p_ids, 1) is null then
    return;
  end if;
  if array_length(p_ids, 1) > app.bulk_limit() then
    raise exception 'A batch is at most % documents at a time',
      app.bulk_limit() using errcode = '22023';
  end if;

  foreach v_id in array p_ids
  loop
    select d.doc_no, d.org_id into v_no, v_org
      from public.sales_documents d where d.id = v_id;

    if v_no is null or not app.is_staff_member(v_org) then
      id := v_id; doc_no := null; sent := false;
      problem := 'No such document';
      return next;
      continue;
    end if;

    begin
      perform public.email_document(v_id, null, p_template_code);
      id := v_id; doc_no := v_no; sent := true; problem := null;
    exception when others then
      -- The commonest one by far is a customer with no email address,
      -- and it is worth reading: a batch of forty that sends
      -- thirty-seven and names the three contacts to go and fix is a
      -- useful afternoon.
      id := v_id; doc_no := v_no; sent := false; problem := sqlerrm;
    end;
    return next;
  end loop;
end;
$function$;

-- bulk_post_documents: 1 membership check
CREATE OR REPLACE FUNCTION public.bulk_post_documents(p_ids uuid[])
 RETURNS TABLE(id uuid, doc_no text, posted boolean, problem text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_id  uuid;
  v_no  text;
  v_org uuid;
begin
  if p_ids is null or array_length(p_ids, 1) is null then
    return;
  end if;
  if array_length(p_ids, 1) > app.bulk_limit() then
    raise exception 'A batch is at most % documents at a time',
      app.bulk_limit() using errcode = '22023';
  end if;

  foreach v_id in array p_ids
  loop
    select d.doc_no, d.org_id into v_no, v_org
      from public.sales_documents d where d.id = v_id;

    -- Whose it is, before anything is attempted. `post_sales_document`
    -- would refuse a document in another company anyway -- this is here
    -- so the answer says so rather than saying whatever the posting
    -- function says about a document the caller cannot see.
    if v_no is null or not app.is_staff_member(v_org) then
      id := v_id; doc_no := null; posted := false;
      problem := 'No such document';
      return next;
      continue;
    end if;

    -- Its own block, which is its own savepoint: a document that will
    -- not post rolls back what it started and leaves the rest of the
    -- batch alone. Without this the eleventh failure throws away the
    -- ten that worked.
    begin
      perform public.post_sales_document(v_id);
      id := v_id; doc_no := v_no; posted := true; problem := null;
    exception when others then
      -- What the database actually said. A count of failures is not
      -- something anybody can act on.
      id := v_id; doc_no := v_no; posted := false; problem := sqlerrm;
    end;
    return next;
  end loop;
end;
$function$;

-- document_numbering: 1 membership check
CREATE OR REPLACE FUNCTION public.document_numbering(p_org_id uuid)
 RETURNS TABLE(doc_type text, label text, module text, prefix text, suffix text, padding integer, reset_policy text, next_value bigint, last_issued bigint, period_key text, sample text, is_default boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  with s as (
    select n.doc_type, n.label, n.module, n.ordinal,
           coalesce(q.prefix, app.default_doc_prefix(n.doc_type)) as prefix,
           coalesce(q.suffix, '') as suffix,
           coalesce(q.padding::integer, 5) as padding,
           coalesce(q.reset_policy, 'yearly') as reset_policy,
           q.id is null as is_default,
           -- The number the next draw returns: 1 when there is no row
           -- yet or the period has turned since the last draw, else the
           -- stored next number.
           case when q.id is null then 1::bigint
                when q.reset_policy <> 'never'
                 and q.period_key is distinct from
                     app.series_period_key(q.reset_policy) then 1::bigint
                else q.next_value end as effective_next
      from app.numbered_series() n
      left join public.number_sequences q
        on q.org_id = p_org_id and q.doc_type = n.doc_type
     where app.module_visible(p_org_id, n.module))
  select s.doc_type, s.label, s.module, s.prefix, s.suffix, s.padding,
         s.reset_policy, s.effective_next,
         case when s.effective_next > 1 then s.effective_next - 1 end,
         app.series_period_key(s.reset_policy),
         app.compose_document_number(
           s.prefix, app.series_period_key(s.reset_policy),
           s.effective_next, s.padding, s.suffix),
         s.is_default
    from s
   order by s.ordinal;
end; $function$;

-- item_price: 1 membership check
CREATE OR REPLACE FUNCTION public.item_price(p_item_id uuid, p_contact_id uuid DEFAULT NULL::uuid, p_quantity numeric DEFAULT 1)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org      uuid;
  v_base     numeric(18, 4);
  v_level    uuid;
  v_named    numeric(18, 4);
  v_percent  numeric(9, 4);
begin
  select org_id, unit_price into v_org, v_base
    from public.items where id = p_item_id;
  if v_org is null then
    raise exception 'Item % not found', p_item_id using errcode = 'P0002';
  end if;
  if not app.is_staff_member(v_org) then
    raise exception 'Not a member of organization %', v_org using errcode = '42501';
  end if;

  if p_contact_id is not null then
    select price_level_id into v_level
      from public.contacts where id = p_contact_id and org_id = v_org;
  end if;

  -- No level, or a contact from another organization: list price.
  if v_level is null then
    select id into v_level from public.price_levels
     where org_id = v_org and is_default and is_active limit 1;
  end if;
  if v_level is null then return v_base; end if;

  select p.unit_price into v_named
    from public.item_prices p
   where p.item_id = p_item_id and p.price_level_id = v_level
     and coalesce(p.min_quantity, 0) <= coalesce(p_quantity, 1)
   order by coalesce(p.min_quantity, 0) desc
   limit 1;

  if v_named is not null then return v_named; end if;

  select adjustment_percent into v_percent
    from public.price_levels where id = v_level;

  if coalesce(v_percent, 0) = 0 then return v_base; end if;
  return round(v_base * (1 + v_percent / 100.0), 4);
end;
$function$;

-- contact_records: 1 membership check
CREATE OR REPLACE FUNCTION public.contact_records(p_contact_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_src     public.contacts;
  v_have    public.contacts;
  v_party   uuid;
  v_records jsonb;
  v_options jsonb := '[]'::jsonb;
  r         app.contact_type;
begin
  select * into v_src
    from public.contacts
   where id = p_contact_id and deleted_at is null;
  if v_src.id is null then
    raise exception 'No such contact' using errcode = 'P0002';
  end if;
  if not app.is_staff_member(v_src.org_id) then
    raise exception 'Not a member of that company' using errcode = '42501';
  end if;

  v_party := coalesce(v_src.party_id, v_src.id);

  -- The other records of this company. Not this one: the screen is
  -- already looking at it.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'code', c.code, 'contact_type', c.contact_type)
           order by c.code), '[]'::jsonb)
    into v_records
    from public.contacts c
   where c.org_id = v_src.org_id
     and c.deleted_at is null
     and c.id <> v_src.id
     and c.party_id = v_party;

  -- Each coded role, with the record that already fills it, if any.
  -- The same arithmetic `create_contact_as` refuses on, so the menu
  -- cannot offer what the function will refuse.
  foreach r in array
    array['customer', 'supplier', 'prospect']::app.contact_type[]
  loop
    select c.* into v_have
      from public.contacts c
     where c.org_id = v_src.org_id
       and c.deleted_at is null
       and (c.id = v_src.id or c.party_id = v_party)
       and app.contact_carries(c.contact_type, r)
     order by c.code
     limit 1;

    v_options := v_options || jsonb_build_object(
      'as', r,
      'prefix', app.default_doc_prefix(app.contact_series(r)),
      'existing', case when v_have.id is null then null
                       else jsonb_build_object(
                              'id', v_have.id, 'code', v_have.code) end);
  end loop;

  return jsonb_build_object(
    'id', v_src.id,
    'code', v_src.code,
    'name', v_src.name,
    'contact_type', v_src.contact_type,
    'records', v_records,
    'options', v_options);
end $function$;

-- contact_duplicates: 1 membership check
CREATE OR REPLACE FUNCTION public.contact_duplicates(p_org_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of that company' using errcode = '42501';
  end if;

  with keyed as (
    -- One row per record per identifier it carries. A record with a
    -- registration number and a TIN is in two groups, and the same
    -- pair of records found by both is reported once, below.
    select c.id, c.code, c.name, c.contact_type, c.party_id,
           c.created_at, k.matched_on, k.value
      from public.contacts c
     cross join lateral (
       values
         ('registration_no', app.identifying_number(c.registration_no)),
         ('id', case when c.id_type is null then null
                     else c.id_type || ':'
                          || app.identifying_number(c.id_value) end),
         ('tin', app.identifying_number(c.tin))
     ) as k(matched_on, value)
     where c.org_id = p_org_id
       and c.deleted_at is null
       and k.value is not null
       -- `id_type || ':' || null` is null, so the ID row drops itself
       -- when there is no number; the others drop on the placeholder.
       and k.value not like '%:'
  ),
  grouped as (
    select matched_on, value,
           array_agg(id order by created_at, code) as ids,
           count(distinct coalesce(party_id, id)) as companies,
           min(created_at) as filed_first
      from keyed
     group by matched_on, value
    having count(*) > 1
  ),
  -- Not already one company: a group whose records all point at the
  -- same party has been decided about, and saying it again is noise.
  undecided as (
    select * from grouped where companies > 1
  ),
  -- The same set of records found by two identifiers is one group,
  -- reported under the stronger.
  once as (
    select distinct on (ids) *
      from undecided
     order by ids,
              case matched_on
                when 'registration_no' then 1
                when 'id' then 2
                else 3 end
  )
  select coalesce(jsonb_agg(s.g order by s.filed_first, s.value),
                  '[]'::jsonb)
    into v_rows
    from (
      select o.value, o.filed_first,
             jsonb_build_object(
               'matched_on', o.matched_on,
               'value', o.value,
               'records', (
                 select jsonb_agg(jsonb_build_object(
                          'id', c.id,
                          'code', c.code,
                          'name', c.name,
                          'contact_type', c.contact_type,
                          'party_id', c.party_id)
                        order by c.created_at, c.code)
                   from public.contacts c
                  where c.id = any (o.ids))) as g
        from once o
    ) s;

  return v_rows;
end $function$;

-- contact_lookalikes: 1 membership check
CREATE OR REPLACE FUNCTION public.contact_lookalikes(p_org_id uuid, p_contact_type app.contact_type, p_name text, p_registration_no text DEFAULT NULL::text, p_tin text DEFAULT NULL::text, p_id_type text DEFAULT NULL::text, p_id_value text DEFAULT NULL::text, p_exclude uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of that company' using errcode = '42501';
  end if;

  -- The records already in the role being typed come first: those are
  -- the ones Save would duplicate. Then the same company in another
  -- role, which Save will link to.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id,
           'code', c.code,
           'name', c.name,
           'contact_type', c.contact_type,
           'matched_on', m.matched_on,
           'same_role', app.contact_carries(c.contact_type, p_contact_type)
                     or app.contact_carries(p_contact_type, c.contact_type))
           order by
             (app.contact_carries(c.contact_type, p_contact_type)
              or app.contact_carries(p_contact_type, c.contact_type)) desc,
             case m.matched_on
               when 'registration_no' then 1
               when 'id' then 2
               when 'tin' then 3
               else 4 end,
             c.code), '[]'::jsonb)
    into v_rows
    from (
      select *
        from app.contact_matches(
               p_org_id, p_exclude, p_name,
               p_registration_no, p_tin, p_id_type, p_id_value)
       limit 5) m
    join public.contacts c on c.id = m.contact_id;

  return v_rows;
end $function$;

-- import_batch_summary: 1 membership check
CREATE OR REPLACE FUNCTION public.import_batch_summary(p_batch_id uuid)
 RETURNS TABLE(target_table text, rows_written bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org   uuid;
  v_table text;
  v_n     bigint;
begin
  select org_id into v_org from public.import_batches where id = p_batch_id;
  if v_org is null then
    raise exception 'No such import batch' using errcode = 'P0002';
  end if;
  if not app.is_staff_member(v_org) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  foreach v_table in array app.import_target_tables() loop
    execute format(
      'select count(*) from public.%I where import_batch_id = $1', v_table)
      into v_n using p_batch_id;
    if v_n > 0 then
      target_table := v_table;
      rows_written := v_n;
      return next;
    end if;
  end loop;
end;
$function$;

-- bank_feed_status: 1 membership check
CREATE OR REPLACE FUNCTION public.bank_feed_status(p_bank_account_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_org  uuid;
  v_feed public.bank_feeds;
  v_run  public.bank_feed_runs;
begin
  select org_id into v_org from public.bank_accounts
   where id = p_bank_account_id;
  if v_org is null or not app.is_staff_member(v_org) then
    return null;
  end if;

  select * into v_feed from public.bank_feeds
   where bank_account_id = p_bank_account_id;
  if not found then
    return null;
  end if;

  select * into v_run from public.bank_feed_runs
   where feed_id = v_feed.id order by started_at desc limit 1;

  return jsonb_build_object(
    'provider',       v_feed.provider,
    'status',         v_feed.status,
    -- Whether one is set, never what it is.
    'has_api_key',    v_feed.api_key is not null,
    'has_api_secret', v_feed.api_secret is not null,
    'account_ref',    v_feed.account_ref,
    'last_pulled_at', v_feed.last_pulled_at,
    'last_error',     v_feed.last_error,
    'last_run', case when v_run.id is null then null else jsonb_build_object(
      'started_at', v_run.started_at,
      'finished_at', v_run.finished_at,
      'ok', v_run.ok,
      'imported', v_run.imported,
      'skipped', v_run.skipped,
      'error', v_run.error) end);
end;
$function$;

-- layout_rows: 1 membership check
CREATE OR REPLACE FUNCTION public.layout_rows(p_layout_id uuid)
 RETURNS SETOF report_layout_rows
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select r.* from public.report_layout_rows r
    join public.report_layouts l on l.id = r.layout_id
   where r.layout_id = p_layout_id and l.deleted_at is null
     and app.is_staff_member(r.org_id)
   order by r.sort_order;
$function$;

-- report_layouts_for: 1 membership check
CREATE OR REPLACE FUNCTION public.report_layouts_for(p_org_id uuid, p_kind app.report_kind)
 RETURNS SETOF report_layouts
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select * from public.report_layouts
   where org_id = p_org_id and kind = p_kind and deleted_at is null
     and app.is_staff_member(p_org_id)
   order by is_active desc, name;
$function$;
