-- =====================================================================
-- iAkauntan :: a deposit is used no earlier than it was taken (0887)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/deposit_used_after_taken.sql
--
-- A deposit may be dated ahead, and "Apply" and "Refund" send no date,
-- so a deposit dated next week was applied and refunded today -- the
-- liability debited before it was credited. Asked as an accountant,
-- with the role `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_du (org uuid, accountant uuid, cust uuid, bank uuid,
  invoice uuid, ahead uuid, today_dep uuid);
grant select on t_du to authenticated;

-- A deposit's balance and how many times it has been used.
create or replace function pg_temp.du_state(p_deposit uuid)
returns text language sql as $$
  select n.balance_amount::text || ' left, '
         || (select count(*) from public.deposit_events e where e.deposit_id = n.id)
         || ' settled, '
         || (select count(*) from public.payment_allocations a where a.deposit_id = n.id)
         || ' applied'
    from public.deposit_notes n where n.id = p_deposit;
$$;

do $$
declare r t_du; v_item uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Deposit Bertarikh Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 90);
  r.accountant := pg_temp.another_user('akauntan@depositbertarikh.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.accountant, 'accountant', 'active');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan', 'customer') returning id into r.cust;
  insert into public.items (org_id, code, name, item_type, track_inventory, unit_price)
  values (r.org, 'KHID', 'Khidmat', 'service', false, 1000) returning id into v_item;
  r.bank := pg_temp.test_bank_account(r.org, 'Semasa', 'current', 'MYR', 0, 0, '512345678905');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'invoice', 'INV-1', pg_temp.today(), pg_temp.today(), r.cust, 'MYR', 1, 'draft')
  returning id into r.invoice;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price)
  values (r.org, r.invoice, 1, 'item', v_item, 'Kerja', 5, 1000);
  perform public.post_sales_document(r.invoice);

  -- One taken ten days on, one taken today.
  r.ahead     := public.create_deposit(r.org, 'customer', r.cust, pg_temp.today() + 10,
                   500, r.bank);
  r.today_dep := public.create_deposit(r.org, 'customer', r.cust, pg_temp.today(),
                   300, r.bank);
  insert into t_du select r.*;
end $$;

select pg_temp.sign_in_as((select accountant from t_du));
set local role authenticated;

do $$
declare d t_du;
begin
  select * into d from t_du;

  -- -------------------------------------------------------------------
  -- Before it was taken: not applied, not given back, not kept
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a deposit is not applied before it was taken',
    format('select public.apply_deposit(%L, %L, 100)', d.ahead, d.invoice),
    'Deposit % was taken on %, and cannot be applied before then.', '23514');
  perform pg_temp.check_refused('not even the day before',
    format('select public.apply_deposit(%L, %L, 100, %L)', d.ahead, d.invoice,
           pg_temp.today() + 9),
    'Deposit % was taken on %, and cannot be applied before then.', '23514');
  perform pg_temp.check_refused('nor given back before it was taken',
    format($q$select public.settle_deposit(%L, 'refund', 100, null, %L)$q$, d.ahead, d.bank),
    'Deposit % was taken on %, and cannot be given back or kept before then.', '23514');
  perform pg_temp.check_refused('not even the day before',
    format($q$select public.settle_deposit(%L, 'refund', 100, null, %L, %L)$q$,
           d.ahead, d.bank, pg_temp.today() + 9),
    'Deposit % was taken on %, and cannot be given back or kept before then.', '23514');
  perform pg_temp.check_refused('nor kept before it was taken',
    format($q$select public.settle_deposit(%L, 'forfeit', 100, 'Batal')$q$, d.ahead),
    'Deposit % was taken on %, and cannot be given back or kept before then.', '23514');
  perform pg_temp.check_eq('so it is all still held',
    pg_temp.du_state(d.ahead), '500.00 left, 0 settled, 0 applied');

  -- -------------------------------------------------------------------
  -- On the day it was taken, and after
  -- -------------------------------------------------------------------
  perform public.apply_deposit(d.ahead, d.invoice, 100, pg_temp.today() + 10);
  perform pg_temp.check_eq('it is applied on the day it was taken',
    pg_temp.du_state(d.ahead), '400.00 left, 0 settled, 1 applied');
  perform public.settle_deposit(d.ahead, 'refund', 100, null, d.bank, pg_temp.today() + 10);
  perform pg_temp.check_eq('and given back that day',
    pg_temp.du_state(d.ahead), '300.00 left, 1 settled, 1 applied');
  perform public.settle_deposit(d.ahead, 'forfeit', 50, 'Batal sebahagian',
    null, pg_temp.today() + 11);
  perform pg_temp.check_eq('and kept the day after',
    pg_temp.du_state(d.ahead), '250.00 left, 2 settled, 1 applied');

  -- Taken today, used today with no day given, as the app does.
  perform public.apply_deposit(d.today_dep, d.invoice, 100);
  perform public.settle_deposit(d.today_dep, 'refund', 100, null, d.bank);
  perform pg_temp.check_eq('a deposit taken today is used today, as before',
    pg_temp.du_state(d.today_dep), '100.00 left, 1 settled, 1 applied');
end $$;

reset role;

rollback;
