-- ---------------------------------------------------------------------
-- 0488  A company turns its own module on
-- ---------------------------------------------------------------------
-- Every add-on in `platform_modules` carries a monthly price, and not
-- one of them could be had. `org_modules` was writable only by a
-- platform administrator: 0018's policy comment reads "only platform
-- admins may change it, so a tenant cannot grant itself a paid
-- add-on", and the settings screen says "Contact us to add one of
-- these" with no address behind it. Loyalty, Memberships and
-- Multi-Company all had prices and no way to buy them.
--
-- 0486 made that visible rather than causing it: its refusal tells
-- somebody to turn Multi-Company on under Settings, and Settings had
-- nothing to turn on.
--
-- **The rule is reversed here.** A company switches its own add-ons
-- on. Waiting on somebody to answer an email is not a feature, and an
-- operator approving each one is a queue that exists to slow a
-- customer down. What was protecting revenue was not the lock -- the
-- price is charged either way -- it was the absence of a path, which
-- is a different thing from a decision.
--
-- ### What stays as it was
--
--   * The table is still not writable from a client. `set_own_module`
--     is the path, and it is SECURITY DEFINER, so a tenant still
--     cannot write an arbitrary row -- it can switch a listed, active,
--     non-core module on for a company it administers, and nothing
--     else. `expires_at`, `notes` and who did it stay the server's.
--   * The platform operator keeps `platform_set_module`, which is how
--     a module is switched off for non-payment or granted outside the
--     price list.
--   * Core modules are refused. They are on for everybody and there is
--     nothing to switch.
--
-- ### Who may
--
-- An owner or an admin. Adding a paid module commits the company to a
-- bill, which is not a decision an accounts clerk makes on their own
-- -- the same line `can_admin` already draws for changing the
-- company's own details.
--
-- ### Mutants
--
-- Run against `supabase/tests/module_self_service.sql`, each named
-- with the assertion that kills it:
--   * the admin guard dropped -- "a clerk cannot commit the company to
--     a bill";
--   * a core module allowed -- "a core module is not something to
--     switch on";
--   * an inactive or unknown module allowed -- "a module that is not
--     for sale cannot be switched on";
--   * the org scope dropped -- "somebody outside the company cannot
--     switch anything on";
--   * switching on not clearing `expires_at` -- "a module that had
--     lapsed comes back";
--   * switching off not working -- "and a company can switch it off
--     again";
--   * the entitlement not actually granted -- "the company holds it
--     the moment it is switched on", which is also what makes
--     0486's refusal true: the door it names now opens.
-- ---------------------------------------------------------------------

create or replace function public.set_own_module(
  p_org_id uuid, p_module_code text, p_enabled boolean default true)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_name text;
  v_core boolean;
begin
  -- Committing the company to a monthly charge is an owner's or an
  -- admin's decision, which is the line `can_admin` already draws.
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin may change the modules'
      using errcode = '42501';
  end if;

  select m.name, m.is_core into v_name, v_core
    from public.platform_modules m
   where m.code = p_module_code and m.is_active;
  if v_name is null then
    raise exception 'There is no such module for sale' using errcode = 'P0002';
  end if;
  if v_core then
    raise exception '% is part of the product and is always on', v_name
      using errcode = '22023';
  end if;

  insert into public.org_modules
    (org_id, module_code, is_enabled, enabled_at, enabled_by, expires_at,
     notes)
  values (p_org_id, p_module_code, p_enabled,
          case when p_enabled then now() else null end,
          auth.uid(), null,
          'Switched on by the company. See 0488.')
  on conflict (org_id, module_code) do update
    set is_enabled = excluded.is_enabled,
        enabled_at = excluded.enabled_at,
        enabled_by = excluded.enabled_by,
        -- A module that had lapsed and is switched on again is on:
        -- leaving the old expiry would grant something that reads as
        -- held and behaves as absent.
        expires_at = null,
        notes      = excluded.notes;
end;
$$;

comment on function public.set_own_module(uuid, text, boolean) is
  'An owner or admin switches one of this company''s paid add-ons on '
  'or off. The only path a tenant has into org_modules, and it reaches '
  'exactly one row of it. See 0488.';

revoke all on function public.set_own_module(uuid, text, boolean)
  from public, anon;
grant execute on function public.set_own_module(uuid, text, boolean)
  to authenticated;

-- 0018's comment is now wrong about the product, and a comment that
-- contradicts the code is worse than none: the policy still says only
-- a platform admin may write the table directly, which is true and is
-- the reason `set_own_module` is SECURITY DEFINER.
comment on policy org_modules_write on public.org_modules is
  'Direct writes stay with the platform. A company changes its own '
  'add-ons through public.set_own_module, which reaches one row and '
  'refuses core modules -- see 0488, which reversed 0018''s rule that '
  'a tenant may not grant itself a paid module.';

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
begin
  if not has_function_privilege('authenticated',
       'public.set_own_module(uuid, text, boolean)', 'execute') then
    raise exception '0488: a company still cannot switch a module on';
  end if;
  if has_function_privilege('anon',
       'public.set_own_module(uuid, text, boolean)', 'execute') then
    raise exception '0488: switching a module on is open to anon';
  end if;
  -- The table itself stays shut. Not by the grant -- `authenticated`
  -- holds insert and update on every table in this schema, as Supabase
  -- sets it up -- but by the policy, which is what actually decides.
  -- Checking the grant here failed the first time this migration ran
  -- and was right to: it proved the protection is somewhere else, and
  -- an assertion aimed at the wrong mechanism would have passed
  -- happily on the day somebody dropped the policy.
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'org_modules'
       and cmd = 'ALL' and qual like '%is_platform_admin%'
       and with_check like '%is_platform_admin%')
  then
    raise exception '0488: org_modules is no longer shut to tenants';
  end if;
  if position('can_admin' in pg_get_functiondef(
       'public.set_own_module(uuid, text, boolean)'::regprocedure)) = 0 then
    raise exception '0488: anybody in the company may change the bill';
  end if;
end $do$;
