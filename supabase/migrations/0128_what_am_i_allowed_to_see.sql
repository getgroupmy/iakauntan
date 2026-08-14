-- =====================================================================
-- iAkauntan :: what am I allowed to see
--
-- 0127 enforces module access in the database, which is where it has to
-- be. It does not tell the app anything, and a screen that cannot ask
-- has only one way to find out: navigate somewhere, read nothing, and
-- show an empty list. "Sales is empty" and "you may not see sales" are
-- different sentences and the second one is the true one.
--
-- One round trip for the whole picture, rather than a call per module,
-- because the shell decides its entire navigation in one build.
--
-- The answer is the same `app.module_access` the policies use, so a
-- screen cannot disagree with the database about what somebody may do.
-- Hiding is a courtesy here, not a control: the row policies are the
-- control, and they do not care what the client believes.
-- =====================================================================

create or replace function public.my_module_access(p_org_id uuid)
returns table (module_code text, access text)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select m.code, app.module_access(p_org_id, m.code)::text
    from public.platform_modules m
   where app.is_org_member(p_org_id)
   order by m.code;
$$;

revoke all on function public.my_module_access(uuid) from public, anon;
grant execute on function public.my_module_access(uuid) to authenticated;
