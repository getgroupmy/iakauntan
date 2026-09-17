-- =====================================================================
-- iAkauntan :: two months, and the month after
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sst_taxable_period.sql
--
-- Before 0455 this schema knew a company was SST-registered and knew
-- what every line was taxed at, and offered `report_sst_summary(org,
-- from, to)` -- any two dates somebody types. There was no taxable
-- period, no return and no deadline.
--
-- SST-02 is bi-monthly, which is a rhythm nobody keeps in their head,
-- and it is late the day after the deadline. So the dates below are
-- asserted one at a time rather than summarised: a cycle that is right
-- for four periods and wrong for the fifth is the failure this is for.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A registered company, since registering is a four-part act that
-- `app.guard_sst_registration` will not let a test fake with an update.
create or replace function pg_temp.sst_org(p_name text, p_from date)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'ST8', 'Service Tax 8%', '02', 8,
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'));
  perform public.set_sst_registration(
    v_org, true, p_from, 'W10-1808-31000455', 'ST8');
  return v_org;
end;
$$;

-- ---------------------------------------------------------------------
-- The cycle is decided by when the company registered
--
-- The first taxable period runs from the day of registration to the
-- last day of the *following* month; every period after it is two
-- months. So there is nothing to choose and nothing to type, and a
-- company registered on 15 April is on the odd-month cycle for good.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  r     record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.sst_org('SST Empat Belas Sdn Bhd', date '2026-04-15');

  select * into r from app.sst_period_for(v_org, date '2026-04-15');
  perform pg_temp.check_eq('the first period starts the day one registers',
    r.period_start::text, '2026-04-15');
  perform pg_temp.check_eq('and ends with the month after that',
    r.period_end::text, '2026-05-31');
  perform pg_temp.check_true('and it is the first', r.is_first);

  -- The deadline: the last day of the month following the period.
  perform pg_temp.check_eq('the return is due a month after the period',
    r.due_date::text, '2026-06-30');

  select * into r from app.sst_period_for(v_org, date '2026-05-31');
  perform pg_temp.check_eq('the last day of a period is still in it',
    r.period_end::text, '2026-05-31');

  select * into r from app.sst_period_for(v_org, date '2026-06-01');
  perform pg_temp.check_eq('the next day is in the next one',
    r.period_start::text, '2026-06-01');
  perform pg_temp.check_eq('which runs two whole months',
    r.period_end::text, '2026-07-31');
  perform pg_temp.check_true('and is not the first', not r.is_first);

  -- Over the year end, where an off-by-one would go unnoticed for a
  -- year: December and January are one period, and its return is due
  -- on the last day of February.
  select * into r from app.sst_period_for(v_org, date '2027-01-15');
  perform pg_temp.check_eq('a period may straddle the year end',
    r.period_start::text, '2026-12-01');
  perform pg_temp.check_eq('ending in January',
    r.period_end::text, '2027-01-31');
  perform pg_temp.check_eq('due at the end of February, whatever that is',
    r.due_date::text, '2027-02-28');

  -- Before registration there is no period, because there is nothing
  -- to declare. Not period zero, and not an error.
  perform pg_temp.check_eq('before registering there is no period',
    (select count(*)::integer
       from app.sst_period_for(v_org, date '2026-04-01')), 0);
end $$;

-- ---------------------------------------------------------------------
-- The other alignment
--
-- A company that registered a month later is on the other cycle for
-- good, and the two never coincide. This is the assertion that would
-- catch a cycle pinned to the calendar rather than to the company.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  r     record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.sst_org('SST Sebulan Lagi Sdn Bhd', date '2026-05-20');

  select * into r from app.sst_period_for(v_org, date '2026-05-20');
  perform pg_temp.check_eq('registering in May ends the first period in June',
    r.period_end::text, '2026-06-30');

  select * into r from app.sst_period_for(v_org, date '2026-08-15');
  perform pg_temp.check_eq('so August falls in July-August',
    r.period_start::text, '2026-07-01');
  perform pg_temp.check_eq('not in August-September',
    r.period_end::text, '2026-08-31');
end $$;

-- ---------------------------------------------------------------------
-- Monthly, for somebody the Director General approved for it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  r     record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.sst_org('SST Sebulan Sdn Bhd', date '2026-04-15');
  update public.organizations set sst_period_months = 1 where id = v_org;

  select * into r from app.sst_period_for(v_org, date '2026-04-20');
  perform pg_temp.check_eq('a monthly filer''s first period starts at once',
    r.period_start::text, '2026-04-15');
  perform pg_temp.check_eq('and ends with the month',
    r.period_end::text, '2026-04-30');
  perform pg_temp.check_eq('due at the end of the month after',
    r.due_date::text, '2026-05-31');

  select * into r from app.sst_period_for(v_org, date '2026-06-10');
  perform pg_temp.check_eq('and later months are whole months',
    r.period_start::text, '2026-06-01');

  -- Three months and thirteen months are not taxable periods.
  perform pg_temp.check_true('and no other length is a taxable period',
    exists (select 1 from pg_constraint
             where conname = 'sst_period_months_is_one_or_two'));
end $$;

-- ---------------------------------------------------------------------
-- Which period an invoice's tax lands in
--
-- Sales tax here, deliberately. Sales tax is due when the goods are
-- sold, so the document date decides it and these assertions are about
-- the period boundary. **Service tax is due when the money arrives**
-- and is asserted in `service_tax_on_payment.sql` -- 0456 -- because a
-- service-tax invoice with nothing paid against it belongs in no
-- period at all.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_cust uuid;
  v_tax  uuid;
  v_doc  uuid;
  r      record;

  procedure_placeholder boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.sst_org('SST Invois Sdn Bhd', date '2026-04-15');
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'SL10', 'Sales Tax 10%', '01', 10,
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'))
  returning id into v_tax;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan', 'customer')
  returning id into v_cust;

  -- One invoice on the last day of a period and one on the first day
  -- of the next. A boundary that is off by a day puts both in the same
  -- return, and the company underdeclares one period and overdeclares
  -- the other.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-SST-1', date '2026-07-31', v_cust, 'MYR',
          1, 'posted')
  returning id into v_doc;
  -- `app.calc_document_line` works the tax out from the line's own
  -- `tax_rate`, not from the code's -- a rate that moved would
  -- otherwise restate every invoice ever issued -- so the rate goes on
  -- the line the way the editor puts it there.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate)
  values (v_org, v_doc, 1, 'Barang Julai', 1, 1000, v_tax, 8);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-SST-2', date '2026-08-01', v_cust, 'MYR',
          1, 'posted')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate)
  values (v_org, v_doc, 1, 'Barang Ogos', 1, 5000, v_tax, 8);

  select * into r from public.sst_taxable_periods(v_org)
   where period_end = date '2026-07-31';
  perform pg_temp.check_eq('the July invoice is in the June-July return',
    r.output_tax, 80);

  select * into r from public.sst_taxable_periods(v_org)
   where period_end = date '2026-09-30';
  perform pg_temp.check_eq('and the August one is in the next',
    r.output_tax, 400);

  -- SST has no input tax credit. A bill the company paid tax on is a
  -- cost, not a deduction from what it owes -- netting it off would
  -- compute a refund nobody is entitled to.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-SST-1', date '2026-08-10', v_cust, 'MYR',
          1, 'posted')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate)
  values (v_org, v_doc, 1, 'Barang dibeli', 1, 2000, v_tax, 8);

  select * into r from public.sst_taxable_periods(v_org)
   where period_end = date '2026-09-30';
  perform pg_temp.check_eq(
    'and tax the company paid its own suppliers is not deducted',
    r.output_tax, 400);
end $$;

-- ---------------------------------------------------------------------
-- Filing one, and what is left owing
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_end   date;
  v_took  boolean;
  v_n     integer;
  r       record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  -- Registered fourteen months ago, so at least one period is long
  -- past its deadline and unfiled.
  v_org := pg_temp.sst_org('SST Lewat Sdn Bhd',
                           (app.today() - interval '14 months')::date);

  select p.period_end into v_end from public.sst_taxable_periods(v_org) p
   where p.period_end < app.today() order by p.period_end limit 1;
  perform pg_temp.check_true('there is a finished period to file', v_end is not null);

  -- A date that is not the end of a period is refused, rather than
  -- filed against whatever period contains it: a return filed for the
  -- wrong period is worse than one not filed at all.
  begin
    perform public.file_sst_return(v_org, v_end - 1, 100);
    v_took := true;
  exception when sqlstate '22007' then v_took := false;
  end;
  perform pg_temp.check_true(
    'a return can only be filed for a whole period', not v_took);

  -- Nor before the period has finished, when what was charged in it is
  -- still being decided.
  begin
    perform public.file_sst_return(
      v_org,
      (select p.period_end from public.sst_taxable_periods(v_org) p
        where p.period_end >= app.today() order by p.period_end limit 1),
      100);
    v_took := true;
  exception when sqlstate '22007' then v_took := false;
  end;
  perform pg_temp.check_true('nor before the period has ended', not v_took);

  select count(*)::integer into v_n from public.report_sst_due(v_org, 3650);
  perform pg_temp.check_true('an unfiled period is chased', v_n > 0);

  perform pg_temp.check_true('and named as overdue once the day has passed',
    exists (select 1 from public.report_sst_due(v_org, 3650) d
             where d.is_overdue));

  perform public.file_sst_return(v_org, v_end, 1234.50, 'SST-02/0001');

  perform pg_temp.check_eq('filing records what was declared',
    (select tax_declared from public.sst_returns
      where org_id = v_org and period_end = v_end), 1234.50);
  perform pg_temp.check_eq('and who filed it',
    (select filed_by from public.sst_returns
      where org_id = v_org and period_end = v_end), pg_temp.test_user());

  perform pg_temp.check_true('and it stops being chased',
    not exists (select 1 from public.report_sst_due(v_org, 3650) d
                 where d.period_end = v_end));

  select * into r from public.sst_taxable_periods(v_org)
   where period_end = v_end;
  perform pg_temp.check_eq('the reference is kept', r.reference, 'SST-02/0001');
end $$;

-- ---------------------------------------------------------------------
-- Who may do any of this
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_clerk uuid;
  v_end   date;
  v_took  boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.sst_org('SST Kebenaran Sdn Bhd',
                           (app.today() - interval '14 months')::date);
  select p.period_end into v_end from public.sst_taxable_periods(v_org) p
   where p.period_end < app.today() order by p.period_end limit 1;

  v_clerk := pg_temp.another_user('viewer-0455@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'viewer', 'active', now());

  perform pg_temp.sign_in_as(v_clerk);

  -- A viewer may read the periods: knowing when the return is due is
  -- not a privilege.
  perform pg_temp.check_true('anybody in the company can see what is due',
    exists (select 1 from public.sst_taxable_periods(v_org)));

  -- Filing one is a statement to the Customs Department about what the
  -- company owes, so it takes the same hand that posts the books.
  begin
    perform public.file_sst_return(v_org, v_end, 1);
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true('but not everybody can file it', not v_took);

  -- And a stranger sees nothing at all.
  perform pg_temp.sign_in_as(pg_temp.another_user('nobody-0455@iakauntan.test'));
  begin
    perform * from public.sst_taxable_periods(v_org);
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true(
    'and somebody outside the company sees none of it', not v_took);
end $$;

rollback;
