-- =====================================================================
-- iAkauntan :: 0849 what a supplier sent stays whole
--
-- `0650` keeps the e-invoices suppliers send us through MyInvois as
-- they arrived: "a record of what a supplier sent is worthless if the
-- person who received it can edit the figures", so a client may read
-- one and delete the whole of one -- "this was not for us" -- and every
-- other change goes through a function. Its LINES carried a delete
-- policy of their own, and nothing asked whether a bill had been built
-- from the document being deleted.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`: one line of a supplier's document deleted was
-- accepted, the document still saying RM212 payable over the one line
-- left; every line of a billed document deleted was accepted; and the
-- document behind a POSTED bill deleted was accepted, the bill standing
-- in the ledger with nothing it was drafted from. The app deletes a
-- document, never a line, and "not for us" has its own status,
-- `ignored`.
--
-- Answered "lines go only with it; billed stays":
--
--   * a client may no longer delete a line. Lines go when their
--     document does, by its foreign key's cascade, which runs as the
--     table's owner.
--   * `a_billed_document_stays` refuses a client's own delete -- role
--     `authenticated` or `anon`, at the top trigger depth -- of a
--     document while a bill built from it still exists. A bill deleted
--     leaves `bill_id` empty, and the document may go after it. NOT
--     security definer: a definer would always answer "the owner".
--
-- Production held no received e-invoice on 12 October.
-- =====================================================================

revoke delete on public.received_einvoice_lines from authenticated, anon;
drop policy if exists received_einvoice_lines_delete
  on public.received_einvoice_lines;

create or replace function app.a_billed_document_stays()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return old;
  end if;

  if old.bill_id is not null then
    raise exception
      'Supplier document % has a bill built from it, and is what that bill '
      'was checked against. It stays while the bill does.',
      old.doc_no
      using errcode = '42501';
  end if;
  return old;
end $$;

revoke all on function app.a_billed_document_stays()
  from public, anon, authenticated;

comment on function app.a_billed_document_stays() is
  'On received_einvoices: refuses a client''s own delete of a document '
  'while a bill built from it still exists (bill_id). 0849.';

create trigger a_billed_document_stays
  before delete on public.received_einvoices
  for each row execute function app.a_billed_document_stays();
