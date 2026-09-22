-- =====================================================================
-- iAkauntan :: 0682 SmartScan is a module, and a statement is many rows
--
-- Two things asked for together, and they are together here because
-- both are about what scanning is ALLOWED to do.
--
-- ---------------------------------------------------------------------
-- 1. A module of its own
--
-- Scanning has been switchable per company since `0111` -- but only as
-- a SETTING, `org_ocr_settings.is_enabled`, which any administrator of
-- any company could turn on. It is the most expensive thing in this
-- product per use: every scan is a call to somebody else's model,
-- billed to the platform when the company is on the platform's key.
-- `attachments` became a module in `0323` for a milder version of the
-- same argument -- storage costs money -- and this one costs more.
--
-- So `smartscan`, alongside it. Off by default, as `0323` made
-- attachments off by default, and for the same reason: a module that
-- arrives switched on for everybody is not a module, it is a feature
-- with a price tag nobody agreed to.
--
-- The gate goes in `ocr_begin` and `ocr_record_local` -- the two doors
-- a scan can come through -- and in `set_ocr_settings`, so the switch
-- refuses with a sentence naming the module rather than letting
-- somebody turn scanning on and discover at the first scan that it
-- does nothing.
--
-- ---------------------------------------------------------------------
-- 2. A target that repeats
--
-- `0681` left bank statements out and said why:
--
--     `bank_import` is left out on purpose: a statement becomes MANY
--     rows, and a field list that describes one record cannot describe
--     it.
--
-- That was true of `0681` and is the thing to fix rather than to work
-- around. `scan_targets.repeats` says the fields describe ONE ROW of
-- many, and the reader is asked for an array of them instead of one
-- object. A statement's fields are a date, a description, an amount
-- and a balance -- the same four on every line, which is exactly what
-- a repeating target is.
--
-- The single-record targets are untouched: `repeats` is false by
-- default, and a platform that has configured none of this reads
-- documents exactly as it did.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The module
--
-- `on conflict do update` rather than `do nothing`, following `0323`:
-- the name and the description are wording, and wording is worth being
-- able to correct with a migration. `is_core` and the price are not
-- touched on an update, so a platform that has repriced it keeps its
-- price.
-- ---------------------------------------------------------------------
insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order, is_active)
values
  ('smartscan', 'AI SmartScan',
   'Photograph a bill, a receipt, a delivery order, a name card or a '
   'bank statement and have it read - the supplier, the date, the '
   'amounts and the lines. Every scan is a call to a reader that is '
   'paid for by the call, from this company''s own key or from '
   'purchased credit.',
   false, 29.00, 101, true)
on conflict (code) do update
  set name        = excluded.name,
      description = excluded.description;

-- ---------------------------------------------------------------------
-- A demo tenant to show it in
--
-- `demo_rebuild.sql` refuses an active module that no demo company
-- carries: a module nobody can be shown is a module nobody buys.
--
-- Through `app.demo_modules_in_use` rather than by granting it to the
-- demo companies as they stand, because `app.demo_rebuild()` DELETES
-- and recreates every one of them -- a grant made here would last
-- until the next rebuild and no longer. `0233` wrote that sweeper for
-- exactly this: it runs at the end of the rebuild and gives a demo
-- tenant every module it has data for.
--
-- Granted for BEING a demo rather than detected from rows, which is
-- what `0324` did for attachments and `0329` for the mailbox and
-- `0470` for the assistant. A tenant rebuilt this morning has scanned
-- nothing and never will by itself; what the module demonstrates is
-- the paperwork it reads, and the demo has plenty. The rest of the
-- union is `0486`'s, unchanged -- copied from the migration that last
-- defined it rather than from `0233`, which would have reverted four
-- migrations' worth of additions.
-- ---------------------------------------------------------------------
create or replace function app.demo_modules_in_use()
returns integer
language plpgsql
security definer
set search_path to 'public', 'app', 'pg_temp'
as $function$
declare
  r   record;
  v_n integer := 0;
begin
  for r in
    select distinct x.org_id, x.module_code
      from (
        select org_id, 'pos'          as module_code from public.pos_outlets
        union all
        select org_id, 'loyalty'      from public.loyalty_programs
        union all
        select org_id, 'memberships'  from public.pos_memberships
        union all
        select org_id, 'ticketing'    from public.tickets
        union all
        select org_id, 'hr'           from public.employees
        union all
        select org_id, 'fixed_assets' from public.fixed_assets
        union all
        select org_id, 'inventory'    from public.warehouses
        union all
        select org_id, 'purchases'    from public.purchase_documents
        union all
        -- 0324. Not detected from rows, unlike every line above it.
        -- Attachments hang off records that already exist rather than
        -- having a subject of their own, so a tenant that happens not
        -- to have uploaded a file yet would show nothing about a
        -- feature it can perfectly well demonstrate.
        select id, 'attachments' from public.organizations where is_demo
        union all
        -- 0329, and for the same reason twice over. A name on our
        -- domain exists only once somebody has asked for one and an
        -- operator has agreed; mail arrives only once somebody has
        -- written to the address. A tenant rebuilt this morning has
        -- neither and never will by itself.
        select id, 'workspace_address'
          from public.organizations where is_demo
        union all
        select id, 'mailbox' from public.organizations where is_demo
        union all
        -- 0486. A company attached to a firm is the multi-company case
        -- by construction: somebody is holding it alongside others on
        -- one sign-in, which is the whole of what the module is.
        select id, 'multi_company'
          from public.organizations where is_demo and firm_id is not null
        union all
        -- 0470, and the same reason a third time. Asking a question is
        -- something a visitor does; a tenant rebuilt this morning has
        -- asked nothing and never will by itself. What the module
        -- demonstrates is the books it reads, and those are there.
        select id, 'ai' from public.organizations where is_demo
        union all
        -- 0682, and the reason a fourth time. A scan is something
        -- somebody does with a camera; a tenant rebuilt this morning
        -- has scanned nothing and never will by itself. What the
        -- module demonstrates is the paperwork it reads, and the demo
        -- has plenty.
        select id, 'smartscan' from public.organizations where is_demo
      ) x
      join public.organizations g on g.id = x.org_id and g.is_demo
     where not exists (
       select 1 from public.org_modules om
        where om.org_id = x.org_id and om.module_code = x.module_code
          and om.is_enabled)
  loop
    insert into public.org_modules (org_id, module_code, is_enabled, enabled_at, notes)
    values (r.org_id, r.module_code, true, now(),
            'Enabled by app.demo_modules_in_use: the tenant has data for it.')
    on conflict (org_id, module_code) do update
      set is_enabled = true, expires_at = null;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$function$;

-- Ungranted, as every version of this has been: it is called from
-- inside `app.demo_rebuild`, which is itself service-role only.
revoke all on function app.demo_modules_in_use()
  from public, anon, authenticated;

-- And for the demo companies standing right now, which the next
-- rebuild would have covered anyway.
select app.demo_modules_in_use();

-- ---------------------------------------------------------------------
-- Every door a scan comes through
--
-- Said in one place so the two doors cannot drift, and worded for
-- somebody who can do something about it. "Not entitled" is true and
-- useless; the sentence below names the module and says where it is
-- switched on.
-- ---------------------------------------------------------------------
create or replace function app.require_smartscan(p_org_id uuid)
returns void language plpgsql stable
set search_path = public, app, pg_temp as $$
begin
  if not app.has_module(p_org_id, 'smartscan') then
    raise exception
      'AI SmartScan is not switched on for this company. It is a module, and an owner turns it on under Settings -> Subscription.'
      using errcode = '42501';
  end if;
end;
$$;

comment on function app.require_smartscan(uuid) is
  'Refuses where the `smartscan` module is off, in the words of '
  'somebody who can do something about it. One function rather than '
  'the same `has_module` call in three places, because three copies of '
  'a sentence is three sentences that end up saying different things.';

create or replace function public.ocr_begin(
  p_org_id uuid, p_attachment_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  s        public.org_ocr_settings;
  pr       public.ocr_providers;
  v_path   text;
  v_mime   text;
  v_price  numeric(18, 2) := 0;
  v_scan   uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'You cannot record documents for this organization'
      using errcode = '42501';
  end if;
  perform app.require_smartscan(p_org_id);

  select * into s from public.org_ocr_settings where org_id = p_org_id;
  if s.org_id is null or not s.is_enabled then
    raise exception
      'Document scanning is switched off for this organization. An administrator turns it on in Settings.'
      using errcode = '42501';
  end if;

  select * into pr from public.ocr_providers where code = s.provider;
  if pr.runs_on_device then
    raise exception
      'This organization reads documents on the device, so there is nothing for the server to do. Use the app on a phone or tablet.'
      using errcode = '0A000';
  end if;

  if not pr.is_active then
    raise exception
      '% is no longer offered. An administrator chooses another reader in Settings.',
      pr.name using errcode = '42501';
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
                    where c.org_id = p_org_id and c.provider = s.provider)
       and not exists (select 1 from public.ocr_provider_keys k
                        where k.org_id = p_org_id and k.provider = s.provider)
    then
      raise exception 'The % key has been removed; scanning cannot run',
        pr.name using errcode = '42501';
    end if;
  else
    v_price := pr.price;
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
    'provider_name', pr.name,
    'kind',         pr.kind,
    'endpoint',     pr.endpoint,
    'model',        pr.model,
    'key_source',   s.key_source,
    'storage_path', v_path,
    'mime_type',    v_mime,
    'charged',      v_price);
end;
$$;

-- The phone's door. It costs the platform nothing -- the reading
-- happened on the device -- and it is gated anyway: the module is what
-- the company is paying for, and a feature that works for free on one
-- surface and not the other is a feature nobody can explain.
create or replace function public.ocr_record_local(
  p_org_id        uuid,
  p_attachment_id uuid,
  p_extracted     jsonb default null,
  p_error         text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  s      public.org_ocr_settings;
  pr     public.ocr_providers;
  v_path text;
  v_scan uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'You cannot record documents for this organization'
      using errcode = '42501';
  end if;
  perform app.require_smartscan(p_org_id);

  select * into s from public.org_ocr_settings where org_id = p_org_id;
  if s.org_id is null or not s.is_enabled then
    raise exception
      'Document scanning is switched off for this organization. An administrator turns it on in Settings.'
      using errcode = '42501';
  end if;

  -- `0113`'s sentence and `0113`'s errcode, unchanged. `ocr_credit.sql`
  -- asserts both, and rewording a refusal while moving a function is
  -- how a test that was protecting something starts protecting nothing.
  select * into pr from public.ocr_providers where code = s.provider;
  if not coalesce(pr.runs_on_device, false) then
    raise exception
      'This organization reads documents with %, not on the device',
      coalesce(pr.name, s.provider) using errcode = '23514';
  end if;

  select a.storage_path into v_path
    from public.attachments a
   where a.id = p_attachment_id and a.org_id = p_org_id;
  if v_path is null then
    raise exception 'That attachment is not on this organization'
      using errcode = '42704';
  end if;

  insert into public.ocr_scans
    (org_id, attachment_id, storage_path, provider, key_source, status,
     amount_charged, extracted, error, requested_by, finished_at)
  values (p_org_id, p_attachment_id, v_path, s.provider, 'device',
          case when p_error is null then 'ok' else 'failed' end,
          0, p_extracted, p_error, auth.uid(), now())
  returning id into v_scan;

  return v_scan;
end;
$$;

-- ---------------------------------------------------------------------
-- The switch says so instead of lying
-- ---------------------------------------------------------------------
create or replace function public.set_ocr_settings(
  p_org_id     uuid,
  p_enabled    boolean,
  p_provider   text default null,
  p_key_source text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  pr         public.ocr_providers;
  s          public.org_ocr_settings;
  v_provider text;
  v_source   text;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can turn document scanning on'
      using errcode = '42501';
  end if;

  -- Only on the way ON. Switching scanning OFF must work whatever the
  -- subscription says: a company whose module has lapsed still has a
  -- switch showing "on", and refusing to let them turn it off would be
  -- refusing to let them tidy up after us.
  if p_enabled then
    perform app.require_smartscan(p_org_id);
  end if;

  select * into s from public.org_ocr_settings where org_id = p_org_id;

  v_provider := coalesce(nullif(btrim(coalesce(p_provider, '')), ''),
                         s.provider, app.default_ocr_provider());
  v_source   := coalesce(nullif(btrim(coalesce(p_key_source, '')), ''),
                         s.key_source, 'platform');

  select * into pr from public.ocr_providers where code = v_provider;
  if pr.code is null then
    raise exception 'Unknown scanning provider %', v_provider
      using errcode = '23514';
  end if;
  if p_enabled and not pr.is_active then
    raise exception
      '% is no longer offered. Choose another reader and switch scanning on with that one.',
      pr.name using errcode = '23514';
  end if;

  if p_enabled and not app.ocr_provider_ready(pr) then
    raise exception
      'No model is set for %. A platform administrator sets one in the console before it can be used.',
      pr.name using errcode = '23514';
  end if;

  if pr.runs_on_device then
    v_source := 'device';
  elsif v_source = 'device' then
    raise exception 'Only an on-device reader runs on the device; % needs a key',
      pr.name using errcode = '23514';
  elsif v_source not in ('platform', 'own') then
    raise exception 'A key comes from the platform or from you, not %',
      v_source using errcode = '23514';
  end if;

  if v_source = 'own' and not pr.takes_key then
    raise exception '% has no key for you to supply', pr.name
      using errcode = '23514';
  end if;

  if p_enabled and v_source = 'own'
     and not exists (select 1 from public.org_ocr_credentials c
                      where c.org_id = p_org_id and c.provider = v_provider)
     and not exists (select 1 from public.ocr_provider_keys k
                      where k.org_id = p_org_id and k.provider = v_provider) then
    raise exception
      'Add your % key before switching scanning on with it', pr.name
      using errcode = '23514';
  end if;

  insert into public.org_ocr_settings
    (org_id, is_enabled, provider, key_source, updated_by, updated_at)
  values (p_org_id, p_enabled, v_provider, v_source, auth.uid(), now())
  on conflict (org_id) do update
    set is_enabled = excluded.is_enabled,
        provider   = excluded.provider,
        key_source = excluded.key_source,
        updated_by = auth.uid(),
        updated_at = now();
end;
$$;

-- ---------------------------------------------------------------------
-- What the settings card is told
--
-- `has_module` so the card can say "this is a module and it is off"
-- rather than drawing a switch that refuses. A refusal a screen could
-- have predicted is a screen that has not been finished.
-- ---------------------------------------------------------------------
create or replace function public.ocr_status(p_org_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  s          public.org_ocr_settings;
  v_default  text;
  v_provider text;
  v_balance  numeric(18, 2);
  v_fb       public.ocr_providers;
begin
  if not app.can_write(p_org_id) and not app.can_read_ledger(p_org_id) then
    raise exception 'You do not have access to this organization'
      using errcode = '42501';
  end if;

  select * into s from public.org_ocr_settings where org_id = p_org_id;
  v_default  := app.default_ocr_provider();
  v_provider := coalesce(s.provider, v_default);

  select c.balance into v_balance
    from public.org_credits c where c.org_id = p_org_id;

  select * into v_fb from public.ocr_providers p
   where p.code = v_default
     and p.code <> v_provider
     and p.is_active
     and app.ocr_provider_ready(p)
     and not p.runs_on_device
     and coalesce(p.price, 0) = 0;

  return jsonb_build_object(
    'enabled',     coalesce(s.is_enabled, false),
    'has_module',  app.has_module(p_org_id, 'smartscan'),
    'provider',    v_provider,
    'default_provider', v_default,
    'chosen',      s.provider is not null,
    'fallback',      v_fb.code,
    'fallback_name', v_fb.name,
    'key_source',  coalesce(s.key_source, 'platform'),
    'has_own_key', exists (select 1 from public.org_ocr_credentials c
                            where c.org_id = p_org_id
                              and c.provider = v_provider),
    'keys',        (select coalesce(jsonb_object_agg(c.provider, true), '{}'::jsonb)
                      from public.org_ocr_credentials c where c.org_id = p_org_id),
    'balance',     coalesce(v_balance, 0),
    'currency',    'MYR',
    'price',       app.ocr_price(v_provider),
    'providers',   (select coalesce(jsonb_agg(jsonb_build_object(
                        'code', p.code,
                        'name', p.name,
                        'kind', p.kind,
                        'price', p.price,
                        'takes_key', p.takes_key,
                        'runs_on_device', p.runs_on_device,
                        'is_active', p.is_active,
                        'ready', app.ocr_provider_ready(p),
                        'blurb', p.blurb) order by p.sort_order), '[]'::jsonb)
                      from public.ocr_providers p
                     where p.is_active or p.code = v_provider),
    'updated_at',  s.updated_at);
end;
$$;

-- ---------------------------------------------------------------------
-- A target whose fields describe one row of many
-- ---------------------------------------------------------------------
alter table public.scan_targets
  add column if not exists repeats boolean not null default false;

comment on column public.scan_targets.repeats is
  'The fields describe ONE ROW of many rather than one record, so the '
  'reader is asked for an array of them. A bank statement is the case '
  'this exists for: a date, a description, an amount and a balance, the '
  'same four on every line. False everywhere else, and a platform that '
  'configures none of this reads documents exactly as it did. 0682.';

insert into public.scan_targets
  (module_code, action, label, table_name, destination, hint, sort_order,
   repeats)
values
  -- The sales side. A customer invoice scanned back in -- a copy
  -- returned with a payment, or one raised on somebody else's system
  -- during a migration.
  ('sales', 'invoice', 'An invoice to a customer', 'sales_documents',
   'sales_document',
   'Becomes an invoice, with the customer and the lines filled in.',
   5, false),
  -- Many rows. `bank_import` is what `0614` called the destination and
  -- what the app still routes on.
  ('accounting', 'bank_statement', 'A bank statement',
   'bank_transactions', 'bank_import',
   'Becomes the lines on the reconciliation screen, one per entry '
   'printed.', 35, true)
on conflict (module_code, action) do nothing;

-- The kind `0614` seeded for a statement, pointed at the target that
-- can now describe one.
update public.scan_document_kinds
   set target_module = 'accounting', target_action = 'bank_statement'
 where code = 'bank_statement' and target_module is null;

-- ---------------------------------------------------------------------
-- What goes to the reader, now that a target can repeat
-- ---------------------------------------------------------------------
create or replace function public.scan_extraction_targets()
returns jsonb
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(x order by x ->> 'key'), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'key', t.module_code || '.' || t.action,
               'label', t.label,
               'hint', t.hint,
               'repeats', t.repeats,
               'kinds', (select coalesce(jsonb_agg(k.label order by k.sort_order), '[]'::jsonb)
                           from public.scan_document_kinds k
                          where k.target_module = t.module_code
                            and k.target_action = t.action
                            and k.is_active),
               'fields', (select jsonb_agg(jsonb_build_object(
                              'name', f.column_name,
                              'description', f.description)
                              order by f.sort_order, f.column_name)
                            from public.scan_target_fields f
                           where f.module_code = t.module_code
                             and f.action = t.action)) as x
        from public.scan_targets t
       where t.is_active
         and exists (select 1 from public.scan_target_fields f
                      where f.module_code = t.module_code
                        and f.action = t.action)
    ) s;
$$;
