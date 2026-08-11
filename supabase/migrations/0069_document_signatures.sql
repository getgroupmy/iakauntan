-- =====================================================================
-- iAkauntan :: 0069 collecting signatures on a resolution
--
-- This is NOT a digital signature under the Digital Signature Act 1997:
-- there is no certificate from a licensed certification authority and no
-- PKI. It is an electronic signature under the Electronic Commerce Act
-- 2006 — a recorded act of signing, attributable to a person, with the
-- document fixed at the moment they signed.
--
-- What makes it worth anything is the hash. The body is digested when
-- the request is raised and again as each person signs, so a later edit
-- to the text is detectable rather than merely disapproved of.
-- =====================================================================

create type app.signature_status as enum
  ('pending', 'signed', 'declined', 'withdrawn');

create table public.corp_signature_requests (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  document_id uuid not null references public.corp_documents (id) on delete cascade,

  -- The document as it stood when signing opened. Everything is measured
  -- against this.
  body_sha256 text not null,
  requested_by uuid references auth.users (id),
  requested_at timestamptz not null default now(),
  due_on date,
  note text,

  is_withdrawn boolean not null default false,
  withdrawn_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (document_id)
);

create table public.corp_signatures (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  request_id uuid not null references public.corp_signature_requests (id)
    on delete cascade,
  person_id uuid not null references public.corp_persons (id) on delete restrict,

  capacity text,                    -- Director, Secretary, Member…
  status app.signature_status not null default 'pending',
  signed_at timestamptz,
  -- The typed name, which is what an electronic signature is here.
  signed_name text,
  decline_reason text,

  -- The evidence. Written by the database at the moment of signing, not
  -- supplied by the caller: a signature record the signer can write is
  -- not evidence of anything.
  body_sha256_at_signing text,
  ip_address inet,
  user_agent text,
  signed_by uuid references auth.users (id),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (request_id, person_id)
);

create index on public.corp_signature_requests (org_id, requested_at desc);
create index on public.corp_signatures (request_id);

do $do$
declare t text;
begin
  foreach t in array array['corp_signature_requests', 'corp_signatures'] loop
    execute format(
      'create trigger set_updated_at before update on public.%I
         for each row execute function app.set_updated_at()', t);
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for select
         using (app.can_read_ledger(org_id) or app.can_write(org_id))',
      t || '_select', t);
    execute format(
      'create policy %I on public.%I for all
         using (app.can_write(org_id))
         with check (app.can_write(org_id) and app.has_module(org_id, ''secretarial''))',
      t || '_write', t);
    execute format(
      'create trigger audit_changes after insert or update or delete on public.%I
         for each row execute function app.write_audit_log()', t);
  end loop;
end
$do$;

-- digest() is pgcrypto, which lives in the extensions schema and is
-- therefore not on a pinned search_path. sha256() has been in pg_catalog
-- since Postgres 11: no extension, and nothing to shadow it.
create or replace function app.corp_body_hash(p_body text)
returns text language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select encode(sha256(convert_to(coalesce(p_body, ''), 'UTF8')), 'hex');
$$;

create or replace function public.corp_request_signatures(
  p_document_id uuid, p_person_ids uuid[], p_capacities text[] default null,
  p_due_on date default null, p_note text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  d public.corp_documents;
  v_id uuid;
  i integer;
begin
  select * into d from public.corp_documents where id = p_document_id;
  if d.id is null then
    raise exception 'Document not found' using errcode = 'P0002';
  end if;
  if not app.can_write(d.org_id) then
    raise exception 'Not permitted to request signatures' using errcode = '42501';
  end if;
  if coalesce(array_length(p_person_ids, 1), 0) = 0 then
    raise exception 'Nobody to sign' using errcode = '22023';
  end if;

  insert into public.corp_signature_requests
    (org_id, document_id, body_sha256, requested_by, due_on, note)
  values (d.org_id, d.id, app.corp_body_hash(d.body), auth.uid(), p_due_on, p_note)
  on conflict (document_id) do update
    set body_sha256 = app.corp_body_hash(d.body),
        due_on = excluded.due_on, note = excluded.note,
        is_withdrawn = false, withdrawn_at = null
  returning id into v_id;

  for i in 1 .. array_length(p_person_ids, 1) loop
    insert into public.corp_signatures
      (org_id, request_id, person_id, capacity)
    values (d.org_id, v_id, p_person_ids[i],
            case when p_capacities is null then null else p_capacities[i] end)
    on conflict (request_id, person_id) do nothing;
  end loop;

  return v_id;
end;
$$;

create or replace function public.corp_sign_document(
  p_signature_id uuid, p_signed_name text)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  s public.corp_signatures;
  r public.corp_signature_requests;
  d public.corp_documents;
  v_now_hash text;
begin
  select * into s from public.corp_signatures where id = p_signature_id;
  if s.id is null then
    raise exception 'Signature not found' using errcode = 'P0002';
  end if;
  if not app.can_write(s.org_id) then
    raise exception 'Not permitted to sign' using errcode = '42501';
  end if;
  if s.status <> 'pending' then
    raise exception 'This signature is already %', s.status using errcode = '22023';
  end if;
  if coalesce(btrim(p_signed_name), '') = '' then
    raise exception 'A signature needs a name' using errcode = '22023';
  end if;

  select * into r from public.corp_signature_requests where id = s.request_id;
  if r.is_withdrawn then
    raise exception 'The signature request has been withdrawn' using errcode = '22023';
  end if;

  select * into d from public.corp_documents where id = r.document_id;
  v_now_hash := app.corp_body_hash(d.body);

  -- The document must be the one that was circulated. Signing a text
  -- that has changed since the request is the failure this whole
  -- arrangement exists to prevent.
  if v_now_hash <> r.body_sha256 then
    raise exception
      'The document has changed since signing opened; withdraw the request '
      'and raise it again' using errcode = '23514';
  end if;

  update public.corp_signatures
     set status = 'signed',
         signed_at = now(),
         signed_name = btrim(p_signed_name),
         body_sha256_at_signing = v_now_hash,
         ip_address = nullif(split_part(coalesce(
           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet,
         user_agent = app.request_header('user-agent'),
         signed_by = auth.uid()
   where id = p_signature_id;
end;
$$;

-- Whether what is on screen is still what was signed. Recomputed on
-- every read rather than stored, because a stored "verified" flag is a
-- claim about the past that nothing keeps true.
create or replace function public.corp_signature_state(p_document_id uuid)
returns table (
  signature_id uuid,
  person_name text,
  capacity text,
  status app.signature_status,
  signed_at timestamptz,
  signed_name text,
  document_unchanged boolean)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  d public.corp_documents;
  v_hash text;
begin
  select * into d from public.corp_documents where id = p_document_id;
  if d.id is null then
    raise exception 'Document not found' using errcode = 'P0002';
  end if;
  if not (app.can_read_ledger(d.org_id) or app.can_write(d.org_id)) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  v_hash := app.corp_body_hash(d.body);

  return query
  select s.id, p.full_name, s.capacity, s.status, s.signed_at, s.signed_name,
         case when s.status = 'signed'
              then s.body_sha256_at_signing = v_hash
              else null end
    from public.corp_signatures s
    join public.corp_signature_requests r on r.id = s.request_id
    join public.corp_persons p on p.id = s.person_id
   where r.document_id = p_document_id
   order by p.full_name;
end;
$$;

do $do$
declare fn record;
begin
  for fn in
    select n.nspname as s, p.proname as f,
           pg_get_function_identity_arguments(p.oid) as a
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app') and p.prosecdef
       and p.proname not in ('create_gl_entry_internal', 'run_daily_jobs',
                             'write_audit_log', 'next_document_number_internal')
  loop
    execute format('revoke all on function %I.%I(%s) from public, anon', fn.s, fn.f, fn.a);
    execute format('grant execute on function %I.%I(%s) to authenticated, service_role', fn.s, fn.f, fn.a);
  end loop;
end
$do$;
