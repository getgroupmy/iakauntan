-- =====================================================================
-- iAkauntan :: 0072 amending a generated document, and when you cannot
--
-- Generated text is a starting point, not a finished deed. A resolution
-- wants a recital the template did not anticipate; a set of particulars
-- needs a note about why a date is what it is. So the body is editable.
--
-- With one boundary: **once somebody has signed it, the text is fixed.**
--
-- The signature layer already detects an edit — the body is hashed when
-- signing opens and again as each person signs, and `document_unchanged`
-- goes false when they disagree. But detecting is not preventing, and a
-- signed resolution whose text has since been rewritten is a document
-- that says one thing while somebody's signature attests to another.
-- Nobody should be able to reach that state by accident.
--
-- The rule lives in a trigger rather than in the RPC that the app calls,
-- because RLS already grants `can_write` full ALL on this table: anyone
-- with the publishable key and a session could PATCH the row directly.
-- A guard only in Dart, or only in one function, is not a guard.
-- =====================================================================

create or replace function app.corp_document_locked()
returns trigger language plpgsql
set search_path = public, app, pg_temp as $$
declare
  v_signed integer;
begin
  -- Only the text is protected. Filing references, links to a resolution
  -- and the like are bookkeeping about the document, not the document.
  if new.body is not distinct from old.body
     and new.title is not distinct from old.title then
    return new;
  end if;

  select count(*) into v_signed
    from public.corp_signatures s
    join public.corp_signature_requests r on r.id = s.request_id
   where r.document_id = old.id
     and s.status = 'signed'
     and not r.is_withdrawn;

  if v_signed > 0 then
    raise exception
      'This document has been signed by % and cannot be edited. '
      'Withdraw the signature request and generate a fresh document.',
      case when v_signed = 1 then '1 person' else v_signed || ' people' end
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger corp_document_locked
  before update on public.corp_documents
  for each row execute function app.corp_document_locked();

-- ---------------------------------------------------------------------
-- The amendment itself
--
-- A thin wrapper, so the app has one call with one error message rather
-- than a PATCH whose failure mode is a policy violation. The trigger
-- above is what actually enforces the rule.
-- ---------------------------------------------------------------------
create or replace function public.corp_update_document(
  p_document_id uuid,
  p_title text,
  p_body text)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare d public.corp_documents;
begin
  select * into d from public.corp_documents where id = p_document_id;
  if d.id is null then
    raise exception 'Document not found' using errcode = 'P0002';
  end if;
  if not app.can_write(d.org_id) then
    raise exception 'Not permitted to edit this document' using errcode = '42501';
  end if;
  if coalesce(btrim(p_title), '') = '' then
    raise exception 'A document needs a title' using errcode = '22023';
  end if;

  update public.corp_documents
     set title = btrim(p_title),
         body = coalesce(p_body, '')
   where id = p_document_id;
end;
$$;

revoke all on function public.corp_update_document(uuid, text, text) from public, anon;
grant execute on function public.corp_update_document(uuid, text, text)
  to authenticated, service_role;
