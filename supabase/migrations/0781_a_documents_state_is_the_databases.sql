-- =====================================================================
-- iAkauntan :: 0781 a document's state is the database's
--
-- A sales or purchase document's `status`, `paid_amount` and
-- `balance_amount` follow from things that happened to it: it was
-- posted (`post_*_document_internal`), voided (`void_sales_document`),
-- paid (`app.apply_allocation`), received against or transferred from.
-- The ageing, the statements, the dashboard, the customer portal and
-- the pay link all read them.
--
-- `refuse_posted_document_change` (`0238` onwards) freezes the figures
-- a document's JOURNAL was built from. It never froze these three, and
-- the tables' own policies (`*_documents_update`: `can_write` and the
-- module) let any member who may write set them directly. Measured on
-- 9 October 2026, locally, signed in as a member who may write but not
-- post:
--
--   * a posted RM1,000 invoice set to 'void' with one UPDATE left the
--     AR ageing -- RM1,000 to nothing -- while the ledger still held
--     the receivable, unreversed: the debtors list stopped agreeing
--     with the control account, and nothing said why;
--   * a posted bill set to 'void' the same way;
--   * a draft invoice set to 'posted' read as posted with no journal;
--   * a posted invoice set to paid, `balance_amount` 0 -- and
--     `settle_shared_payment` takes the LESSER of what was paid and
--     what is owed, so by its own code a customer paying it online is
--     marked paid with no receipt booked (read, not measured).
--
-- The app never writes these columns itself: its editor sends neither
-- `status` nor the two figures, and voiding and paying go through the
-- functions. So this was the API's road, and the rule existed nowhere
-- for it.
--
-- Answered "guard the columns". A trigger refuses a client's own
-- statement -- role `authenticated` or `anon`, at the top trigger depth
-- -- that changes any of the three, and a client's insert of a document
-- that is not a draft with nothing paid on it. Everything the database
-- does for itself still passes:
--
--   * SECURITY DEFINER functions (posting, voiding, receiving, POS,
--     the imports, the e-Invoice preparation) run as their owner, so
--     `current_user` is not a client role. `0643` drew the same line
--     for `accounts.opening_balance`;
--   * the two writers that run as the caller -- `app.apply_allocation`
--     on `payment_allocations`, and the `app.recalc_*_totals_for` that
--     line triggers call -- write from inside another trigger, so the
--     depth is more than one. A client's statement cannot be anything
--     but depth one: anything deeper is code this schema defined.
--
-- Production held no document in a state this refuses to reach: no
-- sales document posted without a journal, and no void document with
-- an unreversed one. Ten demo purchase orders read 'completed' with no
-- journal, which is right -- an order never posts -- and was written
-- by the receiving function, which this does not touch.
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
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array['status', 'paid_amount', 'balance_amount'] loop
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

revoke all on function app.document_state_is_the_databases() from public, anon, authenticated;

comment on function app.document_state_is_the_databases() is
  'Refuses a client''s own statement that writes a sales or purchase '
  'document''s status, paid amount or balance, and a client''s insert of '
  'anything but a draft with nothing paid. Those follow from posting, '
  'voiding and payments; the functions that do those run as their owner '
  'or from inside another trigger, and pass. 0781.';

create trigger state_is_the_databases
  before insert or update on public.sales_documents
  for each row execute function app.document_state_is_the_databases();

create trigger state_is_the_databases
  before insert or update on public.purchase_documents
  for each row execute function app.document_state_is_the_databases();
