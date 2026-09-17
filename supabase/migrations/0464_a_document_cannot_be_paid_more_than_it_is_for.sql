-- ---------------------------------------------------------------------
-- 0464  A document cannot be paid more than it is for
-- ---------------------------------------------------------------------
-- Found while writing `0462`, and measured on a built database before
-- anything was written here:
--
--   allocate_with_discount(receipt, invoice, 5000) against a RM1,000
--   invoice  ->  balance_amount -4000.00, status 'completed'
--
--   allocate_payment_with_discount(payment, bill, 900) against a RM400
--   bill      ->  balance_amount -500.00, status 'completed'
--
-- Neither is refused anywhere. `allocate_with_discount` compares the
-- cash against the balance **only when a discount is present** --
-- 0385's guard is about the discount, not the cash -- and
-- `app.apply_allocation` recomputes `balance_amount` without ever
-- objecting to a negative one. So the ordinary settlement dialog, which
-- is the path every user takes, will take a fat-fingered figure and put
-- the customer RM4,000 into credit on an invoice marked paid in full.
--
-- What that does to the books: the receipt credits the receivable by
-- the full RM5,000 while the invoice only ever debited RM1,000, so the
-- control account carries RM4,000 of credit that belongs to no
-- document. The trial balance still balances -- the bank took the money
-- -- which is exactly why nobody would notice. The ageing shows a
-- debtor in credit, and `0273` wrote a whole migration about that being
-- the wrong place to keep somebody's money.
--
-- ### Where the guard goes
--
-- In `app.apply_allocation`, the trigger, rather than in the two
-- allocation functions. Fourteen places in this schema insert into
-- `payment_allocations` -- receipts, supplier payments, credit notes,
-- contras, deposits, the till, the offline batch, three demo seeds --
-- and a rule that lives in two of them is a rule the other twelve do
-- not have. The trigger is the one thing every writer goes through.
--
-- Two things are refused, and they are different:
--
--   * more against a document than the document is for. The money is
--     real; what is wrong is where it has been put.
--   * more out of a receipt than the receipt is for. `unapplied_amount`
--     was already computed as `amount - sum(allocated)` and was already
--     free to go negative, which is a receipt spread further than the
--     money that arrived.
--
-- ### What to do with the extra instead
--
-- Nothing about this refuses an overpayment. A customer who sends too
-- much leaves the excess sitting as `unapplied_amount` on the receipt,
-- which is what that column has always been for, or it is recorded as a
-- deposit -- a liability, because it is still theirs -- through
-- `create_deposit` from `0273`. Both are one screen away. What is
-- refused is calling it settlement of an invoice that was never for
-- that much.
--
-- ### Deletes are not checked
--
-- The recomputation runs on delete too, and there it can only make the
-- figure smaller. Raising on a delete would mean a set of books that
-- had already been over-allocated -- by any build older than this one
-- -- could not be *un*-allocated, which is the one operation that fixes
-- it.
--
-- ### The dialog already clamps, which is the argument rather than the
-- ### answer
--
-- `settlement_dialog.dart` does `value.clamp(0, doc.balanceAmount)`, so
-- somebody typing into that one screen could not reach this. That is
-- worth knowing and is not a defence: a rule enforced in a Flutter
-- widget is enforced for the people using that widget. It says nothing
-- about the till, the offline batch that lands a day's sales, an
-- import, a group payment, a credit note, or anybody holding an API
-- key -- and it says nothing about the next screen somebody writes.
-- Fourteen writers, one clamp.
--
-- ### Mutants
--
-- Four, restated into a built database and run against
-- `supabase/tests/over_allocation.sql`. All four die.
--
--   * the invoice guard dropped -- killed by "an invoice cannot be paid
--     more than it is for";
--   * the bill guard dropped -- killed by "a bill cannot be paid more
--     than it is for";
--   * the receipt guard dropped -- killed by "a receipt cannot be
--     spread further than the money that arrived". A separate kill, and
--     not a duplicate of the first: the fixture spreads RM1,000 over
--     two RM800 invoices, so every allocation is within its own
--     document and only the money is short;
--   * `v_check` forced true, so the guard fires on deletes as well --
--     **this one needed a fixture that did not exist**. Every state the
--     rest of the file can reach is one the guard permits, so a delete
--     from it recomputes to something legal and the mutant survives.
--     The file now builds the illegal state the only way it still can,
--     with the trigger switched off: 2,400 against a 1,000 invoice,
--     three rows. Taking one off leaves 1,600, still too much, and has
--     to be allowed anyway -- otherwise books written by any build
--     before this one could never be unpicked. Mutant refuses the
--     delete; assertion goes red.
-- ---------------------------------------------------------------------

create or replace function app.apply_allocation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
declare
  v_invoice_id uuid := coalesce(new.invoice_id, old.invoice_id);
  v_bill_id    uuid := coalesce(new.bill_id, old.bill_id);
  v_receipt_id uuid := coalesce(new.receipt_id, old.receipt_id);
  v_payment_id uuid := coalesce(new.payment_id, old.payment_id);
  v_paid       numeric(18, 2);
  v_total      numeric(18, 2);
  v_no         text;
  v_left       numeric(18, 2);
  -- Deletes only ever reduce what is allocated, and a set of books that
  -- is already over-allocated has to be able to put itself right.
  v_check      boolean := tg_op <> 'DELETE';
begin
  if v_invoice_id is not null then
    select coalesce(sum(amount + discount_amount), 0) into v_paid
      from public.payment_allocations where invoice_id = v_invoice_id;

    if v_check then
      select d.doc_no, d.total_amount into v_no, v_total
        from public.sales_documents d where d.id = v_invoice_id;
      if round(v_paid, 2) > round(coalesce(v_total, 0), 2) then
        raise exception
          '% is for %, and % has been put against it. An invoice cannot '
          'be paid more than it is for — leave the difference unapplied '
          'on the receipt, or record it as a deposit.',
          v_no, to_char(v_total, 'FM999G999G990D00'),
          to_char(v_paid, 'FM999G999G990D00')
          using errcode = '23514';
      end if;
    end if;

    update public.sales_documents
       set paid_amount = v_paid,
           balance_amount = total_amount - v_paid,
           status = case
             when total_amount - v_paid <= 0 then 'completed'::app.doc_status
             when v_paid > 0                 then 'partial'::app.doc_status
             when status in ('completed', 'partial')
                                             then 'posted'::app.doc_status
             else status
           end
     where id = v_invoice_id;
  end if;

  if v_bill_id is not null then
    select coalesce(sum(amount + discount_amount), 0) into v_paid
      from public.payment_allocations where bill_id = v_bill_id;

    if v_check then
      select d.doc_no, d.total_amount into v_no, v_total
        from public.purchase_documents d where d.id = v_bill_id;
      if round(v_paid, 2) > round(coalesce(v_total, 0), 2) then
        raise exception
          '% is for %, and % has been put against it. A bill cannot be '
          'paid more than it is for — leave the difference unapplied on '
          'the payment, or record it as a deposit.',
          v_no, to_char(v_total, 'FM999G999G990D00'),
          to_char(v_paid, 'FM999G999G990D00')
          using errcode = '23514';
      end if;
    end if;

    update public.purchase_documents
       set paid_amount = v_paid,
           balance_amount = total_amount - v_paid,
           status = case
             when total_amount - v_paid <= 0 then 'completed'::app.doc_status
             when v_paid > 0                 then 'partial'::app.doc_status
             when status in ('completed', 'partial')
                                             then 'posted'::app.doc_status
             else status
           end
     where id = v_bill_id;
  end if;

  -- Track how much of the receipt/payment is still sitting unapplied.
  if v_receipt_id is not null then
    update public.receipts r
       set unapplied_amount = r.amount - (
             select coalesce(sum(a.amount), 0)
               from public.payment_allocations a where a.receipt_id = r.id)
     where r.id = v_receipt_id
    returning r.unapplied_amount, r.receipt_no into v_left, v_no;

    if v_check and round(coalesce(v_left, 0), 2) < 0 then
      raise exception
        'Receipt % has been spread further than the money that arrived: '
        '% more than it is for.', v_no,
        to_char(-v_left, 'FM999G999G990D00') using errcode = '23514';
    end if;
  end if;

  if v_payment_id is not null then
    update public.purchase_payments p
       set unapplied_amount = p.amount - (
             select coalesce(sum(a.amount), 0)
               from public.payment_allocations a where a.payment_id = p.id)
     where p.id = v_payment_id
    returning p.unapplied_amount, p.payment_no into v_left, v_no;

    if v_check and round(coalesce(v_left, 0), 2) < 0 then
      raise exception
        'Payment % has been spread further than the money that left: '
        '% more than it is for.', v_no,
        to_char(-v_left, 'FM999G999G990D00') using errcode = '23514';
    end if;
  end if;

  return coalesce(new, old);
end;
$function$;

comment on function app.apply_allocation() is
  'Recomputes what a document has been paid and what is left of a '
  'receipt, and refuses an allocation larger than either. In the '
  'trigger rather than in the allocation functions because fourteen '
  'places write payment_allocations. See 0464.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(to_regprocedure('app.apply_allocation()'));
begin
  -- The phrase, not the sentence: the message is built from two string
  -- literals and the sentence spans the join.
  if position('paid more than it is for' in v_src) = 0 then
    raise exception
      '0464: an invoice can still be paid more than it is for';
  end if;
  if position('spread further than the money that arrived' in v_src) = 0 then
    raise exception
      '0464: a receipt can still be allocated beyond what it holds';
  end if;
  -- Without this the guard makes an over-allocated set of books
  -- permanent: the delete that would undo it is refused too.
  if position('tg_op <> ''DELETE''' in v_src) = 0 then
    raise exception
      '0464: the guard fires on deletes, so nothing can be put right';
  end if;
end
$do$;
