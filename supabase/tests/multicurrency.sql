-- =====================================================================
-- iAkauntan :: multi-currency tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/multicurrency.sql
--
-- A wrong exchange rate does not make the ledger unbalanced — it makes it
-- balanced and wrong, which no other check in this system would catch. So
-- these assert the arithmetic rather than the plumbing.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Resolving a rate
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('FX Test Sdn Bhd');
begin
  perform pg_temp.check_eq('base currency resolves to 1',
    app.exchange_rate_for(v_org, 'MYR', current_date), 1);

  -- The important one. Defaulting a missing rate to 1 would post a
  -- USD 10,000 invoice as RM 10,000: balanced, four times understated,
  -- and invisible to every other assertion in this suite.
  begin
    perform app.exchange_rate_for(v_org, 'USD', current_date);
    raise exception 'FAIL: a missing rate was silently treated as 1';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a missing rate refuses to guess';
  end;

  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org,'USD','MYR',4.20,current_date - 30,'manual'),
         (v_org,'USD','MYR',4.70,current_date -  1,'manual'),
         (v_org,'USD','MYR',9.99,current_date +  5,'manual');

  -- A document is converted at the rate that was known on its own date,
  -- so a rate entered for next week must not reach back and restate it.
  perform pg_temp.check_eq('rate today',
    app.exchange_rate_for(v_org,'USD',current_date), 4.70);
  perform pg_temp.check_eq('rate for a back-dated document',
    app.exchange_rate_for(v_org,'USD',current_date - 15), 4.20);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What a foreign entry records
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('FX Ledger Sdn Bhd');
  v_ar uuid; v_sales uuid; v_entry uuid;
  v_base numeric; v_fc numeric;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  select id into v_ar    from public.accounts where org_id=v_org and code='1210';
  select id into v_sales from public.accounts where org_id=v_org and code='4100';

  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org,'USD','MYR',4.70,current_date,'manual');

  v_entry := app.create_gl_entry_internal(
    v_org, current_date, 'manual',
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar,    'debit', 47000, 'credit', 0),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 47000)),
    'USD 10,000 invoice', null, null, null, 'USD', 4.70);

  select sum(debit), sum(fc_debit) into v_base, v_fc
    from public.gl_lines where entry_id = v_entry;

  -- Both halves matter: the ringgit is what the accounts are kept in,
  -- the dollars are what the customer was actually billed and what a
  -- statement in their currency has to show.
  perform pg_temp.check_eq('ringgit posted', v_base, 47000);
  perform pg_temp.check_eq('dollars remembered', v_fc, 10000);

  -- A ringgit entry leaves the foreign columns empty, so a non-zero
  -- figure there always means "this line was in another currency".
  v_entry := app.create_gl_entry_internal(
    v_org, current_date, 'manual',
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar,    'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 100)),
    'A ringgit invoice');
  perform pg_temp.check_eq('a base-currency entry writes no foreign amount',
    (select sum(fc_debit + fc_credit) from public.gl_lines where entry_id = v_entry), 0);

  -- A foreign entry with no usable rate would post zeroes and balance.
  begin
    perform app.create_gl_entry_internal(
      v_org, current_date, 'manual',
      jsonb_build_array(
        jsonb_build_object('account_id', v_ar, 'debit', 1, 'credit', 0),
        jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 1)),
      'no rate', null, null, null, 'USD', 0);
    raise exception 'FAIL: a USD entry posted with a zero rate';
  exception when sqlstate '23514' then
    raise notice 'ok   a foreign entry with no rate is refused';
  end;

  perform pg_temp.sign_out();
end $$;

rollback;
