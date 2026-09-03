-- =====================================================================
-- iAkauntan :: the month-end pile
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bulk_actions.sql
--
-- Posting forty documents is forty postings, not one. What this file is
-- about is what happens when the eleventh will not post: the other
-- thirty-nine have to land, and the one that did not has to be named,
-- in the words the database used rather than as a number in a count.
--
-- And the two things a batch must not become: a way to reach another
-- company's documents, and a way around the guard that decides who may
-- post at all.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.pile_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

-- A company that is genuinely somebody else's. `pg_temp.test_org` makes
-- every company under the same owner, which is right for most files and
-- useless here: a batch reaching a company the caller is a member of is
-- not the thing being tested.
create or replace function pg_temp.someone_elses_org(
  p_name text, p_owner uuid)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', p_owner)
  returning id into v_org;
  -- No org_members insert: creating a company already enrols whoever
  -- created it, which is how `test_org` gets away without one.
  perform app.seed_chart_of_accounts(v_org);
  return v_org;
end;
$$;

create or replace function pg_temp.an_invoice(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric,
  p_date date default date '2026-03-04')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', p_no, p_date, p_contact, 'MYR', 1,
          p_amount, p_amount, p_amount, 'draft')
  returning id into v_id;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_total, cost_amount)
  values (p_org, v_id, 1, 'Consulting', 1, p_amount, p_amount, 0);
  return v_id;
end;
$$;

do $$
declare
  v_org   uuid := pg_temp.pile_org('Pile Sdn Bhd');
  v_other uuid;
  v_them  uuid;
  v_their uuid;
  v_a uuid; v_b uuid; v_c uuid; v_theirs uuid;
  v_ok integer; v_bad integer; v_reason text;
begin
  v_other := pg_temp.someone_elses_org('Somebody Else Sdn Bhd',
    pg_temp.another_user('owner@elsewhere.test'));
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_true('the other company really is somebody else''s',
    not app.is_org_member(v_other));

  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'buyer@example.test')
  returning id into v_them;
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_other, 'C-001', 'Their Buyer', 'customer', 'x@example.test')
  returning id into v_their;

  v_a := pg_temp.an_invoice(v_org, v_them, 'INV-1', 100);
  -- The one that will not post: dated into a year that has no fiscal
  -- period, which is the commonest reason a month-end pile has one bad
  -- document in it.
  v_b := pg_temp.an_invoice(v_org, v_them, 'INV-2', 200, date '2019-06-01');
  v_c := pg_temp.an_invoice(v_org, v_them, 'INV-3', 300);
  v_theirs := pg_temp.an_invoice(v_other, v_their, 'THEIRS-1', 999);

  -- ------------------------------------------------------------------
  -- Forty in, thirty-nine out
  -- ------------------------------------------------------------------
  select count(*) filter (where posted),
         count(*) filter (where not posted)
    into v_ok, v_bad
    from public.bulk_post_documents(array[v_a, v_b, v_c]);

  perform pg_temp.check_eq('the good ones land even when one is bad',
    v_ok, 2);
  perform pg_temp.check_eq('and the bad one is named', v_bad, 1);

  -- Not "1 failed". The sentence somebody has to act on.
  select problem into v_reason
    from public.bulk_post_documents(array[v_b]) where not posted;
  perform pg_temp.check_true('in the words the database used',
    v_reason is not null and length(v_reason) > 12
    and v_reason !~ '^[0-9]+$');

  -- The ledger agrees with the report, which is the point of the
  -- savepoint: the two that posted are posted, and the one that did not
  -- left nothing behind.
  perform pg_temp.check_true('what the report says is what the ledger did',
    (select status = 'posted' and gl_entry_id is not null
       from public.sales_documents where id = v_a)
    and (select status = 'posted' from public.sales_documents where id = v_c)
    and (select status = 'draft' and gl_entry_id is null
           from public.sales_documents where id = v_b));
  perform pg_temp.check_eq('and the failure wrote no journal',
    (select count(*)::integer from public.gl_entries
      where source_table = 'sales_documents' and source_id = v_b), 0);

  -- ------------------------------------------------------------------
  -- What a batch may not reach
  -- ------------------------------------------------------------------
  perform pg_temp.check_true(
    'a batch cannot reach another company''s documents',
    (select not posted and doc_no is null
       from public.bulk_post_documents(array[v_theirs])));
  perform pg_temp.check_true('and leaves it in draft',
    (select status = 'draft' from public.sales_documents
      where id = v_theirs));

  -- ------------------------------------------------------------------
  -- A ceiling
  -- ------------------------------------------------------------------
  begin
    perform public.bulk_post_documents(
      (select array_agg(v_a) from generate_series(1, app.bulk_limit() + 1)));
    raise exception 'FAIL a batch has a ceiling';
  exception when others then
    if sqlerrm like 'FAIL %' then raise; end if;
    raise notice 'ok   a batch has a ceiling';
  end;

  -- An empty batch is not an error, it is nothing to do.
  perform pg_temp.check_eq('an empty batch does nothing quietly',
    (select count(*)::integer
       from public.bulk_post_documents(array[]::uuid[])), 0);
end $$;

-- ---------------------------------------------------------------------
-- Sending the pile
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.pile_org('Sender Sdn Bhd');
  v_them uuid; v_nobody uuid; v_a uuid; v_b uuid;
  v_sent integer; v_bad integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  insert into public.email_settings (org_id, is_enabled, reminder_days)
  values (v_org, true, '{}');

  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'buyer@example.test')
  returning id into v_them;
  -- No email address, which is the commonest reason a send fails and
  -- the one worth naming a contact for.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-002', 'No Email Bhd', 'customer')
  returning id into v_nobody;

  v_a := pg_temp.an_invoice(v_org, v_them, 'INV-1', 100);
  v_b := pg_temp.an_invoice(v_org, v_nobody, 'INV-2', 200);
  perform public.post_sales_document(v_a);
  perform public.post_sales_document(v_b);

  select count(*) filter (where sent), count(*) filter (where not sent)
    into v_sent, v_bad
    from public.bulk_email_documents(array[v_a, v_b]);

  perform pg_temp.check_eq('the ones with an address go', v_sent, 1);
  perform pg_temp.check_eq('and the one without is named', v_bad, 1);
  perform pg_temp.check_true('by its document number',
    (select doc_no = 'INV-2' from public.bulk_email_documents(array[v_b])));
  perform pg_temp.check_eq('one message is queued, not two',
    (select count(*)::integer from public.email_outbox
      where document_id = v_a), 1);
end $$;

-- ---------------------------------------------------------------------
-- Not a way round the guard
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.pile_org('Guarded Sdn Bhd');
  v_them uuid; v_doc uuid; v_reader uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'buyer@example.test')
  returning id into v_them;
  v_doc := pg_temp.an_invoice(v_org, v_them, 'INV-1', 100);

  -- Somebody in the company who may read the ledger and not post to it.
  v_reader := pg_temp.another_user('viewer@example.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_reader, 'viewer', 'active', now());
  perform pg_temp.sign_in_as(v_reader);

  -- The batch does not raise -- one document's refusal is that
  -- document's problem, reported like any other -- but nothing posts.
  perform pg_temp.check_true('a reader cannot post a pile either',
    (select not posted from public.bulk_post_documents(array[v_doc])));
  perform pg_temp.check_true('and the document is untouched',
    (select status = 'draft' and gl_entry_id is null
       from public.sales_documents where id = v_doc));

  perform pg_temp.sign_in_as(pg_temp.test_user());
end $$;

rollback;
