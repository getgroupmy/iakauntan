-- ---------------------------------------------------------------------
-- 0341 - the pages change while you are looking at them
--
-- `0302` put the platform's tables into the `supabase_realtime`
-- publication so that an edit in the console reaches every open page
-- without anybody reloading. `landing_page` and `landing_sections` are
-- in it; `site_pages` — the five screens `0334` added — is not.
--
-- So an operator rewrites the sign-in screen's wording, watches the
-- sign-in page in the next tab, and nothing happens until they reload.
-- Which reads exactly like a console that did not save.
--
-- Publishing it is the whole change. The subscriber side already
-- exists: `platform_live.dart` maps a table name to the providers that
-- go stale, and Realtime evaluates this table's RLS policy per
-- subscriber before delivering anything — `site_pages_admin` admits
-- only platform administrators, so a member subscribed to it receives
-- nothing at all rather than somebody's draft privacy policy.
--
-- ## Replica identity
--
-- Set to full, like the other platform tables: the console sends
-- patches, and a subscriber that receives only the primary key cannot
-- tell a published page from an unpublished one without going back to
-- the database — which is the round trip the subscription was supposed
-- to save.
-- ---------------------------------------------------------------------

alter table public.site_pages replica identity full;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'site_pages')
  then
    alter publication supabase_realtime add table public.site_pages;
  end if;
end $$;
