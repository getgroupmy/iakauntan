-- =====================================================================
-- iAkauntan :: 0013 document posting
-- Turns subsidiary documents into balanced journal entries. Each
-- function is idempotent: a document that already carries a gl_entry_id
-- is refused rather than double posted.
-- =====================================================================

-- Resolves the account to use, falling back through the chain
-- line -> item -> organization default code.
create or replace function app.resolve_account(
  p_org_id       uuid,
  p_explicit_id  uuid,
  p_item_id      uuid,
  p_item_field   text,
  p_default_code text
)
returns uuid
language plpgsql
stable
as $$
declare
  v_id uuid;
begin
  if p_explicit_id is not null then
    return p_explicit_id;
  end if;

  if p_item_id is not null then
    execute format('select %I from public.items where id = $1', p_item_field)
      into v_id using p_item_id;
    if v_id is not null then
      return v_id;
    end if;
  end if;

  select id into v_id from public.accounts
   where org_id = p_org_id and code = p_default_code and not is_group;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Sales invoices, credit notes, debit notes
-- ---------------------------------------------------------------------
create or replace function public.post_sales_document(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
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
begin
  select * into v_doc from public.sales_documents where id = p_id;
  if not found then
    raise exception 'Sales document % not found', p_id;
  end if;
  if not app.can_post(v_doc.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if v_doc.doc_type not in ('invoice', 'credit_note', 'debit_note', 'refund_note') then
    raise exception 'Document type % does not post to the ledger', v_doc.doc_type;
  end if;
  if v_doc.gl_entry_id is not null then
    raise exception 'Document % is already posted', v_doc.doc_no;
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
    v_rev_acct := app.resolve_account(
      v_doc.org_id, v_line.account_id, v_line.item_id, 'sales_account_id', '4100');

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
        'department_code', v_line.department_code
      );
    end if;

    -- Cost of sales for stock items.
    if v_line.track_inventory and v_line.item_id is not null then
      v_cogs_total := v_cogs_total
        + round(v_line.quantity * coalesce(v_line.average_cost, 0) * v_rate, 2);
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

  v_entry_id := public.create_gl_entry(
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
           public.next_document_number(v_doc.org_id, 'stock_movement'),
           v_doc.doc_date,
           case when v_sign = 1 then 'sales_delivery' else 'sales_return' end::app.stock_movement_type,
           l.item_id,
           coalesce(l.warehouse_id, (select id from public.warehouses
                                      where org_id = v_doc.org_id and is_default limit 1)),
           -v_sign * l.quantity,
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

  return v_entry_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Purchase bills and purchase credit notes
-- ---------------------------------------------------------------------
create or replace function public.post_purchase_document(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
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
begin
  select * into v_doc from public.purchase_documents where id = p_id;
  if not found then
    raise exception 'Purchase document % not found', p_id;
  end if;
  if not app.can_post(v_doc.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if v_doc.doc_type not in ('bill', 'purchase_credit_note', 'purchase_debit_note') then
    raise exception 'Document type % does not post to the ledger', v_doc.doc_type;
  end if;
  if v_doc.gl_entry_id is not null then
    raise exception 'Document % is already posted', v_doc.doc_no;
  end if;

  v_sign := case when v_doc.doc_type = 'purchase_credit_note' then -1 else 1 end;
  v_rate := coalesce(v_doc.exchange_rate, 1);

  select coalesce(c.payable_account_id,
                  (select id from public.accounts where org_id = v_doc.org_id and code = '2110'))
    into v_ap_account
    from public.contacts c where c.id = v_doc.contact_id;

  select id into v_tax_account from public.accounts
   where org_id = v_doc.org_id and code = '1410';

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
    if v_line.track_inventory then
      v_exp_acct := coalesce(v_line.inventory_account_id,
        (select id from public.accounts where org_id = v_doc.org_id and code = '1310'));
    else
      v_exp_acct := app.resolve_account(
        v_doc.org_id, v_line.account_id, v_line.item_id, 'purchase_account_id', '5100');
    end if;

    v_amount := round(v_sign * v_line.line_subtotal * v_rate, 2);
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
        'department_code', v_line.department_code
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

  v_entry_id := public.create_gl_entry(
    v_doc.org_id, v_doc.doc_date,
    case when v_sign = -1 then 'purchase_credit_note'::app.journal_source
         else 'purchase_bill'::app.journal_source end,
    v_entries,
    v_doc.doc_type::text || ' ' || v_doc.doc_no,
    'purchase_documents', v_doc.id,
    coalesce(v_doc.supplier_doc_no, v_doc.reference),
    v_doc.currency, v_rate
  );

  -- Receive stock unless a goods-received note already did.
  if not exists (
    select 1 from public.purchase_documents d
     where d.id = v_doc.parent_id and d.doc_type = 'goods_received'
  ) then
    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id, warehouse_id,
      quantity, unit_cost, source_table, source_id, source_line_id, gl_entry_id, created_by
    )
    select v_doc.org_id,
           public.next_document_number(v_doc.org_id, 'stock_movement'),
           v_doc.doc_date,
           case when v_sign = 1 then 'purchase_receipt' else 'purchase_return' end::app.stock_movement_type,
           l.item_id,
           coalesce(l.warehouse_id, (select id from public.warehouses
                                      where org_id = v_doc.org_id and is_default limit 1)),
           v_sign * l.quantity,
           case when l.quantity = 0 then 0
                else round(l.line_subtotal * v_rate / l.quantity, 6) end,
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
$$;

-- ---------------------------------------------------------------------
-- Customer receipts
-- ---------------------------------------------------------------------
create or replace function public.post_receipt(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_rcp        public.receipts;
  v_entries    jsonb := '[]'::jsonb;
  v_bank_acct  uuid;
  v_ar_acct    uuid;
  v_entry_id   uuid;
  v_rate       numeric(18, 8);
  v_net        numeric(18, 2);
begin
  select * into v_rcp from public.receipts where id = p_id;
  if not found then raise exception 'Receipt % not found', p_id; end if;
  if not app.can_post(v_rcp.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if v_rcp.gl_entry_id is not null then
    raise exception 'Receipt % is already posted', v_rcp.receipt_no;
  end if;

  v_rate := coalesce(v_rcp.exchange_rate, 1);

  select a.id into v_bank_acct from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_rcp.bank_account_id;

  if v_bank_acct is null then
    select id into v_bank_acct from public.accounts
     where org_id = v_rcp.org_id and code = '1120';
  end if;

  select coalesce(c.receivable_account_id,
                  (select id from public.accounts where org_id = v_rcp.org_id and code = '1210'))
    into v_ar_acct from public.contacts c where c.id = v_rcp.contact_id;

  v_net := round((v_rcp.amount - coalesce(v_rcp.bank_charges, 0)) * v_rate, 2);

  -- Dr Bank (net of charges), Dr Bank charges, Cr Receivable.
  v_entries := v_entries || jsonb_build_object(
    'account_id', v_bank_acct, 'description', 'Receipt ' || v_rcp.receipt_no,
    'debit', v_net, 'credit', 0, 'contact_id', v_rcp.contact_id);

  if coalesce(v_rcp.bank_charges, 0) > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', (select id from public.accounts where org_id = v_rcp.org_id and code = '6300'),
      'description', 'Bank charges',
      'debit', round(v_rcp.bank_charges * v_rate, 2), 'credit', 0);
  end if;

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_ar_acct, 'description', 'Receipt ' || v_rcp.receipt_no,
    'debit', 0, 'credit', round(v_rcp.amount * v_rate, 2), 'contact_id', v_rcp.contact_id);

  v_entry_id := public.create_gl_entry(
    v_rcp.org_id, v_rcp.receipt_date, 'receipt'::app.journal_source, v_entries,
    'Receipt ' || v_rcp.receipt_no, 'receipts', v_rcp.id, v_rcp.reference,
    v_rcp.currency, v_rate);

  update public.receipts
     set gl_entry_id = v_entry_id, status = 'posted',
         base_amount = round(v_rcp.amount * v_rate, 2),
         posted_at = now(), posted_by = auth.uid()
   where id = p_id;

  update public.bank_accounts
     set current_balance = current_balance + v_net
   where id = v_rcp.bank_account_id;

  return v_entry_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Supplier payments
-- ---------------------------------------------------------------------
create or replace function public.post_purchase_payment(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_pay       public.purchase_payments;
  v_entries   jsonb := '[]'::jsonb;
  v_bank_acct uuid;
  v_ap_acct   uuid;
  v_entry_id  uuid;
  v_rate      numeric(18, 8);
  v_total     numeric(18, 2);
begin
  select * into v_pay from public.purchase_payments where id = p_id;
  if not found then raise exception 'Payment % not found', p_id; end if;
  if not app.can_post(v_pay.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if v_pay.gl_entry_id is not null then
    raise exception 'Payment % is already posted', v_pay.payment_no;
  end if;

  v_rate := coalesce(v_pay.exchange_rate, 1);

  select a.id into v_bank_acct from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_pay.bank_account_id;
  if v_bank_acct is null then
    select id into v_bank_acct from public.accounts
     where org_id = v_pay.org_id and code = '1120';
  end if;

  select coalesce(c.payable_account_id,
                  (select id from public.accounts where org_id = v_pay.org_id and code = '2110'))
    into v_ap_acct from public.contacts c where c.id = v_pay.contact_id;

  v_total := round((v_pay.amount + coalesce(v_pay.bank_charges, 0)) * v_rate, 2);

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_ap_acct, 'description', 'Payment ' || v_pay.payment_no,
    'debit', round(v_pay.amount * v_rate, 2), 'credit', 0, 'contact_id', v_pay.contact_id);

  if coalesce(v_pay.bank_charges, 0) > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', (select id from public.accounts where org_id = v_pay.org_id and code = '6300'),
      'description', 'Bank charges',
      'debit', round(v_pay.bank_charges * v_rate, 2), 'credit', 0);
  end if;

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_bank_acct, 'description', 'Payment ' || v_pay.payment_no,
    'debit', 0, 'credit', v_total, 'contact_id', v_pay.contact_id);

  v_entry_id := public.create_gl_entry(
    v_pay.org_id, v_pay.payment_date, 'payment'::app.journal_source, v_entries,
    'Payment ' || v_pay.payment_no, 'purchase_payments', v_pay.id, v_pay.reference,
    v_pay.currency, v_rate);

  update public.purchase_payments
     set gl_entry_id = v_entry_id, status = 'posted',
         base_amount = round(v_pay.amount * v_rate, 2),
         posted_at = now(), posted_by = auth.uid()
   where id = p_id;

  update public.bank_accounts
     set current_balance = current_balance - v_total
   where id = v_pay.bank_account_id;

  return v_entry_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Expenses
-- ---------------------------------------------------------------------
create or replace function public.post_expense(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_exp       public.expenses;
  v_entries   jsonb := '[]'::jsonb;
  v_bank_acct uuid;
  v_entry_id  uuid;
  v_rate      numeric(18, 8);
begin
  select * into v_exp from public.expenses where id = p_id;
  if not found then raise exception 'Expense % not found', p_id; end if;
  if not app.can_post(v_exp.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if v_exp.gl_entry_id is not null then
    raise exception 'Expense % is already posted', v_exp.expense_no;
  end if;

  v_rate := coalesce(v_exp.exchange_rate, 1);

  select a.id into v_bank_acct from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = v_exp.bank_account_id;
  if v_bank_acct is null then
    select id into v_bank_acct from public.accounts
     where org_id = v_exp.org_id and code = '1120';
  end if;

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_exp.account_id,
    'description', coalesce(v_exp.description, 'Expense ' || v_exp.expense_no),
    'debit', round(v_exp.amount * v_rate, 2), 'credit', 0,
    'contact_id', v_exp.contact_id, 'project_code', v_exp.project_code);

  if coalesce(v_exp.tax_amount, 0) > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', (select id from public.accounts where org_id = v_exp.org_id and code = '1410'),
      'description', 'SST input tax',
      'debit', round(v_exp.tax_amount * v_rate, 2), 'credit', 0,
      'tax_code_id', v_exp.tax_code_id, 'tax_amount', round(v_exp.tax_amount * v_rate, 2));
  end if;

  v_entries := v_entries || jsonb_build_object(
    'account_id', v_bank_acct, 'description', 'Expense ' || v_exp.expense_no,
    'debit', 0, 'credit', round(v_exp.total_amount * v_rate, 2));

  v_entry_id := public.create_gl_entry(
    v_exp.org_id, v_exp.expense_date, 'manual'::app.journal_source, v_entries,
    'Expense ' || v_exp.expense_no, 'expenses', v_exp.id, v_exp.reference,
    v_exp.currency, v_rate);

  update public.expenses
     set gl_entry_id = v_entry_id, status = 'posted', posted_at = now()
   where id = p_id;

  return v_entry_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Unposting: reverse the journal and release the document
-- ---------------------------------------------------------------------
create or replace function public.void_sales_document(p_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_doc public.sales_documents;
begin
  select * into v_doc from public.sales_documents where id = p_id;
  if not found then raise exception 'Document % not found', p_id; end if;
  if not app.can_post(v_doc.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if v_doc.paid_amount > 0 then
    raise exception 'Cannot void %: payments have been applied', v_doc.doc_no;
  end if;
  if v_doc.einvoice_status = 'valid' then
    raise exception 'Cannot void %: cancel the e-Invoice with LHDN first', v_doc.doc_no;
  end if;

  if v_doc.gl_entry_id is not null then
    perform public.reverse_gl_entry(v_doc.gl_entry_id, current_date);
  end if;

  update public.sales_documents
     set status = 'void',
         internal_notes = coalesce(internal_notes || E'\n', '') || 'Voided: ' || coalesce(p_reason, '')
   where id = p_id;
end;
$$;
