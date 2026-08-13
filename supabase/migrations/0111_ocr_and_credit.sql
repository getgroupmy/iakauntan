-- =====================================================================
-- iAkauntan :: 0111 reading a receipt, and paying for having read it
--
-- Attachments landed in 0068 and a camera reached them in the app, so a
-- receipt can now be photographed and filed. Nothing reads it. This is
-- the machinery that does — and, because reading it costs money at a
-- provider, the machinery that decides who pays.
--
-- ---------------------------------------------------------------------
-- Off until somebody says otherwise
--
-- An expense receipt carries a supplier's name, an amount, sometimes a
-- customer's name, and on a hotel folio a person's movements. Sending
-- that to a third party is a decision an organization makes, not a
-- default it discovers. So there is no row per organization until an
-- administrator creates one, and no row means off — the same posture
-- 0107 takes with LHDN credentials, and for the same reason.
--
-- Three choices, not two: Claude vision, Google Document AI, or nothing.
-- `is_enabled = false` is the third, and it is where every organization
-- starts.
--
-- ---------------------------------------------------------------------
-- Whose key, and therefore whose bill
--
-- An organization may bring its own provider key, in which case the
-- charge lands on their account at Anthropic or Google and this system
-- never sees money change hands. Or they may use the platform's key, in
-- which case the platform pays the provider and recovers it from a
-- ringgit credit balance bought in advance.
--
-- Their own key is stored the way LHDN client secrets are: RLS on, no
-- policies at all, and the default grants to `anon` and `authenticated`
-- revoked outright, so the table needs both RLS and the grant to fail
-- together before a key is readable by anyone holding the publishable
-- key that ships in the web bundle. The service role reads it; nothing
-- else does, including the administrator who set it.
--
-- The *platform's* key is not in this database at all. It lives in the
-- edge function's secrets, next to RESEND_API_KEY and SCHEDULER_SECRET,
-- because a key that every tenant's scans run through has no business in
-- a table any migration or dashboard toggle could expose.
--
-- ---------------------------------------------------------------------
-- Credit in ringgit
--
-- Denominated in money rather than in scans, because the price per scan
-- is set by the platform and will move; a balance of "40 scans" bought
-- at one price and spent at another is an argument waiting to happen.
-- A balance of RM 40.00 is not.
--
-- The balance is a single row, taken with FOR UPDATE, and every movement
-- writes an append-only ledger line beside it. Neither is derived from
-- the other by hopeful arithmetic: the ledger is the history, the row is
-- the number, and they move inside one transaction or not at all.
--
-- The charge is taken *before* the provider is called and returned if
-- the call fails. Taking it afterwards means a crashed function is a
-- free scan; not returning it means a provider outage is a paid-for
-- nothing. Both directions are ledger lines, so the statement shows what
-- happened rather than a balance that quietly healed.
--
-- ---------------------------------------------------------------------
-- The top-up is an invoice, from a real company
--
-- Kabeer Holdings Sdn Bhd, registration 201901030189 (formerly
-- 1339519K), sells the credit. That is a supply between two companies
-- and it needs a document, so a top-up raises one: numbered, dated,
-- addressed, with the issuer's registration numbers on it.
--
-- It is deliberately not a `sales_documents` row. Those belong to a
-- tenant and post to a tenant's ledger; this one is the platform's
-- invoice *to* a tenant and posts to nobody's books here. Mixing them
-- would put Kabeer Holdings' revenue inside a customer's trial balance.
--
-- Two statutory points, both parked on purpose rather than guessed at:
--
--   * Service tax. `platform_issuer.sst_registered` is false and the
--     rate is carried on the setting rather than in the code, so the day
--     Kabeer Holdings registers, the number and the rate go in the
--     console and every invoice raised afterwards carries them. Nothing
--     already issued is rewritten.
--
--   * LHDN e-Invoice. These invoices are issued by the platform, not by
--     a tenant, so they are outside every submitter this system holds
--     credentials for. When Kabeer Holdings comes within the mandate it
--     needs its own credentials and its own submission path; this
--     migration records the invoice properly so that path has something
--     to submit, and claims nothing more than that.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What an organization has chosen
--
-- Readable by any member, because the app has to know whether to draw a
-- Scan button. There is nothing secret here — a provider name and two
-- flags. Writable only through the RPC below, which checks can_admin.
-- ---------------------------------------------------------------------
create table public.org_ocr_settings (
  org_id     uuid primary key references public.organizations (id) on delete cascade,
  is_enabled boolean not null default false,
  provider   text not null default 'claude'
    check (provider in ('claude', 'google')),
  key_source text not null default 'platform'
    check (key_source in ('platform', 'own')),
  updated_by uuid references auth.users (id),
  updated_at timestamptz not null default now()
);
alter table public.org_ocr_settings enable row level security;

comment on table public.org_ocr_settings is
  'Per-organization document scanning. Absent row means off, which is where every organization starts.';

create policy org_ocr_settings_read on public.org_ocr_settings
  for select to authenticated
  using (app.is_org_member(org_id) or app.is_platform_admin());

-- ---------------------------------------------------------------------
-- Their own key, if they brought one
--
-- Anthropic wants an API key. Google Document AI wants a service account
-- JSON plus the project, location and processor that identify which
-- processor to call — four separate things, none of which is a secret on
-- its own and all of which are useless without the fifth. They live
-- together so a half-configured processor is impossible.
--
-- Keyed by (org_id, provider) so switching provider to compare them does
-- not destroy the credentials for the one you switched away from.
-- ---------------------------------------------------------------------
create table public.org_ocr_credentials (
  org_id       uuid not null references public.organizations (id) on delete cascade,
  provider     text not null check (provider in ('claude', 'google')),
  api_key      text not null,
  project_id   text,
  location     text,
  processor_id text,
  updated_by   uuid references auth.users (id),
  updated_at   timestamptz not null default now(),
  primary key (org_id, provider)
);
alter table public.org_ocr_credentials enable row level security;
revoke all on public.org_ocr_credentials from anon, authenticated;

comment on table public.org_ocr_credentials is
  'Provider keys an organization supplied itself. RLS on with no policies and grants revoked: the service role reads these and nothing else does.';

-- ---------------------------------------------------------------------
-- The balance, and the history behind it
-- ---------------------------------------------------------------------
create table public.org_credits (
  org_id     uuid primary key references public.organizations (id) on delete cascade,
  balance    numeric(18, 2) not null default 0,
  currency   char(3) not null default 'MYR',
  updated_at timestamptz not null default now()
);
alter table public.org_credits enable row level security;

create policy org_credits_read on public.org_credits
  for select to authenticated
  using (app.is_org_member(org_id) or app.is_platform_admin());

create table public.credit_ledger (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  entry_type  text not null
    check (entry_type in ('topup', 'usage', 'refund', 'adjustment')),
  -- Signed: positive puts money in, negative takes it out. An
  -- adjustment can be either, which is why the sign lives here and not
  -- in the type.
  amount      numeric(18, 2) not null check (amount <> 0),
  balance_after numeric(18, 2) not null,
  description text not null,
  -- What caused it: a scan id, an invoice id, a platform admin's note.
  scan_id     uuid,
  invoice_id  uuid,
  created_by  uuid references auth.users (id),
  created_at  timestamptz not null default now()
);
alter table public.credit_ledger enable row level security;
create index on public.credit_ledger (org_id, created_at desc);

comment on table public.credit_ledger is
  'Append-only. Every movement of a credit balance, including the refund of a scan whose provider call failed.';

create policy credit_ledger_read on public.credit_ledger
  for select to authenticated
  using (app.can_read_ledger(org_id) or app.is_platform_admin());

-- ---------------------------------------------------------------------
-- The platform's invoice for a top-up
--
-- Every party detail is snapshotted rather than joined. An invoice is a
-- statement about a moment: if the customer renames itself or the issuer
-- registers for service tax next year, the document already issued has
-- to keep saying what it said.
-- ---------------------------------------------------------------------
create table public.platform_invoices (
  id          uuid primary key default gen_random_uuid(),
  invoice_no  text not null unique,
  org_id      uuid not null references public.organizations (id) on delete restrict,
  issue_date  date not null default current_date,
  currency    char(3) not null default 'MYR',

  issuer_name                text not null,
  issuer_registration_no     text,
  issuer_old_registration_no text,
  issuer_sst_no              text,
  issuer_address             text,

  bill_to_name            text not null,
  bill_to_registration_no  text,
  bill_to_tin             text,
  bill_to_address         text,

  description   text not null,
  subtotal      numeric(18, 2) not null check (subtotal >= 0),
  tax_rate      numeric(6, 3) not null default 0,
  tax_amount    numeric(18, 2) not null default 0,
  total_amount  numeric(18, 2) not null,

  status     text not null default 'issued'
    check (status in ('issued', 'paid', 'void')),
  paid_at    timestamptz,
  paid_note  text,
  notes      text,
  issued_by  uuid references auth.users (id),
  created_at timestamptz not null default now()
);
alter table public.platform_invoices enable row level security;
create index on public.platform_invoices (org_id, issue_date desc);

comment on table public.platform_invoices is
  'Issued by the platform operator to a tenant, for credit sold. Not a sales_documents row: it belongs to nobody''s books in this system.';

-- The customer may read their own; the platform reads all. Neither may
-- write — issuing goes through platform_topup_credit().
create policy platform_invoices_read on public.platform_invoices
  for select to authenticated
  using (app.can_admin(org_id) or app.is_platform_admin());

-- ---------------------------------------------------------------------
-- One scan
--
-- Kept whether it worked or not, because "why was I charged" and "why
-- did nothing come back" are the same question asked twice and both need
-- the same row to answer them.
-- ---------------------------------------------------------------------
create table public.ocr_scans (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  attachment_id uuid references public.attachments (id) on delete set null,
  storage_path  text not null,
  provider      text not null,
  key_source    text not null,
  status        text not null default 'pending'
    check (status in ('pending', 'ok', 'failed')),
  amount_charged numeric(18, 2) not null default 0,
  refunded      boolean not null default false,
  extracted     jsonb,
  error         text,
  requested_by  uuid references auth.users (id),
  created_at    timestamptz not null default now(),
  finished_at   timestamptz
);
alter table public.ocr_scans enable row level security;
create index on public.ocr_scans (org_id, created_at desc);
create index on public.ocr_scans (attachment_id);

create policy ocr_scans_read on public.ocr_scans
  for select to authenticated
  using (app.can_write(org_id) or app.can_read_ledger(org_id)
         or app.is_platform_admin());

-- ---------------------------------------------------------------------
-- What the platform charges
--
-- On `platform_settings` rather than a table of its own, so it is edited
-- in the console that already exists, and flat so the console's
-- "key: value" editor can round-trip it.
-- ---------------------------------------------------------------------
insert into public.platform_settings (key, value, description) values
  ('ocr_pricing',
   '{"claude": 0.30, "google": 0.20, "currency": "MYR"}',
   'Ringgit charged per document scan when the tenant uses the platform key'),
  ('platform_issuer',
   '{"name": "Kabeer Holdings Sdn Bhd",
     "registration_no": "201901030189",
     "old_registration_no": "1339519K",
     "sst_registered": false,
     "sst_no": "",
     "sst_rate": 8,
     "address": "",
     "invoice_prefix": "KH"}',
   'The company that issues credit top-up invoices, and the tax it charges on them')
on conflict (key) do nothing;

create or replace function app.ocr_price(p_provider text)
returns numeric language sql stable
set search_path = public, pg_temp as $$
  select coalesce(
    (select (s.value ->> p_provider)::numeric
       from public.platform_settings s where s.key = 'ocr_pricing'),
    0);
$$;

-- ---------------------------------------------------------------------
-- Moving the balance
--
-- Every caller goes through here, so the lock, the sign, the ledger line
-- and the running total cannot come apart. FOR UPDATE on the balance row
-- serialises two scans started at the same instant; without it both read
-- the same balance and both think there is enough.
-- ---------------------------------------------------------------------
create or replace function app.move_credit(
  p_org_id      uuid,
  p_entry_type  text,
  p_amount      numeric,
  p_description text,
  p_scan_id     uuid default null,
  p_invoice_id  uuid default null,
  p_require_funds boolean default false)
returns numeric
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_balance numeric(18, 2);
begin
  insert into public.org_credits (org_id) values (p_org_id)
  on conflict (org_id) do nothing;

  select c.balance into v_balance
    from public.org_credits c
   where c.org_id = p_org_id
     for update;

  if p_require_funds and v_balance + p_amount < 0 then
    raise exception
      'Not enough scanning credit: RM % left, RM % needed. Top up from the platform console.',
      to_char(v_balance, 'FM999999990.00'),
      to_char(-p_amount, 'FM999999990.00')
      using errcode = '23514';
  end if;

  v_balance := v_balance + p_amount;

  update public.org_credits
     set balance = v_balance, updated_at = now()
   where org_id = p_org_id;

  insert into public.credit_ledger
    (org_id, entry_type, amount, balance_after, description,
     scan_id, invoice_id, created_by)
  values (p_org_id, p_entry_type, p_amount, v_balance, p_description,
          p_scan_id, p_invoice_id, auth.uid());

  return v_balance;
end;
$$;

-- ---------------------------------------------------------------------
-- Choosing a provider, and switching it off again
-- ---------------------------------------------------------------------
create or replace function public.set_ocr_settings(
  p_org_id     uuid,
  p_enabled    boolean,
  p_provider   text default 'claude',
  p_key_source text default 'platform')
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can turn document scanning on'
      using errcode = '42501';
  end if;
  if p_provider not in ('claude', 'google') then
    raise exception 'Unknown scanning provider %', p_provider
      using errcode = '23514';
  end if;
  if p_key_source not in ('platform', 'own') then
    raise exception 'A key comes from the platform or from you, not %',
      p_key_source using errcode = '23514';
  end if;

  -- Switching on with your own key, having never supplied one, would
  -- otherwise fail at the first scan rather than at the moment somebody
  -- could still do something about it.
  if p_enabled and p_key_source = 'own'
     and not exists (select 1 from public.org_ocr_credentials c
                      where c.org_id = p_org_id and c.provider = p_provider) then
    raise exception
      'Add your % key before switching scanning on with it', p_provider
      using errcode = '23514';
  end if;

  insert into public.org_ocr_settings
    (org_id, is_enabled, provider, key_source, updated_by, updated_at)
  values (p_org_id, p_enabled, p_provider, p_key_source, auth.uid(), now())
  on conflict (org_id) do update
    set is_enabled = excluded.is_enabled,
        provider   = excluded.provider,
        key_source = excluded.key_source,
        updated_by = auth.uid(),
        updated_at = now();
end;
$$;

-- ---------------------------------------------------------------------
-- Their own key
--
-- Null leaves the stored value alone, so correcting a Google processor
-- id does not blank the service account JSON — the trap 0107 documents.
-- ---------------------------------------------------------------------
create or replace function public.set_ocr_credentials(
  p_org_id       uuid,
  p_provider     text,
  p_api_key      text default null,
  p_project_id   text default null,
  p_location     text default null,
  p_processor_id text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_key       text;
  v_project   text;
  v_location  text;
  v_processor text;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can set a scanning key'
      using errcode = '42501';
  end if;
  if p_provider not in ('claude', 'google') then
    raise exception 'Unknown scanning provider %', p_provider
      using errcode = '23514';
  end if;

  select c.api_key, c.project_id, c.location, c.processor_id
    into v_key, v_project, v_location, v_processor
    from public.org_ocr_credentials c
   where c.org_id = p_org_id and c.provider = p_provider;

  v_key       := coalesce(nullif(trim(coalesce(p_api_key, '')), ''), v_key);
  v_project   := coalesce(nullif(trim(coalesce(p_project_id, '')), ''), v_project);
  v_location  := coalesce(nullif(trim(coalesce(p_location, '')), ''), v_location);
  v_processor := coalesce(nullif(trim(coalesce(p_processor_id, '')), ''), v_processor);

  if v_key is null then
    raise exception 'A key is required the first time % is configured',
      p_provider using errcode = '23514';
  end if;

  -- Document AI is addressed by processor, not by project alone. A key
  -- with no processor behind it is a 404 at the first scan.
  if p_provider = 'google'
     and (v_project is null or v_location is null or v_processor is null) then
    raise exception
      'Google Document AI needs a project, a location and a processor id'
      using errcode = '23514';
  end if;

  insert into public.org_ocr_credentials
    (org_id, provider, api_key, project_id, location, processor_id,
     updated_by, updated_at)
  values (p_org_id, p_provider, v_key, v_project, v_location, v_processor,
          auth.uid(), now())
  on conflict (org_id, provider) do update
    set api_key      = excluded.api_key,
        project_id   = excluded.project_id,
        location     = excluded.location,
        processor_id = excluded.processor_id,
        updated_by   = auth.uid(),
        updated_at   = now();
end;
$$;

create or replace function public.clear_ocr_credentials(
  p_org_id uuid, p_provider text)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can remove a scanning key'
      using errcode = '42501';
  end if;

  delete from public.org_ocr_credentials
   where org_id = p_org_id and provider = p_provider;

  -- Leaving the organization switched on with a key that is gone would
  -- turn a deliberate removal into a run of failed scans.
  update public.org_ocr_settings
     set is_enabled = false, updated_by = auth.uid(), updated_at = now()
   where org_id = p_org_id and provider = p_provider and key_source = 'own';
end;
$$;

-- ---------------------------------------------------------------------
-- What the settings screen shows
--
-- Whether a key is set, never what it is.
-- ---------------------------------------------------------------------
create or replace function public.ocr_status(p_org_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  s          public.org_ocr_settings;
  v_provider text;
  v_balance  numeric(18, 2);
begin
  if not app.can_write(p_org_id) and not app.can_read_ledger(p_org_id) then
    raise exception 'You do not have access to this organization'
      using errcode = '42501';
  end if;

  select * into s from public.org_ocr_settings where org_id = p_org_id;
  v_provider := coalesce(s.provider, 'claude');

  select c.balance into v_balance
    from public.org_credits c where c.org_id = p_org_id;

  return jsonb_build_object(
    'enabled',     coalesce(s.is_enabled, false),
    'provider',    v_provider,
    'key_source',  coalesce(s.key_source, 'platform'),
    'has_own_key', exists (select 1 from public.org_ocr_credentials c
                            where c.org_id = p_org_id
                              and c.provider = v_provider),
    -- Which providers hold a key, so switching provider can warn before
    -- it strands somebody rather than after.
    'keys',        (select coalesce(jsonb_object_agg(c.provider, true), '{}'::jsonb)
                      from public.org_ocr_credentials c where c.org_id = p_org_id),
    'balance',     coalesce(v_balance, 0),
    'currency',    'MYR',
    'price',       app.ocr_price(v_provider),
    'updated_at',  s.updated_at);
end;
$$;

-- ---------------------------------------------------------------------
-- Starting a scan
--
-- Called with the requester's own JWT, so `can_write` is the real
-- caller's permission and not the edge function's. The provider key
-- deliberately does not come back: the edge function reads it with the
-- service role, which is the only reader the table has.
--
-- The charge is taken here. Someone with write access could burn their
-- own organization's credit by calling this in a loop — their own money,
-- their own staff, and every attempt has their name on it in ocr_scans,
-- which is the honest trade rather than a pretence that a per-call
-- quota would fix it.
-- ---------------------------------------------------------------------
create or replace function public.ocr_begin(
  p_org_id uuid, p_attachment_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  s        public.org_ocr_settings;
  v_path   text;
  v_mime   text;
  v_price  numeric(18, 2) := 0;
  v_scan   uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'You cannot record documents for this organization'
      using errcode = '42501';
  end if;

  select * into s from public.org_ocr_settings where org_id = p_org_id;
  if s.org_id is null or not s.is_enabled then
    raise exception
      'Document scanning is switched off for this organization. An administrator turns it on in Settings.'
      using errcode = '42501';
  end if;

  select a.storage_path, a.mime_type into v_path, v_mime
    from public.attachments a
   where a.id = p_attachment_id and a.org_id = p_org_id;
  if v_path is null then
    raise exception 'That attachment is not on this organization'
      using errcode = '42704';
  end if;

  if s.key_source = 'own' then
    if not exists (select 1 from public.org_ocr_credentials c
                    where c.org_id = p_org_id and c.provider = s.provider) then
      raise exception 'The % key has been removed; scanning cannot run',
        s.provider using errcode = '42501';
    end if;
  else
    v_price := app.ocr_price(s.provider);
  end if;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source,
     amount_charged, requested_by)
  values (p_org_id, p_attachment_id, v_path, s.provider, s.key_source,
          v_price, auth.uid())
  returning id into v_scan;

  if v_price > 0 then
    perform app.move_credit(
      p_org_id, 'usage', -v_price,
      format('Scan of %s', split_part(v_path, '/', 4)),
      v_scan, null, true);
  end if;

  return jsonb_build_object(
    'scan_id',      v_scan,
    'provider',     s.provider,
    'key_source',   s.key_source,
    'storage_path', v_path,
    'mime_type',    v_mime,
    'charged',      v_price);
end;
$$;

-- ---------------------------------------------------------------------
-- Finishing one
--
-- Service role only. A failed scan returns what it took; an authenticated
-- caller must not be able to reach that.
-- ---------------------------------------------------------------------
create or replace function public.ocr_finish(
  p_scan_id   uuid,
  p_status    text,
  p_extracted jsonb default null,
  p_error     text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare sc public.ocr_scans;
begin
  if p_status not in ('ok', 'failed') then
    raise exception 'A scan finishes ok or failed, not %', p_status
      using errcode = '23514';
  end if;

  select * into sc from public.ocr_scans where id = p_scan_id for update;
  if sc.id is null then
    raise exception 'No such scan' using errcode = '42704';
  end if;
  if sc.status <> 'pending' then
    return;   -- already settled; a retried callback must not refund twice
  end if;

  update public.ocr_scans
     set status      = p_status,
         extracted   = p_extracted,
         error       = p_error,
         refunded    = (p_status = 'failed' and sc.amount_charged > 0),
         finished_at = now()
   where id = p_scan_id;

  if p_status = 'failed' and sc.amount_charged > 0 then
    perform app.move_credit(
      sc.org_id, 'refund', sc.amount_charged,
      'Scan failed at the provider', sc.id, null, false);
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Selling the credit
--
-- `p_amount` is the credit granted, and tax goes on top of it: pay for
-- RM 100 of scanning and RM 100 is what lands in the balance, whatever
-- the service tax on the supply turns out to be.
-- ---------------------------------------------------------------------
create or replace function public.platform_topup_credit(
  p_org_id uuid,
  p_amount numeric,
  p_note   text default null)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_issuer  jsonb;
  v_org     public.organizations;
  v_no      text;
  v_prefix  text;
  v_seq     integer;
  v_rate    numeric(6, 3) := 0;
  v_tax     numeric(18, 2) := 0;
  v_invoice uuid;
  v_balance numeric(18, 2);
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required'
      using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'A top-up has to be more than nothing'
      using errcode = '23514';
  end if;

  select * into v_org from public.organizations where id = p_org_id;
  if v_org.id is null then
    raise exception 'No such organization' using errcode = '42704';
  end if;

  select value into v_issuer from public.platform_settings
   where key = 'platform_issuer';
  v_issuer := coalesce(v_issuer, '{}'::jsonb);

  if coalesce((v_issuer ->> 'sst_registered')::boolean, false) then
    v_rate := coalesce((v_issuer ->> 'sst_rate')::numeric, 0);
    v_tax  := round(p_amount * v_rate / 100, 2);
  end if;

  -- One number at a time, per year. The advisory lock is transaction
  -- scoped, so two administrators topping up at once queue rather than
  -- both reading the same max and colliding on the unique index.
  perform pg_advisory_xact_lock(hashtext('platform_invoice_no'));
  v_prefix := coalesce(nullif(v_issuer ->> 'invoice_prefix', ''), 'KH');
  select coalesce(max(substring(i.invoice_no from '[0-9]+$')::integer), 0) + 1
    into v_seq
    from public.platform_invoices i
   where i.invoice_no like v_prefix || '-' || to_char(current_date, 'YYYY') || '-%';
  v_no := format('%s-%s-%s', v_prefix, to_char(current_date, 'YYYY'),
                 lpad(v_seq::text, 4, '0'));

  insert into public.platform_invoices (
    invoice_no, org_id, issue_date, currency,
    issuer_name, issuer_registration_no, issuer_old_registration_no,
    issuer_sst_no, issuer_address,
    bill_to_name, bill_to_registration_no, bill_to_tin, bill_to_address,
    description, subtotal, tax_rate, tax_amount, total_amount,
    notes, issued_by)
  values (
    v_no, p_org_id, current_date, 'MYR',
    coalesce(v_issuer ->> 'name', 'Kabeer Holdings Sdn Bhd'),
    v_issuer ->> 'registration_no',
    v_issuer ->> 'old_registration_no',
    nullif(v_issuer ->> 'sst_no', ''),
    nullif(v_issuer ->> 'address', ''),
    v_org.name, v_org.registration_no, v_org.tin, v_org.address_line1,
    'Document scanning credit', p_amount, v_rate, v_tax, p_amount + v_tax,
    p_note, auth.uid())
  returning id into v_invoice;

  v_balance := app.move_credit(
    p_org_id, 'topup', p_amount,
    format('Top-up on invoice %s', v_no), null, v_invoice, false);

  return jsonb_build_object(
    'invoice_id', v_invoice,
    'invoice_no', v_no,
    'subtotal',   p_amount,
    'tax_amount', v_tax,
    'total',      p_amount + v_tax,
    'balance',    v_balance);
end;
$$;

create or replace function public.platform_mark_invoice_paid(
  p_invoice_id uuid, p_note text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required'
      using errcode = '42501';
  end if;
  update public.platform_invoices
     set status = 'paid', paid_at = now(), paid_note = p_note
   where id = p_invoice_id and status = 'issued';
end;
$$;

-- ---------------------------------------------------------------------
-- Adjusting a balance by hand
--
-- Goodwill after an outage, or clawing back a mis-keyed top-up. Signed,
-- and it writes the same ledger line everything else does, so it cannot
-- be done invisibly.
-- ---------------------------------------------------------------------
create or replace function public.platform_adjust_credit(
  p_org_id uuid, p_amount numeric, p_reason text)
returns numeric
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required'
      using errcode = '42501';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'Say why' using errcode = '23514';
  end if;
  return app.move_credit(p_org_id, 'adjustment', p_amount, p_reason,
                         null, null, p_amount < 0);
end;
$$;

create or replace function public.platform_credit_summary()
returns table (
  org_id uuid, org_name text, balance numeric,
  scans_30d bigint, spent_30d numeric, last_scan_at timestamptz)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required'
      using errcode = '42501';
  end if;

  return query
    select o.id, o.name, coalesce(c.balance, 0),
           (select count(*) from public.ocr_scans s
             where s.org_id = o.id and s.created_at > now() - interval '30 days'),
           (select coalesce(-sum(l.amount), 0) from public.credit_ledger l
             where l.org_id = o.id and l.entry_type = 'usage'
               and l.created_at > now() - interval '30 days'),
           (select max(s.created_at) from public.ocr_scans s where s.org_id = o.id)
      from public.organizations o
      left join public.org_credits c on c.org_id = o.id
     where o.deleted_at is null
     order by coalesce(c.balance, 0) asc, o.name;
end;
$$;

-- ---------------------------------------------------------------------
-- Reachability
--
-- Postgres grants EXECUTE to PUBLIC on a new function, so each one is
-- taken away before it is given back — the lesson 0080 exists for.
-- ---------------------------------------------------------------------
revoke all on function app.move_credit(uuid, text, numeric, text, uuid, uuid, boolean)
  from public, anon, authenticated;
grant execute on function app.move_credit(uuid, text, numeric, text, uuid, uuid, boolean)
  to service_role;

revoke all on function app.ocr_price(text) from public, anon;
grant execute on function app.ocr_price(text) to authenticated, service_role;

revoke all on function public.set_ocr_settings(uuid, boolean, text, text)
  from public, anon;
grant execute on function public.set_ocr_settings(uuid, boolean, text, text)
  to authenticated;

revoke all on function public.set_ocr_credentials(uuid, text, text, text, text, text)
  from public, anon;
grant execute on function public.set_ocr_credentials(uuid, text, text, text, text, text)
  to authenticated;

revoke all on function public.clear_ocr_credentials(uuid, text) from public, anon;
grant execute on function public.clear_ocr_credentials(uuid, text) to authenticated;

revoke all on function public.ocr_status(uuid) from public, anon;
grant execute on function public.ocr_status(uuid) to authenticated, service_role;

revoke all on function public.ocr_begin(uuid, uuid) from public, anon;
grant execute on function public.ocr_begin(uuid, uuid) to authenticated;

-- Not `authenticated`: this one hands money back.
revoke all on function public.ocr_finish(uuid, text, jsonb, text)
  from public, anon, authenticated;
grant execute on function public.ocr_finish(uuid, text, jsonb, text) to service_role;

revoke all on function public.platform_topup_credit(uuid, numeric, text)
  from public, anon;
grant execute on function public.platform_topup_credit(uuid, numeric, text)
  to authenticated;

revoke all on function public.platform_mark_invoice_paid(uuid, text) from public, anon;
grant execute on function public.platform_mark_invoice_paid(uuid, text) to authenticated;

revoke all on function public.platform_adjust_credit(uuid, numeric, text)
  from public, anon;
grant execute on function public.platform_adjust_credit(uuid, numeric, text)
  to authenticated;

revoke all on function public.platform_credit_summary() from public, anon;
grant execute on function public.platform_credit_summary() to authenticated;
