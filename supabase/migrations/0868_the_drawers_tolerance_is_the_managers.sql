-- =====================================================================
-- iAkauntan :: 0868 the drawer's tolerance is the manager's
--
-- `close_pos_shift` refuses to close a shift whose drawer is further out
-- than `pos_settings.variance_tolerance` unless `app.can_admin` admits
-- the member closing it: "Only a manager can close a shift more than %
-- out." The tolerance itself was written by anybody the till admits
-- (`pos_settings_write` is `can_write_module(org, 'pos')`) -- the
-- cashier whose drawer it judges among them -- and a company with no
-- settings row, or a row with no tolerance, has no limit at all.
--
-- Measured on 13 October 2026, locally, as a `sales` cashier with the
-- role `authenticated`: closing a shift 50.00 short against a tolerance
-- of 5.00 was refused; he set the tolerance to nothing himself, and the
-- same shift closed 50.00 short.
--
-- Production held 5 companies with a till, each with a tolerance, 7
-- shifts, and 2 members among them who are not managers. Nothing in the
-- app reads or writes the table; only the demo data does, as its owner.
--
-- Answered "tolerance is the manager's". A trigger refuses a client's
-- own statement that loosens the tolerance -- raises it, clears it, or
-- deletes the row that holds it -- unless `can_admin` admits the member,
-- which is the test `close_pos_shift` applies. Anybody the till admits
-- may still lower it or set one; a new row can only arrive tighter than
-- none, so an insert is not asked. NOT security definer, as `0822`'s: a
-- definer would always answer "the owner".
-- =====================================================================

create or replace function app.drawer_tolerance_is_the_managers()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_loosened boolean;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  -- Written out by operation: `new` is not there to read on a delete.
  if tg_op = 'DELETE' then
    v_loosened := old.variance_tolerance is not null;
  else
    v_loosened := old.variance_tolerance is not null
                  and (new.variance_tolerance is null
                       or new.variance_tolerance > old.variance_tolerance);
  end if;

  if v_loosened and not app.can_admin(old.org_id) then
    raise exception
      'Only a manager can raise the drawer''s tolerance or take it away: '
      'it is what decides who may close a shift that is out.'
      using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create trigger drawer_tolerance_is_the_managers
  before update or delete on public.pos_settings
  for each row execute function app.drawer_tolerance_is_the_managers();
