-- =====================================================================
-- iAkauntan :: the claims waiting on you
--
-- 0119 turned one approval into a chain of up to four, which means a
-- claim is now nearly always waiting on somebody in particular. The
-- Claims screen could show "Awaiting" — every submitted claim in the
-- company — and nothing narrower, so the manager with two receipts to
-- clear had to open claims one at a time to find out which were theirs.
-- An approval queue nobody can see is an approval queue that stalls.
--
-- Answered here rather than in the client, because the question "may I
-- decide this?" already has an answer in `app.may_decide_claim_step`,
-- and a second copy of it in Dart would be a second copy to get wrong.
-- The client asks which claims, and the database says.
--
-- Returns ids rather than rows so the caller can fetch them with the
-- same select and the same embed as every other claim list, instead of
-- this function becoming a second definition of what a claim looks like.
--
-- `returns table` rather than `returns setof uuid` so the shape over the
-- wire is a named column and not a bare scalar array — one less thing
-- about PostgREST for the client to know by heart.
-- =====================================================================

create or replace function public.claims_awaiting_my_approval(p_org_id uuid)
returns table (claim_id uuid)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select c.id
    from public.expense_claims c
   where
     -- SECURITY DEFINER reads past row level security, so membership is
     -- checked here rather than assumed. Everything below narrows from
     -- one company; this is what stops it being every company.
     app.is_org_member(p_org_id)
     and c.org_id = p_org_id
     and c.status = 'submitted'
     -- The step in front, and only that one. A claim three stages down
     -- the chain is not waiting on the manager who cleared stage one,
     -- and showing it to them would make this list a to-do list of other
     -- people's work.
     and app.may_decide_claim_step((
           select a.id
             from public.claim_approvals a
            where a.claim_id = c.id
              and a.status = 'pending'
            order by a.step_no
            limit 1))
$$;

-- A claim whose chain has no pending step at all passes NULL here, and
-- `may_decide_claim_step` answers false for a step that does not exist,
-- so it stays out of the list rather than sitting in it undecidable.
-- That state should no longer be reachable after 0121, which is the
-- reason to be sure of what happens if it ever is again.

revoke all on function public.claims_awaiting_my_approval(uuid)
  from public, anon;
grant execute on function public.claims_awaiting_my_approval(uuid)
  to authenticated;
