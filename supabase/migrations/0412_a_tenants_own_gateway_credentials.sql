-- ---------------------------------------------------------------------
-- 0412  A tenant's own gateway credentials, which nothing can read
-- ---------------------------------------------------------------------
--
-- `payment_gateways` carries forty-odd acquirers, `billplz-checkout`
-- and `billplz-callback` are deployed, and `gateway_payments.sql`
-- asserts the money. All of it serves **`platform_invoices`** —
-- iAkauntan billing its own subscribers. The table's primary key is
-- `code` alone; there is no `org_id` on it, and there was never meant
-- to be. `docs/gaps-against-akaunting.md` says this the right way round
-- and names what is missing: per-organization credentials, a pay route
-- on the shared invoice link, and a receipt posted when the callback
-- confirms.
--
-- This is the first of those three, and it is the one that has to be
-- right before the other two are worth writing, because it is where a
-- tenant's acquirer secret lives.
--
-- ## The shape, and why it is `0107`'s
--
-- `einvoice_credentials` holds LHDN client secrets and certificate
-- private keys. It has RLS enabled with **no policies at all** and
-- every privilege revoked from `anon` and `authenticated`, so the two
-- barriers have to fail together before a secret is readable by anyone
-- holding the publishable key — and that key ships in the web bundle.
-- Writing is a SECURITY DEFINER function guarded by `app.can_admin`;
-- reading, for a screen, is a status function that answers "is one set"
-- and never hands the secret back.
--
-- An acquirer API key is the same kind of thing: it can take money.
-- Same shape, deliberately, down to the two barriers.
--
-- ## The three secrets an acquirer needs
--
-- Named generically because forty-odd acquirers are registered and they
-- do not agree on vocabulary:
--
--   * `api_key`         — Billplz's secret key, toyyibPay's user secret,
--                         Stripe's `sk_`. What signs a request.
--   * `collection_ref`  — Billplz's collection id, toyyibPay's category
--                         code. Which pot a bill lands in. Not a secret,
--                         and stored beside the key because it is
--                         useless apart from it.
--   * `signature_key`   — what a callback is verified against.
--                         Billplz's X-Signature key. Without it a
--                         forged callback marks an invoice paid.
--
-- ## Sandbox and production, both at once
--
-- `0107` learned this the hard way: with the environment as a column on
-- a row an organization only has one of, saving production credentials
-- destroys the sandbox ones, and "prove it in sandbox, then go live"
-- becomes a one-way door. The key here is
-- `(org_id, gateway_code, mode)`.
--
-- ## A null secret leaves the stored one alone
--
-- `0107`'s other lesson, and the one its test caught on the first run:
-- the merge happens *before* the insert and not in the `on conflict`
-- clause, because `api_key` is NOT NULL and Postgres validates the
-- proposed row before it looks for a conflict — so the obvious
-- `coalesce(excluded.api_key, ...)` in the update arm never runs.
--
-- Without the merge, correcting a typo in a collection id would blank
-- the key, and the next customer to click Pay would get an
-- authentication failure with nothing on screen to explain it.
--
-- ## What this does not do yet
--
-- Nothing charges anybody. There is no checkout call and no callback
-- for a tenant's invoice, and `docs/gaps-against-akaunting.md` still
-- lists taking payment as open. This is the credentials, with their
-- assertions, and the honest description of it is a foundation rather
-- than a feature.
-- ---------------------------------------------------------------------

create table if not exists public.org_payment_gateways (
  org_id         uuid not null references public.organizations(id) on delete cascade,
  gateway_code   text not null references public.payment_gateways(code),
  mode           text not null default 'sandbox'
                   check (mode in ('sandbox', 'production')),
  api_key        text not null,
  collection_ref text,
  signature_key  text,
  is_active      boolean not null default false,
  updated_by     uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  primary key (org_id, gateway_code, mode)
);

comment on table public.org_payment_gateways is
  'An organization''s own acquirer credentials, for collecting from its '
  'own customers. Distinct from public.payment_gateways, which is the '
  'platform''s catalogue and settles platform_invoices. RLS is enabled '
  'with no policies and every client grant is revoked, so a secret here '
  'is reachable only through a SECURITY DEFINER function or the service '
  'role — the same two barriers 0107 gave the LHDN credentials.';

alter table public.org_payment_gateways enable row level security;

-- Both barriers. Supabase's default ACL hands the client roles every
-- privilege on a new table in `public`; RLS with no policies makes that
-- inert, and a single layer is not enough in front of a key that can
-- take money. `0401` revoked the write privileges from `anon` across
-- the schema; SELECT is the one that matters here and is named.
revoke all on public.org_payment_gateways from anon, authenticated;

do $do$
begin
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.org_payment_gateways'::regclass
                    and tgname = 'set_updated_at') then
    create trigger set_updated_at before update on public.org_payment_gateways
      for each row execute function app.set_updated_at();
  end if;
end
$do$;

-- ---------------------------------------------------------------------
-- Setting them
-- ---------------------------------------------------------------------
create or replace function public.set_org_payment_gateway(
  p_org_id         uuid,
  p_gateway        text,
  p_mode           text default 'sandbox',
  p_api_key        text default null,
  p_collection_ref text default null,
  p_signature_key  text default null,
  p_is_active      boolean default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
declare
  v_key    text;
  v_ref    text;
  v_sig    text;
  v_active boolean;
begin
  -- `can_admin`, not `can_write`: these are the keys to taking money in
  -- this company's name.
  if not app.can_admin(p_org_id) then
    raise exception
      'Only an administrator can set this company''s payment credentials'
      using errcode = '42501';
  end if;

  if p_mode not in ('sandbox', 'production') then
    raise exception 'Mode must be sandbox or production, not %', p_mode
      using errcode = '23514';
  end if;

  if not exists (select 1 from public.payment_gateways g
                  where g.code = p_gateway) then
    raise exception '% is not an acquirer this platform knows about.',
      p_gateway using errcode = '23503';
  end if;

  select c.api_key, c.collection_ref, c.signature_key, c.is_active
    into v_key, v_ref, v_sig, v_active
    from public.org_payment_gateways c
   where c.org_id = p_org_id and c.gateway_code = p_gateway
     and c.mode = p_mode;

  -- Before the insert, not in the `on conflict` arm: `api_key` is NOT
  -- NULL and the proposed row is validated before the conflict is
  -- looked for, so a coalesce in the update arm never runs. `0107`
  -- found this with a failing test rather than by reading the manual.
  v_key    := coalesce(nullif(trim(coalesce(p_api_key, '')), ''), v_key);
  v_ref    := coalesce(nullif(trim(coalesce(p_collection_ref, '')), ''), v_ref);
  v_sig    := coalesce(nullif(trim(coalesce(p_signature_key, '')), ''), v_sig);
  v_active := coalesce(p_is_active, v_active, false);

  if v_key is null then
    raise exception
      'An API key is required the first time % is set up for %',
      p_gateway, p_mode using errcode = '23514';
  end if;

  insert into public.org_payment_gateways
    (org_id, gateway_code, mode, api_key, collection_ref, signature_key,
     is_active, updated_by)
  values (p_org_id, p_gateway, p_mode, v_key, v_ref, v_sig, v_active,
          auth.uid())
  on conflict (org_id, gateway_code, mode) do update
     set api_key        = excluded.api_key,
         collection_ref = excluded.collection_ref,
         signature_key  = excluded.signature_key,
         is_active      = excluded.is_active,
         updated_by     = excluded.updated_by,
         updated_at     = now();
end
$fn$;

create or replace function public.clear_org_payment_gateway(
  p_org_id  uuid,
  p_gateway text,
  p_mode    text default 'sandbox')
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
begin
  if not app.can_admin(p_org_id) then
    raise exception
      'Only an administrator can remove this company''s payment credentials'
      using errcode = '42501';
  end if;

  delete from public.org_payment_gateways c
   where c.org_id = p_org_id and c.gateway_code = p_gateway
     and c.mode = p_mode;
end
$fn$;

-- ---------------------------------------------------------------------
-- Reading whether one is set, and never what it is
-- ---------------------------------------------------------------------
--
-- The screen needs to know which acquirers this company has set up, in
-- which mode, and whether the callback can be verified. It does not
-- need the key, and there is no version of this that returns one: a
-- function that hands a secret to a client role is the same exposure as
-- a policy that does, arriving through a different door.
create or replace function public.org_payment_gateway_status(p_org_id uuid)
returns table (
  gateway_code    text,
  gateway_name    text,
  mode            text,
  is_active       boolean,
  has_api_key     boolean,
  has_signature_key boolean,
  collection_ref  text,
  updated_at      timestamptz)
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
begin
  if not app.can_admin(p_org_id) then
    raise exception
      'Only an administrator can see this company''s payment set-up'
      using errcode = '42501';
  end if;

  return query
    select c.gateway_code, g.name, c.mode, c.is_active,
           c.api_key is not null,
           c.signature_key is not null,
           -- Not a secret: a collection id is useless without the key,
           -- and a person checking their set-up needs to see which pot
           -- they pointed at.
           c.collection_ref,
           c.updated_at
      from public.org_payment_gateways c
      join public.payment_gateways g on g.code = c.gateway_code
     where c.org_id = p_org_id
     order by c.gateway_code, c.mode;
end
$fn$;

revoke all on function public.set_org_payment_gateway(
  uuid, text, text, text, text, text, boolean) from public, anon;
grant execute on function public.set_org_payment_gateway(
  uuid, text, text, text, text, text, boolean) to authenticated;

revoke all on function public.clear_org_payment_gateway(uuid, text, text)
  from public, anon;
grant execute on function public.clear_org_payment_gateway(uuid, text, text)
  to authenticated;

revoke all on function public.org_payment_gateway_status(uuid) from public, anon;
grant execute on function public.org_payment_gateway_status(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_policies int; v_privs text; v_src text;
begin
  if not (select relrowsecurity from pg_class
           where oid = 'public.org_payment_gateways'::regclass) then
    raise exception
      'FAIL 0412: row-level security is off on a table holding acquirer '
      'API keys';
  end if;

  select count(*) into v_policies from pg_policy p
    where p.polrelid = 'public.org_payment_gateways'::regclass;
  if v_policies <> 0 then
    raise exception
      'FAIL 0412: % policies on org_payment_gateways -- this table is '
      'reached through SECURITY DEFINER functions and the service role, '
      'and a policy is a third door nobody asked for', v_policies;
  end if;

  select string_agg(distinct privilege_type, ', ' order by privilege_type)
    into v_privs
    from information_schema.role_table_grants
   where grantee in ('anon', 'authenticated')
     and table_schema = 'public' and table_name = 'org_payment_gateways';
  if v_privs is not null then
    raise exception
      'FAIL 0412: a client role holds % on org_payment_gateways. RLS '
      'makes it inert and that is one layer; this table wants two.',
      v_privs;
  end if;

  -- The status function must not be able to return a secret, which is
  -- a fact about its signature and not about its body.
  if exists (
    select 1 from pg_proc p
     cross join lateral unnest(coalesce(p.proargnames, '{}')) as a(name)
     where p.oid = 'public.org_payment_gateway_status(uuid)'::regprocedure
       and a.name in ('api_key', 'signature_key'))
  then
    raise exception
      'FAIL 0412: org_payment_gateway_status returns a secret';
  end if;

  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = 'public.org_payment_gateway_status(uuid)'::regprocedure;
  if v_src ~ 'c\.api_key(?!\s+is not null)'
     or v_src ~ 'c\.signature_key(?!\s+is not null)' then
    raise exception
      'FAIL 0412: the status function reads a secret for something '
      'other than asking whether it is there';
  end if;

  raise notice
    '0412: a tenant can hold acquirer credentials that nothing reads back';
end
$do$;
