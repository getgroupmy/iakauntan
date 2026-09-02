-- ---------------------------------------------------------------------
-- 0456  Service tax is due when the money arrives
-- ---------------------------------------------------------------------
-- 0455 built the taxable period and the deadline, and computed what
-- goes on the return from `report_sst_summary` -- which sums tax by
-- **document date**. That is right for sales tax and wrong for service
-- tax, and the difference is not a rounding matter.
--
-- Service Tax Act 2018, section 11, with the Service Tax Regulations
-- 2018:
--
--   * Service tax is due **at the time payment is received** for the
--     taxable service.
--   * Where payment is not received within **twelve months from the
--     date of the invoice**, the tax on whatever is still outstanding
--     becomes due on the day following that twelve-month period.
--
-- Sales tax is the other way: due when the goods are sold, which is the
-- invoice. So a company registered for both has two bases in one
-- return, and 0455 gave it one.
--
-- ### What that was worth
--
-- A consultancy invoicing RM100,000 plus RM8,000 service tax on 20
-- August, on sixty-day terms, is declared by 0455 in the Jul-Aug return
-- and pays RM8,000 to the Customs Department at the end of September --
-- out of money the client has not sent. Under the Act it is due in the
-- period the payment lands. The error is not in the total over the life
-- of the company; it is in the timing, always in the same direction,
-- and it is the working capital of a business that has just been paid
-- late.
--
-- The twelve-month rule is the other half, and it is the half software
-- forgets: an invoice nobody ever pays still carries tax, and the
-- deadline for it arrives whether or not the money does.
--
-- ### What this changes
--
-- `app.sst_output_due(org, from, to)` replaces the summary as the
-- source for a return:
--
--   * **Sales tax and everything else**: on the document date, as
--     before.
--   * **Service tax on an invoice**: on each payment received in the
--     period, in the proportion the payment bears to the invoice --
--     RM54,000 against RM108,000 declares RM4,000 of the RM8,000.
--   * **Service tax still unpaid twelve months on**: the whole
--     remainder, in the period containing the day after that
--     anniversary, and never again -- payments after the anniversary
--     are not declared a second time.
--
-- **Credit notes stay on the document date**, including their service
-- tax. A credit note is not a payment received and never becomes one;
-- the adjustment belongs in the period it was issued, which is how
-- RMCD's own guide treats it, and treating it any other way would
-- leave a reduction that could never be claimed on an invoice that was
-- never paid.
--
-- ### The rounding, stated rather than hidden
--
-- The apportionment is carried unrounded and rounded once per period,
-- so a tax of RM8,000.00 settled in three instalments can differ from
-- the sum of its parts by a sen. Rounding each instalment instead would
-- move that error into every period rather than one, and rounding
-- nothing would put fractions of a sen on a return. A sen in one period
-- is the smallest of the three wrongs and the assertions say so
-- explicitly rather than passing on a tolerance nobody wrote down.
--
-- ### Mutants
--
-- Six, restated into a built database and run against
-- `supabase/tests/service_tax_on_payment.sql`. Six kills, each on a
-- different assertion, and every number below is what a company would
-- actually have declared:
--
--   * service tax back on the document basis as well as the payment
--     one -- killed by "an unpaid invoice owes no service tax yet",
--     which read 80 where nothing had been received. This is 0455's
--     state, doubled;
--   * the twelve-month rule dropped -- killed by "twelve months on,
--     the tax falls due anyway", 0 for 80. An invoice nobody ever pays
--     would carry tax that never falls due at all;
--   * payments after the anniversary declared a second time -- killed
--     by "a late payment is not taxed twice", 80 for 0;
--   * the catch-up ignoring what had already been paid -- killed by
--     "and the part that never was is due at twelve months", **800 for
--     400**: the whole invoice re-declared when only half of it was
--     outstanding;
--   * the day the payment was keyed in rather than the day it was
--     received -- killed by "the whole tax falls due when the money
--     arrives", which read 0 because every fixture allocation is keyed
--     in today and the period asked about is in the past. A live
--     company would see the tax land in the wrong period whenever
--     posting ran late over a period end, which is exactly when
--     posting runs late;
--   * no apportionment, so any payment declares the whole tax --
--     killed by "half the money declares half the tax", 800 for 400.
-- ---------------------------------------------------------------------

create or replace function app.sst_output_due(
  p_org_id uuid,
  p_from   date,
  p_to     date)
returns table (
  tax_type_code  text,
  basis          text,
  taxable_amount numeric,
  tax_amount     numeric)
language sql stable
set search_path = public, app, pg_temp
as $$
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
           l.line_subtotal as net, l.tax_amount as tax
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
           d.service_charge_amount, d.service_charge_tax
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
$$;

-- ---------------------------------------------------------------------
-- The return, restated to ask the right question
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
$$;

-- ---------------------------------------------------------------------
-- And the breakdown, so a return can be filled in from it
-- ---------------------------------------------------------------------
create or replace function public.sst_return_lines(
  p_org_id     uuid,
  p_period_end date)
returns table (
  tax_type_code  text,
  tax_type_name  text,
  basis          text,
  taxable_amount numeric,
  tax_amount     numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  v_p record;
begin
  if not app.is_org_member(p_org_id) then
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
$$;

revoke all on function public.sst_return_lines(uuid, date) from public;
grant execute on function public.sst_return_lines(uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_due text := pg_get_functiondef(
    to_regprocedure('app.sst_output_due(uuid, date, date)'));
  v_per text := pg_get_functiondef(
    to_regprocedure('public.sst_taxable_periods(uuid, date, date)'));
begin
  if position('app.sst_output_due' in v_per) = 0 then
    raise exception '0456: the return still declares service tax unpaid';
  end if;

  if position('interval ''12 months''' in v_due) = 0 then
    raise exception
      '0456: an invoice nobody pays carries tax that never falls due';
  end if;

  -- The line that keeps the two bases apart.
  if position('not (l.code = ''02'' and l.doc_type = ''invoice'')'
              in v_due) = 0 then
    raise exception '0456: service tax is declared on both bases at once';
  end if;

  if position('r.receipt_date' in v_due) = 0 then
    raise exception
      '0456: the tax falls due on the day somebody keyed the payment in';
  end if;
end
$do$;

comment on function app.sst_output_due(uuid, date, date) is
  'Output tax due in a taxable period, on the basis each type is due '
  'on: sales tax when the goods go, service tax when the money comes '
  'or twelve months after the invoice, whichever is first. See 0456.';
