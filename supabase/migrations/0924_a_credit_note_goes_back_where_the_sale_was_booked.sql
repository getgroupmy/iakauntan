-- =====================================================================
-- iAkauntan :: 0924 a credit note goes back where the sale was booked
--
-- `credit_sales_invoice` is the door that credits an invoice: it writes
-- a credit note line for each line still to credit and posts the note.
-- It wrote those lines with no account, so the credit posted to the
-- item's or the default sales account whatever the invoice's line had
-- named. `credit_purchase_bill` carries the bill line's account and
-- was right.
--
-- Measured on 23 November 2026, locally, as the owner with the role
-- `authenticated`: an invoice of RM100 on a line naming 4150 posted
-- 1210 +100 / 4150 -100. Credited in full, the ledger ended 4150 -100
-- and 4100 +100: RM100 of revenue still standing in the account the
-- sale was reversed out of, and RM100 of negative revenue in Sales.
--
-- Production on 23 November: no sales credit note yet. Of 198 posted
-- invoice lines, 171 name 4100, 22 name none, and five, in four
-- companies, name 4840 -- any of those five would have been credited
-- to 4100.
--
-- Answered "carry the line's account". `credit_sales_invoice` now
-- writes each credit line with its invoice line's account.
--
-- And one thing `0923` made of both doors. A line may no longer name
-- an account that is closed, so a credit for a document whose line's
-- account has been closed since it posted was refused outright --
-- measured the same day on the purchase side: a bill of RM60 on 6291,
-- journalled on, the account closed, and the credit refused with
-- "choose one that is open", which this door gives nobody the chance
-- to do. Both doors now leave such a line with no account of its own,
-- and it posts as any line without one does. The sale or the bill
-- cannot be reversed into an account that is out of use, and the
-- credit is not lost for it.
--
-- Both functions are restated from `pg_get_functiondef` with only the
-- lines marked 0924 changed.
-- =====================================================================

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
    v_doc.org_id, 'credit_note', v_no,
    -- 0889: today, or the original's own day if that is still to come.
    greatest(app.today(), v_doc.doc_date), greatest(app.today(), v_doc.doc_date),
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
    -- 0924: with the account the invoice's line was booked to, so the
    -- credit goes back where the sale went. One that has been closed
    -- since is not named again (`0923`): the line then posts as a line
    -- with no account of its own does.
    insert into public.sales_document_lines (
      org_id, document_id, line_no, line_type, item_id, description,
      quantity, uom_code, unit_price, tax_code_id, tax_rate,
      is_tax_inclusive, warehouse_id, account_id)
    select v_doc.org_id, v_note, v_n, 'item', l.item_id, l.description,
           v_want, l.uom_code, l.unit_price, l.tax_code_id, l.tax_rate,
           l.is_tax_inclusive, l.warehouse_id,
           (select a.id from public.accounts a
             where a.id = l.account_id
               and a.deleted_at is null and a.is_active)
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
    v_doc.org_id, 'purchase_credit_note', v_no,
    -- 0889: today, or the original's own day if that is still to come.
    greatest(app.today(), v_doc.doc_date), greatest(app.today(), v_doc.doc_date),
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
    -- 0924: an account closed since the bill posted is not named
    -- again (`0923` would refuse the whole credit): the line then
    -- posts as a line with no account of its own does.
    insert into public.purchase_document_lines (
      org_id, document_id, line_no, line_type, item_id, description,
      quantity, uom_code, unit_price, tax_code_id, tax_rate,
      is_tax_inclusive, warehouse_id, account_id)
    select v_doc.org_id, v_note, v_n, 'item', l.item_id, l.description,
           v_want, l.uom_code, l.unit_price, l.tax_code_id, l.tax_rate,
           l.is_tax_inclusive, l.warehouse_id,
           (select a.id from public.accounts a
             where a.id = l.account_id
               and a.deleted_at is null and a.is_active)
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
