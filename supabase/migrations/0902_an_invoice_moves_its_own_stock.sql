-- =====================================================================
-- iAkauntan :: 0902 an invoice moves its own stock
--
-- `0013` had posting a sales invoice skip its stock movement when its
-- parent was a delivery order: the delivery order, it said, had already
-- sent the goods. Nothing has ever moved stock on a delivery order. It
-- does not post, and the only statements in the schema that write a
-- `sales_delivery` movement are the successive restatements of this one
-- function, each skipping for the same reason. `0609` found the same
-- sentence on the purchase side, for a goods received note.
--
-- The invoice still took the cost of sales -- Dr 5200, Cr 1310 -- so
-- the ledger said the goods had gone and the stock said they had not.
--
-- Measured on 14 October 2026, locally, as the owner with the role
-- `authenticated`: ten bought at 10; three sold quotation -> invoice,
-- 7 on hand and 1310 at 70; three more sold quotation -> delivery
-- order -> invoice, still 7 on hand and 1310 at 40. Crediting that
-- invoice then put back three that had never left: 10 on hand.
--
-- Production held no delivery order on 14 October.
--
-- Answered "the invoice moves its stock": the skip goes, and an invoice
-- raised from a delivery order moves its stock when it posts, as every
-- other invoice does. A delivery order stays the paper that goes with
-- the goods.
--
-- The body is `pg_get_functiondef` of what was applied (`0889`), with
-- the change marked 0902. Nothing is backfilled.
-- =====================================================================

-- app.post_sales_document_internal
CREATE OR REPLACE FUNCTION app.post_sales_document_internal(p_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_doc         public.sales_documents;
  v_line        record;
  v_entries     jsonb := '[]'::jsonb;
  v_sign        integer;
  v_ar_account  uuid;
  v_tax_account uuid;
  v_round_acct  uuid;
  v_cogs_acct   uuid;
  v_inv_acct    uuid;
  v_rev_acct    uuid;
  v_entry_id    uuid;
  v_amount      numeric(18, 2);
  v_cogs_total  numeric(18, 2) := 0;
  v_rate        numeric(18, 8);
  v_deferred    boolean := false;
begin
  select * into v_doc from public.sales_documents where id = p_id;
  if not found then
    raise exception 'Sales document % not found', p_id;
  end if;
  if v_doc.doc_type not in ('invoice', 'credit_note', 'debit_note', 'refund_note') then
    raise exception 'Document type % does not post to the ledger', v_doc.doc_type;
  end if;
  if v_doc.gl_entry_id is not null then
    raise exception 'Document % is already posted', v_doc.doc_no;
  end if;

  -- 0889: a note adjusts the invoice it names, and cannot come before it.
  -- Dated earlier, the month between carries the adjustment without the
  -- thing adjusted.
  if v_doc.original_invoice_id is not null and v_doc.doc_date < (
       select o.doc_date from public.sales_documents o where o.id = v_doc.original_invoice_id) then
    raise exception
      '% is dated %, before % which it adjusts (dated %). A note cannot '
      'come before the invoice it adjusts.', v_doc.doc_no,
      to_char(v_doc.doc_date, 'DD Mon YYYY'),
      (select o.doc_no from public.sales_documents o where o.id = v_doc.original_invoice_id),
      to_char((select o.doc_date from public.sales_documents o where o.id = v_doc.original_invoice_id),
              'DD Mon YYYY')
      using errcode = '23514';
  end if;

  -- Credit and refund notes move the ledger the other way.
  v_sign := case when v_doc.doc_type in ('credit_note', 'refund_note') then -1 else 1 end;
  v_rate := coalesce(v_doc.exchange_rate, 1);

  select coalesce(c.receivable_account_id,
                  (select id from public.accounts
                    where org_id = v_doc.org_id and code = '1210'))
    into v_ar_account
    from public.contacts c where c.id = v_doc.contact_id;

  select id into v_tax_account from public.accounts
   where org_id = v_doc.org_id and code = '2130';
  select id into v_round_acct from public.accounts
   where org_id = v_doc.org_id and code = '4990';

  -- Receivable: debit for an invoice, credit for a credit note.
  v_amount := round(v_sign * v_doc.total_amount * v_rate, 2);
  v_entries := v_entries || jsonb_build_object(
    'account_id',  v_ar_account,
    'description', v_doc.doc_type::text || ' ' || v_doc.doc_no,
    'debit',       greatest(v_amount, 0),
    'credit',      greatest(-v_amount, 0),
    'contact_id',  v_doc.contact_id
  );

  -- Revenue, one line per document line.
  for v_line in
    select l.*, i.sales_account_id, i.track_inventory, i.cogs_account_id,
           i.inventory_account_id, i.average_cost
      from public.sales_document_lines l
      left join public.items i on i.id = l.item_id
     where l.document_id = p_id and l.line_type = 'item'
     order by l.line_no
  loop
    -- 0309. A line with a service period has not been earned yet, so
    -- the credit goes to the liability rather than to revenue. The
    -- schedule built below is what releases it, month by month. A line
    -- without one is untouched and still credits revenue on the day,
    -- which is every line this system has ever posted.
    -- 0310. Only a document that *creates* the obligation defers. A
    -- credit note is a reversal: it takes revenue back, and what it
    -- does about the liability is cancel the schedule below, not open
    -- a second one.
    if v_line.service_start is not null and v_sign = 1 then
      v_rev_acct := app.deferred_revenue_account(v_doc.org_id);
      v_deferred := true;
    else
      v_rev_acct := app.resolve_account(
        v_doc.org_id, v_line.account_id, v_line.item_id, 'sales_account_id', '4100');
    end if;

    v_amount := round(-v_sign * v_line.line_subtotal * v_rate, 2);
    if v_amount <> 0 then
      v_entries := v_entries || jsonb_build_object(
        'account_id',  v_rev_acct,
        'description', left(coalesce(v_line.description, ''), 200),
        'debit',       greatest(v_amount, 0),
        'credit',      greatest(-v_amount, 0),
        'contact_id',  v_doc.contact_id,
        'item_id',     v_line.item_id,
        'tax_code_id', v_line.tax_code_id,
        'project_code', v_line.project_code,
        'department_code', v_line.department_code,
        -- The line's, falling back to the document's. `0021` put
        -- `matter_id` on `sales_documents` five years ago and
        -- `bill_matter_time` has filled it ever since -- a fee note
        -- raised from a matter's time entries knows its matter before
        -- it has a line. Nothing ever carried it down, so those notes
        -- reached the ledger with no matter on them. The line wins
        -- where it has one, which is the same order `post_expense`
        -- uses and what makes a note covering two files work.
        'matter_id', coalesce(v_line.matter_id, v_doc.matter_id)
      );
    end if;

    -- Cost of sales for stock items.
    if v_line.track_inventory and v_line.item_id is not null then
      -- `average_cost` is per the item's own unit, so the cost of a
      -- line sold in cartons is the pieces it came to, not the number
      -- of cartons. 0270.
      v_cogs_total := v_cogs_total
        + round(coalesce(v_line.base_quantity, v_line.quantity)
                * coalesce(v_line.average_cost, 0) * v_rate, 2);
    end if;
  end loop;

  -- Header discount, if it was not already pushed down to the lines.
  if coalesce(v_doc.discount_amount, 0) > 0 then
    v_amount := round(v_sign * v_doc.discount_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '4300'),
      'description', 'Discount',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  -- SST output tax.
  if coalesce(v_doc.tax_amount, 0) <> 0 then
    v_amount := round(-v_sign * v_doc.tax_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  v_tax_account,
      'description', 'SST output tax',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0),
      'tax_amount',  abs(v_amount)
    );
  end if;

  -- Cash rounding difference.
  if coalesce(v_doc.rounding_amount, 0) <> 0 then
    v_amount := round(-v_sign * v_doc.rounding_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  v_round_acct,
      'description', 'Rounding adjustment',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  -- The service charge, in its own revenue account.
  --
  -- 4250, not 4100: a Malaysian bill reads "subject to 10% service
  -- charge and 8% service tax", the charge is revenue from service
  -- rather than from food, and a restaurant that cannot see the two
  -- apart cannot tell what it took at the table from what it took for
  -- the table. The service tax that sits on top of it is already in
  -- `tax_amount` and posts with the rest of the output tax.
  if coalesce(v_doc.service_charge_amount, 0) <> 0 then
    v_amount := round(-v_sign * v_doc.service_charge_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts
                       where org_id = v_doc.org_id and code = '4250'),
      'description', 'Service charge',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  -- Shipping charged to the customer.
  if coalesce(v_doc.shipping_amount, 0) <> 0 then
    v_amount := round(-v_sign * v_doc.shipping_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '4900'),
      'description', 'Shipping',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  -- Cost of sales pair.
  if v_cogs_total <> 0 then
    select id into v_cogs_acct from public.accounts where org_id = v_doc.org_id and code = '5200';
    select id into v_inv_acct  from public.accounts where org_id = v_doc.org_id and code = '1310';
    v_amount := round(v_sign * v_cogs_total, 2);
    v_entries := v_entries
      || jsonb_build_object('account_id', v_cogs_acct, 'description', 'Cost of goods sold',
                            'debit', greatest(v_amount, 0), 'credit', greatest(-v_amount, 0))
      || jsonb_build_object('account_id', v_inv_acct, 'description', 'Inventory movement',
                            'debit', greatest(-v_amount, 0), 'credit', greatest(v_amount, 0));
  end if;

  v_entry_id := app.create_gl_entry_internal(
    v_doc.org_id, v_doc.doc_date,
    case v_doc.doc_type
      when 'credit_note' then 'credit_note'::app.journal_source
      when 'debit_note'  then 'debit_note'::app.journal_source
      else 'sales_invoice'::app.journal_source
    end,
    v_entries,
    v_doc.doc_type::text || ' ' || v_doc.doc_no,
    'sales_documents', v_doc.id, v_doc.reference,
    v_doc.currency, v_rate
  );

  -- Move stock. 0902: whatever the parent. This skipped an invoice
  -- raised from a delivery order, as if the delivery order had moved
  -- the goods; nothing ever has -- a delivery order does not post --
  -- so they left the ledger here and never left the shelf.
  insert into public.stock_movements (
    org_id, movement_no, movement_date, movement_type, item_id, warehouse_id,
    quantity, unit_cost, source_table, source_id, source_line_id, gl_entry_id, created_by
  )
  select v_doc.org_id,
         app.next_document_number_internal(v_doc.org_id, 'stock_movement'),
         v_doc.doc_date,
         case when v_sign = 1 then 'sales_delivery' else 'sales_return' end::app.stock_movement_type,
         l.item_id,
         coalesce(l.warehouse_id, (select id from public.warehouses
                                    where org_id = v_doc.org_id and is_default limit 1)),
         -- In the item's own unit. Two cartons of twenty-four is
         -- forty-eight pieces off the shelf. 0270.
         -v_sign * coalesce(l.base_quantity, l.quantity),
         coalesce(i.average_cost, 0),
         'sales_documents', v_doc.id, l.id, v_entry_id, auth.uid()
    from public.sales_document_lines l
    join public.items i on i.id = l.item_id
   where l.document_id = p_id
     and l.line_type = 'item'
     and i.track_inventory
     and l.quantity > 0;

  update public.sales_documents
     set gl_entry_id = v_entry_id,
         status      = 'posted',
         posted_at   = now(),
         posted_by   = auth.uid()
   where id = p_id;

  -- Only when something was actually deferred, so a document of
  -- ordinary lines does no extra work and writes no empty schedule.
  if v_deferred then
    perform app.build_revenue_schedule(p_id, v_rate);
  end if;

  -- 0310. A credit note against a deferred invoice stops the rest of
  -- that invoice's schedule and returns what is left of the liability
  -- to revenue. Without this the invoice went on earning after it had
  -- been cancelled.
  if v_sign = -1 then
    perform app.cancel_revenue_schedule(p_id);
  end if;

  return v_entry_id;
end;
$function$;
