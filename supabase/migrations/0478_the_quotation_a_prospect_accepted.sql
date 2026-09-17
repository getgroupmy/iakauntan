-- ---------------------------------------------------------------------
-- 0478  The quotation a prospect accepted
-- ---------------------------------------------------------------------
-- 0471 made room for a prospect -- somebody you have not sold to yet
-- -- and put it on the rule that a prospect "is not refused anything;
-- it is simply not offered": the customer picker asks for customers,
-- so a prospect is not in it. 0477 then gave one company one record
-- per role, P- for the prospect and C- for the customer, and a way to
-- make the second from the first.
--
-- Between the two sits the document a prospect exists to receive. A
-- quotation is what you send somebody you have not sold to yet; that
-- is the whole point of having them on file. But the quotation editor
-- offered customers, so a salesperson quoting a prospect had to make a
-- customer record first -- for a company that had bought nothing and
-- might never -- or leave the prospect out of the books and quote from
-- a spreadsheet. Either way the prospect list was not where the
-- prospects were.
--
-- ### What changes
--
--   * An offer may be made to a prospect. The quotation and the
--     proforma -- the two documents with a `valid_until` on them, the
--     two that ask rather than record -- pick from customers *and*
--     prospects. The invoice, the order and the delivery order still
--     pick from customers only: those record a sale, and a prospect is
--     by definition somebody there has been no sale to. The pipeline's
--     "new deal" picker offers prospects too, for the same reason a
--     deal is not a sale. This is the app's picker filter; the
--     database never refused a prospect on any document and still does
--     not.
--
--   * The accepted offer lands on the customer record. When
--     `transfer_document` takes a quotation or proforma forward into an
--     order, a delivery order or an invoice, and the source is held by
--     a prospect, the new document is made out to the company's
--     customer record -- the C- record, found through `party_id` the
--     way `create_contact_as` finds a sibling. The quotation keeps the
--     prospect: it was made to a prospect, and the ledger should say
--     so. The sale is the customer's, and the customer statement,
--     ageing and credit limit all read `contact_id`, so an invoice left
--     on the P- record would be a debt no statement ever showed.
--
--   * No customer record, no sale. Where the company has no customer
--     record yet the transfer is refused, with the remedy in the
--     message: create a Customer record for them. It is not created
--     here. 0477's instruction was that a record for a role is a
--     deliberate act -- one somebody makes from the Records sheet and
--     can see they made -- not a side effect of pressing "invoice".
--     Refusing costs a click; creating quietly costs a C- code nobody
--     asked for.
--
--   * The person and the delivery address follow, where they can.
--     `contact_person_id` and `shipping_address_id` point at the
--     prospect record's rows. `create_contact_as` copies people and
--     addresses onto the record it makes, so the customer record has a
--     row for the same person -- same name, same email -- and the same
--     door -- same label, same first line, same postcode -- and the
--     new document points at those. Where it does not (the row was
--     added to the prospect after the customer record was made, or
--     edited since) the field is left empty rather than left pointing
--     at another record's row. Best effort, and nothing invented.
--
-- ### What stays
--
-- Everything else `transfer_document` did as of 0420: the validity
-- refusal from 0374, the counters, the proration of delivery,
-- discount and service charge, the delivery date, the branch. A
-- transfer from a customer's quotation is unchanged by this: the
-- customer record is its own customer record, and the lookup answers
-- with the source.
--
-- ### Mutants
--
-- Run against `supabase/tests/prospect_quotation.sql`, each named
-- with the assertion that kills it:
--   * the lookup dropped, the invoice left on the prospect -- "the
--     invoice is the customer record's";
--   * the quotation retyped as well -- "the quotation is still the
--     prospect's";
--   * the refusal dropped where there is no customer record --
--     "refused without a customer record" and "and the remedy is
--     named";
--   * a supplier record taken for a customer one -- "a supplier
--     record is not a customer record";
--   * the lookup crossing organisations, or reading a deleted record
--     -- "a deleted customer record does not count";
--   * the person and address left pointing at the prospect's rows --
--     "the person came along, on the customer record";
--   * the person invented where there is no match -- "and an unmatched
--     one is left empty";
--   * a customer's own quotation re-pointed -- "a customer's quotation
--     transfers as before";
--   * the app's offer filter widened to every document -- pinned in
--     `app/test/contact_type_for_test.dart`.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Which record the sale goes on
-- ---------------------------------------------------------------------
-- The contact itself where it carries the customer role (a customer, or
-- a `both`); otherwise the record of the same company that does, found
-- through `party_id` on the arithmetic 0477's `create_contact_as` uses
-- to find a sibling; otherwise null. Same organization, not deleted.
create or replace function app.customer_record_of(p_contact_id uuid)
returns uuid
language sql stable
set search_path = public, app, pg_temp as $$
  with src as (
    select c.id, c.org_id, coalesce(c.party_id, c.id) as party,
           c.contact_type
      from public.contacts c
     where c.id = p_contact_id
       and c.deleted_at is null
  )
  select c.id
    from src
    join public.contacts c
      on c.org_id = src.org_id
     and c.deleted_at is null
     and (c.id = src.id or c.party_id = src.party)
   where app.contact_carries(c.contact_type, 'customer')
   -- The record itself first, so a customer answers with itself and
   -- a `both` does not answer with a sibling; then by code, as the
   -- sibling check does, so two answers are the same answer each time.
   order by (c.id = src.id) desc, c.code
   limit 1
$$;

comment on function app.customer_record_of(uuid) is
  'The record a sale to this company goes on: the contact where it is '
  'a customer, else the company''s customer record through party_id, '
  'else null. See 0478.';

-- ---------------------------------------------------------------------
-- The transfer, re-pointed
-- ---------------------------------------------------------------------
-- The body is 0420's, with the customer lookup and the person and
-- address matching added before the sales insert. Privileges are those
-- 0081 granted; `create or replace` keeps them.
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

comment on function public.transfer_document(uuid, text, jsonb) is
  'The next document in the cycle, drawn from this one: what is left '
  'of each line, the header amounts in proportion. A quotation or '
  'proforma held by a prospect is taken forward onto the company''s '
  'customer record, and refused where there is none. See 0081, 0374, '
  '0420 and 0478.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_body text := pg_get_functiondef(
    to_regprocedure('public.transfer_document(uuid, text, jsonb)'));
begin
  -- The transfer reads the one lookup, and the lookup reads the one
  -- arithmetic 0477 pinned for "carries the customer role".
  if position('app.customer_record_of' in v_body) = 0 then
    raise exception '0478: the transfer does not look for the customer record';
  end if;
  if position('app.contact_carries' in pg_get_functiondef(
       to_regprocedure('app.customer_record_of(uuid)'))) = 0 then
    raise exception
      '0478: the lookup does not read the arithmetic the sibling check does';
  end if;

  -- The refusal names the remedy 0477 built.
  if position('Create a Customer record' in v_body) = 0 then
    raise exception '0478: the refusal does not say what to do';
  end if;

  -- Nothing 0420 carried was dropped in the copying.
  if position('service_start' in v_body) = 0
     or position('service_charge_amount' in v_body) = 0
     or position('extend_document_validity' in v_body) = 0
     or position('delivery_date' in v_body) = 0 then
    raise exception '0478: the body is not 0420''s';
  end if;

  -- 0081's grant survived the replace, and the lookup is not a surface.
  if not has_function_privilege('authenticated',
       to_regprocedure('public.transfer_document(uuid, text, jsonb)'),
       'execute') then
    raise exception '0478: the editor cannot transfer';
  end if;
  if has_function_privilege('anon',
       to_regprocedure('public.transfer_document(uuid, text, jsonb)'),
       'execute') then
    raise exception '0478: anon can transfer';
  end if;
end $do$;
