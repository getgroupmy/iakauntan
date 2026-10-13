-- =====================================================================
-- iAkauntan :: 0871 an employee is self-service
--
-- `0024` added the `employee` role as "self-service only — their own
-- record, payslips, leave", the README's table of roles says the same
-- with claims added, and the role picker offers it as "Their own
-- payslips, leave and claims". Nothing made it so. `app.module_access`
-- (`0127`, `0232`) answers `write` for every module the company holds
-- to any member who is not an admin and has no access type -- the
-- employee among them -- and every module gate in the schema asks it.
--
-- Measured on 13 October 2026, locally, as an `employee` member with no
-- access type, with the role `authenticated`: `module_access` answered
-- `write` for sales and for inventory, and she read every customer,
-- every item with its cost price, and the chart of accounts. The app's
-- menus come from the same function (`my_module_access`), so it showed
-- her all of it.
--
-- Production held no `employee` member, and no `viewer`, on 13 October.
--
-- Answered "an employee reaches only HR", in two steps. This is the
-- first: to an `employee` with no access type, `module_access` answers
-- `write` for `hr` -- which is where she files her own leave and claims,
-- the rows themselves still only hers by their own policies -- `read`
-- for `payroll`, where her payslips are, and `none` for every other
-- module. That shuts every module gate to her, and the menus with them.
-- An access type, where the company has given her one, still decides,
-- as it does for everybody else: the company can widen her that way.
-- The company still has to hold the module, asked first as before.
--
-- The second step is the tables no module gate stands in front of.
-- =====================================================================

create or replace function app.module_access(p_org_id uuid, p_module text)
returns app.module_access
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_type   uuid;
  v_role   app.member_role;
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
  select m.access_type_id, m.role into v_type, v_role
    from public.org_members m
   where m.org_id = p_org_id and m.user_id = auth.uid();

  if v_type is null then
    -- 0871. An employee is self-service: her own leave and claims under
    -- HR, her own payslips under payroll, and nothing else. Which rows
    -- are hers is still the tables' own business.
    if v_role = 'employee' then
      return case p_module
               when 'hr'      then 'write'
               when 'payroll' then 'read'
               else 'none'
             end;
    end if;
    return 'write';
  end if;

  select t.access into v_access from public.access_type_modules t
   where t.access_type_id = v_type and t.module_code = p_module;
  return coalesce(v_access, 'none');
end;
$$;

comment on function app.module_access(uuid, text) is
  'What this person may do in this module: none, read or write. Two questions, both of which have to be yes — the company has to hold the module and the person has to be allowed into it. An employee with no access type is self-service: write in hr, read in payroll, none elsewhere (0871).';
