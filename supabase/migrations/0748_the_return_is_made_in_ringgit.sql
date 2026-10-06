-- =====================================================================
-- iAkauntan :: 0748 the return is made in ringgit
--
-- `report_sst_summary` and `app.sst_output_due` -- which between them
-- feed `sst_taxable_periods` and `sst_return_lines`, i.e. the SST-02 --
-- added up `line_subtotal` and `tax_amount` as they stood on the
-- document. On a foreign-currency document those are in the foreign
-- currency, and nothing multiplied them by the rate. Measured on 6
-- October: a USD 1,000.00 invoice at 4.20 with 10% sales tax put
-- RM420.00 into 2130 and 100.00 on the return -- the dollar figure read
-- as ringgit, a return short by more than three-quarters.
--
-- `post_sales_document` has always converted (`round(tax_amount *
-- v_rate, 2)`), so the ledger was right and only the return was wrong.
-- Both functions now convert every amount they sum. The Flutter side
-- passes the figures through and needs nothing.
--
-- What is NOT changed: which payments count as bringing service tax due
-- in `app.sst_output_due` is still receipts only. Whether a contra, an
-- applied deposit or a post-dated cheque is "payment received" for the
-- Service Tax Act is a question for the person filing, not a rounding
-- error, and it is written down in `docs/handoff.md` rather than
-- decided here.
-- =====================================================================

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
   where app.is_org_member(p_org_id)
   group by o.code, o.descr
  union all
  select p.code, p.descr, 'input'::text,
         round(sum(p.sign * p.line_subtotal), 2),
         round(sum(p.sign * p.tax_amount), 2)
    from purchases p
   where app.is_org_member(p_org_id)
   group by p.code, p.descr;
$function$;

CREATE OR REPLACE FUNCTION app.sst_output_due(p_org_id uuid, p_from date, p_to date)
 RETURNS TABLE(tax_type_code text, basis text, taxable_amount numeric, tax_amount numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with lines as (
    -- Every taxed line and every taxed service charge on a sales
    -- document that counts, with the tax type it carries. The service
    -- charge is read from the header because that is where it is: the
    -- charge is not a line on the bill, it is a percentage of all of
    -- them. See 0418.
    select d.id as doc_id, d.doc_type, d.doc_date, d.total_amount,
           t.tax_type_code as code,
           case when d.doc_type in ('credit_note', 'refund_note')
                then -1 else 1 end as sign,
           -- 0748. In ringgit. `total_amount` stays in the document's
           -- own money: it is only ever divided into a payment, which
           -- is in that money too, to say what share of the tax a
           -- payment brought due.
           round(l.line_subtotal * coalesce(d.exchange_rate, 1), 2) as net,
           round(l.tax_amount * coalesce(d.exchange_rate, 1), 2) as tax
      from public.sales_document_lines l
      join public.sales_documents d on d.id = l.document_id
      join public.tax_codes t on t.id = l.tax_code_id
     where d.org_id = p_org_id
       and d.doc_type in ('invoice', 'credit_note', 'debit_note',
                          'refund_note')
       and d.status not in ('draft', 'void')
    union all
    select d.id, d.doc_type, d.doc_date, d.total_amount,
           t.tax_type_code,
           case when d.doc_type in ('credit_note', 'refund_note')
                then -1 else 1 end,
           round(d.service_charge_amount * coalesce(d.exchange_rate, 1), 2),
           round(d.service_charge_tax * coalesce(d.exchange_rate, 1), 2)
      from public.sales_documents d
      join public.tax_codes t on t.id = d.service_charge_tax_code_id
     where d.org_id = p_org_id
       and d.doc_type in ('invoice', 'credit_note', 'debit_note',
                          'refund_note')
       and d.status not in ('draft', 'void')
       and coalesce(d.service_charge_amount, 0) <> 0
  ),
  -- Everything that is not service tax on an invoice: the document
  -- date decides, which is section 11 of the Sales Tax Act and, for a
  -- credit note, the period the adjustment belongs to.
  on_the_document as (
    select l.code, 'invoice'::text as basis,
           sum(l.sign * l.net) as net, sum(l.sign * l.tax) as tax
      from lines l
     where not (l.code = '02' and l.doc_type = 'invoice')
       and l.doc_date between p_from and p_to
     group by l.code
  ),
  -- Service tax on an invoice, gathered per document so the
  -- apportionment has a denominator.
  service as (
    select l.doc_id, l.doc_date, max(l.total_amount) as total,
           sum(l.net) as net, sum(l.tax) as tax
      from lines l
     where l.code = '02' and l.doc_type = 'invoice'
     group by l.doc_id, l.doc_date
    having sum(l.tax) <> 0 and max(l.total_amount) > 0
  ),
  -- Money actually received against them, on the day it was received
  -- rather than the day somebody keyed it in.
  paid as (
    select s.doc_id, r.receipt_date as paid_on, a.amount
      from service s
      join public.payment_allocations a on a.invoice_id = s.doc_id
      join public.receipts r on r.id = a.receipt_id
     where a.org_id = p_org_id
       and r.status not in ('draft', 'void')
  ),
  -- The day after the twelve-month anniversary: what is still owing
  -- then falls due whether the money comes or not.
  anniversary as (
    select s.doc_id, s.doc_date, s.total, s.net, s.tax,
           (s.doc_date + interval '12 months' + interval '1 day')::date
             as falls_due,
           coalesce((select sum(p.amount) from paid p
                      where p.doc_id = s.doc_id
                        and p.paid_on
                            <= (s.doc_date + interval '12 months')::date),
                    0) as paid_by_then
      from service s
  ),
  -- Payments inside the period, and only those made before the
  -- anniversary -- after it the tax has already been declared.
  on_payment as (
    select '02'::text as code, 'payment'::text as basis,
           sum(s.net * p.amount / s.total) as net,
           sum(s.tax * p.amount / s.total) as tax
      from paid p
      join service s on s.doc_id = p.doc_id
      join anniversary an on an.doc_id = p.doc_id
     where p.paid_on between p_from and p_to
       and p.paid_on < an.falls_due
  ),
  -- And the remainder of anything that reached the anniversary in this
  -- period without being paid for.
  on_the_clock as (
    select '02'::text as code, 'twelve months'::text as basis,
           sum(an.net * (an.total - an.paid_by_then) / an.total) as net,
           sum(an.tax * (an.total - an.paid_by_then) / an.total) as tax
      from anniversary an
     where an.falls_due between p_from and p_to
       and an.total > an.paid_by_then
  )
  select x.code, x.basis, round(x.net, 2), round(x.tax, 2)
    from (select * from on_the_document
          union all select * from on_payment
          union all select * from on_the_clock) x
   where x.tax is not null
     and (x.net <> 0 or x.tax <> 0);
$function$;
