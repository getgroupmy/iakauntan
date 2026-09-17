-- ---------------------------------------------------------------------
-- The same clock, one layer down: a moment cast to a day
--
-- `0419` to `0423` pinned every function that asks the session what day
-- it is *now*. This is the last four, which ask it a slightly different
-- way and were not caught by that rule.
--
-- ## Why `completed_at::date` is the same defect
--
-- Casting a `timestamptz` to `date` is not "the day it happened". It is
-- the day it happened *in the session's time zone*, which on Supabase is
-- UTC. A sale completed at 00:30 in Kuala Lumpur has a `completed_at`
-- that UTC calls half past four the previous afternoon, so
-- `completed_at::date` is yesterday -- the same eight-hour window, the
-- same day out, reached through a cast rather than through
-- `current_date`.
--
-- `0306` had already written the correct form, in `module_dashboard`:
-- `(t.resolved_at at time zone 'Asia/Kuala_Lumpur')::date`. Fifty-two
-- migrations spell that out somewhere. These four did not.
--
-- ## Found by asking Postgres, not by reading
--
-- Every `timestamptz` column in `public` and `app` -- ninety-three
-- distinct names -- crossed against every function body with comments
-- stripped, looking for `<column>::date`. Four hits, in four functions,
-- and nothing at all for `date_trunc` or `extract` over a `timestamptz`,
-- which inherit the session's zone the same way. That is the whole
-- residue.
--
-- ## What each one costs
--
--   * `app.pos_deplete_recipes` dates the stock movement a plate takes
--     out of the store. After `0420` the sale's invoice is dated in
--     Malaysia and this movement was still dated in UTC, so for eight
--     hours a day the two disagreed about which day the food left the
--     kitchen. That inconsistency is new; the wrong date is not.
--   * `public.start_membership` sets `started_on`, which is the start of
--     the billing period. A membership bought at half past midnight
--     began the day before, and lost a day at the far end.
--   * `app.contact_payment_lag` is `allocated_at - due_date`: how many
--     days late a customer pays. It feeds how much credit they are
--     given.
--   * `app.purchase_document_settled_on` falls back to the allocation
--     date when a payment has no date of its own, and that is the date
--     the bill is reported as settled on.
--
-- ## `app.malaysian_day`, and one place that knows the zone
--
-- `app.today()` was written as `(now() at time zone
-- 'Asia/Kuala_Lumpur')::date`. It is now `app.malaysian_day(now())`, so
-- the zone is written once in the schema rather than twice. `0419` gave
-- the reason: when somebody asks for a per-organization time zone this
-- is the one place to change, and two places is not one place.
--
-- Nothing about `app.today()` changes -- same result, same volatility,
-- same signature -- and `supabase/tests/malaysian_clock.sql` asserts all
-- three of those independently of how it is written.
--
-- ## The rule, widened
--
-- The assertion at the end scans for the cast as well, by the same
-- means it was found with: every `timestamptz` column name, crossed
-- against every function body. A regex over the text alone could not do
-- this -- it has to know which columns carry a zone.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The day a moment fell on, in the country the books are kept in
-- ---------------------------------------------------------------------
create or replace function app.malaysian_day(p_at timestamptz) returns date
language sql
immutable
set search_path = pg_catalog, public, app, pg_temp
as $$ select (p_at at time zone 'Asia/Kuala_Lumpur')::date $$;

comment on function app.malaysian_day(timestamptz) is
  'The Malaysian calendar day a moment fell on. Casting a timestamptz '
  'to date gives the day in the session time zone, which on Supabase is '
  'UTC -- eight hours behind. Use this instead. IMMUTABLE because the '
  'answer depends only on the argument; app.today() stays STABLE '
  'because now() is.';

grant execute on function app.malaysian_day(timestamptz)
  to authenticated, service_role;

-- And today is the Malaysian day of this moment, so the zone is named
-- once rather than twice. STABLE rather than IMMUTABLE, unchanged: the
-- argument is `now()`.
create or replace function app.today() returns date
language sql
stable
set search_path = pg_catalog, public, app, pg_temp
as $$ select app.malaysian_day(now()) $$;

-- The day the plate came off the shelf.
create or replace function app.pos_deplete_recipes(p_sale uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale   public.pos_sales;
  v_wh     uuid;
  v_row    record;
  v_cost   numeric := 0;
  v_lines  jsonb := '[]'::jsonb;
  v_cogs   uuid;
  v_inv    uuid;
  v_entry  uuid;
  v_moved  numeric;
  v_qty    numeric;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    return null;
  end if;

  select coalesce(o.warehouse_id,
                  (select w.id from public.warehouses w
                    where w.org_id = v_sale.org_id and w.is_default limit 1))
    into v_wh
    from public.pos_outlets o where o.id = v_sale.outlet_id;
  if v_wh is null then
    return null;
  end if;

  for v_row in
    with need as (
      select c.item_id, sum(c.quantity) as quantity
        from public.pos_sale_lines l
        cross join lateral app.pos_recipe_components(l.item_id, l.quantity) c
       where l.sale_id = p_sale and l.item_id is not null
       group by c.item_id
      union all
      select c.item_id, sum(c.quantity)
        from public.pos_sale_lines l
        join public.pos_sale_line_modifiers m on m.line_id = l.id
        join public.pos_modifiers pm on pm.id = m.modifier_id
        cross join lateral app.pos_item_consumption(
          pm.recipe_item_id,
          app.uom_qty(pm.recipe_item_id,
                      coalesce(pm.recipe_quantity, 0),
                      coalesce(pm.recipe_uom_code,
                               (select i.uom_code from public.items i
                                 where i.id = pm.recipe_item_id)))
            * m.quantity * l.quantity) c
       where l.sale_id = p_sale
         and pm.recipe_item_id is not null
         and coalesce(pm.recipe_quantity, 0) > 0
       group by c.item_id
    )
    select n.item_id, sum(n.quantity) as quantity, i.name, i.tracking
      from need n join public.items i on i.id = n.item_id
     where i.track_inventory
     group by n.item_id, i.name, i.tracking
     having sum(n.quantity) > 0
  loop
    v_qty := round(v_row.quantity, 4);

    -- The one new clause. See the header.
    if v_row.tracking is not null and v_row.tracking <> 'none' then
      v_qty := least(v_qty, round(app.lot_available(v_row.item_id, v_wh), 4));
    end if;
    if v_qty <= 0 then
      continue;
    end if;

    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id,
      warehouse_id, quantity, unit_cost, source_table, source_id, notes)
    values (
      v_sale.org_id,
      app.next_document_number_internal(v_sale.org_id, 'stock_movement'),
      coalesce(app.malaysian_day(v_sale.completed_at), app.today()),
      'assembly_out', v_row.item_id, v_wh, -v_qty, 0,
      'pos_sales', p_sale, 'Recipe ' || v_sale.sale_no);

    select sm.total_cost into v_moved
      from public.stock_movements sm
     where sm.source_table = 'pos_sales' and sm.source_id = p_sale
       and sm.item_id = v_row.item_id
     order by sm.created_at desc limit 1;

    v_cost := v_cost + coalesce(v_moved, 0);
  end loop;

  if round(v_cost, 2) = 0 then
    return null;
  end if;

  select a.id into v_cogs from public.accounts a
   where a.org_id = v_sale.org_id and a.code = '5200';
  select a.id into v_inv from public.accounts a
   where a.org_id = v_sale.org_id and a.code = '1310';
  if v_cogs is null or v_inv is null then
    return null;
  end if;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_cogs,
      'description', 'Food cost ' || v_sale.sale_no,
      'debit', greatest(-v_cost, 0), 'credit', greatest(v_cost, 0)),
    jsonb_build_object('account_id', v_inv,
      'description', 'Ingredients ' || v_sale.sale_no,
      'debit', greatest(v_cost, 0), 'credit', greatest(-v_cost, 0)));

  v_entry := app.create_gl_entry_internal(
    v_sale.org_id,
    coalesce(app.malaysian_day(v_sale.completed_at), app.today()),
    'stock_movement', v_lines,
    'Recipe consumption ' || v_sale.sale_no, 'pos_sales', p_sale);

  update public.stock_movements sm
     set gl_entry_id = v_entry
   where sm.source_table = 'pos_sales' and sm.source_id = p_sale
     and sm.gl_entry_id is null;

  return v_entry;
end;
$$;

-- The day a membership began, and the period it began in.
create or replace function public.start_membership(
  p_sale       uuid,
  p_membership uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale public.pos_sales;
  v_mem  public.pos_memberships;
  v_sub  uuid;
  v_rec  uuid;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'memberships') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'completed' then
    raise exception
      'Take the money first. A membership that starts before the sale '
      'completes is an entitlement nobody paid for.'
      using errcode = '23514';
  end if;
  if v_sale.contact_id is null then
    raise exception 'A membership needs a member. Say who the customer is.'
      using errcode = '23502';
  end if;

  select * into v_mem from public.pos_memberships
   where id = p_membership and org_id = v_sale.org_id and is_active;
  if v_mem.id is null then
    raise exception 'That membership is not on offer.' using errcode = 'P0002';
  end if;

  -- The membership has to have been bought on this sale. Otherwise
  -- "start a membership" is a button that gives one away.
  if not exists (select 1 from public.pos_sale_lines l
                  where l.sale_id = p_sale and l.item_id = v_mem.item_id) then
    raise exception
      'This sale does not include %. Ring it up first.', v_mem.name
      using errcode = '23514';
  end if;

  insert into public.pos_membership_subscriptions
    (org_id, membership_id, contact_id, started_on, origin_sale_id, created_by)
  values (v_sale.org_id, p_membership, v_sale.contact_id,
          coalesce(app.malaysian_day(v_sale.completed_at), app.today()), p_sale, auth.uid())
  returning id into v_sub;

  -- The renewal schedule, from the invoice the customer just paid --
  -- which already carries the right price, tax code and terms.
  if v_sale.invoice_id is not null and app.can_post(v_sale.org_id) then
    begin
      v_rec := public.create_recurring_document(
        v_sale.invoice_id,
        v_mem.name || ' — ' || to_char(app.today(), 'YYYY'),
        v_mem.period,
        (select (p.period_end + 1)::date from app.membership_period(v_sub, app.today()) p),
        1, null, null, false, false);
      update public.pos_membership_subscriptions s
         set recurring_document_id = v_rec where s.id = v_sub;
    exception when others then
      -- Reported rather than fatal. The member has paid; the schedule
      -- is a thing somebody with the right role can add afterwards, and
      -- `membership_billing_gaps` is how they find out they need to.
      null;
    end;
  end if;

  return v_sub;
end;
$$;

-- How many days late a customer pays, which sets their credit.
create or replace function app.contact_payment_lag(p_contact uuid)
returns integer
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select coalesce(round(avg(greatest(least(lag, 180), -30)))::integer, 0)
    from (
      select (app.malaysian_day(a.allocated_at) - d.due_date) as lag
        from public.payment_allocations a
        join public.sales_documents d on d.id = a.invoice_id
       where d.contact_id = p_contact
         and d.doc_type = 'invoice'
         and d.due_date is not null
         and d.status = 'completed'
       order by a.allocated_at desc
       limit 12
    ) recent;
$$;

-- And the day a bill was settled, when nothing else says.
create or replace function app.purchase_document_settled_on(p_bill uuid)
returns date language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_doc  public.purchase_documents;
  v_when date;
begin
  select * into v_doc from public.purchase_documents where id = p_bill;
  if v_doc.id is null then return null; end if;
  -- `completed` is what `app.apply_allocation` sets when the balance
  -- reaches nil; `void` and the pre-posting statuses are not settlement
  -- and a voided bill has a nil balance for a different reason.
  if v_doc.status not in ('posted', 'partial', 'completed') then
    return null;
  end if;
  if round(coalesce(v_doc.balance_amount, 0), 2) > 0 then return null; end if;

  select max(coalesce(pp.payment_date, dn.doc_date, app.malaysian_day(a.allocated_at)))
    into v_when
    from public.payment_allocations a
    left join public.purchase_payments pp on pp.id = a.payment_id
    left join public.purchase_documents dn on dn.id = a.credit_note_id
   where a.bill_id = p_bill;

  -- A bill with a zero balance and no allocation at all is a nil bill,
  -- and the day it was posted is the day it stopped being owed.
  return coalesce(v_when, v_doc.doc_date);
end $$;

-- ---------------------------------------------------------------------
-- The rule, widened to the cast
--
-- `0423` closed "no function asks the session what day it is now". This
-- closes "and none asks it what day a moment fell on", which is the same
-- question through a different door. The scan has to know which columns
-- carry a time zone, so it reads `information_schema` rather than
-- pattern-matching the text.
--
-- A `timestamp without time zone` cast to `date` is zone-independent and
-- is not scanned for. Neither is `(x at time zone '...')::date`, which
-- is the correct form: the `::date` there follows a closing bracket, not
-- a column name.
-- ---------------------------------------------------------------------
do $$
declare
  v_left text[];
begin
  select array_agg(distinct f || ' (' || c || ')')
    into v_left
    from (
      select n.nspname || '.' || p.proname as f,
             regexp_replace(p.prosrc, '--[^\n]*', '', 'g') as src
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('public', 'app') and p.prokind in ('f', 'p')
    ) fn
    cross join (
      select distinct column_name as c
        from information_schema.columns
       where table_schema in ('public', 'app')
         and data_type = 'timestamp with time zone'
    ) tz
   where fn.src ~ ('\m' || tz.c || '\M\s*::\s*date');

  if v_left is not null then
    raise exception
      'FAIL 0424 left % function(s) casting a moment to a day in the '
      'session''s time zone: %. Wrap it in app.malaysian_day().',
      cardinality(v_left), array_to_string(v_left, ', ')
      using errcode = '23514';
  end if;
end $$;
