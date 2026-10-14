-- =====================================================================
-- iAkauntan :: 0901 a credit is linked by crediting
--
-- `0269` gave a credit note the invoice it credits (`0376` a supplier
-- credit its bill) so that a credit could be held to what was sold:
-- `credit_sales_invoice` and `credit_purchase_bill` refuse more than is
-- left uncredited on each line. The link itself stayed an ordinary
-- column a client could write. A draft written straight into the table
-- with `original_invoice_id` set, then posted, was held to nothing.
--
-- Measured on 14 October 2026, locally, as an accountant with the role
-- `authenticated`: a credit note of 5,000 naming a 1,000 invoice,
-- posted; a supplier credit of 5,000 naming a 1,000 bill, posted. A
-- linked note is also what the credited-recipe stock return reads.
--
-- The app never writes the link itself -- only the two credit functions
-- do. Production on 14 October held no linked note.
--
-- Answered "link only through the functions": a client may not set or
-- change `sales_documents.original_invoice_id` or
-- `purchase_documents.original_bill_id`. The credit functions run as
-- their owner and are not asked. A note typed by hand is still a note,
-- unlinked, as the app has always made it.
-- =====================================================================

create or replace function app.a_credit_is_linked_by_crediting()
returns trigger
language plpgsql
set search_path to 'public', 'app', 'pg_temp'
as $$
declare
  v_col text := tg_argv[0];
  v_new text := to_jsonb(new) ->> v_col;
begin
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;
  if tg_op = 'UPDATE' and v_new is not distinct from (to_jsonb(old) ->> v_col) then
    return new;
  end if;
  if tg_op = 'INSERT' and v_new is null then
    return new;
  end if;
  raise exception
    'A credit is tied to the % it credits by crediting it ("Credit this"), '
    'which holds it to what is left uncredited on each line. Type the note '
    'without naming the %, or credit the % itself.',
    tg_argv[1], tg_argv[1], tg_argv[1]
    using errcode = '42501';
end;
$$;

revoke all on function app.a_credit_is_linked_by_crediting() from public, anon, authenticated;

comment on function app.a_credit_is_linked_by_crediting() is
  'Refuses a client''s write of the column naming the document a credit '
  'note credits (trigger argument 1; argument 2 names the document for '
  'the message). Only credit_sales_invoice and credit_purchase_bill set '
  'it, and they cap the credit. 0901.';

create trigger a_credit_is_linked_by_crediting
  before insert or update of original_invoice_id on public.sales_documents
  for each row execute function app.a_credit_is_linked_by_crediting(
    'original_invoice_id', 'invoice');

create trigger a_credit_is_linked_by_crediting
  before insert or update of original_bill_id on public.purchase_documents
  for each row execute function app.a_credit_is_linked_by_crediting(
    'original_bill_id', 'bill');
