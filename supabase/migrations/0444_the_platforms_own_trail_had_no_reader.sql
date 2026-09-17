-- ---------------------------------------------------------------------
-- 0444  The platform's own trail had no reader
-- ---------------------------------------------------------------------
-- 0442 said this in its own header:
--
--   "An audit row nobody can read is the same shape as an assertion
--    that passes by not running: it exists, and it discharges nothing."
--
-- It then widened `audit_logs_select` so a platform administrator may
-- read the rows whose `org_id` is null, and stopped there. That fixed
-- the policy. It did not give the rows a reader.
--
-- Measured, on the installed schema:
--
--   * the only function that returns audit rows is
--     `public.audit_trail(p_org_id, ...)`, which raises 42501 unless
--     `app.can_admin(p_org_id)` and then filters `l.org_id = p_org_id`.
--     A null `org_id` matches no `p_org_id`, so no argument reaches
--     those rows;
--   * the only caller in the app is `repository.dart:5311`, which
--     passes the current organization;
--   * so the statutory publish that 0442 started recording is visible
--     to nobody through the product. A platform administrator with a
--     connection string could `select` it, and a platform
--     administrator with the app could not.
--
-- The same is true one level up, which is why this migration adds two
-- functions rather than one. `security_log` has the identical shape --
-- `can_admin`, then `e.org_id = p_org_id` -- and `app.note_read`
-- writes a `sensitive_read` event with whatever `org_id` it is handed.
-- Adding a reader that records its own read against a null org, with
-- nothing able to show that either, would repeat exactly the mistake
-- being corrected. So the platform gets the same pair a tenant has:
-- one function for what the data did, one for what the people did.
--
-- ### What these do not do
--
-- Neither widens what a platform administrator may see by one tenant
-- row. Both filter `org_id is null`, which is the platform's own
-- trail and, since 0443, the only thing that can be written there:
-- `app.write_audit_log` refuses to file a tenant's row without a
-- tenant. `audit_redaction.sql` asserts that a platform administrator
-- sees not one row of any company's own, and that assertion now covers
-- the route as well as the policy.
--
-- ### Mutants
--
--   * the platform guard neutered -- `if not app.is_platform_admin()`
--     became `if app.is_platform_admin() is null`, which keeps the
--     name the apply-time check looks for and never refuses anybody --
--     killed by "an org owner cannot read the platform's trail", which
--     came back with 9 rows instead of 42501;
--   * the `org_id is null` filter neutered to `(l.org_id is null or
--     true)`, so a platform administrator is handed every company's
--     trail -- killed by "and not one row of any company's own", which
--     read 97;
--   * the read recorded under the wrong name -- `note_read(null,
--     'audit_trail')` instead of `'platform_audit_trail'` -- killed by
--     "reading the platform trail is itself recorded". That assertion
--     is what stops this being cosmetic: a log that does not record who
--     read it is the one record an insider has no reason to avoid;
--   * the `least(...)` cap on the row limit removed -- **SURVIVED**,
--     and not fixed, for a stated reason rather than an omission.
--     Observing the cap needs 501 platform audit rows in the fixture,
--     which is a lot of scaffolding for a resource guard; and the only
--     cheap alternative -- having the apply-time check string-match
--     `least` -- would assert the source text rather than the
--     behaviour, which this project has been bitten by before. Written
--     down so the next reader knows it was tried, not missed.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- What the data did
-- ---------------------------------------------------------------------
create or replace function public.platform_audit_trail(
  p_table text default null,
  p_limit integer default 100)
returns table (
  id bigint,
  at timestamptz,
  actor text,
  action text,
  table_name text,
  record_id uuid,
  changes jsonb)
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
begin
  if not app.is_platform_admin() then
    raise exception
      'Only a platform administrator may read the platform trail'
      using errcode = '42501';
  end if;

  -- Deliberately not `stable`, for the reason `security_log` gives.
  perform app.note_read(null, 'platform_audit_trail');

  return query
  select l.id,
         l.created_at,
         coalesce(p.full_name, p.email, 'system'),
         l.action,
         l.table_name,
         l.record_id,
         jsonb_build_object('from', l.old_data, 'to', l.new_data)
    from public.audit_logs l
    left join public.profiles p on p.id = l.user_id
   where l.org_id is null
     and (p_table is null or l.table_name = p_table)
   order by l.id desc
   limit least(coalesce(p_limit, 100), 500);
end;
$fn$;

revoke all on function public.platform_audit_trail(text, integer)
  from public;
grant execute on function public.platform_audit_trail(text, integer)
  to authenticated, service_role;

comment on function public.platform_audit_trail(text, integer) is
  'The platform''s own audit trail -- the rows with no organization, '
  'which since 0443 only the statutory rate tables may write. Refuses '
  'anybody who is not a platform administrator, and records the read.';

-- ---------------------------------------------------------------------
-- What the people did
-- ---------------------------------------------------------------------
create or replace function public.platform_security_log(
  p_since timestamptz default null,
  p_limit integer default 200)
returns table (
  id bigint,
  at timestamptz,
  actor text,
  kind text,
  outcome text,
  target text,
  detail text,
  ip_address text,
  user_agent text)
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
begin
  if not app.is_platform_admin() then
    raise exception
      'Only a platform administrator may read the platform security log'
      using errcode = '42501';
  end if;

  perform app.note_read(null, 'platform_security_log');

  return query
  select e.id,
         e.created_at,
         coalesce(p.full_name, p.email, e.email, 'unknown'),
         e.kind::text,
         e.outcome,
         e.target,
         e.detail,
         host(e.ip_address),
         e.user_agent
    from public.security_events e
    left join public.profiles p on p.id = e.user_id
   where e.org_id is null
     and (p_since is null or e.created_at >= p_since)
   order by e.id desc
   limit least(coalesce(p_limit, 200), 1000);
end;
$fn$;

revoke all on function public.platform_security_log(timestamptz, integer)
  from public;
grant execute on function public.platform_security_log(timestamptz, integer)
  to authenticated, service_role;

comment on function public.platform_security_log(timestamptz, integer) is
  'The reads and refusals recorded against no organization, which is '
  'where `platform_audit_trail` files the record of its own use.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_audit text := pg_get_functiondef(
    to_regprocedure('public.platform_audit_trail(text, integer)'));
  v_sec text := pg_get_functiondef(
    to_regprocedure('public.platform_security_log(timestamptz, integer)'));
begin
  if position('is_platform_admin' in v_audit) = 0
     or position('is_platform_admin' in v_sec) = 0 then
    raise exception '0444: a platform reader without a platform guard';
  end if;

  if position('org_id is null' in v_audit) = 0
     or position('org_id is null' in v_sec) = 0 then
    raise exception
      '0444: a platform reader that is not filtered to the platform';
  end if;

  if position('note_read' in v_audit) = 0 then
    raise exception '0444: the trail does not record its own reading';
  end if;
end
$do$;
