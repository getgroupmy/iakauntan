-- =====================================================================
-- iAkauntan :: 0775 a matter closes, by any road, only when empty
--
-- `close_matter` (`0372`) refuses to close a file while the client
-- account still holds anything for it: money on a closed matter is
-- money nobody is looking at, and that is the ordinary route to
-- unclaimed client money. It also refuses a closing date before the
-- opening one.
--
-- Both refusals lived in the function and nowhere else. The table's own
-- UPDATE policy (`matters_update`: `can_write` and the legal module)
-- lets any member who can write set `status` to 'closed' or 'archived'
-- and `closed_date` to anything, directly, and nothing on the table
-- looked at the money. Measured on 9 October 2026, locally: signed in
-- as an ordinary member, one UPDATE closed a matter holding RM5,000 of
-- client money. The app's own screen goes through `close_matter`, so
-- this was the API's road and not the button's -- which is the road a
-- rule enforced in one function does not cover.
--
-- Answered "guard the table". A trigger now asks the same two
-- questions of every change that takes a matter INTO closed or
-- archived, whichever road it came by, in `close_matter`'s own words.
-- `close_matter` keeps its own checks -- they run first and say the
-- same thing -- and `reopen_matter` is untouched: taking a file OUT of
-- closed is never refused here.
--
-- Production held four matters on 9 October, all open, two of them
-- holding client money and none closed, so nothing that exists is
-- refused by this.
--
-- SECURITY DEFINER because the sum has to be the TRUE sum. Run as the
-- caller, it would read `client_account_transactions` through the
-- caller's row-level security, and somebody who could not see the
-- client ledger would see nothing held and be let through.
-- =====================================================================

create or replace function app.matter_closes_only_when_empty()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_funds numeric(18, 2);
begin
  if new.status not in ('closed', 'archived') then
    return new;
  end if;

  if new.closed_date is not null and new.closed_date < new.opened_date then
    raise exception
      'A matter cannot close before it opened. It was opened on %.',
      new.opened_date using errcode = '23514';
  end if;

  -- Only a change INTO closed or archived is asked about the money, so
  -- a closed file stays editable -- its notes, its custom fields --
  -- whatever is later posted against it.
  if old.status is not distinct from new.status then
    return new;
  end if;

  -- The same rows `close_matter` and `report_matter_summary` read.
  select coalesce(sum(t.amount), 0) into v_funds
    from public.client_account_transactions t
   where t.matter_id = new.id and t.status <> 'void';

  if round(v_funds, 2) <> 0 then
    raise exception
      'This matter still holds % of the client''s money. Pay it out, or '
      'move it to their other matter, before closing the file. Money left '
      'on a closed matter is money nobody is looking at.',
      to_char(round(v_funds, 2), 'FM999G999G990D00')
      using errcode = '23514';
  end if;

  return new;
end $$;

revoke all on function app.matter_closes_only_when_empty() from public, anon, authenticated;

comment on function app.matter_closes_only_when_empty() is
  'Refuses to take a matter into closed or archived while the client '
  'account holds money for it, and a closing date before the opening '
  'date -- `close_matter`''s two rules, on every road into the table '
  'rather than on one function. Reads the client ledger as its owner, '
  'so the caller''s row-level security cannot hide the money. 0775.';

create trigger matters_close_only_when_empty
  before update of status, closed_date, opened_date on public.matters
  for each row execute function app.matter_closes_only_when_empty();
