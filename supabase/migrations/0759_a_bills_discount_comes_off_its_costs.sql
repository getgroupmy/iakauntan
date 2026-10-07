-- =====================================================================
-- 0759 :: a bill's discount is taken off its costs, and an intercompany
--         bill keeps the delivery charge
--
-- Answered on 7 October: "spread over the lines" and "copy it".
--
-- 1. A BILL WITH A HEADER DISCOUNT COULD NOT BE POSTED.
--
-- `recalc_purchase_totals_for` subtracts the header discount from the
-- total, so the payable is net of it. `app.post_purchase_document_
-- internal` debited every line at its full net and posted nothing for
-- the discount, so the journal never balanced. Reproduced: a 10,000
-- bill with 500 off was refused with "Journal does not balance: debits
-- 10000.00, credits 9500.00". Reachable through `accept_intercompany_
-- bill`, which copies the seller's header discount, and through
-- recurring bill templates. The selling side has posted its discount
-- (to 4300) all along.
--
-- Now the discount comes off the lines it was given on, by each line's
-- share of the net, the largest taking the rounding: every cost lands at
-- what was paid for it. A credit note raised by `credit_purchase_bill`
-- carries a proportional discount, and is posted the same way.
--
-- 2. AN INTERCOMPANY BILL DROPPED THE SELLER'S DELIVERY CHARGE.
--
-- `accept_intercompany_bill` copied subtotal, discount, tax and total but
-- not `shipping_amount`, and inserting the lines recomputed the total
-- without it. Reproduced: an invoice of 10,000 - 500 + 200 = 9,700
-- became a bill of 9,500, so the two companies' books disagreed by the
-- delivery charge. Now it is carried across.
--
-- Production had no bill with a header discount and no intercompany
-- bill when this was written.
--
-- Both restated whole from the live definitions; the changes are the
-- lines marked 0759. Grants survive a CREATE OR REPLACE.
-- =====================================================================

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

CREATE OR REPLACE FUNCTION public.accept_intercompany_bill(p_sales_document_id uuid, p_org_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_row record;
  v_bill uuid;
  v_supplier uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'You cannot raise bills in this company'
      using errcode = '42501';
  end if;

  -- Read it back through the inbox rather than from the table, so the
  -- addressing rule is written once and cannot drift between what a
  -- person may see and what they may act on.
  select * into v_row from public.intercompany_inbox(p_org_id) i
   where i.sales_document_id = p_sales_document_id;

  -- FOUND rather than `v_row is null`: a record is null only when every
  -- column is, which is true here but by accident rather than by rule.
  if not found then
    raise exception
      'That invoice is not addressed to this company, or has not been '
      'posted yet' using errcode = '42501';
  end if;

  if v_row.already_billed then
    raise exception 'That invoice has already been billed here';
  end if;

  if v_row.supplier_contact_id is null then
    raise exception
      'Add a supplier in this company linked to %, then try again. A bill '
      'has to be owed to somebody on this company''s own books.',
      v_row.from_org;
  end if;
  v_supplier := v_row.supplier_contact_id;

  insert into public.purchase_documents (
    org_id, doc_type, doc_no, doc_date, due_date, payment_term_id,
    contact_id,
    supplier_doc_no, supplier_doc_date,
    currency, exchange_rate,
    subtotal, discount_amount, tax_amount, total_amount, base_total_amount,
    balance_amount, status, source_sales_document_id,
    -- 0759. Carried like every other figure on the invoice.
    shipping_amount)
  select p_org_id, 'bill',
         app.next_document_number_internal(p_org_id, 'bill'),
         d.doc_date,
         -- 0439. Copied, like every other figure on this line. Without
         -- it the bill lands with no due date and `report_ap_aging`
         -- ages it from `doc_date`, so the group shows itself in
         -- arrears for the whole of the credit period it agreed.
         d.due_date, d.payment_term_id, v_supplier,
         -- Their number on our bill, which is what an SST audit and a
         -- self-billed e-Invoice both ask for.
         d.doc_no, d.doc_date,
         d.currency, d.exchange_rate,
         d.subtotal, d.discount_amount, d.tax_amount, d.total_amount,
         d.base_total_amount, d.total_amount, 'draft', d.id,
         -- 0759. Without it the line inserts below recompute the total
         -- without the delivery charge, and the bill owes less than the
         -- invoice says it does.
         d.shipping_amount
    from public.sales_documents d
   where d.id = p_sales_document_id
  returning id into v_bill;

  insert into public.purchase_document_lines (
    org_id, document_id, line_no, line_type, description,
    quantity, uom_code, unit_price,
    discount_percent, discount_amount,
    tax_code_id, tax_rate, tax_amount, is_tax_inclusive,
    line_subtotal, line_total)
  select p_org_id, v_bill, l.line_no, l.line_type, l.description,
         l.quantity, l.uom_code, l.unit_price,
         l.discount_percent, l.discount_amount,
         -- Matched by code, not by id: the two companies have their own
         -- tax_codes rows, and an id from theirs would point at nothing
         -- here — or, worse, at one of ours by coincidence.
         (select t.id from public.tax_codes t
           where t.org_id = p_org_id
             and t.code = (select s.code from public.tax_codes s
                            where s.id = l.tax_code_id)),
         l.tax_rate, l.tax_amount, l.is_tax_inclusive,
         l.line_subtotal, l.line_total
    from public.sales_document_lines l
   where l.document_id = p_sales_document_id
   order by l.line_no;

  -- Deliberately not copied: `item_id` and `account_id`. Both are ids in
  -- the issuer's own masters. Which of our items this is, and which
  -- expense account it belongs in, are decisions for this company —
  -- which is why the bill arrives as a draft rather than posted.
  return v_bill;
end; $function$;
