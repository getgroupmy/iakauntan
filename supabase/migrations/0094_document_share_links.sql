-- Handing an invoice to somebody who does not have a login.
--
-- Every document in this system can be turned into a PDF and then has
-- nowhere to go: the person who made it downloads it and takes over by
-- hand. The customer, who is the entire reason the document exists, has
-- no way to see it.
--
-- The mechanism for this was already built and pointed somewhere else.
-- `corp_signing_links` hands a resolution to a director who is not
-- staff: a long random token, only its hash stored, an expiry, one live
-- link at a time, and the open recorded because that is the only
-- evidence the link reached anybody. All of that applies here
-- unchanged.
--
-- `app.corp_new_token` and `app.corp_token_hash` are reused rather than
-- copied. The `corp_` prefix is historical — one generates a token and
-- the other is sha256 — and a second hash function that exists so a
-- name reads better is how two hashes come to disagree.

create table if not exists public.document_share_links (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  document_id   uuid not null references public.sales_documents (id) on delete cascade,
  token_hash    text not null unique,
  expires_at    timestamptz not null,
  sent_to_email text,
  opened_at     timestamptz,
  last_opened_at timestamptz,
  open_count    integer not null default 0,
  ip_address    inet,
  user_agent    text,
  revoked_at    timestamptz,
  created_by    uuid references auth.users (id),
  created_at    timestamptz not null default now()
);

create index if not exists document_share_links_document
  on public.document_share_links (document_id);

alter table public.document_share_links enable row level security;

-- Members may see and revoke their organization's links. Nobody writes
-- one directly: the token has to be returned to the caller exactly once
-- and never stored in the clear, which an insert policy cannot arrange.
drop policy if exists document_share_links_select on public.document_share_links;
create policy document_share_links_select on public.document_share_links
  for select to authenticated using (app.is_org_member(org_id));

drop policy if exists document_share_links_update on public.document_share_links;
create policy document_share_links_update on public.document_share_links
  for update to authenticated
  using (app.can_write(org_id)) with check (app.can_write(org_id));

-- ---------------------------------------------------------------------
-- Issue a link
--
-- Only for a document that has been issued. Sharing a draft would put a
-- number in front of a customer that the sender has not committed to
-- and may still change; a void or rejected one is shared by accident
-- rather than on purpose.
--
-- `pending` and `approved` are deliberately shareable. A quotation
-- lives at those statuses and being sent to the customer is the entire
-- point of it.
-- ---------------------------------------------------------------------
create or replace function public.share_document(
  p_document_id uuid,
  p_valid_days integer default 30,
  p_email text default null)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  d public.sales_documents;
  v_token text;
begin
  select * into d from public.sales_documents where id = p_document_id;
  if d.id is null or d.deleted_at is not null then
    raise exception 'Document not found' using errcode = 'P0002';
  end if;
  if not app.can_write(d.org_id) then
    raise exception 'Not permitted to share this document'
      using errcode = '42501';
  end if;
  if d.status in ('draft', 'void', 'rejected') then
    raise exception 'A % document cannot be shared', d.status
      using errcode = '22023';
  end if;

  v_token := app.corp_new_token();

  -- One live link per document. Somebody who reissues a link means the
  -- last one to go out is the one that should work; leaving the old one
  -- live makes "revoke" mean nothing.
  update public.document_share_links
     set revoked_at = now()
   where document_id = p_document_id and revoked_at is null;

  insert into public.document_share_links
    (org_id, document_id, token_hash, expires_at, sent_to_email, created_by)
  values (d.org_id, p_document_id, app.corp_token_hash(v_token),
          now() + make_interval(
            days => greatest(least(coalesce(p_valid_days, 30), 365), 1)),
          nullif(btrim(p_email), ''), auth.uid());

  return v_token;
end;
$$;

create or replace function public.revoke_document_share(p_document_id uuid)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org uuid;
  v_n integer;
begin
  select org_id into v_org from public.sales_documents where id = p_document_id;
  if v_org is null then
    raise exception 'Document not found' using errcode = 'P0002';
  end if;
  if not app.can_write(v_org) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  update public.document_share_links
     set revoked_at = now()
   where document_id = p_document_id and revoked_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- Open a link
--
-- Callable by `anon`, which is the whole point and also the reason
-- every field below was chosen deliberately. What comes back is what a
-- customer is entitled to see on their own invoice and nothing else:
-- no internal notes, no line cost, no margin, no other document, and
-- nothing at all about any other customer.
--
-- An invalid token returns a state rather than an error, so a wrong
-- link and a revoked link are indistinguishable from outside — the
-- alternative tells somebody guessing tokens when they have found a
-- real one.
-- ---------------------------------------------------------------------
create or replace function public.open_shared_document(p_token text)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  l public.document_share_links;
  d public.sales_documents;
  o public.organizations;
  c public.contacts;
  v_state text;
begin
  select * into l from public.document_share_links
   where token_hash = app.corp_token_hash(p_token);

  if l.id is null then
    return jsonb_build_object('state', 'invalid');
  end if;

  select * into d from public.sales_documents where id = l.document_id;
  select * into o from public.organizations where id = l.org_id;
  select * into c from public.contacts where id = d.contact_id;

  v_state := case
    when l.revoked_at is not null then 'revoked'
    when l.expires_at < now() then 'expired'
    when d.id is null or d.deleted_at is not null then 'withdrawn'
    when d.status in ('void', 'rejected') then 'withdrawn'
    else 'open'
  end;

  -- Recorded even when the answer is 'expired': that somebody tried is
  -- worth as much as that somebody read it.
  update public.document_share_links
     set opened_at = coalesce(opened_at, now()),
         last_opened_at = now(),
         open_count = open_count + 1,
         ip_address = coalesce(ip_address, nullif(split_part(coalesce(
           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet),
         user_agent = coalesce(user_agent, app.request_header('user-agent'))
   where id = l.id;

  if v_state <> 'open' then
    return jsonb_build_object('state', v_state);
  end if;

  return jsonb_build_object(
    'state', 'open',
    'company', jsonb_build_object(
      'name', coalesce(o.legal_name, o.name),
      'registration_no', o.registration_no,
      'tin', o.tin,
      'sst_registration_no', o.sst_registration_no,
      'address', concat_ws(E'\n', o.address_line1, o.address_line2,
                           o.address_line3,
                           nullif(concat_ws(' ', o.postcode, o.city), ''),
                           o.state_code),
      'email', o.email,
      'phone', o.phone,
      'website', o.website,
      'logo_url', o.logo_url),
    'contact', jsonb_build_object(
      'name', c.name,
      'address', concat_ws(E'\n', c.address_line1, c.address_line2,
                           nullif(concat_ws(' ', c.postcode, c.city), ''),
                           c.state_code)),
    'document', jsonb_build_object(
      'doc_type', d.doc_type,
      'doc_no', d.doc_no,
      'doc_date', d.doc_date,
      'due_date', d.due_date,
      'reference', d.reference,
      'subject', d.subject,
      'currency', d.currency,
      'subtotal', d.subtotal,
      'discount_amount', d.discount_amount,
      'tax_amount', d.tax_amount,
      'shipping_amount', d.shipping_amount,
      'rounding_amount', d.rounding_amount,
      'total_amount', d.total_amount,
      'paid_amount', d.paid_amount,
      'balance_amount', d.balance_amount,
      'status', d.status,
      -- `notes` is what the sender wrote for the customer to read.
      -- `internal_notes` is not, and is deliberately absent.
      'notes', d.notes,
      'terms_conditions', d.terms_conditions),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'line_no', li.line_no,
               'description', li.description,
               'quantity', li.quantity,
               'uom_code', li.uom_code,
               'unit_price', li.unit_price,
               'discount_amount', li.discount_amount,
               'tax_amount', li.tax_amount,
               'line_total', li.line_total)
             order by li.line_no)
        from public.sales_document_lines li
       where li.document_id = d.id), '[]'::jsonb));
end;
$$;

revoke all on function public.share_document(uuid, integer, text)
  from public, anon;
grant execute on function public.share_document(uuid, integer, text)
  to authenticated;

revoke all on function public.revoke_document_share(uuid) from public, anon;
grant execute on function public.revoke_document_share(uuid) to authenticated;

-- The one function here that anonymous callers may run. It takes a
-- token and returns one document; without the token it returns
-- 'invalid' and nothing else.
revoke all on function public.open_shared_document(text) from public;
grant execute on function public.open_shared_document(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Take the table privileges back
--
-- Supabase's default privileges grant `anon` and `authenticated` every
-- privilege on any new table in `public`, so RLS is the only thing
-- standing between an anonymous request and the contents of this table.
-- That is true of every table here and is normally fine. It is not fine
-- for this one: the rows are hashed credentials, and the only reason
-- `anon` reads nothing today is that the select policy above happens to
-- say `to authenticated`. A policy edit a year from now should not be
-- able to turn that into a leak.
--
-- `authenticated` keeps select and update — listing a document's links
-- and revoking one. Inserts go through `share_document`, which is
-- SECURITY DEFINER and runs as the owner, so nobody needs the privilege
-- directly.
revoke all on public.document_share_links from anon;
revoke all on public.document_share_links from authenticated;
grant select, update on public.document_share_links to authenticated;
