-- ---------------------------------------------------------------------
-- What the practice owes the Registrar
--
-- The last module to get figures, and the one where being wrong costs
-- somebody money: a late Annual Return is a compounding penalty and a
-- charge registered a day late is void against the liquidator. The
-- other blocks are carried through from 0303 unchanged.
--
-- ## The figures are counted off the deadline engine, not off the table
--
-- `corp_filings` holds the filings somebody has opened a row for. The
-- dangerous filing is the one nobody has opened a row for — the
-- anniversary that came round while the client file sat closed. So the
-- count comes from `public.corp_upcoming_filings`, which computes what
-- the Act requires from the incorporation date and the year end whether
-- or not a row exists, merges the status of any row that does, and
-- already drops `lodged`, `approved` and `not_applicable`.
--
-- That also means the deadline arithmetic is not restated here. It is
-- asserted in `supabase/tests/secretarial.sql` — the anniversary rule,
-- the leap-day case, 180 + 30 for financial statements, and no AGM for
-- a private company. A second copy in this function would be a second
-- thing to keep in step with the Act.
--
-- ## This block uses `current_date`, and the others use Kuala Lumpur
--
-- Deliberate, and the one place in this function where that is true.
-- `corp_upcoming_filings` windows on `current_date`, so counting here
-- against `v_today` would make the dashboard and the list under it
-- disagree for the eight hours a day when UTC is still yesterday —
-- a tile saying three overdue above a screen showing two.
--
-- Which of the two is right for a Malaysian statutory deadline is a
-- fair question, and the answer is probably Kuala Lumpur. But that is a
-- change to the deadline engine, not to a dashboard tile: it would move
-- every due date `corp_upcoming_filings` returns, and it belongs in a
-- migration that says so and re-runs `secretarial.sql` against it. It
-- is recorded here rather than made as a side effect.
--
-- ## Overdue and due-soon do not overlap
--
-- `overdue` is strictly before today and `due_soon` starts at today, so
-- a filing due this morning is in exactly one of them. Adding the two
-- gives the size of the queue, which is what somebody does with them.
-- ---------------------------------------------------------------------

create or replace function public.module_dashboard(p_org_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_out   jsonb := '{}'::jsonb;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  -- The month v_today falls in, in Kuala Lumpur. Bounds rather than
  -- date_trunc at the point of use, so both CRM figures are read
  -- against one month and cannot drift apart.
  v_month_start date := date_trunc('month', v_today)::date;
  v_month_end   date := (date_trunc('month', v_today)
                          + interval '1 month' - interval '1 day')::date;
  v_base  char(3);
begin
  if p_org_id is null or not app.is_org_member(p_org_id) then
    raise exception 'Not a member of this organization'
      using errcode = '42501';
  end if;

  -- Service desk. "Breaching" is the queue somebody has to look at
  -- before lunch: already past its resolution deadline, or inside the
  -- last four hours of it.
  if app.module_visible(p_org_id, 'ticketing')
     and app.can_read_module(p_org_id, 'ticketing')
  then
    v_out := v_out || jsonb_build_object('ticketing', (
      select jsonb_build_object(
        'open',        count(*) filter (
                         where t.status in ('new','open','pending','on_hold')),
        'unassigned',  count(*) filter (
                         where t.assignee_id is null
                           and t.status in ('new','open')),
        'breaching',   count(*) filter (
                         where t.status in ('new','open','pending','on_hold')
                           and t.resolution_due_at is not null
                           and t.resolution_due_at < now() + interval '4 hours'),
        'breached',    count(*) filter (
                         where t.status in ('new','open','pending','on_hold')
                           and t.resolution_breached),
        'resolved_today', count(*) filter (
                         where t.resolved_at is not null
                           and (t.resolved_at at time zone 'Asia/Kuala_Lumpur')::date
                               = v_today))
        from public.tickets t
       where t.org_id = p_org_id
         and t.deleted_at is null));
  end if;

  -- Point of sale. Today's takings as rung up, plus what is still open
  -- on a table somewhere.
  if app.module_visible(p_org_id, 'pos')
     and app.can_read_module(p_org_id, 'pos')
  then
    v_out := v_out || jsonb_build_object('pos', (
      select jsonb_build_object(
        'takings_today', coalesce(sum(s.total_amount) filter (
                           where s.status = 'completed'
                             and (s.completed_at at time zone 'Asia/Kuala_Lumpur')::date
                                 = v_today), 0),
        'sales_today',   count(*) filter (
                           where s.status = 'completed'
                             and (s.completed_at at time zone 'Asia/Kuala_Lumpur')::date
                                 = v_today),
        'open_bills',    count(*) filter (where s.status = 'parked'),
        'open_shifts',   (select count(*) from public.pos_shifts sh
                           where sh.org_id = p_org_id and sh.status = 'open'))
        from public.pos_sales s
       where s.org_id = p_org_id));
  end if;

  -- Stock. Value is what the ledger carries it at, and the two counts
  -- are the ones somebody acts on: what has run out, and what is at or
  -- under the level it should be reordered at.
  --
  -- Counted as items rather than as item-and-warehouse rows. "Nine
  -- items to reorder" is a sentence somebody can act on; "nine rows"
  -- counts the same shirt twice for being low in two warehouses, and
  -- one purchase order fixes both.
  if app.module_visible(p_org_id, 'inventory')
     and app.can_read_module(p_org_id, 'inventory')
  then
    v_out := v_out || jsonb_build_object('inventory', (
      select jsonb_build_object(
        'stock_value',  coalesce(sum(v.value), 0),
        -- Pooled across warehouses, deliberately NOT the view's own
        -- `needs_reorder`. That column asks whether THIS warehouse is at
        -- or below the level, which is the right question on the stock
        -- screen and the wrong one here: it fires for an item with none
        -- on one shelf and forty on the next, and a buyer sent to raise
        -- a purchase order for it has been sent for nothing.
        'to_reorder',   (select count(*) from (
                           select v2.item_id
                             from public.v_stock_valuation v2
                            where v2.org_id = p_org_id
                            group by v2.item_id
                           having max(v2.reorder_level) > 0
                              and coalesce(sum(v2.quantity), 0)
                                  <= max(v2.reorder_level)) y),
        -- Out of stock is about the item, not the shelf: none anywhere,
        -- rather than none in one warehouse while a pallet sits in the
        -- next one.
        'out_of_stock', (select count(*) from (
                           select v2.item_id
                             from public.v_stock_valuation v2
                            where v2.org_id = p_org_id
                            group by v2.item_id
                           having coalesce(sum(v2.quantity), 0) <= 0) z),
        'items_held',   count(distinct v.item_id) filter (where v.quantity > 0))
        from public.v_stock_valuation v
       where v.org_id = p_org_id));
  end if;

  -- The people. Headcount is who is on the books and coming to work:
  -- probation and notice are both employment, and both are paid. The
  -- other three are queues somebody has to clear.
  if app.module_visible(p_org_id, 'hr')
     and app.can_read_module(p_org_id, 'hr')
  then
    v_out := v_out || jsonb_build_object('hr', (
      select jsonb_build_object(
        'headcount', count(*) filter (
                       where e.employment_status
                             in ('active', 'probation', 'notice')),
        -- Counted as people, not as requests: somebody with two
        -- approved days that happen to abut is one person away, and a
        -- manager looking at who is in today wants the person.
        'on_leave_today', (select count(distinct l.employee_id)
                             from public.leave_requests l
                            where l.org_id = p_org_id
                              and l.status = 'approved'
                              and v_today between l.start_date and l.end_date),
        'leave_to_approve', (select count(*) from public.leave_requests l
                              where l.org_id = p_org_id
                                and l.status = 'submitted'),
        'claims_to_approve', (select count(*) from public.expense_claims c
                               where c.org_id = p_org_id
                                 and c.status = 'submitted'))
        from public.employees e
       where e.org_id = p_org_id));
  end if;

  -- Payroll is its own module and its own tab. A run moves draft ->
  -- calculated -> approved -> posted -> paid, so "open" is everything
  -- that has not been paid and has not been voided, and the two
  -- narrower figures are the two desks it sits on on the way.
  if app.module_visible(p_org_id, 'payroll')
     and app.can_read_module(p_org_id, 'payroll')
  then
    v_out := v_out || jsonb_build_object('payroll', (
      select jsonb_build_object(
        'open_runs',  count(*) filter (
                        where r.status in ('draft', 'calculated',
                                           'approved', 'posted')),
        'to_approve', count(*) filter (where r.status = 'calculated'),
        'to_pay',     count(*) filter (
                        where r.status in ('approved', 'posted')))
        from public.payroll_runs r
       where r.org_id = p_org_id));
  end if;

  -- The pipeline, and the follow-ups nobody has made. See the header
  -- for why the value is not converted and why overdue is a clock.
  if app.module_visible(p_org_id, 'crm')
     and app.can_read_module(p_org_id, 'crm')
  then
    v_base := app.base_currency(p_org_id);
    v_out := v_out || jsonb_build_object('crm', (
      select jsonb_build_object(
        'open_deals',  count(*) filter (where o.status = 'open'),
        -- The company's own currency only. `other_currency` is what
        -- says so, rather than the total quietly being short.
        'open_value',  coalesce(sum(o.amount) filter (
                         where o.status = 'open'
                           and o.currency = v_base), 0),
        'other_currency', count(*) filter (
                            where o.status = 'open'
                              and o.currency <> v_base),
        'closing_this_month', count(*) filter (
                                where o.status = 'open'
                                  and o.expected_close_date
                                      between v_month_start and v_month_end),
        -- Dated by when it was won, not by when somebody got round to
        -- recording it.
        'won_this_month', count(*) filter (
                            where o.status = 'won'
                              and o.actual_close_date
                                  between v_month_start and v_month_end),
        'overdue_activities', (
          select count(*) from public.activities a
           where a.org_id = p_org_id
             and a.status in ('pending', 'overdue')
             and a.due_date is not null
             and a.due_date <= now()))
        from public.opportunities o
       where o.org_id = p_org_id));
  end if;

  -- The Registrar's queue. `corp_upcoming_filings` is the same source
  -- the corp-sec screen lists from, which is why this block counts on
  -- `current_date` rather than on `v_today` — see the header.
  if app.module_visible(p_org_id, 'secretarial')
     and app.can_read_module(p_org_id, 'secretarial')
  then
    v_out := v_out || jsonb_build_object('secretarial', (
      select jsonb_build_object(
        -- Strictly before today. A filing due today is not yet late,
        -- and telling a secretary it is would send them to argue with
        -- SSM about a deadline they have not missed.
        'overdue',   count(*) filter (where u.due_date < current_date),
        'due_soon',  count(*) filter (
                       where u.due_date >= current_date
                         and u.due_date <= current_date + 30),
        -- The date itself, not a count: what a practice actually wants
        -- off this tile is when the next one lands.
        'next_due',  min(u.due_date) filter (
                       where u.due_date >= current_date),
        'entities',  (select count(*) from public.corp_entities e
                       where e.org_id = p_org_id
                         and e.status in ('incorporated', 'dormant')
                         and e.disengaged_on is null))
        from public.corp_upcoming_filings(p_org_id, 120) u));
  end if;

  return v_out;
end;
$$;

comment on function public.module_dashboard(uuid) is
  'Figures for the modules a company holds and this caller may read, '
  'keyed by module code. One object rather than one call per module, '
  'because the dashboard opens every tab it is allowed to. Money is '
  'never converted here (0303) and statutory deadlines are counted off '
  'corp_upcoming_filings rather than restated (0304).';
