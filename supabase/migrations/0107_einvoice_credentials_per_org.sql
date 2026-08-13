-- =====================================================================
-- iAkauntan :: 0107 letting an organization actually set its LHDN
-- credentials
--
-- `einvoice_credentials` has been right in every respect except the one
-- that matters: nothing could write to it. RLS is enabled with no
-- policies — correct for a table holding client secrets and certificate
-- private keys, since it means only the service role may read — but the
-- Settings screen wrote to the table *directly*, so every save was
-- refused:
--
--   new row violates row-level security policy for table
--   "einvoice_credentials"
--
-- Which is why the table is empty. Not "nobody configured it" but
-- "nobody could". e-Invoice, the most statutory thing in this system,
-- has never been reachable.
--
-- Worse, the screen updated `organizations` first and the credentials
-- after, so a failed save left the organization flagged
-- `einvoice_enabled` with a `client_id` recorded and no secret stored
-- anywhere — a document set live against a submitter that cannot
-- authenticate.
--
-- ---------------------------------------------------------------------
-- Sandbox and production, both at once
--
-- The primary key was `org_id` alone, so `environment` was a column on a
-- row an organization only had one of: saving production credentials
-- destroyed the sandbox ones. That makes the sensible order of work —
-- prove it in sandbox, then go live — a one-way door, and leaves nowhere
-- to test from once live.
--
-- `(org_id, environment)` instead. Each organization holds both, and
-- `organizations.einvoice_environment` decides which is in force.
--
-- ---------------------------------------------------------------------
-- Two barriers, not one
--
-- `anon` and `authenticated` hold every privilege on this table —
-- INSERT, SELECT, UPDATE, DELETE, TRUNCATE — from Supabase's default
-- grants. They are inert only because RLS refuses them. That is a single
-- point of failure guarding client secrets and private keys: a migration
-- that disabled RLS, a restore that dropped it, or a toggle in the
-- dashboard would make every organization's credentials readable by
-- anyone holding the publishable key, which ships in the web bundle.
--
-- Revoked outright, so RLS and the grant have to fail together.
-- =====================================================================

-- ---------------------------------------------------------------------
-- One set of credentials per environment
--
-- Safe to swap outright: the table is empty, precisely because of the
-- bug this migration exists to fix.
-- ---------------------------------------------------------------------
alter table public.einvoice_credentials
  drop constraint if exists einvoice_credentials_pkey;
alter table public.einvoice_credentials
  add constraint einvoice_credentials_pkey primary key (org_id, environment);

revoke all on public.einvoice_credentials from anon, authenticated;

-- ---------------------------------------------------------------------
-- Writing them
--
-- SECURITY DEFINER, because the caller is deliberately unable to touch
-- the table. `can_admin` rather than `can_write`: these are the keys to
-- filing somebody's tax documents, not an invoice line.
--
-- A null secret leaves the stored one alone. Otherwise correcting a
-- typo in the client id would silently blank the secret, and the next
-- submission would fail authentication with nothing on screen to explain
-- it — which is close to what the old screen did.
--
-- That merge is done *before* the insert rather than in the ON CONFLICT
-- clause, and it has to be. `client_secret` is NOT NULL, and Postgres
-- validates the proposed row before it looks for a conflict — so the
-- obvious `coalesce(excluded.client_secret, ...)` in the update arm
-- never runs. It fails on the not-null check first. The test caught
-- that on its first run.
-- ---------------------------------------------------------------------
create or replace function public.set_einvoice_credentials(
  p_org_id uuid,
  p_environment text,
  p_client_id text,
  p_client_secret text default null,
  p_cert_pem text default null,
  p_cert_private_key_pem text default null,
  p_cert_serial_number text default null,
  p_cert_issuer_name text default null,
  p_cert_expires_at timestamptz default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_secret  text;
  v_cert    text;
  v_key     text;
  v_serial  text;
  v_issuer  text;
  v_expires timestamptz;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can set e-Invoice credentials'
      using errcode = '42501';
  end if;

  if p_environment not in ('sandbox', 'production') then
    raise exception 'Environment must be sandbox or production, not %',
      p_environment using errcode = '23514';
  end if;

  if coalesce(trim(p_client_id), '') = '' then
    raise exception 'A client id is required' using errcode = '23514';
  end if;

  select c.client_secret, c.cert_pem, c.cert_private_key_pem,
         c.cert_serial_number, c.cert_issuer_name, c.cert_expires_at
    into v_secret, v_cert, v_key, v_serial, v_issuer, v_expires
    from public.einvoice_credentials c
   where c.org_id = p_org_id and c.environment = p_environment;

  v_secret  := coalesce(nullif(trim(coalesce(p_client_secret, '')), ''), v_secret);
  v_cert    := coalesce(nullif(trim(coalesce(p_cert_pem, '')), ''), v_cert);
  v_key     := coalesce(nullif(trim(coalesce(p_cert_private_key_pem, '')), ''), v_key);
  v_serial  := coalesce(nullif(trim(coalesce(p_cert_serial_number, '')), ''), v_serial);
  v_issuer  := coalesce(nullif(trim(coalesce(p_cert_issuer_name, '')), ''), v_issuer);
  v_expires := coalesce(p_cert_expires_at, v_expires);

  if v_secret is null then
    raise exception
      'A client secret is required the first time credentials are set for %',
      p_environment using errcode = '23514';
  end if;

  insert into public.einvoice_credentials
    (org_id, environment, client_id, client_secret, cert_pem,
     cert_private_key_pem, cert_serial_number, cert_issuer_name,
     cert_expires_at, updated_by, updated_at)
  values (p_org_id, p_environment, trim(p_client_id), v_secret, v_cert,
          v_key, v_serial, v_issuer, v_expires, auth.uid(), now())
  on conflict (org_id, environment) do update
    set client_id            = excluded.client_id,
        client_secret        = excluded.client_secret,
        cert_pem             = excluded.cert_pem,
        cert_private_key_pem = excluded.cert_private_key_pem,
        cert_serial_number   = excluded.cert_serial_number,
        cert_issuer_name     = excluded.cert_issuer_name,
        cert_expires_at      = excluded.cert_expires_at,
        updated_by           = auth.uid(),
        updated_at           = now();
end;
$$;

-- ---------------------------------------------------------------------
-- Reading them back, without reading them
--
-- What a settings screen needs is whether a thing is set, not what it
-- is. The secret and the private key are never returned by anything an
-- organization can call — the only reader of those is the edge function,
-- through the service role.
--
-- Both environments always come back, configured or not, so the screen
-- can show that production is still empty rather than leaving somebody
-- to infer it from an absence.
-- ---------------------------------------------------------------------
create or replace function public.einvoice_credential_status(p_org_id uuid)
returns table (
  environment     text,
  is_current      boolean,
  client_id       text,
  has_secret      boolean,
  has_certificate boolean,
  cert_expires_at timestamptz,
  updated_at      timestamptz)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can see the e-Invoice setup'
      using errcode = '42501';
  end if;

  return query
  select e.env,
         e.env = coalesce(o.einvoice_environment, 'sandbox'),
         c.client_id,
         c.client_secret is not null,
         c.cert_pem is not null and c.cert_private_key_pem is not null,
         c.cert_expires_at,
         c.updated_at
    from (values ('sandbox'), ('production')) as e(env)
    cross join public.organizations o
    left join public.einvoice_credentials c
      on c.org_id = p_org_id and c.environment = e.env
   where o.id = p_org_id
   order by e.env desc;   -- sandbox first, which is where to start
end;
$$;

-- ---------------------------------------------------------------------
-- Taking them away
--
-- Separate from writing, because "remove the production credentials"
-- should not be reachable by accidentally saving an empty form — which
-- is exactly what the coalesce above prevents.
-- ---------------------------------------------------------------------
create or replace function public.clear_einvoice_credentials(
  p_org_id uuid, p_environment text)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can remove e-Invoice credentials'
      using errcode = '42501';
  end if;

  delete from public.einvoice_credentials
   where org_id = p_org_id and environment = p_environment;
end;
$$;

-- ---------------------------------------------------------------------
-- Reachability
--
-- Postgres grants EXECUTE to PUBLIC on a new function, so each one has
-- to be taken away before it is given back — the lesson 0080 exists for.
-- ---------------------------------------------------------------------
revoke all on function public.set_einvoice_credentials(
  uuid, text, text, text, text, text, text, text, timestamptz)
  from public, anon;
grant execute on function public.set_einvoice_credentials(
  uuid, text, text, text, text, text, text, text, timestamptz)
  to authenticated;

revoke all on function public.einvoice_credential_status(uuid) from public, anon;
grant execute on function public.einvoice_credential_status(uuid) to authenticated;

revoke all on function public.clear_einvoice_credentials(uuid, text)
  from public, anon;
grant execute on function public.clear_einvoice_credentials(uuid, text)
  to authenticated;
