-- Turn the sales and purchase cycles into a chain.
--
-- Everything needed for this has been in the schema since 0005 and 0006
-- and none of it was ever written: `parent_id` on both headers,
-- `fulfilment_status` on both headers, `quantity_fulfilled` and
-- `quantity_invoiced` on sales lines, `quantity_received` and
-- `quantity_billed` on purchase lines. Every one of those columns is
-- still at its default in live data, because nothing has ever advanced
-- them. Meanwhile the app has screens for quotations, sales orders,
-- delivery orders, purchase orders and goods received notes, and every
-- one of those screens is a dead end: you can raise the document, and
-- then you must retype it as the next one.
--
-- That is worse than not having the screens, because the screens imply
-- the capability.
--
-- What a transfer is
-- ------------------
-- Taking some or all of a document's quantities forward into the next
-- document in the cycle, keeping the pricing, and remembering how much
-- has gone so the same goods are not delivered or billed twice.
--
-- Progress is derived, never accumulated
-- --------------------------------------
-- Each transferred line records the line it came from, and the source
-- line's counters are recomputed from its children. The tempting
-- alternative — add to a counter at transfer time — is wrong the moment
-- anybody deletes or edits the document that was transferred to: the
-- source would still claim the quantity had gone. Deriving means a
-- deleted delivery order releases its quantity back to the order with no
-- correction step, which is the same reasoning the totals triggers in
-- 0009 already follow.

-- ---------------------------------------------------------------------
-- Where a line came from
-- ---------------------------------------------------------------------
alter table public.sales_document_lines
  add column if not exists source_line_id uuid
    references public.sales_document_lines (id) on delete set null;

alter table public.purchase_document_lines
  add column if not exists source_line_id uuid
    references public.purchase_document_lines (id) on delete set null;

create index if not exists sales_document_lines_source_idx
  on public.sales_document_lines (source_line_id)
  where source_line_id is not null;

create index if not exists purchase_document_lines_source_idx
  on public.purchase_document_lines (source_line_id)
  where source_line_id is not null;

-- ---------------------------------------------------------------------
-- What each target advances
--
-- Two counters per line, because there are two independent questions a
-- business asks of an order: what is still to be delivered, and what is
-- still to be billed. They are not the same number and neither bounds
-- the other — a delivery order that has been invoiced has not stopped
-- being deliverable against its own order.
--
--   sales:    an invoice advances `quantity_invoiced`
--             anything else advances `quantity_fulfilled`
--   purchase: a bill advances `quantity_billed`
--             anything else advances `quantity_received`
--
-- A quotation taken up as a sales order therefore reads as "fulfilled".
-- For an offer that is the right word: the offer has been taken up in
-- full and there is nothing left to take up.
--
-- Raises rather than returning null for a transition that is not
-- allowed, so a caller cannot mistake "not permitted" for "nothing to
-- do".
-- ---------------------------------------------------------------------
create or replace function app.transfer_counter(
  p_source_type text, p_target_type text)
returns text
language plpgsql immutable as $$
declare v_allowed boolean;
begin
  v_allowed := case p_source_type
    when 'quotation'        then p_target_type in ('sales_order', 'delivery_order', 'invoice')
    when 'proforma'         then p_target_type in ('invoice')
    when 'sales_order'      then p_target_type in ('delivery_order', 'invoice')
    when 'delivery_order'   then p_target_type in ('invoice')
    when 'purchase_request' then p_target_type in ('purchase_order')
    when 'purchase_order'   then p_target_type in ('goods_received', 'bill')
    when 'goods_received'   then p_target_type in ('bill')
    else false
  end;

  if not v_allowed then
    raise exception 'A % cannot be transferred to a %', p_source_type, p_target_type
      using errcode = '23514';
  end if;

  return case
    when p_target_type = 'invoice' then 'quantity_invoiced'
    when p_target_type = 'bill'    then 'quantity_billed'
    when p_source_type in ('quotation', 'proforma', 'sales_order', 'delivery_order')
      then 'quantity_fulfilled'
    else 'quantity_received'
  end;
end;
$$;

-- ---------------------------------------------------------------------
-- Recompute one source line, and the header it belongs to
--
-- `fulfilled` on the header means every line has been fully passed on by
-- one route or the other. A line that has been delivered in full is done
-- even if it has not been invoiced from here, because the invoice will
-- come off the delivery order — chasing it further up the chain would
-- report the order as outstanding forever.
-- ---------------------------------------------------------------------
create or replace function app.refresh_sales_progress(p_line_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_doc_id uuid;
  v_invoiced numeric(18, 4);
  v_fulfilled numeric(18, 4);
begin
  if p_line_id is null then return; end if;

  select coalesce(sum(c.quantity) filter (where d.doc_type = 'invoice'), 0),
         coalesce(sum(c.quantity) filter (where d.doc_type <> 'invoice'), 0)
    into v_invoiced, v_fulfilled
    from public.sales_document_lines c
    join public.sales_documents d on d.id = c.document_id
   where c.source_line_id = p_line_id
     and d.deleted_at is null and d.status <> 'void';

  -- Written only when it has actually moved. The update fires this same
  -- trigger on the line above, which is how progress climbs a
  -- quotation → order → delivery chain; without this guard it would
  -- climb it on every write whether anything changed or not.
  update public.sales_document_lines l
     set quantity_invoiced = v_invoiced,
         quantity_fulfilled = v_fulfilled
   where l.id = p_line_id
     and (l.quantity_invoiced is distinct from v_invoiced
       or l.quantity_fulfilled is distinct from v_fulfilled)
   returning l.document_id into v_doc_id;

  if v_doc_id is null then return; end if;

  update public.sales_documents d
     set fulfilment_status = case
           when not exists (
             select 1 from public.sales_document_lines l
              where l.document_id = d.id
                and greatest(l.quantity_fulfilled, l.quantity_invoiced) < l.quantity)
             then 'fulfilled'
           when exists (
             select 1 from public.sales_document_lines l
              where l.document_id = d.id
                and greatest(l.quantity_fulfilled, l.quantity_invoiced) > 0)
             then 'partial'
           else 'pending'
         end
   where d.id = v_doc_id and d.fulfilment_status <> 'cancelled';
end;
$$;

create or replace function app.refresh_purchase_progress(p_line_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
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
                and greatest(l.quantity_received, l.quantity_billed) < l.quantity)
             then 'fulfilled'
           when exists (
             select 1 from public.purchase_document_lines l
              where l.document_id = d.id
                and greatest(l.quantity_received, l.quantity_billed) > 0)
             then 'partial'
           else 'pending'
         end
   where d.id = v_doc_id and d.fulfilment_status <> 'cancelled';
end;
$$;

-- ---------------------------------------------------------------------
-- Keep them current
--
-- Both the old and the new source are refreshed on an update, so moving
-- a line from one order to another releases the first and consumes the
-- second. The recursion this would otherwise cause — refreshing a line
-- updates that line, which fires the trigger again — is stopped by the
-- trigger firing only when `source_line_id` is involved, which the
-- refresh itself never touches.
-- ---------------------------------------------------------------------
create or replace function app.sales_progress_trigger()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform app.refresh_sales_progress(old.source_line_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    if tg_op = 'INSERT' or new.source_line_id is distinct from old.source_line_id then
      perform app.refresh_sales_progress(new.source_line_id);
    elsif new.quantity is distinct from old.quantity then
      perform app.refresh_sales_progress(new.source_line_id);
    end if;
  end if;
  return coalesce(new, old);
end;
$$;

create or replace function app.purchase_progress_trigger()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform app.refresh_purchase_progress(old.source_line_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    if tg_op = 'INSERT' or new.source_line_id is distinct from old.source_line_id then
      perform app.refresh_purchase_progress(new.source_line_id);
    elsif new.quantity is distinct from old.quantity then
      perform app.refresh_purchase_progress(new.source_line_id);
    end if;
  end if;
  return coalesce(new, old);
end;
$$;

-- A document can stop counting without any of its lines being touched:
-- voiding it, or soft-deleting it, does exactly that. Both leave the
-- lines untouched, so the line trigger never fires and the order it came
-- from would go on believing the goods had gone out on a delivery note
-- that no longer stands.
create or replace function app.sales_document_progress_trigger()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_source uuid;
begin
  if new.status is distinct from old.status
     or new.deleted_at is distinct from old.deleted_at then
    for v_source in
      select distinct source_line_id from public.sales_document_lines
       where document_id = new.id and source_line_id is not null
    loop
      perform app.refresh_sales_progress(v_source);
    end loop;
  end if;
  return new;
end;
$$;

create or replace function app.purchase_document_progress_trigger()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_source uuid;
begin
  if new.status is distinct from old.status
     or new.deleted_at is distinct from old.deleted_at then
    for v_source in
      select distinct source_line_id from public.purchase_document_lines
       where document_id = new.id and source_line_id is not null
    loop
      perform app.refresh_purchase_progress(v_source);
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists track_progress on public.sales_document_lines;
create trigger track_progress
  after insert or update or delete on public.sales_document_lines
  for each row execute function app.sales_progress_trigger();

drop trigger if exists release_on_void on public.sales_documents;
create trigger release_on_void
  after update on public.sales_documents
  for each row execute function app.sales_document_progress_trigger();

drop trigger if exists release_on_void on public.purchase_documents;
create trigger release_on_void
  after update on public.purchase_documents
  for each row execute function app.purchase_document_progress_trigger();

drop trigger if exists track_progress on public.purchase_document_lines;
create trigger track_progress
  after insert or update or delete on public.purchase_document_lines
  for each row execute function app.purchase_progress_trigger();

-- ---------------------------------------------------------------------
-- The transfer itself
--
-- `p_lines` is [{"line_id": uuid, "quantity": numeric}, ...]. Omit it to
-- take everything still outstanding, which is the common case and the
-- one the "Transfer all" button uses.
--
-- Refuses rather than clamps when asked for more than remains. Clamping
-- would silently deliver nine of the ten somebody asked for and report
-- success, and the difference would not surface until the customer
-- counted the boxes.
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
             coalesce((
               select (e ->> 'quantity')::numeric
                 from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
                where (e ->> 'line_id')::uuid = l.id), null) as asked
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
             coalesce((
               select (e ->> 'quantity')::numeric
                 from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
                where (e ->> 'line_id')::uuid = l.id), null) as asked
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

-- What is still outstanding on a document, for the transfer dialog to
-- show before anything is created.
create or replace function public.transfer_outstanding(
  p_source_id uuid, p_target_type text)
returns table (
  line_id uuid, line_no integer, description text,
  quantity numeric, taken numeric, outstanding numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
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

  if not app.is_org_member(v_org) then
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
    return query
      select l.id, l.line_no, l.description, l.quantity,
             case v_counter when 'quantity_billed' then l.quantity_billed
                            else l.quantity_received end,
             greatest(l.quantity - case v_counter
               when 'quantity_billed' then l.quantity_billed
               else l.quantity_received end, 0)
        from public.purchase_document_lines l
       where l.document_id = p_source_id
       order by l.line_no;
  end if;
end;
$$;

-- PostgreSQL grants EXECUTE to PUBLIC by default, and anon is a member
-- of PUBLIC. Every one of these carries the definer's rights, so the
-- default has to be revoked before the grant means anything — the same
-- correction as 0080.
revoke all on function app.transfer_counter(text, text) from public, anon, authenticated;
revoke all on function app.refresh_sales_progress(uuid) from public, anon, authenticated;
revoke all on function app.refresh_purchase_progress(uuid) from public, anon, authenticated;
revoke all on function app.sales_progress_trigger() from public, anon, authenticated;
revoke all on function app.purchase_progress_trigger() from public, anon, authenticated;
revoke all on function app.sales_document_progress_trigger() from public, anon, authenticated;
revoke all on function app.purchase_document_progress_trigger() from public, anon, authenticated;

revoke all on function public.transfer_document(uuid, text, jsonb) from public, anon;
grant execute on function public.transfer_document(uuid, text, jsonb) to authenticated;

revoke all on function public.transfer_outstanding(uuid, text) from public, anon;
grant execute on function public.transfer_outstanding(uuid, text) to authenticated;

comment on column public.sales_document_lines.source_line_id is
  'The line this was transferred from. Progress counters on the source are derived from this, never accumulated.';
comment on column public.purchase_document_lines.source_line_id is
  'The line this was transferred from. Progress counters on the source are derived from this, never accumulated.';
