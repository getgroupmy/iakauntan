-- ---------------------------------------------------------------------
-- 0443  How many days' leave a person gets
-- ---------------------------------------------------------------------
-- 0442 audited `statutory_schedules` and `statutory_rates` after asking
-- what, outside the 41 audited tables, ought to be inside. It answered
-- that question for the platform-wide half and left the tenant-scoped
-- half unasked. This is that half, and it found two things -- one of
-- them a consequence of 0442 itself.
--
-- ### The leave policy nobody had to sign for
--
-- `public.leave_types` and `public.leave_entitlement_bands` decide how
-- many days of annual and sick leave every employee of a company is
-- entitled to. `app.leave_entitlement` reads the bands for each
-- employee's years of service; `public.apply_statutory_leave_bands`
-- writes the Employment Act 1955 s.60E(1) minimums into them. Both are
-- edited from the app -- `hr_setup_screen.dart` for the type,
-- `leave_bands_dialog.dart` for its bands -- by anybody who passes
-- `app.can_manage_hr`.
--
-- Measured on a local build of this schema, before this migration:
--
--   * inserting a band: 0 rows in `audit_logs`;
--   * updating that band from 8 days to 99: still 0.
--
-- So the entitlement an employee is owed could be edited down with
-- nothing recorded, while `payroll_settings`, `salary_components`,
-- `employee_salary_components` and `employee_tax_reliefs` -- every
-- neighbouring HR table that decides money -- are all audited. Leave is
-- money: s.60E(3) requires payment for untaken annual leave on
-- termination, and the band is what says how much.
--
-- ### A tenant's row in the platform's trail
--
-- `leave_entitlement_bands` has no `org_id`; it names its tenant
-- through `leave_type_id`. `app.write_audit_log` takes `org_id` from
-- the row it is auditing, so a plain trigger would write a null there
-- -- and since 0442, a null `org_id` no longer means "readable by
-- nobody". It means the platform's own trail, which every platform
-- administrator may read.
--
-- `access_type_modules` is the same shape and has been since 0236, so
-- it was measured rather than reasoned about:
--
--   * delete an `access_type`, and its modules cascade;
--   * `null-org rows after access_type cascade: 1 (access_type_modules)`
--
-- The lookup `write_audit_log` does for that table resolves through
-- `access_types`, and on a cascade the parent row is already gone, so
-- it resolves to null. Before 0442 that row was readable by nobody and
-- the mistake was invisible. After 0442 it is one company's deleted
-- permission set sitting in the trail every platform administrator
-- reads. 0442 did not create the null; it gave it a reader.
--
-- So the rule is now explicit, and it is the one thing in here worth
-- remembering: **a null `org_id` in `audit_logs` means the platform,
-- and only the two statutory tables may write one.** Anything else that
-- cannot name its tenant writes nothing.
--
-- Nothing is lost by dropping those rows. They only arise on a cascade,
-- and the parent's own deletion is audited against the right company --
-- `access_types` since 0236, `leave_types` as of this migration -- with
-- its old payload. A child row saying "and its five modules went too"
-- adds nothing the parent row did not already say, and it cannot be
-- filed under the company it belonged to.
--
-- ### Mutants
--
--   * the `leave_entitlement_bands` branch of the tenant lookup deleted
--     outright -- killed by this migration's own apply-time guard,
--     which string-matches the very text the mutant removed. That is
--     the guard working and is **not** a test kill, so:
--   * the branch kept and its lookup pointed at the wrong column, so it
--     resolves to nothing -- killed by "so is the band under it", which
--     read 0. The guard drops a row it cannot file, so a broken lookup
--     shows up as an absence rather than a misfiling;
--   * the guard's exemption widened to cover `access_type_modules` and
--     `leave_entitlement_bands`, restoring exactly the leak this
--     migration closes -- killed by "and a cascade leaves nothing in
--     the platform's trail", which read 1;
--   * the `leave_types` trigger narrowed to insert and update -- killed
--     by "while the deletion itself is recorded", which read 0. That
--     assertion is what lets the guard above throw the orphaned band
--     away without losing the event;
--   * the band's lookup joined without its key, so a band is filed
--     under whichever company's leave type came first -- killed by "so
--     is the band under it", again reading 0, because that count is
--     scoped to the company under test and a misfiled row is a missing
--     one. Which means "the band's trail is filed under its own
--     company" made no kill of its own; it states the claim, and the
--     scoped count is what enforces it.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The trigger function, restated from the installed definition
-- ---------------------------------------------------------------------
create or replace function app.write_audit_log()
returns trigger language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
declare
  v_old  jsonb := case when TG_OP = 'INSERT' then null else to_jsonb(OLD) end;
  v_new  jsonb := case when TG_OP = 'DELETE' then null else to_jsonb(NEW) end;
  v_row  jsonb := coalesce(v_new, v_old);
  v_org  uuid;
  v_id   uuid;
  v_from jsonb;
  v_to   jsonb;
begin
  if TG_TABLE_NAME = 'organizations' then
    v_org := (v_row ->> 'id')::uuid;
  elsif TG_TABLE_NAME = 'access_type_modules' then
    select t.org_id into v_org
      from public.access_types t
     where t.id = (v_row ->> 'access_type_id')::uuid;
  elsif TG_TABLE_NAME = 'leave_entitlement_bands' then
    select t.org_id into v_org
      from public.leave_types t
     where t.id = (v_row ->> 'leave_type_id')::uuid;
  else
    v_org := nullif(v_row ->> 'org_id', '')::uuid;
  end if;

  -- The company is already gone: this row is cascading away behind it.
  -- Only on DELETE, because an insert or an update cannot name an
  -- organization that does not exist -- the source row's own foreign key
  -- has already said so -- and this must not cost a lookup on the path
  -- every invoice takes.
  if TG_OP = 'DELETE'
     and v_org is not null
     and not exists (select 1 from public.organizations o where o.id = v_org)
  then
    return null;
  end if;

  -- Since 0442 a null `org_id` is not "readable by nobody"; it is the
  -- platform's own trail, which every platform administrator reads.
  -- Only the two statutory tables genuinely have no tenant. Any other
  -- table arriving here without one has lost the parent it names its
  -- tenant through -- a cascade -- and the parent's own deletion is
  -- audited against the right company. Writing this row would file a
  -- tenant's data under the platform.
  if v_org is null
     and TG_TABLE_NAME not in ('statutory_schedules', 'statutory_rates')
  then
    return null;
  end if;

  begin
    v_id := nullif(v_row ->> 'id', '')::uuid;
  exception when others then
    v_id := null;   -- a table keyed on something other than a uuid
  end;

  if v_id is null and TG_TABLE_NAME = 'access_type_modules' then
    v_id := (v_row ->> 'access_type_id')::uuid;
  end if;

  if TG_OP = 'UPDATE' then
    v_to := app.audit_diff(v_old, v_new);
    -- A write that changed nothing is not an event.
    if v_to = '{}'::jsonb then return null; end if;
    v_from := app.audit_diff(v_new, v_old);
  else
    v_from := app.audit_redact(v_old);
    v_to := app.audit_redact(v_new);
  end if;

  insert into public.audit_logs
    (org_id, user_id, table_name, record_id, action, old_data, new_data,
     ip_address, user_agent)
  values (v_org, auth.uid(), TG_TABLE_NAME, v_id, lower(TG_OP), v_from, v_to,
          nullif(split_part(coalesce(
            app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet,
          app.request_header('user-agent'));

  return null;
end;
$fn$;

-- ---------------------------------------------------------------------
-- The two tables
-- ---------------------------------------------------------------------
drop trigger if exists audit_changes on public.leave_types;
create trigger audit_changes
  after insert or delete or update on public.leave_types
  for each row execute function app.write_audit_log();

drop trigger if exists audit_changes on public.leave_entitlement_bands;
create trigger audit_changes
  after insert or delete or update on public.leave_entitlement_bands
  for each row execute function app.write_audit_log();

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_n   integer;
  v_src text := pg_get_functiondef(to_regprocedure('app.write_audit_log()'));
begin
  select count(*) into v_n
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where not t.tgisinternal
     and t.tgname = 'audit_changes'
     and n.nspname = 'public'
     and c.relname in ('leave_types', 'leave_entitlement_bands');
  if v_n <> 2 then
    raise exception '0443: % of 2 leave tables audited', v_n;
  end if;

  if position('leave_entitlement_bands' in v_src) = 0 then
    raise exception
      '0443: write_audit_log does not resolve the band''s tenant';
  end if;

  if position('''statutory_schedules'', ''statutory_rates''' in v_src) = 0 then
    raise exception
      '0443: write_audit_log has no guard on the platform trail';
  end if;
end
$do$;

comment on trigger audit_changes on public.leave_entitlement_bands is
  'How many days an employee is entitled to. Files its rows under the '
  'company that owns the leave type, because the band itself has no '
  'org_id -- see 0443.';
