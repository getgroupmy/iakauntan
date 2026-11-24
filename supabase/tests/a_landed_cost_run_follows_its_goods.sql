-- =====================================================================
-- iAkauntan :: a landed cost run follows its goods (0928)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/a_landed_cost_run_follows_its_goods.sql
--
-- A landed cost run's journal and stock movement are dated by the run.
-- Before `0928` a run dated sixty days before its bill posted on that
-- day, putting freight onto stock that was not there yet. As the owner
-- with the role `authenticated`, and as the database's owner for a date
-- changed behind the save.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_lg (
  org uuid, wh uuid, sup uuid, tile uuid,
  b1 uuid, b1_no text, b2 uuid, b2_no text, grn uuid, b3 uuid, b3_no text, b4 uuid, svc uuid);
grant select on t_lg to authenticated;

-- A draft run over the bills given, one charge of 50.
create or replace function pg_temp.lg_run(p_id uuid, p_org uuid, p_date date, p_bills uuid[])
returns uuid language sql as $$
  select public.upsert_landed_cost_run(p_id, p_org, p_date,
    (select jsonb_agg(jsonb_build_object('bill', b)) from unnest(p_bills) b),
    jsonb_build_array(jsonb_build_object('description', 'Fret', 'amount', 50)),
    null);
$$;

do $$
declare r t_lg; v_po uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Barang Sampai Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 60, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['accounting', 'inventory', 'purchases', 'sales']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'MAIN', 'Stor', true) returning id into r.wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal', 'supplier') returning id into r.sup;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'TILE', 'Jubin', 'stock', true, 'C62', 20) returning id into r.tile;

  -- A bill that received its own goods, ten days ago.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'bill', 'BIL-1', pg_temp.today() - 10, pg_temp.today(), r.sup, 'MYR', 1, 'draft')
  returning id, doc_no into r.b1, r.b1_no;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, uom_code, unit_price, warehouse_id)
  values (r.org, r.b1, 1, 'item', r.tile, 'Jubin', 100, 'C62', 10, r.wh);
  perform public.post_purchase_document(r.b1);

  -- Goods received on a note twenty days ago, billed five days ago: the
  -- bill moves no stock of its own.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'purchase_order', 'PO-1', pg_temp.today() - 25, r.sup, 'MYR', 1, 'draft')
  returning id into v_po;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, uom_code, unit_price, warehouse_id)
  values (r.org, v_po, 1, 'item', r.tile, 'Jubin', 50, 'C62', 10, r.wh);
  update public.purchase_documents set status = 'posted' where id = v_po;
  r.grn := public.transfer_document(v_po, 'goods_received');
  update public.purchase_documents set doc_date = pg_temp.today() - 20 where id = r.grn;
  perform public.post_goods_received(r.grn);
  r.b2 := public.transfer_document(r.grn, 'bill');
  update public.purchase_documents set doc_date = pg_temp.today() - 5, due_date = pg_temp.today()
   where id = r.b2;
  perform public.post_purchase_document(r.b2);
  select doc_no into r.b2_no from public.purchase_documents where id = r.b2;

  -- And a bill that received its own goods three days ago.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'bill', 'BIL-3', pg_temp.today() - 3, pg_temp.today(), r.sup, 'MYR', 1, 'draft')
  returning id, doc_no into r.b3, r.b3_no;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, uom_code, unit_price, warehouse_id)
  values (r.org, r.b3, 1, 'item', r.tile, 'Jubin', 20, 'C62', 10, r.wh);
  perform public.post_purchase_document(r.b3);

  -- And one, two days ago, for a service: nothing received, so it is
  -- taken at its own date.
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'PASANG', 'Pemasangan', 'service', false, 'C62', 20) returning id into r.svc;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'bill', 'BIL-4', pg_temp.today() - 2, pg_temp.today(), r.sup, 'MYR', 1, 'draft')
  returning id into r.b4;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, uom_code, unit_price)
  values (r.org, r.b4, 1, 'item', r.svc, 'Pasang', 1, 'C62', 100);
  perform public.post_purchase_document(r.b4);

  insert into t_lg select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_lg; v_run uuid; v_entry uuid;
begin
  select * into d from t_lg;

  perform pg_temp.check_eq('the note, not its bill, moved the goods it received',
    (select count(*) from public.stock_movements m
      where m.source_table = 'purchase_documents' and m.source_id = d.b2),
    0::bigint);

  -- -------------------------------------------------------------------
  -- Saved: not before the goods arrived
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a run is not dated the day before its bill''s goods arrived',
    format('select pg_temp.lg_run(null, %L, %L, array[%L]::uuid[])', d.org, pg_temp.today() - 11, d.b1),
    'Landed cost run % is dated ' || (pg_temp.today() - 11) || ', before the goods on bill BIL-1 arrived on '
      || (pg_temp.today() - 10) || ': freight can only go onto stock that is there. Date the run on or after '
      || (pg_temp.today() - 10) || '.',
    '23514');
  perform pg_temp.check_refused('nor before a goods received note brought in what its bill names',
    format('select pg_temp.lg_run(null, %L, %L, array[%L]::uuid[])', d.org, pg_temp.today() - 21, d.b2),
    'Landed cost run % is dated ' || (pg_temp.today() - 21) || ', before the goods on bill ' || d.b2_no
      || ' arrived on ' || (pg_temp.today() - 20) || ':%',
    '23514');
  perform pg_temp.check_refused('a run over two bills follows the later of them',
    format('select pg_temp.lg_run(null, %L, %L, array[%L, %L]::uuid[])', d.org, pg_temp.today() - 4, d.b1, d.b3),
    'Landed cost run % is dated ' || (pg_temp.today() - 4) || ', before the goods on bill BIL-3 arrived on '
      || (pg_temp.today() - 3) || ':%',
    '23514');
  perform pg_temp.check_refused('a bill that received nothing is taken at its own date',
    format('select pg_temp.lg_run(null, %L, %L, array[%L, %L]::uuid[])', d.org, pg_temp.today() - 5, d.b1, d.b4),
    'Landed cost run % is dated ' || (pg_temp.today() - 5) || ', before the goods on bill BIL-4 arrived on '
      || (pg_temp.today() - 2) || ':%',
    '23514');
  perform pg_temp.check_eq('and none of those was kept',
    (select count(*) from public.landed_cost_runs where org_id = d.org), 0::bigint);

  -- On the day, or after it, is taken; and a bill raised from a note
  -- follows the note, so a run between the two is right.
  v_run := pg_temp.lg_run(null, d.org, pg_temp.today() - 10, array[d.b1]);
  v_entry := public.post_landed_cost_run(v_run);
  perform pg_temp.check_eq('a run on the day the goods arrived posts on that day',
    (select entry_date::text from public.gl_entries where id = v_entry), (pg_temp.today() - 10)::text);
  v_run := pg_temp.lg_run(null, d.org, pg_temp.today() - 15, array[d.b2]);
  v_entry := public.post_landed_cost_run(v_run);
  perform pg_temp.check_eq('a run after the note and before its bill posts too',
    (select entry_date::text from public.gl_entries where id = v_entry), (pg_temp.today() - 15)::text);

  -- -------------------------------------------------------------------
  -- Saved again
  -- -------------------------------------------------------------------
  v_run := pg_temp.lg_run(null, d.org, pg_temp.today(), array[d.b1, d.b3]);
  perform pg_temp.check_refused('a saved run is not moved to before its goods',
    format('select pg_temp.lg_run(%L, %L, %L, array[%L, %L]::uuid[])', v_run, d.org, pg_temp.today() - 4, d.b1, d.b3),
    'Landed cost run % is dated ' || (pg_temp.today() - 4) || ', before the goods on bill BIL-3 arrived on%',
    '23514');
  perform pg_temp.check_eq('and keeps its date',
    (select run_date::text from public.landed_cost_runs where id = v_run), pg_temp.today()::text);
  -- Moved earlier while the later bill comes off it: asked of the bill
  -- it still spreads over, not the one taken off.
  perform pg_temp.lg_run(v_run, d.org, pg_temp.today() - 4, array[d.b1]);
  perform pg_temp.check_eq('moved earlier with its later bill taken off, it is saved',
    (select run_date::text from public.landed_cost_runs where id = v_run), (pg_temp.today() - 4)::text);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- Posted: a date changed behind the save is asked again
-- ---------------------------------------------------------------------
do $$
declare d t_lg; v_run uuid; v_no text; v_posted bigint;
begin
  select * into d from t_lg;
  select count(*) into v_posted from public.gl_entries where source_table = 'landed_cost_runs'
     and source_id in (select id from public.landed_cost_runs where org_id = d.org);
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_run := pg_temp.lg_run(null, d.org, pg_temp.today(), array[d.b1, d.b3]);
  select run_no into v_no from public.landed_cost_runs where id = v_run;
  -- After the first bill's goods, before the second's.
  update public.landed_cost_runs set run_date = pg_temp.today() - 5 where id = v_run;

  perform pg_temp.check_refused('a run whose date was changed behind the save is not posted',
    format('select public.post_landed_cost_run(%L)', v_run),
    'Landed cost run ' || v_no || ' is dated ' || (pg_temp.today() - 5) || ', before the goods on bill BIL-3 arrived on '
      || (pg_temp.today() - 3) || ':%',
    '23514');
  perform pg_temp.check_eq('and is still a draft',
    (select status::text from public.landed_cost_runs where id = v_run), 'draft');
  perform pg_temp.check_eq('with nothing posted for it',
    (select count(*) from public.gl_entries where source_table = 'landed_cost_runs'
        and source_id in (select id from public.landed_cost_runs where org_id = d.org)),
    v_posted);
  perform pg_temp.check_eq('nor any stock moved for it',
    (select count(*) from public.stock_movements where source_table = 'landed_cost_runs' and source_id = v_run),
    0::bigint);

  -- Put back on a date after its goods, it posts.
  update public.landed_cost_runs set run_date = pg_temp.today() - 3 where id = v_run;
  perform public.post_landed_cost_run(v_run);
  perform pg_temp.check_eq('dated after its goods again, it posts',
    (select status::text from public.landed_cost_runs where id = v_run), 'posted');
end $$;

rollback;
