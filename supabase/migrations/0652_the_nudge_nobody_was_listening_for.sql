-- =====================================================================
-- The nudge nobody was listening for
--
-- Reported as: changes made in the platform console do not reach the
-- mobile app until it is relaunched.
--
-- Two faults, and only together do they produce that. Each on its own
-- would have been covered by the other, which is why neither was
-- noticed.
--
-- ## One: the broadcast went to a topic nothing subscribes to
--
-- `0322` puts a statement trigger on the landing tables — and `0647`
-- on `site_pages` — that calls
--
--     realtime.send(jsonb_build_object('table', tg_table_name),
--                   'changed', 'landing', false);
--
-- The third argument is the TOPIC. The app subscribes with
-- `client.channel('platform')` in `core/platform_live.dart`, and
-- `realtime_client`'s `channel(topic)` builds `realtime:$topic` — so it
-- is listening on `realtime:platform` while every nudge since `0322` has
-- gone to `realtime:landing`.
--
-- Nothing reported it. A broadcast to a topic with no subscribers is
-- not an error at either end: the trigger succeeds, the socket stays
-- connected, and `channel.onBroadcast` simply never fires. The one
-- screen the mechanism was written for — the front page, read by people
-- who are not signed in — has never updated itself.
--
-- ## Two: `site_pages` is admin-only, so the other path is empty too
--
-- The app has a second route for the same news: `onPostgresChanges` on
-- each watched table, which carries the row and is therefore delivered
-- under RLS, per subscriber. For `landing_page`, `landing_sections`,
-- `platform_modules` and the rest that is fine — every one of them has
-- `for select using (true)`, so any signed-in subscriber receives the
-- change.
--
-- `site_pages` does not. Its only policy is
--
--     site_pages_admin ... using (app.is_platform_admin())
--
-- which is right — the table is the platform's, and `site_pages()` is
-- how a visitor reads it — and it means Realtime delivers a row to
-- platform administrators AND NOBODY ELSE. An ordinary signed-in user
-- receives nothing when the terms, the privacy policy or the sign-in
-- wording changes.
--
-- So for everyone except a platform admin, both paths were empty. The
-- providers then hold what they were told at startup, which is a screen
-- confidently out of date with no reason to refetch — and on a phone,
-- where the process survives for days, "no reason to refetch" means
-- until the app is relaunched. On a browser tab it was masked by
-- ordinary reloads.
--
-- ## The fix is the topic, and only the topic
--
-- The broadcast carries THE TABLE NAME AND NOTHING ELSE, deliberately
-- (`0322` argues it at length: the topic is public, so a draft must not
-- travel on it). That is exactly what makes it the right path for a
-- subscriber who may not read the row — there is no row. Pointed at the
-- topic the app actually listens on, it covers the signed-out visitor
-- AND the signed-in non-admin in one go.
--
-- `onPostgresChanges` is left alone. It is more precise where it works,
-- and the two together are belt and braces rather than a choice.
--
-- The function keeps its name. Eight triggers name it and
-- `create or replace` keeps every one of them; renaming it to match
-- what it now does would mean recreating all eight for a word.
--
-- ## And a gate, because this failed silently for 330 migrations
--
-- `scripts/check_realtime_topic.py` reads the topic out of this
-- function and the channel name out of `platform_live.dart` and refuses
-- a mismatch. Nothing else can: the two halves are in different
-- languages, neither is wrong on its own, and the symptom is a message
-- that is never delivered.
-- =====================================================================

create or replace function app.landing_touched()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp as $$
begin
  -- Only the table name travels. Deliberately not `new` or `old`: the
  -- topic is public, and the whole point is that a draft stays behind
  -- `landing_page()` and `site_pages()`.
  --
  -- The topic is 'platform' because that is the channel
  -- `core/platform_live.dart` opens. Changing either without the other
  -- silently stops every client being told anything, which is what
  -- `scripts/check_realtime_topic.py` exists to prevent.
  if to_regprocedure('realtime.send(jsonb, text, text, boolean)') is not null
  then
    perform realtime.send(
      jsonb_build_object('table', tg_table_name),
      'changed',
      'platform',
      false);
  end if;
  return null;
end;
$$;

revoke all on function app.landing_touched() from public, anon;

comment on function app.landing_touched is
  'Broadcasts the NAME of a changed platform table to the public '
  '`platform` topic, which is the channel core/platform_live.dart '
  'opens. Carries no row, so it reaches subscribers who could not read '
  'one -- a signed-out visitor, and any user who is not a platform '
  'administrator.';

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text;
  v_missing text;
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'landing_touched';

  if v_src is null then
    raise exception '0652: app.landing_touched is gone';
  end if;
  if v_src not like '%''platform''%' then
    raise exception '0652: the nudge does not name the platform topic';
  end if;
  -- The old topic must be gone, not merely joined by the new one: two
  -- sends would be two messages for one edit.
  if v_src like '%''landing'',%' then
    raise exception '0652: the nudge still goes to the landing topic';
  end if;

  -- Every table that nudges still nudges. `create or replace` keeps the
  -- triggers, and this says so rather than assuming it.
  select string_agg(want, ', ') into v_missing
    from unnest(array['landing_page', 'landing_sections',
                      'landing_app_links', 'landing_stats',
                      'landing_testimonials', 'landing_logos',
                      'platform_modules', 'site_pages']) as want
   where not exists (
     select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
      where c.relname = want
        and t.tgname = 'trg_' || want || '_landing_touched'
        and not t.tgisinternal);
  if v_missing is not null then
    raise exception '0652: these tables stopped nudging: %', v_missing;
  end if;
end
$do$;
