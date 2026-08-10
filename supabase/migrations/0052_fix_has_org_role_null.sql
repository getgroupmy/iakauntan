-- =====================================================================
-- iAkauntan :: 0052 close a guard that failed open
--
-- app.org_role returns null for someone who is not a member of the
-- organisation at all, and in SQL `null = any (...)` is null, not false.
-- app.has_org_role passed that null straight out, so every `can_*`
-- helper built on it returned null for a non-member.
--
-- Row level security was never at risk: a policy whose USING clause is
-- null filters the row out, which is the safe direction. The damage was
-- in the twenty-six SECURITY DEFINER functions guarded as
--
--   if not app.can_x(v_org) then raise exception ... end if;
--
-- because `not null` is null, the branch never fired, and a signed-in
-- user belonging to no organisation walked past all of them. Confirmed
-- against the live database: such a user could read a payroll payment
-- instruction — names, banks, account numbers and net pay — for an
-- organisation they had nothing to do with.
--
-- Coalescing here fixes all twenty-six call sites at once, which is why
-- it is done here rather than at each guard.
-- =====================================================================

create or replace function app.has_org_role(p_org_id uuid, p_roles app.member_role[])
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(app.org_role(p_org_id) = any (p_roles), false);
$$;

revoke all on function app.has_org_role(uuid, app.member_role[]) from public, anon;
grant execute on function app.has_org_role(uuid, app.member_role[])
  to authenticated, service_role;
