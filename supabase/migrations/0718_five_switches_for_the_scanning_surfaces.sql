-- =====================================================================
-- iAkauntan :: 0718 five switches for the scanning surfaces
--
-- Asked for: a Settings page under Console → Document scanning, with a
-- toggle for each of
--
--   the Scan button            on AI SmartScan
--   the Upload button          on AI SmartScan
--   "My own key"               on AI SmartScan
--   "Send documents to a reader" ON BY DEFAULT
--   the Upload button          on Bank statements
--
-- ---------------------------------------------------------------------
-- Three of these are presentation and two are rules. They are not the
-- same thing and they are not built the same way
--
-- THE THREE BUTTONS are affordances. Hiding the Scan button does not
-- stop anybody scanning -- `ocr_begin` decides that, off the company's
-- own switch and its module -- and hiding either Upload button does not
-- stop a file reaching storage. They are for taking a surface off the
-- product while it is being worked on, or off a platform that does not
-- want it, and that is all they are. The comment beside each one says
-- so, because a switch somebody believes is a security control is worse
-- than no switch.
--
-- "MY OWN KEY" IS A RULE. It decides whose money pays for a reading.
-- Enforced in `set_ocr_settings`, not in the screen, because a rule
-- enforced only in Dart is not enforced -- somebody calling the RPC
-- directly would move themselves onto their own key and the platform
-- would stop earning on it.
--
-- "ON BY DEFAULT" IS A RULE TOO, and the awkward one. See below.
--
-- ---------------------------------------------------------------------
-- The default has to be true in three places at once
--
-- `org_ocr_settings` has one row per company and NO ROW means off.
-- Three functions read that:
--
--   `ocr_status`        what the screen draws
--   `ocr_begin`         what lets a document be sent to a reader
--   `ocr_record_local`  what lets a reading made on the device be filed
--
-- Changing only the first would put a switch reading "on" above a
-- server refusing every document -- the exact shape of failure a
-- default invites, and one nobody would find until a customer did. So
-- all three call `app.scan_surface('scan_reader_on_by_default')`, and
-- the assertions walk all three.
--
-- A ROW IS A CHOICE; ITS ABSENCE IS NOT. A company that turned scanning
-- on and then off has a row saying false and stays off, whatever the
-- platform default becomes. Only a company that has never touched the
-- switch follows it. That is what makes this a default rather than an
-- override, and it is why nothing is backfilled.
--
-- `ocr_begin` needed two more lines for the same reason: a company
-- running on the default has no row, so it has no provider and no
-- key_source either. Without them the first company to use this would
-- have been told `There is no reader called <null>`.
--
-- ---------------------------------------------------------------------
-- It ships OFF, and that is deliberate
--
-- Every switch here ships in the state the product is in today, so
-- applying this migration changes nothing for anybody. Four ship ON
-- because those surfaces are on now; `scan_reader_on_by_default` ships
-- OFF because scanning is off for a new company now.
--
-- Turning that one on is a real decision and not a small one: it sends
-- documents a company has not asked to have read to a third-party
-- model, and spends platform credit doing it. The description on the
-- row says so, and so does the console.
--
-- ---------------------------------------------------------------------
-- Why a function rather than widening the read policy
--
-- `platform_settings` is readable by platform administrators and by
-- nobody else, except `nav_grouping`, which `0298` named in the policy
-- because every signed-in user needs it to draw their own menu.
--
-- Five more names in that `using` clause would be five more chances to
-- open the table by accident -- `maintenance_mode` and `signup_enabled`
-- live in it and are nobody's business but ours. `scan_surfaces()`
-- returns these five and only these five, so the policy is left as it
-- is and the blast radius of getting it wrong is one function body.
--
-- `set_scan_surface` refuses a key it does not know, which is `0678`'s
-- lesson in a different corner: a setter that accepts any string writes
-- a row nothing reads, and `check_settings_are_read.py` finds it a
-- year later.
-- =====================================================================

insert into public.platform_settings (key, value, description)
values
  ('scan_show_scan_button', to_jsonb(true),
   'Whether AI SmartScan offers the Scan button. Presentation only — '
   'it takes the surface off the screen and does not stop scanning, '
   'which `ocr_begin` decides off the company''s own switch.'),
  ('scan_show_upload_button', to_jsonb(true),
   'Whether AI SmartScan offers Upload, which keeps a file without '
   'reading it. Presentation only, like the Scan button.'),
  ('scan_allow_own_key', to_jsonb(true),
   'Whether a company may read on its own provider key instead of on '
   'credit bought here. A RULE: `set_ocr_settings` refuses the choice '
   'when this is off. A company already on its own key keeps it and '
   'can still move back to platform credit.'),
  ('scan_reader_on_by_default', to_jsonb(false),
   'Whether a company that has NEVER touched the switch has '
   '"Send documents to a reader" on. Off ships today''s behaviour. '
   'Turning it on sends documents to a third-party model for '
   'companies that did not ask, and spends platform credit doing it. '
   'A company that has chosen — on or off — is unaffected.'),
  ('statements_show_upload_button', to_jsonb(true),
   'Whether Bank statements offers Upload beside each account. '
   'Presentation only; the import itself lives on Reconcile and is '
   'reachable without it.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- Reading one, with its default where the row has gone missing
-- ---------------------------------------------------------------------
create or replace function app.scan_surface(p_key text)
returns boolean language sql stable
set search_path = public, app, pg_temp as $$
  select coalesce(
    (select s.value #>> '{}' = 'true'
       from public.platform_settings s where s.key = p_key),
    -- A row somebody deleted must not turn a surface off for everybody
    -- -- except the one whose safe answer is off, which is the only one
    -- that costs money and sends paperwork somewhere.
    p_key <> 'scan_reader_on_by_default');
$$;

comment on function app.scan_surface(text) is
  'One scanning switch, true when the platform_settings row says so. '
  'A missing row reads as ON for the three presentation switches and '
  'for the own-key rule, and OFF for `scan_reader_on_by_default` — the '
  'safe answer in each direction. `0718`.';

-- ---------------------------------------------------------------------
-- Reading all five, for anybody signed in
-- ---------------------------------------------------------------------
create or replace function public.scan_surfaces()
returns jsonb language sql stable security definer
set search_path = public, app, pg_temp as $$
  select jsonb_build_object(
    'scan_button',       app.scan_surface('scan_show_scan_button'),
    'upload_button',     app.scan_surface('scan_show_upload_button'),
    'own_key',           app.scan_surface('scan_allow_own_key'),
    'reader_on_default', app.scan_surface('scan_reader_on_by_default'),
    'statements_upload', app.scan_surface('statements_show_upload_button'));
$$;

revoke all on function public.scan_surfaces() from public, anon;
grant execute on function public.scan_surfaces() to authenticated;

comment on function public.scan_surfaces() is
  'The five scanning surface switches, for the screens that draw them. '
  'A function rather than a wider read policy on `platform_settings`, '
  'which also holds `maintenance_mode` and `signup_enabled`. `0718`.';

-- ---------------------------------------------------------------------
-- Setting one
-- ---------------------------------------------------------------------
create or replace function public.set_scan_surface(
  p_key text, p_on boolean)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;
  if p_on is null then
    raise exception 'A switch is on or off, not neither'
      using errcode = '23514';
  end if;

  -- `0678`'s lesson in another corner. A setter that takes any string
  -- writes a row nothing reads, and the sweep finds it a year later
  -- while somebody wonders why their switch does nothing.
  if p_key not in ('scan_show_scan_button', 'scan_show_upload_button',
                   'scan_allow_own_key', 'scan_reader_on_by_default',
                   'statements_show_upload_button') then
    raise exception 'There is no scanning switch called %', p_key
      using errcode = '23514';
  end if;

  insert into public.platform_settings (key, value, updated_by, updated_at)
  values (p_key, to_jsonb(p_on), auth.uid(), now())
  on conflict (key) do update
    set value = excluded.value,
        updated_by = excluded.updated_by, updated_at = now();
end;
$$;

revoke all on function public.set_scan_surface(text, boolean) from public, anon;
grant execute on function public.set_scan_surface(text, boolean) to authenticated;

comment on function public.set_scan_surface(text, boolean) is
  'Turns one scanning surface switch on or off. Platform '
  'administrators only, and refuses a key that is not one of the five '
  '— a setter that took any string would write a row nothing reads. '
  '`0718`.';

-- ---------------------------------------------------------------------
-- The four functions that now have to agree, restated whole
--
-- Each is the definition that was live before this migration with one
-- expression changed; they are reproduced rather than patched because
-- `create or replace` takes the whole body.
-- ---------------------------------------------------------------------
create or replace function public.ocr_status(p_org_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
    -- `0718`: a company that has never chosen follows the
    -- platform's default. A row -- even one saying false -- is a
    -- choice, and the default speaks only for its absence.
    'enabled',     coalesce(s.is_enabled,
                            app.scan_surface('scan_reader_on_by_default')),
    'has_module',  app.has_module(p_org_id, 'smartscan'),
    'provider',    v_provider,
    'default_provider', v_default,
    'chosen',      s.provider is not null,
    'fallback',      v_fb.code,
    'fallback_name', v_fb.name,
    'key_source',  coalesce(s.key_source, 'platform'),
    -- So the screen can stop offering a choice the platform has
    -- withdrawn, while a company ALREADY on its own key keeps the
    -- control it needs to move back off it.
    'own_key_allowed', app.scan_surface('scan_allow_own_key'),
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
                        -- The READER's answer, not the shape's. 0701.
                        'reads_pdf', app.provider_reads_pdf(p),
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
$function$;


create or replace function public.ocr_begin(p_org_id uuid, p_attachment_id uuid, p_provider text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  s        public.org_ocr_settings;
  pr       public.ocr_providers;
  v_code   text;
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
  -- `0718`. The same rule as `ocr_status`, in the place that
  -- ENFORCES it: a screen saying scanning is on while this refused
  -- every document would be the switch lying, which is the whole
  -- failure mode a platform default invites.
  if not coalesce(s.is_enabled,
                  app.scan_surface('scan_reader_on_by_default')) then
    raise exception
      'Document scanning is switched off for this organization. An administrator turns it on under “How it reads” on the AI SmartScan screen.'
      using errcode = '42501';
  end if;

  -- `nullif(btrim(...), '')` rather than `is not null`: an empty string
  -- arriving from a client is somebody meaning "no choice", and looking
  -- it up in the catalog would refuse it as an unknown reader.
  -- `app.default_ocr_provider()` last, because a company running on
  -- the platform default has NO ROW and therefore no provider of
  -- its own -- and `There is no reader called <null>` is what this
  -- would otherwise say to the first company to use it. `0718`.
  v_code := coalesce(nullif(btrim(coalesce(p_provider, '')), ''),
                     s.provider, app.default_ocr_provider());

  select * into pr from public.ocr_providers where code = v_code;
  if pr.code is null then
    raise exception 'There is no reader called %', v_code
      using errcode = '23514';
  end if;

  if pr.runs_on_device then
    raise exception
      'This organization reads documents on the device, so there is nothing for the server to do. Use the app on a phone or tablet.'
      using errcode = '0A000';
  end if;

  if not pr.is_active then
    raise exception
      '% is no longer offered. An administrator chooses another reader under “How it reads” on the AI SmartScan screen.',
      pr.name using errcode = '42501';
  end if;

  -- Only for a reader the caller NAMED. The company's own reader is
  -- allowed to be unready and fail further in, exactly as it did
  -- before this migration -- narrowing that would be a behaviour
  -- change smuggled in beside a feature.
  if v_code is distinct from s.provider and not app.ocr_provider_ready(pr) then
    raise exception
      '% has not been set up by the platform yet, so it cannot be asked to read anything.',
      pr.name using errcode = '42501';
  end if;

  select a.storage_path, a.mime_type into v_path, v_mime
    from public.attachments a
   where a.id = p_attachment_id and a.org_id = p_org_id;
  if v_path is null then
    -- `0702`. This said "That attachment is not on this organization",
    -- which is a sentence about TENANCY and sends somebody to check
    -- which company they are signed into. It is almost never what
    -- happened.
    --
    -- `ocr_scans.attachment_id` carries a COMPOSITE foreign key to
    -- `attachments (org_id, id)`, so a non-null id always had a row on
    -- this organization. The ordinary way to arrive here is that the
    -- row has since been DELETED -- a document removed takes its
    -- attachments with it -- while a screen still holds the id it read
    -- a minute ago. The storage object goes at the same time, which is
    -- why the same scan also answers 404 to "View the image".
    raise exception
      'That file is no longer on file -- it was removed after this list '
      'was loaded. Refresh, and what was read off it is still kept.'
      using errcode = '42704';
  end if;

  if coalesce(s.key_source, 'platform') = 'own' then
    if not exists (select 1 from public.org_ocr_credentials c
                    where c.org_id = p_org_id and c.provider = v_code)
       and not exists (select 1 from public.ocr_provider_keys k
                        where k.org_id = p_org_id and k.provider = v_code)
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
  values (p_org_id, p_attachment_id, v_path, v_code,
          coalesce(s.key_source, 'platform'),
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
    'provider',     v_code,
    'provider_name', pr.name,
    'kind',         pr.kind,
    'endpoint',     pr.endpoint,
    'model',        pr.model,
    'key_source',   coalesce(s.key_source, 'platform'),
    'storage_path', v_path,
    'mime_type',    v_mime,
    'charged',      v_price);
end;
$function$;


create or replace function public.ocr_record_local(p_org_id uuid, p_attachment_id uuid, p_extracted jsonb DEFAULT NULL::jsonb, p_error text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  s      public.org_ocr_settings;
  pr     public.ocr_providers;
  v_code text;
  v_path text;
  v_scan uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'You cannot record documents for this organization'
      using errcode = '42501';
  end if;
  perform app.require_smartscan(p_org_id);

  select * into s from public.org_ocr_settings where org_id = p_org_id;
  -- `0718`, and the third of three. A reading made on the device
  -- costs the platform nothing, but it still files an `ocr_scans`
  -- row against a company, so it answers the same question the
  -- same way.
  if not coalesce(s.is_enabled,
                  app.scan_surface('scan_reader_on_by_default')) then
    raise exception
      'Document scanning is switched off for this organization. An administrator turns it on under “How it reads” on the AI SmartScan screen.'
      using errcode = '42501';
  end if;

  -- The company's own reader first, because a company set to Local Read
  -- must keep recording against Local Read whatever else the catalog
  -- holds -- and because that is the only case this function had before
  -- `0700`, and it has to behave identically.
  select * into pr from public.ocr_providers where code = s.provider;
  if coalesce(pr.runs_on_device, false) then
    v_code := s.provider;
  else
    -- A reading made HERE by a company whose setting points at a
    -- server: "Read it with → Local Read", or the app rescuing a
    -- document its reader would not answer for. Refused until `0703`
    -- with `0113`'s sentence, after the file had already been read.
    v_code := app.device_ocr_reader();
  end if;

  -- `0113`'s errcode, and the only thing that can still raise it: the
  -- platform has no reader that runs in the app at all, so there is
  -- nothing to file this against. Nobody should reach it -- the app
  -- offers Local Read off the same catalog -- and it is a refusal
  -- rather than a row naming a reader that did not read.
  if v_code is null then
    raise exception
      'This platform has no reader that runs on the device, so there is nothing to record this reading against'
      using errcode = '23514';
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
  values (p_org_id, p_attachment_id, v_path, v_code, 'device',
          case when p_error is null then 'ok' else 'failed' end,
          0, p_extracted, p_error, auth.uid(), now())
  returning id into v_scan;

  return v_scan;
end;
$function$;


create or replace function public.set_ocr_settings(p_org_id uuid, p_enabled boolean, p_provider text DEFAULT NULL::text, p_key_source text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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

  -- `0718`. Whose key pays is a RULE, not a decoration, so hiding
  -- the choice on the screen would be enforcing it nowhere. A
  -- company already on its own key is left alone: withdrawing the
  -- option must not strand somebody mid-month on a key they can no
  -- longer switch away from, and moving them to platform credit
  -- without asking would spend their money for them.
  if v_source = 'own'
     and coalesce(s.key_source, 'platform') <> 'own'
     and not app.scan_surface('scan_allow_own_key') then
    raise exception
      'Reading on your own key is not offered on this platform. '
      'Scanning runs on credit bought here.'
      using errcode = '42501';
  end if;

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
$function$;
