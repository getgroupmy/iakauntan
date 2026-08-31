-- =====================================================================
-- iAkauntan :: 0367 a rule that only judges the change
--
-- `0365`'s half-day trigger is `before insert or update` and looks only
-- at whether the row says `is_half_day`. That is right on the way in
-- and a trap on the way through.
--
-- A leave request is updated several times after it is filed: approved,
-- rejected, cancelled, its dates corrected. Every one of those fires
-- this trigger, and every one of them sees a row that already says half
-- a day. So a company that files half days and *then* marks a leave
-- type whole-days-only would find the requests already in flight could
-- no longer be approved, rejected or cancelled — refused by a rule
-- about something nobody was changing, with no way out of it except
-- editing the type back.
--
-- The same trap would follow any tightening of the policy: the rule
-- would apply retrospectively to rows filed under the old one, which is
-- not what anybody means by changing a leave type.
--
-- So it judges the change rather than the row. A new request is checked;
-- an existing one is checked only when the half-day flag or the leave
-- type is what moved. Approving, rejecting and cancelling touch neither
-- and go through.
--
-- Found before it shipped, by asking of each new trigger what the
-- *second* write to a row does — which is the question a `before insert
-- or update` always deserves and rarely gets.
-- =====================================================================

create or replace function app.enforce_half_day_rule()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_type public.leave_types;
begin
  if not coalesce(new.is_half_day, false) then
    return new;
  end if;

  -- An update that moved neither the flag nor the type is not asking
  -- for half a day; it is approving, rejecting or correcting one that
  -- was already asked for.
  if tg_op = 'UPDATE'
     and coalesce(old.is_half_day, false) = coalesce(new.is_half_day, false)
     and old.leave_type_id is not distinct from new.leave_type_id then
    return new;
  end if;

  select * into v_type from public.leave_types where id = new.leave_type_id;
  if v_type.id is not null and not coalesce(v_type.allow_half_day, true) then
    raise exception
      '% is taken in whole days. Ask for the day, or for a different '
      'kind of leave.', v_type.name
      using errcode = '23514';
  end if;
  return new;
end $$;

revoke all on function app.enforce_half_day_rule()
  from public, anon, authenticated;

comment on function app.enforce_half_day_rule() is
  'Refuses half a day of a leave type taken in whole days, on the write '
  'that asks for it. An update that moves neither the flag nor the type '
  'is approving or cancelling a request already filed, and a rule '
  'applied to that would strand every request in flight the moment the '
  'policy tightened.';
