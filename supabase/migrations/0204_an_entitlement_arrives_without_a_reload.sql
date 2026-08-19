-- A module bought is a module you can use, without being told to reload.
--
-- `org_modules` is what the navigation is built from: the client reads
-- it once when the app loads and never again. Nothing invalidates it
-- except the platform console toggling a module *in that same tab*, so
-- an entitlement granted anywhere else — by another admin, from another
-- device, by support, by a demo rebuild — is invisible until the person
-- happens to reload the page. Nothing tells them to.
--
-- That is a poor seam for a product that sells modules as add-ons. The
-- customer pays, the screen does not change, and the only cure is one
-- they have no way to guess.
--
-- 0117 built the mechanism for exactly this and left this table out,
-- reasonably: at the time modules were set up once at onboarding and a
-- reload between buying and using was nobody's problem. It is now.
--
-- The policies say it plainly. `org_modules_write` is
-- `app.is_platform_admin()` — only staff may grant a module, from the
-- console, in a different session on a different machine. So the change
-- that most needs to reach a customer's screen is the one change their
-- own session can never be the author of, and therefore the one no
-- in-app invalidation could ever have caught.
--
-- ---------------------------------------------------------------------
-- What is safe about it
--
-- Realtime applies row-level security when it decides who receives a
-- row, and `org_modules_read` is
-- `app.is_org_member(org_id) or app.is_platform_admin()`, granted to
-- `authenticated` — so a row reaches the members of the organization it
-- belongs to and nobody else. It is what draws their own navigation.
-- The row carries a module code, whether it is on, and when it lapses.
-- No price, no key, nobody else's business. So this publishes something
-- every recipient could already select, which is the test 0117 set.
--
-- Deliberately not extended to `org_members`. Access *types* are the
-- other half of what `moduleEnabled` asks, and they live there — but
-- that row also carries `invite_token`, which is a credential, and
-- publishing a table to make a menu item appear sooner is not a reason
-- to put one on the wire. The team screen already invalidates the
-- access map when it changes an access type, which covers the case
-- somebody is actually watching.
do $$
declare
  v_table text := 'org_modules';
begin
  -- A delete carries only the primary key by default, which is not
  -- enough for Realtime to tell whether the row was yours, so the event
  -- is dropped rather than delivered. A module switched off is exactly
  -- the change that most needs to arrive. Same reasoning as 0117.
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
end $$;
