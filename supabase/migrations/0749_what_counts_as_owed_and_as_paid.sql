-- =====================================================================
-- iAkauntan :: 0749 what counts as owed, and what counts as paid
--
-- Two questions put to the user on 6 October, and answered.
--
-- ---------------------------------------------------------------------
-- A debit note is chased like an invoice
--
-- `report_collections` read `report_ar_aging` and kept only
-- `doc_kind = 'invoice'`. A mutation sweep showed the filter mattered for
-- one kind of row and one only -- a debit note, the positive one; credit
-- notes, refund notes and receipts are negative and `> 0` already drops
-- them -- so a customer whose only debt was a debit note was never on the
-- worklist, and one who owed on both was shown the invoices alone.
-- Answer: "Chase debit notes."
--
-- ---------------------------------------------------------------------
-- A set-off, a deposit and a cheque are payment received
--
-- Service tax on an invoice falls due when the money arrives (`0456`),
-- and `app.sst_output_due` counted receipts only. A contra, a deposit
-- applied and a post-dated cheque each settle the invoice in the ledger
-- (`0747` taught the listings to see them) and none of them brought its
-- service tax due. Answer: "All three count" -- each on the day it
-- reached the ledger, the cheque on the day it was taken in.
--
-- The deliberate edge, written down: a post-dated cheque that later
-- bounces deletes its allocation, so a return filed after the bounce no
-- longer counts it -- but a return already FILED for the month it was
-- taken in did. That is the same thing that happens to a receipt that
-- is voided after its month is filed, and it is what an amended return
-- is for.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.report_collections(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(contact_id uuid, contact_code text, contact_name text, outstanding numeric, oldest_days integer, invoices integer, last_attempt_on date, last_outcome app.collection_outcome, last_notes text, promise_date date, promise_amount numeric, promise_broken boolean, assigned_to uuid, assigned_name text, never_chased boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;
  if not (app.can_read_ledger(p_org_id) or app.can_write(p_org_id)) then
    raise exception 'You may not read the sales ledger'
      using errcode = '42501';
  end if;

  return query
  with owed as (
    select a.contact_id, a.contact_code, a.contact_name,
           sum(a.base_outstanding) as outstanding,
           max(a.days_overdue) as oldest_days,
           count(*)::integer as invoices
      from public.report_ar_aging(p_org_id, p_as_at) a
     -- 0749. A debit note is how an extra charge is billed, and it is
     -- owed like an invoice. Until 0749 the worklist read invoices only,
     -- and a customer whose only debt was a debit note was never on it.
     where a.doc_kind in ('invoice', 'debit_note')
       and a.base_outstanding > 0
     group by 1, 2, 3
  ),
  latest as (
    -- The most recent attempt per customer. `distinct on` rather than a
    -- window function because only one row per customer is wanted and
    -- this is the shape Postgres can answer straight off the index.
    select distinct on (c.contact_id)
           c.contact_id, c.attempted_on, c.outcome, c.notes, c.assigned_to
      from public.collection_attempts c
     where c.org_id = p_org_id and c.attempted_on <= p_as_at
     order by c.contact_id, c.attempted_on desc, c.created_at desc
  ),
  promised as (
    -- The live promise: the furthest-out date anybody has given that has
    -- not yet been superseded by a later attempt. Taking the *latest*
    -- promise rather than the earliest is deliberate — a customer who
    -- rang back to move Friday to the following Tuesday has one promise,
    -- for Tuesday, and chasing them on Friday is chasing a promise they
    -- already renegotiated.
    select distinct on (c.contact_id)
           c.contact_id, c.promise_date, c.promise_amount
      from public.collection_attempts c
     where c.org_id = p_org_id
       and c.promise_date is not null
       and c.attempted_on <= p_as_at
     order by c.contact_id, c.attempted_on desc, c.created_at desc
  )
  select o.contact_id, o.contact_code, o.contact_name,
         o.outstanding, o.oldest_days, o.invoices,
         l.attempted_on, l.outcome, l.notes,
         p.promise_date, p.promise_amount,
         -- Broken: the day came and went and they still owe something.
         -- This row only exists because they owe something, so the
         -- second half of that is already true.
         (p.promise_date is not null and p.promise_date < p_as_at),
         l.assigned_to,
         (select coalesce(pr.full_name, pr.email)
            from public.profiles pr where pr.id = l.assigned_to),
         (l.contact_id is null)
    from owed o
    left join latest l on l.contact_id = o.contact_id
    left join promised p on p.contact_id = o.contact_id
   order by
     -- Broken promises first, then never chased, then oldest debt. A
     -- worklist that opens on the thing most likely to be lost.
     (p.promise_date is not null and p.promise_date < p_as_at) desc,
     (l.contact_id is null) desc,
     o.oldest_days desc;
end $function$;

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
    union all
    -- 0749. Payment received by other means, on the day each reached the
    -- ledger -- the same days `0747` taught the aged listings: a contra
    -- on its own date, a deposit on the day it was applied, a
    -- post-dated cheque on the day it was taken in. A void contra and a
    -- bounced or cancelled cheque delete their allocations, so what is
    -- left here is what still stands.
    select s.doc_id,
           coalesce(k.contra_date,
                    case when n.id is not null then a.applied_on end,
                    q.received_on),
           a.amount
      from service s
      join public.payment_allocations a on a.invoice_id = s.doc_id
      left join public.contra_notes k on k.id = a.contra_id
       and k.gl_entry_id is not null and k.status <> 'void'
      left join public.deposit_notes n on n.id = a.deposit_id
       and n.gl_entry_id is not null and n.status <> 'void'
      left join public.post_dated_cheques q on q.id = a.pdc_id
       and q.gl_entry_id is not null
       and q.status in ('held', 'deposited', 'cleared')
     where a.org_id = p_org_id
       and a.receipt_id is null
       and (k.id is not null or n.id is not null or q.id is not null)
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
