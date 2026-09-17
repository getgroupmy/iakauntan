-- =====================================================================
-- iAkauntan :: 0374 two dates on a document that nothing honoured
--
-- `sales_documents.valid_until` and `delivery_date` have been columns
-- since `0005`. `valid_until` even carries the comment `-- quotations`,
-- which is the whole of what anybody ever did about it. Neither has been
-- written by any screen or read by any function.
--
-- ---------------------------------------------------------------------
-- The price that ran out
--
-- A quotation is an offer. An offer with no end is one a customer can
-- accept eight months later at last year's prices, and `transfer_document`
-- would convert it without a word: quotation to sales order to invoice,
-- every figure carried forward, every downstream total agreeing with
-- every other. Nothing in the books would look wrong. The company would
-- simply have done the work for less than it now costs.
--
-- A proforma is the same shape and the stakes are higher: it is what an
-- importer's bank reads before it opens a letter of credit, and the
-- validity is part of what the bank is relying on.
--
-- So the transfer refuses an expired one and names the date. Refused
-- rather than warned, because honouring an expired quote is a decision
-- somebody makes rather than a click somebody makes without noticing —
-- and `extend_document_validity` is where they make it, on the record,
-- with the new date beside the old one in the audit trail.
--
-- A quotation with no `valid_until` is not expired. Every quote raised
-- before this migration has none, and refusing them all would break
-- every open quote in every company on the day it applied.
--
-- ---------------------------------------------------------------------
-- The date that was promised
--
-- `delivery_date` is what the customer was told. It survived nothing:
-- `transfer_document` never carried it from the quotation to the order,
-- or from the order to the delivery order, so a promise made in the
-- quote was gone by the time anybody could act on it. It is carried
-- forward now, onto the two document types where it means something —
-- an invoice's delivery date is a fact about a delivery that already
-- happened, and copying a promise into it would restate history.
--
-- And it gets a reader, which is the point. `report_late_orders` is the
-- question the column exists to answer: which orders are past the day we
-- promised them and still not shipped. Without it this migration would
-- have finished by storing a date nobody looks at, which is the failure
-- it was written to fix.
--
-- Outstanding is measured on the lines, not on the document's status:
-- `quantity_fulfilled` is what the delivery orders have actually taken,
-- and an order 90% shipped is late on the tenth that is not.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Honouring an expired quote, deliberately
-- ---------------------------------------------------------------------
create or replace function public.extend_document_validity(
  p_document uuid, p_valid_until date)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_d public.sales_documents;
begin
  select * into v_d from public.sales_documents
   where id = p_document and deleted_at is null;
  if v_d.id is null then
    raise exception 'No such document.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_d.org_id) then
    raise exception 'not permitted to change this document'
      using errcode = '42501';
  end if;
  if v_d.doc_type not in ('quotation', 'proforma') then
    raise exception
      'Only a quotation or a proforma has a validity. % is a %.',
      v_d.doc_no, v_d.doc_type using errcode = '22023';
  end if;
  if p_valid_until is null then
    raise exception 'Give the new date it is good until.'
      using errcode = '23514';
  end if;
  -- A date already gone is not an extension, it is a typo. Refusing it
  -- here means the only way past the transfer guard is a date somebody
  -- meant.
  if p_valid_until < current_date then
    raise exception
      'That date has already passed. An extension has to be to a day the '
      'price still holds.' using errcode = '23514';
  end if;
  if p_valid_until < v_d.doc_date then
    raise exception
      'A quotation cannot expire before the day it was raised (%).',
      to_char(v_d.doc_date, 'DD Mon YYYY') using errcode = '23514';
  end if;

  update public.sales_documents
     set valid_until = p_valid_until, updated_at = now()
   where id = p_document;
end $$;

revoke all on function public.extend_document_validity(uuid, date)
  from public, anon;
grant execute on function public.extend_document_validity(uuid, date)
  to authenticated;

comment on function public.extend_document_validity(uuid, date) is
  'Puts a new date on a quotation or proforma. Honouring an expired '
  'quote should be a decision somebody makes and the record keeps, not '
  'a transfer nobody noticed.';

-- ---------------------------------------------------------------------
-- Which orders are past the day we promised
-- ---------------------------------------------------------------------
create or replace function public.report_late_orders(
  p_org_id uuid, p_as_at date default null)
returns table (
  document_id uuid, doc_no text, doc_date date, delivery_date date,
  days_late integer, contact_name text,
  ordered numeric, fulfilled numeric, outstanding numeric, amount numeric)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  with asked as (
    select d.id, d.doc_no, d.doc_date, d.delivery_date, d.total_amount,
           c.name as contact_name,
           coalesce(sum(l.quantity), 0) as ordered,
           coalesce(sum(l.quantity_fulfilled), 0) as fulfilled
      from public.sales_documents d
      left join public.contacts c on c.id = d.contact_id
      left join public.sales_document_lines l on l.document_id = d.id
     where d.org_id = p_org_id
       and d.doc_type = 'sales_order'
       and d.deleted_at is null
       and d.status not in ('draft', 'void')
       and d.delivery_date is not null
       and d.delivery_date < coalesce(p_as_at, current_date)
     group by d.id, d.doc_no, d.doc_date, d.delivery_date, d.total_amount, c.name)
  select a.id, a.doc_no, a.doc_date, a.delivery_date,
         (coalesce(p_as_at, current_date) - a.delivery_date)::integer,
         a.contact_name, a.ordered, a.fulfilled, a.ordered - a.fulfilled,
         a.total_amount
    from asked a
   where a.ordered - a.fulfilled > 0
     and app.is_org_member(p_org_id)
   order by a.delivery_date;
$$;

revoke all on function public.report_late_orders(uuid, date) from public, anon;
grant execute on function public.report_late_orders(uuid, date) to authenticated;

comment on function public.report_late_orders(uuid, date) is
  'Sales orders past the delivery date they were given, with what is '
  'still unshipped. Measured on the lines rather than the status: an '
  'order nine tenths shipped is late on the tenth that is not.';

-- ---------------------------------------------------------------------
-- And the transfer honours both
-- ---------------------------------------------------------------------
create or replace function public.transfer_document(
  p_source_id uuid,
  p_target_type text,
  p_lines jsonb default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_sales      public.sales_documents;
  v_purchase   public.purchase_documents;
  v_is_sales   boolean;
  v_org        uuid;
  v_source_type text;
  v_counter    text;
  v_new_id     uuid;
  v_doc_no     text;
  v_due        date;
  v_term_id    uuid;
  v_term_days  integer;
  v_no         integer := 0;
  v_want       numeric(18, 4);
  v_left       numeric(18, 4);
  r            record;
begin
  select * into v_sales from public.sales_documents where id = p_source_id;
  v_is_sales := found;

  if v_is_sales then
    v_org := v_sales.org_id;
    v_source_type := v_sales.doc_type::text;
    if v_sales.deleted_at is not null or v_sales.status = 'void' then
      raise exception 'Document % has been voided', v_sales.doc_no
        using errcode = '23514';
    end if;
  else
    select * into v_purchase from public.purchase_documents where id = p_source_id;
    if not found then
      raise exception 'Document % not found', p_source_id using errcode = 'P0002';
    end if;
    v_org := v_purchase.org_id;
    v_source_type := v_purchase.doc_type::text;
    if v_purchase.deleted_at is not null or v_purchase.status = 'void' then
      raise exception 'Document % has been voided', v_purchase.doc_no
        using errcode = '23514';
    end if;
  end if;

  if not app.can_write(v_org) then
    raise exception 'Insufficient privileges to transfer' using errcode = '42501';
  end if;

  -- 0374. A price that ran out. A quotation and a proforma are both
  -- offers with a date on them, and turning one into an order or an
  -- invoice after that date charges last quarter's price for this
  -- quarter's work — quietly, because every downstream figure agrees
  -- with it. Refused rather than warned: honouring an expired quote is
  -- a decision somebody makes, and `extend_document_validity` is where
  -- they make it and where it is recorded.
  if v_is_sales
     and v_sales.doc_type in ('quotation', 'proforma')
     and v_sales.valid_until is not null
     and v_sales.valid_until < current_date then
    raise exception
      '% was only valid until %. Extend it, or raise a new one at '
      'today''s prices.', v_sales.doc_no, to_char(v_sales.valid_until, 'DD Mon YYYY')
      using errcode = '23514';
  end if;

  -- Raises on a transition that is not part of either cycle.
  v_counter := app.transfer_counter(v_source_type, p_target_type);

  v_doc_no := app.next_document_number_internal(v_org, p_target_type);

  -- A document that will be settled needs a due date; ageing is built on
  -- it and a null there quietly parks the debt in "not yet due" forever.
  if p_target_type in ('invoice', 'bill') then
    v_term_id := case when v_is_sales then v_sales.payment_term_id
                      else v_purchase.payment_term_id end;
    if v_term_id is not null then
      select days into v_term_days from public.payment_terms where id = v_term_id;
    end if;
    v_due := current_date + coalesce(v_term_days, 30);
  end if;

  if v_is_sales then
    insert into public.sales_documents (
      org_id, doc_type, doc_no, doc_date, due_date, contact_id,
      contact_person_id, shipping_address_id, reference, subject, parent_id,
      payment_term_id, currency, exchange_rate, salesperson_id,
      opportunity_id, matter_id, notes, terms_conditions, status, created_by,
      delivery_date
    ) values (
      v_org, p_target_type::app.sales_doc_type, v_doc_no, current_date, v_due,
      v_sales.contact_id, v_sales.contact_person_id, v_sales.shipping_address_id,
      v_sales.reference, v_sales.subject, v_sales.id,
      v_sales.payment_term_id, v_sales.currency, v_sales.exchange_rate,
      v_sales.salesperson_id, v_sales.opportunity_id, v_sales.matter_id,
      v_sales.notes, v_sales.terms_conditions, 'draft', auth.uid(),
      -- 0374. The date promised on the quotation is the date promised on
      -- the order, and on the delivery order raised from it. Dropping it
      -- at each step is how a promise becomes nobody's.
      case when p_target_type in ('sales_order', 'delivery_order')
           then v_sales.delivery_date end
    ) returning id into v_new_id;

    for r in
      select l.*,
             (select (e ->> 'quantity')::numeric
                from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
               where (e ->> 'line_id')::uuid = l.id) as asked
        from public.sales_document_lines l
       where l.document_id = p_source_id
       order by l.line_no
    loop
      v_left := r.quantity - case v_counter
        when 'quantity_invoiced' then r.quantity_invoiced
        else r.quantity_fulfilled end;

      v_want := case when p_lines is null then greatest(v_left, 0)
                     else coalesce(r.asked, 0) end;
      if v_want <= 0 then continue; end if;

      if v_want > v_left then
        raise exception
          'Line % has % outstanding; % was asked for.',
          r.line_no, v_left, v_want using errcode = '23514';
      end if;

      v_no := v_no + 1;
      insert into public.sales_document_lines (
        org_id, document_id, line_no, line_type, item_id, description,
        classification_code, quantity, uom_code, unit_price, discount_percent,
        discount_amount, tax_code_id, tax_rate, is_tax_inclusive, warehouse_id,
        account_id, project_code, department_code, source_line_id,
        service_start, service_end
      ) values (
        v_org, v_new_id, v_no, r.line_type, r.item_id, r.description,
        r.classification_code, v_want, r.uom_code, r.unit_price,
        r.discount_percent,
        -- A cash discount is proportional to what is being taken, not
        -- carried whole onto a partial transfer.
        case when r.quantity = 0 then 0
             else round(r.discount_amount * v_want / r.quantity, 2) end,
        r.tax_code_id, r.tax_rate, r.is_tax_inclusive, r.warehouse_id,
        r.account_id, r.project_code, r.department_code, r.id,
        -- The period is a property of what was sold, not of the piece of
        -- paper it was first written on. Dropping it here would let a
        -- quoted twelve-month contract arrive at the invoice as income
        -- earned on the day, and nobody would see it go.
        r.service_start, r.service_end
      );
    end loop;
  else
    insert into public.purchase_documents (
      org_id, doc_type, doc_no, doc_date, due_date, contact_id,
      contact_person_id, reference, parent_id, payment_term_id,
      currency, exchange_rate, notes, status, created_by
    ) values (
      v_org, p_target_type::app.purchase_doc_type, v_doc_no, current_date, v_due,
      v_purchase.contact_id, v_purchase.contact_person_id,
      v_purchase.reference, v_purchase.id, v_purchase.payment_term_id,
      v_purchase.currency, v_purchase.exchange_rate, v_purchase.notes,
      'draft', auth.uid()
    ) returning id into v_new_id;

    for r in
      select l.*,
             (select (e ->> 'quantity')::numeric
                from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
               where (e ->> 'line_id')::uuid = l.id) as asked
        from public.purchase_document_lines l
       where l.document_id = p_source_id
       order by l.line_no
    loop
      v_left := r.quantity - case v_counter
        when 'quantity_billed' then r.quantity_billed
        else r.quantity_received end;

      v_want := case when p_lines is null then greatest(v_left, 0)
                     else coalesce(r.asked, 0) end;
      if v_want <= 0 then continue; end if;

      if v_want > v_left then
        raise exception
          'Line % has % outstanding; % was asked for.',
          r.line_no, v_left, v_want using errcode = '23514';
      end if;

      v_no := v_no + 1;
      insert into public.purchase_document_lines (
        org_id, document_id, line_no, line_type, item_id, description,
        classification_code, quantity, uom_code, unit_price, discount_percent,
        discount_amount, tax_code_id, tax_rate, is_tax_inclusive, warehouse_id,
        account_id, project_code, department_code, source_line_id
      ) values (
        v_org, v_new_id, v_no, r.line_type, r.item_id, r.description,
        r.classification_code, v_want, r.uom_code, r.unit_price,
        r.discount_percent,
        case when r.quantity = 0 then 0
             else round(r.discount_amount * v_want / r.quantity, 2) end,
        r.tax_code_id, r.tax_rate, r.is_tax_inclusive, r.warehouse_id,
        r.account_id, r.project_code, r.department_code, r.id
      );
    end loop;
  end if;

  if v_no = 0 then
    -- Nothing was left to take. The empty document is rolled back rather
    -- than left behind, because a stray zero-line draft in the numbering
    -- sequence is a document somebody has to explain later.
    raise exception
      'Nothing left to transfer — every line has already been taken forward.'
      using errcode = '23514';
  end if;

  return v_new_id;
end;
$$;