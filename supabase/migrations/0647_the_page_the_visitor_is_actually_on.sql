-- =====================================================================
-- The page the visitor is actually on
--
-- `0322` made the front page update itself for somebody who is not
-- signed in: every policy on the platform tables is granted to
-- `authenticated`, so Postgres changes cannot reach a stranger, and a
-- trigger broadcasts the NAME of the table that changed to a public
-- topic instead. The client answers by calling the gated function
-- again. Not a word of what was written goes over the wire.
--
-- It listed seven tables: the six landing ones and `platform_modules`,
-- because the price list is part of the page when `show_pricing` is on.
--
-- ## It missed `site_pages`
--
-- Which is the table holding every OTHER public page — the ones
-- `site_page_screen.dart` draws, and that screen watches
-- `platformLiveProvider` exactly as the landing screen does. So it
-- subscribes, and then nothing ever arrives:
--
--   * the Postgres-changes subscription is registered only when
--     somebody is signed in, and the visitor is not;
--   * and `site_pages` has no broadcast trigger.
--
-- The result is the shape worth naming: editing a site page in the
-- console updates it at once for the signed-in administrator who
-- pressed Save, and NEVER for the public visitors the page exists for.
-- The one audience it is written for is the one audience it does not
-- reach, and the screen that would show it is already listening.
--
-- `'site_pages'` is in `_watchers` in `platform_live.dart`, so the
-- client already knows what to do with the name; all that was missing
-- was somebody sending it.
--
-- ## Nothing is opened
--
-- Same trigger function, same public topic, same rule: the broadcast
-- carries `site_pages` and nothing else, and the refetch goes back
-- through the function that decides whether a page is published. A
-- draft stays a draft. `0322`'s own argument about a forged nudge
-- applies unchanged — the worst it achieves is a client re-reading a
-- page it is allowed to read.
-- =====================================================================

do $$
begin
  execute format(
    'drop trigger if exists %I on public.site_pages',
    'trg_site_pages_landing_touched');
  execute format(
    'create trigger %I after insert or update or delete on public.site_pages '
    'for each statement execute function app.landing_touched()',
    'trg_site_pages_landing_touched');
end $$;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_def text;
  v_missing text;
begin
  select pg_get_triggerdef(t.oid) into v_def
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
   where c.relname = 'site_pages'
     and t.tgname = 'trg_site_pages_landing_touched';

  if v_def is null then
    raise exception 'site_pages still sends no nudge';
  end if;

  -- For each STATEMENT, like the other seven. A row-level trigger on a
  -- bulk edit would send one message per row and the client settles a
  -- burst anyway, so the rows would be work nobody reads.
  if v_def not like '%FOR EACH STATEMENT%' then
    raise exception 'the site_pages nudge fires per row: %', v_def;
  end if;
  if v_def not like '%INSERT OR DELETE OR UPDATE%'
     and v_def not like '%INSERT OR UPDATE OR DELETE%' then
    raise exception 'the site_pages nudge does not cover every edit: %', v_def;
  end if;

  -- And the seven that were already there are still there. This file
  -- adds one; it must not be read later as the place the list lives.
  select string_agg(want, ', ') into v_missing
    from unnest(array['landing_page', 'landing_sections', 'landing_app_links',
                      'landing_stats', 'landing_testimonials', 'landing_logos',
                      'platform_modules']) as want
   where not exists (
     select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
      where c.relname = want
        and t.tgname = 'trg_' || want || '_landing_touched');
  if v_missing is not null then
    raise exception 'tables 0322 nudged no longer do: %', v_missing;
  end if;
end $do$;
