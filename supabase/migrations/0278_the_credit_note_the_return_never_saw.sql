-- =====================================================================
-- iAkauntan :: 0278 the credit note the return never saw
--
-- report_sst_summary is what the SST-02 is filled in from, and since
-- 0014 it has counted invoices and debit notes and nothing else:
--
--   d.doc_type in ('invoice', 'debit_note')
--   d.doc_type in ('bill', 'purchase_debit_note')
--
-- The ledger has never agreed with it. app.post_sales_document posts
-- credit and refund notes with v_sign = -1, and
-- app.post_purchase_document does the same for a purchase credit note,
-- so the SST output and input tax accounts net correctly. The return
-- does not: issue a credit note and the report still shows the full
-- invoice, because the credit note is not one of the two types it
-- looks at.
--
-- On the output side that overstates the tax due and the company pays
-- Customs money it does not owe. On the input side it overstates the
-- tax claimed, which is the same error pointing at the taxpayer.
--
-- The fix is not a new rule. It is the rule the ledger already uses:
-- the same document types that post, with the same signs, so the
-- return and the accounts cannot disagree. A wholly credited invoice
-- now nets to zero and still shows its line, because a period in which
-- something was sold and then credited is not a period in which
-- nothing happened.
-- =====================================================================

create or replace function public.report_sst_summary(
  p_org_id uuid, p_from date, p_to date)
returns table (
  tax_type_code text, tax_type_name text, direction text,
  taxable_amount numeric, tax_amount numeric)
language sql stable security definer set search_path = public, app, pg_temp as $$
  with sales as (
    select t.tax_type_code as code, rt.description as descr,
           -- The signs app.post_sales_document uses, and for the same
           -- reason: a credit note undoes a sale.
           case when d.doc_type in ('credit_note', 'refund_note')
                then -1 else 1 end as sign,
           l.line_subtotal, l.tax_amount
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
  purchases as (
    select t.tax_type_code as code, rt.description as descr,
           case when d.doc_type = 'purchase_credit_note'
                then -1 else 1 end as sign,
           l.line_subtotal, l.tax_amount
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
  select s.code, s.descr, 'output'::text,
         round(sum(s.sign * s.line_subtotal), 2),
         round(sum(s.sign * s.tax_amount), 2)
    from sales s
   where app.is_org_member(p_org_id)
   group by s.code, s.descr
  union all
  select p.code, p.descr, 'input'::text,
         round(sum(p.sign * p.line_subtotal), 2),
         round(sum(p.sign * p.tax_amount), 2)
    from purchases p
   where app.is_org_member(p_org_id)
   group by p.code, p.descr;
$$;

-- 0165's event trigger strips PUBLIC and anon from a newly created
-- function, so the grant has to be written back after every re-create.
grant execute on function public.report_sst_summary(uuid, date, date)
  to authenticated;
