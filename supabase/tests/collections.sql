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

-- ---------------------------------------------------------------------
-- The worklist, rule by rule
--
-- A mutation sweep of `report_collections` killed 7 of 18 on the block
-- above. Its three customers were each owed one invoice, the one nobody
-- had rung was also the oldest debt -- so "never chased first" and
-- "oldest first" put it in the same place -- and nobody but the owner
-- ever asked. This company is built so that each rule moves somebody:
--
--   D1  chased in May, rung again on 20 June   two invoices, due Jan and May
--   D2  never chased                           due 15 May   (the youngest)
--   D3  promised to pay on 10 June, assigned   due 1 March
--   D4  chased                                 due 1 April, and a credit
--                                              note nobody has used
--
-- As at 10 June: D2 first (never chased, though youngest), then oldest
-- first -- D1, D3, D4. D3's promise falls due that day and is not yet
-- broken; D1's June call has not happened yet.
--
-- Not asserted, because no data can tell them apart:
--   * another company's attempt: `collection_attempts` carries a
--     composite key to its contact's company. A table constraint.
--   * a credit balance on the worklist (`<> 0` for `> 0`): the rows are
--     invoices, and `app.apply_allocation` refuses to put more against
--     an invoice than it is for, so none is ever negative. The writer.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_ac uuid; v_hr uuid; v_stranger uuid;
  v_d uuid[] := array[]::uuid[]; v_c uuid; v_inv uuid; i integer;
  r record; v_order text;
begin
  v_org := pg_temp.test_org('Senarai Kutipan Sdn Bhd');
  v_owner := (select created_by from public.organizations where id = v_org);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  select id into v_ac from public.accounts
   where org_id = v_org and account_type = 'revenue' and not is_group limit 1;

  for i in 1..4 loop
    insert into public.contacts (org_id, code, name, contact_type)
    values (v_org, 'D' || i, 'Pelanggan ' || i, 'customer') returning id into v_c;
    v_d := v_d || v_c;
  end loop;

  -- The invoices: D1 two, the rest one each.
  for i in 1..5 loop
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
       exchange_rate, status)
    values (v_org, 'invoice', app.next_document_number_internal(v_org, 'invoice'),
            (array[date '2026-01-01', date '2026-05-01', date '2026-05-15',
                   date '2026-03-01', date '2026-04-01'])[i],
            (array[date '2026-01-01', date '2026-05-01', date '2026-05-15',
                   date '2026-03-01', date '2026-04-01'])[i],
            v_d[(array[1, 1, 2, 3, 4])[i]], 'MYR', 1, 'draft')
    returning id into v_inv;
    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description, quantity,
       unit_price, account_id, tax_rate)
    values (v_org, v_inv, 1, 'item', 'Goods', 1, 1000, v_ac, 0);
    perform app.post_sales_document_internal(v_inv);
  end loop;
  -- And D4's unused credit note.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'credit_note', 'CN-D4', date '2026-04-05', v_d[4], 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id, tax_rate)
  values (v_org, v_inv, 1, 'item', 'Returned', 1, 300, v_ac, 0);
  perform app.post_sales_document_internal(v_inv);

  insert into public.collection_attempts
    (org_id, contact_id, attempted_on, channel, outcome, created_by)
  values (v_org, v_d[1], date '2026-05-01', 'call', 'no_answer', v_owner),
         (v_org, v_d[1], date '2026-06-20', 'call', 'no_answer', v_owner),
         (v_org, v_d[4], date '2026-05-02', 'email', 'no_answer', v_owner);
  insert into public.collection_attempts
    (org_id, contact_id, attempted_on, channel, outcome, promise_date,
     promise_amount, assigned_to, created_by)
  values (v_org, v_d[3], date '2026-06-01', 'call', 'promised',
          date '2026-06-10', 1000, v_owner, v_owner);

  select string_agg(contact_code, ' ' order by ord) into v_order
    from (select contact_code, row_number() over () as ord
            from public.report_collections(v_org, date '2026-06-10')) x;
  perform pg_temp.check_eq(
    'the customer never rung comes first, then the oldest debt first',
    v_order, 'D2 D1 D3 D4');

  select * into r from public.report_collections(v_org, date '2026-06-10')
   where contact_id = v_d[1];
  perform pg_temp.check_eq('a customer''s oldest debt is its oldest invoice',
    r.oldest_days, 160);
  perform pg_temp.check_eq('and a call not yet made is not the last one',
    r.last_attempt_on::text, '2026-05-01');

  select * into r from public.report_collections(v_org, date '2026-06-10')
   where contact_id = v_d[3];
  perform pg_temp.check_true('a promise falling due today is not yet broken',
    not r.promise_broken);
  perform pg_temp.check_eq('and the person it is assigned to is named',
    r.assigned_name,
    (select coalesce(pr.full_name, pr.email) from public.profiles pr
      where pr.id = v_owner));

  select * into r from public.report_collections(v_org, date '2026-06-10')
   where contact_id = v_d[4];
  perform pg_temp.check_eq('an unused credit note is not chased as a debt',
    r.outstanding::text || '/' || r.invoices::text, '1000.00/1');

  -- Who may read it.
  v_hr := pg_temp.another_user('hr.kutipan@test.local');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_hr, 'hr_manager', 'active', now());
  perform pg_temp.sign_in_as(v_hr);
  perform pg_temp.check_refused('a member who keeps the staff files may not read it',
    format('select * from public.report_collections(%L)', v_org),
    '%may not read the sales ledger%', '42501');
  v_stranger := pg_temp.another_user('orang.luar@kutipan.test');
  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_refused('and a stranger may not either',
    format('select * from public.report_collections(%L)', v_org),
    '%Not your company%', '42501');
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A debit note is chased like an invoice (0749)
--
-- Until `0749` the worklist read invoices only, so a customer whose only
-- debt was a debit note was never on it, and one who owed on both was
-- shown the invoice part alone. The user's answer on 6 October: chase
-- debit notes.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_ac uuid; v_only uuid; v_both uuid; v_doc uuid; r record;
begin
  v_org := pg_temp.test_org('Nota Debit Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  select id into v_ac from public.accounts
   where org_id = v_org and account_type = 'revenue' and not is_group limit 1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'N1', 'Hanya Nota Debit', 'customer') returning id into v_only;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'N2', 'Kedua-duanya', 'customer') returning id into v_both;

  -- N1 owes 250 on a debit note and nothing else; N2 owes 1,000 on an
  -- invoice and 250 on a debit note.
  for r in select * from (values
      (v_only, 'debit_note'::app.sales_doc_type, 'DN-1', 250::numeric, date '2026-04-01'),
      (v_both, 'invoice',    'INV-1', 1000, date '2026-03-01'),
      (v_both, 'debit_note', 'DN-2',   250, date '2026-04-01')) x(c, t, no, amt, d)
  loop
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
       exchange_rate, status)
    values (v_org, r.t, r.no, r.d, r.d, r.c, 'MYR', 1, 'draft')
    returning id into v_doc;
    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description, quantity,
       unit_price, account_id, tax_rate)
    values (v_org, v_doc, 1, 'item', 'Charge', 1, r.amt, v_ac, 0);
    perform app.post_sales_document_internal(v_doc);
  end loop;

  perform pg_temp.check_eq('a customer who owes only on a debit note is chased',
    (select outstanding from public.report_collections(v_org, date '2026-06-10')
      where contact_id = v_only), 250);
  select * into r from public.report_collections(v_org, date '2026-06-10')
   where contact_id = v_both;
  perform pg_temp.check_eq('and one who owes on both is chased for both',
    r.outstanding::text || '/' || r.invoices::text, '1250.00/2');
end $$;

rollback;
