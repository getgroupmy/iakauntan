-- =====================================================================
-- iAkauntan :: a transfer arrives no earlier than it leaves (0898)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/transfer_arrives_after_it_leaves.sql
--
-- Sending posts on the transfer's own date; receiving posted on today,
-- so a transfer dated ahead arrived before it left and the stock sat in
-- both warehouses in between. Written as the owner with the role
-- `authenticated`, as the transfer screen writes.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ta (org uuid, kitchen uuid, shop uuid, rice uuid,
  ahead uuid, past uuid, today_t uuid);
grant select, update on t_ta to authenticated;

-- When a transfer arrived: its movement in, then its journal, in days
-- from today.
create or replace function pg_temp.ta_in(p_t uuid)
returns text language sql as $$
  select coalesce((select (min(m.movement_date) - pg_temp.today())::text
                     from public.stock_movements m
                    where m.source_table = 'stock_transfers' and m.source_id = p_t
                      and m.movement_type = 'transfer_in'), 'none')
         || ' / ' ||
         coalesce((select (e.entry_date - pg_temp.today())::text
                     from public.stock_transfers t join public.gl_entries e on e.id = t.receipt_entry_id
                    where t.id = p_t), 'none');
$$;

-- What a warehouse holds of an item as at a day.
create or replace function pg_temp.ta_on_hand(p_wh uuid, p_item uuid, p_on date)
returns numeric language sql as $$
  select coalesce(sum(quantity), 0)::numeric(18, 2) from public.stock_movements
   where warehouse_id = p_wh and item_id = p_item and movement_date <= p_on;
$$;

create or replace function pg_temp.ta_transfer(p_on date)
returns uuid language plpgsql as $$
declare d t_ta; v uuid;
begin
  select * into d from t_ta;
  v := public.upsert_stock_transfer(null, d.org, d.kitchen, d.shop, p_on,
         jsonb_build_array(jsonb_build_object('item', d.rice, 'quantity', 20, 'uom', 'KGM')),
         'Hantar');
  perform public.send_stock_transfer(v);
  return v;
end $$;

do $$
declare r t_ta;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Pindah Stok Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 60);
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (r.org, 'inventory', true)
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'DAPUR', 'Central kitchen', true) returning id into r.kitchen;
  insert into public.warehouses (org_id, code, name)
  values (r.org, 'KEDAI', 'The shop') returning id into r.shop;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (r.org, 'BERAS', 'Beras', 'stock', true, 'KGM', 4.00) returning id into r.rice;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id, quantity, unit_cost)
  values (r.org, 'OB-1', pg_temp.today() - 20, 'opening_balance', r.rice, r.kitchen, 100, 4.00);
  insert into t_ta select r.*;
end $$;

set local role authenticated;

update t_ta set ahead = pg_temp.ta_transfer(pg_temp.today() + 10),
                past = pg_temp.ta_transfer(pg_temp.today() - 5),
                today_t = pg_temp.ta_transfer(pg_temp.today());

do $$
declare d t_ta;
begin
  select * into d from t_ta;
  perform public.receive_stock_transfer(d.ahead, null);
  perform public.receive_stock_transfer(d.past, null);
  perform public.receive_stock_transfer(d.today_t, null);

  perform pg_temp.check_eq('a transfer dated ahead arrives on its own day, movement and journal',
    pg_temp.ta_in(d.ahead), '10 / 10');
  perform pg_temp.check_eq('so until then the rice is in one place only',
    pg_temp.ta_on_hand(d.kitchen, d.rice, pg_temp.today() + 9)
      + pg_temp.ta_on_hand(d.shop, d.rice, pg_temp.today() + 9), 100.00);
  perform pg_temp.check_eq('and on the day it is in the shop, not the kitchen',
    pg_temp.ta_on_hand(d.shop, d.rice, pg_temp.today() + 10)::text || ' / '
      || pg_temp.ta_on_hand(d.kitchen, d.rice, pg_temp.today() + 10)::text,
    '60.00 / 40.00');
  perform pg_temp.check_eq('one already dated arrives today, as before',
    pg_temp.ta_in(d.past), '0 / 0');
  perform pg_temp.check_eq('and one dated today, today',
    pg_temp.ta_in(d.today_t), '0 / 0');
end $$;

reset role;

rollback;
