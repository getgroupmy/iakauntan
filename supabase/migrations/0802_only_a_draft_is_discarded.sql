-- =====================================================================
-- iAkauntan :: 0802 only a draft is discarded
--
-- A document is discarded by setting `deleted_at`: every list that
-- shows documents hides those rows. The app offers "Discard" on a draft
-- alone (`canDiscard`: status = 'draft'), and voids a posted invoice
-- through `void_sales_document`, which reverses what it posted. `0238`
-- refuses a HARD delete of a posted document -- "deleting it would
-- leave that journal with nothing to explain it" -- and nothing refused
-- the soft one. Measured on 10 October 2026, locally, as the owner with
-- the role `authenticated`: a posted invoice and a posted bill, each
-- with an e-Invoice queued for LHDN, both set deleted. The journals
-- stayed in the ledger, the e-Invoices stayed queued for the bulk
-- MyInvois sweep, and both documents left every list.
--
-- Answered "only a draft is deleted". A trigger refuses a client's own
-- statement -- role `authenticated` or `anon`, at the top trigger depth
-- -- that sets `deleted_at` on a sales or purchase document that is not
-- a draft. Bringing a discarded draft back stays allowed. The
-- database's own functions run as their owner and pass. NOT security
-- definer itself. Named to fire before the other BEFORE triggers on
-- both tables, so the refusal is this one's.
--
-- Production held one deleted sales document, a draft, and no deleted
-- document past draft, on 10 October.
-- =====================================================================

create or replace function app.a_draft_is_what_is_discarded()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  if new.deleted_at is not null
     and old.deleted_at is null
     and old.status <> 'draft' then
    raise exception
      '% is %, and only a draft is discarded. A document past draft stays '
      'on the record: void it or raise a credit note against it, which '
      'reverses what it posted.', old.doc_no, old.status
      using errcode = '42501';
  end if;

  return new;
end $$;

revoke all on function app.a_draft_is_what_is_discarded() from public, anon, authenticated;

comment on function app.a_draft_is_what_is_discarded() is
  'On sales and purchase documents: refuses a client''s own statement '
  'that discards (sets deleted_at on) a document past draft. 0802.';

create trigger a_draft_is_what_is_discarded
  before update on public.sales_documents
  for each row execute function app.a_draft_is_what_is_discarded();

create trigger a_draft_is_what_is_discarded
  before update on public.purchase_documents
  for each row execute function app.a_draft_is_what_is_discarded();
