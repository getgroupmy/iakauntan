-- =====================================================================
-- iAkauntan :: 0801 a self-billed invoice goes with the obligation
--
-- `0611` lets a company say whether a bill owes LHDN a self-billed
-- e-Invoice -- a foreign supplier's does, and somebody can say so by
-- hand or take it off again -- and refuses to take it off once one is
-- submitted or valid. Before that, it took the tick off and nothing
-- else. Measured on 10 October 2026, locally: a self-billed e-Invoice
-- prepared for a bill (queued), then the bill unticked; the call
-- succeeded, the bill said it owed none, and the e-Invoice stayed
-- queued -- where `myinvois/submit.ts`'s bulk sweep, which sends
-- everything queued for the company and never asks the bill, would
-- file it. LHDN would then hold a self-billed e-Invoice for a supply
-- the company had just said the supplier files themselves.
--
-- Answered "withdraw the prepared one". Unticking marks the bill's
-- self-billed e-Invoice that LHDN has not received -- draft, queued,
-- failed or invalid -- 'cancelled', with why and when, and leaves the
-- bill owing none ('not_applicable', as a bill that never owed one
-- reads) and pointing at none. One submitted or valid is
-- refused as before. Ticking again clears a withdrawal that never
-- reached LHDN, so a second preparation re-queues a clean document.
-- Otherwise restated from `0611` (production's body hashes
-- identically, e4274e28...).
--
-- Production held no self-billed e-Invoice and no bill owing one on
-- 10 October.
-- =====================================================================

create or replace function public.set_requires_self_billed(
  p_document_id uuid,
  p_required boolean)
returns boolean
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_doc public.purchase_documents;
begin
  select * into v_doc from public.purchase_documents where id = p_document_id;
  if not found then
    raise exception 'Purchase document % not found', p_document_id
      using errcode = 'P0002';
  end if;
  if not app.can_write(v_doc.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if v_doc.einvoice_status in ('submitted', 'valid') then
    raise exception 'This bill''s self-billed e-Invoice is already with '
                    'LHDN. Cancel it there before changing whether one '
                    'is owed.'
      using errcode = '55000';
  end if;

  update public.purchase_documents
     set requires_self_billed = coalesce(p_required, false)
   where id = p_document_id;

  -- `0801`. A self-billed e-Invoice prepared for this bill and not yet
  -- with LHDN goes with the obligation. Left queued, the bulk MyInvois
  -- sweep files everything queued for the company and asks nothing of
  -- the bill, so LHDN would hold one for a supply the supplier files
  -- themselves. Withdrawn as 'cancelled', with why; the bill is left
  -- owing no e-Invoice and pointing at none.
  if not coalesce(p_required, false) then
    update public.einvoice_documents e
       set status = 'cancelled',
           cancelled_at = now(),
           cancellation_reason =
             'Withdrawn before it was sent: the bill no longer owes a '
             'self-billed e-Invoice.'
     where e.org_id = v_doc.org_id
       and e.source_table = 'purchase_documents'
       and e.source_id = v_doc.id
       and e.is_self_billed
       and e.status in ('draft', 'queued', 'failed', 'invalid');
    if found then
      update public.purchase_documents
         set einvoice_status = 'not_applicable', einvoice_id = null
       where id = p_document_id;
    end if;
  else
    -- Owed again: a withdrawn one that never reached LHDN is not a
    -- cancellation on the record, and `prepare_self_billed_einvoice`
    -- re-queues it over the top without clearing why it was withdrawn.
    update public.einvoice_documents e
       set cancelled_at = null, cancellation_reason = null
     where e.org_id = v_doc.org_id
       and e.source_table = 'purchase_documents'
       and e.source_id = v_doc.id
       and e.is_self_billed
       and e.status = 'cancelled'
       and e.myinvois_uuid is null;
  end if;
  return true;
end;
$function$;

comment on function public.set_requires_self_billed(uuid, boolean) is
  'Says whether a bill owes LHDN a self-billed e-Invoice. Refuses once '
  'one has been submitted -- that is cancelled at MyInvois, not '
  'un-ticked here. Taking it off withdraws one prepared and not yet '
  'sent. 0611, 0801.';

revoke all on function public.set_requires_self_billed(uuid, boolean)
  from public, anon;
grant execute on function public.set_requires_self_billed(uuid, boolean)
  to authenticated, service_role;
