-- =====================================================================
-- iAkauntan :: 0629 the credit note nobody could knock off
--
-- `payment_allocations.credit_note_id` has existed since `0005`.
-- `0272`, `0273` and `0275` each restated the check constraint that
-- names it. `0096`'s aged listing works out how much of a credit note
-- has been used. `app.apply_allocation` looks the credit note up to
-- check whose money it is.
--
-- **Nothing has ever written the column.** Four hundred migrations of
-- infrastructure around a door that does not open. A customer holding a
-- credit note has an invoice showing fully outstanding and a credit
-- sitting beside it, and no way in the product to put one against the
-- other -- which is the single most common thing an accounts clerk does
-- at month end.
--
-- ---------------------------------------------------------------------
-- No journal, and that is the point
--
-- `app.post_sales_document` posts a credit note with `v_sign = -1`, so
-- the receivable was credited on the day it was raised. Allocating it
-- moves nothing in the ledger; it records WHICH invoice the credit is
-- against. The same shape as `apply_on_account` for money already
-- banked, and for the same reason -- which is why this migration can be
-- written at all without touching anything that posts.
--
-- ---------------------------------------------------------------------
-- One number, in one place
--
-- Today `balance_amount` on a credit note is its full value for ever,
-- and `0096` compensates in the report:
--
--   "A credit note keeps its own full total in `balance_amount` however
--    much of it has been used, so what is left has to be worked out
--    here."
--
-- That was the right call when nothing could use one. It stops being
-- right the moment something can, because the compensation lives in
-- exactly one of the three places that read the number: the aged
-- listing works it out, the open-item statement PDF
-- (`Repo.outstandingFor`) does not, and a knock-off screen would be a
-- fourth. A company would then be told three different figures for the
-- same credit note, and the one that goes to the CUSTOMER is the wrong
-- one.
--
-- So `balance_amount` becomes what it says on every other document:
-- what is left, maintained by `app.apply_allocation` exactly as a
-- receipt's unapplied amount is.
--
-- `0096` is then deliberately NOT touched, and the reason is worth
-- writing down because the first draft of this migration did touch it.
-- Its arm computes `total_amount - sum(allocations)`, which is the
-- same arithmetic `apply_allocation` now performs -- so the report goes
-- on giving the right answer by working it out, the statement PDF gives
-- the same answer by reading it, and the two agree. Restating a report
-- to read a column instead of recomputing it is tidiness, and tidiness
-- is not worth a migration that rewrites the aged listing. A test
-- asserts the two agree to the sen after an allocation, which is the
-- thing that would actually break.
--
-- ---------------------------------------------------------------------
-- The guard that has to exist before the door opens
--
-- Without it, a credit note for 500 could be spread over 5,000 of
-- invoices and wipe out receivables that were never credited. Every
-- other source on this table is guarded -- a receipt cannot be spread
-- further than the money that arrived, a payment likewise -- and the
-- credit note had no guard because it had no writer. It gets one here,
-- in the trigger rather than in the function, because a guard in a
-- function holds only for callers that go through the function.
-- =====================================================================

-- ---------------------------------------------------------------------
-- How much of a credit note is still unspent
-- ---------------------------------------------------------------------
create or replace function app.credit_note_used(p_document_id uuid)
returns numeric
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(sum(a.amount), 0)::numeric(18, 2)
    from public.payment_allocations a
   where a.credit_note_id = p_document_id;
$$;

comment on function app.credit_note_used(uuid) is
  'How much of a credit note has been put against invoices. See 0629.';

revoke all on function app.credit_note_used(uuid) from public, anon;
grant execute on function app.credit_note_used(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- The trigger learns about the fifth source
-- ---------------------------------------------------------------------
-- Restated from the built definition. Two things are added and nothing
-- else is touched: the credit note's own remaining value is maintained
-- like a receipt's, and spreading it further than it is for is refused
-- like a receipt's.
create or replace function app.apply_allocation()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $function$
declare
  v_invoice_id uuid := coalesce(new.invoice_id, old.invoice_id);
  v_bill_id    uuid := coalesce(new.bill_id, old.bill_id);
  v_receipt_id uuid := coalesce(new.receipt_id, old.receipt_id);
  v_payment_id uuid := coalesce(new.payment_id, old.payment_id);
  v_credit_id  uuid := coalesce(new.credit_note_id, old.credit_note_id);
  v_paid       numeric(18, 2);
  v_total      numeric(18, 2);
  v_no         text;
  v_left       numeric(18, 2);
  v_from       uuid;
  v_to         uuid;
  -- Deletes only ever reduce what is allocated, and a set of books that
  -- is already over-allocated has to be able to put itself right.
  v_check      boolean := tg_op <> 'DELETE';
begin
  -- ------------------------------------------------------------------
  -- Whose money, and whose document. 0465.
  -- ------------------------------------------------------------------
  -- Only when the money's party can be known. A contra allocation
  -- names none of these columns, so `v_from` stays null and this
  -- declines; `create_contra` is where its two parties are checked.
  if v_check then
    v_from := coalesce(
      (select r.contact_id from public.receipts r
        where r.id = new.receipt_id),
      (select p.contact_id from public.purchase_payments p
        where p.id = new.payment_id),
      (select d.contact_id from public.sales_documents d
        where d.id = new.credit_note_id),
      (select n.contact_id from public.deposit_notes n
        where n.id = new.deposit_id),
      (select c.contact_id from public.post_dated_cheques c
        where c.id = new.pdc_id),
      (select w.contact_id from public.withholding_certificates w
        where w.id = new.withholding_id));

    v_to := coalesce(
      (select d.contact_id from public.sales_documents d
        where d.id = v_invoice_id),
      (select d.contact_id from public.purchase_documents d
        where d.id = v_bill_id));

    if v_from is not null and v_to is not null
       and not app.same_party(v_from, v_to) then
      raise exception
        'This money is %''s and the document belongs to %. One party''s '
        'money cannot settle another''s: if they are the same party '
        'under two names, put the same TIN on both contact records; if '
        'they are not, the money belongs on its own account.',
        coalesce((select name from public.contacts where id = v_from), '?'),
        coalesce((select name from public.contacts where id = v_to), '?')
        using errcode = '23514';
    end if;
  end if;

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

  -- ------------------------------------------------------------------
  -- 0629. The credit note used as a source, kept like a receipt.
  -- ------------------------------------------------------------------
  -- `paid_amount` on a credit note means "how much of it has been put
  -- against something", which is the same shape of fact as on an
  -- invoice and keeps `balance_amount` meaning what it means on every
  -- other document: what is left. The aged listing reads it rather
  -- than recomputing it, and so can anything else.
  --
  -- A credit note is never also an invoice target -- the check
  -- constraint puts the two in different columns and the doc types
  -- differ -- so these two updates cannot fight over the same row.
  if v_credit_id is not null then
    select coalesce(sum(amount), 0) into v_paid
      from public.payment_allocations where credit_note_id = v_credit_id;

    if v_check then
      select d.doc_no, d.total_amount into v_no, v_total
        from public.sales_documents d where d.id = v_credit_id;
      if round(v_paid, 2) > round(coalesce(v_total, 0), 2) then
        raise exception
          'Credit note % is for %, and % has been put against invoices. '
          'A credit note cannot settle more than it credits.',
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
     where id = v_credit_id;
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

-- ---------------------------------------------------------------------
-- The writer
-- ---------------------------------------------------------------------
create or replace function public.allocate_credit_note(
  p_credit_note uuid,
  p_invoice     uuid,
  p_amount      numeric)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_cn    public.sales_documents;
  v_inv   public.sales_documents;
  v_alloc uuid;
begin
  select * into v_cn from public.sales_documents where id = p_credit_note;
  if v_cn.id is null or v_cn.deleted_at is not null then
    raise exception 'No such credit note.' using errcode = 'P0002';
  end if;
  -- `can_post`, matching `allocate_with_discount`. Knocking a credit
  -- note off an invoice changes what a customer is shown to owe and
  -- what the aged listing reports, which is a posting decision even
  -- though no journal moves.
  if not app.can_post(v_cn.org_id) then
    raise exception 'not permitted to allocate a credit note'
      using errcode = '42501';
  end if;
  if v_cn.doc_type <> 'credit_note' then
    raise exception '% is a %, not a credit note.', v_cn.doc_no, v_cn.doc_type
      using errcode = '22023';
  end if;
  -- A draft credits nothing. Allocating one would reduce an invoice
  -- against a document that has not reached the ledger.
  if v_cn.gl_entry_id is null or v_cn.status = 'void' then
    raise exception 'Credit note % has not been posted.', v_cn.doc_no
      using errcode = '22023';
  end if;

  select * into v_inv from public.sales_documents where id = p_invoice;
  if v_inv.id is null or v_inv.org_id <> v_cn.org_id
     or v_inv.deleted_at is not null then
    raise exception 'No such invoice.' using errcode = 'P0002';
  end if;
  if v_inv.doc_type not in ('invoice', 'debit_note') then
    raise exception
      'A credit note is set against an invoice or a debit note, not a %.',
      v_inv.doc_type using errcode = '22023';
  end if;
  if v_inv.gl_entry_id is null or v_inv.status = 'void' then
    raise exception '% has not been posted.', v_inv.doc_no
      using errcode = '22023';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'An allocation is of something.' using errcode = '23514';
  end if;

  -- No journal. The credit note credited the receivable when it was
  -- posted; this records which invoice it is against. The two guards
  -- that keep it honest -- not more than the invoice owes, not more
  -- than the credit note credits -- are both in `app.apply_allocation`,
  -- where a writer that did not come through here still meets them.
  insert into public.payment_allocations
    (org_id, credit_note_id, invoice_id, amount, allocated_by)
  values (v_cn.org_id, p_credit_note, p_invoice, round(p_amount, 2),
          auth.uid())
  returning id into v_alloc;

  return v_alloc;
end $$;

comment on function public.allocate_credit_note(uuid, uuid, numeric) is
  'Sets a posted credit note against a posted invoice. Posts no '
  'journal: the credit note credited the receivable when it was '
  'raised. See 0629.';

revoke all on function public.allocate_credit_note(uuid, uuid, numeric)
  from public, anon;
grant execute on function public.allocate_credit_note(uuid, uuid, numeric)
  to authenticated, service_role;
