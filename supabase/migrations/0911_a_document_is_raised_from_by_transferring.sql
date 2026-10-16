-- =====================================================================
-- iAkauntan :: 0911 a document is raised from another by transferring
--
-- `parent_id` on a sales or purchase document names the document it
-- was raised from. `transfer_document` sets it, and
-- `credit_sales_invoice` and `credit_purchase_bill`; all three run as
-- their owner. The app never writes it. And posting reads it:
-- `app.post_purchase_document_internal` asks whether a bill's parent
-- is a goods received note, and if it is, the bill clears what the note
-- accrued (2118) and moves no stock -- the note moved it -- while a
-- bill with no such parent receives the goods itself.
--
-- It was an ordinary column to a client. Measured on 16 October 2026,
-- locally, as the owner with the role `authenticated`: an order for 10
-- received on a note and the note posted (10 on hand, 1310 RM250, 2118
-- -RM250); a bill raised from the note; its `parent_id` set to null by
-- one UPDATE; the bill posted. 20 on hand, 1310 RM500, and the note's
-- RM250 accrual never cleared. The other way round -- a bill with no
-- parent given somebody else's note -- clears an accrual it never
-- received against.
--
-- Production on 16 October: no document with a parent.
--
-- Answered "set only by transferring": a client may not insert a
-- document that names a parent, nor change the parent of one. The
-- transfer and the two credit functions run as their owner and are
-- not asked. `0901` drew the same line for `original_invoice_id` and
-- `original_bill_id`.
-- =====================================================================

create or replace function app.a_document_is_raised_by_transferring()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- NOT security definer, for 0781's reason: the question is who runs
  -- the statement. The transfer and the credit functions run as their
  -- owner.
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if tg_op = 'INSERT' and new.parent_id is not null then
    raise exception
      'A document is raised from another by transferring or crediting '
      'it, and does not arrive naming one (% named %). Transfer the '
      'document it comes from instead.',
      new.doc_no, new.parent_id
      using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and new.parent_id is distinct from old.parent_id then
    raise exception
      'What % was raised from is set when it is transferred or credited, '
      'and is not changed by hand (% -> %). How it posts depends on it: a '
      'bill raised from a goods received note clears what the note '
      'accrued, and does not receive the goods again.',
      new.doc_no, coalesce(old.parent_id::text, 'null'),
      coalesce(new.parent_id::text, 'null')
      using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function app.a_document_is_raised_by_transferring() from public, anon, authenticated;

comment on function app.a_document_is_raised_by_transferring() is
  'Refuses a client''s insert of a sales or purchase document that names '
  'a parent, and a client''s change of one''s parent. transfer_document, '
  'credit_sales_invoice and credit_purchase_bill set it, as their owner; '
  'posting a bill reads it. 0911.';

create trigger a_document_is_raised_by_transferring
  before insert or update of parent_id on public.sales_documents
  for each row execute function app.a_document_is_raised_by_transferring();

create trigger a_document_is_raised_by_transferring
  before insert or update of parent_id on public.purchase_documents
  for each row execute function app.a_document_is_raised_by_transferring();
