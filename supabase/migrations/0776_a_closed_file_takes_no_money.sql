-- =====================================================================
-- iAkauntan :: 0776 a closed file takes no money
--
-- `0775` stopped a matter being closed, by any road, while the client
-- account holds money for it. The other door was still open: money
-- could ARRIVE on a matter already closed. `receive_client_money` and
-- `transfer_between_matters` both put client money onto a closed or
-- archived matter, and none of the four client-money functions looked
-- at the matter's status. Measured on 9 October 2026 with a receipt:
-- the closed file took it, and then held money with nobody looking at
-- it -- the state `0775` exists to prevent, reached the other way.
--
-- Answered "refuse; reopen first". Money arriving for a closed or
-- archived matter is refused, naming the file and saying what to do.
-- Paying out and settling from a closed file stay allowed: they empty
-- it, which is never what the rule is against.
--
-- Asked of the ROW rather than of the four functions, so a fifth
-- function cannot forget it, and asked as "does this change raise what
-- the file holds" rather than "is this a receipt": a transfer in, a
-- receipt, an amount raised on a row, a row moved onto the file, a
-- payment out deleted -- each raises the balance of a file nobody is
-- watching, and each is refused the same way. Clients may only read
-- `client_account_transactions`, so every write already comes through
-- a function; this sits under all of them.
--
-- SECURITY DEFINER so the matter's status is read as it is, not as the
-- caller's row-level security lets them see it.
--
-- Production held no closed or archived matter on 9 October.
-- =====================================================================

create or replace function app.closed_matter_takes_no_money()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_matter uuid;
  v_gain   numeric(18, 2) := 0;
  v_status app.matter_status;
  v_no     text;
begin
  -- What this change adds to the one matter it can add to: the new
  -- row's part of that matter's balance, less the old row's part of
  -- the same matter's. A row moved between matters takes nothing from
  -- the one it lands on, so only the new part counts there.
  if tg_op = 'DELETE' then
    v_matter := old.matter_id;
    v_gain := case when old.status <> 'void' then -old.amount else 0 end;
  else
    v_matter := new.matter_id;
    v_gain := case when new.status <> 'void' then new.amount else 0 end;
    if tg_op = 'UPDATE'
       and old.matter_id is not distinct from new.matter_id
       and old.status <> 'void' then
      v_gain := v_gain - old.amount;
    end if;
  end if;

  if v_matter is null or v_gain <= 0 then
    return coalesce(new, old);
  end if;

  select m.status, m.matter_no into v_status, v_no
    from public.matters m where m.id = v_matter;

  if v_status in ('closed', 'archived') then
    raise exception
      'Matter % is %. Reopen it before taking money for it.',
      v_no, v_status using errcode = '23514';
  end if;

  return coalesce(new, old);
end $$;

revoke all on function app.closed_matter_takes_no_money() from public, anon, authenticated;

comment on function app.closed_matter_takes_no_money() is
  'Refuses any change to the client ledger that would raise what a '
  'closed or archived matter holds -- a receipt, a transfer in, an '
  'amount raised, a row moved onto it, a payment out deleted. Paying '
  'out of a closed file is allowed: it empties it. The other half of '
  '0775. 0776.';

create trigger client_money_not_onto_a_closed_matter
  before insert or update or delete on public.client_account_transactions
  for each row execute function app.closed_matter_takes_no_money();
