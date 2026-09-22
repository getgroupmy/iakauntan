-- =====================================================================
-- iAkauntan :: 0675 a pool of reader keys, each with a budget and a
--                   clock
--
-- `0113` made the readers data. The key behind a reader stayed one
-- thing: `OCR_KEY_<CODE>` in the function's environment for the
-- platform, one row in `org_ocr_credentials` for a company that brought
-- its own. One key, no limits, no rotation.
--
-- That is the wrong shape for the reader this migration adds. Google AI
-- Studio's free tier is capped by REQUESTS PER MINUTE and REQUESTS PER
-- DAY, per key — so the way anybody actually runs it is several keys
-- with the traffic spread across them, and a key that has spent its
-- allowance stood down until the window rolls over. A single secret in
-- an environment variable cannot express that, and adding a second key
-- would be a deploy.
--
-- ---------------------------------------------------------------------
-- What a key carries
--
-- Two independent gates, and a key is used only when BOTH let it
-- through:
--
--   a BUDGET   per minute, per day, per month. Null is no cap. This is
--              the one that matters for a free tier.
--   a CLOCK    hours of the day, days of the week, months of the year.
--              Empty is always. This is for a key that belongs to a
--              billing account somebody wants used only at certain
--              times -- an overnight key, a month-end key.
--
-- Kept apart because they fail differently and a person reading the
-- console needs to know which happened: "spent" comes back tomorrow by
-- itself, "out of hours" comes back at six.
--
-- ---------------------------------------------------------------------
-- The counters are on the row, not in a log
--
-- Three windows, three counts, three window starts, rolled forward when
-- the claim notices the window has moved. A usage table would be more
-- faithful and would need pruning forever; this answers the only
-- question anybody asks -- "has this key got anything left right now" --
-- in one UPDATE that is also the claim, so two requests cannot both
-- spend the last call in the minute.
--
-- The day and the month are MALAYSIAN, like everything else in this
-- schema (`app.today`). Google's own free-tier day rolls over on
-- Pacific time, so a cap set here is a budget of OUR OWN rather than a
-- mirror of Google's counter -- which is the honest way round: you set
-- yours under theirs and never find out what theirs was.
--
-- ---------------------------------------------------------------------
-- Where the keys live, and who can read them
--
-- `public.ocr_provider_keys`, RLS on with no policies and grants
-- revoked from anon and authenticated -- exactly as
-- `org_ocr_credentials` (0111) and `ai_provider_credentials` (0536).
-- The service role reads them and nothing else does. The console reads
-- `public.ocr_keys_for` instead, which returns everything about a key
-- EXCEPT the key: a label, the last four characters, the caps, the
-- clock, and what it has spent. A key you have lost is one you replace.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Gemini, as a row and not as a protocol
--
-- Google AI Studio publishes an OpenAI-compatible endpoint, and `0113`
-- already has a handler for that shape -- it is what ChatGPT and Grok
-- both arrive through. So this reader is a row with an endpoint and a
-- model, and the edge function needs no new branch at all.
--
-- The native `generateContent` API is the other way in and is NOT used
-- here. It would be a fourth protocol for a response we already know
-- how to parse; if its `responseSchema` ever earns its keep, it is a
-- new `kind` and this row changes endpoint.
--
-- `is_active` false on arrival. The model below is the one current when
-- this was written and the key pool is empty until somebody fills it,
-- so switching it on before either is checked would be a 404 blamed on
-- the feature. The console switch is what turns it on -- which is the
-- on/off this was asked for.
-- ---------------------------------------------------------------------
insert into public.ocr_providers
  (code, name, kind, endpoint, model, price, takes_key, runs_on_device,
   blurb, is_active, sort_order)
values
  ('gemini', 'Gemini', 'openai',
   'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
   'gemini-2.0-flash', 0.10,
   true, false,
   'Google AI Studio, through the same chat-completions shape as '
   'ChatGPT. Cheap, and quick on a phone photograph. Its free tier is '
   'capped per key per minute and per day, so the platform holds '
   'several keys and moves between them.',
   false, 25)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- The pool
-- ---------------------------------------------------------------------
create table public.ocr_provider_keys (
  id          uuid primary key default gen_random_uuid(),
  provider    text not null references public.ocr_providers (code)
                on update cascade on delete cascade,

  -- Null is the PLATFORM's pool, shared by every tenant on the
  -- platform's key. A uuid is that one company's own pool. One table
  -- for both, as `ai_provider_credentials` does it, because everything
  -- about claiming a key is the same either way and two tables would be
  -- two claim functions that drift.
  org_id      uuid references public.organizations (id) on delete cascade,

  -- What to call it in the console. Not the key and not derived from
  -- it: two keys off the same Google account differ by what they are
  -- for, which only the person who made them knows.
  label       text not null check (btrim(label) <> ''),
  api_key     text not null check (btrim(api_key) <> ''),

  -- The budget. Null is no cap, which is right for a paid key.
  per_minute  integer check (per_minute is null or per_minute > 0),
  per_day     integer check (per_day   is null or per_day   > 0),
  per_month   integer check (per_month is null or per_month > 0),

  -- The clock, in Asia/Kuala_Lumpur. Empty or null is always, which is
  -- what almost every key wants and so is the default.
  --
  -- Written out rather than generated: a check constraint may not
  -- contain a subquery, so `array(select generate_series(0, 23))` is
  -- rejected at CREATE TABLE. The literals are the whole rule and are
  -- easier to read than the expression that would have produced them.
  hours       smallint[] not null default '{}'
                check (hours <@ '{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23}'::smallint[]),
  weekdays    smallint[] not null default '{}'
                check (weekdays <@ '{1,2,3,4,5,6,7}'::smallint[]),
  months      smallint[] not null default '{}'
                check (months <@ '{1,2,3,4,5,6,7,8,9,10,11,12}'::smallint[]),

  -- Stood down by hand. Separate from "spent", which comes back by
  -- itself, and from "out of hours", which comes back at six.
  is_active   boolean not null default true,

  -- What it has spent, and since when. Rolled forward by the claim.
  minute_start timestamptz,
  minute_count integer not null default 0,
  day_start    date,
  day_count    integer not null default 0,
  month_start  date,
  month_count  integer not null default 0,

  -- Round-robin orders on this, so the pool wears evenly rather than
  -- burning the first key to its cap before touching the second.
  last_used_at timestamptz,

  -- The last thing the provider said when this key failed, so a key
  -- that has been revoked at Google's end can be told apart from one
  -- that is merely busy.
  last_error   text,
  last_error_at timestamptz,

  created_by  uuid references auth.users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.ocr_provider_keys enable row level security;
revoke all on public.ocr_provider_keys from anon, authenticated;

comment on table public.ocr_provider_keys is
  'Reader keys, the platform''s (org_id null) and the tenants''. RLS on with no policies and grants revoked: the service role reads these and nothing else does. The console reads public.ocr_keys_for, which never returns a key.';

-- A label is how somebody tells two keys apart in the console, so it
-- has to be unique within the pool it belongs to. Two partial indexes,
-- because a null org_id does not compare equal to another null one.
create unique index ocr_provider_keys_platform_label
  on public.ocr_provider_keys (provider, label) where org_id is null;
create unique index ocr_provider_keys_org_label
  on public.ocr_provider_keys (provider, org_id, label)
  where org_id is not null;

-- The claim's own lookup: the pool for one provider and one owner,
-- freshest-last so round-robin is an index scan.
create index ocr_provider_keys_pool
  on public.ocr_provider_keys (provider, org_id, is_active, last_used_at);

-- ---------------------------------------------------------------------
-- Is this key allowed to run at this moment?
--
-- Pure and separate from the claim, so the rule can be asserted against
-- a table of times rather than by making requests. Empty is always:
-- three empty arrays is the ordinary key, and reading that as "never"
-- would stand the whole pool down the moment it was filled.
--
-- `p_at` is a timestamptz; the arrays are read in Asia/Kuala_Lumpur,
-- because an operator setting "nine to six" means nine to six here.
-- ---------------------------------------------------------------------
create or replace function app.ocr_key_in_window(
  p_hours    smallint[],
  p_weekdays smallint[],
  p_months   smallint[],
  p_at       timestamptz default now())
returns boolean
language sql immutable
set search_path = pg_catalog, public, app, pg_temp
as $$
  select
    (coalesce(array_length(p_hours, 1), 0) = 0
       or extract(hour from (p_at at time zone 'Asia/Kuala_Lumpur'))::smallint
          = any (p_hours))
    and
    (coalesce(array_length(p_weekdays, 1), 0) = 0
       or extract(isodow from (p_at at time zone 'Asia/Kuala_Lumpur'))::smallint
          = any (p_weekdays))
    and
    (coalesce(array_length(p_months, 1), 0) = 0
       or extract(month from (p_at at time zone 'Asia/Kuala_Lumpur'))::smallint
          = any (p_months));
$$;

comment on function app.ocr_key_in_window(smallint[], smallint[], smallint[], timestamptz) is
  'Whether a key''s clock allows it at this moment, in Asia/Kuala_Lumpur. Empty arrays mean always.';

-- ---------------------------------------------------------------------
-- Take a key out of the pool, and spend one call of its budget
--
-- One statement, so two requests arriving in the same millisecond
-- cannot both spend the last call in the minute. `for update skip
-- locked` rather than plain `for update`: a row another request is
-- already spending is one this request should walk past, not queue
-- behind.
--
-- The windows roll INSIDE the update. A key whose minute has passed
-- starts a new minute at one rather than being reset by a sweeper that
-- would have to run every minute forever.
--
-- Returns null when the pool has nothing to give, and the caller is
-- expected to say which of the three reasons it was -- `ocr_keys_for`
-- is what it asks.
-- ---------------------------------------------------------------------
create or replace function app.claim_ocr_key(
  p_provider text,
  p_org_id   uuid default null)
returns table (key_id uuid, api_key text, label text)
language sql volatile
set search_path = pg_catalog, public, app, pg_temp
as $$
  with now_at as (
    select now() as ts,
           (now() at time zone 'Asia/Kuala_Lumpur')::date as today,
           date_trunc('month',
             (now() at time zone 'Asia/Kuala_Lumpur')::date)::date as this_month,
           date_trunc('minute', now()) as this_minute
  ),
  pick as (
    select k.id
      from public.ocr_provider_keys k, now_at n
     where k.provider = p_provider
       and k.org_id is not distinct from p_org_id
       and k.is_active
       and app.ocr_key_in_window(k.hours, k.weekdays, k.months, n.ts)
       -- A count from a window that has since rolled is not a count.
       and (k.per_minute is null
            or k.minute_start is distinct from n.this_minute
            or k.minute_count < k.per_minute)
       and (k.per_day is null
            or k.day_start is distinct from n.today
            or k.day_count < k.per_day)
       and (k.per_month is null
            or k.month_start is distinct from n.this_month
            or k.month_count < k.per_month)
     -- Evenly, so the pool wears at one rate. Never used comes first.
     order by k.last_used_at asc nulls first, k.created_at asc
     limit 1
     for update skip locked
  )
  update public.ocr_provider_keys k
     set minute_start = n.this_minute,
         minute_count = case when k.minute_start is distinct from n.this_minute
                             then 1 else k.minute_count + 1 end,
         day_start    = n.today,
         day_count    = case when k.day_start is distinct from n.today
                             then 1 else k.day_count + 1 end,
         month_start  = n.this_month,
         month_count  = case when k.month_start is distinct from n.this_month
                             then 1 else k.month_count + 1 end,
         last_used_at = n.ts,
         updated_at   = n.ts
    from now_at n
   where k.id = (select id from pick)
  returning k.id, k.api_key, k.label;
$$;

comment on function app.claim_ocr_key(text, uuid) is
  'Takes the next key from a pool and spends one call of its budget, atomically. Null when nothing in the pool is both in its window and under its caps. Service role only: it returns a key.';

revoke all on function app.claim_ocr_key(text, uuid) from public, anon, authenticated;
grant execute on function app.claim_ocr_key(text, uuid) to service_role;

-- ---------------------------------------------------------------------
-- What the provider said when a key failed
--
-- Recorded so a key revoked at Google's end reads differently in the
-- console from one that is merely busy. Not a refusal: a key that
-- errored once is still in the pool, because the commonest error is a
-- rate limit we have already stopped causing.
-- ---------------------------------------------------------------------
create or replace function app.note_ocr_key_error(
  p_key_id uuid, p_error text)
returns void
language sql volatile
set search_path = pg_catalog, public, app, pg_temp
as $$
  update public.ocr_provider_keys
     set last_error = left(p_error, 500),
         last_error_at = now(),
         updated_at = now()
   where id = p_key_id;
$$;

revoke all on function app.note_ocr_key_error(uuid, text) from public, anon, authenticated;
grant execute on function app.note_ocr_key_error(uuid, text) to service_role;

-- ---------------------------------------------------------------------
-- What the console sees
--
-- Everything about a key except the key. The last four characters are
-- there so two keys off the same account can be told apart against the
-- provider's own console, and four is short enough to be useless to
-- anybody who obtains it.
--
-- `spent_*` are the counts AS THEY STAND, which means a count from a
-- window that has rolled reads as nought rather than as yesterday's
-- number. A console showing 1,500 of 1,500 spent at nine in the
-- morning would send somebody looking for a problem that fixed itself
-- at midnight.
-- ---------------------------------------------------------------------
create or replace function public.ocr_keys_for(
  p_provider text,
  p_org_id   uuid default null)
returns table (
  id            uuid,
  label         text,
  key_tail      text,
  per_minute    integer,
  per_day       integer,
  per_month     integer,
  hours         smallint[],
  weekdays      smallint[],
  months        smallint[],
  is_active     boolean,
  in_window     boolean,
  spent_minute  integer,
  spent_day     integer,
  spent_month   integer,
  has_headroom  boolean,
  last_used_at  timestamptz,
  last_error    text,
  last_error_at timestamptz,
  created_at    timestamptz)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if p_org_id is null then
    if not app.is_platform_admin() then
      raise exception 'Only the platform may look at the platform''s keys'
        using errcode = '42501';
    end if;
  elsif not (app.can_admin(p_org_id) or app.is_platform_admin()) then
    raise exception 'You cannot look at this organization''s keys'
      using errcode = '42501';
  end if;

  return query
  with n as (
    select now() as ts,
           (now() at time zone 'Asia/Kuala_Lumpur')::date as today,
           date_trunc('month',
             (now() at time zone 'Asia/Kuala_Lumpur')::date)::date as this_month,
           date_trunc('minute', now()) as this_minute
  )
  select k.id,
         k.label,
         right(k.api_key, 4),
         k.per_minute, k.per_day, k.per_month,
         k.hours, k.weekdays, k.months,
         k.is_active,
         app.ocr_key_in_window(k.hours, k.weekdays, k.months, n.ts),
         case when k.minute_start is distinct from n.this_minute
              then 0 else k.minute_count end,
         case when k.day_start is distinct from n.today
              then 0 else k.day_count end,
         case when k.month_start is distinct from n.this_month
              then 0 else k.month_count end,
         (k.per_minute is null
            or k.minute_start is distinct from n.this_minute
            or k.minute_count < k.per_minute)
         and (k.per_day is null
            or k.day_start is distinct from n.today
            or k.day_count < k.per_day)
         and (k.per_month is null
            or k.month_start is distinct from n.this_month
            or k.month_count < k.per_month),
         k.last_used_at,
         k.last_error, k.last_error_at,
         k.created_at
    from public.ocr_provider_keys k, n
   where k.provider = p_provider
     and k.org_id is not distinct from p_org_id
   order by k.created_at;
end;
$$;

comment on function public.ocr_keys_for(text, uuid) is
  'A pool as the console sees it: everything about each key except the key. The last four characters only, so two can be told apart.';

revoke all on function public.ocr_keys_for(text, uuid) from public, anon;
grant execute on function public.ocr_keys_for(text, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Adding one, changing one, removing one
--
-- `p_api_key` null on an update means "leave the key alone", which is
-- what lets somebody change a cap without retyping a secret they no
-- longer have. A blank string is refused rather than stored, because a
-- key that is the empty string is a key that fails at the provider with
-- a message about authentication.
-- ---------------------------------------------------------------------
create or replace function public.save_ocr_key(
  p_provider   text,
  p_org_id     uuid    default null,
  p_id         uuid    default null,
  p_label      text    default null,
  p_api_key    text    default null,
  p_per_minute integer default null,
  p_per_day    integer default null,
  p_per_month  integer default null,
  p_hours      smallint[] default '{}',
  p_weekdays   smallint[] default '{}',
  p_months     smallint[] default '{}',
  p_is_active  boolean default true)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_id uuid;
begin
  if p_org_id is null then
    if not app.is_platform_admin() then
      raise exception 'Only the platform may keep the platform''s keys'
        using errcode = '42501';
    end if;
  elsif not app.can_admin(p_org_id) then
    raise exception 'You cannot keep keys for this organization'
      using errcode = '42501';
  end if;

  if not exists (select 1 from public.ocr_providers
                  where code = p_provider and takes_key) then
    raise exception 'That reader does not take a key'
      using errcode = '23514';
  end if;

  if p_id is null then
    if btrim(coalesce(p_api_key, '')) = '' then
      raise exception 'A key is needed to add one'
        using errcode = '23514';
    end if;
    insert into public.ocr_provider_keys
      (provider, org_id, label, api_key, per_minute, per_day, per_month,
       hours, weekdays, months, is_active, created_by)
    values
      (p_provider, p_org_id, btrim(coalesce(p_label, 'Key')),
       btrim(p_api_key), p_per_minute, p_per_day, p_per_month,
       coalesce(p_hours, '{}'), coalesce(p_weekdays, '{}'),
       coalesce(p_months, '{}'), coalesce(p_is_active, true), auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  update public.ocr_provider_keys
     set label      = coalesce(btrim(p_label), label),
         -- Null leaves it alone; blank is refused above rather than
         -- being stored as a key nobody can use.
         api_key    = case when btrim(coalesce(p_api_key, '')) = ''
                           then api_key else btrim(p_api_key) end,
         per_minute = p_per_minute,
         per_day    = p_per_day,
         per_month  = p_per_month,
         hours      = coalesce(p_hours, '{}'),
         weekdays   = coalesce(p_weekdays, '{}'),
         months     = coalesce(p_months, '{}'),
         is_active  = coalesce(p_is_active, is_active),
         updated_at = now()
   where id = p_id
     and provider = p_provider
     and org_id is not distinct from p_org_id
  returning id into v_id;

  if v_id is null then
    raise exception 'That key is not in this pool' using errcode = '42704';
  end if;
  return v_id;
end;
$$;

comment on function public.save_ocr_key(
  text, uuid, uuid, text, text, integer, integer, integer,
  smallint[], smallint[], smallint[], boolean) is
  'Adds a key to a reader''s pool, or changes one. `p_org_id` null is '
  'the platform''s pool and needs a platform administrator; a uuid is '
  'that company''s own and needs an administrator of it. On an update '
  'a null `p_api_key` LEAVES THE KEY ALONE, which is what lets a cap '
  'be raised without retyping a secret nobody still has; a blank one '
  'is refused rather than stored, because a key that is the empty '
  'string fails at the provider with a message about authentication. '
  'Caps are per minute, per day and per month, null for no cap; the '
  'clock arrays are Asia/Kuala_Lumpur and empty means always. The key '
  'cannot be read back by anything but the service role.';

revoke all on function public.save_ocr_key(
  text, uuid, uuid, text, text, integer, integer, integer,
  smallint[], smallint[], smallint[], boolean) from public, anon;
grant execute on function public.save_ocr_key(
  text, uuid, uuid, text, text, integer, integer, integer,
  smallint[], smallint[], smallint[], boolean) to authenticated;

create or replace function public.delete_ocr_key(
  p_provider text, p_id uuid, p_org_id uuid default null)
returns void
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if p_org_id is null then
    if not app.is_platform_admin() then
      raise exception 'Only the platform may remove the platform''s keys'
        using errcode = '42501';
    end if;
  elsif not app.can_admin(p_org_id) then
    raise exception 'You cannot remove keys for this organization'
      using errcode = '42501';
  end if;

  delete from public.ocr_provider_keys
   where id = p_id
     and provider = p_provider
     and org_id is not distinct from p_org_id;
end;
$$;

comment on function public.delete_ocr_key(text, uuid, uuid) is
  'Takes a key out of a pool for good. `p_org_id` null is the '
  'platform''s pool and needs a platform administrator; a uuid is that '
  'company''s own. Deleting the last usable key in a pool does not '
  'switch the reader off -- scans then fail at the claim with nothing '
  'to give, which `ocr_key_pool_size` is what Settings asks to warn '
  'about beforehand.';

revoke all on function public.delete_ocr_key(text, uuid, uuid) from public, anon;
grant execute on function public.delete_ocr_key(text, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- How many keys a pool has, for the screen that chooses a reader
--
-- A reader switched on with an empty pool is a reader that fails at the
-- first scan, so Settings needs to be able to say so before anybody
-- picks it. Counts only -- no labels, no tails -- so this one is
-- readable by any member rather than by an administrator.
-- ---------------------------------------------------------------------
create or replace function public.ocr_key_pool_size(
  p_provider text, p_org_id uuid default null)
returns jsonb
language sql stable security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  select jsonb_build_object(
    'keys', count(*),
    'usable', count(*) filter (
      where k.is_active
        and app.ocr_key_in_window(k.hours, k.weekdays, k.months, now())))
    from public.ocr_provider_keys k
   where k.provider = p_provider
     and k.org_id is not distinct from p_org_id;
$$;

revoke all on function public.ocr_key_pool_size(text, uuid) from public, anon;
grant execute on function public.ocr_key_pool_size(text, uuid) to authenticated;
