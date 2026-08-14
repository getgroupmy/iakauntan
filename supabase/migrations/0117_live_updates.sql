-- Other people's work, arriving
--
-- Two people keeping one ledger currently cannot see each other. A
-- colleague raises an invoice and it is not on your screen until you
-- leave it and come back; a partner changes the company's tax number and
-- your copy of it is yesterday's until you reload. Nothing is *wrong* in
-- the database — the screen simply has no way to learn that it is out of
-- date.
--
-- Realtime is that way. This publishes the tables whose changes another
-- person can make while you are looking at them; the app subscribes per
-- organization and re-reads what changed.
--
-- ---------------------------------------------------------------------
-- What is safe about this
--
-- Realtime applies row-level security when it decides who gets a row: a
-- subscriber is only sent changes to rows they could have selected. Each
-- of these tables already has org-membership policies, so no new
-- exposure is created here — a member of one organization cannot receive
-- another's rows by subscribing to the table.
--
-- The app also filters by org_id on the wire. That is bandwidth, not
-- security: the boundary is RLS, above, and it holds whatever the client
-- asks for.
--
-- ---------------------------------------------------------------------
-- What is deliberately not published
--
-- Anything holding a secret or another person's private business:
-- `einvoice_credentials` and `org_ocr_credentials` (keys), `payslips`
-- and the payroll tables (one employee's pay is not the office's), and
-- the platform tables. Live updates are a convenience; none of these
-- change often enough for it to be worth widening what leaves the
-- database.

-- Full old rows in the WAL, which a delete needs.
--
-- With the default replica identity a DELETE carries only the primary
-- key. That is not enough to tell whether the row belonged to your
-- organization, so Realtime cannot apply RLS to it and the event is
-- dropped — a document deleted by a colleague would sit on your screen
-- until you reloaded, which is the whole complaint this is fixing.
--
-- The cost is a larger WAL record per update on these tables. Worth it:
-- they are all low-volume by the standards of the thing writing them.
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'organizations',
    'sales_documents',
    'purchase_documents',
    'receipts',
    'purchase_payments',
    'contacts',
    'items',
    'expenses',
    'gl_entries',
    'org_credits'
  ]
  loop
    execute format('alter table public.%I replica identity full', v_table);

    -- `alter publication ... add table` errors if the table is already
    -- there, and this has to be safe to run against a database where
    -- somebody added one by hand in the dashboard.
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
