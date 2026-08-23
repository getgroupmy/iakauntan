-- ---------------------------------------------------------------------
-- The menu setting nobody could read
--
-- 0293 let a platform operator group every company's side menu by
-- module, and stored the choice in `platform_settings` under
-- `nav_grouping`. What it did not do is let anybody read it:
-- `platform_settings_read` is `using (app.is_platform_admin())`, so an
-- ordinary member selecting that row gets nothing, the app's
-- `navGrouping()` sees an empty result, and falls back to false.
--
-- The switch therefore worked for exactly one person on the platform —
-- the administrator who set it — and did nothing at all for the users
-- it was for. No error anywhere; the menu simply stayed flat.
--
-- ## Why one key and not the table
--
-- The rest of that table is the platform's own business:
-- `platform_issuer` is the billing entity's registration and address,
-- `einvoice_defaults` and `trial_days` are commercial settings,
-- `maintenance_mode` and `signup_enabled` say what the platform is
-- about to do. None of that is a tenant's business, so the policy names
-- the one key that is rather than opening the table.
--
-- `nav_grouping` is a display preference — whether a menu has headings
-- in it — and the module names it groups by are already readable by
-- every signed-in user through `platform_modules`, which has been
-- `for select to authenticated using (true)` since 0018.
-- ---------------------------------------------------------------------

drop policy if exists platform_settings_read on public.platform_settings;

create policy platform_settings_read on public.platform_settings
  for select to authenticated
  using (app.is_platform_admin() or key = 'nav_grouping');

comment on table public.platform_settings is
  'Platform-wide settings. Readable only by platform administrators, except `nav_grouping`, which every signed-in user needs because it decides how their own menu is drawn.';
