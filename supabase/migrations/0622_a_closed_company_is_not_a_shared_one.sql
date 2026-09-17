-- =====================================================================
-- iAkauntan :: 0622 a closed company is not a shared one
--
-- `0619` made `app.is_org_member` and `app.org_role` refuse a closed
-- login and a closed company, which took every tenant table dark in one
-- step. It did not touch the third membership guard, and there is one:
-- `app.shares_org_with`, which `0010` wrote for the profiles policy and
-- nothing else calls.
--
--   create policy profiles_select on public.profiles
--     for select to authenticated
--     using (id = auth.uid() or app.shares_org_with(id));
--
-- Two consequences, one of which is already right and one of which is
-- not.
--
-- ## Already right: a closed login disappears from the staff list
--
-- Both sides of that function ask for `status = 'active'`, and 0619
-- suspends the memberships of somebody who closes their account. So
-- their profile row stops being readable by their former colleagues the
-- moment they go -- not scrubbed-and-visible, but absent. That is the
-- better answer and it came for free; it is asserted in
-- `account_closure.sql` now rather than left to be rediscovered.
--
-- ## Not right: a closed company keeps introducing its members
--
-- Closing a company suspends nobody. Its members keep `status =
-- 'active'` rows in a company that no longer exists as far as every
-- other guard is concerned -- which is deliberate, because those rows
-- are the record 0619 exists to keep. But `shares_org_with` reads them,
-- so two people whose only connection was a company that closed last
-- year go on being able to read each other's name, email address and
-- phone number.
--
-- Small, and not nothing: `docs/personal-data.md` says that sharing is
-- "deliberate and scoped to shared organizations", and after the
-- organization is closed it is scoped to a shared memory of one. One
-- clause fixes it.
--
-- ## The grant, again
--
-- `app.shares_org_with` predates `0165`, whose event trigger fires on
-- CREATE OR REPLACE as well as CREATE. Its ACL is `authenticated` and
-- `service_role` -- what `0023`'s sweep left -- and replacing it without
-- restating that would take the profiles policy away from every
-- signed-in user. Restated and asserted below, the same way 0619 did
-- for the other two.
-- =====================================================================

create or replace function app.shares_org_with(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.org_members mine
      join public.org_members theirs on theirs.org_id = mine.org_id
      join public.organizations o on o.id = mine.org_id
     where mine.user_id = auth.uid()
       and mine.status = 'active'
       and theirs.user_id = p_user_id
       and theirs.status = 'active'
       and o.deleted_at is null
  );
$$;

grant execute on function app.shares_org_with(uuid)
  to authenticated, service_role;

comment on function app.shares_org_with(uuid) is
  'Whether the caller and this person are both active members of a '
  'company that is still open. The whole of what makes one person''s '
  'profile readable by another. 0622 added the last clause: a company '
  'that has been closed introduces nobody.';

do $do$
begin
  if not has_function_privilege('authenticated',
       'app.shares_org_with(uuid)', 'execute') then
    raise exception
      'app.shares_org_with lost its EXECUTE to authenticated -- it is '
      'the whole of the profiles read policy.';
  end if;
  if has_function_privilege('anon', 'app.shares_org_with(uuid)', 'execute')
  then
    raise exception
      'app.shares_org_with is reachable by anon, which 0023 did not '
      'leave and statutory.sql''s allowlist fails the build over.';
  end if;
  if pg_get_functiondef(to_regprocedure('app.shares_org_with(uuid)'))
       !~ 'deleted_at is null' then
    raise exception 'app.shares_org_with still reads closed companies.';
  end if;
end
$do$;
