-- =====================================================================
-- iAkauntan :: the drawer's tolerance is the manager's (0868)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/drawer_tolerance.sql
--
-- `close_pos_shift` lets only a manager close a shift further out than
-- `pos_settings.variance_tolerance`, and the cashier whose drawer it
-- judges could raise it, clear it or delete it. Anybody the till admits
-- may still tighten it; loosening is a manager's. Asked with the role
-- `authenticated`, as the till asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- The till from `cash_is_not_credit.sql`, its shift opened on a float of
-- 100.00.
create or replace function pg_temp.till_shop(p_name text)
returns uuid language plpgsql as $$
declare
  v_org uuid := pg_temp.test_org(p_name);
  v_wh  uuid;
  v_c   uuid;
  v_o   uuid;
begin
  perform public.create_fiscal_year(
    v_org, date_trunc('year', pg_temp.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos', 'accounting', 'inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'W', 'Store', true) returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type,
                               credit_limit, credit_hold)
  values (v_org, 'REG', 'Encik Zaid', 'customer', 500, false)
  returning id into v_c;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'KOPI', 'Kopi', 'service', false, 'C62', 5.00);

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'K', 'Kedai', 'retail', v_wh, v_c, false)
  returning id into v_o;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_o, 'C1', 'Counter');
  insert into public.pos_settings (org_id, round_cash_to_5sen)
  values (v_org, false);
  perform pg_temp.a_till(v_org);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change, opens_drawer)
  values (v_org, 'TUNAI', 'Tunai', 'cash', '01', true, true, true),
         (v_org, 'AKAUN', 'Akaun', 'on_account', null, false, false, false);
  perform public.open_pos_shift(
    (select id from public.pos_registers where org_id = v_org), 100.00);
  return v_org;
end $$;

create temporary table t_dt (org uuid, cashier uuid, accountant uuid,
  manager uuid, shift uuid);
grant select on t_dt to authenticated;

do $$
declare r t_dt;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.till_shop('Kedai Laci Sdn Bhd');
  update public.pos_settings set variance_tolerance = 5 where org_id = r.org;
  select id into r.shift from public.pos_shifts where org_id = r.org and status = 'open';
  r.cashier    := pg_temp.another_user('juruwang@kedailaci.test');
  r.accountant := pg_temp.another_user('akauntan@kedailaci.test');
  r.manager    := pg_temp.another_user('pengurus@kedailaci.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.cashier, 'sales', 'active'),
         (r.org, r.accountant, 'accountant', 'active'),
         (r.org, r.manager, 'admin', 'active');
  insert into t_dt select r.*;
end $$;

-- ---------------------------------------------------------------------
-- The cashier: tightens, loosens nothing, and so cannot close short
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select cashier from t_dt));
set local role authenticated;

do $$
declare d t_dt;
  v_msg constant text := 'Only a manager can raise the drawer''s tolerance or take it away%';
begin
  select * into d from t_dt;
  perform pg_temp.check_true('the premise: the cashier works the till and is not a manager',
    app.can_write_module(d.org, 'pos') and not app.can_admin(d.org));
  perform pg_temp.check_refused('the cashier cannot raise the tolerance',
    'update public.pos_settings set variance_tolerance = 100', v_msg, '42501');
  perform pg_temp.check_refused('nor clear it',
    'update public.pos_settings set variance_tolerance = null', v_msg, '42501');
  perform pg_temp.check_refused('nor delete the row that holds it',
    'delete from public.pos_settings', v_msg, '42501');
  perform pg_temp.check_refused('so a shift 50.00 short is still a manager''s to close',
    format('select public.close_pos_shift(%L, 50)', d.shift),
    'The drawer is out by -50.00. Only a manager can close a shift more than 5.00 out.');

  update public.pos_settings set variance_tolerance = 2, round_cash_to_5sen = true;
  perform pg_temp.check_eq('he lowers it, and changes another setting with it left as it is',
    (select variance_tolerance || ' / ' || round_cash_to_5sen from public.pos_settings),
    '2.00 / true');
  update public.pos_settings set park_expiry_hours = 6;
  perform pg_temp.check_eq('and changes a setting without naming it',
    (select variance_tolerance || ' / ' || park_expiry_hours from public.pos_settings),
    '2.00 / 6');
end $$;

reset role;

-- The accountant posts and is not a manager: the test is the manager's.
select pg_temp.sign_in_as((select accountant from t_dt));
set local role authenticated;

do $$
begin
  perform pg_temp.check_refused('an accountant cannot raise it either',
    'update public.pos_settings set variance_tolerance = 100',
    'Only a manager can raise the drawer''s tolerance or take it away%', '42501');
end $$;

reset role;

-- ---------------------------------------------------------------------
-- The manager loosens it; the cashier tightens it again from none
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select manager from t_dt));
set local role authenticated;
update public.pos_settings set variance_tolerance = null;
reset role;

select pg_temp.sign_in_as((select cashier from t_dt));
set local role authenticated;

do $$
declare d t_dt;
begin
  select * into d from t_dt;
  -- With no tolerance there is nothing to loosen: the cashier changes
  -- another setting, and even deletes the row, and puts one back.
  update public.pos_settings set park_expiry_hours = 8;
  perform pg_temp.check_eq('with none, the cashier changes another setting',
    (select coalesce(variance_tolerance::text, 'none') || ' / ' || park_expiry_hours
       from public.pos_settings), 'none / 8');
  delete from public.pos_settings;
  perform pg_temp.check_eq('and deletes a row that holds no tolerance',
    (select count(*)::int from public.pos_settings), 0);
  insert into public.pos_settings (org_id) values (d.org);
  update public.pos_settings set variance_tolerance = 4;
end $$;

reset role;

select pg_temp.sign_in_as((select manager from t_dt));
set local role authenticated;

do $$
begin
  perform pg_temp.check_eq('the manager cleared it and the cashier set one where there was none',
    (select variance_tolerance::text from public.pos_settings), '4.00');
  update public.pos_settings set variance_tolerance = 100;
  perform pg_temp.check_eq('and the manager raises it',
    (select variance_tolerance::text from public.pos_settings), '100.00');
end $$;

reset role;

select pg_temp.sign_in_as((select cashier from t_dt));
set local role authenticated;

do $$
declare d t_dt;
begin
  select * into d from t_dt;
  perform public.close_pos_shift(d.shift, 50);
  perform pg_temp.check_eq('so the cashier closes the shift 50.00 short, within it',
    (select status || ' / ' || variance from public.pos_shifts where id = d.shift),
    'closed / -50.00');
end $$;

reset role;

select pg_temp.sign_in_as((select manager from t_dt));
set local role authenticated;
delete from public.pos_settings;
reset role;

select pg_temp.sign_in_as((select cashier from t_dt));
set local role authenticated;

do $$
declare d t_dt;
begin
  select * into d from t_dt;
  insert into public.pos_settings (org_id, variance_tolerance) values (d.org, 3);
  perform pg_temp.check_eq('the manager deleted the row, and the cashier made one with a tolerance',
    (select count(*) || ' / ' || max(variance_tolerance) from public.pos_settings), '1 / 3.00');
end $$;

reset role;

rollback;
