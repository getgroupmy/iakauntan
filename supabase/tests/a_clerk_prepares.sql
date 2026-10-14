-- =====================================================================
-- iAkauntan :: a clerk prepares, somebody else posts (0883)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/a_clerk_prepares.sql
--
-- Deposits, contras and post-dated cheques post a journal the moment
-- they are made, cleared, settled or bounced, and asked only whether
-- the caller may write the module -- which an Accounts Clerk may. Each
-- asks whether the caller may post now. Asked with the role
-- `authenticated`, as the app asks.
--
-- Every refusal is paired with the same call by an accountant, which
-- does the work or meets the function's NEXT question.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cp (org uuid, clerk uuid, accountant uuid, cust uuid,
  bank uuid, invoice uuid, deposit uuid, pdc_clear uuid, pdc_bounce uuid);
grant select on t_cp to authenticated;

create or replace function pg_temp.outcome(p_statement text)
returns text language plpgsql as $$
begin
  execute p_statement;
  return 'done';
exception when others then return SQLERRM;
end $$;

create or replace function pg_temp.journals(p_org uuid) returns integer
language sql as $$
  select count(*)::int from public.gl_entries where org_id = p_org;
$$;

do $$
declare r t_cp; v_item uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Kerani Sedia Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  -- Both sides of today: a cheque dated next month, cleared or
  -- bounced on it, is next year's in the last days of December.
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 90);
  r.clerk      := pg_temp.another_user('kerani@keranisedia.test');
  r.accountant := pg_temp.another_user('akauntan@keranisedia.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.clerk, 'accounts_clerk', 'active'),
         (r.org, r.accountant, 'accountant', 'active');

  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan', 'customer') returning id into r.cust;
  insert into public.items (org_id, code, name, item_type, track_inventory, unit_price)
  values (r.org, 'KHID', 'Khidmat', 'service', false, 1000) returning id into v_item;
  r.bank := pg_temp.test_bank_account(r.org, 'Semasa', 'current', 'MYR', 0, 0, '512345678903');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'invoice', 'INV-1', pg_temp.today(), pg_temp.today(), r.cust, 'MYR', 1, 'draft')
  returning id into r.invoice;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price)
  values (r.org, r.invoice, 1, 'item', v_item, 'Kerja', 5, 1000);
  perform public.post_sales_document(r.invoice);

  -- What there is already, made by the owner.
  r.deposit := public.create_deposit(r.org, 'customer', r.cust, pg_temp.today(), 1000,
    r.bank, '02', 'CHQ 1', 'Pendahuluan');
  r.pdc_clear := public.record_pdc(r.org, 'incoming', r.cust, '100001',
    pg_temp.today() + 30, 1000,
    jsonb_build_array(jsonb_build_object('document', r.invoice, 'amount', 1000)),
    r.bank, 'CIMB');
  r.pdc_bounce := public.record_pdc(r.org, 'incoming', r.cust, '100002',
    pg_temp.today() + 30, 1000,
    jsonb_build_array(jsonb_build_object('document', r.invoice, 'amount', 1000)),
    r.bank, 'CIMB');
  insert into t_cp select r.*;
end $$;

create temporary table t_count (n integer);
grant all on t_count to authenticated;
insert into t_count select pg_temp.journals((select org from t_cp));

-- ---------------------------------------------------------------------
-- The clerk: none of the seven posts
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select clerk from t_cp));
set local role authenticated;

do $$
declare d t_cp;
begin
  select * into d from t_cp;
  perform pg_temp.check_refused('a clerk takes no deposit',
    format($q$select public.create_deposit(%L, 'customer', %L, %L, 500, %L)$q$,
           d.org, d.cust, pg_temp.today(), d.bank),
    'A deposit posts to the ledger, which only somebody who may post does%', '42501');
  perform pg_temp.check_refused('applies none to an invoice',
    format('select public.apply_deposit(%L, %L, 100)', d.deposit, d.invoice),
    'Applying a deposit posts to the ledger, which only somebody who may post does%', '42501');
  perform pg_temp.check_refused('refunds none',
    format($q$select public.settle_deposit(%L, 'refund', 100, null, %L)$q$, d.deposit, d.bank),
    'Settling a deposit posts to the ledger, which only somebody who may post does%', '42501');
  perform pg_temp.check_refused('records no post-dated cheque',
    format($q$select public.record_pdc(%L, 'incoming', %L, '100003', %L, 500,
                     jsonb_build_array(jsonb_build_object('document', %L, 'amount', 500)), %L)$q$,
           d.org, d.cust, pg_temp.today() + 30, d.invoice, d.bank),
    'A post-dated cheque posts to the ledger, which only somebody who may post does%', '42501');
  perform pg_temp.check_refused('clears none',
    format('select public.clear_pdc(%L, %L)', d.pdc_clear, pg_temp.today() + 31),
    'Clearing a post-dated cheque posts to the ledger, which only somebody who may post does%', '42501');
  perform pg_temp.check_refused('bounces none',
    format($q$select public.bounce_pdc(%L, 'Refer to drawer', %L)$q$, d.pdc_bounce, pg_temp.today() + 31),
    'A bounced cheque posts to the ledger, which only somebody who may post does%', '42501');
  perform pg_temp.check_refused('and sets nothing off in a contra',
    format($q$select public.create_contra(%L, %L, '[]'::jsonb, '[]'::jsonb, null)$q$,
           d.org, pg_temp.today()),
    'A contra posts to the ledger, which only somebody who may post does%', '42501');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('so the clerk put no journal in the ledger',
    pg_temp.journals((select org from t_cp)), (select n from t_count));
end $$;

-- ---------------------------------------------------------------------
-- The accountant: done, or the function's next question
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select accountant from t_cp));
set local role authenticated;

do $$
declare d t_cp;
begin
  select * into d from t_cp;
  perform pg_temp.check_true('an accountant takes a deposit',
    public.create_deposit(d.org, 'customer', d.cust, pg_temp.today(), 500, d.bank) is not null);
  perform pg_temp.check_true('applies one to the invoice',
    public.apply_deposit(d.deposit, d.invoice, 100) is not null);
  perform pg_temp.check_true('refunds part of it',
    public.settle_deposit(d.deposit, 'refund', 100, null, d.bank) is not null);
  perform pg_temp.check_true('records a post-dated cheque',
    public.record_pdc(d.org, 'incoming', d.cust, '100004', pg_temp.today() + 30, 500,
      jsonb_build_array(jsonb_build_object('document', d.invoice, 'amount', 500)), d.bank) is not null);
  perform pg_temp.check_true('clears one',
    public.clear_pdc(d.pdc_clear, pg_temp.today() + 31) is not null);
  perform pg_temp.check_true('bounces one',
    public.bounce_pdc(d.pdc_bounce, 'Refer to drawer', pg_temp.today() + 31) is not null);
  perform pg_temp.check_eq('and is asked for both sides of a contra',
    pg_temp.outcome(format($q$select public.create_contra(%L, %L, '[]'::jsonb, '[]'::jsonb, null)$q$,
                           d.org, pg_temp.today())),
    'A contra needs something on both sides: an invoice to settle and a bill to settle it against.');
end $$;

reset role;

rollback;
