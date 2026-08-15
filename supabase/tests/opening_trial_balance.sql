-- =====================================================================
-- iAkauntan :: the opening trial balance
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/opening_trial_balance.sql
--
-- One assertion carries this file: **after both halves of a migration,
-- `3900 Opening Balance Equity` is zero.**
--
-- It is worth more than the sum of the figures around it. 0150 posts the
-- receivables invoice by invoice and parks the other side in 3900; this
-- import posts everything except the control accounts and puts the
-- residual in the same place. The two meet at zero only if the old
-- system's receivables total agrees with the invoices actually brought
-- across — so a zero here is a reconciliation, and a non-zero is the
-- amount by which somebody's migration is incomplete.
--
-- Which is also why the control accounts are asserted *not* to move
-- twice. That is the failure this design exists to avoid and it is
-- silent: doubled receivables look like a healthy balance sheet.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.tb_org(p_name text, p_owner uuid)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', p_owner)
  returning id into v;
  perform app.seed_chart_of_accounts(v);
  perform pg_temp.sign_in_as(p_owner);
  perform public.create_fiscal_year(v, date '2026-01-01');
  return v;
end; $$;

create or replace function pg_temp.balance_of(p_org uuid, p_code text)
returns numeric language sql stable as $$
  select round(coalesce(sum(l.debit - l.credit), 0), 2)
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.org_id = p_org and a.code = p_code;
$$;

-- ---------------------------------------------------------------------
-- Both halves of a migration, agreeing
-- ---------------------------------------------------------------------
do $$
declare
  v_boss uuid := pg_temp.another_user('boss@tb.test');
  v_org uuid; v_rows jsonb; v_refused boolean; v_msg text; v_n integer;
begin
  v_org := pg_temp.tb_org('Opening TB Sdn Bhd', v_boss);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Pelanggan', 'customer'),
         (v_org, 'S-001', 'Pembekal', 'supplier');

  perform public.import_open_invoices(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','INV-1','contact_code','C-001',
      'doc_date','2025-11-03','outstanding_amount','3000'),
    jsonb_build_object('doc_no','INV-2','contact_code','C-001',
      'doc_date','2026-06-30','outstanding_amount','1200.50')),
    date '2026-08-01', true);
  perform public.import_open_bills(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','BILL-1','contact_code','S-001',
      'doc_date','2026-05-02','outstanding_amount','800')),
    date '2026-08-01', true);

  perform pg_temp.check_eq(
    'the open items leave the receivables less the payables in suspense',
    (select balance from public.report_opening_balance_suspense(v_org)),
    3400.50);

  v_rows := jsonb_build_array(
    jsonb_build_object('account_code','1110','debit','5000'),
    jsonb_build_object('account_code','1210','debit','4200.50'),
    jsonb_build_object('account_code','2110','credit','800'),
    jsonb_build_object('account_code','3100','credit','1000'),
    jsonb_build_object('account_code','3200','credit','7400.50'));

  -- The preview says the control accounts are not posted, and says so
  -- because it has checked rather than because it always does.
  perform pg_temp.check_true(
    'the receivables row reports agreement with the invoices imported',
    (select message like '%they agree at 4200.50%'
       from public.import_opening_balances(v_org, v_rows, date '2026-08-01', false)
      where code = '1210'));
  perform pg_temp.check_true('and is not an error',
    (select status = 'ok'
       from public.import_opening_balances(v_org, v_rows, date '2026-08-01', false)
      where code = '1210'));

  perform public.import_opening_balances(v_org, v_rows, date '2026-08-01', true);

  -- The assertion this file exists for.
  perform pg_temp.check_eq(
    'once both halves are in, opening balance equity is nothing',
    (select balance from public.report_opening_balance_suspense(v_org)), 0);
  perform pg_temp.check_true('and says so',
    (select settled from public.report_opening_balance_suspense(v_org)));

  -- The control accounts moved once, not twice.
  perform pg_temp.check_eq(
    'receivables are what the invoices came to, not twice that',
    pg_temp.balance_of(v_org, '1210'), 4200.50);
  perform pg_temp.check_eq('and payables likewise',
    pg_temp.balance_of(v_org, '2110'), -800);

  -- And everything else did move.
  perform pg_temp.check_eq('cash came in', pg_temp.balance_of(v_org, '1110'), 5000);
  perform pg_temp.check_eq('share capital came in',
    pg_temp.balance_of(v_org, '3100'), -1000);
  perform pg_temp.check_eq('retained earnings came in',
    pg_temp.balance_of(v_org, '3200'), -7400.50);

  select count(*) into v_n from (
    select l.entry_id from public.gl_lines l
     where l.org_id = v_org group by l.entry_id
    having round(sum(l.debit) - sum(l.credit), 2) <> 0) x;
  perform pg_temp.check_eq('every entry balances', v_n, 0);

  -- Once only. Unlike an invoice there is no document number to catch a
  -- second run, so the guard is the entry itself.
  v_refused := false;
  begin perform public.import_opening_balances(v_org, v_rows, date '2026-08-01', true);
  exception when others then v_refused := true; v_msg := sqlerrm; end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true(
    'a second opening trial balance is refused rather than doubled',
    v_refused);
  perform pg_temp.check_true('and says why',
    v_msg like '%already been brought into this company%');
  perform pg_temp.check_eq('nothing moved', pg_temp.balance_of(v_org, '1110'), 5000);
end $$;

-- ---------------------------------------------------------------------
-- Both halves of a migration, disagreeing
--
-- The control account is where a migration goes wrong, so the case where
-- the two sides differ is asserted rather than assumed. This is also the
-- control for the block above: a function that reported agreement
-- unconditionally would pass every assertion there.
-- ---------------------------------------------------------------------
do $$
declare
  v_boss uuid := pg_temp.another_user('boss2@tb.test');
  v_org uuid; v_rows jsonb;
begin
  v_org := pg_temp.tb_org('Opening TB Dua Sdn Bhd', v_boss);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Pelanggan', 'customer');

  -- One invoice was missed out of the open items.
  perform public.import_open_invoices(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','INV-1','contact_code','C-001',
      'doc_date','2025-11-03','outstanding_amount','3000')),
    date '2026-08-01', true);

  v_rows := jsonb_build_array(
    jsonb_build_object('account_code','1110','debit','5000'),
    jsonb_build_object('account_code','1210','debit','4200.50'),
    jsonb_build_object('account_code','3100','credit','1000'),
    jsonb_build_object('account_code','3200','credit','8200.50'));

  perform pg_temp.check_true(
    'a receivables total that does not match what was brought across is '
    'a warning, not silence',
    (select status = 'warning'
       from public.import_opening_balances(v_org, v_rows, date '2026-08-01', false)
      where code = '1210'));
  perform pg_temp.check_true('naming both figures, which is the useful part',
    (select message like '%4200.50%' and message like '%3000.00%'
       from public.import_opening_balances(v_org, v_rows, date '2026-08-01', false)
      where code = '1210'));

  -- A warning does not stop the file: the migration is still worth
  -- completing, and the difference then shows up where it can be chased.
  perform public.import_opening_balances(v_org, v_rows, date '2026-08-01', true);

  -- Exactly the invoice that was left out, and on the side that says so:
  -- the report gives credits less debits, so a *debit* balance means the
  -- trial balance expected more receivables than were brought across.
  -- The other sign would mean invoices imported that the old system's
  -- own receivables figure does not account for, which is a different
  -- mistake and wants a different answer.
  perform pg_temp.check_eq(
    'and the suspense account is left holding exactly the difference',
    (select balance from public.report_opening_balance_suspense(v_org)),
    -1200.50);
  perform pg_temp.check_true('reported as unsettled',
    (select not settled from public.report_opening_balance_suspense(v_org)));
end $$;

-- ---------------------------------------------------------------------
-- Files that are wrong
-- ---------------------------------------------------------------------
do $$
declare
  v_boss uuid := pg_temp.another_user('boss3@tb.test');
  v_clerk uuid := pg_temp.another_user('clerk@tb.test');
  v_org uuid; v_refused boolean; v_msg text; v_role text;
begin
  v_org := pg_temp.tb_org('Opening TB Tiga Sdn Bhd', v_boss);

  perform pg_temp.check_true('a heading is refused, because posting to it '
    'would double the accounts under it',
    (select message like '%heading%'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','3000','credit','1000'),
         jsonb_build_object('account_code','1110','debit','1000')),
         date '2026-08-01', false)
      where code = '3000'));

  perform pg_temp.check_true('an unknown code is named rather than ignored',
    (select message like '%not an account in this company%'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','9999','debit','1000'),
         jsonb_build_object('account_code','3100','credit','1000')),
         date '2026-08-01', false)
      where code = '9999'));

  -- 3900 is created on demand, so in a company that has imported nothing
  -- it does not exist — and the answer must still be the reason it is
  -- refused, not "no such account".
  perform pg_temp.check_true(
    'the suspense account itself is refused by name, even before it exists',
    (select message like '%balances *to*%'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','3900','credit','1000'),
         jsonb_build_object('account_code','1110','debit','1000')),
         date '2026-08-01', false)
      where code = '3900'));

  perform pg_temp.check_true('a negative is sent to the other column',
    (select message like '%other column%'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','1110','debit','-5')),
         date '2026-08-01', false)
      where code = '1110'));

  perform pg_temp.check_true('and a line on both sides at once is refused',
    (select message like '%one side or the other%'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','1110','debit','5','credit','5')),
         date '2026-08-01', false)
      where code = '1110'));

  -- A trial balance that does not balance is not one.
  v_refused := false;
  begin
    perform public.import_opening_balances(v_org, jsonb_build_array(
      jsonb_build_object('account_code','1110','debit','5000'),
      jsonb_build_object('account_code','3100','credit','4000')),
      date '2026-08-01', true);
  exception when others then v_refused := true; v_msg := sqlerrm; end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true('a file that does not balance is refused',
    v_refused);
  perform pg_temp.check_true(
    'saying by how much, which is what somebody goes looking for',
    v_msg like '%difference of 1000.00%');

  -- The control: the same file, balanced, goes in.
  perform public.import_opening_balances(v_org, jsonb_build_array(
    jsonb_build_object('account_code','1110','debit','5000'),
    jsonb_build_object('account_code','3100','credit','5000')),
    date '2026-08-01', true);
  perform pg_temp.check_eq('a balanced one does not',
    pg_temp.balance_of(v_org, '1110'), 5000);

  -- Posting, not preparing.
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'accounts_clerk');
  perform pg_temp.sign_in_as(v_clerk);
  v_refused := false;
  begin
    set local role authenticated;
    v_role := current_user;
    perform public.import_opening_balances(v_org, jsonb_build_array(
      jsonb_build_object('account_code','1130','debit','1'),
      jsonb_build_object('account_code','3100','credit','1')),
      date '2026-08-01', true);
  exception when others then v_refused := true;
  end;
  reset role;
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_true(
    'an accounts clerk cannot bring in an opening ledger', v_refused);
end $$;

rollback;
