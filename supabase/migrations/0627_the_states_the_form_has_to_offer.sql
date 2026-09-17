-- =====================================================================
-- iAkauntan :: 0627 the states the form has to offer
--
-- 0626's form is opened by somebody with no account, so it cannot read
-- `ref_states` -- the table is not granted to anon, and should not be.
-- But `contacts.state_code` is a foreign key into it, and MyInvois
-- requires the state on a buyer's address, so a form that cannot offer
-- the list either asks for free text (which the foreign key refuses) or
-- does not ask at all (which leaves the one field an e-Invoice needs
-- blank on exactly the contacts this link is sent to).
--
-- The third option is a second copy of the list in Dart. That is what
-- this migration exists to avoid: the sixteen codes are LHDN's, they
-- are seeded from a migration, and a screen holding its own copy is a
-- screen that goes on offering `07` for Pulau Pinang after the day the
-- standard renumbers it.
--
-- So `open_tax_detail_request` carries the list. It is the same
-- disclosure the page already makes -- a fixed public code list from a
-- published standard, with nothing in it about any person, company or
-- account.
--
-- Restated in full from 0626 with one key added and nothing else
-- touched.
-- =====================================================================

create or replace function public.open_tax_detail_request(p_token text)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  l       public.tax_detail_requests;
  c       public.contacts;
  o       public.organizations;
  v_state text;
begin
  select * into l from public.tax_detail_requests
   where token_hash = app.corp_token_hash(p_token);
  if l.id is null then
    return jsonb_build_object('state', 'invalid');
  end if;

  select * into c from public.contacts where id = l.contact_id;
  select * into o from public.organizations where id = l.org_id;

  v_state := case
    when l.revoked_at is not null then 'revoked'
    when l.expires_at < now() then 'expired'
    when c.id is null or c.deleted_at is not null then 'withdrawn'
    else 'open'
  end;

  update public.tax_detail_requests
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
      'email', o.email,
      'phone', o.phone,
      'logo_url', o.logo_url),
    'contact', jsonb_build_object(
      'name', c.name,
      'legal_name', c.legal_name,
      'registration_no', c.registration_no,
      'tin', c.tin,
      'is_tin_verified', c.is_tin_verified,
      'id_type', c.id_type,
      'id_value', c.id_value,
      'sst_registration_no', c.sst_registration_no,
      'email', c.email,
      'phone', c.phone,
      'address_line1', c.address_line1,
      'address_line2', c.address_line2,
      'address_line3', c.address_line3,
      'postcode', c.postcode,
      'city', c.city,
      'state_code', c.state_code,
      'country_code', c.country_code),
    -- The list the form's dropdown is built from, so there is one copy
    -- of it and it is this one.
    'states', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', s.code, 'name', s.name) order by s.code), '[]'::jsonb)
        from public.ref_states s),
    'already_submitted', l.submission_count > 0);
end $$;

comment on function public.open_tax_detail_request(text) is
  'What we hold about one contact, plus the state list its form needs, '
  'for somebody holding their tax-details token and no account. Money '
  'is not in it. See 0626 and 0627.';

-- 0165's event trigger strips anon on every `create or replace`, so the
-- grant has to be written back or the form stops opening -- which is
-- found by a customer who was asked for their TIN and could not give
-- it.
revoke all on function public.open_tax_detail_request(text) from public;
grant execute on function public.open_tax_detail_request(text)
  to anon, authenticated, service_role;

do $do$
begin
  if not has_function_privilege('anon',
       'public.open_tax_detail_request(text)', 'execute') then
    raise exception '0627: the form can no longer be opened';
  end if;
end $do$;
