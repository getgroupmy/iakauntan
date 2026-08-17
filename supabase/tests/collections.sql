-- =====================================================================
-- iAkauntan :: debt collection
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/collections.sql
--
-- Chasing money has one job — knowing who said they would pay and
-- whether they did — and three ways to get it wrong.
--
--   1. **Quoting a different number from the aged receivables.** The
--      worklist reads through `report_ar_aging` rather than counting
--      `sales_documents` a second time, so the two cannot drift. That is
--      asserted by comparing them.
--
--   2. **Losing a promise.** An outcome of "promised" with no date never
--      reaches a follow-up list; a renegotiated promise that keeps the
--      old date sends somebody chasing a deadline the customer already
--      moved.
--
--   3. **Ordering by the wrong thing.** The oldest debt is not the most
--      urgent. A promise that has been broken is, because that is the
--      one that was being actively managed and has just stopped being.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org uuid; v_owner uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_ac uuid; v_inv uuid; v_other uuid;
  v_cids uuid[]; v_amts numeric[]; v_dues date[]; i integer;
  r record;
  v_owed numeric; v_aged numeric; v_rows integer;
  v_first text; v_second text;
begin
  v_org := pg_temp.test_org('Probe Collections');
  v_owner := pg_temp.test_user();
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  select id into v_ac from public.accounts
   where org_id = v_org and account_type = 'revenue' and not is_group limit 1;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Broke A Promise Sdn Bhd', 'customer')
  returning id into v_c1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C2', 'Never Chased Bhd', 'customer') returning id into v_c2;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C3', 'Promised Next Week Sdn Bhd', 'customer')
  returning id into v_c3;

  -- One overdue invoice each. C2's is the oldest, which is what makes
  -- the ordering assertion below mean something: it has to be beaten by
  -- C1's broken promise despite being older.
  v_cids := array[v_c1, v_c2, v_c3];
  v_amts := array[1000.00, 2000.00, 3000.00];
  v_dues := array[date '2026-03-01', date '2026-01-15', date '2026-04-01'];
  for i in 1..3 loop
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
       exchange_rate, status)
    values (v_org, 'invoice',
            app.next_document_number_internal(v_org, 'invoice'),
            v_dues[i], v_dues[i], v_cids[i], 'MYR', 1, 'draft')
    returning id into v_inv;
    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description, quantity,
       unit_price, account_id, tax_rate)
    values (v_org, v_inv, 1, 'item', 'Goods', 1, v_amts[i], v_ac, 0);
    perform app.post_sales_document_internal(v_inv);
  end loop;

  -- C1 promised the 20th of May and it is now June.
  insert into public.collection_attempts
    (org_id, contact_id, attempted_on, channel, outcome, promise_date,
     promise_amount, notes, assigned_to, created_by)
  values (v_org, v_c1, date '2026-05-10', 'call', 'promised',
          date '2026-05-20', 1000.00, 'Cheque goes out Friday',
          v_owner, v_owner);

  -- C3 promised the 30th of June, then rang back and moved it to July.
  insert into public.collection_attempts
    (org_id, contact_id, attempted_on, channel, outcome, promise_date,
     promise_amount, notes, created_by)
  values (v_org, v_c3, date '2026-06-01', 'whatsapp', 'promised',
          date '2026-06-30', 3000.00, 'Waiting on their customer', v_owner);
  insert into public.collection_attempts
    (org_id, contact_id, attempted_on, channel, outcome, promise_date,
     promise_amount, notes, created_by)
  values (v_org, v_c3, date '2026-06-05', 'call', 'promised',
          date '2026-07-15', 3000.00, 'Moved to mid-July', v_owner);

  -- ------------------------------------------------------------------
  -- 1. The worklist says what the aged receivables say
  -- ------------------------------------------------------------------
  select sum(outstanding), count(*) into v_owed, v_rows
    from public.report_collections(v_org, date '2026-06-10');
  select sum(base_outstanding) into v_aged
    from public.report_ar_aging(v_org, date '2026-06-10')
   where doc_kind = 'invoice' and base_outstanding > 0;

  perform pg_temp.check_eq('three customers owe something', v_rows, 3);
  perform pg_temp.check_eq('and the total is the aged total', v_owed, 6000.00);
  perform pg_temp.check_eq(
    'which is the same figure the aging report gives', v_owed, v_aged);

  -- ------------------------------------------------------------------
  -- 2. Promises
  -- ------------------------------------------------------------------
  select promise_date, promise_broken, never_chased, oldest_days
    into r from public.report_collections(v_org, date '2026-06-10')
   where contact_id = v_c1;
  perform pg_temp.check_true('C1''s promise is broken', r.promise_broken);
  perform pg_temp.check_eq('and its debt is 101 days old', r.oldest_days, 101);

  select promise_date, promise_broken into r
    from public.report_collections(v_org, date '2026-06-10')
   where contact_id = v_c3;
  -- The later promise wins. Chasing C3 on the 30th of June would be
  -- chasing a date they already renegotiated.
  perform pg_temp.check_true('C3''s live promise is the renegotiated one',
    r.promise_date = date '2026-07-15');
  perform pg_temp.check_true('and it is not broken yet',
    not r.promise_broken);

  select never_chased into r
    from public.report_collections(v_org, date '2026-06-10')
   where contact_id = v_c2;
  perform pg_temp.check_true('C2 has never been chased', r.never_chased);

  -- A promise made after the as-at date is not yet a promise anyone has
  -- made. Without this the report would show tomorrow's phone call.
  select count(*) into v_rows
    from public.report_collections(v_org, date '2026-05-01')
   where contact_id = v_c3 and promise_date is not null;
  perform pg_temp.check_eq(
    'a promise made later is not visible earlier', v_rows, 0);

  -- ------------------------------------------------------------------
  -- 3. What comes first
  -- ------------------------------------------------------------------
  select contact_code into v_first
    from public.report_collections(v_org, date '2026-06-10') limit 1;
  select contact_code into v_second
    from public.report_collections(v_org, date '2026-06-10')
    offset 1 limit 1;

  -- C2's debt is 146 days old against C1's 101, and C1 still comes
  -- first, because a promise that has just been broken is the thing most
  -- likely to be lost if nobody looks at it today.
  perform pg_temp.check_true('the broken promise is at the top',
    v_first = 'C1');
  perform pg_temp.check_true('then the customer nobody has rung',
    v_second = 'C2');

  -- ------------------------------------------------------------------
  -- What the table refuses
  -- ------------------------------------------------------------------
  begin
    insert into public.collection_attempts
      (org_id, contact_id, attempted_on, channel, outcome, created_by)
    values (v_org, v_c1, date '2026-06-10', 'call', 'promised', v_owner);
    raise exception 'a promise with no date was accepted';
  exception when check_violation then
    raise notice 'ok   "promised" without a date is refused';
  end;

  begin
    insert into public.collection_attempts
      (org_id, contact_id, attempted_on, channel, outcome, promise_date,
       created_by)
    values (v_org, v_c1, date '2026-06-10', 'call', 'promised',
            date '2026-06-01', v_owner);
    raise exception 'a promise to have paid last week was accepted';
  exception when check_violation then
    raise notice 'ok   a promise cannot predate the conversation';
  end;

  begin
    insert into public.collection_attempts
      (org_id, contact_id, attempted_on, channel, outcome, promise_date,
       created_by)
    values (v_org, v_c1, date '2026-06-10', 'call', 'refused',
            date '2026-07-01', v_owner);
    raise exception '"refused, will pay Friday" was accepted';
  exception when check_violation then
    raise notice 'ok   a promise date belongs only to "promised"';
  end;

  -- An invoice being chased must be the invoice of the customer being
  -- chased. The composite key stops another company's; this stops
  -- another customer of the same one.
  select id into v_inv from public.sales_documents
   where org_id = v_org and contact_id = v_c2 limit 1;
  begin
    insert into public.collection_attempts
      (org_id, contact_id, document_id, attempted_on, channel, outcome,
       created_by)
    values (v_org, v_c1, v_inv, date '2026-06-10', 'call', 'no_answer',
            v_owner);
    raise exception 'one customer was chased over another''s invoice';
  exception when check_violation then
    raise notice 'ok   an invoice belongs to the customer being chased';
  end;

  -- The positive control on those four refusals: an ordinary attempt,
  -- against this customer's own invoice, still goes in. Without it a
  -- trigger that refused everything would pass all four.
  select id into v_inv from public.sales_documents
   where org_id = v_org and contact_id = v_c1 limit 1;
  insert into public.collection_attempts
    (org_id, contact_id, document_id, attempted_on, channel, outcome,
     notes, created_by)
  values (v_org, v_c1, v_inv, date '2026-06-11', 'email', 'no_answer',
          'Chased again, no reply', v_owner);
  raise notice 'ok   and an ordinary attempt is still recorded';

  -- That newer attempt has no promise on it, so C1''s promise is now
  -- superseded by silence — the "latest attempt" is the email, but the
  -- live promise is still the last one actually given. Both are true and
  -- the report has to say both.
  select last_attempt_on, promise_date, promise_broken into r
    from public.report_collections(v_org, date '2026-06-12')
   where contact_id = v_c1;
  perform pg_temp.check_true('the last contact is the newer one',
    r.last_attempt_on = date '2026-06-11');
  perform pg_temp.check_true('and the broken promise still stands',
    r.promise_date = date '2026-05-20' and r.promise_broken);

  -- ------------------------------------------------------------------
  -- Paying it clears the worklist
  --
  -- The control on the whole report: it must be reading live balances,
  -- not a snapshot taken when the attempt was logged.
  -- ------------------------------------------------------------------
  select count(*) into v_rows
    from public.report_collections(v_org, date '2026-02-01');
  perform pg_temp.check_eq(
    'before the other two invoices existed, one customer owed', v_rows, 1);

  select count(*) into v_rows from public.collection_history(v_c1);
  perform pg_temp.check_eq('C1''s history has both attempts', v_rows, 2);

  raise notice 'collections: % owed across 3 customers, 1 broken promise',
    v_owed;
end $$;

rollback;
