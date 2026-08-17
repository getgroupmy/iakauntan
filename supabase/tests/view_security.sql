-- =====================================================================
-- iAkauntan :: a view reads as the caller
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/view_security.sql
--
-- Row level security is evaluated against whoever the query runs as. A
-- view without `security_invoker` runs as its *owner*, so every policy
-- underneath it is skipped and any signed-in user gets every tenant's
-- rows. The policies are still there, still correct, and no longer
-- consulted — which is the worst version of this failure, because the
-- schema reads as though it is safe.
--
-- `v_stock_valuation` was in exactly that state in the repository for
-- roughly a hundred and sixty migrations. The hosted project had the
-- option set by hand; nothing set it in a file; and `0014_reports.sql`
-- carried a comment crediting a `0010a` migration that does not exist.
-- A deployment built from these files would have served every company's
-- stock quantities and costs to every other. `0174` set it, and this is
-- the assertion that keeps it set.
--
-- Deliberately not a list of the views that matter. It is every view in
-- `public`, so a view added next year is covered by a test written
-- today — the only kind of coverage that survives.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_bad text;
  v_checked integer;
begin
  select string_agg(c.relname, ', ' order by c.relname), count(*)
    into v_bad, v_checked
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'v'
     -- `security_invoker` accepts `on`, `true`, `1` — Postgres stores
     -- whichever spelling was written, so match the option rather than
     -- the word. Absent entirely is the case this exists to catch.
     and coalesce(
           (select option_value
              from pg_options_to_table(c.reloptions)
             where option_name = 'security_invoker'), 'off')
         not in ('on', 'true', '1');

  if v_bad is not null then
    raise exception
      'FAIL a view in public runs with its owner''s rights, so row '
      'level security underneath it is skipped: %', v_bad;
  end if;
  raise notice 'ok   no view in public runs as its owner';
end $$;

-- The positive control.
--
-- The block above passes by finding nothing, and finding nothing is also
-- what happens when there are no views at all — if a later migration
-- dropped both of them, or if `relkind` stopped meaning what it means,
-- the assertion would go quiet and pass forever. So: count what was
-- actually examined, and name the two that must be among them.
do $$
declare v_views integer;
begin
  select count(*) into v_views
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'v';

  if v_views = 0 then
    raise exception
      'FAIL there are no views in public at all, so the check above '
      'proved nothing';
  end if;
  raise notice 'ok   % view(s) were actually examined', v_views;

  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'v'
       and c.relname = 'v_stock_valuation') then
    raise exception
      'FAIL v_stock_valuation is gone — the view this test was written '
      'for is not being checked';
  end if;
  raise notice 'ok   including v_stock_valuation, which is why this exists';
end $$;

rollback;
