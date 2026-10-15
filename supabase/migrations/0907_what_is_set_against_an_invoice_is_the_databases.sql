-- =====================================================================
-- iAkauntan :: 0907 what is set against an invoice is the database's
--
-- `sales_documents.applied_amount` (`0005`, "for credit notes") is
-- read in one place: `app.recalc_sales_totals_for` works the balance
-- out as the total less what was paid less what was applied. Nothing
-- writes it. Credit notes are set against invoices through
-- `payment_allocations`, which `app.apply_allocation` counts into
-- `paid_amount`, and no function, import or screen has ever filled
-- `applied_amount`. `0781` made the status, the paid figure and the
-- balance the database's; this one was still an ordinary column.
--
-- Measured on 14 October 2026, locally, as the owner with the role
-- `authenticated`: a draft invoice of RM1,080 (one 8% line) given an
-- `applied_amount` of 1,000 by hand worked out to a balance of RM80
-- at its next line change, and posted with that balance against
-- RM1,080 in the receivable. `customer_credit_status` -- which the
-- credit limit reads -- then said RM80 outstanding. The ageing works
-- out its own figure and still said RM1,080, so the two disagreed and
-- nothing said why. The portal, the overdue reminders and the pay
-- link read the same balance as the credit status.
--
-- Production on 14 October: 167 invoices, not one with an applied
-- amount.
--
-- Answered "guard it like 0905": `0781`'s trigger, which already
-- stands on both header tables, refuses a client's change of
-- `applied_amount` and a client's insert of a document with one. The
-- column stays, and the database's own hand -- every function that
-- runs as its owner, and anything run from inside another trigger --
-- is not asked. Purchase documents have no such column, so `to_jsonb`
-- reads it: absent there, and the same on both sides.
-- =====================================================================

create or replace function app.document_state_is_the_databases()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_col text;
  v_old jsonb;
  v_new jsonb;
begin
  -- NOT security definer: the question is who is running the statement,
  -- and a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'draft'
       or coalesce(new.paid_amount, 0) <> 0 then
      raise exception
        'A document is created as a draft with nothing paid on it (this '
        'one said %, with % paid). It becomes posted by posting it, and '
        'paid by recording payments against it.',
        new.status, coalesce(new.paid_amount, 0)
        using errcode = '42501';
    end if;
    -- 0907: nor with anything already set against it. A purchase
    -- document has no such column, and reads as nothing.
    if coalesce((to_jsonb(new) ->> 'applied_amount')::numeric, 0) <> 0 then
      raise exception
        'A document is created with nothing set against it (this one '
        'said % applied). A credit note or a payment is set against it '
        'by allocating it.',
        to_jsonb(new) ->> 'applied_amount'
        using errcode = '42501';
    end if;
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  -- 0907: `applied_amount` too; the balance is worked out from it.
  foreach v_col in array array['status', 'paid_amount', 'balance_amount',
                               'applied_amount'] loop
    if (v_new -> v_col) is distinct from (v_old -> v_col) then
      raise exception
        'The % of % follows from what happened to it -- posting, voiding, '
        'payments -- and is not written directly (% -> %). Post it, void '
        'it, or record the payment instead.',
        replace(v_col, '_', ' '), new.doc_no,
        coalesce(v_old ->> v_col, 'null'), coalesce(v_new ->> v_col, 'null')
        using errcode = '42501';
    end if;
  end loop;

  return new;
end $$;

comment on function app.document_state_is_the_databases() is
  'Refuses a client''s own statement that writes a sales or purchase '
  'document''s status, paid amount, balance or applied amount, and a '
  'client''s insert of anything but a draft with nothing paid or applied. '
  'Those follow from posting, voiding and payments; the functions that '
  'do those run as their owner or from inside another trigger, and pass. '
  '0781, 0907.';
