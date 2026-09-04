-- =====================================================================
-- iAkauntan :: the drawer at close of day
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pos_drawer_shapes.sql
--
-- `app.pos_expected_cash` is the figure a cashier is measured against.
-- `close_pos_shift` turns it into a variance and decides whether that
-- variance needs a manager. Between them they are the most consequential
-- arithmetic in the till: get either wrong and a real person is short on
-- paper for money that was never in the drawer.
--
-- A mutation sweep of 56 one-line mutants over the shift lifecycle,
-- the expected-cash sum and the loyalty expiry killed 15.
--
-- `pos_counting.sql` and `pos.sql` between them prove the good path
-- thoroughly -- a float, a cash sale, a count, a close, and the
-- `counting` state in between. What they never do is get any of it
-- WRONG. There is no shift closed twice, no drawer counted as a
-- negative, no variance outside the tolerance, no manager refusing one,
-- no second till on the same outlet, and no voided sale.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- An outlet with two registers, so "this till" can be told from "any
-- till". Everything else follows `pos_counting.sql`'s shape.
create or replace function pg_temp.dr_org(p_name text)
returns uuid language plpgsql as $$
declare
  v_org uuid; v_wh uuid; v_walkin uuid; v_outlet uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory','loyalty']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Shop floor') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'KOPI', 'Kopi', 'stock', false, 'C62', 5.00);
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'SHOP', 'The shop', 'retail', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Counter one'),
         (v_org, v_outlet, 'T2', 'Counter two');
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CASH', 'Cash', 'cash', '01', true, true),
         (v_org, 'CARD', 'Card', 'card', '03', false, false);
  return v_org;
end $$;

create or replace function pg_temp.dr_reg(p_org uuid, p_code text)
returns uuid language sql as $$
  select id from public.pos_registers
   where org_id = p_org and code = p_code order by code limit 1;
$$;

create or replace function pg_temp.dr_tender(p_org uuid, p_code text)
returns uuid language sql as $$
  select id from public.pos_tender_types
   where org_id = p_org and code = p_code order by code limit 1;
$$;

create or replace function pg_temp.dr_item(p_org uuid)
returns uuid language sql as $$
  select id from public.items where org_id = p_org and code = 'KOPI'
   order by code limit 1;
$$;

-- A completed cash sale on a register, tendering `p_tendered` for a
-- `p_price` cup of coffee -- so the change given is real.
create or replace function pg_temp.dr_cash_sale(
  p_org uuid, p_reg uuid, p_price numeric, p_tendered numeric)
returns uuid language plpgsql as $$
declare v_sale uuid;
begin
  v_sale := public.open_pos_sale(p_reg);
  perform public.add_pos_sale_line(v_sale, pg_temp.dr_item(p_org), 1, p_price);
  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(jsonb_build_object(
      'type', pg_temp.dr_tender(p_org, 'CASH'), 'amount', p_tendered)));
  return v_sale;
end $$;

-- ---------------------------------------------------------------------
-- 1. Opening a till
-- ---------------------------------------------------------------------
-- Five of the six things `open_pos_shift` refuses had nothing on them.
-- The one that matters most on a shop floor is the last: two shifts
-- open on one till means two people counting the same drawer, and the
-- unique index would say so in words nobody holding a queue can act on.
do $$
declare
  v_org uuid := pg_temp.dr_org('Buka Laci Sdn Bhd');
  v_t1 uuid; v_t2 uuid; v_shift uuid; v_gone uuid; v_viewer uuid;
  v_type uuid;
begin
  v_t1 := pg_temp.dr_reg(v_org, 'T1');
  v_t2 := pg_temp.dr_reg(v_org, 'T2');

  perform pg_temp.check_refused('a till that is not there cannot be opened',
    format($q$ select public.open_pos_shift(%L, 50) $q$, gen_random_uuid()),
    '%does not exist, or has been retired%', 'P0002');

  -- A retired till and a switched-off till are different states and
  -- both must refuse. A shop that replaces a register keeps the old row
  -- for the sales already rung on it.
  insert into public.pos_registers (org_id, outlet_id, code, name, deleted_at)
  select v_org, outlet_id, 'T9', 'Retired counter', now()
    from public.pos_registers where id = v_t1
  returning id into v_gone;
  perform pg_temp.check_refused('a retired till cannot be opened',
    format($q$ select public.open_pos_shift(%L, 50) $q$, v_gone),
    '%does not exist, or has been retired%', 'P0002');

  update public.pos_registers set is_active = false where id = v_t2;
  perform pg_temp.check_refused('and neither can one switched off',
    format($q$ select public.open_pos_shift(%L, 50) $q$, v_t2),
    '%does not exist, or has been retired%', 'P0002');
  update public.pos_registers set is_active = true where id = v_t2;

  -- A float is money put in, so it cannot be negative. Nought is
  -- perfectly ordinary -- a card-only till starts empty.
  perform pg_temp.check_refused('a float cannot be negative',
    format($q$ select public.open_pos_shift(%L, -1) $q$, v_t1),
    '%float cannot be negative%', '23514');
  v_shift := public.open_pos_shift(v_t2, 0);
  perform pg_temp.check_eq('but a float of nothing is a float',
    (select opening_float from public.pos_shifts where id = v_shift), 0);

  -- The float given is the float recorded, because it is the first term
  -- of the expected figure.
  v_shift := public.open_pos_shift(v_t1, 150.50);
  perform pg_temp.check_eq('and the float given is the float on the shift',
    (select opening_float from public.pos_shifts where id = v_shift), 150.50);

  -- One shift per till. And a till in the middle of being COUNTED is
  -- not free either: `status <> 'closed'` covers both, where a test for
  -- `= 'open'` would let somebody start a second shift on a drawer
  -- somebody else is counting.
  perform pg_temp.check_refused('a till cannot have two shifts open',
    format($q$ select public.open_pos_shift(%L, 20) $q$, v_t1),
    '%already has a shift open%', '23505');
  update public.pos_shifts set status = 'counting' where id = v_shift;
  perform pg_temp.check_refused('nor one open while the drawer is counted',
    format($q$ select public.open_pos_shift(%L, 20) $q$, v_t1),
    '%already has a shift open%', '23505');
  update public.pos_shifts set status = 'open' where id = v_shift;

  -- Somebody who may only READ the till may not open one. A register of
  -- its own, because both the others are in use by now.
  --
  -- Note what makes this person: not the `role` column but an ACCESS
  -- TYPE with `pos` set to read. `app.module_access` returns 'write' to
  -- a member with no access type at all, so a bare 'viewer' row is a
  -- member who may still work the till -- which is right, and is why
  -- the restriction has to be written this way.
  insert into public.pos_registers (org_id, outlet_id, code, name)
  select v_org, outlet_id, 'T3', 'Counter three'
    from public.pos_registers where id = v_t1
  returning id into v_t2;
  v_viewer := pg_temp.another_user('viewer.laci@example.com');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_viewer, 'viewer')
  on conflict (org_id, user_id) do update set role = 'viewer';
  insert into public.access_types (org_id, name)
  values (v_org, 'Floor watcher') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'pos', 'read');
  update public.org_members set access_type_id = v_type
   where org_id = v_org and user_id = v_viewer;

  perform pg_temp.sign_in_as(v_viewer);
  perform pg_temp.check_refused('somebody who may only watch may not open a till',
    format($q$ select public.open_pos_shift(%L, 20) $q$, v_t2),
    '%not permitted to open a till%', '42501');
  perform pg_temp.sign_in_as(pg_temp.test_user());
end $$;

-- ---------------------------------------------------------------------
-- 2. What the drawer is expected to hold
-- ---------------------------------------------------------------------
-- Four conditions decide the figure a cashier is measured against, and
-- each has a specific way of accusing somebody. Count card tenders and
-- the drawer is short by every card sale. Forget the change given and
-- it is short by every note handed back. Count a voided sale and it is
-- short by that sale. Read every till on the outlet and one cashier
-- carries another's takings.
do $$
declare
  v_org uuid := pg_temp.dr_org('Wang Dijangka Sdn Bhd');
  v_t1 uuid; v_t2 uuid; v_s1 uuid; v_s2 uuid; v_sale uuid;
begin
  v_t1 := pg_temp.dr_reg(v_org, 'T1');
  v_t2 := pg_temp.dr_reg(v_org, 'T2');
  v_s1 := public.open_pos_shift(v_t1, 100.00);
  v_s2 := public.open_pos_shift(v_t2, 200.00);

  perform pg_temp.check_eq('an untouched till holds its float',
    app.pos_expected_cash(v_s1), 100.00);

  -- RM20 handed over for a RM12.50 coffee. RM12.50 stays in the drawer,
  -- RM7.50 goes back.
  perform pg_temp.dr_cash_sale(v_org, v_t1, 12.50, 20.00);
  perform pg_temp.check_eq(
    'a cash sale adds what was kept, not what was handed over',
    app.pos_expected_cash(v_s1), 112.50);

  -- The other till's takings are the other till's.
  perform pg_temp.dr_cash_sale(v_org, v_t2, 30.00, 30.00);
  perform pg_temp.check_eq('the second till counts only its own',
    app.pos_expected_cash(v_s2), 230.00);
  perform pg_temp.check_eq('and the first is unmoved by it',
    app.pos_expected_cash(v_s1), 112.50);

  -- A card sale is money, and it is not money in the drawer.
  v_sale := public.open_pos_sale(v_t1);
  perform public.add_pos_sale_line(v_sale, pg_temp.dr_item(v_org), 1, 40.00);
  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(jsonb_build_object(
      'type', pg_temp.dr_tender(v_org, 'CARD'), 'amount', 40.00)));
  perform pg_temp.check_eq('a card sale puts nothing in the drawer',
    app.pos_expected_cash(v_s1), 112.50);

  -- `and sa.status = 'completed'` reads like it is keeping voided sales
  -- out of the drawer, and it cannot be doing that: a bill that has
  -- been paid cannot be voided at all. `void_pos_sale` refuses one and
  -- says to raise a credit note instead, so the only sale that can
  -- reach 'voided' is a PARKED one -- and a parked bill has no tenders
  -- to count. The filter is a belt on a state the till cannot produce.
  --
  -- That is the rule, and it is what is asserted rather than the dead
  -- branch. It is worth pinning because it is the reason the expected
  -- figure can be trusted at all: cash in the drawer belongs to a sale
  -- that is finished and stays finished.
  v_sale := pg_temp.dr_cash_sale(v_org, v_t1, 25.00, 25.00);
  perform pg_temp.check_eq('a completed sale is in the figure',
    app.pos_expected_cash(v_s1), 137.50);
  perform pg_temp.check_refused('and a paid bill cannot then be voided',
    format($q$ select public.void_pos_sale(%L, 'wrong_item', 'Rung twice') $q$,
           v_sale),
    '%completed and cannot be voided%');
  perform pg_temp.check_eq('so the figure stands',
    app.pos_expected_cash(v_s1), 137.50);
  -- And the other half of the rule: what CAN be voided has no money
  -- against it in the first place.
  declare v_parked uuid;
  begin
    v_parked := public.open_pos_sale(v_t1);
    perform public.add_pos_sale_line(
      v_parked, pg_temp.dr_item(v_org), 1, 9.00);
    perform pg_temp.check_eq('a bill still on the screen has no tenders',
      (select count(*)::integer from public.pos_tenders
        where sale_id = v_parked), 0);
    perform public.void_pos_sale(v_parked, 'customer_cancelled', 'Walked off');
    perform pg_temp.check_eq('and voiding it moves the drawer by nothing',
      app.pos_expected_cash(v_s1), 137.50);
  end;

  -- A shift that is not there has no expected figure, which is not the
  -- same as expecting nothing. Nought would read as an empty drawer and
  -- make every count an overage.
  perform pg_temp.check_true('a shift that is not there expects nothing at all',
    app.pos_expected_cash(gen_random_uuid()) is null);
end $$;

-- ---------------------------------------------------------------------
-- 3. Closing the drawer, and being told the drawer is wrong
-- ---------------------------------------------------------------------
-- The variance is `declared - expected`: POSITIVE is an overage, money
-- in the drawer nobody rang up; NEGATIVE is a shortfall, money missing.
-- Which way round it reads decides whether a cashier is congratulated
-- or accused, and nothing in the suite had ever produced one that was
-- not nought.
do $$
declare
  v_org uuid := pg_temp.dr_org('Tutup Laci Sdn Bhd');
  v_t1 uuid; v_shift uuid; v_r record;
begin
  v_t1 := pg_temp.dr_reg(v_org, 'T1');
  v_shift := public.open_pos_shift(v_t1, 100.00);
  perform pg_temp.dr_cash_sale(v_org, v_t1, 40.00, 50.00);   -- 10 change

  -- Expected: 100 float + 40 kept = 140.
  -- Counted 137.50: three ringgit fifty missing.
  select * into v_r from public.close_pos_shift(v_shift, 137.50, 'Short');
  perform pg_temp.check_eq('the drawer was expected to hold 140',
    v_r.expected_cash, 140.00);
  perform pg_temp.check_eq('and held 137.50', v_r.declared_cash, 137.50);
  perform pg_temp.check_eq(
    'so the variance is a shortfall, written as a negative',
    v_r.variance, -2.50);
  -- Every one of the three figures is stored, and the stored ones are
  -- the ones returned. A report that read the row and a receipt that
  -- read the return must not disagree.
  perform pg_temp.check_true('all three are recorded on the shift',
    (select expected_cash = 140.00 and declared_cash = 137.50
        and variance = -2.50 and status = 'closed'
       from public.pos_shifts where id = v_shift));
  perform pg_temp.check_eq('and the note the cashier left is kept',
    (select notes from public.pos_shifts where id = v_shift), 'Short');

  -- Closed is closed.
  perform pg_temp.check_refused('a shift cannot be closed twice',
    format($q$ select * from public.close_pos_shift(%L, 137.50) $q$, v_shift),
    '%already closed%', '23514');
  perform pg_temp.check_refused('and a shift that is not there cannot be closed',
    format($q$ select * from public.close_pos_shift(%L, 10) $q$,
           gen_random_uuid()),
    '%No such shift%', 'P0002');
end $$;

-- An overage reads the other way, and a drawer that is exactly right
-- reads nought. Both are needed: a variance computed backwards is
-- invisible when it is always nought, and `abs()` is invisible until
-- something is over rather than under.
do $$
declare
  v_org uuid := pg_temp.dr_org('Lebih Kurang Sdn Bhd');
  v_t1 uuid; v_t2 uuid; v_a uuid; v_b uuid; v_r record;
begin
  v_t1 := pg_temp.dr_reg(v_org, 'T1');
  v_t2 := pg_temp.dr_reg(v_org, 'T2');

  v_a := public.open_pos_shift(v_t1, 50.00);
  perform pg_temp.dr_cash_sale(v_org, v_t1, 20.00, 20.00);
  select * into v_r from public.close_pos_shift(v_a, 75.00);
  perform pg_temp.check_eq('five ringgit too much is an overage, not a shortfall',
    v_r.variance, 5.00);

  v_b := public.open_pos_shift(v_t2, 50.00);
  perform pg_temp.dr_cash_sale(v_org, v_t2, 20.00, 20.00);
  select * into v_r from public.close_pos_shift(v_b, 70.00);
  perform pg_temp.check_eq('and a drawer that is right is out by nothing',
    v_r.variance, 0);
end $$;

-- The count itself. A drawer closed without a figure is a shift with no
-- variance at all, and a negative count is not a count.
do $$
declare
  v_org uuid := pg_temp.dr_org('Kira Dulu Sdn Bhd');
  v_t1 uuid; v_t2 uuid; v_shift uuid; v_r record;
begin
  v_t1 := pg_temp.dr_reg(v_org, 'T1');
  v_t2 := pg_temp.dr_reg(v_org, 'T2');
  v_shift := public.open_pos_shift(v_t1, 100.00);

  perform pg_temp.check_refused('a shift cannot be closed without a figure',
    format($q$ select * from public.close_pos_shift(%L, null) $q$, v_shift),
    '%Count the drawer%', '23514');
  perform pg_temp.check_refused('and the figure cannot be negative',
    format($q$ select * from public.close_pos_shift(%L, -5) $q$, v_shift),
    '%Count the drawer%', '23514');

  -- An empty drawer is a real count. A till that took nothing all
  -- evening and started with no float closes at nought.
  v_shift := public.open_pos_shift(v_t2, 0);
  select * into v_r from public.close_pos_shift(v_shift, 0);
  perform pg_temp.check_eq('but an empty drawer is a count of nothing',
    v_r.variance, 0);
end $$;

-- A sale left parked belongs to THIS till. A check that looked across
-- the whole table would stop one cashier closing because another had a
-- customer mid-order.
do $$
declare
  v_org uuid := pg_temp.dr_org('Tertangguh Sdn Bhd');
  v_t1 uuid; v_t2 uuid; v_a uuid; v_b uuid; v_parked uuid; v_r record;
begin
  v_t1 := pg_temp.dr_reg(v_org, 'T1');
  v_t2 := pg_temp.dr_reg(v_org, 'T2');
  v_a := public.open_pos_shift(v_t1, 50.00);
  v_b := public.open_pos_shift(v_t2, 50.00);

  v_parked := public.open_pos_sale(v_t1);
  perform public.add_pos_sale_line(v_parked, pg_temp.dr_item(v_org), 1, 8.00);

  perform pg_temp.check_refused(
    'a till with a customer still on the screen will not close',
    format($q$ select * from public.close_pos_shift(%L, 50) $q$, v_a),
    '%still parked on this till%', '23514');

  -- The till beside it closes perfectly well, which is the half that
  -- makes the filter load-bearing rather than decorative.
  select * into v_r from public.close_pos_shift(v_b, 50.00);
  perform pg_temp.check_eq('while the till beside it closes normally',
    v_r.variance, 0);

  -- Finish the parked sale and the first till closes too.
  perform public.void_pos_sale(v_parked, 'customer_cancelled', 'Left');
  select * into v_r from public.close_pos_shift(v_a, 50.00);
  perform pg_temp.check_eq('and once it is dealt with, so does the first',
    v_r.variance, 0);
end $$;

-- ---------------------------------------------------------------------
-- 4. Who may close a drawer that is out
-- ---------------------------------------------------------------------
-- `pos_settings.variance_tolerance` is the line between "count it
-- again" and "get the manager". Nothing in the suite had ever set it,
-- so the whole ladder -- the tolerance, its absolute value, the
-- boundary, and the manager who overrides it -- was one branch nobody
-- had walked.
--
-- The shape that matters is a shortfall. `abs(v_variance)` is what
-- makes the rule symmetric, and without it a till RM500 short closes
-- itself while a till RM6 over needs a manager.
do $$
declare
  v_org uuid := pg_temp.dr_org('Toleransi Sdn Bhd');
  v_t1 uuid; v_t2 uuid; v_shift uuid; v_r record;
  v_clerk uuid; v_type uuid;
begin
  v_t1 := pg_temp.dr_reg(v_org, 'T1');
  v_t2 := pg_temp.dr_reg(v_org, 'T2');
  insert into public.pos_settings (org_id, variance_tolerance)
  values (v_org, 5.00)
  on conflict (org_id) do update set variance_tolerance = 5.00;

  -- Somebody who works the till and does not run the shop.
  v_clerk := pg_temp.another_user('clerk.toleransi@example.com');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'sales')
  on conflict (org_id, user_id) do update set role = 'sales';
  insert into public.access_types (org_id, name)
  values (v_org, 'Cashier') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'pos', 'write');
  update public.org_members set access_type_id = v_type
   where org_id = v_org and user_id = v_clerk;

  -- Within tolerance: the cashier closes it themselves.
  v_shift := public.open_pos_shift(v_t1, 100.00);
  perform pg_temp.sign_in_as(v_clerk);
  select * into v_r from public.close_pos_shift(v_shift, 96.00);
  perform pg_temp.check_eq(
    'four ringgit out is inside five, so the cashier closes it', v_r.variance, -4.00);
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- Outside it, and SHORT. This is the one that would be silent without
  -- `abs()`: a shortfall is a negative, and a bare `> tolerance` never
  -- fires on a negative however large.
  v_shift := public.open_pos_shift(v_t2, 100.00);
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_refused(
    'but a drawer twenty ringgit short needs a manager',
    format($q$ select * from public.close_pos_shift(%L, 80.00) $q$, v_shift),
    '%Only a manager can close a shift more than%', '42501');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- The manager can. Same shift, same figure, different person.
  select * into v_r from public.close_pos_shift(v_shift, 80.00);
  perform pg_temp.check_eq('and a manager may close exactly that drawer',
    v_r.variance, -20.00);
end $$;

-- The boundary, and the overage side. Exactly on the tolerance is
-- INSIDE it -- `> tolerance`, not `>=` -- because a shop that sets five
-- ringgit means five ringgit is acceptable.
do $$
declare
  v_org uuid := pg_temp.dr_org('Sempadan Sdn Bhd');
  v_t1 uuid; v_t2 uuid; v_shift uuid; v_r record;
  v_clerk uuid; v_type uuid;
begin
  v_t1 := pg_temp.dr_reg(v_org, 'T1');
  v_t2 := pg_temp.dr_reg(v_org, 'T2');
  insert into public.pos_settings (org_id, variance_tolerance)
  values (v_org, 5.00)
  on conflict (org_id) do update set variance_tolerance = 5.00;

  v_clerk := pg_temp.another_user('clerk.sempadan@example.com');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'sales')
  on conflict (org_id, user_id) do update set role = 'sales';
  insert into public.access_types (org_id, name)
  values (v_org, 'Cashier') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'pos', 'write');
  update public.org_members set access_type_id = v_type
   where org_id = v_org and user_id = v_clerk;

  v_shift := public.open_pos_shift(v_t1, 100.00);
  perform pg_temp.sign_in_as(v_clerk);
  select * into v_r from public.close_pos_shift(v_shift, 95.00);
  perform pg_temp.check_eq('exactly on the tolerance is within it',
    v_r.variance, -5.00);

  -- And over the top the same distance is refused, which is the other
  -- half of `abs`.
  v_shift := public.open_pos_shift(v_t2, 100.00);
  perform pg_temp.check_refused(
    'while six ringgit OVER needs a manager just as six short would',
    format($q$ select * from public.close_pos_shift(%L, 106.00) $q$, v_shift),
    '%Only a manager can close a shift more than%', '42501');
  perform pg_temp.sign_in_as(pg_temp.test_user());
end $$;

-- A shop that has set no tolerance has not asked for the check. Every
-- drawer closes, whatever it is out by -- which is the default, and
-- has to stay the default or the first shop to install this cannot
-- close a till at all.
do $$
declare
  v_org uuid := pg_temp.dr_org('Tiada Had Sdn Bhd');
  v_t1 uuid; v_shift uuid; v_r record; v_clerk uuid; v_type uuid;
begin
  v_t1 := pg_temp.dr_reg(v_org, 'T1');
  perform pg_temp.check_true('this shop has set no tolerance',
    not exists (select 1 from public.pos_settings
                 where org_id = v_org and variance_tolerance is not null));

  v_clerk := pg_temp.another_user('clerk.tiadahad@example.com');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'sales')
  on conflict (org_id, user_id) do update set role = 'sales';
  insert into public.access_types (org_id, name)
  values (v_org, 'Cashier') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'pos', 'write');
  update public.org_members set access_type_id = v_type
   where org_id = v_org and user_id = v_clerk;

  v_shift := public.open_pos_shift(v_t1, 100.00);
  perform pg_temp.sign_in_as(v_clerk);
  select * into v_r from public.close_pos_shift(v_shift, 30.00);
  perform pg_temp.check_eq(
    'so a drawer seventy ringgit short still closes', v_r.variance, -70.00);
  perform pg_temp.sign_in_as(pg_temp.test_user());
end $$;

-- And the tolerance is THIS shop's. Read from any row, a strict shop
-- next door would start refusing closes here.
do $$
declare
  v_a uuid := pg_temp.dr_org('Ketat Sdn Bhd');
  v_b uuid := pg_temp.dr_org('Longgar Sdn Bhd');
  v_t uuid; v_shift uuid; v_r record; v_clerk uuid; v_type uuid;
begin
  perform pg_temp.allow_many_companies();
  insert into public.pos_settings (org_id, variance_tolerance)
  values (v_a, 0.50) on conflict (org_id) do update set variance_tolerance = 0.50;
  insert into public.pos_settings (org_id, variance_tolerance)
  values (v_b, 100.00) on conflict (org_id) do update set variance_tolerance = 100.00;

  v_clerk := pg_temp.another_user('clerk.longgar@example.com');
  insert into public.org_members (org_id, user_id, role)
  values (v_b, v_clerk, 'sales')
  on conflict (org_id, user_id) do update set role = 'sales';
  insert into public.access_types (org_id, name)
  values (v_b, 'Cashier') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'pos', 'write');
  update public.org_members set access_type_id = v_type
   where org_id = v_b and user_id = v_clerk;

  v_t := pg_temp.dr_reg(v_b, 'T1');
  v_shift := public.open_pos_shift(v_t, 100.00);
  perform pg_temp.sign_in_as(v_clerk);
  select * into v_r from public.close_pos_shift(v_shift, 80.00);
  perform pg_temp.check_eq(
    'a lenient shop is not held to its strict neighbour''s tolerance',
    v_r.variance, -20.00);
  perform pg_temp.sign_in_as(pg_temp.test_user());
end $$;

-- ---------------------------------------------------------------------
-- 5. One shift closes, and only that one
-- ---------------------------------------------------------------------
-- Two tills open at once is the ordinary shape of a shop, and it is
-- what tells `where s.id = p_shift` from `where s.org_id = v_org`. The
-- second closes both drawers on one count, and the till still selling
-- is recorded as counted and reconciled.
do $$
declare
  v_org uuid := pg_temp.dr_org('Dua Laci Sdn Bhd');
  v_t1 uuid; v_t2 uuid; v_a uuid; v_b uuid; v_r record;
begin
  v_t1 := pg_temp.dr_reg(v_org, 'T1');
  v_t2 := pg_temp.dr_reg(v_org, 'T2');
  v_a := public.open_pos_shift(v_t1, 100.00);
  v_b := public.open_pos_shift(v_t2, 60.00);

  select * into v_r from public.close_pos_shift(v_a, 100.00);
  perform pg_temp.check_eq('the first till closes', v_r.expected_cash, 100.00);
  perform pg_temp.check_true('and the second is still open, still uncounted',
    (select status = 'open' and closed_at is null and declared_cash is null
       from public.pos_shifts where id = v_b));
  -- Which is the point: it can still be closed on its own figures.
  select * into v_r from public.close_pos_shift(v_b, 60.00);
  perform pg_temp.check_eq('on its own float, when its own cashier counts it',
    v_r.expected_cash, 60.00);
end $$;

-- Closing a till is a write, and somebody who may only watch the floor
-- may not do it. `open_pos_shift` has the same check and the two are
-- separate lines in separate functions.
do $$
declare
  v_org uuid := pg_temp.dr_org('Tutup Izin Sdn Bhd');
  v_t1 uuid; v_shift uuid; v_watcher uuid; v_type uuid; v_r record;
begin
  v_t1 := pg_temp.dr_reg(v_org, 'T1');
  v_shift := public.open_pos_shift(v_t1, 40.00);

  v_watcher := pg_temp.another_user('watcher.tutup@example.com');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_watcher, 'viewer')
  on conflict (org_id, user_id) do update set role = 'viewer';
  insert into public.access_types (org_id, name)
  values (v_org, 'Floor watcher') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'pos', 'read');
  update public.org_members set access_type_id = v_type
   where org_id = v_org and user_id = v_watcher;

  perform pg_temp.sign_in_as(v_watcher);
  perform pg_temp.check_refused('somebody who may only watch may not close a till',
    format($q$ select * from public.close_pos_shift(%L, 40) $q$, v_shift),
    '%not permitted to close a till%', '42501');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- A note put on the shift when it opened is not thrown away by a
  -- close that carries none. The cashier's "float short, borrowed from
  -- petty cash" written at eight in the morning is the context for the
  -- variance at ten at night.
  update public.pos_shifts set notes = 'Opened with a borrowed float'
   where id = v_shift;
  select * into v_r from public.close_pos_shift(v_shift, 40.00);
  perform pg_temp.check_eq('and closing without a note keeps the note already there',
    (select notes from public.pos_shifts where id = v_shift),
    'Opened with a borrowed float');
end $$;

-- ---------------------------------------------------------------------
-- Putting a till back into service
-- ---------------------------------------------------------------------
-- `resume_pos_shift` exists so a till that was put into `counting` can
-- go back to selling -- a manager was called away mid-count. Nothing in
-- the suite reached its permission check or the scope of its update,
-- and the second is the one that matters: scoped to the company it
-- would reopen every closed shift in the shop, undoing every count of
-- the day.
do $$
declare
  v_org uuid := pg_temp.dr_org('Sambung Semula Sdn Bhd');
  v_t1 uuid; v_t2 uuid; v_a uuid; v_b uuid;
  v_watcher uuid; v_type uuid;
begin
  v_t1 := pg_temp.dr_reg(v_org, 'T1');
  v_t2 := pg_temp.dr_reg(v_org, 'T2');
  v_a := public.open_pos_shift(v_t1, 30.00);
  v_b := public.open_pos_shift(v_t2, 30.00);

  -- The second till is counted and closed for the day.
  perform public.close_pos_shift(v_b, 30.00);

  -- The first is mid-count and goes back into service.
  update public.pos_shifts set status = 'counting' where id = v_a;
  perform public.resume_pos_shift(v_a);
  perform pg_temp.check_true('a till being counted can be put back into service',
    (select status = 'open' from public.pos_shifts where id = v_a));
  -- And the one that was closed for the day stays closed.
  perform pg_temp.check_true('while the one closed for the day stays closed',
    (select status = 'closed' from public.pos_shifts where id = v_b));
  perform pg_temp.check_refused('and cannot be reopened',
    format($q$ select public.resume_pos_shift(%L) $q$, v_b),
    '%Open a new one to keep selling%', '23514');

  v_watcher := pg_temp.another_user('watcher.sambung@example.com');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_watcher, 'viewer')
  on conflict (org_id, user_id) do update set role = 'viewer';
  insert into public.access_types (org_id, name)
  values (v_org, 'Floor watcher') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'pos', 'read');
  update public.org_members set access_type_id = v_type
   where org_id = v_org and user_id = v_watcher;

  update public.pos_shifts set status = 'counting' where id = v_a;
  perform pg_temp.sign_in_as(v_watcher);
  perform pg_temp.check_refused('somebody who may only watch may not reopen a till',
    format($q$ select public.resume_pos_shift(%L) $q$, v_a),
    '%not permitted to reopen this till%', '42501');
  perform pg_temp.sign_in_as(pg_temp.test_user());
end $$;

-- ---------------------------------------------------------------------
-- 6. Points that go stale
-- ---------------------------------------------------------------------
-- `expire_loyalty_points` walks dormant accounts and writes off what is
-- left. `pos_loyalty.sql` proves an admin may run it and a viewer may
-- not, and that the entry it writes is negative. What it never varies
-- is the DORMANCY: one programme, one window, and every account in the
-- file either expires or does not for the same reason.
do $$
declare
  v_org uuid := pg_temp.dr_org('Mata Lupus Sdn Bhd');
  v_prog uuid; v_old uuid; v_recent uuid; v_edge uuid; v_empty uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid; v_n integer;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'M1', 'Ahmad', 'customer'),
         (v_org, 'M2', 'Bala', 'customer'),
         (v_org, 'M3', 'Chong', 'customer'),
         (v_org, 'M4', 'Devi', 'customer');
  select id into v_c1 from public.contacts where org_id = v_org and code = 'M1';
  select id into v_c2 from public.contacts where org_id = v_org and code = 'M2';
  select id into v_c3 from public.contacts where org_id = v_org and code = 'M3';
  select id into v_c4 from public.contacts where org_id = v_org and code = 'M4';

  -- Twelve months of inactivity ends a card.
  insert into public.loyalty_programs
    (org_id, code, name, earn_points_per_myr, redeem_value_per_point,
     min_redeem_points, is_active, dormancy_expiry_months)
  values (v_org, 'KAD', 'Kad Kedai', 1, 0.01, 100, true, 12)
  returning id into v_prog;

  -- Dormant: joined two years ago, earned once eighteen months ago.
  insert into public.loyalty_accounts (org_id, program_id, contact_id, joined_on)
  values (v_org, v_prog, v_c1, (current_date - 730))
  returning id into v_old;
  insert into public.loyalty_entries
    (org_id, account_id, kind, points, note, created_at)
  values (v_org, v_old, 'earn', 500, 'Shopping', now() - interval '18 months');

  -- Active: joined two years ago and earned LAST MONTH. Dormancy is
  -- measured from the last thing that happened, not from joining --
  -- otherwise every long-standing customer is wiped out.
  insert into public.loyalty_accounts (org_id, program_id, contact_id, joined_on)
  values (v_org, v_prog, v_c2, (current_date - 730))
  returning id into v_recent;
  insert into public.loyalty_entries
    (org_id, account_id, kind, points, note, created_at)
  values (v_org, v_recent, 'earn', 300, 'Shopping', now() - interval '1 month');

  -- Joined eighteen months ago and NEVER earned anything. Measured from
  -- entries alone this account has no date at all and is skipped; the
  -- joining date is the fallback that catches it.
  insert into public.loyalty_accounts (org_id, program_id, contact_id, joined_on)
  values (v_org, v_prog, v_c3, (current_date - 540))
  returning id into v_edge;
  insert into public.loyalty_entries
    (org_id, account_id, kind, points, note, created_at)
  values (v_org, v_edge, 'adjust', 40, 'Goodwill', now() - interval '20 months');

  -- Dormant but with nothing left to expire. It must not get an entry
  -- of nought, which would reset its own dormancy for ever after.
  insert into public.loyalty_accounts (org_id, program_id, contact_id, joined_on)
  values (v_org, v_prog, v_c4, (current_date - 730))
  returning id into v_empty;

  select count(*)::integer into v_n from public.expire_loyalty_points(v_org);
  perform pg_temp.check_eq('three cards are dormant and one is not', v_n, 2);

  perform pg_temp.check_eq('the long-dormant card is written off',
    app.loyalty_balance(v_old), 0);
  perform pg_temp.check_eq('and the one that shopped last month is untouched',
    app.loyalty_balance(v_recent), 300);
  perform pg_temp.check_eq('the card whose only entry is old goes too',
    app.loyalty_balance(v_edge), 0);
  perform pg_temp.check_eq('and an empty card is left without an entry',
    (select count(*)::integer from public.loyalty_entries
      where account_id = v_empty), 0);

  -- The window is the programme's own number, not a constant.
  perform pg_temp.check_eq('the window is the twelve months the shop set',
    (select dormancy_expiry_months from public.loyalty_programs where id = v_prog),
    12);
end $$;

-- A programme with no dormancy rule expires nothing, and a programme
-- switched off expires nothing either. Both are the difference between
-- "we do not do this" and "wipe every card in the shop".
do $$
declare
  v_org uuid := pg_temp.dr_org('Tiada Lupus Sdn Bhd');
  v_prog uuid; v_acc uuid; v_c uuid; v_n integer;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'M1', 'Ahmad', 'customer') returning id into v_c;

  insert into public.loyalty_programs
    (org_id, code, name, earn_points_per_myr, redeem_value_per_point,
     min_redeem_points, is_active, dormancy_expiry_months)
  values (v_org, 'KAD', 'Kad Selamanya', 1, 0.01, 100, true, null)
  returning id into v_prog;
  insert into public.loyalty_accounts (org_id, program_id, contact_id, joined_on)
  values (v_org, v_prog, v_c, (current_date - 2000))
  returning id into v_acc;
  insert into public.loyalty_entries
    (org_id, account_id, kind, points, note, created_at)
  values (v_org, v_acc, 'earn', 900, 'Shopping', now() - interval '5 years');

  select count(*)::integer into v_n from public.expire_loyalty_points(v_org);
  perform pg_temp.check_eq('a programme with no dormancy rule expires nothing',
    v_n, 0);
  perform pg_temp.check_eq('and five years of dormancy keeps its points',
    app.loyalty_balance(v_acc), 900);

  -- Now give it a rule and switch the programme off. A shop that has
  -- retired its card scheme has not asked for the cards to be emptied.
  update public.loyalty_programs
     set dormancy_expiry_months = 12, is_active = false where id = v_prog;
  select count(*)::integer into v_n from public.expire_loyalty_points(v_org);
  perform pg_temp.check_eq('and a retired programme expires nothing either',
    v_n, 0);
  perform pg_temp.check_eq('its members keep what they earned',
    app.loyalty_balance(v_acc), 900);
end $$;

-- A shop that never bought the loyalty module gets nothing back, and is
-- NOT refused: the function returns quietly, because a scheduler that
-- walks every company must not raise on the ones that do not use it.
do $$
declare
  v_org uuid := pg_temp.dr_org('Tanpa Kad Sdn Bhd');
  v_prog uuid; v_acc uuid; v_c uuid; v_n integer;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'M1', 'Ahmad', 'customer') returning id into v_c;
  insert into public.loyalty_programs
    (org_id, code, name, earn_points_per_myr, redeem_value_per_point,
     min_redeem_points, is_active, dormancy_expiry_months)
  values (v_org, 'KAD', 'Kad Kedai', 1, 0.01, 100, true, 12)
  returning id into v_prog;
  insert into public.loyalty_accounts (org_id, program_id, contact_id, joined_on)
  values (v_org, v_prog, v_c, (current_date - 730))
  returning id into v_acc;
  insert into public.loyalty_entries
    (org_id, account_id, kind, points, note, created_at)
  values (v_org, v_acc, 'earn', 700, 'Shopping', now() - interval '2 years');

  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'loyalty';

  select count(*)::integer into v_n from public.expire_loyalty_points(v_org);
  perform pg_temp.check_eq(
    'a shop without the module expires nothing, and is not refused', v_n, 0);
  perform pg_temp.check_eq('its cards keep their points',
    app.loyalty_balance(v_acc), 700);

  -- Switched back on, the same call empties it. Which is what makes the
  -- silence above a decision rather than a coincidence.
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'loyalty';
  select count(*)::integer into v_n from public.expire_loyalty_points(v_org);
  perform pg_temp.check_eq('and with the module on, the card expires', v_n, 1);
end $$;

-- The window is read from the programme. Six months of dormancy is
-- inside a twelve-month rule and outside a three-month one, which is
-- the pair of dates that tells a column from a constant.
do $$
declare
  v_org uuid := pg_temp.dr_org('Tingkap Sdn Bhd');
  v_prog uuid; v_six uuid; v_c uuid; v_n integer;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'M1', 'Ahmad', 'customer') returning id into v_c;
  insert into public.loyalty_programs
    (org_id, code, name, earn_points_per_myr, redeem_value_per_point,
     min_redeem_points, is_active, dormancy_expiry_months)
  values (v_org, 'KAD', 'Kad Dua Belas Bulan', 1, 0.01, 100, true, 12)
  returning id into v_prog;
  insert into public.loyalty_accounts (org_id, program_id, contact_id, joined_on)
  values (v_org, v_prog, v_c, (current_date - 900))
  returning id into v_six;
  insert into public.loyalty_entries
    (org_id, account_id, kind, points, note, created_at)
  values (v_org, v_six, 'earn', 250, 'Shopping', now() - interval '6 months');

  select count(*)::integer into v_n from public.expire_loyalty_points(v_org);
  perform pg_temp.check_eq(
    'six months idle is not dormant under a twelve-month rule', v_n, 0);
  perform pg_temp.check_eq('and the points stand',
    app.loyalty_balance(v_six), 250);

  update public.loyalty_programs set dormancy_expiry_months = 3
   where id = v_prog;
  select count(*)::integer into v_n from public.expire_loyalty_points(v_org);
  perform pg_temp.check_eq('but it is dormant under a three-month one', v_n, 1);
  perform pg_temp.check_eq('and the card is emptied',
    app.loyalty_balance(v_six), 0);
end $$;

-- What the run REPORTS is read by whoever has to answer a customer
-- asking where their points went, so the date it names has to be the
-- last thing that happened on the card -- not the day they joined.
do $$
declare
  v_org uuid := pg_temp.dr_org('Lapor Sdn Bhd');
  v_prog uuid; v_acc uuid; v_c uuid; v_r record;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'M1', 'Ahmad', 'customer') returning id into v_c;
  insert into public.loyalty_programs
    (org_id, code, name, earn_points_per_myr, redeem_value_per_point,
     min_redeem_points, is_active, dormancy_expiry_months)
  values (v_org, 'KAD', 'Kad Kedai', 1, 0.01, 100, true, 12)
  returning id into v_prog;
  -- Joined four years ago, last shopped eighteen months ago. The two
  -- dates are far apart on purpose.
  insert into public.loyalty_accounts (org_id, program_id, contact_id, joined_on)
  values (v_org, v_prog, v_c, (current_date - 1460))
  returning id into v_acc;
  insert into public.loyalty_entries
    (org_id, account_id, kind, points, note, created_at)
  values (v_org, v_acc, 'earn', 400, 'Shopping', now() - interval '18 months');

  select * into v_r from public.expire_loyalty_points(v_org);
  perform pg_temp.check_eq('the run names the customer', v_r.contact, 'Ahmad');
  perform pg_temp.check_eq('and the points it took', v_r.points, 400);
  perform pg_temp.check_true(
    'and dates it from the last thing they did, not the day they joined',
    v_r.last_activity > now() - interval '19 months'
      and v_r.last_activity < now() - interval '17 months');
end $$;

-- =====================================================================
-- The survivors that are equivalent, and the rules they lean on
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.dr_org('Setara Laci Sdn Bhd');
  v_prog uuid; v_acc uuid; v_c uuid; v_n integer;
begin
  -- (a) `round(p_declared - v_expected, 2)` and `round(v_float + v_cash, 2)`
  -- each have a column with a scale under them. Nothing observable
  -- moves if either round is deleted, because money is kept to the sen
  -- in the columns as well as in the arithmetic. Third time this
  -- campaign has met it, after the withholding tax and the group
  -- payment; the rule is what is asserted.
  perform pg_temp.check_eq('a variance is kept to the sen',
    (select numeric_scale::integer from information_schema.columns
      where table_schema = 'public' and table_name = 'pos_shifts'
        and column_name = 'variance'), 2);
  perform pg_temp.check_eq('and so is the figure counted',
    (select numeric_scale::integer from information_schema.columns
      where table_schema = 'public' and table_name = 'pos_shifts'
        and column_name = 'declared_cash'), 2);
  perform pg_temp.check_eq('and the figure expected',
    (select numeric_scale::integer from information_schema.columns
      where table_schema = 'public' and table_name = 'pos_shifts'
        and column_name = 'expected_cash'), 2);

  -- (b) `coalesce(max(e.created_at), a.joined_on)` in the HAVING has a
  -- fallback that cannot change an answer, and the reason is one line
  -- further down. An account with NO entries reaches the fallback --
  -- and its balance is the sum of its entries, so it is nought, and
  -- `if v_balance <= 0 then continue` skips it. Every account the
  -- fallback uniquely admits has nothing to expire.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'M1', 'Ahmad', 'customer') returning id into v_c;
  insert into public.loyalty_programs
    (org_id, code, name, earn_points_per_myr, redeem_value_per_point,
     min_redeem_points, is_active, dormancy_expiry_months)
  values (v_org, 'KAD', 'Kad Kedai', 1, 0.01, 100, true, 12)
  returning id into v_prog;
  insert into public.loyalty_accounts (org_id, program_id, contact_id, joined_on)
  values (v_org, v_prog, v_c, (current_date - 900))
  returning id into v_acc;
  perform pg_temp.check_eq(
    'a card with no entries has no points, whenever it was opened',
    app.loyalty_balance(v_acc), 0);
  select count(*)::integer into v_n from public.expire_loyalty_points(v_org);
  perform pg_temp.check_eq('so a dormant empty card is passed over', v_n, 0);
  perform pg_temp.check_eq('without an entry of nought being written',
    (select count(*)::integer from public.loyalty_entries
      where account_id = v_acc), 0);

  -- (c) A programme with no dormancy months set returns early, and
  -- would return nothing anyway: `make_interval(months => null)` is
  -- null, and `last_at < now() - null` is null, which no row satisfies.
  -- The early return is the sentence, not the control -- the same
  -- reasoning `resume_pos_shift` already carries in its own comment.
  perform pg_temp.check_true('an unbounded window excludes every row',
    (now() - make_interval(months => null::integer)) is null);

  -- (d) `<` rather than `<=` on the dormancy boundary needs a card whose
  -- last activity is the same MICROSECOND as the cutoff. That is a
  -- coincidence rather than a case somebody can be in, and no fixture
  -- can produce it reliably.
  raise notice 'the dormancy boundary is exclusive; equality is unreachable';
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('opening a till is closed to anon',
    not has_function_privilege('anon',
      'public.open_pos_shift(uuid, numeric, text)', 'execute'));
  perform pg_temp.check_true('and closing one',
    not has_function_privilege('anon',
      'public.close_pos_shift(uuid, numeric, text)', 'execute'));
  perform pg_temp.check_true('and the expected figure is not a client surface',
    not has_function_privilege('anon',
      'app.pos_expected_cash(uuid)', 'execute'));
  perform pg_temp.check_true('and expiring points',
    not has_function_privilege('anon',
      'public.expire_loyalty_points(uuid)', 'execute'));
end $$;

rollback;
