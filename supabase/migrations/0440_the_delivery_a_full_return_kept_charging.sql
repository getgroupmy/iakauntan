-- ---------------------------------------------------------------------
-- 0440  The delivery a full return kept charging
-- ---------------------------------------------------------------------
-- The `0410` shape again, and the fourth time it has paid out:
-- `credit_sales_invoice` and `credit_purchase_bill` copy the document
-- they are crediting -- contact, currency, exchange rate, and every
-- line with its item, price, tax code, rate, warehouse and inclusivity
-- -- and do not copy `shipping_amount`, `service_charge_amount` or
-- `discount_amount`. Those are header columns, and the credit note was
-- written before two of the three existed.
--
-- Measured on Sinar. An invoice for RM11,600 -- RM10,000 of goods,
-- RM500 delivery, RM300 service charge, RM800 tax -- credited IN FULL,
-- every line, nothing left:
--
--     INVOICE  sub=10000.00 ship=500.00 svc=300.00 tax=800.00 total=11600.00
--     CREDIT   sub=10000.00 ship=  0.00 svc=  0.00 tax=800.00 total=10800.00
--
-- The customer returned everything and still owes RM800 for delivering
-- and serving it. Worse than a wrong figure on a document: the
-- receivable never clears, so the invoice sits on the ageing forever,
-- the statement says the customer owes money on goods they sent back,
-- and the only way out is a manual journal somebody has to justify.
--
-- Not a new judgement. `0417` had to answer the same question when a
-- quotation became an invoice -- how much of a header charge follows a
-- partial transfer -- and settled it: apportion by the share of the
-- source lines being carried over, with all of it on a whole transfer
-- and none on a partial one when the source nets to zero. This uses
-- that rule, in that form, so the two paths cannot drift apart. A full
-- credit gets the whole charge back; crediting one line of three gets a
-- third of the delivery.
--
-- And the arithmetic is left to the function that owns it, exactly as
-- `0417` argued: `app.recalc_sales_totals` is a trigger on the LINES,
-- so a header amount written after the last line is in the row and not
-- in the total. Touching a line re-runs it over the header this
-- function has just finished writing. Setting `total_amount` by hand
-- here would put a credit note in the business of arithmetic that
-- belongs somewhere else.
--
-- Four mutants applied and measured:
--
--   * the whole charge on a partial credit (`v_share := 1`) -- killed,
--     "crediting half the goods gives half the delivery", got 500 for
--     250. A three-line invoice would have handed back the delivery
--     three times over;
--   * the delivery apportioned to nothing while the others still move
--     -- killed by the same assertion, got 0.00;
--   * the trigger re-run removed -- killed by this migration's own
--     apply-time guard before a test ran, so it exercised nothing;
--   * the re-run kept but matching no rows (`and false`), which gets
--     past the guard -- and here the system caught it harder than the
--     test does. `create_gl_entry` refused: "Journal does not balance:
--     debits 5800.00, credits 5400.00". The header charge that never
--     reached `total_amount` makes the posting unbalanced, and the
--     ledger will not take it. So the assertion written for this --
--     "the charge is inside the credit note's own total" -- made no
--     kill of its own. It stays because it says plainly what is wrong,
--     where the balance error says only that something is; but it is
--     not credited with catching it.
--
-- `discount_amount` is apportioned with them. It is the same kind of
-- column and the same omission; a discounted invoice credited in full
-- was giving back more than it took, which is the mirror of the
-- delivery and no more defensible.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The sales credit note, restated to give the charges back
-- ---------------------------------------------------------------------
-- Restated from the live `pg_get_functiondef`.

CREATE OR REPLACE FUNCTION public.credit_sales_invoice(p_invoice uuid, p_lines jsonb DEFAULT NULL::jsonb, p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_src_net numeric(18, 2);
  v_new_net numeric(18, 2);
  v_share   numeric;
  v_doc   public.sales_documents;
  v_note  uuid;
  v_no    text;
  v_row   record;
  v_want  numeric;
  v_n     integer := 0;
begin
  select * into v_doc from public.sales_documents d
   where d.id = p_invoice and d.doc_type = 'invoice';
  if v_doc.id is null then
    raise exception 'No such invoice.' using errcode = 'P0002';
  end if;
  if not app.can_post(v_doc.org_id) then
    raise exception
      'Crediting an invoice posts a document, which needs permission this '
      'account has not been given.'
      using errcode = '42501';
  end if;
  -- Posted, part-paid or paid in full -- all three are invoices that
  -- have reached the ledger and can be credited. A counter sale's
  -- invoice is `completed` the moment the till takes the money, so
  -- testing for `posted` alone would refuse to credit exactly the sales
  -- this migration exists for.
  if v_doc.status not in ('posted', 'partial', 'completed') then
    raise exception
      'That invoice is %, so there is nothing to credit yet.', v_doc.status
      using errcode = '23514';
  end if;

  v_no := app.next_document_number_internal(v_doc.org_id, 'credit_note');

  insert into public.sales_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
    exchange_rate, status, original_invoice_id, parent_id, notes,
    created_by)
  values (
    v_doc.org_id, 'credit_note', v_no, app.today(), app.today(),
    v_doc.contact_id, v_doc.currency, v_doc.exchange_rate, 'draft',
    -- The link this whole migration exists to create.
    p_invoice, p_invoice,
    coalesce(nullif(btrim(coalesce(p_reason, '')), ''),
             'Credit against ' || v_doc.doc_no),
    auth.uid())
  returning id into v_note;

  for v_row in
    select r.*,
           (select (e ->> 'quantity')::numeric
              from jsonb_array_elements(p_lines) e
             where (e ->> 'line')::uuid = r.line_id) as asked
      from public.invoice_credit_remaining(p_invoice) r
  loop
    -- Null asks for everything left; a named line asks for what it says.
    v_want := case when p_lines is null then v_row.remaining
                   else coalesce(v_row.asked, 0) end;
    if v_want <= 0 then
      continue;
    end if;
    if v_want > v_row.remaining then
      raise exception
        'Only % of "%" is left uncredited on %, and this asks for %. A '
        'credit note is a document about money, not authorisation to '
        'invent a return.',
        v_row.remaining, v_row.description, v_doc.doc_no, v_want
        using errcode = '23514';
    end if;

    v_n := v_n + 1;
    insert into public.sales_document_lines (
      org_id, document_id, line_no, line_type, item_id, description,
      quantity, uom_code, unit_price, tax_code_id, tax_rate,
      is_tax_inclusive, warehouse_id)
    select v_doc.org_id, v_note, v_n, 'item', l.item_id, l.description,
           v_want, l.uom_code, l.unit_price, l.tax_code_id, l.tax_rate,
           l.is_tax_inclusive, l.warehouse_id
      from public.sales_document_lines l where l.id = v_row.line_id;
  end loop;

  if v_n = 0 then
    -- Nothing to credit. The half-built note is removed rather than
    -- left as an empty document somebody has to explain.
    delete from public.sales_documents d where d.id = v_note;
    raise exception
      'There is nothing left to credit on %.', v_doc.doc_no
      using errcode = '23514';
  end if;

  -- 0440. The header charges, apportioned by the share of the invoice
  -- being credited -- `0417`'s rule, in `0417`'s form.
  select coalesce(sum(line_subtotal), 0) into v_src_net
    from public.sales_document_lines where document_id = p_invoice;
  select coalesce(sum(line_subtotal), 0) into v_new_net
    from public.sales_document_lines where document_id = v_note;

  v_share := case
    -- An invoice whose lines net to zero -- all of it discounted, or a
    -- swap -- has no share to take. All of it on a whole credit and
    -- none on a partial one are the only defensible answers.
    when v_src_net = 0 then case when p_lines is null then 1 else 0 end
    else v_new_net / v_src_net
  end;

  update public.sales_documents d
     set shipping_amount = round(coalesce(v_doc.shipping_amount, 0) * v_share, 2),
         discount_amount = round(coalesce(v_doc.discount_amount, 0) * v_share, 2),
         service_charge_amount =
           round(coalesce(v_doc.service_charge_amount, 0) * v_share, 2)
   where d.id = v_note;

  -- And let the totals be recomputed by the trigger that owns them. It
  -- fires on the lines, so a header amount written after the last line
  -- is in the row and not in the total.
  update public.sales_document_lines
     set line_no = line_no where document_id = v_note;

  perform app.post_sales_document_internal(v_note);
  return v_note;
end;
$function$;

-- ---------------------------------------------------------------------
-- And the purchase credit note
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.credit_purchase_bill(p_bill uuid, p_lines jsonb DEFAULT NULL::jsonb, p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_src_net numeric(18, 2);
  v_new_net numeric(18, 2);
  v_share   numeric;
  v_doc  public.purchase_documents;
  v_note uuid;
  v_no   text;
  v_row  record;
  v_want numeric;
  v_n    integer := 0;
begin
  select * into v_doc from public.purchase_documents d
   where d.id = p_bill and d.doc_type = 'bill';
  if v_doc.id is null then
    raise exception 'No such bill.' using errcode = 'P0002';
  end if;
  if not app.can_post(v_doc.org_id) then
    raise exception
      'Crediting a bill posts a document, which needs permission this '
      'account has not been given.'
      using errcode = '42501';
  end if;
  if v_doc.status not in ('posted', 'partial', 'completed') then
    raise exception
      'That bill is %, so there is nothing to credit yet.', v_doc.status
      using errcode = '23514';
  end if;

  v_no := app.next_document_number_internal(
            v_doc.org_id, 'purchase_credit_note');

  insert into public.purchase_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
    exchange_rate, status, original_bill_id, parent_id, notes, created_by)
  values (
    v_doc.org_id, 'purchase_credit_note', v_no, app.today(), app.today(),
    v_doc.contact_id, v_doc.currency,
    -- The bill's rate, not today's. The credit reverses money recorded
    -- at that rate; re-resolving it would book an FX gain on a return.
    v_doc.exchange_rate, 'draft',
    p_bill, p_bill,
    coalesce(nullif(btrim(coalesce(p_reason, '')), ''),
             'Credit against ' || v_doc.doc_no),
    auth.uid())
  returning id into v_note;

  for v_row in
    select r.*,
           (select (e ->> 'quantity')::numeric
              from jsonb_array_elements(p_lines) e
             where (e ->> 'line')::uuid = r.line_id) as asked
      from public.bill_credit_remaining(p_bill) r
  loop
    v_want := case when p_lines is null then v_row.remaining
                   else coalesce(v_row.asked, 0) end;
    if v_want <= 0 then
      continue;
    end if;
    if v_want > v_row.remaining then
      raise exception
        'Only % of "%" is left uncredited on %, and this asks for %. A '
        'credit note is a document about money, not a claim for goods '
        'the supplier never sent.',
        v_row.remaining, v_row.description, v_doc.doc_no, v_want
        using errcode = '23514';
    end if;

    v_n := v_n + 1;
    insert into public.purchase_document_lines (
      org_id, document_id, line_no, line_type, item_id, description,
      quantity, uom_code, unit_price, tax_code_id, tax_rate,
      is_tax_inclusive, warehouse_id, account_id)
    select v_doc.org_id, v_note, v_n, 'item', l.item_id, l.description,
           v_want, l.uom_code, l.unit_price, l.tax_code_id, l.tax_rate,
           l.is_tax_inclusive, l.warehouse_id, l.account_id
      from public.purchase_document_lines l where l.id = v_row.line_id;
  end loop;

  if v_n = 0 then
    -- Nothing to credit. The half-built note needs no deleting: this
    -- raise unwinds the whole call, and the insert above goes with it.
    --
    -- `0269` deletes the row first, and the mutation run showed that
    -- line is dead there too — removing it changed no assertion, because
    -- there is no path out of here that does not raise. Said out loud so
    -- the next reader does not copy it back in thinking it was load
    -- bearing.
    raise exception
      'There is nothing left to credit on %.', v_doc.doc_no
      using errcode = '23514';
  end if;

  -- 0440. Same rule, same form. `purchase_documents` carries shipping
  -- and a discount; there is no service charge on the buying side.
  select coalesce(sum(line_subtotal), 0) into v_src_net
    from public.purchase_document_lines where document_id = p_bill;
  select coalesce(sum(line_subtotal), 0) into v_new_net
    from public.purchase_document_lines where document_id = v_note;

  v_share := case
    when v_src_net = 0 then case when p_lines is null then 1 else 0 end
    else v_new_net / v_src_net
  end;

  update public.purchase_documents d
     set shipping_amount = round(coalesce(v_doc.shipping_amount, 0) * v_share, 2),
         discount_amount = round(coalesce(v_doc.discount_amount, 0) * v_share, 2)
   where d.id = v_note;

  update public.purchase_document_lines
     set line_no = line_no where document_id = v_note;

  perform app.post_purchase_document_internal(v_note);
  return v_note;
end;
$function$;

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = to_regprocedure(
     'public.credit_sales_invoice(uuid, jsonb, text)');

  if v_src !~ 'service_charge_amount' or v_src !~ 'shipping_amount' then
    raise exception
      'FAIL 0440: a credit note still leaves the delivery and the '
      'service charge on the customer, so a full return never clears '
      'the receivable';
  end if;

  -- Apportioned, not copied whole. Copying the full charge onto a
  -- partial credit would satisfy the check above and hand back a
  -- delivery three times over on a three-line invoice.
  if v_src !~ 'v_share' then
    raise exception
      'FAIL 0440: the charges are not apportioned to the share being '
      'credited, so a partial credit gives back a whole delivery';
  end if;

  -- And the totals are recomputed by the trigger that owns them.
  -- `0417` found this the hard way: a header amount written after the
  -- last line is in the column and not in the total.
  if v_src !~ 'set line_no = line_no' then
    raise exception
      'FAIL 0440: the charge is written to the header and never reaches '
      'the credit note''s own total';
  end if;

  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = to_regprocedure(
     'public.credit_purchase_bill(uuid, jsonb, text)');
  if v_src !~ 'shipping_amount' or v_src !~ 'v_share' then
    raise exception
      'FAIL 0440: the purchase side still keeps the supplier''s delivery '
      'charge on a returned bill';
  end if;

  raise notice '0440: a full return gives back everything it was charged';
end
$do$;
