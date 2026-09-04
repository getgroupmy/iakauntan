-- =====================================================================
-- 0531 :: a read that writes is not a read
--
-- Reported from the platform console. "What people told us" showed
--
--     PostgrestException(message: cannot execute INSERT in a read-only
--     transaction, code: 25006)
--
-- `public.platform_feedback` is declared STABLE. STABLE is a PROMISE TO
-- POSTGRES that the function does not modify the database, and this one
-- does: `perform app.note_read(null, 'feedback_reports')` writes a
-- security-audit row, which is `0136`'s rule that reading the feedback
-- of every company on the platform is a sensitive read worth recording.
--
-- PostgREST believes the promise. It runs a STABLE function in a
-- READ ONLY transaction, so the audit insert is refused and the whole
-- call fails. The page has never worked.
--
-- WHY NO TEST CAUGHT IT. `supabase/tests/feedback.sql` does cover this
-- function — by calling it from psql, where there is no read-only
-- transaction and the insert succeeds. The declaration is only load
-- bearing at the PostgREST door. That is the same shape as the note in
-- `CLAUDE.md` about the edge functions: green in one place is not green
-- in the other, and the test has to stand where the caller stands.
--
-- The fix is the declaration, not the audit. The function writes, so it
-- is VOLATILE. `supabase/tests/feedback.sql` now calls it inside
-- `set transaction read only`, which is exactly what PostgREST does,
-- and `scripts/check_stable_writers.py` refuses any future function
-- that makes the same promise while writing.
-- =====================================================================

-- Same body; the volatility is the change. Spelled out rather than
-- `alter function` so the definition in the tree is the whole truth.
create or replace function public.platform_feedback(
  p_status app.feedback_status default null,
  p_limit  integer default 200)
returns table (
  id uuid, kind app.feedback_kind, title text, body text, screen text,
  app_version text, status app.feedback_status, severity smallint,
  platform_note text, reported_by text, company text,
  created_at timestamptz, resolved_at timestamptz)
language plpgsql
volatile security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;

  perform app.note_read(null, 'feedback_reports');

  return query
  select f.id, f.kind, f.title, f.body, f.screen, f.app_version, f.status,
         f.severity, f.platform_note,
         coalesce(p.full_name, p.email, 'somebody who has since left'),
         o.name, f.created_at, f.resolved_at
    from public.feedback_reports f
    left join public.profiles p on p.id = f.reported_by
    left join public.organizations o on o.id = f.org_id
   where (p_status is null or f.status = p_status)
   order by
     -- Faults first, worst first, then whatever came in most recently.
     case when f.kind = 'bug' then 0 else 1 end,
     coalesce(f.severity, 9),
     f.created_at desc
   limit greatest(coalesce(p_limit, 200), 1);
end;
$$;

revoke all on function public.platform_feedback(app.feedback_status, integer)
  from public, anon;
grant execute on function public.platform_feedback(app.feedback_status, integer)
  to authenticated;
