-- =====================================================================
-- iAkauntan :: 0372 a matter that could never be closed
--
-- `app.matter_status` is ('open', 'on_hold', 'closed', 'archived') and
-- the matters screen has had a **Closed** tab since it was written. It
-- has always been empty and always will be: nothing in this system ever
-- writes that value. `createMatter` inserts with the default 'open' and
-- there is no update path at all, so `matters.closed_date` — a column
-- since `0021` — has never held a date.
--
-- A file that cannot be closed is not a cosmetic problem in a law firm.
-- Every matter ever opened stays on the matter list, in the client-funds
-- report, and in the work-in-progress figures, for the life of the
-- practice. The list a partner uses to ask "what is still live" answers
-- "all of it".
--
-- ---------------------------------------------------------------------
-- What closing has to check
--
-- One thing, absolutely: the client's money.
--
-- The Legal Profession (Accounts) Rules 1990 govern a client account on
-- the principle that money held for a client is that client's, held for
-- a purpose, and to be paid out when the purpose is done. A matter
-- closed with a balance still on it is money nobody is looking at any
-- more — the file is off the list, the client is not chasing it, and it
-- sits in the client account until an accountant's report finds it. That
-- is the ordinary route to unclaimed client money, and it is the reason
-- this refusal is absolute rather than a warning.
--
-- Refused by naming the balance, because the two ways out are both a
-- click away and neither is "try again": pay it to the client, or move
-- it to their other matter with `0358`'s `transfer_between_matters`.
--
-- And one thing reported rather than refused: unbilled time and
-- disbursements. Those are the firm's own money, not the client's, and a
-- firm writing off work in progress on a file that came to nothing is
-- making a commercial decision it is entitled to make. Refusing would
-- turn an ordinary write-off into a dead end. So `close_matter` returns
-- what it left behind and the screen says so before asking to confirm —
-- the difference between a control and a nag is whose money it is.
--
-- Outstanding invoices are not checked at all. A matter is finished and
-- the bill is unpaid: that is what a receivables ledger is for, and
-- keeping the file open until the client pays would empty the word
-- "closed" of meaning.
--
-- ---------------------------------------------------------------------
-- And reopening
--
-- The client comes back on the same file, or the matter was closed by
-- somebody who picked the wrong row. Both ordinary. A state with no way
-- out of it is how somebody ends up opening a second matter for the same
-- job, which then splits the client's money across two files — the exact
-- thing `0358` exists to unpick.
-- =====================================================================

create or replace function public.close_matter(
  p_matter uuid,
  p_closed_date date default null,
  p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_m        public.matters;
  v_funds    numeric(18, 2);
  v_time     numeric(18, 2);
  v_disb     numeric(18, 2);
  v_date     date;
begin
  select * into v_m from public.matters
   where id = p_matter and deleted_at is null;
  if v_m.id is null then
    raise exception 'No such matter.' using errcode = 'P0002';
  end if;
  if not app.has_module(v_m.org_id, 'legal') then
    raise exception 'The legal module is not enabled for this organization.'
      using errcode = '42501';
  end if;
  if not app.can_post(v_m.org_id) then
    raise exception 'not permitted to close a matter' using errcode = '42501';
  end if;
  if v_m.status = 'closed' then
    raise exception 'That matter is already closed.' using errcode = '23514';
  end if;

  v_date := coalesce(p_closed_date,
                     (now() at time zone 'Asia/Kuala_Lumpur')::date);
  if v_date < v_m.opened_date then
    raise exception
      'A matter cannot close before it opened. It was opened on %.',
      v_m.opened_date using errcode = '23514';
  end if;

  -- The client's money. Voided transactions are excluded the same way
  -- `report_matter_summary` excludes them, so the two agree.
  select coalesce(sum(t.amount), 0) into v_funds
    from public.client_account_transactions t
   where t.matter_id = p_matter and t.status <> 'void';

  if round(v_funds, 2) <> 0 then
    raise exception
      'This matter still holds % of the client''s money. Pay it out, or '
      'move it to their other matter, before closing the file. Money left '
      'on a closed matter is money nobody is looking at.',
      to_char(round(v_funds, 2), 'FM999G999G990D00')
      using errcode = '23514';
  end if;

  -- The firm's own, reported rather than refused.
  select coalesce(sum(e.amount), 0) into v_time
    from public.time_entries e
   where e.matter_id = p_matter and e.is_billable and not e.is_billed;
  select coalesce(sum(d.amount + d.tax_amount), 0) into v_disb
    from public.disbursements d
   where d.matter_id = p_matter and d.is_billable and not d.is_billed;

  update public.matters set
    status      = 'closed',
    closed_date = v_date,
    notes       = case
                    when nullif(trim(coalesce(p_note, '')), '') is null
                      then notes
                    when nullif(trim(coalesce(notes, '')), '') is null
                      then trim(p_note)
                    else notes || E'\n' || trim(p_note)
                  end,
    updated_at  = now()
  where id = p_matter;

  return jsonb_build_object(
    'closed_date', v_date,
    'unbilled_time', round(v_time, 2),
    'unbilled_disbursements', round(v_disb, 2));
end $$;

create or replace function public.reopen_matter(p_matter uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_m public.matters;
begin
  select * into v_m from public.matters
   where id = p_matter and deleted_at is null;
  if v_m.id is null then
    raise exception 'No such matter.' using errcode = 'P0002';
  end if;
  if not app.has_module(v_m.org_id, 'legal') then
    raise exception 'The legal module is not enabled for this organization.'
      using errcode = '42501';
  end if;
  if not app.can_post(v_m.org_id) then
    raise exception 'not permitted to reopen a matter' using errcode = '42501';
  end if;
  if v_m.status not in ('closed', 'archived') then
    raise exception 'That matter is not closed.' using errcode = '23514';
  end if;

  update public.matters
     set status = 'open', closed_date = null, updated_at = now()
   where id = p_matter;
end $$;

revoke all on function public.close_matter(uuid, date, text) from public, anon;
revoke all on function public.reopen_matter(uuid) from public, anon;
grant execute on function public.close_matter(uuid, date, text) to authenticated;
grant execute on function public.reopen_matter(uuid) to authenticated;

comment on function public.close_matter(uuid, date, text) is
  'Closes a file. Refuses while the client account still holds anything '
  'for it: money on a closed matter is money nobody is looking at, and '
  'that is the ordinary route to unclaimed client money. Unbilled time '
  'and disbursements are the firm''s own and are reported, not refused.';
comment on function public.reopen_matter(uuid) is
  'Reopens a closed file. A client coming back and a matter closed by '
  'somebody who picked the wrong row are both ordinary, and the '
  'alternative is a second matter for the same job with the client''s '
  'money split across two files.';
