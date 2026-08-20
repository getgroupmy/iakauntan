-- ---------------------------------------------------------------------
-- 0232  A module you did not buy
-- ---------------------------------------------------------------------
--
-- `app.module_access` decides what every RLS policy and every module
-- guard in this system is allowed to do. It has never looked at
-- `org_modules`:
--
--     if p_org_id is null or auth.uid() is null then return 'none'; end if;
--     if not app.is_org_member(p_org_id) then return 'none'; end if;
--     if app.can_admin(p_org_id) then return 'write'; end if;
--     ... then the person's access type
--
-- Which means it answers "is this person allowed into this module", and
-- nobody has ever answered "has this company bought it". The
-- entitlement check lives in the Flutter client, in
-- `enabledModulesProvider`, and the client's own comment says both
-- questions have to be yes -- but only one of them was ever asked
-- anywhere the answer is enforced.
--
-- So switching a module off hid its screens and left its API wide open.
-- Any member of the company could still call `open_pos_sale`,
-- `redeem_loyalty_points`, `post_payroll_run` or anything else, from a
-- terminal, for a module the company never paid for. `CLAUDE.md` says
-- it plainly: a rule enforced only in Dart is not enforced.
--
-- 0231 was written believing otherwise. It moved thirteen guards from
-- `pos` onto `loyalty` and `memberships`, which was right and did
-- nothing on its own, because the thing it moved them onto was not
-- being checked either. Its test is what found this: an assertion that
-- a disabled module hides a loyalty card failed, and the card was
-- visible because no server-side code has ever cared.
--
-- ## Where the check goes, and why not after `can_admin`
--
-- Before the person's permissions, not after. Entitlement is a fact
-- about the company and permission is a fact about the person, so an
-- owner must not be able to reach a module the company does not hold.
-- Putting it after `can_admin` would leave every owner and admin -- the
-- accounts most worth protecting -- with access to everything on the
-- price list.
--
-- ## Core modules have no rows and never will
--
-- `sales`, `accounting` and `contacts` are `is_core`, and no
-- organization has an `org_modules` row for any of them. They are what
-- the product is, not what it sells, so they pass on the flag rather
-- than on a row that would have to be written for every tenant that has
-- ever existed.
--
-- ## An entitlement can expire
--
-- `org_modules.expires_at` has been on the table since module
-- entitlements were built and has never been read by anything. A trial
-- that ended is not a module you hold.

create or replace function app.module_access(p_org_id uuid, p_module text)
returns app.module_access
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_type   uuid;
  v_access app.module_access;
begin
  if p_org_id is null or auth.uid() is null then return 'none'; end if;
  if not app.is_org_member(p_org_id) then return 'none'; end if;

  -- The question 0232 adds, asked first. Whether the company holds the
  -- module is a fact about the company; whether this person may use it
  -- is a fact about the person. Asking them the other way round would
  -- let every owner and admin into everything on the price list.
  if not exists (
        select 1 from public.platform_modules pm
         where pm.code = p_module and pm.is_core and pm.is_active)
     and not exists (
        select 1 from public.org_modules om
         where om.org_id = p_org_id
           and om.module_code = p_module
           and om.is_enabled
           and (om.expires_at is null or om.expires_at > now()))
  then
    return 'none';
  end if;

  if app.can_admin(p_org_id) then return 'write'; end if;
  select m.access_type_id into v_type from public.org_members m
   where m.org_id = p_org_id and m.user_id = auth.uid();
  if v_type is null then return 'write'; end if;
  select t.access into v_access from public.access_type_modules t
   where t.access_type_id = v_type and t.module_code = p_module;
  return coalesce(v_access, 'none');
end;
$$;

-- The lookup this now does on every policy evaluation.
create index if not exists org_modules_entitlement_idx
  on public.org_modules (org_id, module_code) where is_enabled;

comment on function app.module_access(uuid, text) is
  'What this person may do in this module: none, read or write. Two questions, both of which have to be yes — the company has to hold the module and the person has to be allowed into it.';

-- ---------------------------------------------------------------------
-- Nobody loses anything they were using
-- ---------------------------------------------------------------------
--
-- Enforcing a check that has never run can only take access away, so
-- this fills the gap before the check starts biting: any module a
-- company has data for, and no enabled row, is switched on. It is the
-- same principle as 0231's backfill — a rule that starts being enforced
-- must not withdraw a feature somebody is in the middle of using.
--
-- Listed by hand rather than derived from the schema, because "which
-- table proves a module is in use" is a judgement about the product,
-- not something a catalogue query knows.
do $$
declare
  r     record;
  v_n   integer := 0;
begin
  for r in
    select distinct x.org_id, x.module_code
      from (
        select org_id, 'pos'          as module_code from public.pos_outlets
        union all
        select org_id, 'loyalty'      from public.loyalty_programs
        union all
        select org_id, 'memberships'  from public.pos_memberships
        union all
        select org_id, 'ticketing'    from public.tickets
        union all
        select org_id, 'hr'           from public.employees
        union all
        select org_id, 'fixed_assets' from public.fixed_assets
        union all
        select org_id, 'inventory'    from public.warehouses
        union all
        select org_id, 'purchases'    from public.purchase_documents
      ) x
     where not exists (
       select 1 from public.org_modules om
        where om.org_id = x.org_id and om.module_code = x.module_code
          and om.is_enabled
          and (om.expires_at is null or om.expires_at > now()))
  loop
    insert into public.org_modules (org_id, module_code, is_enabled, enabled_at, notes)
    values (r.org_id, r.module_code, true, now(),
            'Enabled by 0232: in use before entitlement was enforced.')
    on conflict (org_id, module_code) do update
      set is_enabled = true, expires_at = null;
    v_n := v_n + 1;
  end loop;
  raise notice '0232 kept % module(s) switched on that were already in use', v_n;
end;
$$;
