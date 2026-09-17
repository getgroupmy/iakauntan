-- ---------------------------------------------------------------------
-- 0442  Who changed the rate everybody is paid by
-- ---------------------------------------------------------------------
-- Found by re-measuring `docs/security.md` rather than by reading code.
-- Its opening table says data changes are recorded by `audit_changes`
-- on 41 tables, and that is still exactly true -- 41, on a schema that
-- has grown from 249 tables to 306. Which raised the question the
-- number does not answer: is anything that *should* be audited now
-- outside those 41?
--
-- One thing is, and it is the most consequential row in the product.
--
-- `public.statutory_schedules` and `public.statutory_rates` hold the
-- EPF, SOCSO, EIS and PCB schedules that `calculate_payroll_run` reads
-- for every employee of every tenant. Republishing one moves what every
-- person in the product is paid and what every employer owes the
-- statutory bodies. It is written by exactly one function,
-- `platform_publish_statutory_schedule`, which is guarded by
-- `app.is_platform_admin()` -- and which records, measured:
--
--   * in `statutory_schedules`: `source`, `is_verified`, `notes`,
--     `created_at` -- when, from what, and whether somebody checked it;
--   * in `audit_logs`: nothing;
--   * in `security_events`: nothing;
--   * who did it: nowhere. There is no `published_by` column and no
--     audit trigger on either table.
--
-- So the one change with the widest blast radius in this database is
-- the one nobody has to put their name to. `payroll_settings`,
-- `salary_components`, `employee_salary_components` and
-- `employee_tax_reliefs` are all audited; the schedule they are all
-- measured against is not.
--
-- Not a permissions hole -- `authenticated` holds SELECT and nothing
-- else on both tables, and the write path is one platform-admin
-- function. It is an accountability hole, which is what an audit trail
-- is for and is a different thing from an access control.
--
-- ### The row has to be readable by somebody
--
-- `app.write_audit_log` takes `org_id` from the row it is auditing, and
-- these two tables have no `org_id` -- they are platform-wide, which is
-- the whole point. `audit_logs.org_id` is nullable, so the insert
-- works; but the read policy is `app.can_admin(org_id)`, and
-- `can_admin(null)` is false for everybody. The row would be written
-- and readable by nobody through the API.
--
-- An audit row nobody can read is the same shape as an assertion that
-- passes by not running: it exists, and it discharges nothing. So the
-- policy gains one clause -- a platform administrator may read an audit
-- row that belongs to no organization. Not every row: a tenant's audit
-- trail stays the tenant's, and `app.can_admin(org_id)` is untouched
-- for every row that has an `org_id`.
-- ### Four mutants, and one that survived
--
--   * the platform clause dropped -- killed, "a platform administrator
--     reads the platform's own trail", got 0 for 1;
--   * the trigger left off `statutory_schedules` -- killed by this
--     migration's own apply-time guard, "1 of 2 tables audited", so it
--     exercised no test assertion;
--   * the clause WIDENED to `is_platform_admin()` alone, letting a
--     platform administrator read every company's audit trail --
--     **SURVIVED**. The whole file passed. The migration claimed in so
--     many words that this "does not widen a platform admin's view of
--     any tenant's audit trail by one row", and nothing checked it.
--     An assertion was added -- a platform administrator sees not one
--     row of any company's own trail -- and the mutant now dies on it,
--     reading 214.
--
-- Which is the point of applying mutants to the direction a change is
-- claimed NOT to go, and not only to the direction it is claimed to go.
--
-- ### Three things the fixture taught, all measured
--
-- `pg_temp.sign_in_as` sets the JWT claim and nothing else: the session
-- is still `postgres`, which owns these tables and is exempt from row
-- level security. An RLS assertion has to change role as well, at the
-- top level -- `set local role` inside a `do` block does not survive
-- it. The first draft asserted a tenant sees nothing while running as
-- the owner and read 2 rows; the second moved the role change into a
-- `do` block and read 6. Both failures were luck: had either fixture
-- left the count at zero, the assertion would have passed while
-- testing nothing.
--
-- And `pg_temp.test_user()` returns the SAME fixture user every time,
-- who owns every company the suite builds. Making that user a platform
-- administrator puts the tenant and the platform in one pair of hands,
-- which is precisely what these assertions exist to tell apart. Both
-- blocks now create a platform user of their own.
-- ---------------------------------------------------------------------

create trigger audit_changes
  after insert or delete or update on public.statutory_schedules
  for each row execute function app.write_audit_log();

create trigger audit_changes
  after insert or delete or update on public.statutory_rates
  for each row execute function app.write_audit_log();

-- ---------------------------------------------------------------------
-- A platform row is readable by the platform, and by nobody else
-- ---------------------------------------------------------------------
drop policy if exists audit_logs_select on public.audit_logs;
create policy audit_logs_select on public.audit_logs
  for select
  using (
    -- Unchanged: a company's own administrators read their own trail.
    app.can_admin(org_id)
    -- Added by 0442: a row belonging to no company is a platform-level
    -- event, and the people accountable for it are the ones who can
    -- cause it. `org_id is null` and not `is_platform_admin()` alone,
    -- so this does not widen a platform admin's view of any tenant's
    -- audit trail by one row.
    or (org_id is null and app.is_platform_admin())
  );

comment on policy audit_logs_select on public.audit_logs is
  'A company administrator reads their own company''s trail. A platform '
  'administrator additionally reads rows that belong to no company -- '
  'which since 0442 is how a change to the statutory schedules is '
  'recorded. Neither can read the other''s.';

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_n integer;
begin
  select count(*) into v_n from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and not t.tgisinternal
     and t.tgfoid = 'app.write_audit_log'::regproc
     and c.relname in ('statutory_schedules', 'statutory_rates');
  if v_n <> 2 then
    raise exception
      'FAIL 0442: the statutory schedules are still changed by nobody in '
      'particular -- % of 2 tables audited', v_n;
  end if;

  -- Both halves of the policy. Losing `can_admin` would take every
  -- company''s trail away from the company; losing the other would put
  -- the platform row back out of reach of everyone.
  if not exists (
    select 1 from pg_policy p join pg_class c on c.oid = p.polrelid
     where c.relname = 'audit_logs' and p.polname = 'audit_logs_select'
       and pg_get_expr(p.polqual, p.polrelid) like '%can_admin%'
       and pg_get_expr(p.polqual, p.polrelid) like '%is_platform_admin%')
  then
    raise exception
      'FAIL 0442: the audit read policy no longer says both who may '
      'read a company''s trail and who may read the platform''s';
  end if;

  raise notice
    '0442: a change to what everybody is paid by has a name on it';
end
$do$;
