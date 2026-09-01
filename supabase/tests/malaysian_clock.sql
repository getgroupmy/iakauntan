-- =====================================================================
-- Malaysian time, everywhere the clock is read
--
-- `0305` pinned one function to `Asia/Kuala_Lumpur` and `0419` pinned
-- the other eighteen. What is asserted here is not eighteen dates. It
-- is the two things that, together, make the defect impossible:
--
--   1. `app.today()` gives Malaysia's day, and gives the same one
--      whoever asks; and
--   2. no STABLE function in `public` or `app` asks anybody else.
--
-- ## Why the property and not the value
--
-- `supabase/tests/secretarial.sql` gives the long version, and it is
-- the reason this file exists at all. A test that compares UTC against
-- Kuala Lumpur can only fail during the eight hours they differ: green
-- every morning, red every afternoon. The first person to see it red
-- would call the suite flaky and the second would delete it.
--
-- So the clock assertions below run under two session time zones
-- twenty-six hours apart. `Pacific/Kiritimati` is UTC+14 and
-- `Etc/GMT+12` is UTC-12, so they are never on the same date, at any
-- instant, on any day of the year. Anything reading the session clock
-- answers differently in the two; anything pinned answers the same.
-- No window, no flake.
--
-- ## How the defect was found, and what it cost
--
-- `supabase/tests/vacancies.sql` dates a requisition forty-five days
-- before the Malaysian today and asserts the report says forty-five. At
-- 02:02 in Kuala Lumpur it said forty-four, because it was still the
-- previous day in London and the report was reading London's clock.
--
-- The permit fixture below is the same bug where it costs the most.
-- `report_expiring_documents` exists to tell an HR manager that a
-- foreign worker's permit has run out -- it says `offence` rather than
-- `permit`, in those words, because employing somebody on an expired
-- one is an offence. For the eight hours of the Malaysian morning, a
-- permit that expired last night was reported as expiring today and
-- still in order.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The helper itself
-- ---------------------------------------------------------------------
do $$
declare
  v_east date; v_west date;
  v_vol  "char";
begin
  begin
    set local time zone 'Pacific/Kiritimati';
    v_east := app.today();
    set local time zone 'Etc/GMT+12';
    v_west := app.today();
  end;
  reset time zone;

  perform pg_temp.check_true(
    'today does not depend on who is asking',
    v_east = v_west);

  -- The control for the assertion above. If both calls somehow returned
  -- null it would pass on nulls being equal -- which they are not in
  -- SQL, but the shape is worth closing anyway.
  perform pg_temp.check_true('and it returned a date at all',
    v_east is not null);

  -- Weaker than the property above, and kept for what the property
  -- cannot reach: pinning to the *wrong* zone passes a
  -- caller-independence test perfectly. This catches that whenever
  -- Malaysia and the session differ, which is most of the day but not
  -- all of it. `0305` made the same call, in the same words.
  perform pg_temp.check_eq('and it is Malaysia''s day',
    app.today()::text,
    (now() at time zone 'Asia/Kuala_Lumpur')::date::text);

  -- STABLE, not IMMUTABLE. An IMMUTABLE app.today() would be folded at
  -- plan time and a prepared statement or a cached plan would go on
  -- returning the day it was planned on -- a subtler version of the
  -- same defect, and one that would only show up after midnight.
  select p.provolatile into v_vol
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'today';
  perform pg_temp.check_eq('and it is stable rather than immutable',
    v_vol::text, 's');

  -- ------------------------------------------------------------------
  -- And its sibling, which takes the moment rather than assuming it
  -- ------------------------------------------------------------------
  -- A fixed instant, so this is a value assertion and not a property
  -- one: 2026-01-01T16:30Z is half past midnight on the 2nd in Kuala
  -- Lumpur and still the 1st in London. The whole defect, in one row.
  perform pg_temp.check_eq(
    'half past midnight in Kuala Lumpur is the second, not the first',
    app.malaysian_day(timestamptz '2026-01-01 16:30:00+00')::text,
    '2026-01-02');

  -- The plain cast is what four functions were doing, and it is only
  -- right when the session happens to be in Malaysia. Asserted under a
  -- zone that is not, so it says something.
  begin
    set local time zone 'Etc/UTC';
    perform pg_temp.check_eq(
      'which is not what casting it to a date gives you',
      (timestamptz '2026-01-01 16:30:00+00')::date::text, '2026-01-01');
    perform pg_temp.check_eq('while the helper is unmoved',
      app.malaysian_day(timestamptz '2026-01-01 16:30:00+00')::text,
      '2026-01-02');
  end;
  reset time zone;

  -- IMMUTABLE here, unlike app.today(): the answer depends only on the
  -- argument, so folding it at plan time is correct. Getting this the
  -- wrong way round in either direction is a defect -- an immutable
  -- today() caches yesterday, and a stable malaysian_day() gives up an
  -- index on an expression for nothing.
  select p.provolatile into v_vol
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'malaysian_day';
  perform pg_temp.check_eq('and it is immutable, which today() is not',
    v_vol::text, 'i');
end $$;

-- ---------------------------------------------------------------------
-- The permit that ran out last night
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Kilang Masa Sdn Bhd');
  v_emp   uuid;
  v_east  jsonb;
  v_west  jsonb;
  v_row   record;
begin
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, employment_status)
  values (v_org, 'E1', 'Encik Ravi', date '2020-01-01', 3000,
          date '1990-01-01', 'foreign_worker', 'active')
  returning id into v_emp;

  -- Yesterday in Kuala Lumpur. Between midnight and eight in the
  -- morning there, UTC still calls this today.
  insert into public.employee_documents
    (org_id, employee_id, doc_type, title, expires_date)
  values (v_org, v_emp, 'permit', 'Work Permit',
          (now() at time zone 'Asia/Kuala_Lumpur')::date - 1);

  begin
    set local time zone 'Pacific/Kiritimati';
    select jsonb_agg(jsonb_build_object(
             'days', d.days_until, 'expired', d.is_expired,
             'consequence', d.consequence) order by d.document_id)
      into v_east from public.report_expiring_documents(v_org, 60) d;

    set local time zone 'Etc/GMT+12';
    select jsonb_agg(jsonb_build_object(
             'days', d.days_until, 'expired', d.is_expired,
             'consequence', d.consequence) order by d.document_id)
      into v_west from public.report_expiring_documents(v_org, 60) d;
  end;
  reset time zone;

  -- The control. Without it the two could be equal as nulls and this
  -- block would assert that the report returns nothing.
  perform pg_temp.check_true(
    'the fixture put a permit in front of the report',
    v_east is not null and jsonb_array_length(v_east) = 1);

  perform pg_temp.check_true(
    'an expired permit is expired whoever is asking',
    v_east = v_west);

  -- And the answer is the Malaysian one, not either extreme's.
  select * into v_row from public.report_expiring_documents(v_org, 60);
  perform pg_temp.check_eq('the permit ran out yesterday',
    v_row.days_until, -1);
  perform pg_temp.check_true('so it is expired', v_row.is_expired);
  perform pg_temp.check_eq(
    'and employing him on it is an offence, in those words',
    v_row.consequence, 'offence');
end $$;

-- ---------------------------------------------------------------------
-- The mamak at half past midnight
--
-- `0420`'s story, asserted. A till rings up a sale at 00:30 in Kuala
-- Lumpur. On `current_date` the sale, the invoice raised from it, the
-- ledger entry behind it and the month in the invoice number were all
-- the previous day's -- every day, for the eight hours the session's
-- zone is behind Malaysia.
--
-- Two sales are completed here, one under each of the two zones
-- twenty-six hours apart. Everything dated must come out the same, and
-- must be Malaysia's day.
--
-- The date assertions are the ones that do the work: they separate a
-- pinned implementation from a session-clock one at every instant,
-- because the two zones are never on the same date.
--
-- The number assertions are weaker and are kept as a statement of what
-- the number should be rather than as a trap.
-- `app.next_document_number_internal` resets the counter when the
-- `YYYYMM` key changes, so under the defect the second sale would carry
-- a different month and restart the series at one -- but only on the
-- days when the two zones fall in different months, which is a day or so
-- either side of a month end. For the rest of the month both zones agree
-- about `YYYYMM` and these three assertions pass whether or not the
-- defect is present. Measured, not assumed: reverting
-- `app.next_document_number_internal` to `current_date` leaves them green
-- and is caught by the rule at the end of this file instead.
--
-- Making them sharp would mean waiting for a month boundary, which is
-- the flake `secretarial.sql` argues against at length. So the honest
-- arrangement is this one: the dates catch it always, the number says
-- what it should be, and the rule catches the function itself.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid := pg_temp.test_org('Mamak Tengah Malam Sdn Bhd');
  v_wh     uuid; v_walkin uuid; v_item uuid; v_outlet uuid; v_reg uuid;
  v_cash   uuid; v_shift uuid;
  v_s1     uuid; v_s2 uuid;
  v_d1     uuid; v_d2 uuid;
  v_no1    text; v_no2 text;
  v_dt1    date; v_dt2 date;
  v_gl1    date; v_gl2 date;
  v_today  date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  -- The period the sale will post into. Dated from the Malaysian year,
  -- because that is the day the posting will carry.
  perform public.create_fiscal_year(v_org, date_trunc('year', v_today)::date);

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Shop floor') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer')
  returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price)
  values (v_org, 'NASI', 'Nasi lemak', 'stock', false, 'C62', 5.00, 2.00)
  returning id into v_item;
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'SHOP', 'The shop', 'food_beverage', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Counter') returning id into v_reg;
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change)
  values (v_org, 'CASH', 'Cash', 'cash', '01', true, true)
  returning id into v_cash;

  -- Numbered by month rather than by year. `yearly` is the default and
  -- the defect shows there too -- one day a year instead of one day a
  -- month -- but a shop that numbers `INV-202609-0001` meets it twelve
  -- times over, and it is the case worth pinning.
  insert into public.number_sequences
    (org_id, doc_type, prefix, reset_policy)
  values (v_org, 'invoice', 'INV-', 'monthly');

  v_shift := public.open_pos_shift(v_reg, 100.00);

  -- Kiritimati is UTC+14 and Etc/GMT+12 is UTC-12: twenty-six hours
  -- apart, never on the same date.
  begin
    set local time zone 'Pacific/Kiritimati';
    v_s1 := public.open_pos_sale(v_reg);
    perform public.add_pos_sale_line(v_s1, v_item, 1, 5.00);
    perform public.complete_pos_sale(v_s1, jsonb_build_array(
      jsonb_build_object('type', v_cash, 'amount', 5.00)));

    set local time zone 'Etc/GMT+12';
    v_s2 := public.open_pos_sale(v_reg);
    perform public.add_pos_sale_line(v_s2, v_item, 1, 5.00);
    perform public.complete_pos_sale(v_s2, jsonb_build_array(
      jsonb_build_object('type', v_cash, 'amount', 5.00)));
  end;
  reset time zone;

  select s.invoice_id into v_d1 from public.pos_sales s where s.id = v_s1;
  select s.invoice_id into v_d2 from public.pos_sales s where s.id = v_s2;

  -- The control. Without it every comparison below is between two nulls.
  perform pg_temp.check_true('both sales raised an invoice',
    v_d1 is not null and v_d2 is not null and v_d1 <> v_d2);

  select d.doc_date, d.doc_no into v_dt1, v_no1
    from public.sales_documents d where d.id = v_d1;
  select d.doc_date, d.doc_no into v_dt2, v_no2
    from public.sales_documents d where d.id = v_d2;

  perform pg_temp.check_eq('the invoice is dated the same day either way',
    v_dt1::text, v_dt2::text);
  perform pg_temp.check_eq('and it is the day it is in Malaysia',
    v_dt1::text, v_today::text);

  select e.entry_date into v_gl1 from public.gl_entries e
   where e.id = (select gl_entry_id from public.sales_documents where id = v_d1);
  select e.entry_date into v_gl2 from public.gl_entries e
   where e.id = (select gl_entry_id from public.sales_documents where id = v_d2);
  perform pg_temp.check_true('the ledger entry exists to be dated',
    v_gl1 is not null);
  perform pg_temp.check_eq('the ledger agrees with the invoice',
    v_gl1::text, v_dt1::text);
  perform pg_temp.check_eq('whoever rang it up', v_gl2::text, v_gl1::text);

  -- The number carries the month, and both sales are in one series.
  -- See the note above: this separates the two implementations only
  -- near a month end.
  perform pg_temp.check_true(
    'both invoice numbers carry the Malaysian month',
    v_no1 like '%' || to_char(v_today, 'YYYYMM') || '%'
    and v_no2 like '%' || to_char(v_today, 'YYYYMM') || '%');
  perform pg_temp.check_true(
    'and the series ran on rather than starting again',
    v_no1 <> v_no2);
end $$;

-- ---------------------------------------------------------------------
-- The rule: nothing asks the session what day it is
--
-- This is what makes the next one loud. A new function that reaches for
-- `current_date` -- the obvious thing to reach for, and what all
-- sixty-one of them did -- turns this red before it reaches anybody's
-- screen.
--
-- `0419` scanned only the STABLE half and said the writers were a
-- separate migration: the date a posting carries runs into fiscal period
-- control and into document numbers already issued. `0420` to `0423` did
-- them and made both arguments explicitly, so the scan is now the whole
-- population and the rule is one sentence with nothing after it.
-- ---------------------------------------------------------------------
do $$
declare
  v_re    text := '(\mcurrent_date\M)|(\mlocaltimestamp\M)'
                  '|(\mcurrent_timestamp\M\s*::\s*date)'
                  '|(\mnow\M\s*\(\s*\)\s*::\s*date)';
  v_left  text[];
  v_seen  integer;
begin
  -- The pattern is asserted before it is trusted. A regex that matched
  -- nothing would pass the rule below by not doing anything, which is
  -- the failure mode a mechanical assertion has.
  perform pg_temp.check_true(
    'the pattern finds every way of asking the session what day it is',
    'select current_date + 1'          ~* v_re and
    'select localtimestamp'            ~* v_re and
    'select current_timestamp::date'   ~* v_re and
    'select now()::date'               ~* v_re and
    'select now() :: date'             ~* v_re);

  perform pg_temp.check_true(
    'and does not fire on the two correct ways of asking',
    'select app.today()' !~* v_re and
    'select (now() at time zone ''Asia/Kuala_Lumpur'')::date' !~* v_re);

  perform pg_temp.check_true(
    'nor on a column that merely starts the same way',
    'select current_date_of_birth from x' !~* v_re);

  -- The other half of the same worry: that the scan found no functions
  -- to look at. There are hundreds.
  select count(*) into v_seen
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app');
  perform pg_temp.check_true(
    'and there are functions to scan', v_seen > 100);

  select array_agg(n.nspname || '.' || p.proname order by 1)
    into v_left
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app')
     -- `0306` left the word in a comment in `module_dashboard`,
     -- explaining why it no longer reads it. That is not a defect.
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~* v_re;

  perform pg_temp.check_eq(
    'no function asks the caller what day it is',
    coalesce(array_to_string(v_left, ', '), ''), '');

  -- ------------------------------------------------------------------
  -- And none asks it what day a moment fell on
  -- ------------------------------------------------------------------
  -- `0424`'s half of the rule. Casting a `timestamptz` to `date` gives
  -- the day in the session's zone as surely as `current_date` does, and
  -- no regex over the text can see it -- it has to know which columns
  -- carry a zone, which means reading `information_schema`.
  select count(*) into v_seen
    from information_schema.columns
   where table_schema in ('public', 'app')
     and data_type = 'timestamp with time zone';
  perform pg_temp.check_true(
    'there are timestamptz columns to scan for', v_seen > 50);

  select array_agg(distinct f || ' (' || c || ')')
    into v_left
    from (
      select n.nspname || '.' || p.proname as f,
             regexp_replace(p.prosrc, '--[^\n]*', '', 'g') as src
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('public', 'app') and p.prokind in ('f', 'p')
    ) fn
    cross join (
      select distinct column_name as c
        from information_schema.columns
       where table_schema in ('public', 'app')
         and data_type = 'timestamp with time zone'
    ) tz
   where fn.src ~ ('\m' || tz.c || '\M\s*::\s*date');

  perform pg_temp.check_eq(
    'nor casts a moment to a day in the caller''s time zone',
    coalesce(array_to_string(v_left, ', '), ''), '');
end $$;

rollback;
