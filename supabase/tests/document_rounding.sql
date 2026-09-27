-- =====================================================================
-- iAkauntan :: the supplier's total is the amount owed
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/document_rounding.sql
--
-- `0706`. Reported with the supplier's own PDF: a Google tax invoice
-- whose printed total is MYR 1,173.01 became RM 1,173.00 in this system,
-- with a rounding adjustment of one sen that nobody on either side of
-- the bill made.
--
-- Bank Negara's rounding mechanism applies to CASH. It exists because
-- there is no one sen coin to pay the last sen with, and a bill settled
-- by transfer or on credit terms is paid to the sen. But
-- `organizations.rounding_method` was one switch for the whole company
-- and both recalculation triggers applied it to everything, so a
-- company that takes cash over a counter was also restating every
-- supplier bill it received.
--
-- What is asserted here:
--
--   * a document that names no method still rounds the company's way,
--     because every row that exists anywhere is null and none of them
--     may move by a sen;
--   * a document that names `none` totals what its lines come to -- the
--     reported case, with the reported figures;
--   * naming it on the HEADER alone recomputes the total. The totals
--     were only ever recalculated by a LINE moving, which would have
--     made this column take effect whenever somebody happened to edit a
--     line afterwards, and not before;
--   * the method cannot change once the document is posted, because the
--     journal carries the rounding line it produced;
--   * and the check constraint refuses a method nobody implements.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid;
  v_sup   uuid;
  v_item  uuid;
  v_tax   uuid;
  v_bill  uuid;
  v_acct  uuid;
  v_total numeric;
  v_round numeric;
  v_n      integer;
  v_sched  uuid;
  v_rec    uuid;
  v_method text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kedai Kopi Sdn Bhd');

  -- The company takes cash over a counter, so the switch is on. This is
  -- the setting that was restating the supplier's bill.
  update public.organizations set rounding_method = 'nearest_5cent'
   where id = v_org;

  perform pg_temp.check_eq('the company rounds to five sen',
    (select rounding_method from public.organizations where id = v_org),
    'nearest_5cent');

  perform public.create_fiscal_year(v_org,
                                   date_trunc('year', current_date)::date);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Google Asia Pacific Pte. Ltd.', 'supplier')
  returning id into v_sup;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '5180', 'Langganan perisian', 'expense', 'operating_expense')
  returning id into v_acct;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price,
     purchase_account_id)
  values (v_org, 'ITM-140', 'Google Workspace', 'service', false, 'C62',
          0, v_acct)
  returning id into v_item;

  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to)
  values (v_org, 'ST8', 'SST 8%', '01', 8, 'purchase')
  returning id into v_tax;

  -- ------------------------------------------------------------------
  -- The reported bill, with the figures off the paper.
  --
  --   Subtotal in MYR   MYR 1,086.12
  --   Service tax (8%)  MYR    86.89
  --   Total in MYR      MYR 1,173.01
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, supplier_doc_no)
  values (v_org, 'bill', 'BILL-ROUND-1', current_date, v_sup, 'MYR', 1,
          'draft', '5665871390')
  returning id into v_bill;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate)
  values (v_org, v_bill, 1, 'item', v_item, 'Google Workspace', 1, 'C62',
          1086.12, v_tax, 8);

  select total_amount, rounding_amount into v_total, v_round
    from public.purchase_documents where id = v_bill;

  -- Before anything is said about rounding, the company's switch still
  -- applies -- which is the behaviour every existing document has and
  -- must keep.
  perform pg_temp.check_eq('a bill that names no method rounds the '
    'company''s way', v_total, 1173.00::numeric);
  perform pg_temp.check_eq('and carries the adjustment that made it',
    v_round, -0.01::numeric);

  -- ------------------------------------------------------------------
  -- The paper said 1,173.01, so the document says `none`. Set on the
  -- HEADER and nothing else -- no line is touched.
  -- ------------------------------------------------------------------
  update public.purchase_documents set rounding_method = 'none'
   where id = v_bill;

  select total_amount, rounding_amount into v_total, v_round
    from public.purchase_documents where id = v_bill;
  perform pg_temp.check_eq('the supplier''s own total is what is owed',
    v_total, 1173.01::numeric);
  perform pg_temp.check_eq('and nothing was rounded away',
    v_round, 0::numeric);

  -- And back again, so this is a switch rather than a one-way door.
  update public.purchase_documents set rounding_method = 'nearest_5cent'
   where id = v_bill;
  perform pg_temp.check_eq('naming the company''s own method rounds again',
    (select total_amount from public.purchase_documents where id = v_bill),
    1173.00::numeric);

  update public.purchase_documents set rounding_method = 'none'
   where id = v_bill;

  -- A line moving afterwards must not undo it: the line trigger reads
  -- the same resolution the header trigger did.
  update public.purchase_document_lines set quantity = 1
   where document_id = v_bill;
  perform pg_temp.check_eq('and a line moving afterwards keeps it',
    (select total_amount from public.purchase_documents where id = v_bill),
    1173.01::numeric);

  -- ------------------------------------------------------------------
  -- A method nobody implements is refused rather than silently ignored
  -- by `app.round_amount`'s else branch.
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused(
    'a method nobody implements is refused',
    format('update public.purchase_documents set rounding_method = '
           '''nearest_ringgit'' where id = %L', v_bill),
    '%purchase_documents_rounding_method_ck%', '23514');

  -- ------------------------------------------------------------------
  -- Posted, the method is frozen with the figures it decided.
  -- ------------------------------------------------------------------
  perform public.post_purchase_document(v_bill);
  perform pg_temp.check_eq('the posted bill carries the paper''s total',
    (select total_amount from public.purchase_documents where id = v_bill),
    1173.01::numeric);

  -- Named in the message, so this cannot pass on a refusal that some
  -- other frozen column happened to raise.
  perform pg_temp.check_refused(
    'a posted document''s rounding method cannot change',
    format('update public.purchase_documents set rounding_method = '
           '''nearest_5cent'' where id = %L', v_bill),
    '%rounding_method is one of the figures its journal was built from%',
    '42501');

  -- ------------------------------------------------------------------
  -- A standing order meets the same supplier every month
  --
  -- The structural gate in `recurring_template_carries_the_document`
  -- refuses a column the snapshot does not NAME. This asserts the value
  -- actually arrives, which naming it does not.
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, rounding_method)
  values (v_org, 'bill', 'BILL-ROUND-2', current_date, v_sup, 'MYR', 1,
          'draft', 'none')
  returning id into v_sched;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate)
  values (v_org, v_sched, 1, 'item', v_item, 'Google Workspace', 1, 'C62',
          1086.12, v_tax, 8);

  v_rec := public.create_recurring_document(
    v_sched, 'Langganan bulanan', 'monthly', current_date);
  perform app.raise_recurring_document(v_rec, current_date);

  select rounding_method, total_amount into v_method, v_total
    from public.purchase_documents
   where org_id = v_org and id not in (v_bill, v_sched)
   order by created_at desc limit 1;
  perform pg_temp.check_eq('next month''s bill rounds the way this one did',
    v_method, 'none');
  perform pg_temp.check_eq('so it is for the same money',
    v_total, 1173.01::numeric);

  raise notice 'document rounding: the paper''s total is the amount owed';
end $$;

rollback;
