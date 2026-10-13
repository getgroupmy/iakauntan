-- =====================================================================
-- iAkauntan :: credit is loosened by whoever answers for it (0867)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/credit_terms_loosened.sql
--
-- A customer's credit hold and limit were written by any member who may
-- write, so the cashier a hold is there to stop could take it off and
-- sell on account. Anybody may still tighten them; loosening is for a
-- member who may post. Asked with the role `authenticated`, as the app
-- and the till ask.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- The till from `cash_is_not_credit.sql`: a customer on a 500 limit, a
-- cash tender and one on account.
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

create or replace function pg_temp.till_sell(
  p_org uuid, p_tender text, p_amount numeric)
returns text language plpgsql as $$
declare
  v_sale uuid;
  v_msg  text;
begin
  -- The customer is named on the sale. A sale on account has to be —
  -- `complete_pos_sale` refuses one that is not, which is right and is
  -- not what this file is about.
  v_sale := public.open_pos_sale(
    (select id from public.pos_registers where org_id = p_org),
    (select id from public.contacts where org_id = p_org and code = 'REG'));
  perform public.add_pos_sale_line(v_sale,
    (select id from public.items where org_id = p_org and code = 'KOPI'),
    1, p_amount);
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object(
      'type', (select id from public.pos_tender_types
                where org_id = p_org and code = p_tender),
      'amount', p_amount)));
  return 'ok';
exception when others then
  get stacked diagnostics v_msg = message_text;
  return v_msg;
end $$;


-- Two tenders on one basket: most of it in the drawer, a little on the
-- tab. This is the shape that tells the two readings of the rule apart

create temporary table t_cl (org uuid, cashier uuid, clerk uuid,
  accountant uuid, reg uuid, other uuid);
grant select on t_cl to authenticated;
grant execute on all functions in schema pg_temp to authenticated;

do $$
declare r t_cl;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.till_shop('Kedai Kredit Sdn Bhd');
  select id into r.reg from public.contacts where org_id = r.org and code = 'REG';
  update public.contacts set credit_hold = true where id = r.reg;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'LAIN', 'Puan Lina', 'customer') returning id into r.other;
  r.cashier    := pg_temp.another_user('juruwang@kedaikredit.test');
  r.clerk      := pg_temp.another_user('kerani@kedaikredit.test');
  r.accountant := pg_temp.another_user('akauntan@kedaikredit.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.cashier, 'sales', 'active'),
         (r.org, r.clerk, 'accounts_clerk', 'active'),
         (r.org, r.accountant, 'accountant', 'active');
  insert into t_cl select r.*;
end $$;

-- ---------------------------------------------------------------------
-- The cashier: tightens, and loosens nothing
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select cashier from t_cl));
set local role authenticated;

do $$
declare d t_cl;
  v_msg constant text := 'Only the owner, an admin or an accountant can take % off hold%';
begin
  select * into d from t_cl;
  perform pg_temp.check_true('the premise: the cashier writes and sells at the till, and does not post',
    app.can_write(d.org) and app.can_write_module(d.org, 'pos')
    and not app.can_post(d.org));
  perform pg_temp.check_refused('the cashier cannot take the customer off hold',
    format('update public.contacts set credit_hold = false where id = %L', d.reg),
    v_msg, '42501');
  perform pg_temp.check_eq('so the sale on account is still refused',
    pg_temp.till_sell(d.org, 'AKAUN', 20),
    'Encik Zaid is on credit hold, so INV-' || extract(year from pg_temp.today())
      || '-00001 cannot be posted. Take the hold off, or raise this as a cash sale.');
  perform pg_temp.check_refused('nor raise the limit',
    format('update public.contacts set credit_limit = 1000000 where id = %L', d.reg),
    v_msg, '42501');
  perform pg_temp.check_refused('nor take it away as nought',
    format('update public.contacts set credit_limit = 0 where id = %L', d.reg),
    v_msg, '42501');

  -- What the cashier may still do.
  update public.contacts set credit_limit = 300 where id = d.reg;
  -- A limit where there was none, the hold left off as it was; then the
  -- hold put on.
  update public.contacts set credit_hold = false, credit_limit = 1000 where id = d.other;
  update public.contacts set credit_hold = true where id = d.other;
  -- The editor sends every field on every save, unchanged or not.
  update public.contacts set name = 'Encik Zaid bin Omar', credit_hold = true,
                             credit_limit = 300 where id = d.reg;
  perform pg_temp.check_eq('lowers a limit, puts somebody on hold with a limit where there was none, and edits the rest',
    (select string_agg(code || ' ' || name || ' ' || credit_hold || ' ' || credit_limit,
                       ', ' order by code)
       from public.contacts where id in (d.reg, d.other)),
    'LAIN Puan Lina true 1000.00, REG Encik Zaid bin Omar true 300.00');
end $$;

reset role;

-- ---------------------------------------------------------------------
-- The clerk reads the ledger and writes, and posts nothing
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select clerk from t_cl));
set local role authenticated;

do $$
declare d t_cl;
begin
  select * into d from t_cl;
  perform pg_temp.check_refused('the clerk cannot take a hold off either',
    format('update public.contacts set credit_hold = false where id = %L', d.other),
    'Only the owner, an admin or an accountant can take % off hold%', '42501');
end $$;

reset role;

-- ---------------------------------------------------------------------
-- The accountant answers for it
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select accountant from t_cl));
set local role authenticated;

do $$
declare d t_cl;
begin
  select * into d from t_cl;
  update public.contacts set credit_hold = false, credit_limit = 800 where id = d.reg;
  update public.contacts set credit_limit = 0 where id = d.other;
  perform pg_temp.check_eq('the accountant takes a hold off, raises one limit and takes another away',
    (select string_agg(code || ' ' || credit_hold || ' ' || credit_limit, ', ' order by code)
       from public.contacts where id in (d.reg, d.other)),
    'LAIN true 0.00, REG false 800.00');
end $$;

reset role;

select pg_temp.sign_in_as((select cashier from t_cl));
set local role authenticated;

do $$
declare d t_cl;
begin
  select * into d from t_cl;
  perform pg_temp.check_eq('and the cashier then sells on account',
    pg_temp.till_sell(d.org, 'AKAUN', 20), 'ok');
end $$;

reset role;

rollback;
