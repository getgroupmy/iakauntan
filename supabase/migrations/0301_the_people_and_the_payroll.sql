-- ---------------------------------------------------------------------
-- The people, and the payroll they are on
--
-- Two more modules given figures, and two rather than one because `hr`
-- and `payroll` are separate modules with separate prices — a company
-- can hold either without the other, and after the dashboard grew a tab
-- per module they each need their own.
--
-- ## Headcount is who is employed, not who is untroubled
--
-- `probation` and `notice` are both employment and both get paid, so
-- both count. `resigned`, `retired`, `terminated` and `suspended` do
-- not: the first three have left and the fourth is not coming in. A
-- headcount that quietly dropped somebody serving notice would
-- disagree with the payroll run that is about to pay them.
--
-- ## On leave is a count of people
--
-- Somebody with two approved requests that happen to abut is one person
-- away, and a manager looking at who is in today wants the person, not
-- the paperwork. `distinct employee_id`, and the day is Malaysian —
-- `v_today` is already `now() at time zone 'Asia/Kuala_Lumpur'`, which
-- matters for the eight hours a day when UTC is yesterday.
--
-- The same gate as every other block: the company holds the module and
-- this caller may read it. Which is doing real work here, because HR is
-- the module a company is most likely to shut most of its staff out of.
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

  return v_out;
end;
$$;
