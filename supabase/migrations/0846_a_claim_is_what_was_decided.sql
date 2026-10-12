-- =====================================================================
-- iAkauntan :: 0846 a claim is what was decided
--
-- An expense claim is decided step by step (`decide_claim_step`), and
-- what is posted and paid is the approver's `approved_amount` -- spread
-- across expense accounts by `app.claim_expense_allocation` in the
-- proportions of the claim's LINES, each line's category naming its
-- account. `0795` kept the claim's own status and decisions to its
-- functions. Its lines kept a policy for all commands that lets the
-- claimant write them whatever the claim's state.
--
-- Measured on 12 October 2026, locally, as the claimant with the role
-- `authenticated`, on a claim approved through its chain at RM500: its
-- line rewritten to RM5,000 "Taxi, and dinner" and moved from Travel to
-- Client entertainment -- half of it not deductible -- was accepted; a
-- line added, and the only line deleted --
-- leaving an approved claim with nothing to post -- were accepted. The
-- app writes a claim's lines once, as it makes the claim.
--
-- Answered "freeze once anybody decides": a trigger refuses a client's
-- own insert, update or delete of a claim's lines -- role
-- `authenticated` or `anon`, at the top trigger depth -- once the claim
-- has left draft or submitted, or once any approver has approved or
-- rejected a step. Before that the claimant edits as the app does. HR
-- (`app.can_manage_hr`) and the claim functions pass. NOT security
-- definer: a definer would always answer "the owner".
--
-- Production held no expense claim on 12 October.
-- =====================================================================

create or replace function app.a_claim_is_what_was_decided()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_claim uuid;
  c       record;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return coalesce(new, old);
  end if;

  -- The claim a line leaves and the claim it joins are both asked.
  foreach v_claim in array array_remove(array[
      case when tg_op <> 'INSERT' then old.claim_id end,
      case when tg_op <> 'DELETE' then new.claim_id end], null)
  loop
    select x.org_id, x.claim_no, x.status into c
      from public.expense_claims x where x.id = v_claim;
    continue when c.org_id is null or app.can_manage_hr(c.org_id);

    if c.status not in ('draft', 'submitted')
       or exists (select 1 from public.claim_approvals a
                   where a.claim_id = v_claim
                     and a.status in ('approved', 'rejected')) then
      raise exception
        'Claim % has been decided on, and its lines are what was decided. '
        'A change after that is a fresh claim.',
        c.claim_no
        using errcode = '42501';
    end if;
  end loop;

  return coalesce(new, old);
end $$;

revoke all on function app.a_claim_is_what_was_decided()
  from public, anon, authenticated;

comment on function app.a_claim_is_what_was_decided() is
  'On expense_claim_lines: refuses a client''s own insert, update or '
  'delete once the claim has left draft or submitted, or once a step has '
  'been approved or rejected. HR and the claim functions pass. 0846.';

create trigger a_claim_is_what_was_decided
  before insert or update or delete on public.expense_claim_lines
  for each row execute function app.a_claim_is_what_was_decided();
