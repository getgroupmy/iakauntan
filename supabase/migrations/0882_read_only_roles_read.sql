-- =====================================================================
-- iAkauntan :: 0882 read-only roles read
--
-- `app.module_access` answers a member with no access type `write` on
-- every module the company holds -- `0871` took the Employee out of
-- that, and nobody else. `app.can_write_module` is that answer and
-- nothing more. The tables never relied on it alone: each write policy
-- asks a role as well, and the module gate only narrows it. But 114
-- definer functions ask `can_write_module` and nothing else, and a
-- definer's statements pass every policy.
--
-- Measured on 14 October 2026, locally, with the role `authenticated`:
-- a `viewer` and an `auditor`, neither of whom passes `can_write`, each
-- raised a support ticket through `create_ticket`. The same door opens
-- the till, promotions, stock transfers, and deposits and post-dated
-- cheques that post journals. The README gives the Auditor "writes
-- nothing" and View Only "read-only". The HR Manager, not a `can_write`
-- role either, had `write` everywhere too.
--
-- Production held one `auditor` with no access type on 14 October, and
-- no `viewer` and no `hr_manager`.
--
-- Answered "read-only roles read; HR writes HR": with no access type, a
-- `viewer` and an `auditor` are answered `read` on every module, and an
-- `hr_manager` `write` on `hr` and `payroll` and `read` on the rest.
-- Owner and admin are answered before this, as before; the accountant,
-- clerk, salesperson and purchaser keep `write`; the Employee keeps
-- `0871`'s answer. An access type decides instead, as it always has.
-- Reading is unchanged for every one of them, and so is every menu
-- `my_module_access` draws, except that a read-only role's menus say so.
--
-- The body is `pg_get_functiondef` of what was applied, with the one
-- branch added.
-- =====================================================================

CREATE OR REPLACE FUNCTION app.module_access(p_org_id uuid, p_module text)
 RETURNS app.module_access
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
    -- 0882. Read-only roles read. A View Only member and an auditor
    -- write nothing, so no module answers them `write`; the HR Manager
    -- writes HR's two and reads the rest. Every other role, as before.
    if v_role in ('viewer', 'auditor') then
      return 'read';
    end if;
    if v_role = 'hr_manager' then
      return case when p_module in ('hr', 'payroll') then 'write'
                  else 'read' end;
    end if;
    return 'write';
  end if;

  select t.access into v_access from public.access_type_modules t
   where t.access_type_id = v_type and t.module_code = p_module;
  return coalesce(v_access, 'none');
end;
$function$;
