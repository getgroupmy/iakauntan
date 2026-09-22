-- =====================================================================
-- iAkauntan :: 0678 a default that was a name in a function body
--
--     PostgrestException(message: Claude is not available, code: 23514)
--
-- reported from the Settings screen of a company whose administrator
-- had just switched Gemini ON and Claude OFF in the console, and then
-- went to switch scanning on.
--
-- ---------------------------------------------------------------------
-- What actually happened
--
-- `ocr_status` (0113) answered
--
--     v_provider := coalesce(s.provider, 'claude');
--
-- for a company that has never chosen a reader. The Settings card then
-- echoed that back on the toggle --
--
--     setOcrSettings(enabled: true, provider: ocr.provider, ...)
--
-- -- and `set_ocr_settings` refused it, because Claude had just been
-- retired. Nothing in the console had told the tenant anything,
-- because the console cannot: the name of the reader a company falls
-- back to was a string literal in a function body, so switching
-- readers on and off in the catalog changed what was ON OFFER and
-- never changed what anybody GOT.
--
-- The screen then closed the loop. The reader dropdown is drawn inside
-- `if (ocr.enabled)`, so the only way to choose a different reader was
-- to switch scanning on first -- which is the call that was failing.
-- A company in this state could not reach the control that fixes it
-- from any screen it has.
--
-- Three things, then, and all three are needed. This file is the two
-- in the database.
--
-- ---------------------------------------------------------------------
-- 1. A default that can be set, and one that can be worked out
--
-- `set_platform_ai_default` (0536) already does this for the
-- assistant, and the shape is worth copying rather than inventing: a
-- row in `platform_settings`, refused unless it names something that
-- can actually answer.
--
-- The derived fallback underneath it matters as much. A platform that
-- has never set a default must still not hand out the name of a
-- retired reader, so the fallback is the first ACTIVE reader that is
-- READY -- `ready` being 0113's own test, that a reader talking to an
-- LLM has a model to talk to. `'claude'` survives only as the last
-- resort when the catalog holds nothing usable at all, where any
-- answer is wrong and a familiar one is easiest to diagnose.
-- ---------------------------------------------------------------------
create or replace function app.ocr_provider_ready(p public.ocr_providers)
returns boolean language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select p.kind not in ('anthropic', 'openai')
      or coalesce(btrim(coalesce(p.model, '')), '') <> '';
$$;

comment on function app.ocr_provider_ready(public.ocr_providers) is
  'Whether a reader has everything it needs to be sent a document. '
  'One expression, named, because `ocr_status` reports it, '
  '`set_ocr_settings` refuses on it and `app.default_ocr_provider` '
  'picks by it -- and three copies of a test is three chances for a '
  'reader to be offered by one and refused by another.';

create or replace function app.default_ocr_provider()
returns text language sql stable
set search_path = public, app, pg_temp as $$
  select coalesce(
    -- What the platform chose, if it is still usable. Checked again
    -- here and not trusted from the setting: a default set last year
    -- names a reader that may have been retired since, and a stale
    -- default is the exact bug this file is about.
    (select p.code from public.ocr_providers p
      where p.is_active and app.ocr_provider_ready(p)
        and p.code = (select s.value #>> '{}'
                        from public.platform_settings s
                       where s.key = 'ocr_default_provider')),
    -- Nothing chosen, or what was chosen is gone: the first reader on
    -- offer, in the order the catalog itself is shown in.
    (select p.code from public.ocr_providers p
      where p.is_active and app.ocr_provider_ready(p)
      order by p.sort_order, p.code
      limit 1),
    'claude');
$$;

comment on function app.default_ocr_provider() is
  'The reader a company that has never chosen one falls back to: what '
  'a platform administrator set, if it is still active and still has a '
  'model; otherwise the first active, ready reader by sort order. '
  'Until 0678 this was the literal ''claude'' inside `ocr_status`, so '
  'retiring Claude in the console left every company that had not '
  'chosen for itself pointed at a reader the same console would then '
  'refuse to switch on.';

create or replace function public.platform_set_default_ocr_provider(
  p_code text)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare pr public.ocr_providers;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required'
      using errcode = '42501';
  end if;

  select * into pr from public.ocr_providers
   where code = btrim(coalesce(p_code, ''));
  if pr.code is null then
    raise exception 'No reader is called %', p_code using errcode = '23514';
  end if;
  if not pr.is_active then
    raise exception
      '% is switched off, so it cannot be what a company falls back to.',
      pr.name using errcode = '23514';
  end if;
  if not app.ocr_provider_ready(pr) then
    raise exception
      'No model is set for %, so it cannot be what a company falls back to.',
      pr.name using errcode = '23514';
  end if;

  insert into public.platform_settings
    (key, value, description, updated_by, updated_at)
  values ('ocr_default_provider', to_jsonb(pr.code),
          'The reader a company that has not chosen one of its own is '
          'offered. Set in the console; falls back to the first active '
          'reader if the one named here is later retired.',
          auth.uid(), now())
  on conflict (key) do update
    set value = excluded.value, description = excluded.description,
        updated_by = excluded.updated_by, updated_at = now();
end;
$$;

comment on function public.platform_set_default_ocr_provider(text) is
  'Chooses the reader a company that has never chosen one is offered. '
  'Refuses a reader that is switched off and one with no model set, so '
  'the default can never name something `set_ocr_settings` would then '
  'refuse -- which is the failure 0678 was written for. Platform '
  'administrators only.';

revoke all on function public.platform_set_default_ocr_provider(text)
  from public, anon;
grant execute on function public.platform_set_default_ocr_provider(text)
  to authenticated;

-- What the console shows as selected. Resolved, not raw: an operator
-- looking at this dropdown wants to know what companies ARE getting,
-- which is not the same as what somebody typed into the setting once.
create or replace function public.ocr_default_provider()
returns text language sql stable security definer
set search_path = public, app, pg_temp as $$
  select app.default_ocr_provider();
$$;

comment on function public.ocr_default_provider() is
  'The reader a company that has never chosen one falls back to, '
  'resolved: the platform''s choice if it is still usable, otherwise '
  'the first active ready reader. No secret in it -- `ocr_status` '
  'already carries the same code to every tenant -- so the console can '
  'ask it without a platform-admin round trip.';

revoke all on function public.ocr_default_provider() from public, anon;
grant execute on function public.ocr_default_provider()
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. What the settings screen is told
--
-- Three additions, and each one exists because the screen could not
-- draw the fix without it:
--
--   default_provider  what an unchosen company is being offered, so
--                     the card can say where the suggestion came from.
--   chosen            whether this company ever picked a reader at
--                     all. Without it the screen cannot tell a
--                     deliberate choice of Claude from the literal
--                     that 0113 handed out to everybody.
--   is_active         per reader, so a retired one that a company IS
--                     on can be shown as retired rather than shown as
--                     ordinary and then refused on save.
--
-- A company that HAS chosen keeps its choice even when the reader is
-- retired. Silently moving it would send its documents to a different
-- company's servers on the strength of a console toggle, which is not
-- a thing to do quietly; so the choice stands, it is flagged, and the
-- screen asks. A company that has NOT chosen is moved, because there
-- was never a choice to respect.
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

  return jsonb_build_object(
    'enabled',     coalesce(s.is_enabled, false),
    'provider',    v_provider,
    'default_provider', v_default,
    'chosen',      s.provider is not null,
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
-- 3. Saying nothing, and being told why
--
-- `p_provider` defaulted to `'claude'` -- the same literal in a second
-- place. It now defaults to null, meaning "whatever this company is
-- already on, or the platform's default", so a caller that only wants
-- to move the switch does not have to name a reader to do it, and
-- cannot name a stale one by accident.
--
-- And the refusal says what to do. "Claude is not available" is true
-- and leaves somebody staring at a toggle; a retired reader needs a
-- different reader chosen, and the sentence now says so.
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

  -- A reader with nowhere to send the document and no model to send it
  -- to is a 404 waiting for somebody to press Scan. Caught here, where
  -- an operator can still do something about it.
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

comment on function public.set_ocr_settings(uuid, boolean, text, text) is
  'Switches document scanning on or off and chooses whose key it uses '
  '-- the company''s own or the platform''s. Either may be omitted, in '
  'which case what the company is already on is kept, and a company '
  'that is on nothing yet gets the platform''s default reader: until '
  '0678 the omitted provider was the literal ''claude'', which is what '
  'made retiring Claude in the console break the switch for every '
  'company that had never chosen for itself. Refuses to switch on a '
  'reader that is no longer offered, and one with nowhere to send the '
  'document and no model to send it to -- caught HERE, where an '
  'operator can still do something about it, rather than becoming a '
  '404 waiting for somebody to press Scan. Needs `can_admin`.';

-- ---------------------------------------------------------------------
-- 4. A key in the pool is a key
--
-- Not the reported bug, and the same shape of one. `0675` gave a
-- company a SECOND place to keep its own keys, and both gates that ask
-- "has this company got a key?" were written in 0111 and 0113, before
-- that place existed:
--
--   `set_ocr_settings` refuses to switch scanning on with `own` and no
--   row in `org_ocr_credentials` -- fixed above;
--
--   `ocr_begin` refuses every scan for the same reason -- fixed here.
--
-- Left as it was, a company that put three Gemini keys in the pool and
-- nothing in the single-key field would have been told `The Gemini key
-- has been removed; scanning cannot run` at the moment it pressed Scan,
-- with three keys visibly sitting on the screen it had just filled in.
-- The pool is consulted FIRST by the edge function (`credentialFor`),
-- so the guard was refusing a scan that would have worked.
--
-- The rest of the body is 0113's, unchanged.
-- ---------------------------------------------------------------------
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

  -- Retired between switching scanning on and pressing Scan. Said here
  -- rather than left to become whatever the vendor returns to a key
  -- nobody is paying for any more.
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
