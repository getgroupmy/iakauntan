-- =====================================================================
-- 0755 :: a named approver who has left decides nothing
--
-- Answered on 7 October: "fix it".
--
-- An approval rule can name a role or a person, and the steps it raises
-- copy whichever it named. `decide_approval` (0167) checked a named
-- step with `approver_user_id <> auth.uid()` and nothing else -- never
-- that the person was still a member of the company. So somebody
-- removed from the company could still approve or reject the invoices,
-- bills and requisitions whose steps named them, given the request id.
-- Reproduced locally: an accountant removed from the company approved
-- an invoice's step and the request was approved.
--
-- A step that asks for a ROLE was never affected: `app.has_org_role`
-- reads the membership. Production had no rules or steps naming a
-- person when this was written, so nothing was decided this way.
--
-- The named step now also asks `app.is_org_member`, the same question
-- every other guard asks, and refuses with its own words. Nothing else
-- changes; grants and comments survive a CREATE OR REPLACE.
-- =====================================================================

create or replace function public.decide_approval(
  p_request_id uuid,
  p_approve boolean,
  p_note text default null)
returns app.approval_status
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  q public.approval_requests;
  s public.approval_steps;
  v_left integer;
begin
  select * into q from public.approval_requests where id = p_request_id;
  if not found then
    raise exception 'No such approval request' using errcode = 'P0002';
  end if;
  if q.status <> 'pending' then
    raise exception 'That request was already %', q.status
      using errcode = '22023';
  end if;

  -- The next undecided step, and only that one. Approving out of order
  -- would let the last signatory clear a document the first has not
  -- seen, which is the entire point of having steps.
  select * into s from public.approval_steps
   where request_id = p_request_id and status = 'pending'
   order by step_no limit 1;
  if not found then
    raise exception 'Nothing left to decide on this request'
      using errcode = '22023';
  end if;

  -- May this person decide *this* step?
  if s.approver_user_id is not null then
    if s.approver_user_id <> auth.uid() then
      raise exception 'This step is somebody else''s to decide'
        using errcode = '42501';
    end if;
    -- Named, and still here. A rule that names a person keeps naming
    -- them after they leave; the step is the company's, and somebody
    -- who is no longer in it decides nothing for it. 0755.
    if not app.is_org_member(q.org_id) then
      raise exception
        'You are no longer a member of this company, so this step is not '
        'yours to decide. Ask an administrator to change the rule.'
        using errcode = '42501';
    end if;
  elsif not app.has_org_role(q.org_id, array[s.approver_role]) then
    raise exception 'This step needs a %', s.approver_role
      using errcode = '42501';
  end if;

  -- Nobody approves their own. The commonest way an approval chain
  -- becomes decoration is the person who raised the document also
  -- holding the role that clears it.
  if q.requested_by = auth.uid() then
    raise exception
      'You raised this, so you cannot approve it. Somebody else holding '
      'the same role has to.' using errcode = '42501';
  end if;

  -- Cast explicitly. A bare CASE over two string literals is `text`,
  -- and Postgres will not coerce that into the enum on assignment.
  update public.approval_steps
     set status = case when p_approve then 'approved'::app.approval_status
                       else 'rejected'::app.approval_status end,
         decided_by = auth.uid(), decided_at = now(), note = p_note
   where id = s.id;

  if not p_approve then
    update public.approval_requests
       set status = 'rejected', decided_at = now()
     where id = p_request_id;
    return 'rejected';
  end if;

  select count(*) into v_left from public.approval_steps
   where request_id = p_request_id and status = 'pending';

  if v_left = 0 then
    update public.approval_requests
       set status = 'approved', decided_at = now()
     where id = p_request_id;
    return 'approved';
  end if;

  return 'pending';
end $$;
