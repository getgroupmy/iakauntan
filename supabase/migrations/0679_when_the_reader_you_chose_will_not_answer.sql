-- =====================================================================
-- iAkauntan :: 0679 when the reader you chose will not answer
--
-- A company picks a reader. That reader's vendor has an afternoon --
-- a rate limit, an outage, a key revoked at the other end -- and every
-- scan in the company stops, with a reference number and nothing to
-- do about it but wait or go into Settings and pick another one.
--
-- There is a reader sitting right there that would have worked: the
-- one the platform hands to a company that has chosen nothing. So a
-- failed scan tries it, once, and only when trying it is free.
--
-- ---------------------------------------------------------------------
-- Free is a condition, not a coincidence
--
-- The fallback reader is used WITHOUT ASKING. Nobody chose it for this
-- company, nobody was shown its price, and the scan that reaches it
-- has already failed once. Charging for it would be billing a company
-- for a decision it did not make, on a second attempt it did not ask
-- for, at a price it never saw.
--
-- So `price = 0` is a gate rather than a preference. A platform that
-- sets a chargeable reader as its default simply has no fallback, and
-- the console says so rather than quietly billing for one.
--
-- The same argument settles whose key it runs on: the PLATFORM'S. A
-- company's own key belongs to the reader that company chose. Spending
-- it on a different vendor -- one it may have no account with, may
-- have deliberately avoided, may be forbidden by its own policy from
-- sending documents to -- because our first choice timed out is not a
-- fallback, it is a decision made on somebody else's behalf with
-- somebody else's money.
--
-- ---------------------------------------------------------------------
-- Once
--
-- One retry, on one reader, and if that fails the scan fails. A chain
-- of fallbacks is a way to turn a five-second failure into a minute of
-- them while the document sits there, and every link is another vendor
-- the document has been sent to.
-- =====================================================================

-- Which reader actually read it, when it was not the one that was
-- chosen. Null for every scan that went the ordinary way, which is
-- what makes the column readable: a non-null here is a fallback that
-- happened, and counting them is how anybody finds out a vendor has
-- been having a bad week.
alter table public.ocr_scans
  add column if not exists fell_back_to text;

comment on column public.ocr_scans.fell_back_to is
  'The reader that read this document when the one the company chose '
  'would not answer. Null for an ordinary scan. `provider` still names '
  'what was CHOSEN, and `amount_charged` still records what was '
  'charged for it -- a fallback is always free, so a row with this set '
  'and a charge on it is a scan that was billed for a reader the '
  'company did not pick.';

-- ---------------------------------------------------------------------
-- The one call the edge function makes
--
-- It answers and records in the same statement, because the two coming
-- apart is the failure that would matter: a scan read by a reader
-- whose name is nowhere on it.
--
-- Returns null -- and records nothing -- when there is no fallback to
-- offer, which is every one of:
--
--   * the platform's default IS the reader that just failed;
--   * the default is chargeable, so using it unasked would bill for a
--     choice nobody made;
--   * the default runs on the device, which a server cannot do;
--   * this scan has already fallen back once.
-- ---------------------------------------------------------------------
create or replace function public.ocr_fallback(p_scan_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  sc public.ocr_scans;
  pr public.ocr_providers;
begin
  select * into sc from public.ocr_scans where id = p_scan_id;
  if sc.id is null or sc.fell_back_to is not null then
    return null;
  end if;

  select * into pr from public.ocr_providers
   where code = app.default_ocr_provider();

  if pr.code is null
     or pr.code = sc.provider
     or not pr.is_active
     or not app.ocr_provider_ready(pr)
     or pr.runs_on_device
     or coalesce(pr.price, 0) > 0 then
    return null;
  end if;

  update public.ocr_scans set fell_back_to = pr.code where id = p_scan_id;

  -- `key_source` is not returned and is not a choice. The caller runs
  -- this reader on the platform's keys, because the company's own
  -- belong to the reader the company chose. See the header.
  return jsonb_build_object(
    'provider',      pr.code,
    'provider_name', pr.name,
    'kind',          pr.kind,
    'endpoint',      pr.endpoint,
    'model',         pr.model);
end;
$$;

comment on function public.ocr_fallback(uuid) is
  'The reader a failed scan may try instead, and the record that it '
  'did. Only ever the platform''s default, only when that default is '
  'FREE -- a fallback is used without asking, and charging for a '
  'choice nobody made is not a fallback -- never the reader that just '
  'failed, and never twice for one scan. Returns null when there is no '
  'such reader, which is a platform with no fallback rather than an '
  'error. The service role alone, because it hands back an endpoint '
  'and a model for a reader this company never chose.';

revoke all on function public.ocr_fallback(uuid)
  from public, anon, authenticated;
grant execute on function public.ocr_fallback(uuid) to service_role;

-- ---------------------------------------------------------------------
-- Saying so, on both screens
--
-- A silent fallback is worse than none. A company whose documents are
-- being read by a vendor it did not choose has to be able to find that
-- out BEFORE it happens, not by noticing a column.
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

  -- The same test `ocr_fallback` applies, so the sentence on the
  -- settings card cannot promise a retry that would not happen.
  select * into v_fb from public.ocr_providers p
   where p.code = v_default
     and p.code <> v_provider
     and p.is_active
     and app.ocr_provider_ready(p)
     and not p.runs_on_device
     and coalesce(p.price, 0) = 0;

  return jsonb_build_object(
    'enabled',     coalesce(s.is_enabled, false),
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

-- What the console needs to show whether a fallback exists at all, and
-- why not when there is none. Counts and codes; nothing a tenant could
-- not already read off `ocr_status`.
create or replace function public.ocr_default_state()
returns jsonb language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_code text := app.default_ocr_provider();
  pr     public.ocr_providers;
begin
  select * into pr from public.ocr_providers where code = v_code;
  return jsonb_build_object(
    'provider', v_code,
    'name',     coalesce(pr.name, v_code),
    'price',    coalesce(pr.price, 0),
    -- A default that is free is also the fallback. One reader, two
    -- jobs, and the second is conditional on the first being free --
    -- so the console can say which of the two this reader is doing.
    'is_free',  coalesce(pr.price, 0) = 0,
    'runs_on_device', coalesce(pr.runs_on_device, false),
    'is_fallback', coalesce(pr.price, 0) = 0
                   and coalesce(pr.is_active, false)
                   and not coalesce(pr.runs_on_device, false));
end;
$$;

comment on function public.ocr_default_state() is
  'The reader an unchosen company is handed, and whether it is also '
  'the one a failed scan retries on -- which it is exactly when it is '
  'free and can run on a server. Two jobs for one row, and the console '
  'has to be able to say which of them it is doing, because a platform '
  'that sets a chargeable default silently has no fallback at all.';

revoke all on function public.ocr_default_state() from public, anon;
grant execute on function public.ocr_default_state()
  to authenticated, service_role;
