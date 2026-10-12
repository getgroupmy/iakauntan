-- =====================================================================
-- iAkauntan :: a ledger account is closed by closing it (0829)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ledger_account_closed_by_closing.sql
--
-- `retire_account` will not close 1210 Accounts Receivable: the ledger
-- posts to it by number. Before `0829` a client could close it by hand,
-- and the next invoice posted to the closed account and left the trial
-- balance short; or delete it, and the next invoice did not post at all.
-- Asked as the owner, with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_la (org uuid, cust uuid, ar uuid, gone uuid, spare uuid);
grant select, update on t_la to authenticated;

-- An invoice of one line, posted, as the invoice screen posts one.
create or replace function pg_temp.inv(p_no text, p_amt numeric)
returns uuid language plpgsql as $$
declare d t_la; v_id uuid;
begin
  select * into d from t_la;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status, currency, exchange_rate)
  values (d.org, 'invoice', p_no, pg_temp.today(), pg_temp.today(), d.cust, 'draft', 'MYR', 1)
  returning id into v_id;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price)
  values (d.org, v_id, 1, 'item', 'Work', 1, p_amt);
  perform public.post_sales_document(v_id);
  return v_id;
end $$;
grant execute on function pg_temp.inv(text, numeric) to authenticated;

do $$
declare r t_la;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Carta Kekal Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, date_trunc('year', pg_temp.today())::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Pelanggan', 'customer') returning id into r.cust;
  r.ar := (select id from public.accounts where org_id = r.org and code = '1210');
  insert into t_la select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_la;
begin
  select * into d from t_la;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- What `retire_account` says.
  perform pg_temp.check_refused('retire_account will not close 1210',
    format('select public.retire_account(%L)', d.ar),
    'Account 1210 is one the ledger posts to by number.%', '23514');

  -- What was measured: closed by hand instead. And each half alone.
  perform pg_temp.check_refused('nor is it closed by hand',
    format('update public.accounts set is_active = false, deleted_at = now() where id = %L', d.ar),
    'Account 1210 is closed with retire_account%', '42501');
  perform pg_temp.check_refused('nor marked deleted alone',
    format('update public.accounts set deleted_at = now() where id = %L', d.ar),
    'Account 1210 is closed with retire_account%', '42501');
  perform pg_temp.check_refused('nor switched off alone',
    format('update public.accounts set is_active = false where id = %L', d.ar),
    'Account 1210 is closed with retire_account%', '42501');

  -- Nor deleted.
  perform pg_temp.check_refused('nor deleted',
    format('delete from public.accounts where id = %L', d.ar),
    'permission denied for table accounts', '42501');

  -- An account closed properly is not reopened by hand either.
  d.gone := public.upsert_account('6197', 'Tidak dipakai', 'expense', 'operating_expense',
    p_org_id => d.org);
  update t_la set gone = d.gone;
  perform pg_temp.check_eq('an account with nothing in it is closed through retire_account',
    public.retire_account(d.gone), 'closed');
  perform pg_temp.check_refused('and is not reopened by hand',
    format('update public.accounts set deleted_at = null where id = %L', d.gone),
    'Account 6197 is closed with retire_account%', '42501');
  perform pg_temp.check_refused('nor switched back on alone',
    format('update public.accounts set is_active = true where id = %L', d.gone),
    'Account 6197 is closed with retire_account%', '42501');

  -- Nor made already closed.
  perform pg_temp.check_refused('an account is not made closed',
    format($q$insert into public.accounts (org_id, code, name, account_type, account_subtype, deleted_at)
              values (%L, '6196', 'Tutup', 'expense', 'operating_expense', now())$q$, d.org),
    'A new account is open.%', '42501');
  perform pg_temp.check_refused('nor switched off',
    format($q$insert into public.accounts (org_id, code, name, account_type, account_subtype, is_active)
              values (%L, '6196', 'Tutup', 'expense', 'operating_expense', false)$q$, d.org),
    'A new account is open.%', '42501');

  -- What the chart screen writes is as before.
  d.spare := public.upsert_account('6195', 'Ganti', 'expense', 'operating_expense',
    p_org_id => d.org);
  update t_la set spare = d.spare;
  update public.accounts set tax_treatment = 'entertainment', name = 'Ganti nama' where id = d.spare;
  perform pg_temp.check_eq('the chart still sets an account''s tax treatment and name',
    (select tax_treatment || '/' || name from public.accounts where id = d.spare),
    'entertainment/Ganti nama');
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (d.org, '6194', 'Baharu', 'expense', 'operating_expense');
  perform pg_temp.check_true('and an open account is still made',
    (select is_active and deleted_at is null from public.accounts
      where org_id = d.org and code = '6194'));

  -- So an invoice goes to an open 1210, and the trial balance balances.
  perform pg_temp.inv('INV-1', 100);
  perform pg_temp.check_eq('RM100 receivable, on an open 1210',
    (select closing_balance from public.report_trial_balance(d.org) where account_id = d.ar),
    100::numeric);
  perform pg_temp.check_eq('and the trial balance balances',
    (select sum(closing_balance) from public.report_trial_balance(d.org)), 0::numeric);
end $$;

reset role;

-- The database itself, as the owner, is not a client.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives as
-- an equivalent one: `retire_account`, the console's restore and the
-- posting helpers that revive an account are definers, which run as the
-- owner at any depth.
do $$
declare d t_la;
begin
  select * into d from t_la;
  update public.accounts set is_active = false where id = d.spare;
  perform pg_temp.check_true('the owner, at the top, is not refused',
    not (select is_active from public.accounts where id = d.spare));

  perform pg_temp.check_eq('no delete policy is left on the accounts',
    (select count(*)::integer from pg_policies
      where schemaname = 'public' and tablename = 'accounts'
        and cmd in ('DELETE', 'ALL') and permissive = 'PERMISSIVE'), 0);
end $$;

rollback;
