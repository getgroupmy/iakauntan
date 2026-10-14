-- =====================================================================
-- iAkauntan :: 0889 a note never comes before what it adjusts
--
-- 0888's shape, one step over. `credit_sales_invoice` -- the app's
-- "credit this invoice" -- and `credit_purchase_bill` dated the credit
-- note today, so crediting a document dated ahead put the credit before
-- the sale. And a note typed by hand that names its invoice or bill was
-- posted whatever its date.
--
-- Measured on 14 October 2026, locally, as an accountant with the role
-- `authenticated`: crediting an invoice dated 3 November made a credit
-- note dated 14 October; a credit note typed by hand against an invoice
-- dated 14 October, dated 4 October, posted.
--
-- Production held no credit or debit note linked to an invoice or bill
-- on 14 October.
--
-- Answered "never before what it credits":
--
--   * posting a sales note that names its invoice
--     (`original_invoice_id`), or a purchase note that names its bill
--     (`original_bill_id`), refuses a date before that document's;
--   * `credit_sales_invoice` and `credit_purchase_bill` date the note on
--     the later of today and the original's date.
--
-- A note that names no original is not asked: there is nothing to come
-- before.
--
-- Each body is `pg_get_functiondef` of what was applied, with the
-- change marked 0889.
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
  v_from_do     boolean := false;
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

  -- Move stock, unless a delivery order already did.
  select exists (
    select 1 from public.sales_documents d
     where d.id = v_doc.parent_id and d.doc_type = 'delivery_order'
  ) into v_from_do;

  if not v_from_do then
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
  end if;

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

-- app.post_purchase_document_internal
CREATE OR REPLACE FUNCTION app.post_purchase_document_internal(p_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_doc         public.purchase_documents;
  v_line        record;
  v_entries     jsonb := '[]'::jsonb;
  v_sign        integer;
  v_ap_account  uuid;
  v_tax_account uuid;
  v_exp_acct    uuid;
  v_entry_id    uuid;
  v_amount      numeric(18, 2);
  v_rate        numeric(18, 8);
  -- 0609. Whether a posted goods received note already put this stock
  -- on the shelf and accrued what is owed for it. When it did, the
  -- bill's item lines clear that accrual instead of capitalising the
  -- stock a second time.
  v_from_grn    boolean;
  v_grni        uuid;
  v_received    integer;
  -- 0759. The header discount, spread over the lines it was taken from.
  v_disc        numeric(18, 2);
  v_lines_net   numeric(18, 2);
  v_big         uuid;
  v_run         numeric(18, 2) := 0;
  v_share       numeric(18, 2);
begin
  select * into v_doc from public.purchase_documents where id = p_id;
  if not found then
    raise exception 'Purchase document % not found', p_id;
  end if;
  if v_doc.doc_type not in ('bill', 'purchase_credit_note', 'purchase_debit_note') then
    raise exception 'Document type % does not post to the ledger', v_doc.doc_type;
  end if;
  if v_doc.gl_entry_id is not null then
    raise exception 'Document % is already posted', v_doc.doc_no;
  end if;

  -- 0889: a note adjusts the bill it names, and cannot come before it.
  -- Dated earlier, the month between carries the adjustment without the
  -- thing adjusted.
  if v_doc.original_bill_id is not null and v_doc.doc_date < (
       select o.doc_date from public.purchase_documents o where o.id = v_doc.original_bill_id) then
    raise exception
      '% is dated %, before % which it adjusts (dated %). A note cannot '
      'come before the bill it adjusts.', v_doc.doc_no,
      to_char(v_doc.doc_date, 'DD Mon YYYY'),
      (select o.doc_no from public.purchase_documents o where o.id = v_doc.original_bill_id),
      to_char((select o.doc_date from public.purchase_documents o where o.id = v_doc.original_bill_id),
              'DD Mon YYYY')
      using errcode = '23514';
  end if;

  v_sign := case when v_doc.doc_type = 'purchase_credit_note' then -1 else 1 end;
  v_rate := coalesce(v_doc.exchange_rate, 1);

  -- 0609. A POSTED goods received note, not merely a goods received
  -- note: the old test was a proxy for "the stock is already here" and
  -- a draft one is not. Until 0609 nothing ever posted one, so this was
  -- false for every bill that has ever been raised through a receiving
  -- note -- and the skip below still fired, which is how ten units
  -- bought that way arrived nowhere.
  v_from_grn := exists (
    select 1 from public.purchase_documents d
     where d.id = v_doc.parent_id
       and d.doc_type = 'goods_received'
       and d.gl_entry_id is not null);

  if v_from_grn then
    select id into v_grni from public.accounts
     where org_id = v_doc.org_id and code = '2118';
    if v_grni is null then
      raise exception 'Billing goods received on % needs account 2118, '
                      'Goods Received Not Invoiced. Add it to the chart '
                      'of accounts.', v_doc.doc_no
        using errcode = 'P0002';
    end if;
  end if;

  select coalesce(c.payable_account_id,
                  (select id from public.accounts where org_id = v_doc.org_id and code = '2110'))
    into v_ap_account
    from public.contacts c where c.id = v_doc.contact_id;

  select id into v_tax_account from public.accounts
   where org_id = v_doc.org_id and code = '1410';

  -- 0759. A header discount is taken off the costs it was given on.
  --
  -- The totals have always subtracted it -- `recalc_purchase_totals_for`
  -- -- so the payable below is net of it. Nothing here posted it, so
  -- every bill carrying one was refused as unbalanced: a 10,000 bill
  -- with 500 off was debits 10,000 against credits 9,500, and could
  -- never be posted. Intercompany bills copy the seller's header
  -- discount, and so do recurring bill templates.
  --
  -- Spread by each line's share of the net, in base currency, with the
  -- LARGEST line taking what rounding leaves -- `post_expense`'s rule
  -- (0639), so the parts always sum to the discount. Each cost then
  -- lands at what was actually paid for it.
  --
  -- Stock bought on the bill is NOT revalued: the movement below still
  -- carries the undiscounted cost. Said here because inventory in the
  -- ledger will read below the stock valuation by the discount on any
  -- stock line, and that difference is this and nothing else.
  v_disc := round(coalesce(v_doc.discount_amount, 0) * v_rate, 2);
  if v_disc <> 0 then
    select coalesce(sum(round(l.line_subtotal * v_rate, 2)), 0)
      into v_lines_net
      from public.purchase_document_lines l
     where l.document_id = p_id and l.line_type = 'item';
    if v_lines_net = 0 then
      raise exception
        '% has a discount of % but nothing on its lines to take it off.',
        v_doc.doc_no, v_doc.discount_amount
        using errcode = '23514';
    end if;

    select l.id into v_big from public.purchase_document_lines l
     where l.document_id = p_id and l.line_type = 'item'
     order by abs(l.line_subtotal) desc, l.line_no
     limit 1;

    select coalesce(sum(round(v_disc * round(l.line_subtotal * v_rate, 2)
                               / v_lines_net, 2)), 0)
      into v_run
      from public.purchase_document_lines l
     where l.document_id = p_id and l.line_type = 'item' and l.id <> v_big;
  end if;

  -- Payable: credit for a bill.
  v_amount := round(-v_sign * v_doc.total_amount * v_rate, 2);
  v_entries := v_entries || jsonb_build_object(
    'account_id',  v_ap_account,
    'description', v_doc.doc_type::text || ' ' || v_doc.doc_no,
    'debit',       greatest(v_amount, 0),
    'credit',      greatest(-v_amount, 0),
    'contact_id',  v_doc.contact_id
  );

  for v_line in
    select l.*, i.track_inventory, i.inventory_account_id, i.purchase_account_id
      from public.purchase_document_lines l
      left join public.items i on i.id = l.item_id
     where l.document_id = p_id and l.line_type = 'item'
     order by l.line_no
  loop
    -- Stock items capitalise into inventory; everything else expenses.
    --
    -- 0609: unless the goods received note already capitalised them, in
    -- which case this clears the accrual it raised instead. The two
    -- entries together are exactly what the direct path posts, and
    -- `goods_received.sql` asserts that by buying the same thing both
    -- ways and comparing every account.
    --
    -- Where the bill's price differs from the receiving note's -- a
    -- line edited after transfer, a supplier who charged more than the
    -- order said -- the difference stays in 2118 rather than being
    -- silently absorbed. That is a purchase price variance and it is
    -- meant to be visible; an accountant clears it deliberately.
    if v_line.track_inventory then
      v_exp_acct := case when v_from_grn then v_grni else
        coalesce(v_line.inventory_account_id,
          (select id from public.accounts where org_id = v_doc.org_id and code = '1310'))
      end;
    else
      v_exp_acct := app.resolve_account(
        v_doc.org_id, v_line.account_id, v_line.item_id, 'purchase_account_id', '5100');
    end if;

    -- 0759: less this line's share of the header discount.
    v_share := case
      when v_disc = 0 then 0
      when v_line.id = v_big then v_disc - v_run
      else round(v_disc * round(v_line.line_subtotal * v_rate, 2)
                 / v_lines_net, 2)
    end;
    v_amount := round(v_sign * v_line.line_subtotal * v_rate, 2)
              - v_sign * v_share;
    if v_amount <> 0 then
      v_entries := v_entries || jsonb_build_object(
        'account_id',  v_exp_acct,
        'description', left(coalesce(v_line.description, ''), 200),
        'debit',       greatest(v_amount, 0),
        'credit',      greatest(-v_amount, 0),
        'contact_id',  v_doc.contact_id,
        'item_id',     v_line.item_id,
        'tax_code_id', v_line.tax_code_id,
        'project_code', v_line.project_code,
        'department_code', v_line.department_code,
        'matter_id', v_line.matter_id
      );
    end if;
  end loop;

  if coalesce(v_doc.tax_amount, 0) <> 0 then
    v_amount := round(v_sign * v_doc.tax_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  v_tax_account,
      'description', 'SST input tax',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0),
      'tax_amount',  abs(v_amount)
    );
  end if;

  if coalesce(v_doc.shipping_amount, 0) <> 0 then
    v_amount := round(v_sign * v_doc.shipping_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '5400'),
      'description', 'Freight and handling',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  if coalesce(v_doc.rounding_amount, 0) <> 0 then
    v_amount := round(v_sign * v_doc.rounding_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '4990'),
      'description', 'Rounding adjustment',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  v_entry_id := app.create_gl_entry_internal(
    v_doc.org_id, v_doc.doc_date,
    case when v_sign = -1 then 'purchase_credit_note'::app.journal_source
         else 'purchase_bill'::app.journal_source end,
    v_entries,
    v_doc.doc_type::text || ' ' || v_doc.doc_no,
    'purchase_documents', v_doc.id,
    coalesce(v_doc.supplier_doc_no, v_doc.reference),
    v_doc.currency, v_rate
  );

  -- Receive stock unless a goods received note already did.
  --
  -- 0609. This asked whether the parent was a receiving note, which was
  -- standing in for whether the stock was already here. They are not
  -- the same thing and were never the same thing: nothing received
  -- stock on a receiving note until 0609, so the answer was always
  -- "skip" and the stock was always missing. It now asks the question
  -- it means, of the movements themselves, so a bill raised from a
  -- draft note -- or from a note posted before this migration and left
  -- without movements -- receives the goods here instead of nowhere.
  --
  -- The `doc_type` half stays, and dropping it was wrong: a purchase
  -- credit note raised by `credit_purchase_bill` carries the BILL as
  -- its parent, and that bill has movements. Asking only "does the
  -- parent have movements" made every return skip its own outward
  -- movement -- twenty bags credited and a hundred still on the shelf,
  -- which is what `bill_credit.sql` said when this was written the
  -- short way.
  select count(*) into v_received
    from public.stock_movements m
    join public.purchase_documents d
      on d.id = m.source_id and d.doc_type = 'goods_received'
   where m.source_table = 'purchase_documents'
     and d.id = v_doc.parent_id;

  if v_received = 0 then
    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id, warehouse_id,
      quantity, unit_cost, source_table, source_id, source_line_id, gl_entry_id, created_by
    )
    select v_doc.org_id,
           app.next_document_number_internal(v_doc.org_id, 'stock_movement'),
           v_doc.doc_date,
           case when v_sign = 1 then 'purchase_receipt' else 'purchase_return' end::app.stock_movement_type,
           l.item_id,
           coalesce(l.warehouse_id, (select id from public.warehouses
                                      where org_id = v_doc.org_id and is_default limit 1)),
           -- Both in the item's own unit. Two cartons of twenty-four
           -- is forty-eight pieces onto the shelf, and RM 480 for them
           -- is RM 10 a piece -- not RM 240, which is what dividing by
           -- the carton count would have made it. 0270.
           v_sign * coalesce(l.base_quantity, l.quantity),
           case when coalesce(l.base_quantity, l.quantity) = 0 then 0
                else round(l.line_subtotal * v_rate
                           / coalesce(l.base_quantity, l.quantity), 6) end,
           'purchase_documents', v_doc.id, l.id, v_entry_id, auth.uid()
      from public.purchase_document_lines l
      join public.items i on i.id = l.item_id
     where l.document_id = p_id
       and l.line_type = 'item'
       and i.track_inventory
       and l.quantity > 0;
  end if;

  update public.purchase_documents
     set gl_entry_id = v_entry_id,
         status      = 'posted',
         posted_at   = now(),
         posted_by   = auth.uid()
   where id = p_id;

  return v_entry_id;
end;
$function$;

-- credit_sales_invoice
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

-- credit_purchase_bill
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
