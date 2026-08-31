-- =====================================================================
-- iAkauntan :: the deal and the quotation it was won on
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/pipeline_quotes.sql
--
-- `opportunities.quotation_id` has carried a comment since `0008`
-- saying it is set when the deal becomes a quotation. Nothing set it,
-- so the pipeline and the sales ledger were two accounts of the same
-- deal with nothing joining them.
--
-- The figure is what goes wrong. `amount` is typed early and round;
-- the quotation is priced weeks later. Both then sit in the system,
-- the forecast comes off one and the invoice off the other, and
-- nothing ever compares them.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.pq_deal(
  p_org uuid, p_no text, p_name text, p_contact uuid, p_amount numeric)
returns uuid language plpgsql as $$
declare v_pipe uuid; v_stage uuid; v_id uuid;
begin
  select id into v_pipe from public.pipelines
   where org_id = p_org order by created_at limit 1;
  if v_pipe is null then
    insert into public.pipelines (org_id, name) values (p_org, 'Sales')
    returning id into v_pipe;
  end if;
  -- Won and lost stages as well as an open one:
  -- `close_opportunity` moves the deal through a stage of the matching
  -- type, so a pipeline without them cannot close anything.
  select id into v_stage from public.pipeline_stages
   where pipeline_id = v_pipe and stage_type = 'open' order by sort_order
   limit 1;
  if v_stage is null then
    insert into public.pipeline_stages
      (org_id, pipeline_id, name, sort_order, probability, stage_type)
    values (p_org, v_pipe, 'Qualified', 1, 50, 'open') returning id into v_stage;
    insert into public.pipeline_stages
      (org_id, pipeline_id, name, sort_order, probability, stage_type)
    -- `stage_type` is open, won or lost; an abandoned deal closes into
    -- the lost stage and is told apart by `opportunities.status`,
    -- which is what `0373` is about.
    values (p_org, v_pipe, 'Closed Won', 5, 100, 'won'),
           (p_org, v_pipe, 'Closed Lost', 6, 0, 'lost');
  end if;

  insert into public.opportunities
    (org_id, opportunity_no, name, contact_id, pipeline_id, stage_id,
     amount, currency)
  values (p_org, p_no, p_name, p_contact, v_pipe, v_stage, p_amount, 'MYR')
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- One number, written once
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Saluran Jualan Sdn Bhd');
  v_cust uuid;
  v_deal uuid;
  v_doc  uuid;
  v_row  public.sales_documents;
  v_said text;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pembeli Sdn Bhd', 'customer') returning id into v_cust;

  v_deal := pg_temp.pq_deal(v_org, 'OPP-1', 'Fit-out for level 8', v_cust,
    60000);

  v_doc := public.quote_opportunity(v_deal);
  select * into v_row from public.sales_documents where id = v_doc;

  perform pg_temp.check_eq('the quotation goes to the deal''s customer',
    v_row.contact_id, v_cust);
  perform pg_temp.check_eq('and starts at the deal''s figure',
    (select unit_price from public.sales_document_lines
      where document_id = v_doc), 60000);
  perform pg_temp.check_eq('it is a quotation', v_row.doc_type::text,
    'quotation');
  -- `0374`: an offer with no end never runs out. Thirty days where
  -- nobody said otherwise.
  perform pg_temp.check_eq('with an end date, because an offer has one',
    v_row.valid_until::text, (v_today + 30)::text);
  perform pg_temp.check_eq('and the deal names it',
    (select quotation_id from public.opportunities where id = v_deal), v_doc);

  begin
    perform public.quote_opportunity(v_deal);
    raise exception 'FAIL: a deal was quoted twice';
  exception when sqlstate '23505' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a deal has one quotation, not two figures',
    v_said like '%two figures for one job%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What will not be quoted
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Tak Boleh Sebut Sdn Bhd');
  v_cust  uuid;
  v_none  uuid;
  v_free  uuid;
  v_shut  uuid;
  v_said  text;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pembeli Sdn Bhd', 'customer') returning id into v_cust;

  -- A deal with nobody on it.
  v_none := pg_temp.pq_deal(v_org, 'OPP-1', 'Somebody, one day', null, 5000);
  begin
    perform public.quote_opportunity(v_none);
    raise exception 'FAIL: a quotation was raised for nobody';
  exception when sqlstate '23502' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a quotation goes to somebody',
    v_said like '%goes to somebody%');

  -- A deal worth nothing.
  v_free := pg_temp.pq_deal(v_org, 'OPP-2', 'Unpriced', v_cust, 0);
  begin
    perform public.quote_opportunity(v_free);
    raise exception 'FAIL: a quotation was raised for nothing';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and is worth something',
    v_said like '%worth nothing%');

  -- A deal already closed.
  v_shut := pg_temp.pq_deal(v_org, 'OPP-3', 'Gone', v_cust, 5000);
  perform public.close_opportunity(v_shut, 'lost', 'Price');
  begin
    perform public.quote_opportunity(v_shut);
    raise exception 'FAIL: a closed deal was quoted';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and is still open',
    v_said like '%already lost%');

  -- A validity in the past.
  update public.opportunities set amount = 5000 where id = v_free;
  begin
    perform public.quote_opportunity(v_free, v_today - 1);
    raise exception 'FAIL: a quotation expired before it was raised';
  exception when sqlstate '23514' then null;
  end;

  begin
    perform public.quote_opportunity(gen_random_uuid());
    raise exception 'FAIL: a deal that does not exist was quoted';
  exception when sqlstate 'P0002' then null;
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Attaching one that already exists
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Sambung Sebut Harga Sdn Bhd');
  v_cust  uuid;
  v_other uuid;
  v_deal  uuid;
  v_quote uuid;
  v_theirs uuid;
  v_inv   uuid;
  v_said  text;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pembeli Sdn Bhd', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-2', 'Orang Lain Sdn Bhd', 'customer')
  returning id into v_other;

  v_deal := pg_temp.pq_deal(v_org, 'OPP-1', 'Fit-out', v_cust, 60000);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'quotation', 'QT-1', current_date, v_cust, 'MYR', 1, 'draft')
  returning id into v_quote;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_quote, 1, 'Fit-out', 1, 48250);

  -- Somebody else's quotation, and an invoice, neither of which is
  -- what a deal is won on.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'quotation', 'QT-2', current_date, v_other, 'MYR', 1,
          'draft')
  returning id into v_theirs;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-1', current_date, v_cust, 'MYR', 1, 'draft')
  returning id into v_inv;

  begin
    perform public.link_opportunity_quotation(v_deal, v_theirs);
    raise exception 'FAIL: a deal was linked to another customer''s quote';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a deal and its quotation name one customer',
    v_said like '%went to somebody else%');

  begin
    perform public.link_opportunity_quotation(v_deal, v_inv);
    raise exception 'FAIL: a deal was linked to an invoice';
  exception when sqlstate '22023' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and it is a quotation',
    v_said like '%not on a invoice%');

  perform public.link_opportunity_quotation(v_deal, v_quote);
  perform pg_temp.check_eq('linking attaches it',
    (select quotation_id from public.opportunities where id = v_deal),
    v_quote);
  -- The document is the priced answer; the deal's figure was a guess.
  perform pg_temp.check_eq('and the deal takes the priced figure',
    (select amount from public.opportunities where id = v_deal), 48250);

  perform public.link_opportunity_quotation(v_deal, null);
  perform pg_temp.check_true('and it can be detached again',
    (select quotation_id is null from public.opportunities
      where id = v_deal));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Won on a quotation that had run out
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Tamat Tempoh Sdn Bhd');
  v_cust  uuid;
  v_deal  uuid;
  v_hand  uuid;
  v_doc   uuid;
  v_said  text;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pembeli Sdn Bhd', 'customer') returning id into v_cust;

  v_deal := pg_temp.pq_deal(v_org, 'OPP-1', 'Fit-out', v_cust, 60000);
  v_doc := public.quote_opportunity(v_deal);

  -- In date, it closes.
  perform public.close_opportunity(v_deal, 'won', 'Best price');
  perform pg_temp.check_eq('a deal on a live quotation closes',
    (select status from public.opportunities where id = v_deal), 'won');

  -- And once it is won it stays editable. A quotation lapses the day
  -- after every deal it was attached to closed, and a deal nobody can
  -- correct the name of because of that is a rule judging the row
  -- rather than the change.
  update public.sales_documents set valid_until = v_today - 1
   where id = v_doc;
  update public.opportunities set name = 'Fit-out, level 8'
   where id = v_deal;
  perform pg_temp.check_eq('a won deal stays editable after its quote '
    'lapses', (select name from public.opportunities where id = v_deal),
    'Fit-out, level 8');

  -- Lapsed, it does not. `0374` is the note on why: the price was an
  -- offer, and the offer ran out.
  v_deal := pg_temp.pq_deal(v_org, 'OPP-2', 'Second floor', v_cust, 20000);
  v_doc := public.quote_opportunity(v_deal);
  update public.sales_documents set valid_until = v_today - 5
   where id = v_doc;
  begin
    perform public.close_opportunity(v_deal, 'won', 'Agreed');
    raise exception 'FAIL: a deal was won on a lapsed quotation';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a lapsed quotation stops the deal closing',
    v_said like '%only valid until%');
  perform pg_temp.check_true('and the way through is named',
    v_said like '%extend_document_validity%');

  perform public.extend_document_validity(v_doc, v_today + 14);
  perform public.close_opportunity(v_deal, 'won', 'Agreed');
  perform pg_temp.check_eq('extended, it closes',
    (select status from public.opportunities where id = v_deal), 'won');

  -- A voided quotation is not something a customer accepted either.
  v_deal := pg_temp.pq_deal(v_org, 'OPP-3', 'Third floor', v_cust, 30000);
  v_doc := public.quote_opportunity(v_deal);
  update public.sales_documents set status = 'void' where id = v_doc;
  begin
    perform public.close_opportunity(v_deal, 'won', 'Agreed');
    raise exception 'FAIL: a deal was won on a withdrawn quotation';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('nor a withdrawn one',
    v_said like '%was voided%');

  -- And plenty of work is won on a phone call. A CRM that refuses to
  -- record that is a CRM people keep outside the system.
  v_hand := pg_temp.pq_deal(v_org, 'OPP-4', 'A handshake', v_cust, 4000);
  perform public.close_opportunity(v_hand, 'won', 'Known to us');
  perform pg_temp.check_eq('a deal with no quotation closes as it always did',
    (select status from public.opportunities where id = v_hand), 'won');

  -- Losing one is nobody's business here.
  v_deal := pg_temp.pq_deal(v_org, 'OPP-5', 'Fourth floor', v_cust, 10000);
  v_doc := public.quote_opportunity(v_deal);
  update public.sales_documents set valid_until = v_today - 5
   where id = v_doc;
  perform public.close_opportunity(v_deal, 'lost', 'Went elsewhere');
  perform pg_temp.check_eq('and a lost deal is not stopped by it',
    (select status from public.opportunities where id = v_deal), 'lost');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Where the two figures have drifted apart
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Beza Angka Sdn Bhd');
  v_cust  uuid;
  v_deal  uuid;
  v_same  uuid;
  v_shut  uuid;
  v_fresh uuid;
  v_doc   uuid;
  v_out   uuid := pg_temp.another_user('outsider@pq.test');
  v_said  text;
  r       record;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pembeli Sdn Bhd', 'customer') returning id into v_cust;

  v_deal := pg_temp.pq_deal(v_org, 'OPP-1', 'Fit-out', v_cust, 60000);
  v_doc  := public.quote_opportunity(v_deal);
  v_same := pg_temp.pq_deal(v_org, 'OPP-2', 'Agreeing', v_cust, 10000);
  perform public.quote_opportunity(v_same);

  perform pg_temp.check_eq('quoted from the deal, the two agree',
    (select count(*) from public.report_pipeline_quote_mismatch(v_org)), 0);

  -- Somebody prices it properly. This is the ordinary case, and the
  -- forecast is now wrong by the difference.
  update public.sales_document_lines set unit_price = 48250
   where document_id = v_doc;

  select * into r from public.report_pipeline_quote_mismatch(v_org);
  perform pg_temp.check_eq('a revised quote shows up', r.opportunity_no,
    'OPP-1');
  perform pg_temp.check_eq('with the pipeline figure', r.deal_amount, 60000);
  perform pg_temp.check_eq('and what was actually quoted',
    r.quoted_amount, 48250);
  perform pg_temp.check_eq('and the forecast is wrong by',
    r.difference, -11750);
  -- The document itself, so the screen can offer to take the deal to
  -- the priced figure rather than making somebody find it.
  perform pg_temp.check_eq('with the document to fix it from',
    r.document_id, v_doc);
  perform pg_temp.check_eq('while the one that agrees is not listed',
    (select count(*) from public.report_pipeline_quote_mismatch(v_org)
      where opportunity_no = 'OPP-2'), 0);

  -- A closed deal's figure is history, and rewriting it to agree with
  -- a document is not a fix.
  v_shut := pg_temp.pq_deal(v_org, 'OPP-3', 'Done', v_cust, 5000);
  perform public.link_opportunity_quotation(v_shut, v_doc);
  update public.opportunities set amount = 5000 where id = v_shut;
  perform public.close_opportunity(v_shut, 'lost', 'Price');
  perform pg_temp.check_eq('a closed deal is not chased',
    (select count(*) from public.report_pipeline_quote_mismatch(v_org)
      where opportunity_no = 'OPP-3'), 0);

  v_fresh := pg_temp.pq_deal(v_org, 'OPP-4', 'Not quoted yet', v_cust, 9000);

  -- Asked while there is something to find, so "closed to an outsider"
  -- is about who is asking and not about an empty pipeline.
  perform pg_temp.check_eq('the firm sees its own mismatch',
    (select count(*) from public.report_pipeline_quote_mismatch(v_org)), 1);
  perform pg_temp.sign_in_as(v_out);
  perform pg_temp.check_eq('and the report is closed to an outsider',
    (select count(*) from public.report_pipeline_quote_mismatch(v_org)), 0);
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- A voided quotation is not a figure to compare against.
  update public.sales_documents set status = 'void' where id = v_doc;
  perform pg_temp.check_eq('nor is a withdrawn quotation',
    (select count(*) from public.report_pipeline_quote_mismatch(v_org)), 0);

  perform pg_temp.sign_in_as(v_out);
  begin
    -- A deal with nothing on it yet, so what refuses the outsider is
    -- the permission and not a quotation already attached.
    perform public.quote_opportunity(v_fresh);
    raise exception 'FAIL: an outsider quoted a deal';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  -- The message, not just the code. Something further in refuses an
  -- outsider too, and a test that accepted any refusal would pass with
  -- this function's own check taken out — leaving the refusal to
  -- happen after a document number had been drawn.
  perform pg_temp.check_true('and is refused before anything is drawn',
    v_said like '%not permitted to raise a quotation%');
  begin
    perform public.link_opportunity_quotation(v_same, null);
    raise exception 'FAIL: an outsider unlinked a quotation';
  exception when sqlstate '42501' then null;
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('quoting a deal is closed to anon',
    not has_function_privilege('anon',
      'public.quote_opportunity(uuid, date, text)', 'execute'));
  perform pg_temp.check_true('and linking one',
    not has_function_privilege('anon',
      'public.link_opportunity_quotation(uuid, uuid)', 'execute'));
  perform pg_temp.check_true('and the mismatch report',
    not has_function_privilege('anon',
      'public.report_pipeline_quote_mismatch(uuid)', 'execute'));
  perform pg_temp.check_true('while a signed-in user may quote',
    has_function_privilege('authenticated',
      'public.quote_opportunity(uuid, date, text)', 'execute'));
end $$;

rollback;
