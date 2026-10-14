-- =====================================================================
-- iAkauntan :: 0903 one road per order line
--
-- A purchase order goes forward two ways: to a goods received note
-- (`0609` made the note receive the goods and accrue 2118 for them),
-- or straight to a bill, which receives the goods itself. The two were
-- counted apart -- `quantity_received` and `quantity_billed` -- so one
-- order line could go both ways, and each received the goods.
--
-- Measured on 14 October 2026, locally, as the owner with the role
-- `authenticated`: ten ordered at 25 and received on a note (10 on
-- hand, 1310 at 250, 2118 at -250); then the ten billed from the order
-- rather than the note -- 20 on hand, 1310 at 500, 2110 at -250, and
-- the 250 accrued in 2118 never cleared.
--
-- Production on 14 October: ten purchase orders, no goods received
-- notes, no bill raised from an order.
--
-- Answered "one road per order line":
--
--   * `transfer_document` takes a note and a bill from a purchase
--     order out of the same quantity -- ordered, less received on
--     notes, less billed straight from the order -- and, when the
--     other road took all of it, says which and where to go;
--   * `transfer_outstanding`, what the transfer dialog offers, counts
--     the same way;
--   * `app.refresh_purchase_progress` calls an order fulfilled when the
--     two together took it. A requisition is only ever received and a
--     note only ever billed, so the sum is the old figure for both.
--
-- Goods received on a note are billed from the note, as `0609` built.
-- Each body is `pg_get_functiondef` of what was applied, with the
-- change marked 0903. Nothing is backfilled.
-- =====================================================================

-- public.transfer_document
CREATE OR REPLACE FUNCTION public.transfer_document(p_source_id uuid, p_target_type text, p_lines jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
  v_share      numeric(18, 8);
  v_src_net    numeric(18, 2);
  v_new_net    numeric(18, 2);
  -- 0646. What an approval rule would be about, if one covered this.
  v_kind       app.approval_entity;
  v_amount     numeric(18, 2);
  -- 0478. Who the new document is made out to, and their rows.
  v_holder     public.contacts;
  v_contact    uuid;
  v_person     uuid;
  v_address    uuid;
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
  perform app.require_side(v_org, case when v_is_sales then 'sales' else 'purchases' end);

  -- 0646. An approval rule that nothing consulted.
  --
  -- `app.refuse_unapproved_posting` is the only place an approval
  -- decision was ever read, and it fires on the transition into
  -- `posted`. SEVEN of the fifteen document types never post --
  -- quotation, proforma, sales order, delivery order, purchase
  -- requisition, purchase order, purchase return -- and the rule
  -- editor offers every one of them. So a company could set "purchase
  -- orders over ten thousand need the owner", save it, watch it appear
  -- in the list, submit an order for approval, have somebody approve
  -- it -- and the answer was written to a table nothing asked.
  --
  -- The transfer is where a document that does not post becomes an
  -- act: a requisition becomes an order, an order becomes goods
  -- received, a quotation becomes a sale. So the decision is read here
  -- too, with the same two functions the posting trigger uses, and a
  -- rule means the same thing whichever kind of document carries it.
  --
  -- On the SOURCE, not the target. The thing being authorised is
  -- acting on this document; a requisition is approved and then
  -- becomes an order, which is the order procurement is done in
  -- everywhere. The target gets its own gate at posting if it posts.
  --
  -- It inherits `app.approval_required`'s fail-open on the module, for
  -- the reason `approvals.sql` sets out at length: a company whose
  -- add-on lapsed must not be left holding documents it cannot move
  -- and no screen to release them.
  v_kind := case when v_is_sales then 'sales_document'
                 else 'purchase_document' end;
  v_amount := case when v_is_sales then v_sales.total_amount
                   else v_purchase.total_amount end;
  if app.approval_required(v_org, v_kind, v_source_type, v_amount)
     and not app.is_approved(v_org, v_kind, p_source_id) then
    raise exception
      '% needs approving before it can be turned into a %. Send it for '
      'approval first.',
      case when v_is_sales then v_sales.doc_no else v_purchase.doc_no end,
      replace(p_target_type, '_', ' ')
      using errcode = '42501';
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
     and v_sales.valid_until < app.today() then
    raise exception
      '% was only valid until %. Extend it, or raise a new one at '
      'today''s prices.', v_sales.doc_no, to_char(v_sales.valid_until, 'DD Mon YYYY')
      using errcode = '23514';
  end if;

  -- Raises on a transition that is not part of either cycle.
  v_counter := app.transfer_counter(v_source_type, p_target_type);

  -- 0478. The offer was made to a prospect; the sale is the customer
  -- record's. Resolved before anything is written.
  if v_is_sales then
    v_contact := v_sales.contact_id;
    v_person  := v_sales.contact_person_id;
    v_address := v_sales.shipping_address_id;

    select * into v_holder from public.contacts where id = v_sales.contact_id;
    if v_holder.contact_type = 'prospect' then
      v_contact := app.customer_record_of(v_sales.contact_id);
      if v_contact is null then
        raise exception
          '% is a prospect. Create a Customer record for them first; '
          'the % is then made out to it.',
          v_holder.name,
          replace(p_target_type, '_', ' ')
          using errcode = '23514',
                hint = 'Open the prospect, then Records, then '
                       '"Create a Customer record".';
      end if;

      -- The same person and the same door, on the customer record's
      -- own rows; empty where there is no such row, never the
      -- prospect's.
      select p2.id into v_person
        from public.contact_persons p1
        join public.contact_persons p2
          on p2.contact_id = v_contact
         and p2.name = p1.name
         and coalesce(p2.email, '') = coalesce(p1.email, '')
       where p1.id = v_sales.contact_person_id
       order by p2.is_primary desc, p2.created_at
       limit 1;
      if not found then v_person := null; end if;

      select a2.id into v_address
        from public.contact_addresses a1
        join public.contact_addresses a2
          on a2.contact_id = v_contact
         and a2.label = a1.label
         and coalesce(a2.address_line1, '') = coalesce(a1.address_line1, '')
         and coalesce(a2.postcode, '') = coalesce(a1.postcode, '')
       where a1.id = v_sales.shipping_address_id
       order by a2.is_default desc, a2.created_at
       limit 1;
      if not found then v_address := null; end if;
    end if;
  end if;

  v_doc_no := app.next_document_number_internal(v_org, p_target_type);

  -- A document that will be settled needs a due date; ageing is built on
  -- it and a null there quietly parks the debt in "not yet due" forever.
  if p_target_type in ('invoice', 'bill') then
    v_term_id := case when v_is_sales then v_sales.payment_term_id
                      else v_purchase.payment_term_id end;
    if v_term_id is not null then
      select days into v_term_days from public.payment_terms where id = v_term_id;
    end if;
    v_due := app.today() + coalesce(v_term_days, 30);
  end if;

  if v_is_sales then
    insert into public.sales_documents (
      org_id, doc_type, doc_no, doc_date, due_date, contact_id,
      contact_person_id, shipping_address_id, reference, subject, parent_id,
      payment_term_id, currency, exchange_rate, salesperson_id,
      opportunity_id, matter_id, branch_id, notes, terms_conditions, status,
      created_by, delivery_date
    ) values (
      v_org, p_target_type::app.sales_doc_type, v_doc_no, app.today(), v_due,
      v_contact, v_person, v_address,
      v_sales.reference, v_sales.subject, v_sales.id,
      v_sales.payment_term_id, v_sales.currency, v_sales.exchange_rate,
      v_sales.salesperson_id, v_sales.opportunity_id, v_sales.matter_id,
      -- Which branch quoted it is which branch invoices it. An amount
      -- can be split across two invoices; a branch cannot, so this
      -- carries whole.
      v_sales.branch_id,
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

    -- The header amounts, on the same rule the line above states:
    -- proportional to what is being taken, not carried whole onto a
    -- partial transfer and not dropped on a whole one.
    --
    -- Before this they were not carried at all, so a quotation for
    -- RM1000 of goods with RM50 delivery and RM100 off the job was
    -- invoiced at RM1080 against RM1030 quoted: the customer was billed
    -- fifty ringgit more than the price they had agreed, because the
    -- discount went and the delivery went with it.
    --
    -- The share is measured on line value rather than on quantity,
    -- because two lines at different prices are not two equal halves of
    -- a delivery charge. It is taken against the *source's* total and
    -- not against what is left, so two half-transfers add back to one
    -- whole -- exactly the property the line-level proration has.
    v_src_net := coalesce(v_sales.subtotal, 0);
    select coalesce(subtotal, 0) into v_new_net
      from public.sales_documents where id = v_new_id;

    v_share := case
      -- A document whose lines come to nothing but which carries a
      -- delivery charge. There is no value to apportion by, so the
      -- only defensible answers are all of it on a whole transfer and
      -- none of it on a partial one.
      when v_src_net = 0 then case when p_lines is null then 1 else 0 end
      else v_new_net / v_src_net
    end;

    update public.sales_documents d
       set shipping_amount = round(coalesce(v_sales.shipping_amount, 0) * v_share, 2),
           discount_amount = round(coalesce(v_sales.discount_amount, 0) * v_share, 2),
           service_charge_amount =
             round(coalesce(v_sales.service_charge_amount, 0) * v_share, 2)
     where d.id = v_new_id;

    -- And then let the arithmetic be done by the one function that owns
    -- it. `app.recalc_sales_totals` is a trigger on the *lines*, so a
    -- header amount written after the last line is in the row and not
    -- in the total -- which is how the figures above came to disagree
    -- with each other in the first place. Touching a line re-runs it
    -- over the header this function has just finished writing.
    --
    -- Rather than either of the alternatives: computing the share
    -- before the header insert would mean writing the `v_want`
    -- expression a second time, where the two copies can drift apart
    -- silently; and setting `total_amount` here by hand would put this
    -- function in the business of arithmetic that belongs somewhere
    -- else, on a draft somebody is still going to edit.
    update public.sales_document_lines
       set line_no = line_no where document_id = v_new_id;
  else
    insert into public.purchase_documents (
      org_id, doc_type, doc_no, doc_date, due_date, contact_id,
      contact_person_id, reference, parent_id, payment_term_id,
      currency, exchange_rate, branch_id, notes, status, created_by
    ) values (
      v_org, p_target_type::app.purchase_doc_type, v_doc_no, app.today(), v_due,
      v_purchase.contact_id, v_purchase.contact_person_id,
      v_purchase.reference, v_purchase.id, v_purchase.payment_term_id,
      v_purchase.currency, v_purchase.exchange_rate, v_purchase.branch_id,
      v_purchase.notes, 'draft', auth.uid()
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
      -- 0903. On a purchase order a goods received note and a bill
      -- raised straight from the order each receive the goods, so the
      -- two draw on the one quantity. Goods received on a note are
      -- billed from the note, which clears what it accrued.
      v_left := r.quantity - case
        when v_source_type = 'purchase_order'
          then r.quantity_received + r.quantity_billed
        when v_counter = 'quantity_billed' then r.quantity_billed
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

    -- The same on the buying side. A purchase order with carriage on it
    -- part-received and part-billed would otherwise be billed for the
    -- goods and never for the carriage. There is no service charge on a
    -- purchase document: a supplier's is a line on their bill.
    v_src_net := coalesce(v_purchase.subtotal, 0);
    select coalesce(subtotal, 0) into v_new_net
      from public.purchase_documents where id = v_new_id;

    v_share := case
      when v_src_net = 0 then case when p_lines is null then 1 else 0 end
      else v_new_net / v_src_net
    end;

    update public.purchase_documents d
       set shipping_amount = round(coalesce(v_purchase.shipping_amount, 0) * v_share, 2),
           discount_amount = round(coalesce(v_purchase.discount_amount, 0) * v_share, 2)
     where d.id = v_new_id;

    -- The same touch, for the same reason.
    update public.purchase_document_lines
       set line_no = line_no where document_id = v_new_id;
  end if;

  if v_no = 0 then
    -- 0903. Where the other road took it, say which, and where to go.
    if not v_is_sales and v_source_type = 'purchase_order'
       and p_lines is null
       and exists (select 1 from public.purchase_document_lines l
                    where l.document_id = p_source_id
                      and case p_target_type when 'bill' then l.quantity_received
                                             else l.quantity_billed end > 0) then
      raise exception '%', case p_target_type
        when 'bill' then format(
          '%s has been received on a goods received note. Bill it from '
          'the note, which clears what the note accrued.', v_purchase.doc_no)
        else format(
          '%s has been billed straight from the order, and that bill '
          'received the goods.', v_purchase.doc_no) end
        using errcode = '23514';
    end if;
    -- Nothing was left to take. The empty document is rolled back rather
    -- than left behind, because a stray zero-line draft in the numbering
    -- sequence is a document somebody has to explain later.
    raise exception
      'Nothing left to transfer — every line has already been taken forward.'
      using errcode = '23514';
  end if;

  return v_new_id;
end;
$function$;

-- public.transfer_outstanding
CREATE OR REPLACE FUNCTION public.transfer_outstanding(p_source_id uuid, p_target_type text)
 RETURNS TABLE(line_id uuid, line_no integer, description text, quantity numeric, taken numeric, outstanding numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org uuid; v_type text; v_counter text; v_is_sales boolean;
begin
  select org_id, doc_type::text into v_org, v_type
    from public.sales_documents where id = p_source_id;
  v_is_sales := found;

  if not v_is_sales then
    select org_id, doc_type::text into v_org, v_type
      from public.purchase_documents where id = p_source_id;
    if not found then
      raise exception 'Document % not found', p_source_id using errcode = 'P0002';
    end if;
  end if;

  if not app.is_staff_member(v_org) then
    raise exception 'Not a member of organization %', v_org using errcode = '42501';
  end if;

  v_counter := app.transfer_counter(v_type, p_target_type);

  if v_is_sales then
    return query
      select l.id, l.line_no, l.description, l.quantity,
             case v_counter when 'quantity_invoiced' then l.quantity_invoiced
                            else l.quantity_fulfilled end,
             greatest(l.quantity - case v_counter
               when 'quantity_invoiced' then l.quantity_invoiced
               else l.quantity_fulfilled end, 0)
        from public.sales_document_lines l
       where l.document_id = p_source_id
       order by l.line_no;
  else
    -- 0903. On a purchase order the note and the bill draw on the one
    -- quantity, as transfer_document now takes them.
    return query
      select l.id, l.line_no, l.description, l.quantity,
             case when v_type = 'purchase_order'
                    then l.quantity_received + l.quantity_billed
                  when v_counter = 'quantity_billed' then l.quantity_billed
                  else l.quantity_received end,
             greatest(l.quantity - case
               when v_type = 'purchase_order'
                 then l.quantity_received + l.quantity_billed
               when v_counter = 'quantity_billed' then l.quantity_billed
               else l.quantity_received end, 0)
        from public.purchase_document_lines l
       where l.document_id = p_source_id
       order by l.line_no;
  end if;
end;
$function$;

-- app.refresh_purchase_progress
CREATE OR REPLACE FUNCTION app.refresh_purchase_progress(p_line_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_doc_id uuid;
  v_billed numeric(18, 4);
  v_received numeric(18, 4);
begin
  if p_line_id is null then return; end if;

  select coalesce(sum(c.quantity) filter (where d.doc_type = 'bill'), 0),
         coalesce(sum(c.quantity) filter (where d.doc_type <> 'bill'), 0)
    into v_billed, v_received
    from public.purchase_document_lines c
    join public.purchase_documents d on d.id = c.document_id
   where c.source_line_id = p_line_id
     and d.deleted_at is null and d.status <> 'void';

  update public.purchase_document_lines l
     set quantity_billed = v_billed,
         quantity_received = v_received
   where l.id = p_line_id
     and (l.quantity_billed is distinct from v_billed
       or l.quantity_received is distinct from v_received)
   returning l.document_id into v_doc_id;

  if v_doc_id is null then return; end if;

  update public.purchase_documents d
     set fulfilment_status = case
           when not exists (
             select 1 from public.purchase_document_lines l
              where l.document_id = d.id
                -- 0903: the two roads together. A requisition is only
                -- ever received and a note only ever billed, so the sum
                -- is the old figure for both.
                and l.quantity_received + l.quantity_billed < l.quantity)
             then 'fulfilled'
           when exists (
             select 1 from public.purchase_document_lines l
              where l.document_id = d.id
                and l.quantity_received + l.quantity_billed > 0)
             then 'partial'
           else 'pending'
         end
   where d.id = v_doc_id and d.fulfilment_status <> 'cancelled';
end;
$function$;
