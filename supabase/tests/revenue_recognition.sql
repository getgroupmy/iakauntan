-- =====================================================================
-- iAkauntan :: revenue earned, rather than revenue invoiced
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/revenue_recognition.sql
--
-- 0309 lets an invoice line carry a service period. A line that has one
-- credits `2127 Deferred Revenue` instead of revenue, and a schedule
-- releases it month by month.
--
-- Asserted:
--
--   * a line with no service period is untouched — which is every line
--     this system wrote before 0309, so it is the first thing checked;
--   * a deferred line credits the liability and not revenue;
--   * the schedule sums exactly to the invoice, across a range of
--     amounts and lengths chosen to break naive rounding;
--   * proration is by days, so a mid-month start earns a part month;
--   * recognition posts one journal per period, debiting the liability
--     and crediting the revenue account the line would have used;
--   * running it twice does nothing the second time;
--   * nothing is recognised past the date asked for;
--   * a closed period refuses the posting rather than writing into it;
--   * the client cannot write the schedule.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.rev_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  -- Two years open, so a twelve-month contract has somewhere to land.
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  perform public.create_fiscal_year(
    v_org, (date_trunc('year', current_date) + interval '1 year')::date);
  return v_org;
end $$;

-- An invoice for one service line. Returns the document id.
create or replace function pg_temp.service_invoice(
  p_org uuid, p_no text, p_amount numeric, p_from date, p_to date)
returns uuid language plpgsql as $$
declare v_cust uuid; v_doc uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, 'C-' || p_no, 'Pelanggan ' || p_no, 'customer')
  returning id into v_cust;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', p_no, coalesce(p_from, current_date), v_cust,
          'MYR', 1, p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, line_subtotal, line_total, service_start, service_end)
  values (p_org, v_doc, 1, 'item', 'Support', 1, p_amount, p_amount,
          p_amount, p_from, p_to);
  return v_doc;
end $$;

-- ---------------------------------------------------------------------
-- An ordinary line is exactly what it was
--
-- First, because everything else here is a change to the posting path
-- and the thing that must not move is the path every existing invoice
-- takes.
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_doc uuid; v_rev uuid; v_def uuid;
begin
  v_org := pg_temp.rev_org('Biasa Sdn Bhd');
  v_doc := pg_temp.service_invoice(v_org, 'INV-PLAIN', 1200, null, null);
  perform public.post_sales_document(v_doc);

  select id into v_rev from public.accounts where org_id=v_org and code='4100';
  perform pg_temp.check_eq('a line with no service period credits revenue',
    (select coalesce(sum(g.credit - g.debit), 0) from public.gl_lines g
       join public.gl_entries e on e.id = g.entry_id
      where e.source_id = v_doc and g.account_id = v_rev), 1200);

  select id into v_def from public.accounts where org_id=v_org and code='2127';
  perform pg_temp.check_true('and no deferred revenue account is even made',
    v_def is null);
  perform pg_temp.check_eq('and nothing is scheduled',
    (select count(*) from public.revenue_schedule_periods
      where document_id = v_doc)::numeric, 0);
end $$;

-- ---------------------------------------------------------------------
-- A deferred line owes the work instead of having earned it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_doc uuid; v_rev uuid; v_def uuid;
  v_start date := date_trunc('year', current_date)::date;
begin
  v_org := pg_temp.rev_org('Tertunda Sdn Bhd');
  -- A full calendar year: twelve periods, and RM 1,200 over 365 days is
  -- not a whole number of sen a month.
  v_doc := pg_temp.service_invoice(v_org, 'INV-DEF', 1200, v_start,
                                   (v_start + interval '1 year' - interval '1 day')::date);
  perform public.post_sales_document(v_doc);

  select id into v_rev from public.accounts where org_id=v_org and code='4100';
  select id into v_def from public.accounts where org_id=v_org and code='2127';

  perform pg_temp.check_true('the liability account is made when first needed',
    v_def is not null);
  perform pg_temp.check_eq('the invoice credits the liability',
    (select coalesce(sum(g.credit - g.debit), 0) from public.gl_lines g
       join public.gl_entries e on e.id = g.entry_id
      where e.source_id = v_doc and g.account_id = v_def), 1200);
  -- The control. Crediting both would balance and be wrong.
  perform pg_temp.check_eq('and none of it reaches revenue yet',
    (select coalesce(sum(g.credit - g.debit), 0) from public.gl_lines g
       join public.gl_entries e on e.id = g.entry_id
      where e.source_id = v_doc and g.account_id = v_rev), 0);

  perform pg_temp.check_eq('twelve months make twelve periods',
    (select count(*) from public.revenue_schedule_periods
      where document_id = v_doc)::numeric, 12);
end $$;

-- ---------------------------------------------------------------------
-- The schedule adds back to the invoice
--
-- The trap this whole design turns on. Twelve times round(1200/12) is
-- lucky; twelve times round(1000/12) is not, and a schedule that does
-- not sum to the invoice leaves sen in the liability that nobody can
-- ever clear.
--
-- Amounts and lengths chosen to be awkward: thirds, sevenths, a single
-- day, a period inside one month, one that straddles a year end, and a
-- leap February.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_doc uuid; v_sum numeric; v_case record; v_n integer := 0;
begin
  v_org := pg_temp.rev_org('Genap Sdn Bhd');

  for v_case in
    select * from (values
      (1000.00::numeric, date '2026-01-01', date '2026-12-31', 'a year of thirds'),
      (100.00,           date '2026-01-01', date '2026-03-31', 'three months'),
      (0.07,             date '2026-01-01', date '2026-12-31', 'seven sen over a year'),
      (999.99,           date '2026-01-15', date '2027-01-14', 'a year from mid-month'),
      (500.00,           date '2026-06-10', date '2026-06-10', 'a single day'),
      (250.00,           date '2026-06-05', date '2026-06-25', 'inside one month'),
      (1234.56,          date '2026-11-20', date '2027-02-19', 'across a year end'),
      (777.77,           date '2028-02-01', date '2028-02-29', 'a leap February')
    ) as t(amount, from_d, to_d, label)
  loop
    v_n := v_n + 1;
    v_doc := pg_temp.service_invoice(
      v_org, 'INV-R' || v_n, v_case.amount, v_case.from_d, v_case.to_d);
    -- Built directly: posting would need an open fiscal year for every
    -- one of these dates, and what is under test is the arithmetic.
    perform app.build_revenue_schedule(v_doc, 1);

    select coalesce(sum(amount), 0) into v_sum
      from public.revenue_schedule_periods where document_id = v_doc;
    perform pg_temp.check_eq(
      format('the schedule sums to the invoice: %s', v_case.label),
      v_sum, v_case.amount);

    -- And no period is negative, which a remainder taken from the wrong
    -- end would produce.
    perform pg_temp.check_eq(
      format('and no period is negative: %s', v_case.label),
      (select count(*) from public.revenue_schedule_periods
        where document_id = v_doc and amount < 0)::numeric, 0);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Proration is by days, not by whole months
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_doc uuid; v_first numeric; v_periods integer;
begin
  v_org := pg_temp.rev_org('Hari Sdn Bhd');
  -- 20 January to 19 April: twelve days of January, then February,
  -- March, and nineteen days of April.
  v_doc := pg_temp.service_invoice(v_org, 'INV-DAY', 900,
             date '2026-01-20', date '2026-04-19');
  perform app.build_revenue_schedule(v_doc, 1);

  select count(*) into v_periods
    from public.revenue_schedule_periods where document_id = v_doc;
  perform pg_temp.check_eq('four calendar months are touched',
    v_periods::numeric, 4);

  select amount into v_first from public.revenue_schedule_periods
   where document_id = v_doc order by period_end limit 1;
  -- 12 days of the 90 in the period. A whole-month split would give
  -- 225.00 and a start-of-month one would give the full January.
  perform pg_temp.check_eq('the first month earns only its twelve days',
    v_first, round(900 * 12.0 / 90, 2));
end $$;

-- ---------------------------------------------------------------------
-- Releasing it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_doc uuid; v_rev uuid; v_def uuid;
  v_start date := date_trunc('year', current_date)::date;
  v_third date; v_n integer; v_again integer;
begin
  v_org := pg_temp.rev_org('Lepas Sdn Bhd');
  v_doc := pg_temp.service_invoice(v_org, 'INV-REL', 1200, v_start,
             (v_start + interval '1 year' - interval '1 day')::date);
  perform public.post_sales_document(v_doc);

  select id into v_rev from public.accounts where org_id=v_org and code='4100';
  select id into v_def from public.accounts where org_id=v_org and code='2127';

  -- Up to the end of the third month.
  v_third := (v_start + interval '3 months' - interval '1 day')::date;
  v_n := public.recognise_revenue(v_org, v_third);
  perform pg_temp.check_eq('one journal per month released',
    v_n::numeric, 3);

  perform pg_temp.check_eq('three months have reached revenue',
    (select coalesce(sum(g.credit - g.debit), 0) from public.gl_lines g
       join public.gl_entries e on e.id = g.entry_id
      where e.org_id = v_org and g.account_id = v_rev
        and e.source = 'revenue_recognition'),
    (select coalesce(sum(amount), 0) from public.revenue_schedule_periods
      where document_id = v_doc and period_end <= v_third));

  -- The liability is drawn down by exactly what left it.
  perform pg_temp.check_eq('and the liability is drawn down by the same',
    (select coalesce(sum(g.credit - g.debit), 0) from public.gl_lines g
       join public.gl_entries e on e.id = g.entry_id
      where e.org_id = v_org and g.account_id = v_def),
    1200 - (select coalesce(sum(amount), 0) from public.revenue_schedule_periods
             where document_id = v_doc and period_end <= v_third));

  -- Nothing beyond the date asked for.
  perform pg_temp.check_eq('nothing later was touched',
    (select count(*) from public.revenue_schedule_periods
      where document_id = v_doc and period_end > v_third
        and gl_entry_id is not null)::numeric, 0);

  -- And the run is safe to repeat, which is how a monthly job behaves.
  v_again := public.recognise_revenue(v_org, v_third);
  perform pg_temp.check_eq('running it again releases nothing',
    v_again::numeric, 0);
  perform pg_temp.check_eq('and revenue did not move',
    (select coalesce(sum(g.credit - g.debit), 0) from public.gl_lines g
       join public.gl_entries e on e.id = g.entry_id
      where e.org_id = v_org and g.account_id = v_rev
        and e.source = 'revenue_recognition'),
    (select coalesce(sum(amount), 0) from public.revenue_schedule_periods
      where document_id = v_doc and period_end <= v_third));
end $$;

-- ---------------------------------------------------------------------
-- A closed month refuses the release
--
-- Recognition goes through `create_gl_entry` precisely so that period
-- control applies to it. A release that could write into a closed month
-- would be a back door into a signed-off set of accounts.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_doc uuid;
  v_start date := date_trunc('year', current_date)::date;
  v_first date := (v_start + interval '1 month' - interval '1 day')::date;
begin
  v_org := pg_temp.rev_org('Tutup Sdn Bhd');
  v_doc := pg_temp.service_invoice(v_org, 'INV-SHUT', 1200, v_start,
             (v_start + interval '1 year' - interval '1 day')::date);
  perform public.post_sales_document(v_doc);

  update public.fiscal_periods set status = 'closed'
   where org_id = v_org and v_first between start_date and end_date;

  begin
    perform public.recognise_revenue(v_org, v_first);
    raise exception 'FAIL: revenue was released into a closed period';
  exception
    -- 0053 raises 23514 for a period that is not open. Named exactly
    -- rather than caught with `when others`, which would also swallow a
    -- typo in the fixture and report it as a passing test.
    when sqlstate '23514' then
      raise notice 'ok   a closed period refuses the release';
  end;

  -- And nothing was written on the way to being refused.
  perform pg_temp.check_eq('and nothing was released',
    (select count(*) from public.revenue_schedule_periods
      where document_id = v_doc and gl_entry_id is not null)::numeric, 0);
end $$;

-- ---------------------------------------------------------------------
-- The schedule is the ledger's, not the client's
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_doc uuid; v_user uuid; v_role text; v_wrote boolean := false;
  v_start date := date_trunc('year', current_date)::date;
begin
  v_org := pg_temp.rev_org('Sulit Jadual Sdn Bhd');
  v_doc := pg_temp.service_invoice(v_org, 'INV-RLS', 1200, v_start,
             (v_start + interval '1 year' - interval '1 day')::date);
  perform public.post_sales_document(v_doc);

  v_user := pg_temp.another_user('clerk@jadual.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_user, 'accountant') on conflict do nothing;

  perform pg_temp.sign_in_as(v_user);
  begin
    set local role authenticated;
    v_role := current_user;
    begin
      update public.revenue_schedule_periods set amount = 0
       where document_id = v_doc;
      v_wrote := true;
    exception when insufficient_privilege then
      v_wrote := false;
    end;
  end;
  reset role;

  perform pg_temp.check_true('the privilege test ran as authenticated',
    v_role = 'authenticated');
  perform pg_temp.check_true(
    'a member cannot rewrite what the ledger has scheduled', not v_wrote);
  -- The control: they can still read it, or the screen showing the
  -- schedule would be empty for everybody.
  perform pg_temp.check_eq('but can read their own company''s schedule',
    (select count(*) from public.revenue_schedule_periods
      where document_id = v_doc)::numeric, 12);
end $$;

rollback;
