-- What the recognition run is about to do, before it does it.
--
-- `0309` gave `public.recognise_revenue(org, up_to)`, which releases
-- deferred revenue that has been earned. It had no caller: the only way
-- to run it was psql, and the only way to know what it would post was to
-- read `revenue_schedule_periods` by hand.
--
-- This is the preview the button needs, modelled on `0083`'s
-- `fx_revaluation_preview` — the same job at the same point in the
-- month, and the card that shows it sits beside the foreign balances
-- card for the same reason.
--
-- One row per period end rather than per line. That is the shape the
-- run posts in (`0309` groups by `period_end` and writes one journal per
-- group), so the preview and the ledger agree line for line, and a
-- five-year contract is sixty rows rather than sixty times however many
-- lines there are.
--
-- ## Why the total is filtered, not just summed
--
-- `recognise_revenue` skips a group whose total is zero — there is no
-- journal to write. Left in the preview those groups would show as
-- "RM 0.00 to release" that pressing the button never clears, forever,
-- because nothing about them ever changes.
--
-- They are reachable: one sen spread over twelve months gives eleven
-- months of nothing and one month of a sen. So the `having` clause here
-- is not tidying, it is the preview telling the same truth the run does.
--
-- It is also self-correcting rather than a hole. A later invoice whose
-- line matures on the same period end lands in the same group, the
-- total stops being zero, and both are posted together on the next run.
--
-- Everything unposted is returned, not only what is due by some date.
-- The caller picks the date and splits the list on it, so moving the
-- date is not a round trip, and what is still to come is visible next to
-- what is about to post — which is the number somebody checks the
-- deferred revenue balance against.

create or replace function public.revenue_schedule_due(p_org_id uuid)
returns table (
  period_end date, amount numeric, lines integer, documents integer)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select p.period_end,
         round(sum(p.amount), 2),
         count(*)::integer,
         count(distinct p.document_id)::integer
    from public.revenue_schedule_periods p
   where p.org_id = p_org_id
     and p.gl_entry_id is null
   group by p.period_end
  having round(sum(p.amount), 2) <> 0
   order by p.period_end;
end;
$$;

comment on function public.revenue_schedule_due(uuid) is
  'Deferred revenue not yet released, one row per period end — the '
  'shape recognise_revenue posts in. Groups totalling zero are omitted '
  'because the run skips them.';

revoke all on function public.revenue_schedule_due(uuid) from public, anon;
grant execute on function public.revenue_schedule_due(uuid) to authenticated;
