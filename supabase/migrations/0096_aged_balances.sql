-- =====================================================================
-- iAkauntan :: 0096 aged receivables and payables
--
-- An aged listing is not a list of overdue invoices. It is a subledger
-- analysis that has to foot to the control account in the nominal at
-- the same date, or the two numbers get reconciled by hand every month
-- until somebody stops trusting both of them.
--
-- Three things follow from that, and they are the whole content of this
-- migration:
--
-- 1. **As at a date, not as of now.** `sales_documents.balance_amount`
--    is the balance today. Running "aged receivables as at 31 March" in
--    June off that column makes every invoice settled in April vanish,
--    and the report foots to nothing in particular. The balance here is
--    reconstructed: the document total, less the settlements that had
--    happened by the as-at date.
--
-- 2. **A settlement takes effect on the date its source document is
--    dated**, not on `allocated_at`. The receipt is what credits the
--    receivable, on `receipt_date`; matching it against an invoice
--    later is bookkeeping inside the subledger and moves no money. An
--    allocation therefore counts at the as-at date only when the
--    receipt (or credit note) *and* the invoice it settles are both
--    dated on or before it — an advance received in March against an
--    invoice raised in April is unapplied cash at 31 March, not a
--    settled invoice.
--
-- 3. **Everything sitting in the control account is listed**, including
--    the credits. Unallocated credit notes, refund notes and receipts
--    with cash still unapplied are all part of the receivable balance
--    and appear as negatives. Leave them out and the report is tidier
--    and wrong.
--
-- `supabase/tests/aged_balances.sql` asserts the footing against
-- `report_trial_balance` for both sides, which is the assertion that
-- makes the rest of this worth having.
--
-- Amounts come back twice: `outstanding` in the document's own currency
-- for the person chasing it, and `base_outstanding` at the document's
-- own exchange rate — the rate the ledger carries it at, which is what
-- makes the total foot. Retranslating open balances at a closing rate
-- is what `fx_revaluation` does, and it posts a journal when it does.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Receivables
-- ---------------------------------------------------------------------
create or replace function public.report_ar_aging(
  p_org_id uuid,
  p_as_at date default current_date)
returns table (
  contact_id uuid, contact_code text, contact_name text,
  doc_kind text, document_id uuid, doc_no text,
  doc_date date, due_date date, currency char(3),
  outstanding numeric, base_outstanding numeric,
  days_overdue integer, aging_bucket text)
language sql stable security definer set search_path = public, app, pg_temp as $$
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
     where a.org_id = p_org_id
       and coalesce(r.receipt_date, cn.doc_date) <= p_as_at
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
     and app.is_org_member(p_org_id)
   order by c.name, d.doc_date, d.doc_no;
$$;

-- ---------------------------------------------------------------------
-- Payables
--
-- The mirror image, with one asymmetry that is in the schema rather
-- than here: `payment_allocations.credit_note_id` points at
-- `sales_documents`, so a purchase credit note cannot be matched
-- against a bill. It still reduces the payable when it posts, so it is
-- listed on its own line rather than netted off the bill it relates to.
-- ---------------------------------------------------------------------
create or replace function public.report_ap_aging(
  p_org_id uuid,
  p_as_at date default current_date)
returns table (
  contact_id uuid, contact_code text, contact_name text,
  doc_kind text, document_id uuid, doc_no text,
  doc_date date, due_date date, currency char(3),
  outstanding numeric, base_outstanding numeric,
  days_overdue integer, aging_bucket text)
language sql stable security definer set search_path = public, app, pg_temp as $$
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
     where a.org_id = p_org_id
       and coalesce(p.payment_date, cn.doc_date) <= p_as_at
  ),
  documents as (
    -- The sign follows `post_purchase_document`: a bill and a purchase
    -- debit note both credit the payable, a purchase credit note debits
    -- it. Reporting a different sign here than the one the ledger used
    -- would be a report that disagrees with the account it summarises.
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
     and app.is_org_member(p_org_id)
   order by c.name, d.doc_date, d.doc_no;
$$;

-- ---------------------------------------------------------------------
-- The views these replace
--
-- `v_ar_aging` and `v_ap_aging` computed the same five buckets against
-- `current_date` and today's `balance_amount`. Two implementations of
-- one bucket rule is how a printed report comes to disagree with the
-- screen, and the view could not answer the question a month-end
-- listing is for. The dashboard now reads the function with no as-at
-- date, which is the same question the view was answering.
-- ---------------------------------------------------------------------
drop view if exists public.v_ar_aging;
drop view if exists public.v_ap_aging;

-- PostgreSQL grants EXECUTE on a new function to PUBLIC, which includes
-- `anon`. These read every customer balance in an organization.
revoke all on function public.report_ar_aging(uuid, date) from public, anon;
revoke all on function public.report_ap_aging(uuid, date) from public, anon;
grant execute on function public.report_ar_aging(uuid, date) to authenticated;
grant execute on function public.report_ap_aging(uuid, date) to authenticated;
