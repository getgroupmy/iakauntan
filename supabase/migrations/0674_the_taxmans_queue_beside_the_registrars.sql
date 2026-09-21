-- =====================================================================
-- iAkauntan :: 0674 the taxman's queue, beside the Registrar's
--
-- `0304` put the Registrar's deadlines on the company's home screen
-- and argued for it: a secretarial firm's whole risk is a missed
-- date, and a date nobody navigates to is a date nobody meets.
--
-- The argument is at least as good for LHDN. `0668` computes every
-- income tax deadline, `0669` lets one be marked done and `0673`
-- tracks the instalments -- and the only way to any of it was the
-- financial statements screen and then an icon. Income tax carries
-- the larger penalties of the two.
--
-- ---------------------------------------------------------------------
-- Two clocks, two sets of figures
--
-- A return and an instalment are different obligations on different
-- rhythms, and a company can be perfectly up to date on one while
-- behind on the other. Folding them into one count would produce a
-- number that is true of nothing: "three things overdue" where one is
-- a Form C and two are CP204 instalments tells somebody neither what
-- to do nor how much it costs.
--
-- So the tile carries both, and the screen draws them as separate
-- figures.
--
-- ---------------------------------------------------------------------
-- What is reused rather than rebuilt
--
-- Every figure comes from `tax_upcoming_filings` and
-- `tax_estimate_payment_summary` -- the same functions the screens
-- read. A dashboard that counted the rows itself would be a second
-- implementation of "overdue", and the day the two disagreed the tile
-- would be the one nobody could check.
--
-- That includes the filtering: `tax_upcoming_filings` already decides
-- which obligations an entity type has and drops what has been filed
-- or dismissed. Nothing is re-decided here.
--
-- ---------------------------------------------------------------------
-- The function is rewritten whole
--
-- `module_dashboard` has been replaced wholesale by every migration
-- that touched it since `0304`, because plpgsql has no way to add a
-- block to an existing body. This is `0602`'s version with one `if`
-- inserted before the return, and the rest character for character.
-- =====================================================================

create or replace function public.module_dashboard(p_org_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $fn$
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

  -- The Registrar's queue. Now on `v_today` like every other block:
  -- 0305 pinned `corp_upcoming_filings` to Kuala Lumpur, so the reason
  -- 0304 had for reading `current_date` here — keeping the tile and the
  -- screen under it on one clock — is now the reason for not doing so.
  if app.module_visible(p_org_id, 'secretarial')
     and app.can_read_module(p_org_id, 'secretarial')
  then
    v_out := v_out || jsonb_build_object('secretarial', (
      select jsonb_build_object(
        -- Strictly before today. A filing due today is not yet late,
        -- and telling a secretary it is would send them to argue with
        -- SSM about a deadline they have not missed.
        'overdue',   count(*) filter (where u.due_date < v_today),
        'due_soon',  count(*) filter (
                       where u.due_date >= v_today
                         and u.due_date <= v_today + 30),
        -- The date itself, not a count: what a practice actually wants
        -- off this tile is when the next one lands.
        'next_due',  min(u.due_date) filter (
                       where u.due_date >= v_today),
        'entities',  (select count(*) from public.corp_entities e
                       where e.org_id = p_org_id
                         and e.status in ('incorporated', 'dormant')
                         and e.disengaged_on is null))
        from public.corp_upcoming_filings(p_org_id, 120) u));
  end if;

  -- LHDN's queue, beside the Registrar's. `0668` computes every
  -- income tax deadline and `0669` lets one be taken off the list,
  -- and until now the only way to either was Financial statements
  -- and then an icon. A deadline nobody navigates to is a deadline
  -- nobody meets, which is the argument the secretarial tile above
  -- already won -- and income tax carries the larger penalties of
  -- the two.
  --
  -- Gated on `accounting`, which every company has, because a basis
  -- period is a thing every company has. Nothing here is filtered by
  -- entity type: `tax_upcoming_filings` has already done that.
  if app.module_visible(p_org_id, 'accounting')
     and app.can_read_module(p_org_id, 'accounting')
  then
    v_out := v_out || jsonb_build_object('tax', (
      select jsonb_build_object(
        -- Strictly before today, for the same reason as the
        -- Registrar's: a return due today is not yet late.
        'overdue',   count(*) filter (where u.due_date < v_today),
        'due_soon',  count(*) filter (
                       where u.due_date >= v_today
                         and u.due_date <= v_today + 30),
        'next_due',  min(u.due_date) filter (where u.due_date >= v_today),
        -- Which form, not just when. "Form C on 31 January" is what
        -- goes in the diary; "something on 31 January" is not.
        'next_form', (array_agg(u.form_label order by u.due_date)
                        filter (where u.due_date >= v_today))[1],
        -- Instalments are a different clock from returns and a
        -- company can be perfectly up to date on one while behind on
        -- the other, so they are their own figures rather than being
        -- folded into the counts above.
        'instalments_overdue', (
          select coalesce(sum(s.overdue_count), 0)
            from public.tax_estimates te
            cross join lateral
              public.tax_estimate_payment_summary(te.id) s
           where te.org_id = p_org_id
             and te.status <> 'superseded'),
        'instalment_next_due', (
          select min(s.next_due_on)
            from public.tax_estimates te
            cross join lateral
              public.tax_estimate_payment_summary(te.id) s
           where te.org_id = p_org_id
             and te.status <> 'superseded'))
        from public.tax_upcoming_filings(p_org_id, 120) u));
  end if;

  return v_out;
end;


$fn$;

revoke all on function public.module_dashboard(uuid) from public, anon;
grant execute on function public.module_dashboard(uuid) to authenticated;

comment on function public.module_dashboard(uuid) is
  'One figure set per module for the company''s home screen, built in '
  'Kuala Lumpur time. CHECKS EIGHT MODULES AND REQUIRES NONE OF THEM: '
  '`ticketing`, `pos`, `inventory`, `hr`, `payroll`, `crm`, '
  '`secretarial` and `accounting` each gate their own section, so the '
  'answer is a jsonb object carrying a key for every module this '
  'company has and nothing for the rest. A missing key means the '
  'module is off or hidden, NOT that the figure is zero -- the two '
  'are different and only one of them is worth telephoning somebody '
  'about. The only thing it insists on is membership of the company; '
  'it is filed under `ticketing` in this document because that is the '
  'first module its body names, which is an artefact of the filing '
  'and not a claim about the function.';
