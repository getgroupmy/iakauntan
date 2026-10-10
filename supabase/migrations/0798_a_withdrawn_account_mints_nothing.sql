-- =====================================================================
-- iAkauntan :: 0798 a withdrawn account mints nothing
--
-- `0493` gave a customer one link to their whole account, and
-- `portal_document_token` to turn a tap on one of its rows into a link
-- to that invoice. `open_customer_portal` answers a customer the
-- company has deleted with 'withdrawn' and lists nothing. The minting
-- road never asked. Measured on 10 October 2026, locally: the contact
-- deleted, the portal said 'withdrawn' -- and the same token minted a
-- link to one of the customer's invoices, and the link opened. The page
-- shows a withdrawn account no rows to tap, so only a request written
-- by hand got there.
--
-- Answered "refuse it". A deleted customer's portal mints nothing,
-- refused in the words a revoked or expired one is. Links minted before
-- keep their own expiry, thirty days at most. Otherwise restated from
-- `0493` (production's body hashes identically, 2120aa59...).
--
-- Production held no portal link on 10 October.
-- =====================================================================

create or replace function public.portal_document_token(
  p_token text, p_document_id uuid)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  l       public.customer_portal_links;
  c       public.contacts;
  d       public.sales_documents;
  v_token text;
begin
  select * into l from public.customer_portal_links
   where token_hash = app.corp_token_hash(p_token)
     and revoked_at is null and expires_at >= now();
  if l.id is null then
    raise exception 'This link is no longer open' using errcode = '42501';
  end if;

  select * into c from public.contacts where id = l.contact_id;
  -- `0798`. A customer the company has deleted is an account it has
  -- withdrawn: `open_customer_portal` says 'withdrawn' and lists
  -- nothing, and this mints nothing either. Answered as a closed portal
  -- is, because to the holder it is one.
  if c.id is null or c.deleted_at is not null then
    raise exception 'This link is no longer open' using errcode = '42501';
  end if;
  select * into d from public.sales_documents where id = p_document_id;

  -- The document has to be this customer's, in this company. Without
  -- this line a portal token is a key to every invoice in the tenant.
  if d.id is null
     or d.deleted_at is not null
     or d.org_id <> l.org_id
     or d.contact_id is null
     or not exists (
       select 1 from public.contacts c2
        where c2.id = d.contact_id
          and c2.org_id = l.org_id
          and (c2.id = c.id
               or (c.party_id is not null and c2.party_id = c.party_id)))
  then
    raise exception 'Not one of this account''s documents'
      using errcode = '42501';
  end if;
  if d.status in ('draft', 'void', 'rejected') then
    raise exception 'A % document cannot be opened', d.status
      using errcode = '22023';
  end if;

  v_token := app.corp_new_token();

  -- Deliberately no revoke. `share_document` kills the previous link
  -- because the tenant just emailed a new one and the last one sent
  -- has to be the one that works. Nobody has sent anything here: the
  -- customer clicked a row in their own account, and taking down the
  -- link they were emailed last week for doing so would be a bug
  -- wearing a rule's clothes.
  insert into public.document_share_links
    (org_id, document_id, token_hash, expires_at, sent_to_email)
  values (l.org_id, d.id, app.corp_token_hash(v_token),
          least(l.expires_at, now() + interval '30 days'),
          l.sent_to_email);

  return v_token;
end $$;

-- `0165`'s event trigger takes EXECUTE from `anon` on every create or
-- replace, and the customer tapping a row has no login.
grant execute on function public.portal_document_token(text, uuid) to anon, authenticated;

comment on function public.portal_document_token(text, uuid) is
  'Hands a customer holding a portal token a document token for one of '
  'their own invoices, so 0067''s view and 0414''s payment work '
  'unchanged. Revokes nothing. See 0493. Mints nothing for a customer '
  'the company has deleted. 0798.';
