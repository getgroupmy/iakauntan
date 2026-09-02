-- ---------------------------------------------------------------------
-- 0465  Whose money it is
-- ---------------------------------------------------------------------
-- Measured on a built database, one customer and one invoice belonging
-- to another:
--
--   allocate_with_discount(A's receipt, B's invoice, 500)
--     ->  accepted. B's invoice: balance 0.00.
--         app.same_party(A, B) = false
--
-- B's invoice is marked paid with money A sent. A's account no longer
-- shows the payment as theirs to spend; B's shows a debt that was never
-- settled. Two customers' ledgers have been crossed, and the only
-- record of it is an allocation row nobody will read.
--
-- `create_contra` has refused exactly this since `0272` -- "a contra
-- between two different parties is refused", asserted in
-- `supabase/tests/contra.sql` -- because setting one party's invoice
-- against another's bill is obviously wrong. Paying one party's invoice
-- with another's cash is the same wrongness through a different door,
-- and that door has been open the whole time.
--
-- ### The rule
--
-- The money's party and the document's party have to be the same party,
-- and `app.same_party` already decides what that means: the same
-- contact record, or two records carrying the same TIN. A group that
-- keeps one customer under three contact rows says so by putting the
-- TIN on all three, which is the same thing consolidation already
-- relies on.
--
-- It is checked for every source of money that names a party --
-- receipts, supplier payments, credit notes, deposits, post-dated
-- cheques, withholding certificates -- because they all reach the same
-- trigger.
--
-- **A contra is outside it by construction, not by an exception.** The
-- first draft carried `and new.contra_id is null`, on the reasoning
-- that a contra note names two contacts by design -- a customer and a
-- supplier -- and `create_contra` already holds them to `same_party`
-- itself. The mutant that removed that condition **survived**, and
-- looking at why is the useful part: a contra allocation sets
-- `contra_id` and leaves every column this guard reads null, so the
-- money's party is unknown and the check declines on its own. The
-- condition was a comment wearing an `if`. It is gone, the reason is
-- here, and `supabase/tests/allocation_party.sql` asserts the shape it
-- depended on -- that a contra allocation names no source column --
-- rather than leaving it as something somebody once knew.
--
-- ### Where the guard goes, and why here again
--
-- `app.apply_allocation`, beside `0464`'s. Same argument, and it has
-- got stronger: fourteen writers, and the two that anybody would think
-- to guard are not where the holes were.
--
-- ### Mutants
--
-- Four, restated into a built database and run against
-- `supabase/tests/allocation_party.sql`.
--
--   * the party guard dropped -- killed by "one customer's money cannot
--     settle another's invoice";
--   * `app.same_party` replaced with plain inequality -- killed, and
--     killed by the *permissive* half of the file: head office settling
--     the branch's invoice is refused, with the message quoted back at
--     it. A guard that only ever refuses more is still a broken guard,
--     and this is the assertion that says so;
--   * the source narrowed to receipts, so a supplier payment is not
--     checked -- killed by "money sent to one supplier cannot settle
--     another's bill";
--   * the `new.contra_id is null` condition removed -- **survived**,
--     and the survivor was right. See the paragraph above: a contra
--     names no money source, so the condition never decided anything.
--     It has been removed rather than left in with a passing test
--     beside it, and what it was standing in for is asserted instead.
-- ---------------------------------------------------------------------

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
  'receipt, and refuses three things: an allocation larger than the '
  'document, one larger than the money behind it, and one that crosses '
  'from one party''s money to another''s document. In the trigger '
  'because fourteen places write payment_allocations. See 0464, 0465.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(to_regprocedure('app.apply_allocation()'));
begin
  if position('app.same_party(v_from, v_to)' in v_src) = 0 then
    raise exception
      '0465: one customer''s money can still settle another''s invoice';
  end if;

  -- 0464's two guards are still there. A restatement that quietly drops
  -- one is the failure mode of this whole approach.
  if position('paid more than it is for' in v_src) = 0
     or position('spread further than the money that arrived' in v_src) = 0
     or position('tg_op <> ''DELETE''' in v_src) = 0 then
    raise exception '0465: restating the trigger dropped one of 0464''s guards';
  end if;

  -- The guard only fires when both ends are known. Drop this and a
  -- contra allocation -- which names no money source at all -- would be
  -- compared against a null party.
  if position('v_from is not null and v_to is not null' in v_src) = 0 then
    raise exception
      '0465: the party check runs when it does not know whose money it is';
  end if;
end
$do$;
