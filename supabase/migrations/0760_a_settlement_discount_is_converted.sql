-- =====================================================================
-- 0760 :: a settlement discount on a foreign document is converted
--
-- Answered on 8 October: "the document's rate".
--
-- `allocate_with_discount` (0385, restated in 0734) and
-- `allocate_payment_with_discount` (0386, restated in 0734) posted the
-- discount journal in the base currency at a rate of 1, using the
-- DOCUMENT-currency figure. On a ringgit document that is the same
-- number. On a foreign one it is not. Reproduced on both sides: a
-- USD1,000 invoice at 4.50, settled with USD980 cash and a USD20
-- discount, showed nothing owed -- and the receivable still held RM70
-- in the ledger, with RM20 of discount where RM90 was given. The payable
-- side the same, with the income understated.
--
-- Now the discount is converted at the invoice's or bill's own rate --
-- the rate the receivable or payable it settles was recorded at -- and
-- the journal carries the document's currency and rate, with the
-- document-currency figure as its foreign amount, so revaluation reads
-- it as part of the same balance. The allocation row is unchanged: its
-- `discount_amount` was always in the document's currency.
--
-- Production had no settlement discount taken, and no foreign document
-- on terms that offer one, when this was written.
--
-- Both restated whole from the live definitions; the changes are the
-- lines marked 0760. Grants survive a CREATE OR REPLACE, and 0734's
-- idempotent wrappers call these by name and are untouched.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.allocate_with_discount(p_receipt uuid, p_invoice uuid, p_amount numeric, p_discount numeric DEFAULT NULL::numeric, p_as_at date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_rcp      public.receipts;
  v_inv      public.sales_documents;
  v_offer    record;
  v_discount numeric(18, 2);
  -- 0760. The discount in the books' currency, at the invoice's rate.
  v_disc_base numeric(18, 2);
  v_ar       uuid;
  v_disc_ac  uuid;
  v_entry    uuid;
  v_alloc    uuid;
  v_as_at    date := coalesce(p_as_at,
                       (now() at time zone 'Asia/Kuala_Lumpur')::date);
begin
  select * into v_rcp from public.receipts where id = p_receipt;
  if v_rcp.id is null then
    raise exception 'No such receipt.' using errcode = 'P0002';
  end if;
  if not app.can_post(v_rcp.org_id) then
    raise exception 'not permitted to allocate a receipt'
      using errcode = '42501';
  end if;

  select * into v_inv from public.sales_documents where id = p_invoice;
  if v_inv.id is null or v_inv.org_id <> v_rcp.org_id then
    raise exception 'No such invoice.' using errcode = 'P0002';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'An allocation is of something.' using errcode = '23514';
  end if;

  select * into v_offer from app.settlement_discount_of(
    v_inv.payment_term_id, v_inv.doc_date,
    greatest(coalesce(v_inv.balance_amount, 0), 0));

  v_discount := round(coalesce(p_discount, 0), 2);
  if v_discount > 0 then
    if v_offer.deadline is null then
      raise exception
        '% is on terms that offer no settlement discount. Set one on the '
        'payment term, or raise a credit note if the reduction is '
        'something else.', v_inv.doc_no using errcode = '23514';
    end if;
    if v_offer.deadline < v_as_at then
      raise exception
        'The discount on % ran out on %. It is not a discount any more, '
        'and taking it now would clear an invoice the customer has not '
        'paid.', v_inv.doc_no, to_char(v_offer.deadline, 'DD Mon YYYY')
        using errcode = '23514';
    end if;
    if v_discount > v_offer.amount then
      raise exception
        'The terms on % allow % as a settlement discount, not %.',
        v_inv.doc_no,
        to_char(v_offer.amount, 'FM999G999G990D00'),
        to_char(v_discount, 'FM999G999G990D00') using errcode = '23514';
    end if;
    if round(p_amount + v_discount, 2)
       > round(coalesce(v_inv.balance_amount, 0), 2) then
      raise exception
        'The cash and the discount come to more than % still owes.',
        v_inv.doc_no using errcode = '23514';
    end if;
  end if;

  if v_discount > 0 then
    select coalesce(c.receivable_account_id,
                    (select id from public.accounts
                      where org_id = v_rcp.org_id and code = '1210'))
      into v_ar from public.contacts c where c.id = v_inv.contact_id;
    select id into v_disc_ac from public.accounts
     where org_id = v_rcp.org_id and code = '4300';
    if v_ar is null or v_disc_ac is null then
      raise exception
        'No receivable (1210) or sales discount (4300) account in the '
        'chart.' using errcode = 'P0002';
    end if;

    -- Dr Sales Returns and Discounts, Cr Receivable. A reduction of
    -- revenue, which is what a discount for early settlement is.
    --
    -- The tax is not touched. What was charged is what the invoice
    -- said and what LHDN was told; changing the taxable value takes a
    -- credit note, and quietly reducing the output tax here would
    -- understate what the company has already declared.
    --
    -- 0760. At the INVOICE's rate. The discount is a share of the
    -- invoice's own figure, in the invoice's currency, and it settles
    -- part of a receivable recorded at the invoice's rate -- so that is
    -- the rate that clears it. This posted the document-currency figure
    -- as ringgit at a rate of 1: USD20 off a USD invoice at 4.50 took
    -- RM20 off the receivable, and left RM70 owing in the ledger on an
    -- invoice that showed nothing owed.
    v_disc_base := round(v_discount * coalesce(v_inv.exchange_rate, 1), 2);
    v_entry := public.create_gl_entry(
      v_rcp.org_id, v_as_at, 'receipt'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_disc_ac,
          'description', 'Settlement discount on ' || v_inv.doc_no,
          'debit', v_disc_base, 'credit', 0,
          'fc_debit', v_discount, 'fc_credit', 0),
        jsonb_build_object('account_id', v_ar,
          'description', 'Settlement discount on ' || v_inv.doc_no,
          'debit', 0, 'credit', v_disc_base,
          'fc_debit', 0, 'fc_credit', v_discount,
          'contact_id', v_inv.contact_id)),
      'Settlement discount on ' || v_inv.doc_no,
      'sales_documents', v_inv.id, v_rcp.receipt_no,
      v_inv.currency, coalesce(v_inv.exchange_rate, 1));
  end if;

  insert into public.payment_allocations
    (org_id, receipt_id, invoice_id, amount, discount_amount,
     discount_entry_id, allocated_by)
  values (v_rcp.org_id, p_receipt, p_invoice, round(p_amount, 2),
          v_discount, v_entry, auth.uid())
  returning id into v_alloc;

  return v_alloc;
end $function$;

CREATE OR REPLACE FUNCTION public.allocate_payment_with_discount(p_payment uuid, p_bill uuid, p_amount numeric, p_discount numeric DEFAULT NULL::numeric, p_as_at date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_pay      public.purchase_payments;
  v_bill     public.purchase_documents;
  v_offer    record;
  v_discount numeric(18, 2);
  -- 0760. The discount in the books' currency, at the bill's rate.
  v_disc_base numeric(18, 2);
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
    --
    -- 0760. At the BILL's rate, for the reason `allocate_with_discount`
    -- gives: the discount settles part of a payable recorded at that
    -- rate. Unconverted, USD20 off a USD bill at 4.50 took RM20 off the
    -- payable and left RM70 owing on a bill that showed nothing owed.
    v_disc_base := round(v_discount * coalesce(v_bill.exchange_rate, 1), 2);
    v_entry := public.create_gl_entry(
      v_pay.org_id, v_as_at, 'payment'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_ap,
          'description', 'Settlement discount on ' || v_bill.doc_no,
          'debit', v_disc_base, 'credit', 0,
          'fc_debit', v_discount, 'fc_credit', 0,
          'contact_id', v_bill.contact_id),
        jsonb_build_object('account_id', v_inc_ac,
          'description', 'Settlement discount on ' || v_bill.doc_no,
          'debit', 0, 'credit', v_disc_base,
          'fc_debit', 0, 'fc_credit', v_discount)),
      'Settlement discount on ' || v_bill.doc_no,
      'purchase_documents', v_bill.id, v_pay.payment_no,
      v_bill.currency, coalesce(v_bill.exchange_rate, 1));
  end if;

  insert into public.payment_allocations
    (org_id, payment_id, bill_id, amount, discount_amount,
     discount_entry_id, allocated_by)
  values (v_pay.org_id, p_payment, p_bill, round(p_amount, 2),
          v_discount, v_entry, auth.uid())
  returning id into v_alloc;

  return v_alloc;
end $function$;
