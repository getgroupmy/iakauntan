-- =====================================================================
-- iAkauntan :: withholding tax
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/withholding.sql
--
-- Statutory arithmetic, so the rates are asserted one by one: a rate
-- that moves has to break CI rather than a CP37. The deadline is
-- asserted the same way, including across a short month, because "one
-- month" and "thirty days" are different dates in February and only one
-- of them is the law.
--
-- The other thing asserted here is that a deduction keeps the payables
-- subledger and the payable control account moving together. Withholding
-- settles part of a bill without money reaching the supplier, and a
-- settlement that only touches one of the two is how an aged listing
-- stops footing.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.wht_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.supplier(
  p_org uuid, p_code text, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, p_code, p_name, 'supplier')
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function pg_temp.bill(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric,
  p_date date default date '2026-02-10')
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id,
     currency, exchange_rate, status)
  values (p_org, 'bill', p_no, p_date, p_date + 30, p_contact, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Technical services', 1, p_amount);
  perform public.post_purchase_document(v_doc);
  return v_doc;
end;
$$;

-- The balance on an account in the nominal, as at a date.
create or replace function pg_temp.balance(
  p_org uuid, p_code text, p_as_at date default date '2026-12-31')
returns numeric language sql as $$
  select coalesce(
    (select closing_balance from public.report_trial_balance(p_org, null, p_as_at)
      where code = p_code), 0);
$$;

-- ---------------------------------------------------------------------
-- The rates in the Act
--
-- One assertion per rate, named for the section, so a failure says
-- which one moved.
-- ---------------------------------------------------------------------
do $$
declare
  r record;
  v_expected numeric;
begin
  for r in select code, section, rate, payee, remit_months
             from public.ref_withholding_types order by sort_order
  loop
    v_expected := case r.code
      when 'S107A_A'           then 10   -- contractor's own tax
      when 'S107A_B'           then 3    -- tax on the contractor's employees
      when 'S109_INTEREST'     then 15
      when 'S109_ROYALTY'      then 10
      when 'S109A_ENTERTAINER' then 15
      when 'S109B_SPECIAL'     then 10   -- s.4A special classes of income
      when 'S109F_OTHER'       then 10   -- s.4(f) other gains or profits
      when 'S107D_AGENT'       then 2    -- resident agent, dealer, distributor
    end;

    if v_expected is null then
      raise exception 'FAIL: % (%) is seeded but this test does not know '
        'what rate it should carry', r.code, r.section;
    end if;
    perform pg_temp.check_eq(
      format('%s (%s)', r.code, r.section), r.rate, v_expected);

    -- Everything here is remitted within one month of paying or
    -- crediting. A type seeded with a different rule is a change
    -- somebody has to come and justify here.
    perform pg_temp.check_eq(
      format('%s is remitted within a month', r.code), r.remit_months, 1);
  end loop;

  perform pg_temp.check_eq('eight types are seeded',
    (select count(*) from public.ref_withholding_types), 8);

  -- s.107D is the only one of these that reaches a resident, and
  -- treating it as a non-resident deduction would put it on the wrong
  -- form.
  perform pg_temp.check_true('only s.107D applies to a resident',
    (select payee from public.ref_withholding_types where code = 'S107D_AGENT')
      = 'resident'
    and not exists (select 1 from public.ref_withholding_types
                     where payee = 'resident' and code <> 'S107D_AGENT'));
end $$;

-- ---------------------------------------------------------------------
-- Deducting, and what it does to the ledger
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.wht_org('Withhold Sdn Bhd');
  v_supp uuid; v_bill uuid; v_cert uuid; c public.withholding_certificates;
begin
  v_supp := pg_temp.supplier(v_org, 'S-001', 'Overseas Consulting Pte Ltd');
  v_bill := pg_temp.bill(v_org, v_supp, 'BILL-1', 100000, date '2026-02-10');

  v_cert := public.create_withholding(v_bill, 'S109B_SPECIAL');
  select * into c from public.withholding_certificates where id = v_cert;

  perform pg_temp.check_eq('ten per cent of a hundred thousand',
    c.tax_amount, 10000);
  perform pg_temp.check_eq('on the whole bill unless told otherwise',
    c.gross_amount, 100000);
  perform pg_temp.check_true('under the section it was issued under',
    c.section = 'ITA s.109B' and c.form_code = 'CP37A');
  -- One month after 10 February is 10 March.
  perform pg_temp.check_true('due one month after it was credited',
    c.due_date = date '2026-03-10');

  perform pg_temp.check_true('nothing is in the ledger until it is posted',
    c.gl_entry_id is null
    and (select balance_amount from public.purchase_documents where id = v_bill)
        = 100000);

  perform public.post_withholding(v_cert);

  -- Dr payable, Cr withholding payable. The supplier is owed ninety
  -- thousand and LHDN is owed ten.
  perform pg_temp.check_eq('the payable comes down by the tax',
    -pg_temp.balance(v_org, '2110'), 90000);
  perform pg_temp.check_eq('and the tax is held, not spent',
    -pg_temp.balance(v_org, '2145'), 10000);
  perform pg_temp.check_eq('the bill shows what the supplier will actually get',
    (select balance_amount from public.purchase_documents where id = v_bill),
    90000);

  -- The assertion that ties the two halves together.
  perform pg_temp.check_eq('and the aged listing still foots to the control',
    (select coalesce(sum(base_outstanding), 0)
       from public.report_ap_aging(v_org, date '2026-02-28')),
    -pg_temp.balance(v_org, '2110', date '2026-02-28'));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A month is not thirty days
--
-- Credited on 31 January, due 28 February. Thirty days would say 2
-- March, which is two days after the money should have reached LHDN.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.wht_org('Shortmonth Sdn Bhd');
  v_supp uuid; v_bill uuid; v_cert uuid;
begin
  v_supp := pg_temp.supplier(v_org, 'S-001', 'Overseas Ltd');
  v_bill := pg_temp.bill(v_org, v_supp, 'BILL-1', 50000, date '2026-01-31');
  v_cert := public.create_withholding(v_bill, 'S109_ROYALTY');

  perform pg_temp.check_true('the end of January falls due at the end of February',
    (select due_date = date '2026-02-28'
       from public.withholding_certificates where id = v_cert));
  perform pg_temp.check_eq('ten per cent on a royalty',
    (select tax_amount from public.withholding_certificates where id = v_cert),
    5000);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Interest, and a treaty rate
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.wht_org('Interest Sdn Bhd');
  v_supp uuid; v_bill uuid; v_statutory uuid; v_treaty uuid;
begin
  v_supp := pg_temp.supplier(v_org, 'S-001', 'Lender Ltd');
  v_bill := pg_temp.bill(v_org, v_supp, 'BILL-1', 200000, date '2026-02-01');

  v_statutory := public.create_withholding(v_bill, 'S109_INTEREST',
                                           p_gross_amount => 100000);
  perform pg_temp.check_eq('fifteen per cent on interest',
    (select tax_amount from public.withholding_certificates where id = v_statutory),
    15000);

  -- A double tax agreement can cut any of these, and which one applies
  -- depends on where the payee is resident rather than on anything this
  -- database knows. The rate is a default, not a rule.
  v_treaty := public.create_withholding(v_bill, 'S109_INTEREST',
                                        p_gross_amount => 100000, p_rate => 10);
  perform pg_temp.check_eq('a treaty rate is applied as given',
    (select tax_amount from public.withholding_certificates where id = v_treaty),
    10000);
  perform pg_temp.check_true('and the section is still recorded',
    (select section = 'ITA s.109' and rate = 10
       from public.withholding_certificates where id = v_treaty));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Remitting it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.wht_org('Remit Sdn Bhd');
  v_supp uuid; v_bill uuid; v_cert uuid;
begin
  v_supp := pg_temp.supplier(v_org, 'S-001', 'Overseas Ltd');
  v_bill := pg_temp.bill(v_org, v_supp, 'BILL-1', 100000, date '2026-02-10');
  v_cert := public.create_withholding(v_bill, 'S107A_A');

  perform pg_temp.check_eq('ten per cent under s.107A(1)(a)',
    (select tax_amount from public.withholding_certificates where id = v_cert),
    10000);

  -- Remitting before posting would credit the bank for a liability the
  -- ledger has never heard of.
  begin
    perform public.remit_withholding(v_cert, date '2026-03-05');
    raise exception 'FAIL: remitted a certificate that was never posted';
  exception when sqlstate '22023' then
    raise notice 'ok   the certificate has to be posted first';
  end;

  perform public.post_withholding(v_cert);
  perform public.remit_withholding(v_cert, date '2026-03-05',
                                   p_reference => 'CP37D/2026/001');

  perform pg_temp.check_eq('the liability is cleared',
    -pg_temp.balance(v_org, '2145'), 0);
  perform pg_temp.check_true('and it is on the record as remitted',
    (select remitted_on = date '2026-03-05'
        and remittance_ref = 'CP37D/2026/001'
        and status = 'completed'
       from public.withholding_certificates where id = v_cert));

  -- Paying LHDN twice for one deduction.
  begin
    perform public.remit_withholding(v_cert, date '2026-03-06');
    raise exception 'FAIL: remitted the same certificate twice';
  exception when sqlstate '22023' then
    raise notice 'ok   a certificate is only remitted once';
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What it refuses
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.wht_org('Refuse Sdn Bhd');
  v_supp uuid; v_bill uuid; v_draft uuid;
begin
  v_supp := pg_temp.supplier(v_org, 'S-001', 'Overseas Ltd');
  v_bill := pg_temp.bill(v_org, v_supp, 'BILL-1', 1000, date '2026-02-10');

  -- Withholding more than is left on the bill would push the payable
  -- past zero and settle a debt that is not there.
  begin
    perform public.create_withholding(v_bill, 'S109B_SPECIAL',
                                      p_gross_amount => 1000, p_rate => 200);
    raise exception 'FAIL: withheld more than the bill was worth';
  exception when sqlstate '22023' then
    raise notice 'ok   it will not withhold more than is outstanding';
  end;

  begin
    perform public.create_withholding(v_bill, 'NOT_A_SECTION');
    raise exception 'FAIL: accepted a section that does not exist';
  exception when sqlstate '22023' then
    raise notice 'ok   an unknown section is refused';
  end;

  -- An unposted bill has created no payable to deduct from.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-2', date '2026-02-10', v_supp, 'MYR', 1, 'draft')
  returning id into v_draft;
  begin
    perform public.create_withholding(v_draft, 'S109B_SPECIAL',
                                      p_gross_amount => 100);
    raise exception 'FAIL: withheld against a bill that was never posted';
  exception when sqlstate '22023' then
    raise notice 'ok   the bill has to be posted first';
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The return, and what being late costs
--
-- s.109(2) adds ten per cent to tax that misses its month. It is
-- reported and never posted: nobody has been charged it until LHDN says
-- so, and a journal for a penalty that has not been raised is a
-- liability the company does not have.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.wht_org('Late Sdn Bhd');
  v_supp uuid; v_bill uuid; v_late uuid; v_soon uuid; r record;
begin
  v_supp := pg_temp.supplier(v_org, 'S-001', 'Overseas Ltd');
  v_bill := pg_temp.bill(v_org, v_supp, 'BILL-1', 300000, date '2026-02-10');

  -- Credited long enough ago that its month has certainly run out.
  v_late := public.create_withholding(v_bill, 'S109B_SPECIAL',
    p_gross_amount => 100000, p_cert_date => current_date - 120);
  -- And one that has not.
  v_soon := public.create_withholding(v_bill, 'S109B_SPECIAL',
    p_gross_amount => 100000, p_cert_date => current_date);

  select * into r from public.report_withholding(v_org)
   where certificate_id = v_late;
  perform pg_temp.check_eq('ten per cent of the tax is at risk once it is late',
    r.penalty_if_unpaid, 1000);
  perform pg_temp.check_true('and it is counted as late',
    r.days_late > 0);

  select * into r from public.report_withholding(v_org)
   where certificate_id = v_soon;
  perform pg_temp.check_eq('nothing is at risk before the month is up',
    r.penalty_if_unpaid, 0);
  perform pg_temp.check_eq('and it is not late', r.days_late, 0);

  -- The form is the unit of work: CP37 and CP37A are filed separately,
  -- so the listing has to carry it.
  perform pg_temp.check_true('every line says which form it goes on',
    not exists (select 1 from public.report_withholding(v_org)
                 where form_code is null));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who can reach any of it
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('a stranger cannot withhold or remit',
    not has_function_privilege('anon',
      'public.create_withholding(uuid, text, numeric, numeric, date)', 'execute')
    and not has_function_privilege('anon', 'public.post_withholding(uuid)', 'execute')
    and not has_function_privilege('anon',
      'public.remit_withholding(uuid, date, uuid, text)', 'execute')
    and not has_function_privilege('anon',
      'public.report_withholding(uuid, date, date)', 'execute'));

  perform pg_temp.check_true('a member can',
    has_function_privilege('authenticated',
      'public.create_withholding(uuid, text, numeric, numeric, date)', 'execute')
    and has_function_privilege('authenticated',
      'public.post_withholding(uuid)', 'execute'));

  -- Certificates name a payee and an amount paid to them.
  perform pg_temp.check_true('the certificates are closed to anon',
    not has_table_privilege('anon', 'public.withholding_certificates', 'select'));
  perform pg_temp.check_true('and readable by members',
    has_table_privilege('authenticated',
      'public.withholding_certificates', 'select'));

  -- The rate table is reference data, and nobody signing in through the
  -- API should be able to edit what the Act says.
  perform pg_temp.check_true('the rates are readable but not writable',
    has_table_privilege('authenticated', 'public.ref_withholding_types', 'select')
    and not has_table_privilege('authenticated',
      'public.ref_withholding_types', 'update')
    and not has_table_privilege('anon',
      'public.ref_withholding_types', 'select'));
end $$;

rollback;
