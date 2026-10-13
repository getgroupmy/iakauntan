-- =====================================================================
-- iAkauntan :: 0867 credit is loosened by whoever answers for it
--
-- `0362` made a customer's `credit_hold` refuse an invoice whatever the
-- company's credit control mode, because "a hold is a person's
-- instruction", and `0086` and `0467` refuse what would take a customer
-- past `credit_limit` in block mode -- at the till as well, for the part
-- of a basket put on account. Both columns were written by any member
-- who may write (`contacts_update` is `can_write`): the cashier the hold
-- is there to stop could take it off.
--
-- Measured on 13 October 2026, locally, as a `sales` member -- may
-- write, may use the till, may not post -- with the role
-- `authenticated`: a sale on account to a customer on hold was refused,
-- "Encik Zaid is on credit hold"; he set `credit_hold` off and the limit
-- to 1,000,000 himself; and the same sale went through.
--
-- Production held 4 customers with a limit, in 1 company, with 1 member
-- there who writes and does not post; none on hold; no tender on
-- account.
--
-- Answered "anyone tightens, posters loosen". A trigger refuses a
-- client's own statement that loosens a customer's credit -- takes a
-- hold off, raises a limit, or takes one away (nought is no limit:
-- `if coalesce(v_limit, 0) <= 0 then return new`; both columns are
-- NOT NULL, so there is no "none" to read as well) -- unless
-- `can_post` admits the member: the owner, an admin, an accountant.
-- Anybody who may write may still put a customer on hold, lower a
-- limit, or set one where there was none; a new contact can only arrive
-- tighter than no limit at all, so an insert is not asked, and
-- `import_contacts`, which only inserts, is not either. NOT security
-- definer, as `0822`'s: a definer would always answer "the owner".
-- =====================================================================

create or replace function app.credit_is_loosened_by_a_poster()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  if (old.credit_hold and not new.credit_hold)
     or (old.credit_limit > 0
         and (new.credit_limit <= 0
              or new.credit_limit > old.credit_limit)) then
    if not app.can_post(new.org_id) then
      raise exception
        'Only the owner, an admin or an accountant can take % off hold, '
        'raise its credit limit or take the limit away. Anybody may put '
        'a customer on hold or lower a limit.', old.name
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

create trigger credit_is_loosened_by_a_poster
  before update of credit_hold, credit_limit on public.contacts
  for each row execute function app.credit_is_loosened_by_a_poster();
