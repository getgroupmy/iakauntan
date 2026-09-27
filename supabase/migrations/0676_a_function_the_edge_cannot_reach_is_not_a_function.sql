-- =====================================================================
-- iAkauntan :: 0676 a function the edge function cannot reach is not a
--                   function
--
-- `0675` put `claim_ocr_key` and `note_ocr_key_error` in the `app`
-- schema, where the rest of this database's guards live. That is the
-- right neighbourhood for a guard and the wrong one for this: the
-- caller is `supabase/functions/ocr`, which reaches the database
-- through PostgREST, and PostgREST serves the schemas the project
-- exposes. `app` is not one of them, so `db.rpc("claim_ocr_key")` would
-- have looked for `public.claim_ocr_key`, found nothing, and fallen
-- through to the older key arrangements on every single scan -- which
-- is the worst possible failure, because it WORKS. The pool would have
-- sat there filled and unused, the counters would have stayed at
-- nought, and the console would have shown a pool with nothing spent
-- out of it while Google's quota came off the one key in the
-- environment.
--
-- `public.ocr_finish` is the shape to copy and has been since `0111`:
-- in `public` so the function can call it, `security definer` so it
-- carries its own rights, and granted to `service_role` ALONE because
-- what it does is not a tenant's to do. `0618` is a migration about
-- forgetting exactly that grant.
--
-- The bodies are unchanged. `app.ocr_key_in_window` stays where it is
-- and is not moved: it is a helper that two `public` functions call,
-- not an entry point, and nothing outside the database asks it
-- anything.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Take a key out of the pool, and spend one call of its budget
--
-- Body as `0675` wrote it. One statement, so two requests arriving in
-- the same millisecond cannot both spend the last call in the minute;
-- `for update skip locked` so a row another request is already spending
-- is walked past rather than queued behind; and the windows roll inside
-- the update, so a key whose minute has passed starts a new minute at
-- one with no sweeper running for ever.
-- ---------------------------------------------------------------------
create or replace function public.claim_ocr_key(
  p_provider text,
  p_org_id   uuid default null)
returns table (key_id uuid, api_key text, label text)
language sql volatile security definer
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

comment on function public.claim_ocr_key(text, uuid) is
  'Takes the next key from a reader''s pool and spends one call of its '
  'budget, atomically. Empty when nothing in the pool is both inside '
  'its clock and under its caps. Granted to the service role alone, '
  'because it returns a key: the edge function calls it, and nothing a '
  'tenant holds can.';

revoke all on function public.claim_ocr_key(text, uuid)
  from public, anon, authenticated;
grant execute on function public.claim_ocr_key(text, uuid) to service_role;

-- ---------------------------------------------------------------------
-- What the provider said when a key failed
-- ---------------------------------------------------------------------
create or replace function public.note_ocr_key_error(
  p_key_id uuid, p_error text)
returns void
language sql volatile security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  update public.ocr_provider_keys
     set last_error = left(p_error, 500),
         last_error_at = now(),
         updated_at = now()
   where id = p_key_id;
$$;

comment on function public.note_ocr_key_error(uuid, text) is
  'Records what a provider said when a key failed, so one revoked at '
  'the provider''s end reads differently in the console from one that '
  'is merely busy. Not a refusal: the key stays in the pool, because '
  'the commonest error is a rate limit the caps have already stopped '
  'us causing. Service role only.';

revoke all on function public.note_ocr_key_error(uuid, text)
  from public, anon, authenticated;
grant execute on function public.note_ocr_key_error(uuid, text) to service_role;

-- ---------------------------------------------------------------------
-- And the two that could not be called go
--
-- Dropped rather than left beside their replacements. Two functions of
-- the same name in two schemas, one reachable and one not, is the next
-- person calling the wrong one -- and the wrong one here fails by
-- silently doing nothing, which is how this was nearly shipped.
--
-- Nothing calls them: `0675` and this migration are one push apart and
-- the edge function has never been deployed against either.
-- ---------------------------------------------------------------------
drop function if exists app.claim_ocr_key(text, uuid);
drop function if exists app.note_ocr_key_error(uuid, text);
