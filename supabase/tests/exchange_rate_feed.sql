-- =====================================================================
-- iAkauntan :: the published exchange rate feed
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/exchange_rate_feed.sql
--
-- Two things are being asserted here and they fail in different ways.
--
-- The arithmetic: Bank Negara quotes the yen per hundred, and a rate
-- divided by the wrong number is wrong by a factor of a hundred while
-- still balancing, still footing, and still looking like a rate. That
-- division is in SQL rather than in the edge function precisely so this
-- file can run it.
--
-- The precedence: a rate somebody typed may already have priced a posted
-- document, and a nightly job that could move it would be rewriting
-- history. The feed must never touch an organization's own row, and the
-- organization's row must win wherever both exist for a date.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- An org with a fiscal year, in ringgit, which is what a feed quoting in
-- ringgit is any use to.
create or replace function pg_temp.rate_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

-- One published quote, shaped the way the feed hands them over.
create or replace function pg_temp.quote(
  p_code text, p_unit numeric, p_rate numeric, p_on date)
returns jsonb language sql immutable as $$
  select jsonb_build_object('currency_code', p_code, 'unit', p_unit,
                            'rate', p_rate, 'rate_date', p_on);
$$;

-- ---------------------------------------------------------------------
-- The unit divisor
--
-- The single most consequential line in the migration.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rate_org('Unit Divisor Sdn Bhd');
  r record;
begin
  perform public.ingest_exchange_rates(jsonb_build_array(
    pg_temp.quote('USD',   1, 4.2010,  date '2026-03-31'),
    pg_temp.quote('JPY', 100, 2.8500,  date '2026-03-31'),
    pg_temp.quote('IDR', 100, 0.02580, date '2026-03-31')));

  perform pg_temp.check_eq('a rate quoted per unit is stored as it came',
    app.exchange_rate_for(v_org, 'USD', date '2026-03-31'), 4.20100000);

  -- 2.85 ringgit per *hundred* yen is not 2.85 ringgit per yen. Store it
  -- undivided and a JPY 1,000,000 invoice posts at RM 2,850,000 instead
  -- of RM 28,500 — a figure that balances and would pass every other
  -- check in this system.
  perform pg_temp.check_eq('and one quoted per hundred is divided by a hundred',
    app.exchange_rate_for(v_org, 'JPY', date '2026-03-31'), 0.02850000);

  perform pg_temp.check_eq('however small the result',
    app.exchange_rate_for(v_org, 'IDR', date '2026-03-31'), 0.00025800);

  -- And the verdict says so, because somebody reading the log of a run
  -- should be able to see that a division happened.
  select * into r from public.ingest_exchange_rates(
    jsonb_build_array(pg_temp.quote('JPY', 100, 2.8500, date '2026-03-31')));
  perform pg_temp.check_true('the verdict names the divisor',
    r.message like '%per 100 units%');
  perform pg_temp.check_true('and carries the rate that was stored',
    r.applied_rate = 0.02850000 and r.status = 'stored');
end $$;

-- ---------------------------------------------------------------------
-- Whose rate wins
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rate_org('Precedence Sdn Bhd');
  v_other uuid := pg_temp.rate_org('Somebody Else Sdn Bhd');
begin
  -- A rate this organization typed for the 1st.
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org, 'USD', 'MYR', 4.70, date '2026-03-01', 'manual');

  perform public.ingest_exchange_rates(jsonb_build_array(
    pg_temp.quote('USD', 1, 4.9000, date '2026-03-01'),
    pg_temp.quote('USD', 1, 4.2000, date '2026-03-15')));

  -- Same date, both exist: theirs.
  perform pg_temp.check_eq('a typed rate beats a published one for its own date',
    app.exchange_rate_for(v_org, 'USD', date '2026-03-01'), 4.70000000);

  -- Later date, only the feed has one: the feed's. A rate typed on the
  -- 1st says what the rate was on the 1st. It does not say that the 1st
  -- should still be governing a document dated a fortnight later.
  perform pg_temp.check_eq('a later published rate beats an earlier typed one',
    app.exchange_rate_for(v_org, 'USD', date '2026-03-20'), 4.20000000);

  -- The organization's own row is untouched by any of it.
  perform pg_temp.check_eq('and the typed row is still exactly as typed',
    (select rate from public.exchange_rates
      where org_id = v_org and rate_date = date '2026-03-01'), 4.70000000);
  perform pg_temp.check_eq('with nothing else added to that org',
    (select count(*) from public.exchange_rates where org_id = v_org), 1);

  -- An organization that has typed nothing gets the published rates,
  -- which is the entire point: this is the org that could not revalue.
  perform pg_temp.check_eq('an org with no rates of its own uses the published one',
    app.exchange_rate_for(v_other, 'USD', date '2026-03-20'), 4.20000000);

  -- Still refused when nobody has priced the currency at all.
  begin
    perform app.exchange_rate_for(v_org, 'EUR', date '2026-03-20');
    raise exception 'FAIL: priced a currency with no rate anywhere';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a currency neither party has priced is still refused';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Running it twice
--
-- A feed publishes on business days and a scheduler runs every day, so
-- the same quote arrives again and again. The table's own unique
-- constraint does not stop it — in a UNIQUE constraint two NULLs are
-- distinct — which is what the partial index in 0104 is for.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rate_org('Idempotent Sdn Bhd');
begin
  perform public.ingest_exchange_rates(jsonb_build_array(
    pg_temp.quote('SGD', 1, 3.1000, date '2026-03-31')));
  perform public.ingest_exchange_rates(jsonb_build_array(
    pg_temp.quote('SGD', 1, 3.1000, date '2026-03-31')));
  perform public.ingest_exchange_rates(jsonb_build_array(
    pg_temp.quote('SGD', 1, 3.1500, date '2026-03-31')));

  perform pg_temp.check_eq('three runs leave one row',
    (select count(*) from public.exchange_rates
      where org_id is null and from_currency = 'SGD'
        and rate_date = date '2026-03-31'), 1);

  -- A correction republished on the same day is taken. The alternative
  -- is holding a figure the publisher has withdrawn.
  perform pg_temp.check_eq('and it holds the figure most recently published',
    app.exchange_rate_for(v_org, 'SGD', date '2026-03-31'), 3.15000000);
end $$;

-- ---------------------------------------------------------------------
-- A bad row does not take the batch with it
--
-- Unlike the CSV importers, which refuse a whole file. A central bank
-- dropping one currency is not a reason to discard the other twenty, and
-- each rate stands alone in a way the rows of an import do not.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rate_org('Partial Batch Sdn Bhd');
  v_stored integer; v_skipped integer; v_error integer;
begin
  select count(*) filter (where status = 'stored'),
         count(*) filter (where status = 'skipped'),
         count(*) filter (where status = 'error')
    into v_stored, v_skipped, v_error
    from public.ingest_exchange_rates(jsonb_build_array(
      pg_temp.quote('GBP',   1, 5.4000, date '2026-03-31'),  -- good
      pg_temp.quote('XYZ',   1, 1.0000, date '2026-03-31'),  -- not ours
      pg_temp.quote('MYR',   1, 1.0000, date '2026-03-31'),  -- itself
      pg_temp.quote('AUD',   0, 2.7000, date '2026-03-31'),  -- no divisor
      pg_temp.quote('CHF', null, 4.6000, date '2026-03-31'), -- no unit
      pg_temp.quote('CAD',   1, 0.0000, date '2026-03-31'),  -- not a rate
      pg_temp.quote('SGDX',  1, 3.1000, date '2026-03-31'),  -- not a code
      pg_temp.quote('HKD',   1, 0.5400, date '2026-03-31'))); -- good

  perform pg_temp.check_eq('the good ones are stored', v_stored, 2);
  perform pg_temp.check_eq('the unknown and the self-quote are skipped', v_skipped, 2);
  perform pg_temp.check_eq('and the malformed are errors', v_error, 4);

  perform pg_temp.check_eq('the good rates really did land',
    app.exchange_rate_for(v_org, 'HKD', date '2026-03-31'), 0.54000000);

  -- A missing unit is refused rather than assumed to be 1. A feed that
  -- has stopped sending it is a feed whose shape has changed underneath
  -- us, and guessing is how the yen ends up wrong by a hundred.
  perform pg_temp.check_eq('nothing was stored for the currency with no unit',
    (select count(*) from public.exchange_rates
      where org_id is null and from_currency = 'CHF'), 0);
end $$;

-- ---------------------------------------------------------------------
-- What the ingest refuses outright
-- ---------------------------------------------------------------------
do $$
begin
  begin
    perform public.ingest_exchange_rates(
      jsonb_build_array(pg_temp.quote('USD', 1, 4.2, date '2026-03-31')), 'manual');
    raise exception 'FAIL: a fetched rate was allowed to call itself manual';
  exception when sqlstate '23514' then
    raise notice 'ok   a fetched rate cannot be passed off as typed';
  end;

  begin
    perform public.ingest_exchange_rates('{"currency_code":"USD"}'::jsonb);
    raise exception 'FAIL: took a single object as a batch';
  exception when sqlstate '22023' then
    raise notice 'ok   rates have to arrive as a list';
  end;

  begin
    perform public.ingest_exchange_rates('[]'::jsonb, 'bnm', 'ZZZ');
    raise exception 'FAIL: quoted against a currency that does not exist';
  exception when sqlstate '23503' then
    raise notice 'ok   the quote currency has to be one this system holds';
  end;

  perform pg_temp.check_eq('an empty batch is not an error',
    (select count(*) from public.ingest_exchange_rates('[]'::jsonb)), 0);
end $$;

-- ---------------------------------------------------------------------
-- It reaches the ledger
--
-- The reason any of this was built. Before 0104 an organization that had
-- typed no rates could not revalue at all: `revalue_foreign_balances`
-- raises P0002 rather than assuming par, so the safety check and the
-- empty table together meant month end quietly did not happen.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rate_org('Revalues From Feed Sdn Bhd');
  v_cust uuid; v_doc uuid; v_entry uuid; v_ar uuid; v_loss uuid;
begin
  -- Only published rates. Nobody at this company has typed one.
  perform public.ingest_exchange_rates(jsonb_build_array(
    pg_temp.quote('USD', 1, 4.7000, date '2026-03-01'),
    pg_temp.quote('USD', 1, 4.2000, date '2026-03-31')));

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-USD', 'US Buyer', 'customer') returning id into v_cust;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org, 'invoice', 'INV-FEED', date '2026-03-01', v_cust, 'USD',
          public.exchange_rate_for(v_org, 'USD', date '2026-03-01'),
          10000, 10000, 10000, 'draft')
  returning id into v_doc;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_doc, 1, 'Export sale', 1, 10000);

  perform public.post_sales_document(v_doc);

  perform pg_temp.check_eq('the invoice was priced off the published rate',
    (select exchange_rate from public.sales_documents where id = v_doc), 4.70000000);

  select id into v_ar   from public.accounts where org_id = v_org and code = '1210';
  select id into v_loss from public.accounts where org_id = v_org and code = '6500';

  v_entry := public.revalue_foreign_balances(v_org, date '2026-03-31');
  perform pg_temp.check_true('and month end can now run at all', v_entry is not null);

  perform pg_temp.check_eq('receivables written down to the closing rate',
    (select coalesce(sum(credit) - sum(debit), 0) from public.gl_lines
      where entry_id = v_entry and account_id = v_ar), 5000);
  perform pg_temp.check_eq('with the loss recognised',
    (select coalesce(sum(debit) - sum(credit), 0) from public.gl_lines
      where entry_id = v_entry and account_id = v_loss), 5000);
end $$;

-- ---------------------------------------------------------------------
-- The board
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rate_org('Board Sdn Bhd');
  r record;
begin
  perform public.ingest_exchange_rates(jsonb_build_array(
    pg_temp.quote('USD', 1, 4.2000, date '2026-03-31')));
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org, 'SGD', 'MYR', 3.30, date '2026-03-31', 'manual');

  select * into r from public.exchange_rate_board(v_org, date '2026-03-31')
   where currency = 'USD';
  perform pg_temp.check_eq('the board shows the published rate', r.rate, 4.20000000);
  perform pg_temp.check_true('and says where it came from',
    r.source = 'bnm' and r.is_own = false);

  select * into r from public.exchange_rate_board(v_org, date '2026-03-31')
   where currency = 'SGD';
  perform pg_temp.check_true('a typed rate is marked as this org''s own',
    r.source = 'manual' and r.is_own);

  -- The most useful line on the list: the one that will refuse to post.
  select * into r from public.exchange_rate_board(v_org, date '2026-03-31')
   where currency = 'EUR';
  perform pg_temp.check_true('a currency with no rate is listed, not omitted',
    r.currency = 'EUR' and r.rate is null);

  perform pg_temp.check_true('and the org''s own currency is not on it',
    not exists (select 1 from public.exchange_rate_board(v_org, date '2026-03-31')
                 where currency = 'MYR'));
end $$;

-- ---------------------------------------------------------------------
-- Reachability
--
-- A rate that prices everybody's ledger is not any one organization's
-- business, however senior the person asking.
-- ---------------------------------------------------------------------
do $$
declare v_org uuid := pg_temp.rate_org('Reach Sdn Bhd');
begin
  perform pg_temp.check_true('the ingest is closed to signed-in users',
    not has_function_privilege('authenticated',
      'public.ingest_exchange_rates(jsonb, text, character)', 'execute'));
  perform pg_temp.check_true('and to anon',
    not has_function_privilege('anon',
      'public.ingest_exchange_rates(jsonb, text, character)', 'execute'));
  perform pg_temp.check_true('and open to the service role, which is the feed',
    has_function_privilege('service_role',
      'public.ingest_exchange_rates(jsonb, text, character)', 'execute'));

  perform pg_temp.check_true('the board is readable by a signed-in user',
    has_function_privilege('authenticated',
      'public.exchange_rate_board(uuid, date)', 'execute'));
  perform pg_temp.check_true('and not by anon',
    not has_function_privilege('anon',
      'public.exchange_rate_board(uuid, date)', 'execute'));

  -- The other half of the same rule, from the RLS side: even with the
  -- function out of reach, a direct insert must not be able to create a
  -- row that every organization would then read.
  perform pg_temp.check_true('and the insert policy refuses a system row',
    (select with_check like '%org_id IS NOT NULL%'
       from pg_policies
      where schemaname = 'public' and tablename = 'exchange_rates'
        and policyname = 'exchange_rates_insert'));
end $$;

rollback;
