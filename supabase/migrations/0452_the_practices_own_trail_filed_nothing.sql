-- ---------------------------------------------------------------------
-- 0452  The practice's own trail filed nothing
-- ---------------------------------------------------------------------
-- 0450 put an `audit_changes` trigger on `public.firms`, on the
-- reasonable belief that a table worth having is a table worth
-- auditing. Measured on a built database, with a positive control in
-- the same transaction so that a zero means something:
--
--   | table | rows written |
--   |---|---|
--   | organizations (control) | 1 |
--   | company_transfers | 1 |
--   | **firms** | **0** |
--   | **firm_members** | **0** |
--
-- The trigger fires and writes nothing. `app.write_audit_log` derives a
-- tenant from `org_id` and, since 0443, drops any row it cannot place
-- -- because a row arriving without a tenant is almost always a child
-- cascading away behind a deleted company, and filing it under the
-- platform would put one tenant's data in a place other tenants' staff
-- can reach. `firms` has no `org_id` and never will: **a practice is
-- not owned by any of the companies whose books it keeps.** So every
-- firm row met the guard and was discarded.
--
-- A trigger that files nothing is worse than no trigger, because it
-- reads as coverage. `docs/security.md` counted `firms` among the
-- audited tables on the strength of the trigger existing.
--
-- `firm_members` had no trigger at all, which matters more: that table
-- decides who can see other people's books. Adding somebody to a
-- practice with forty clients grants them forty companies' ledgers in
-- one insert, and until now nothing recorded it.
--
-- ### Where a firm's changes belong
--
-- Not under a tenant -- there is no single tenant they concern; a staff
-- appointment touches every client at once and the trail is one row per
-- change. So they go where the platform's own trail already goes,
-- `org_id is null`, which 0442 made a real place and 0444 gave a
-- reader.
--
-- But platform administrators are not the people who most need to read
-- this. The partners of the practice are. `firm_audit_trail` is that
-- reader, guarded by `app.can_manage_firm` so a member of staff cannot
-- read the record of their own appointment being questioned. Widening a
-- policy is not the same as adding a reader; this adds the reader.
--
-- ### The record id
--
-- `firm_members` rows are filed under the **firm**, not the membership
-- row, exactly as 0445 files the three promotion scope tables under the
-- promotion. What a partner asks is "what has happened to my practice",
-- and `new_data` still carries which person it was.
--
-- ### Mutants
--
-- Four, restated into a built database and run against
-- `supabase/tests/firm_portfolio.sql`. All four died, each to a
-- different assertion:
--
--   * the null-tenant guard put back as it was, so firm rows are
--     discarded again -- killed by "starting a practice is recorded";
--   * a staff change filed under the membership row rather than the
--     practice -- killed by "and so is somebody joining it", which is
--     the shape this trail is read in;
--   * `firm_audit_trail` open to anybody at the practice rather than
--     its partners and managers -- killed by "but a member of staff
--     cannot";
--   * the trail not scoped to one firm -- killed by "and a partner can
--     read the lot", which read **16** where 3 was expected: every
--     other practice built earlier in the same test file. That is the
--     leak stated as a number.
--
-- The first assertion is read next to a control on `organizations` in
-- the same block. This migration exists because a count of zero was
-- taken at face value once already.

-- ---------------------------------------------------------------------
-- The trail learns about practices
-- ---------------------------------------------------------------------
create or replace function app.write_audit_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
  elsif TG_TABLE_NAME in ('pos_promotion_items',
                          'pos_promotion_outlets',
                          'pos_promotion_channels') then
    select t.org_id into v_org
      from public.pos_promotions t
     where t.id = (v_row ->> 'promotion_id')::uuid;
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
  -- Four tables genuinely have no tenant: the two statutory ones, which
  -- are below every company, and the two firm ones, which are above
  -- them -- a practice is not owned by any of the companies whose books
  -- it keeps. Any other table arriving here without an org has lost the
  -- parent it names its tenant through -- a cascade -- and the parent's
  -- own deletion is audited against the right company. Writing that row
  -- would file a tenant's data under the platform.
  if v_org is null
     and TG_TABLE_NAME not in ('statutory_schedules', 'statutory_rates',
                               'firms', 'firm_members')
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

  -- The three promotion scope tables are keyed on the pair, so the
  -- promotion is the record this row is about.
  if v_id is null and TG_TABLE_NAME in ('pos_promotion_items',
                                        'pos_promotion_outlets',
                                        'pos_promotion_channels') then
    v_id := (v_row ->> 'promotion_id')::uuid;
  end if;

  -- A change to who works at a practice is a change to that practice,
  -- and the practice is what anybody looking at this trail is looking
  -- for. Which membership row carried it is in `new_data` either way.
  if TG_TABLE_NAME = 'firm_members' then
    v_id := (v_row ->> 'firm_id')::uuid;
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
$function$

;

create trigger audit_changes
  after insert or delete or update on public.firm_members
  for each row execute function app.write_audit_log();

-- ---------------------------------------------------------------------
-- And somebody to read it
-- ---------------------------------------------------------------------
create or replace function public.firm_audit_trail(
  p_firm_id uuid,
  p_limit   integer default 200)
returns table (
  at         timestamptz,
  who        text,
  what       text,
  action     text,
  new_data   jsonb)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_manage_firm(p_firm_id) then
    raise exception
      'Only a partner or manager of the practice may read its trail'
      using errcode = '42501';
  end if;

  return query
  select l.created_at,
         coalesce(p.full_name, p.email, 'somebody who has since left'),
         l.table_name,
         l.action,
         l.new_data
    from public.audit_logs l
    left join public.profiles p on p.id = l.user_id
   where l.org_id is null
     and l.table_name in ('firms', 'firm_members')
     and l.record_id = p_firm_id
   order by l.created_at desc, l.id desc
   limit greatest(coalesce(p_limit, 200), 1);
end;
$$;

revoke all on function public.firm_audit_trail(uuid, integer) from public;
grant execute on function public.firm_audit_trail(uuid, integer)
  to authenticated;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(to_regprocedure('app.write_audit_log()'));
begin
  if position('''firms'', ''firm_members''' in v_src) = 0 then
    raise exception '0452: the trail still discards every firm row';
  end if;

  if position('v_id := (v_row ->> ''firm_id'')::uuid' in v_src) = 0 then
    raise exception '0452: a staff change is not filed under its practice';
  end if;

  if not exists (select 1 from pg_trigger
                  where tgname = 'audit_changes'
                    and tgrelid = 'public.firm_members'::regclass) then
    raise exception '0452: who works at a practice is still unrecorded';
  end if;

  -- The whole point of the guard being narrowed rather than removed.
  if position('''statutory_schedules'', ''statutory_rates''' in v_src) = 0 then
    raise exception '0452: the null-tenant guard lost its statutory tables';
  end if;
end
$do$;

comment on function public.firm_audit_trail(uuid, integer) is
  'What has happened to a practice: who joined it, who left it, and '
  'what changed about the firm itself. Filed with no tenant because a '
  'practice belongs to none of its clients. See 0452.';
