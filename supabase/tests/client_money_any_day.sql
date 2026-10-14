-- =====================================================================
-- iAkauntan :: client money is never short on any day (0891)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/client_money_any_day.sql
--
-- The client-funds check summed a matter's whole client ledger and
-- never asked when, so a payment out could be dated before the money it
-- spent arrived. Asked as an accountant, with the role `authenticated`,
-- as the app asks; the void at the end is the owner's, the only one who
-- can make one.
--
-- The check is a deferred constraint trigger, so each refusal below is
-- made immediate first: deferred, it would fire at a commit this file
-- never reaches.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cd (org uuid, accountant uuid, client uuid,
  early uuid, late uuid, target uuid, exact uuid, settle uuid, voided uuid,
  invoice uuid, office uuid, fund_early uuid);
grant select on t_cd to authenticated;

-- A matter's client ledger, day by day, as `day:balance` from today.
create or replace function pg_temp.cd_days(p_matter uuid)
returns text language sql as $$
  select coalesce(string_agg((d.transaction_date - pg_temp.today())::text || ':' || d.running,
                             ' ' order by d.transaction_date), 'none')
    from (select t.transaction_date,
                 sum(sum(t.amount)) over (order by t.transaction_date) as running
            from public.client_account_transactions t
           where t.matter_id = p_matter and t.status <> 'void'
           group by t.transaction_date) d;
$$;

create or replace function pg_temp.cd_matter(p_org uuid, p_client uuid, p_no text)
returns uuid language sql as $$
  insert into public.matters (org_id, matter_no, name, client_id,
                              fee_earner, responsible_solicitor)
  values (p_org, p_no, 'Perkara ' || p_no, p_client,
          pg_temp.test_user(), pg_temp.test_user())
  returning id;
$$;

do $$
declare r t_cd;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Peguam Bertarikh', array['legal']);
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 60, pg_temp.today());
  perform public.setup_legal_module(r.org);
  r.office := pg_temp.test_bank_account(r.org, 'Akaun Pejabat', 'current', 'MYR', 0, 0, '512345678907');
  r.accountant := pg_temp.another_user('akauntan@peguambertarikh.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.accountant, 'accountant', 'active');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C1', 'Puan Aminah', 'customer') returning id into r.client;

  r.early      := pg_temp.cd_matter(r.org, r.client, 'M-EARLY');
  r.late       := pg_temp.cd_matter(r.org, r.client, 'M-LATE');
  r.target     := pg_temp.cd_matter(r.org, r.client, 'M-TARGET');
  r.exact      := pg_temp.cd_matter(r.org, r.client, 'M-EXACT');
  r.settle     := pg_temp.cd_matter(r.org, r.client, 'M-SETTLE');
  r.voided     := pg_temp.cd_matter(r.org, r.client, 'M-VOID');
  r.fund_early := pg_temp.cd_matter(r.org, r.client, 'M-FUNDED');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, matter_id, currency,
     subtotal, total_amount, status)
  values (r.org, 'invoice', 'INV-SETTLE', pg_temp.today() - 20, r.client, r.settle,
          'MYR', 800, 800, 'posted')
  returning id into r.invoice;
  insert into t_cd select r.*;
end $$;

select pg_temp.sign_in_as((select accountant from t_cd));
set local role authenticated;

do $$
declare d t_cd;
begin
  select * into d from t_cd;
  set constraints assert_client_funds immediate;

  -- -------------------------------------------------------------------
  -- Paid out before the money arrived
  -- -------------------------------------------------------------------
  perform public.receive_client_money(d.early, 1000, pg_temp.today(), 'Deposit');
  perform pg_temp.check_refused('a payment dated before the money it spends is refused',
    format('select public.pay_from_client_account(%L, 600, %L, %L)',
           d.early, 'Pejabat Tanah', pg_temp.today() - 10),
    format('Client account for matter M-EARLY would be overdrawn by 600.00 on %s.%%',
           pg_temp.today() - 10),
    '23514');
  perform pg_temp.check_refused('not even the day before',
    format('select public.pay_from_client_account(%L, 600, %L, %L)',
           d.early, 'Pejabat Tanah', pg_temp.today() - 1),
    format('Client account for matter M-EARLY would be overdrawn by 600.00 on %s.%%',
           pg_temp.today() - 1),
    '23514');
  perform pg_temp.check_eq('so the matter holds what it was given',
    pg_temp.cd_days(d.early), '0:1000.00');
  perform public.pay_from_client_account(d.early, 600, 'Pejabat Tanah', pg_temp.today());
  perform pg_temp.check_eq('paid the day it arrived, it goes',
    pg_temp.cd_days(d.early), '0:400.00');

  -- Money that had arrived earlier funds a payment dated before a later
  -- receipt; only the day's balance is asked.
  perform public.receive_client_money(d.fund_early, 1000, pg_temp.today() - 20, 'Deposit');
  perform public.receive_client_money(d.fund_early, 1000, pg_temp.today(), 'Top-up');
  perform public.pay_from_client_account(d.fund_early, 700, 'Jurunilai', pg_temp.today() - 10);
  perform pg_temp.check_eq('a payment the matter had already been given goes, dated back',
    pg_temp.cd_days(d.fund_early), '-20:1000.00 -10:300.00 0:1300.00');

  -- A payment dated back may not take more than the matter held on that
  -- day, though it holds far more today. Short by 200 on its day, not by
  -- the 1,000 it would be with the later receipt left out.
  perform pg_temp.check_refused('nor more than the matter held on the day it is dated',
    format('select public.pay_from_client_account(%L, 500, %L, %L)',
           d.fund_early, 'Jurunilai', pg_temp.today() - 5),
    format('Client account for matter M-FUNDED would be overdrawn by 200.00 on %s.%%',
           pg_temp.today() - 5),
    '23514');
  -- Dated further back still, it leaves two days short: 200 on its own
  -- day and 900 once the earlier payment goes out. The refusal names
  -- the first. The total, 100 in credit, would have let it through.
  perform pg_temp.check_refused('and the first day it leaves short is the one named',
    format('select public.pay_from_client_account(%L, 1200, %L, %L)',
           d.fund_early, 'Jurunilai', pg_temp.today() - 15),
    format('Client account for matter M-FUNDED would be overdrawn by 200.00 on %s.%%',
           pg_temp.today() - 15),
    '23514');

  -- -------------------------------------------------------------------
  -- To the sen, and in either order on one day
  -- -------------------------------------------------------------------
  perform public.receive_client_money(d.exact, 500, pg_temp.today() - 3, 'Deposit');
  perform public.pay_from_client_account(d.exact, 500, 'Pejabat Tanah', pg_temp.today() - 3);
  perform pg_temp.check_eq('paying out the whole of it on the day it came is allowed',
    pg_temp.cd_days(d.exact), '-3:0.00');

  -- -------------------------------------------------------------------
  -- The other two ways out: to another matter, and to office
  -- -------------------------------------------------------------------
  perform public.receive_client_money(d.late, 900, pg_temp.today(), 'Deposit');
  perform pg_temp.check_refused('a transfer to another matter dated before the money is refused',
    format('select public.transfer_between_matters(%L, %L, 300, %L)',
           d.late, d.target, pg_temp.today() - 5),
    format('Client account for matter M-LATE would be overdrawn by 300.00 on %s.%%',
           pg_temp.today() - 5),
    '23514');
  perform public.receive_client_money(d.settle, 800, pg_temp.today(), 'Deposit');
  perform pg_temp.check_refused('and a transfer to office for a bill',
    format('select public.settle_from_client_account(%L, %L, 800, %L, %L)',
           d.settle, d.invoice, pg_temp.today() - 7, d.office),
    format('Client account for matter M-SETTLE would be overdrawn by 800.00 on %s.%%',
           pg_temp.today() - 7),
    '23514');
  perform pg_temp.check_eq('so neither moved anything',
    pg_temp.cd_days(d.late) || ' / ' || pg_temp.cd_days(d.settle) || ' / ' || pg_temp.cd_days(d.target),
    '0:900.00 / 0:800.00 / none');
end $$;

-- -------------------------------------------------------------------
-- A void that leaves an earlier payment unfunded
-- -------------------------------------------------------------------
reset role;
select pg_temp.sign_in_as((select accountant from t_cd));
set local role authenticated;
do $$
declare d t_cd;
begin
  select * into d from t_cd;
  perform public.receive_client_money(d.voided, 1000, pg_temp.today() - 20, 'Deposit');
  perform public.pay_from_client_account(d.voided, 600, 'Pejabat Tanah', pg_temp.today() - 10);
  perform public.receive_client_money(d.voided, 1000, pg_temp.today(), 'Top-up');
end $$;
reset role;

set constraints assert_client_funds immediate;
do $$
declare d t_cd;
begin
  select * into d from t_cd;
  perform pg_temp.check_refused('voiding the receipt that paid for it is refused, though the total stays in credit',
    format('update public.client_account_transactions set status = %L
             where matter_id = %L and transaction_date = %L and amount > 0',
           'void', d.voided, pg_temp.today() - 20),
    format('Client account for matter M-VOID would be overdrawn by 600.00 on %s.%%',
           pg_temp.today() - 10),
    '23514');
  -- Moving that receipt onto another matter does the same to the one it
  -- leaves, though the one it joins is better off.
  perform pg_temp.check_refused('nor can the receipt be moved off the matter it paid for',
    format('update public.client_account_transactions set matter_id = %L
             where matter_id = %L and transaction_date = %L and amount > 0',
           d.target, d.voided, pg_temp.today() - 20),
    format('Client account for matter M-VOID would be overdrawn by 600.00 on %s.%%',
           pg_temp.today() - 10),
    '23514');
  perform pg_temp.check_eq('so the ledger stands',
    pg_temp.cd_days(d.voided), '-20:1000.00 -10:400.00 0:1400.00');
end $$;

rollback;
