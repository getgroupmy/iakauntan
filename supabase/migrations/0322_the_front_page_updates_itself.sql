-- The front page updates itself.
--
-- `0302` put the platform's own tables on the wire so a change made in
-- the console reaches everybody else's browser without a reload, and
-- `platform_live.dart` subscribes to them. It has never worked on the
-- landing page, for a reason that is written down in the file itself:
--
--     It needs a signed-in user, because every policy on these tables
--     is granted to `authenticated` and a channel opened without one
--     can only ever receive nothing.
--
-- Which is true, and means the one page where nobody is signed in — the
-- front page, read by strangers — was the one page that never updated.
-- Edit the headline in the console and the visitor sees it on their
-- next reload, whenever that is.
--
-- ## A nudge, not the row
--
-- The obvious fix is to let `anon` select from `landing_page` so
-- Postgres changes reach them. That would undo the thing this schema is
-- careful about: the tables are shut, `landing_page()` is the only way
-- in, and it withholds everything until `is_published`. Opening the
-- table would put every half-written draft on the socket.
--
-- So the socket carries no content. A trigger sends the name of the
-- table that changed to a public broadcast topic, and the browser
-- answers it by calling `landing_page()` again — the same gated
-- function, applying the same publish rule, returning null for a draft
-- exactly as it does today. What a listener learns is that somebody
-- edited something, and which table. Not a word of what they wrote.
--
-- The topic is public (`private => false`) because the listener is
-- anonymous by definition; there is no session to authorize. That also
-- means anyone can send to it, and the worst a forged nudge achieves is
-- a browser re-reading a page it is allowed to read — so the client
-- settles a burst before acting rather than fetching per message.
--
-- ## Why it is defensive about `realtime.send`
--
-- CI runs these migrations against a real `supabase start`, where the
-- function exists. The no-Docker development harness in
-- `scripts/localdb/` is Postgres and this repository's SQL, with no
-- Realtime at all — and a migration that cannot be applied there stops
-- being run before it is pushed, which is worse than a trigger that
-- quietly does nothing on a machine with nobody to notify.

create or replace function app.landing_touched()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp as $$
begin
  -- Only the table name travels. Deliberately not `new` or `old`:
  -- the topic is public, and the whole point is that a draft stays
  -- behind `landing_page()`.
  if to_regprocedure('realtime.send(jsonb, text, text, boolean)') is not null
  then
    perform realtime.send(
      jsonb_build_object('table', tg_table_name),
      'changed',
      'landing',
      false);
  end if;
  return null;
end;
$$;

revoke all on function app.landing_touched() from public;

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'landing_page', 'landing_sections', 'landing_app_links',
    'landing_stats', 'landing_testimonials', 'landing_logos',
    -- The price list is part of the page when `show_pricing` is on, so
    -- a module renamed or repriced is a change to the front page.
    'platform_modules']
  loop
    execute format(
      'drop trigger if exists %I on public.%I',
      'trg_' || v_table || '_landing_touched', v_table);
    execute format(
      'create trigger %I after insert or update or delete on public.%I '
      'for each statement execute function app.landing_touched()',
      'trg_' || v_table || '_landing_touched', v_table);
  end loop;
end $$;
