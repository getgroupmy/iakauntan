-- Pin the search_path on the last ten of our own functions without one.
--
-- Every SECURITY DEFINER function this project owns — 290 of them across
-- `public` and `app` — already pins its search_path, and that is the
-- case that matters: a definer function running with a search_path the
-- caller controls can be made to call the caller's own `pg_temp.round()`
-- instead of the real one, with the definer's rights. Every guard in
-- this schema is such a function.
--
-- These ten are SECURITY INVOKER, so they cannot escalate anything: they
-- run as whoever called them and can do nothing that caller could not do
-- unaided. They are pinned anyway, for one reason: ten standing warnings
-- on the security advisor are ten places for the eleventh to hide. A
-- report nobody reads to the bottom of has stopped being a report.
--
-- What is left unpinned after this is `citext` and `pg_trgm` — sixty-six
-- C functions belonging to two extensions installed in `public`, owned
-- by `supabase_admin` and not ours to alter. `supabase/tests/search_path.sql`
-- excludes extension members by `pg_depend`, not by name, so the day one
-- of ours slips through it will be the only thing the test reports.
--
-- `pg_catalog, pg_temp` is safe for all ten. Their bodies use built-in
-- functions and operators only; the one call between them,
-- `app.months_held` inside `app.accumulated_depreciation_at`, is already
-- schema-qualified, and the `fixed_assets` parameter type was resolved
-- when the function was defined rather than when it is called.

alter function app.import_date(text)
  set search_path = pg_catalog, pg_temp;
alter function app.import_number(text, numeric)
  set search_path = pg_catalog, pg_temp;
alter function app.import_boolean(text, boolean)
  set search_path = pg_catalog, pg_temp;
alter function app.import_text(jsonb, text)
  set search_path = pg_catalog, pg_temp;

alter function app.default_doc_prefix(text)
  set search_path = pg_catalog, pg_temp;
alter function app.transfer_counter(text, text)
  set search_path = pg_catalog, pg_temp;

alter function app.months_held(date, date)
  set search_path = pg_catalog, pg_temp;
alter function app.accumulated_depreciation_at(public.fixed_assets, date)
  set search_path = pg_catalog, pg_temp;

alter function app.chat_edit_window()
  set search_path = pg_catalog, pg_temp;
alter function app.chat_presence_window()
  set search_path = pg_catalog, pg_temp;
