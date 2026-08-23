-- A change made in the platform console reaches the people using the
-- product, without anybody reloading.
--
-- The console edits things that are not any one company's: what each
-- module is called, whether the menu is grouped by module, the landing
-- page and the logo on it. Every one of those is read once when a
-- session starts and then cached for as long as it lasts. Renaming a
-- module renamed it in the console's own list and nowhere else — not in
-- the admin's own side menu, not in anyone's dashboard tabs, not until
-- each of them signed out and back in. On the way to a customer that is
-- indistinguishable from the rename not having worked.
--
-- Realtime is the half this migration can do. The other half is the
-- client's: `app/lib/src/core/platform_live.dart` subscribes to these
-- tables and invalidates what reads them, and the console invalidates
-- the same list against its own cache so the person who pressed Save
-- does not wait for a round trip through the socket to see their own
-- work.
--
-- **Nothing here widens who may read what.** Realtime evaluates the
-- table's RLS policies per subscriber before it delivers a row, so a
-- table on the wire shows exactly what a `select` already showed and
-- nothing more. That matters most for `platform_settings`, where 0298
-- lets an ordinary member read one key and a platform admin read all of
-- them: an admin changing something else sends that member nothing.

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'platform_modules',
    'platform_settings',
    'landing_page',
    'landing_sections',
    'landing_app_links'
  ] loop
    -- A delete carries only the primary key by default, which is not
    -- enough for Realtime to run the policy and decide whether the row
    -- was yours, so the event is dropped rather than delivered. A
    -- landing section removed and a module retired are both deletes,
    -- and both are exactly the change that has to arrive. Same
    -- reasoning as 0117 and 0204.
    execute format('alter table public.%I replica identity full', v_table);

    -- `alter publication ... add table` errors if the table is already
    -- there, and this has to be safe against a database where somebody
    -- added it by hand in the dashboard.
    if not exists (
      select 1
        from pg_publication_rel pr
        join pg_publication p on p.oid = pr.prpubid
        join pg_class c on c.oid = pr.prrelid
        join pg_namespace n on n.oid = c.relnamespace
       where p.pubname = 'supabase_realtime'
         and n.nspname = 'public'
         and c.relname = v_table
    ) then
      execute format(
        'alter publication supabase_realtime add table public.%I', v_table);
    end if;
  end loop;
end $$;

-- `payment_gateways` is deliberately not here, and the reason is worth
-- writing down so nobody adds it as an oversight.
--
-- Its read policy is `using (is_active)`, so switching a gateway off
-- produces an update whose new row fails the policy for every ordinary
-- subscriber — the one change most worth delivering is the one that
-- would not be. And the console does not read the table directly: it
-- goes through `platform_payment_gateways`, a SECURITY DEFINER function,
-- because a platform admin has to see the inactive ones too. Publishing
-- the table would put rows on the wire that neither audience is reading
-- and still miss the event that matters. The console invalidates its own
-- list on save, which is the case that actually exists.

comment on table public.platform_modules is
  'The module catalogue. Published to supabase_realtime by 0302 so a '
  'rename or a re-ordering reaches every open session; RLS still '
  'decides who receives a row.';
