-- `transfer_document`: `coalesce(x, null)` is `x`.
--
-- Last of the three functions the drift check flagged. The difference is
-- the smallest of the set and, like `0176`, it is the repository
-- carrying something that does nothing.
--
-- Both loops — the sales branch and the purchase branch — wrap the
-- "how much was asked for on this line" subquery in a `coalesce` whose
-- second argument is `null`:
--
--     coalesce((
--       select (e ->> 'quantity')::numeric
--         from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
--        where (e ->> 'line_id')::uuid = l.id), null) as asked
--
-- `coalesce(x, null)` returns `x` when `x` is not null, and `null`
-- otherwise — which is `x`. It cannot change a value, cannot raise, and
-- cannot be reached by a row the bare subquery would have answered
-- differently. The hosted project drops it and keeps the subquery:
--
--     (select (e ->> 'quantity')::numeric
--        from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
--       where (e ->> 'line_id')::uuid = l.id) as asked
--
-- Note that the *inner* `coalesce(p_lines, '[]'::jsonb)` is real and
-- stays: `p_lines` genuinely defaults to null, and
-- `jsonb_array_elements(null)` is not an empty set. Only the outer
-- wrapper goes.
--
-- ## Why bother
--
-- Nothing breaks either way, and this migration changes no behaviour.
-- It exists because the drift check compares text, and a difference it
-- cannot resolve is a difference it has to report — every run, forever,
-- alongside the ones that matter. A permanent known-benign finding is
-- how a check stops being read. Closing it costs one no-op statement.
--
-- The alternative would have been to teach `scripts/schema_drift.py` to
-- normalise `coalesce(x, null)` away. That is worse: it is a rule about
-- SQL semantics living in a text comparison, it would need a rule for
-- the next benign difference too, and each one widens the blind spot
-- the check is supposed to be closing.
--
-- ## Verified, not assumed
--
-- With the wrapper removed from both branches the body normalises
-- byte-for-byte to the hosted project's, under the same `code()`
-- normalisation `scripts/schema_drift.py` uses
-- (`0cc7686ae15bc069d29ce9a8da23a928`).
--
-- With `0176`, `0177` and this one applied, the migrations and the
-- hosted project hold the same definition for every function either of
-- them has, and the drift check should run clean.

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
      opportunity_id, matter_id, notes, terms_conditions, status, created_by
    ) values (
      v_org, p_target_type::app.sales_doc_type, v_doc_no, current_date, v_due,
      v_sales.contact_id, v_sales.contact_person_id, v_sales.shipping_address_id,
      v_sales.reference, v_sales.subject, v_sales.id,
      v_sales.payment_term_id, v_sales.currency, v_sales.exchange_rate,
      v_sales.salesperson_id, v_sales.opportunity_id, v_sales.matter_id,
      v_sales.notes, v_sales.terms_conditions, 'draft', auth.uid()
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
        account_id, project_code, department_code, source_line_id
      ) values (
        v_org, v_new_id, v_no, r.line_type, r.item_id, r.description,
        r.classification_code, v_want, r.uom_code, r.unit_price,
        r.discount_percent,
        -- A cash discount is proportional to what is being taken, not
        -- carried whole onto a partial transfer.
        case when r.quantity = 0 then 0
             else round(r.discount_amount * v_want / r.quantity, 2) end,
        r.tax_code_id, r.tax_rate, r.is_tax_inclusive, r.warehouse_id,
        r.account_id, r.project_code, r.department_code, r.id
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
