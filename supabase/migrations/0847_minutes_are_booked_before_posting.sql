-- =====================================================================
-- iAkauntan :: 0847 minutes are booked before posting
--
-- A manufacturing order's operations are copied from its bill of
-- materials by `confirm_manufacturing_order`, and
-- `post_manufacturing_order` costs the labour from them -- the minutes
-- actually booked where there are any, the planned ones where not, at
-- each work centre's rate. Both are definers. The screen's one write is
-- booking the minutes actually taken, on an order not yet posted.
-- `0843` locked the components beside them; the operations kept a
-- policy for all commands asking only `app.can_post`.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`, on a posted order baked for thirty minutes at RM60 an
-- hour -- RM7.00 a loaf, as posted: its operation rewritten to 600
-- minutes was accepted, and deleting it was accepted, the journal and
-- the stock's cost standing as they were. Booking minutes on a
-- confirmed order, the screen's own write, was accepted as it should be.
--
-- Answered "book minutes only, unposted": a trigger refuses a client's
-- own statement -- role `authenticated` or `anon`, at the top trigger
-- depth -- that makes or removes an operation, changes anything on one
-- but its `actual_minutes`, or books minutes on an order already posted.
-- Confirming and posting are definers and pass. NOT security definer.
--
-- Production held five operations on 12 October, three on posted
-- orders, none with minutes booked, all in demonstration companies.
-- =====================================================================

create or replace function app.minutes_are_booked_before_posting()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_order text;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return coalesce(new, old);
  end if;

  if tg_op <> 'UPDATE' then
    raise exception
      'An order''s operations are copied from its bill of materials when '
      'it is confirmed. Minutes are booked against them; they are not '
      'made or taken away by hand.'
      using errcode = '42501';
  end if;

  if (to_jsonb(new) - 'actual_minutes') is distinct from
     (to_jsonb(old) - 'actual_minutes') then
    raise exception
      'Only the minutes actually taken are booked against an operation. '
      'The rest is the recipe the order was confirmed with.'
      using errcode = '42501';
  end if;

  if new.actual_minutes is distinct from old.actual_minutes then
    select m.order_no into v_order
      from public.manufacturing_orders m
     where m.id = old.mo_id and m.gl_entry_id is not null;
    if found then
      raise exception
        'Manufacturing order % is posted, and its cost was taken from '
        'these minutes. They are not booked again.',
        v_order
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

revoke all on function app.minutes_are_booked_before_posting()
  from public, anon, authenticated;

comment on function app.minutes_are_booked_before_posting() is
  'On mo_operations: refuses a client''s own statement that makes or '
  'removes an operation, changes anything but actual_minutes, or books '
  'minutes on a posted order. confirm and post pass. 0847.';

create trigger minutes_are_booked_before_posting
  before insert or update or delete on public.mo_operations
  for each row execute function app.minutes_are_booked_before_posting();
