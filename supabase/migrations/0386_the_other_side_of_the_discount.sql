-- =====================================================================
-- iAkauntan :: 0386 the other side of the discount
--
-- `0385` describes both sides of a settlement discount in its own
-- header — Dr 4300 Cr Receivable on a sale, Dr Payable Cr Other Income
-- on a purchase — and built only the first. A migration whose prose
-- claims something it did not do is a worse artefact than one that
-- claims less, because the next person reads the prose.
--
-- So: the purchase side, and the caller.
--
-- ---------------------------------------------------------------------
-- The same falsehood, the other way round
--
-- `app.apply_allocation` clears a bill by `amount + discount_amount`
-- exactly as it clears an invoice, and `app.post_payment_internal`
-- debits the payable by the cash alone. A discount taken from a
-- supplier would settle the bill and leave the **payable control
-- account understated** by it — the company's books showing less owed
-- than the creditors ledger, which is the same disagreement in the
-- direction that flatters the balance sheet.
--
-- ---------------------------------------------------------------------
-- Where it goes
--
-- Dr Payable, Cr Other Income (4900). Money the company agreed to pay
-- and did not have to.
--
-- It is income rather than a reduction of the cost, and that is a
-- choice worth stating. A discount for early settlement is a financing
-- benefit — it is earned by paying sooner, not by buying more cheaply —
-- and putting it against Purchases would move it into cost of sales,
-- change the gross margin, and, for anything already sold, restate a
-- cost the stock valuation has been built on. Other income leaves the
-- trading account alone.
--
-- The input tax is untouched for the reason its opposite number is
-- untouched in `0385`: the tax on the bill is what the supplier
-- charged and what the company claims, and changing it takes a credit
-- note from them.
--
-- ---------------------------------------------------------------------
-- And the caller
--
-- `recordSettlement` in the client wrote its allocations straight into
-- `payment_allocations` and then posted. That path can never carry a
-- discount now — `0385`'s guard refuses one with no journal — so the
-- dialog routes every allocation, discounted or not, through these two
-- functions instead. One path, and the discount cannot be written by a
-- route that forgets to post it.
-- =====================================================================

create or replace function public.allocate_payment_with_discount(
  p_payment   uuid,
  p_bill      uuid,
  p_amount    numeric,
  p_discount  numeric default null,
  p_as_at     date default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_pay      public.purchase_payments;
  v_bill     public.purchase_documents;
  v_offer    record;
  v_discount numeric(18, 2);
  v_ap       uuid;
  v_inc_ac   uuid;
  v_entry    uuid;
  v_alloc    uuid;
  v_as_at    date := coalesce(p_as_at,
                       (now() at time zone 'Asia/Kuala_Lumpur')::date);
begin
  select * into v_pay from public.purchase_payments where id = p_payment;
  if v_pay.id is null then
    raise exception 'No such payment.' using errcode = 'P0002';
  end if;
  if not app.can_post(v_pay.org_id) then
    raise exception 'not permitted to allocate a payment'
      using errcode = '42501';
  end if;

  select * into v_bill from public.purchase_documents where id = p_bill;
  if v_bill.id is null or v_bill.org_id <> v_pay.org_id then
    raise exception 'No such bill.' using errcode = 'P0002';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'An allocation is of something.' using errcode = '23514';
  end if;

  select * into v_offer from app.settlement_discount_of(
    v_bill.payment_term_id, v_bill.doc_date,
    greatest(coalesce(v_bill.balance_amount, 0), 0));

  v_discount := round(coalesce(p_discount, 0), 2);
  if v_discount > 0 then
    if v_offer.deadline is null then
      raise exception
        '% is on terms that offer no settlement discount. Ask the '
        'supplier for a credit note if the reduction is something else.',
        v_bill.doc_no using errcode = '23514';
    end if;
    if v_offer.deadline < v_as_at then
      raise exception
        'The discount on % ran out on %. Taking it now would clear a '
        'bill the company has not paid.',
        v_bill.doc_no, to_char(v_offer.deadline, 'DD Mon YYYY')
        using errcode = '23514';
    end if;
    if v_discount > v_offer.amount then
      raise exception
        'The terms on % allow % as a settlement discount, not %.',
        v_bill.doc_no,
        to_char(v_offer.amount, 'FM999G999G990D00'),
        to_char(v_discount, 'FM999G999G990D00') using errcode = '23514';
    end if;
    if round(p_amount + v_discount, 2)
       > round(coalesce(v_bill.balance_amount, 0), 2) then
      raise exception
        'The cash and the discount come to more than is owed on %.',
        v_bill.doc_no using errcode = '23514';
    end if;

    select coalesce(c.payable_account_id,
                    (select id from public.accounts
                      where org_id = v_pay.org_id and code = '2110'))
      into v_ap from public.contacts c where c.id = v_bill.contact_id;
    select id into v_inc_ac from public.accounts
     where org_id = v_pay.org_id and code = '4900';
    if v_ap is null or v_inc_ac is null then
      raise exception
        'No payable (2110) or other income (4900) account in the chart.'
        using errcode = 'P0002';
    end if;

    -- Dr Payable, Cr Other Income. Income rather than a reduction of
    -- cost: it is earned by paying sooner, not by buying more cheaply,
    -- and putting it against Purchases would move it into cost of
    -- sales and restate a cost the stock valuation is built on.
    --
    -- The input tax is untouched. What the supplier charged is what the
    -- company claims, and changing it takes a credit note from them.
    v_entry := public.create_gl_entry(
      v_pay.org_id, v_as_at, 'payment'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_ap,
          'description', 'Settlement discount on ' || v_bill.doc_no,
          'debit', v_discount, 'credit', 0,
          'contact_id', v_bill.contact_id),
        jsonb_build_object('account_id', v_inc_ac,
          'description', 'Settlement discount on ' || v_bill.doc_no,
          'debit', 0, 'credit', v_discount)),
      'Settlement discount on ' || v_bill.doc_no,
      'purchase_documents', v_bill.id, v_pay.payment_no,
      app.base_currency(v_pay.org_id), 1);
  end if;

  insert into public.payment_allocations
    (org_id, payment_id, bill_id, amount, discount_amount,
     discount_entry_id, allocated_by)
  values (v_pay.org_id, p_payment, p_bill, round(p_amount, 2),
          v_discount, v_entry, auth.uid())
  returning id into v_alloc;

  return v_alloc;
end $$;

-- ---------------------------------------------------------------------
revoke all on function public.allocate_payment_with_discount(
  uuid, uuid, numeric, numeric, date) from public, anon;
grant execute on function public.allocate_payment_with_discount(
  uuid, uuid, numeric, numeric, date) to authenticated;

comment on function public.allocate_payment_with_discount(
  uuid, uuid, numeric, numeric, date) is
  'The purchase side of `0385`. `app.apply_allocation` clears a bill by '
  'cash plus discount and the payment posting debits the payable by the '
  'cash alone, so a supplier discount would leave the payable '
  'understated — the same disagreement as on the sales side, in the '
  'direction that flatters the balance sheet.';
