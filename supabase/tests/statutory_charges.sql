-- =====================================================================
-- iAkauntan :: the quit rent, and what is behind it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/statutory_charges.sql
--
-- `paid_on` was a date somebody typed. Typing it took the charge out of
-- `property_statutory_due` — the one report anyone consults to see what
-- the company still owes the land office and the local authority — with
-- no bill, no supplier, no payment and nothing in the ledger.
--
-- The assertions here are about what is behind the date:
--
--   * a charge billed through `bill_statutory_charge` carries the
--     charge's own amount and due date, and lands in the ledger;
--   * its `paid_on` is the bill's settlement date, and is null until
--     the bill is settled however many times somebody writes to it;
--   * a bill reopened takes the paid date back with it;
--   * a charge paid outside the books must name the receipt.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.sc_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name, array['property_nonstrata']);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'property_nonstrata', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(v_org,
    date_trunc('year', current_date)::date);
  return v_org;
end $$;

-- ---------------------------------------------------------------------
-- Billed, settled, and reopened
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.sc_org('Tanah Amanah Sdn Bhd');
  v_site  uuid;
  v_land  uuid;
  v_bank  uuid;
  v_ch    uuid;
  v_bill  uuid;
  v_pay   uuid;
  v_ac    text;
  v_said  text;
  v_n     integer;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_due   date := (now() at time zone 'Asia/Kuala_Lumpur')::date + 30;
  v_row   record;
begin
  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'S1', 'Wisma Amanah', 'non_strata') returning id into v_site;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'PTG', 'Pejabat Tanah dan Galian', 'supplier')
  returning id into v_land;
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, currency)
  values (v_org, (select id from public.accounts
                   where org_id = v_org and code = '1110'),
          'Current account', 'Maybank', 'MYR')
  returning id into v_bank;

  insert into public.property_statutory_charges
    (org_id, site_id, kind, authority, account_no, period_year,
     amount, due_date)
  values (v_org, v_site, 'quit_rent', 'Pejabat Tanah Kuala Lumpur',
          'QR-1234-5678', extract(year from v_today)::integer, 4800, v_due)
  returning id into v_ch;

  -- It is owed, and the due report says so.
  select count(*) into v_n from public.property_statutory_due(v_org, 90)
   where charge_id = v_ch;
  perform pg_temp.check_eq('an unpaid charge is on the due list', v_n, 1);

  v_bill := public.bill_statutory_charge(v_ch, v_land);

  -- The bill is made out of the charge, so the two cannot disagree.
  select * into v_row from public.purchase_documents where id = v_bill;
  perform pg_temp.check_eq('the bill is for the charge''s amount',
    round(v_row.total_amount, 2), 4800);
  perform pg_temp.check_eq('and falls due when the charge does',
    v_row.due_date::text, v_due::text);
  perform pg_temp.check_eq('and is posted', v_row.status::text, 'posted');
  perform pg_temp.check_eq('and carries the land office account number',
    v_row.reference, 'QR-1234-5678');

  -- Charged to quit rent, not to licences and not to purchases.
  select a.code into v_ac
    from public.purchase_document_lines l
    join public.accounts a on a.id = l.account_id
   where l.document_id = v_bill;
  perform pg_temp.check_eq('charged to quit rent', v_ac, '6296');

  -- The description is what an auditor traces the bill by.
  perform pg_temp.check_true('the line names the site, the period and '
    'the account',
    (select description from public.purchase_document_lines
      where document_id = v_bill)
      like 'Wisma Amanah — quit rent, %(account QR-1234-5678)');

  -- And it is in the ledger, which is the whole point.
  perform pg_temp.check_eq('the charge is an expense in the ledger',
    (select round(coalesce(sum(l.debit - l.credit), 0), 2)
       from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where a.org_id = v_org and a.code = '6296'), 4800);

  -- Unpaid still: a bill raised is not a bill paid, and the charge must
  -- not leave the due list merely because it has been recorded.
  perform pg_temp.check_true('a billed charge is not yet a paid one',
    (select paid_on from public.property_statutory_charges
      where id = v_ch) is null);
  select count(*) into v_n from public.property_statutory_due(v_org, 90)
   where charge_id = v_ch;
  perform pg_temp.check_eq('and is still on the due list', v_n, 1);

  -- Typing a date now changes nothing. The bill is the record.
  update public.property_statutory_charges
     set paid_on = v_today - 5 where id = v_ch;
  perform pg_temp.check_true('a typed date is ignored while a bill '
    'stands behind the charge',
    (select paid_on from public.property_statutory_charges
      where id = v_ch) is null);

  -- Pay it, dated deliberately earlier than the day it is keyed in.
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, bank_account_id,
     amount, unapplied_amount, currency, exchange_rate)
  values (v_org, 'PAY-1', v_today - 3, v_land, v_bank, 4800, 4800, 'MYR', 1)
  returning id into v_pay;
  perform public.post_purchase_payment(v_pay);
  perform public.allocate_payment_with_discount(v_pay, v_bill, 4800, null);

  -- The date is the payment's, not today's: the period a statutory
  -- charge falls into is decided by when it was paid, not by when
  -- somebody got round to keying the allocation.
  perform pg_temp.check_eq('the paid date is the payment''s',
    (select paid_on from public.property_statutory_charges
      where id = v_ch)::text, (v_today - 3)::text);
  select count(*) into v_n from public.property_statutory_due(v_org, 90)
   where charge_id = v_ch;
  perform pg_temp.check_eq('and the charge leaves the due list', v_n, 0);

  -- Reopen it — the cheque came back. Whatever puts the balance back
  -- must take the paid date with it, or the charge goes on claiming to
  -- be settled by a bill that is outstanding again.
  delete from public.payment_allocations where bill_id = v_bill;
  perform pg_temp.check_true('a reopened bill takes the paid date back',
    (select paid_on from public.property_statutory_charges
      where id = v_ch) is null);
  select count(*) into v_n from public.property_statutory_due(v_org, 90)
   where charge_id = v_ch;
  perform pg_temp.check_eq('and the charge is owed again', v_n, 1);

  -- Billing it twice is billing it twice.
  begin
    perform public.bill_statutory_charge(v_ch, v_land);
    raise exception 'FAIL: a charge was billed twice';
  exception when sqlstate '23505' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a charge is billed once',
    v_said like '%already on bill%');

  -- Settle it again, and then take the bill away. This is what happens
  -- when the bill is deleted: the foreign key sets the link to null,
  -- and a charge left claiming to be paid through a document that no
  -- longer exists is the falsehood coming back in by the side door.
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, bank_account_id,
     amount, unapplied_amount, currency, exchange_rate)
  values (v_org, 'PAY-2', v_today - 1, v_land, v_bank, 4800, 4800, 'MYR', 1)
  returning id into v_pay;
  perform public.post_purchase_payment(v_pay);
  perform public.allocate_payment_with_discount(v_pay, v_bill, 4800, null);
  perform pg_temp.check_eq('settled again',
    (select paid_on from public.property_statutory_charges
      where id = v_ch)::text, (v_today - 1)::text);

  update public.property_statutory_charges
     set bill_document_id = null where id = v_ch;
  perform pg_temp.check_true('the paid date goes with the bill',
    (select paid_on from public.property_statutory_charges
      where id = v_ch) is null);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Paid outside the books, and the receipt it has to name
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.sc_org('Luar Buku Sdn Bhd');
  v_site  uuid;
  v_ch    uuid;
  v_maj   uuid;
  v_said  text;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'S1', 'Kedai Lama', 'non_strata') returning id into v_site;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'DBKL', 'Dewan Bandaraya Kuala Lumpur', 'supplier')
  returning id into v_maj;

  insert into public.property_statutory_charges
    (org_id, site_id, kind, authority, account_no, period_year,
     period_half, amount, due_date)
  values (v_org, v_site, 'assessment', 'DBKL', 'A-99',
          extract(year from v_today)::integer, 1, 620, v_today + 10)
  returning id into v_ch;

  -- A date with nothing behind it is the thing being fixed.
  begin
    update public.property_statutory_charges
       set paid_on = v_today where id = v_ch;
    raise exception 'FAIL: a charge was marked paid with nothing behind it';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  -- The message, not just the code: the table has its own constraints,
  -- and a test taking any refusal would pass with the guard deleted.
  perform pg_temp.check_true('a paid date has to name what paid it',
    v_said like '%give the receipt number%');

  -- The receipt makes it honest.
  update public.property_statutory_charges
     set paid_on = v_today, reference = 'DBKL receipt 88213'
   where id = v_ch;
  perform pg_temp.check_eq('a charge paid at the counter, with its receipt',
    (select paid_on from public.property_statutory_charges
      where id = v_ch)::text, v_today::text);

  -- And it cannot then be billed as well, because the two would each
  -- claim to be the record of the same payment.
  begin
    perform public.bill_statutory_charge(v_ch, v_maj);
    raise exception 'FAIL: a charge already paid was billed as well';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('one record of the payment, not two',
    v_said like '%Clear the paid date before billing it%');

  -- Inserting one already paid, with its receipt, is allowed — a
  -- managing agent taking over a site enters last year's as history.
  insert into public.property_statutory_charges
    (org_id, site_id, kind, period_year, amount, due_date, paid_on,
     reference)
  values (v_org, v_site, 'quit_rent',
          extract(year from v_today)::integer - 1, 300, v_today - 400,
          v_today - 380, 'Old receipt 12');
  perform pg_temp.check_eq('history comes in with its receipt',
    (select count(*)::integer from public.property_statutory_charges
      where org_id = v_org and paid_on is not null), 2);

  -- But not without one.
  begin
    insert into public.property_statutory_charges
      (org_id, site_id, kind, period_year, amount, due_date, paid_on)
    values (v_org, v_site, 'quit_rent',
            extract(year from v_today)::integer - 2, 300, v_today - 800,
            v_today - 780);
    raise exception 'FAIL: history came in with nothing behind it';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and not without one',
    v_said like '%give the receipt number%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What is behind each one
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.sc_org('Laporan Cukai Sdn Bhd');
  v_site  uuid;
  v_land  uuid;
  v_billed uuid; v_counter uuid; v_owing uuid;
  v_bill  uuid;
  v_row   record;
  v_year  integer;
  v_n     integer;
  v_said  text;
  v_out   uuid := pg_temp.another_user('outsider@sc.test');
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_year := extract(year from v_today)::integer;
  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'S1', 'Rumah Kedai', 'non_strata') returning id into v_site;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'PTG', 'Pejabat Tanah', 'supplier') returning id into v_land;

  insert into public.property_statutory_charges
    (org_id, site_id, kind, period_year, amount, due_date)
  values (v_org, v_site, 'quit_rent', v_year, 1200, v_today + 20)
  returning id into v_billed;
  insert into public.property_statutory_charges
    (org_id, site_id, kind, period_year, period_half, amount, due_date,
     paid_on, reference)
  values (v_org, v_site, 'assessment', v_year, 1, 400, v_today - 10,
          v_today - 12, 'Counter receipt 7')
  returning id into v_counter;
  insert into public.property_statutory_charges
    (org_id, site_id, kind, period_year, period_half, amount, due_date)
  values (v_org, v_site, 'assessment', v_year, 2, 400, v_today + 150)
  returning id into v_owing;

  v_bill := public.bill_statutory_charge(v_billed, v_land);

  select * into v_row from public.report_statutory_charges(v_org, v_year)
   where charge_id = v_billed;
  perform pg_temp.check_eq('the billed one names its bill',
    v_row.settled_by, 'bill');
  perform pg_temp.check_eq('and the bill number',
    v_row.bill_no,
    (select doc_no from public.purchase_documents where id = v_bill));

  select * into v_row from public.report_statutory_charges(v_org, v_year)
   where charge_id = v_counter;
  perform pg_temp.check_eq('the counter one says so',
    v_row.settled_by, 'outside the books');
  perform pg_temp.check_eq('and names the receipt',
    v_row.reference, 'Counter receipt 7');
  perform pg_temp.check_eq('and the half it is for', v_row.period,
    v_year::text || ' H1');

  select * into v_row from public.report_statutory_charges(v_org, v_year)
   where charge_id = v_owing;
  perform pg_temp.check_eq('and the one still owed is unpaid',
    v_row.settled_by, 'unpaid');

  -- The year filter is a filter.
  select count(*)::integer into v_n
    from public.report_statutory_charges(v_org, v_year - 5);
  perform pg_temp.check_eq('a year with nothing in it reports nothing',
    v_n, 0);

  -- An outsider reads none of it, and is refused by this function's own
  -- guard rather than by the row policies behind it.
  perform pg_temp.sign_in_as(v_out);
  begin
    perform count(*) from public.report_statutory_charges(v_org, v_year);
    raise exception 'FAIL: an outsider read the statutory charges';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('not your company', v_said like '%Not your company%');

  begin
    perform public.bill_statutory_charge(v_owing, v_land);
    raise exception 'FAIL: an outsider billed a statutory charge';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and bills none of it either',
    v_said like '%not permitted to bill a statutory charge%');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A nil charge, and a company that never bought the module
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.sc_org('Kosong Sdn Bhd');
  v_other uuid := pg_temp.test_org('Bukan Hartanah Sdn Bhd');
  v_site  uuid;
  v_land  uuid;
  v_ch    uuid;
  v_real  uuid;
  v_alien uuid;
  v_said  text;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'S1', 'Tapak Kosong', 'non_strata') returning id into v_site;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'PTG', 'Pejabat Tanah', 'supplier') returning id into v_land;

  insert into public.property_statutory_charges
    (org_id, site_id, kind, period_year, amount, due_date)
  values (v_org, v_site, 'quit_rent',
          extract(year from v_today)::integer, 0, v_today + 30)
  returning id into v_ch;

  begin
    perform public.bill_statutory_charge(v_ch, v_land);
    raise exception 'FAIL: a nil charge was billed';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a bill is for something',
    v_said like '%That charge is nil%');

  -- A supplier from another company is not this company's supplier.
  -- On a charge with an amount on it, so the nil check above cannot
  -- stand in for the one under test.
  insert into public.property_statutory_charges
    (org_id, site_id, kind, period_year, amount, due_date)
  values (v_org, v_site, 'assessment',
          extract(year from v_today)::integer, 500, v_today + 30)
  returning id into v_real;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_other, 'X', 'Orang Luar Sdn Bhd', 'supplier')
  returning id into v_alien;
  begin
    perform public.bill_statutory_charge(v_real, v_alien);
    raise exception 'FAIL: a charge was billed to another company''s supplier';
  exception when sqlstate 'P0002' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and to a supplier of this company',
    v_said like '%No such supplier%');

  perform pg_temp.sign_out();
end $$;

rollback;
