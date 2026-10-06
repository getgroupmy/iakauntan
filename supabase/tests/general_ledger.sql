-- =====================================================================
-- iAkauntan :: the ledger itself
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/general_ledger.sql
--
-- A trial balance is a list of totals. The general ledger is what the
-- totals are made of: by account, in date order, with the balance
-- carried down the page. Before 0458 this schema had the first and not
-- the second.
--
-- The assertion that matters most is not about any single figure. It is
-- that the ledger and the trial balance agree — because they compute
-- the same thing twice, and two answers to "what is in account 1120"
-- is worse than one.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.gl_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.acct(p_org uuid, p_code text)
returns uuid language sql as $$
  select id from public.accounts where org_id = p_org and code = p_code;
$$;

-- Three journals in a row on the same account, so there is a balance to
-- carry down and an order to get wrong.
create or replace function pg_temp.gl_fixture(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.gl_org(p_name);
begin
  perform public.post_manual_journal(v_org, date '2026-01-10',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1120'),
                         'debit', 10000, 'credit', 0, 'description', 'Capital'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '3100'),
                         'debit', 0, 'credit', 10000, 'description', 'Capital')),
    'Capital introduced');

  perform public.post_manual_journal(v_org, date '2026-02-15',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '6100'),
                         'debit', 2500, 'credit', 0, 'description', 'Rent'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1120'),
                         'debit', 0, 'credit', 2500, 'description', 'Rent')),
    'February rent');

  perform public.post_manual_journal(v_org, date '2026-03-20',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '6100'),
                         'debit', 2500, 'credit', 0, 'description', 'Rent'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1120'),
                         'debit', 0, 'credit', 2500, 'description', 'Rent')),
    'March rent');

  -- Money back in, so the balance goes down and then up. A ledger
  -- printed in balance order rather than date order reads correctly
  -- for a column that only ever falls; this is what makes the
  -- difference visible.
  perform public.post_manual_journal(v_org, date '2026-04-05',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1120'),
                         'debit', 3000, 'credit', 0, 'description', 'Refund'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '4100'),
                         'debit', 0, 'credit', 3000, 'description', 'Refund')),
    'April receipt');

  return v_org;
end;
$$;

-- ---------------------------------------------------------------------
-- The balance carried down
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_acc uuid;
  r     record;
  v_n   integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.gl_fixture('Lejar Sdn Bhd');
  v_acc := pg_temp.acct(v_org, '1120');

  select count(*)::integer into v_n
    from public.report_general_ledger(v_org, null, date '2026-12-31', v_acc);
  perform pg_temp.check_eq(
    'the account shows every line it was touched by, and its opening',
    v_n, 5);

  -- Brought forward first, and it is not a transaction.
  select * into r
    from public.report_general_ledger(v_org, null, date '2026-12-31', v_acc)
   where is_opening;
  perform pg_temp.check_eq('nothing is brought forward from before time',
    r.balance, 0);
  perform pg_temp.check_eq('and the opening line moves nothing',
    r.debit + r.credit, 0);

  -- Then the balance walks down: 10,000 in, 2,500 out, 2,500 out.
  perform pg_temp.check_eq('the first entry stands at what went in',
    (select balance from public.report_general_ledger(
       v_org, null, date '2026-12-31', v_acc)
      where entry_date = date '2026-01-10'), 10000);
  perform pg_temp.check_eq('the second carries the first down with it',
    (select balance from public.report_general_ledger(
       v_org, null, date '2026-12-31', v_acc)
      where entry_date = date '2026-02-15'), 7500);
  perform pg_temp.check_eq('and so does the third',
    (select balance from public.report_general_ledger(
       v_org, null, date '2026-12-31', v_acc)
      where entry_date = date '2026-03-20'), 5000);
  perform pg_temp.check_eq('and the fourth puts some back',
    (select balance from public.report_general_ledger(
       v_org, null, date '2026-12-31', v_acc)
      where entry_date = date '2026-04-05'), 8000);

  -- The order the rows come back in, not just the figures in them. A
  -- ledger is read down the page: a balance that does not follow from
  -- the line above it is worse than no balance at all, and asserting
  -- values by date says nothing about the order they arrive in.
  perform pg_temp.check_eq('and the page reads down in that order',
    (select string_agg(g.balance::text, ' ' order by g.ord)
       from (select balance, row_number() over () as ord
               from public.report_general_ledger(
                 v_org, null, date '2026-12-31', v_acc)) g),
    '0.00 10000.00 7500.00 5000.00 8000.00');

  -- Which is the whole point of the report: the last balance is what
  -- the trial balance says, arrived at a different way.
  perform pg_temp.check_eq(
    'and the ledger ends where the trial balance says it does',
    (select balance from public.report_general_ledger(
       v_org, null, date '2026-12-31', v_acc)
      where entry_date = date '2026-04-05'),
    (select closing_balance from public.report_trial_balance(
       v_org, null, date '2026-12-31') where code = '1120'));
end $$;

-- ---------------------------------------------------------------------
-- A period that starts partway through
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_acc uuid;
  r     record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.gl_fixture('Lejar Separuh Sdn Bhd');
  v_acc := pg_temp.acct(v_org, '1120');

  -- February onwards. January's RM10,000 is not a line any more; it is
  -- the balance the page starts from.
  select * into r
    from public.report_general_ledger(
      v_org, date '2026-02-01', date '2026-12-31', v_acc)
   where is_opening;
  perform pg_temp.check_eq('what happened before the period is brought forward',
    r.balance, 10000);

  perform pg_temp.check_true('and is not listed again as a movement',
    not exists (select 1 from public.report_general_ledger(
       v_org, date '2026-02-01', date '2026-12-31', v_acc)
      where entry_date = date '2026-01-10'));

  perform pg_temp.check_eq('the balance still ends where it ended',
    (select balance from public.report_general_ledger(
       v_org, date '2026-02-01', date '2026-12-31', v_acc)
      where entry_date = date '2026-04-05'), 8000);

  -- And a period that ends early stops there rather than running on.
  perform pg_temp.check_eq('a period that ends early ends early',
    (select max(balance) from public.report_general_ledger(
       v_org, date '2026-02-01', date '2026-02-28', v_acc)
      where not is_opening), 7500);
end $$;

-- ---------------------------------------------------------------------
-- Every account, and the ones with nothing in them
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_n   integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.gl_fixture('Lejar Penuh Sdn Bhd');

  -- Three accounts were touched. The other eighty-odd in the chart are
  -- not part of anybody's ledger and are left out.
  select count(distinct code)::integer into v_n
    from public.report_general_ledger(v_org, null, date '2026-12-31');
  perform pg_temp.check_eq('only the accounts that were used appear', v_n, 4);

  perform pg_temp.check_true('and every one of them opens the page',
    (select count(*) from public.report_general_ledger(
       v_org, null, date '2026-12-31') where is_opening) = 4);

  -- The ledger and the trial balance are the same arithmetic done
  -- twice. If they ever disagree, both are useless.
  perform pg_temp.check_eq('every account agrees with the trial balance',
    (select count(*)::integer
       from public.report_trial_balance(v_org, null, date '2026-12-31') tb
       join lateral (
         select balance from public.report_general_ledger(
           v_org, null, date '2026-12-31') g
          where g.code = tb.code
          -- Movements first, latest last: `is_opening` sorts false
          -- before true, so an account with nothing but a brought
          -- forward balance still yields its one row.
          order by g.is_opening, g.entry_date desc nulls last,
                   g.entry_no desc, g.line_no desc
          limit 1) last on true
      where round(tb.closing_balance, 2) <> round(last.balance, 2)),
    0);
end $$;

-- ---------------------------------------------------------------------
-- The balance a company started with
--
-- `accounts.opening_balance` is what was on the books the day this
-- system took over. It is not a journal and never will be, so a ledger
-- that summed only journals would open every migrated company at zero
-- and disagree with its own trial balance from the first line.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_acc uuid;
  r     record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.gl_fixture('Lejar Bawa Sdn Bhd');
  v_acc := pg_temp.acct(v_org, '1120');

  update public.accounts set opening_balance = 2000 where id = v_acc;

  select * into r
    from public.report_general_ledger(v_org, null, date '2026-12-31', v_acc)
   where is_opening;
  perform pg_temp.check_eq('what the company came in with is brought forward',
    r.balance, 2000);

  perform pg_temp.check_eq('and every line after it carries that too',
    (select balance from public.report_general_ledger(
       v_org, null, date '2026-12-31', v_acc)
      where entry_date = date '2026-04-05'), 10000);

  perform pg_temp.check_eq('which is what the trial balance says as well',
    (select closing_balance from public.report_trial_balance(
       v_org, null, date '2026-12-31') where code = '1120'), 10000);
end $$;

-- ---------------------------------------------------------------------
-- What is not in it
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_acc   uuid;
  v_other uuid;
  v_took  boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.gl_fixture('Lejar Sulit Sdn Bhd');
  v_acc := pg_temp.acct(v_org, '1120');

  -- A draft journal is not the ledger. Posting is what puts it there.
  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, description, status,
     total_debit, total_credit)
  values (v_org, 'JV-DRAFT', date '2026-04-01', 'manual', 'Not posted',
          'draft', 999, 999);
  insert into public.gl_lines
    (org_id, entry_id, line_no, account_id, description, debit, credit)
  values (v_org,
          (select id from public.gl_entries
            where org_id = v_org and entry_no = 'JV-DRAFT'),
          1, v_acc, 'Not posted', 999, 0);

  perform pg_temp.check_true('a draft journal is not in the ledger',
    not exists (select 1 from public.report_general_ledger(
      v_org, null, date '2026-12-31', v_acc) where entry_no = 'JV-DRAFT'));

  perform pg_temp.check_eq('so the balance is unmoved by it',
    (select balance from public.report_general_ledger(
       v_org, null, date '2026-12-31', v_acc)
      where entry_date = date '2026-04-05'), 8000);

  -- And another company's ledger is not this one's.
  v_other := pg_temp.another_user('outsider-0458@iakauntan.test');
  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_eq('somebody outside the company sees no ledger',
    (select count(*)::integer from public.report_general_ledger(
       v_org, null, date '2026-12-31')), 0);
end $$;

-- ---------------------------------------------------------------------
-- The ledger, rule by rule
--
-- A mutation sweep of `report_general_ledger` killed 15 of 28 on this
-- file. Every survivor but one was a rule the fixture never reached:
-- a call with no end date; a journal on the period's first day; a
-- draft before the period; an opening balance on a liability, an
-- expense, a deleted account, a group heading, or another company's
-- account; an account with nothing but a balance brought forward; a
-- journal back-dated after later ones were posted; a contact.
--
-- Not asserted, because no data can tell it apart: the brought-forward
-- sum reading another company's lines on this company's account --
-- `gl_lines_account_same_org` ties a line's company to its account's.
-- A table constraint.
-- ---------------------------------------------------------------------
do $$
declare
  v_other uuid; v_org uuid; v_owner uuid; v_acc uuid; v_cust uuid;
  r record;
begin
  -- Another company first, with an opening balance of its own, so that
  -- a ledger that forgot whose accounts it was reading would show it.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_other := pg_temp.gl_org('Lejar Orang Lain Sdn Bhd');
  update public.accounts set opening_balance = 777
   where org_id = v_other and code = '1130';

  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.gl_fixture('Lejar Peraturan Sdn Bhd');
  v_owner := (select created_by from public.organizations where id = v_org);
  perform pg_temp.sign_in_as(v_owner);
  v_acc := pg_temp.acct(v_org, '1120');

  perform pg_temp.check_eq('another company''s accounts are not in this ledger',
    (select count(*)::integer from public.report_general_ledger(
       v_org, null, date '2026-12-31') g
       join public.accounts a on a.id = g.account_id
      where a.org_id <> v_org), 0);

  -- No end date is today, not some earlier day.
  perform pg_temp.check_eq('with no end date the ledger runs to today',
    (select count(*)::integer from public.report_general_ledger(
       v_org, null, null, v_acc)), 5);

  -- A period that opens on the day of an entry: brought forward is
  -- everything before it, and the entry itself is the first line.
  perform pg_temp.check_eq('a period opening on an entry brings forward only what came before',
    (select balance from public.report_general_ledger(
       v_org, date '2026-02-15', date '2026-12-31', v_acc) where is_opening),
    10000);
  perform pg_temp.check_eq('and lists that day''s entry',
    (select count(*)::integer from public.report_general_ledger(
       v_org, date '2026-02-15', date '2026-12-31', v_acc)
      where entry_date = date '2026-02-15' and not is_opening), 1);

  -- A draft before the period is not brought forward.
  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, description, status,
     total_debit, total_credit)
  values (v_org, 'JV-DRAFT-JAN', date '2026-01-20', 'manual', 'Not posted',
          'draft', 999, 999);
  insert into public.gl_lines
    (org_id, entry_id, line_no, account_id, description, debit, credit)
  values (v_org, (select id from public.gl_entries
                   where org_id = v_org and entry_no = 'JV-DRAFT-JAN'),
          1, v_acc, 'Not posted', 999, 0);
  perform pg_temp.check_eq('a draft before the period is not brought forward',
    (select balance from public.report_general_ledger(
       v_org, date '2026-02-01', date '2026-12-31', v_acc) where is_opening),
    10000);

  -- Opening balances, each signed by what the account is: a liability
  -- and an expense, neither of them touched by a journal since.
  update public.accounts set opening_balance = 5000
   where org_id = v_org and code = '2110';
  update public.accounts set opening_balance = 100
   where org_id = v_org and code = '6100';
  select * into r from public.report_general_ledger(
    v_org, null, date '2026-12-31', pg_temp.acct(v_org, '2110'));
  perform pg_temp.check_eq(
    'a payable brought forward with nothing since still has its page',
    r.balance, -5000);
  perform pg_temp.check_eq('an expense brought forward is a debit',
    (select balance from public.report_general_ledger(
       v_org, null, date '2026-12-31', pg_temp.acct(v_org, '6100'))
      where is_opening), 100);

  -- A deleted account and a group heading, each with an opening
  -- balance somebody typed, are still not ledger accounts.
  update public.accounts set opening_balance = 300, deleted_at = now()
   where org_id = v_org and code = '1130';
  update public.accounts set opening_balance = 400
   where org_id = v_org and code = '1100';
  perform pg_temp.check_eq('a deleted account is not in the ledger',
    (select count(*)::integer from public.report_general_ledger(
       v_org, null, date '2026-12-31') where code = '1130'), 0);
  perform pg_temp.check_eq('nor a group heading',
    (select count(*)::integer from public.report_general_ledger(
       v_org, null, date '2026-12-31') where code = '1100'), 0);

  -- A line that names a contact says who.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pelanggan Lejar', 'customer') returning id into v_cust;
  perform public.post_manual_journal(v_org, date '2026-05-01',
    jsonb_build_array(
      jsonb_build_object('account_id', v_acc, 'contact_id', v_cust,
                         'debit', 50, 'credit', 0, 'description', 'Named'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '4100'),
                         'debit', 0, 'credit', 50, 'description', 'Named')),
    'A named line');
  perform pg_temp.check_eq('a line that names a contact says who',
    (select contact_name from public.report_general_ledger(
       v_org, null, date '2026-12-31', v_acc)
      where entry_date = date '2026-05-01'), 'Pelanggan Lejar');

  -- Back-dated: posted last, dated first. The running balance follows
  -- the date, so the page still reads down.
  perform public.post_manual_journal(v_org, date '2026-01-05',
    jsonb_build_array(
      jsonb_build_object('account_id', v_acc,
                         'debit', 1000, 'credit', 0, 'description', 'Late'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '3100'),
                         'debit', 0, 'credit', 1000, 'description', 'Late')),
    'Back-dated');
  perform pg_temp.check_eq('a journal back-dated later stands where its date puts it',
    (select balance from public.report_general_ledger(
       v_org, null, date '2026-12-31', v_acc)
      where entry_date = date '2026-01-05'), 1000);
  perform pg_temp.check_eq('and everything after it carries it down',
    (select balance from public.report_general_ledger(
       v_org, null, date '2026-12-31', v_acc)
      where entry_date = date '2026-01-10'), 11000);
end $$;

rollback;
