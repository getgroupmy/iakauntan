-- =====================================================================
-- iAkauntan :: 0070 signing links — signing without an account
--
-- A director will not sign up to an accounting system to sign one
-- resolution. So there has to be a way to hand one person one action on
-- one document without giving them a login.
--
-- The primitive is deliberately general: a scoped, expiring, single-use
-- credential, stored only as a SHA-256 hash so that a database dump is
-- not a bag of working links. A client-portal invitation is the same
-- thing pointed at a different action, which is why this is built as a
-- table of links rather than a column on the signature row.
--
-- What this is NOT: a second factor. The app sends no e-mail, so the
-- link is exactly as strong as the channel it is sent over. It is
-- short-lived, single-use, bound to one signature line, and refuses to
-- work if the document text moved — but anyone holding the URL can sign.
-- Send it to the person, not to a group.
-- =====================================================================

create table public.corp_signing_links (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  signature_id uuid not null references public.corp_signatures (id)
    on delete cascade,

  -- The token itself is never stored. It is returned once, at creation,
  -- and after that only its hash exists.
  token_hash text not null unique,

  expires_at timestamptz not null,
  used_at timestamptz,
  revoked_at timestamptz,

  -- Where it was sent, for the secretary's own record. Delivery is not
  -- this system's job yet.
  sent_to_email text,

  -- Evidence that it reached somebody, captured on first open.
  opened_at timestamptz,
  ip_address inet,
  user_agent text,

  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index on public.corp_signing_links (signature_id);

create trigger set_updated_at before update on public.corp_signing_links
  for each row execute function app.set_updated_at();
create trigger audit_changes after insert or update or delete
  on public.corp_signing_links
  for each row execute function app.write_audit_log();

alter table public.corp_signing_links enable row level security;

-- Staff only, and only their own company's. The link holder never comes
-- through PostgREST at all — the two functions below are the only doors,
-- and they authorise against the token rather than against a JWT.
create policy corp_signing_links_select on public.corp_signing_links
  for select using (app.can_read_ledger(org_id) or app.can_write(org_id));
create policy corp_signing_links_write on public.corp_signing_links
  for all using (app.can_write(org_id))
  with check (app.can_write(org_id) and app.has_module(org_id, 'secretarial'));

-- Belt as well as braces. Supabase grants `anon` the full set of table
-- privileges by default and relies on RLS to hold the line; for the
-- tables in the signing path that is one mistake away from disaster, and
-- nothing legitimate needs them — every anonymous read and write here
-- goes through a SECURITY DEFINER function. Taking the privileges away
-- means a future policy slip cannot open these tables at all.
revoke all on public.corp_signing_links from anon;
revoke all on public.corp_signatures from anon;
revoke all on public.corp_signature_requests from anon;
revoke all on public.corp_documents from anon;

-- ---------------------------------------------------------------------
-- Tokens
-- ---------------------------------------------------------------------

-- Built-in sha256(), not pgcrypto's digest(): pgcrypto lives in the
-- extensions schema, which a pinned search_path cannot see.
create or replace function app.corp_token_hash(p_token text)
returns text language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex');
$$;

-- 256 bits of randomness in hex. gen_random_bytes() is pgcrypto and so
-- out of reach here; two v4 UUIDs give 122 bits each from the same CSPRNG.
create or replace function app.corp_new_token()
returns text language sql volatile
set search_path = pg_catalog, pg_temp as $$
  select replace(gen_random_uuid()::text, '-', '')
      || replace(gen_random_uuid()::text, '-', '');
$$;

-- ---------------------------------------------------------------------
-- Issuing (staff)
-- ---------------------------------------------------------------------

-- Returns the raw token exactly once. There is no way to read it back,
-- by design: if the secretary loses it they issue a new one, which
-- retires the old.
create or replace function public.corp_create_signing_link(
  p_signature_id uuid,
  p_valid_days integer default 14,
  p_email text default null)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  s public.corp_signatures;
  v_token text;
begin
  select * into s from public.corp_signatures where id = p_signature_id;
  if s.id is null then
    raise exception 'Signature not found' using errcode = 'P0002';
  end if;
  if not app.can_write(s.org_id) then
    raise exception 'Not permitted to issue a signing link' using errcode = '42501';
  end if;
  if s.status <> 'pending' then
    raise exception 'That line is already %', s.status using errcode = '22023';
  end if;

  v_token := app.corp_new_token();

  -- One live link per signature: issuing a new one retires the old.
  update public.corp_signing_links
     set revoked_at = now()
   where signature_id = p_signature_id
     and used_at is null and revoked_at is null;

  insert into public.corp_signing_links
    (org_id, signature_id, token_hash, expires_at, sent_to_email, created_by)
  values (s.org_id, p_signature_id, app.corp_token_hash(v_token),
          now() + make_interval(days => greatest(least(coalesce(p_valid_days, 14), 90), 1)),
          p_email, auth.uid());

  return v_token;
end;
$$;

-- ---------------------------------------------------------------------
-- Redeeming (no account)
-- ---------------------------------------------------------------------

-- Every unusable state is named rather than collapsed into "invalid":
-- telling somebody their link expired saves them hunting for a problem
-- that is not there. The document body is withheld unless it can
-- actually be signed.
create or replace function public.corp_open_signing_link(p_token text)
returns table (
  state text,
  company_name text,
  document_title text,
  document_body text,
  signatory_name text,
  capacity text,
  expires_at timestamptz)
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  l public.corp_signing_links;
  s public.corp_signatures;
  r public.corp_signature_requests;
  d public.corp_documents;
  e public.corp_entities;
  p public.corp_persons;
  v_state text;
begin
  select * into l from public.corp_signing_links
   where token_hash = app.corp_token_hash(p_token);

  if l.id is null then
    return query select 'invalid'::text, null::text, null::text, null::text,
                        null::text, null::text, null::timestamptz;
    return;
  end if;

  select * into s from public.corp_signatures where id = l.signature_id;
  select * into r from public.corp_signature_requests where id = s.request_id;
  select * into d from public.corp_documents where id = r.document_id;
  select * into e from public.corp_entities where id = d.entity_id;
  select * into p from public.corp_persons where id = s.person_id;

  v_state := case
    when l.revoked_at is not null then 'revoked'
    when l.used_at is not null then 'used'
    when l.expires_at < now() then 'expired'
    when r.is_withdrawn then 'withdrawn'
    when s.status <> 'pending' then 'already_signed'
    -- The text must still be the text that was circulated.
    when app.corp_body_hash(d.body) <> r.body_sha256 then 'changed'
    else 'open'
  end;

  -- Opening is itself worth recording: it is the only evidence the link
  -- reached anybody.
  update public.corp_signing_links
     set opened_at = coalesce(opened_at, now()),
         ip_address = coalesce(ip_address, nullif(split_part(coalesce(
           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet),
         user_agent = coalesce(user_agent, app.request_header('user-agent'))
   where id = l.id;

  return query select v_state, e.name, d.title,
    -- The text is only handed over when it can actually be signed.
    case when v_state = 'open' then d.body else null end,
    p.full_name, s.capacity, l.expires_at;
end;
$$;

-- The act of signing. Every check that corp_sign_document makes for a
-- signed-in signer is made here too, plus the link's own state.
create or replace function public.corp_sign_with_link(
  p_token text,
  p_signed_name text)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  l public.corp_signing_links;
  s public.corp_signatures;
  r public.corp_signature_requests;
  d public.corp_documents;
  v_hash text;
begin
  if coalesce(btrim(p_signed_name), '') = '' then
    raise exception 'A signature needs a name' using errcode = '22023';
  end if;

  select * into l from public.corp_signing_links
   where token_hash = app.corp_token_hash(p_token);
  if l.id is null then
    raise exception 'This link is not valid' using errcode = '42501';
  end if;
  if l.revoked_at is not null or l.used_at is not null then
    raise exception 'This link has already been used' using errcode = '22023';
  end if;
  if l.expires_at < now() then
    raise exception 'This link has expired' using errcode = '22023';
  end if;

  select * into s from public.corp_signatures where id = l.signature_id;
  if s.status <> 'pending' then
    raise exception 'That line is already %', s.status using errcode = '22023';
  end if;

  select * into r from public.corp_signature_requests where id = s.request_id;
  if r.is_withdrawn then
    raise exception 'The signature request has been withdrawn' using errcode = '22023';
  end if;

  select * into d from public.corp_documents where id = r.document_id;
  v_hash := app.corp_body_hash(d.body);
  if v_hash <> r.body_sha256 then
    raise exception
      'The document has changed since this link was sent; ask for a new one'
      using errcode = '23514';
  end if;

  update public.corp_signatures
     set status = 'signed',
         signed_at = now(),
         signed_name = btrim(p_signed_name),
         body_sha256_at_signing = v_hash,
         ip_address = nullif(split_part(coalesce(
           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet,
         user_agent = app.request_header('user-agent'),
         -- Deliberately null: nobody was signed in. The link is the
         -- attribution, and it is recorded beside it.
         signed_by = null
   where id = l.signature_id;

  update public.corp_signing_links set used_at = now() where id = l.id;

  return 'signed';
end;
$$;

-- ---------------------------------------------------------------------
-- Grants
--
-- The standing rule in this schema is that no SECURITY DEFINER function
-- is reachable by anon. These two are the only exceptions in the whole
-- database, and supabase/tests/statutory.sql asserts that by name — so a
-- third one cannot appear by accident.
-- ---------------------------------------------------------------------

do $do$
declare fn record;
begin
  for fn in
    select n.nspname as s, p.proname as f,
           pg_get_function_identity_arguments(p.oid) as a
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app') and p.prosecdef
       and p.proname not in ('create_gl_entry_internal', 'run_daily_jobs',
                             'write_audit_log', 'next_document_number_internal',
                             'corp_open_signing_link', 'corp_sign_with_link')
  loop
    execute format('revoke all on function %I.%I(%s) from public, anon', fn.s, fn.f, fn.a);
    execute format('grant execute on function %I.%I(%s) to authenticated, service_role', fn.s, fn.f, fn.a);
  end loop;
end
$do$;

revoke all on function public.corp_open_signing_link(text) from public;
revoke all on function public.corp_sign_with_link(text, text) from public;
grant execute on function public.corp_open_signing_link(text)
  to anon, authenticated, service_role;
grant execute on function public.corp_sign_with_link(text, text)
  to anon, authenticated, service_role;
