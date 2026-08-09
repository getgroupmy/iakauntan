-- =====================================================================
-- iAkauntan :: 0009 business logic
-- Membership helpers, document numbering, line/header total maths,
-- the single GL posting entry point, and weighted-average stock costing.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Membership / authorisation helpers
--
-- These are security definer so RLS policies can call them without
-- recursing into the very policies they are evaluating.
-- ---------------------------------------------------------------------
create or replace function app.is_org_member(p_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.org_members m
     where m.org_id = p_org_id
       and m.user_id = auth.uid()
       and m.status = 'active'
  );
$$;

create or replace function app.org_role(p_org_id uuid)
returns app.member_role
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.role from public.org_members m
   where m.org_id = p_org_id
     and m.user_id = auth.uid()
     and m.status = 'active'
   limit 1;
$$;

create or replace function app.has_org_role(p_org_id uuid, p_roles app.member_role[])
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app.org_role(p_org_id) = any (p_roles);
$$;

-- Roles allowed to create/modify operational documents.
create or replace function app.can_write(p_org_id uuid)
returns boolean
language sql
stable
as $$
  select app.has_org_role(p_org_id,
    array['owner', 'admin', 'accountant', 'sales', 'purchaser']::app.member_role[]);
$$;

-- Roles allowed to post to the general ledger or close periods.
create or replace function app.can_post(p_org_id uuid)
returns boolean
language sql
stable
as $$
  select app.has_org_role(p_org_id,
    array['owner', 'admin', 'accountant']::app.member_role[]);
$$;

create or replace function app.can_admin(p_org_id uuid)
returns boolean
language sql
stable
as $$
  select app.has_org_role(p_org_id, array['owner', 'admin']::app.member_role[]);
$$;

-- Every org the caller belongs to; used by the org switcher.
create or replace function public.my_organizations()
returns setof public.organizations
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select o.* from public.organizations o
    join public.org_members m on m.org_id = o.id
   where m.user_id = auth.uid()
     and m.status = 'active'
     and o.deleted_at is null
   order by o.name;
$$;

-- ---------------------------------------------------------------------
-- Malaysian cash rounding (rounding mechanism: nearest 5 sen)
-- ---------------------------------------------------------------------
create or replace function app.round_amount(p_amount numeric, p_method text)
returns numeric
language sql
immutable
as $$
  select case p_method
    when 'nearest_5cent'  then round(p_amount * 20) / 20
    when 'nearest_10cent' then round(p_amount * 10) / 10
    else round(p_amount, 2)
  end;
$$;

comment on function app.round_amount is
  'Bank Negara rounding mechanism: cash totals round to the nearest 5 sen.';

-- ---------------------------------------------------------------------
-- Document numbering
-- ---------------------------------------------------------------------
create or replace function app.default_doc_prefix(p_doc_type text)
returns text
language sql
immutable
as $$
  select case p_doc_type
    when 'quotation'            then 'QT-'
    when 'sales_order'          then 'SO-'
    when 'delivery_order'       then 'DO-'
    when 'invoice'              then 'INV-'
    when 'credit_note'          then 'CN-'
    when 'debit_note'           then 'DN-'
    when 'refund_note'          then 'RN-'
    when 'proforma'             then 'PF-'
    when 'purchase_request'     then 'PR-'
    when 'purchase_order'       then 'PO-'
    when 'goods_received'       then 'GRN-'
    when 'bill'                 then 'BILL-'
    when 'purchase_credit_note' then 'PCN-'
    when 'purchase_debit_note'  then 'PDN-'
    when 'purchase_return'      then 'PRT-'
    when 'receipt'              then 'RCP-'
    when 'payment'              then 'PAY-'
    when 'expense'              then 'EXP-'
    when 'journal'              then 'JV-'
    when 'stock_adjustment'     then 'ADJ-'
    when 'stock_movement'       then 'SM-'
    when 'lead'                 then 'LD-'
    when 'opportunity'          then 'OPP-'
    when 'contact'              then 'C-'
    when 'item'                 then 'I-'
    else upper(left(p_doc_type, 3)) || '-'
  end;
$$;

create or replace function public.next_document_number(p_org_id uuid, p_doc_type text)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_seq         public.number_sequences;
  v_period_key  text;
  v_number      bigint;
  v_body        text;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id using errcode = '42501';
  end if;

  insert into public.number_sequences (org_id, doc_type, prefix)
  values (p_org_id, p_doc_type, app.default_doc_prefix(p_doc_type))
  on conflict (org_id, doc_type) do nothing;

  -- Row lock serialises concurrent allocations for this doc type.
  select * into v_seq
    from public.number_sequences
   where org_id = p_org_id and doc_type = p_doc_type
   for update;

  v_period_key := case v_seq.reset_policy
    when 'yearly'  then to_char(current_date, 'YYYY')
    when 'monthly' then to_char(current_date, 'YYYYMM')
    else null
  end;

  -- A new period restarts the counter.
  if v_seq.reset_policy <> 'never' and v_seq.period_key is distinct from v_period_key then
    v_number := 1;
  else
    v_number := v_seq.next_value;
  end if;

  update public.number_sequences
     set next_value = v_number + 1,
         period_key = v_period_key
   where id = v_seq.id;

  v_body := lpad(v_number::text, v_seq.padding, '0');

  return v_seq.prefix
      || coalesce(v_period_key || '-', '')
      || v_body
      || v_seq.suffix;
end;
$$;

comment on function public.next_document_number is
  'Allocates the next number for a document type, e.g. INV-2026-00001.';

-- ---------------------------------------------------------------------
-- Line maths (shared shape between sales and purchase lines)
-- ---------------------------------------------------------------------
create or replace function app.calc_document_line()
returns trigger
language plpgsql
as $$
declare
  v_gross     numeric(18, 4);
  v_discount  numeric(18, 2);
  v_net       numeric(18, 2);
  v_tax       numeric(18, 2);
begin
  if new.line_type <> 'item' then
    new.line_subtotal := 0;
    new.tax_amount    := 0;
    new.line_total    := 0;
    return new;
  end if;

  v_gross := coalesce(new.quantity, 0) * coalesce(new.unit_price, 0);

  -- A percentage, when given, wins over any manually typed amount.
  if coalesce(new.discount_percent, 0) > 0 then
    v_discount := round(v_gross * new.discount_percent / 100.0, 2);
  else
    v_discount := coalesce(new.discount_amount, 0);
  end if;

  if new.is_tax_inclusive and coalesce(new.tax_rate, 0) > 0 then
    -- unit_price already contains tax: strip it back out.
    v_net := round((v_gross - v_discount) / (1 + new.tax_rate / 100.0), 2);
    v_tax := round(v_gross - v_discount - v_net, 2);
  else
    v_net := round(v_gross - v_discount, 2);
    v_tax := round(v_net * coalesce(new.tax_rate, 0) / 100.0, 2);
  end if;

  new.discount_amount := v_discount;
  new.line_subtotal   := v_net;
  new.tax_amount      := v_tax;
  new.line_total      := v_net + v_tax;

  return new;
end;
$$;

comment on function app.calc_document_line is
  'Normalises a sales/purchase line so line_subtotal is always tax exclusive.';

-- ---------------------------------------------------------------------
-- Header totals
-- ---------------------------------------------------------------------
create or replace function app.recalc_sales_totals()
returns trigger
language plpgsql
as $$
declare
  v_doc_id    uuid := coalesce(new.document_id, old.document_id);
  v_subtotal  numeric(18, 2);
  v_tax       numeric(18, 2);
  v_doc       public.sales_documents;
  v_method    text;
  v_discount  numeric(18, 2);
  v_raw_total numeric(18, 2);
  v_rounded   numeric(18, 2);
begin
  select * into v_doc from public.sales_documents where id = v_doc_id;
  if not found then
    return coalesce(new, old);
  end if;

  select coalesce(sum(line_subtotal), 0), coalesce(sum(tax_amount), 0)
    into v_subtotal, v_tax
    from public.sales_document_lines
   where document_id = v_doc_id;

  select rounding_method into v_method
    from public.organizations where id = v_doc.org_id;

  if coalesce(v_doc.discount_percent, 0) > 0 then
    v_discount := round(v_subtotal * v_doc.discount_percent / 100.0, 2);
  else
    v_discount := coalesce(v_doc.discount_amount, 0);
  end if;

  v_raw_total := v_subtotal - v_discount + v_tax + coalesce(v_doc.shipping_amount, 0);
  v_rounded   := app.round_amount(v_raw_total, coalesce(v_method, 'none'));

  update public.sales_documents
     set subtotal          = v_subtotal,
         discount_amount   = v_discount,
         tax_amount        = v_tax,
         rounding_amount   = v_rounded - v_raw_total,
         total_amount      = v_rounded,
         base_total_amount = round(v_rounded * coalesce(v_doc.exchange_rate, 1), 2),
         balance_amount    = v_rounded - coalesce(v_doc.paid_amount, 0)
                                       - coalesce(v_doc.applied_amount, 0)
   where id = v_doc_id;

  return coalesce(new, old);
end;
$$;

create or replace function app.recalc_purchase_totals()
returns trigger
language plpgsql
as $$
declare
  v_doc_id    uuid := coalesce(new.document_id, old.document_id);
  v_subtotal  numeric(18, 2);
  v_tax       numeric(18, 2);
  v_doc       public.purchase_documents;
  v_method    text;
  v_discount  numeric(18, 2);
  v_raw_total numeric(18, 2);
  v_rounded   numeric(18, 2);
begin
  select * into v_doc from public.purchase_documents where id = v_doc_id;
  if not found then
    return coalesce(new, old);
  end if;

  select coalesce(sum(line_subtotal), 0), coalesce(sum(tax_amount), 0)
    into v_subtotal, v_tax
    from public.purchase_document_lines
   where document_id = v_doc_id;

  select rounding_method into v_method
    from public.organizations where id = v_doc.org_id;

  if coalesce(v_doc.discount_percent, 0) > 0 then
    v_discount := round(v_subtotal * v_doc.discount_percent / 100.0, 2);
  else
    v_discount := coalesce(v_doc.discount_amount, 0);
  end if;

  v_raw_total := v_subtotal - v_discount + v_tax + coalesce(v_doc.shipping_amount, 0);
  v_rounded   := app.round_amount(v_raw_total, coalesce(v_method, 'none'));

  update public.purchase_documents
     set subtotal          = v_subtotal,
         discount_amount   = v_discount,
         tax_amount        = v_tax,
         rounding_amount   = v_rounded - v_raw_total,
         total_amount      = v_rounded,
         base_total_amount = round(v_rounded * coalesce(v_doc.exchange_rate, 1), 2),
         balance_amount    = v_rounded - coalesce(v_doc.paid_amount, 0)
   where id = v_doc_id;

  return coalesce(new, old);
end;
$$;

create trigger calc_line before insert or update on public.sales_document_lines
  for each row execute function app.calc_document_line();
create trigger recalc_totals after insert or update or delete on public.sales_document_lines
  for each row execute function app.recalc_sales_totals();

create trigger calc_line before insert or update on public.purchase_document_lines
  for each row execute function app.calc_document_line();
create trigger recalc_totals after insert or update or delete on public.purchase_document_lines
  for each row execute function app.recalc_purchase_totals();

-- ---------------------------------------------------------------------
-- General ledger
-- ---------------------------------------------------------------------

-- Guards the fundamental invariant: a posted journal must balance.
create or replace function app.assert_gl_balanced()
returns trigger
language plpgsql
as $$
declare
  v_entry   public.gl_entries;
  v_debit   numeric(18, 2);
  v_credit  numeric(18, 2);
  v_id      uuid := coalesce(new.entry_id, old.entry_id);
begin
  select * into v_entry from public.gl_entries where id = v_id;
  if not found then
    return coalesce(new, old);
  end if;

  select coalesce(sum(debit), 0), coalesce(sum(credit), 0)
    into v_debit, v_credit
    from public.gl_lines where entry_id = v_id;

  update public.gl_entries
     set total_debit = v_debit, total_credit = v_credit
   where id = v_id;

  if v_entry.status = 'posted' and v_debit <> v_credit then
    raise exception
      'Journal % is out of balance: debits %, credits %',
      v_entry.entry_no, v_debit, v_credit
      using errcode = '23514';
  end if;

  return coalesce(new, old);
end;
$$;

create constraint trigger assert_balanced
  after insert or update or delete on public.gl_lines
  deferrable initially deferred
  for each row execute function app.assert_gl_balanced();

-- Keeps accounts.current_balance in step with posted lines.
create or replace function app.apply_account_balance()
returns trigger
language plpgsql
as $$
declare
  v_sign numeric;
begin
  -- Debit increases assets and expenses; credit increases the rest.
  if tg_op in ('INSERT', 'UPDATE') then
    select case when a.account_type in ('asset', 'expense') then 1 else -1 end
      into v_sign from public.accounts a where a.id = new.account_id;
    update public.accounts
       set current_balance = current_balance + v_sign * (new.debit - new.credit)
     where id = new.account_id;
  end if;

  if tg_op in ('UPDATE', 'DELETE') then
    select case when a.account_type in ('asset', 'expense') then 1 else -1 end
      into v_sign from public.accounts a where a.id = old.account_id;
    update public.accounts
       set current_balance = current_balance - v_sign * (old.debit - old.credit)
     where id = old.account_id;
  end if;

  return coalesce(new, old);
end;
$$;

create trigger apply_balance after insert or update or delete on public.gl_lines
  for each row execute function app.apply_account_balance();

-- Resolves the open fiscal period a date falls into.
create or replace function app.period_for_date(p_org_id uuid, p_date date)
returns uuid
language sql
stable
as $$
  select p.id from public.fiscal_periods p
   where p.org_id = p_org_id
     and p_date between p.start_date and p.end_date
   limit 1;
$$;

-- The single entry point for writing to the ledger.
-- p_lines: [{"account_id":"…","debit":100,"credit":0,"description":"…",
--            "contact_id":null,"item_id":null,"tax_code_id":null}, …]
create or replace function public.create_gl_entry(
  p_org_id       uuid,
  p_entry_date   date,
  p_source       app.journal_source,
  p_lines        jsonb,
  p_description  text default null,
  p_source_table text default null,
  p_source_id    uuid default null,
  p_reference    text default null,
  p_currency     char(3) default 'MYR',
  p_exchange_rate numeric default 1
)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_entry_id  uuid;
  v_period_id uuid;
  v_status    text;
  v_line      jsonb;
  v_no        integer := 0;
  v_debit     numeric(18, 2) := 0;
  v_credit    numeric(18, 2) := 0;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to post to the ledger'
      using errcode = '42501';
  end if;

  -- Refuse to post into a closed or locked period.
  v_period_id := app.period_for_date(p_org_id, p_entry_date);
  if v_period_id is not null then
    select status into v_status from public.fiscal_periods where id = v_period_id;
    if v_status <> 'open' then
      raise exception 'Fiscal period for % is %', p_entry_date, v_status
        using errcode = '23514';
    end if;
  end if;

  insert into public.gl_entries (
    org_id, entry_no, entry_date, fiscal_period_id, source,
    source_table, source_id, description, reference,
    currency, exchange_rate, status, posted_at, posted_by, created_by
  ) values (
    p_org_id,
    public.next_document_number(p_org_id, 'journal'),
    p_entry_date, v_period_id, p_source,
    p_source_table, p_source_id, p_description, p_reference,
    p_currency, p_exchange_rate, 'posted', now(), auth.uid(), auth.uid()
  ) returning id into v_entry_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into public.gl_lines (
      org_id, entry_id, line_no, account_id, description,
      debit, credit, currency, exchange_rate,
      contact_id, item_id, tax_code_id, tax_amount,
      project_code, department_code
    ) values (
      p_org_id, v_entry_id, v_no,
      (v_line ->> 'account_id')::uuid,
      v_line ->> 'description',
      round(coalesce((v_line ->> 'debit')::numeric, 0), 2),
      round(coalesce((v_line ->> 'credit')::numeric, 0), 2),
      p_currency, p_exchange_rate,
      nullif(v_line ->> 'contact_id', '')::uuid,
      nullif(v_line ->> 'item_id', '')::uuid,
      nullif(v_line ->> 'tax_code_id', '')::uuid,
      round(coalesce((v_line ->> 'tax_amount')::numeric, 0), 2),
      v_line ->> 'project_code',
      v_line ->> 'department_code'
    );
    v_debit  := v_debit  + round(coalesce((v_line ->> 'debit')::numeric, 0), 2);
    v_credit := v_credit + round(coalesce((v_line ->> 'credit')::numeric, 0), 2);
  end loop;

  if v_debit <> v_credit then
    raise exception 'Journal does not balance: debits %, credits %', v_debit, v_credit
      using errcode = '23514';
  end if;

  return v_entry_id;
end;
$$;

-- Reverses a posted entry by writing its mirror image.
create or replace function public.reverse_gl_entry(p_entry_id uuid, p_date date default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_entry     public.gl_entries;
  v_new_id    uuid;
  v_period_id uuid;
begin
  select * into v_entry from public.gl_entries where id = p_entry_id;
  if not found then
    raise exception 'Journal % not found', p_entry_id;
  end if;
  if not app.can_post(v_entry.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if v_entry.status <> 'posted' then
    raise exception 'Only posted journals can be reversed';
  end if;

  v_period_id := app.period_for_date(v_entry.org_id, coalesce(p_date, current_date));

  insert into public.gl_entries (
    org_id, entry_no, entry_date, fiscal_period_id, source,
    source_table, source_id, description, reference, currency, exchange_rate,
    status, is_reversal, reversed_entry_id, posted_at, posted_by, created_by
  ) values (
    v_entry.org_id,
    public.next_document_number(v_entry.org_id, 'journal'),
    coalesce(p_date, current_date), v_period_id, v_entry.source,
    v_entry.source_table, v_entry.source_id,
    'Reversal of ' || v_entry.entry_no, v_entry.reference,
    v_entry.currency, v_entry.exchange_rate,
    'posted', true, v_entry.id, now(), auth.uid(), auth.uid()
  ) returning id into v_new_id;

  insert into public.gl_lines (
    org_id, entry_id, line_no, account_id, description,
    debit, credit, currency, exchange_rate, contact_id, item_id, tax_code_id
  )
  select org_id, v_new_id, line_no, account_id,
         'Reversal: ' || coalesce(description, ''),
         credit, debit,       -- swapped
         currency, exchange_rate, contact_id, item_id, tax_code_id
    from public.gl_lines where entry_id = p_entry_id;

  update public.gl_entries set status = 'void' where id = p_entry_id;
  return v_new_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Inventory: weighted average costing
-- ---------------------------------------------------------------------
create or replace function app.apply_stock_movement()
returns trigger
language plpgsql
as $$
declare
  v_level     public.stock_levels;
  v_old_qty   numeric(18, 4) := 0;
  v_old_value numeric(18, 2) := 0;
  v_old_avg   numeric(18, 6) := 0;
  v_new_qty   numeric(18, 4);
  v_new_value numeric(18, 2);
  v_new_avg   numeric(18, 6);
  v_cost      numeric(18, 2);
begin
  insert into public.stock_levels (org_id, item_id, warehouse_id)
  values (new.org_id, new.item_id, new.warehouse_id)
  on conflict (item_id, warehouse_id) do nothing;

  select * into v_level
    from public.stock_levels
   where item_id = new.item_id and warehouse_id = new.warehouse_id
   for update;

  v_old_qty   := coalesce(v_level.quantity, 0);
  v_old_value := coalesce(v_level.value, 0);
  v_old_avg   := coalesce(v_level.average_cost, 0);

  if new.quantity >= 0 then
    -- Inbound: unit_cost comes from the source document.
    v_cost      := round(new.quantity * new.unit_cost, 2);
    v_new_qty   := v_old_qty + new.quantity;
    v_new_value := v_old_value + v_cost;
  else
    -- Outbound: valued at the current weighted average.
    if new.unit_cost = 0 then
      new.unit_cost := v_old_avg;
    end if;
    v_cost      := round(new.quantity * new.unit_cost, 2);   -- negative
    v_new_qty   := v_old_qty + new.quantity;
    v_new_value := v_old_value + v_cost;
  end if;

  -- Guard against a negative valuation when stock runs to zero.
  if v_new_qty = 0 then
    v_new_value := 0;
    v_new_avg   := v_old_avg;
  else
    v_new_avg := round(v_new_value / v_new_qty, 6);
  end if;

  new.total_cost         := v_cost;
  new.balance_quantity   := v_new_qty;
  new.balance_value      := v_new_value;
  new.average_cost_after := v_new_avg;

  update public.stock_levels
     set quantity = v_new_qty,
         value = v_new_value,
         average_cost = v_new_avg,
         last_movement_at = now()
   where id = v_level.id;

  -- Roll the per-warehouse figures up onto the item.
  update public.items i
     set quantity_on_hand = (
           select coalesce(sum(sl.quantity), 0)
             from public.stock_levels sl where sl.item_id = i.id),
         average_cost = (
           select case when coalesce(sum(sl.quantity), 0) = 0 then i.average_cost
                       else round(sum(sl.value) / sum(sl.quantity), 6) end
             from public.stock_levels sl where sl.item_id = i.id)
   where i.id = new.item_id;

  return new;
end;
$$;

create trigger apply_movement before insert on public.stock_movements
  for each row execute function app.apply_stock_movement();

-- ---------------------------------------------------------------------
-- Settlement: keep invoice/bill balances in step with allocations
-- ---------------------------------------------------------------------
create or replace function app.apply_allocation()
returns trigger
language plpgsql
as $$
declare
  v_invoice_id uuid := coalesce(new.invoice_id, old.invoice_id);
  v_bill_id    uuid := coalesce(new.bill_id, old.bill_id);
  v_receipt_id uuid := coalesce(new.receipt_id, old.receipt_id);
  v_payment_id uuid := coalesce(new.payment_id, old.payment_id);
  v_paid       numeric(18, 2);
begin
  if v_invoice_id is not null then
    select coalesce(sum(amount + discount_amount), 0) into v_paid
      from public.payment_allocations where invoice_id = v_invoice_id;

    update public.sales_documents
       set paid_amount = v_paid,
           balance_amount = total_amount - v_paid,
           status = case
             when total_amount - v_paid <= 0 then 'completed'::app.doc_status
             when v_paid > 0                 then 'partial'::app.doc_status
             else status
           end
     where id = v_invoice_id;
  end if;

  if v_bill_id is not null then
    select coalesce(sum(amount + discount_amount), 0) into v_paid
      from public.payment_allocations where bill_id = v_bill_id;

    update public.purchase_documents
       set paid_amount = v_paid,
           balance_amount = total_amount - v_paid,
           status = case
             when total_amount - v_paid <= 0 then 'completed'::app.doc_status
             when v_paid > 0                 then 'partial'::app.doc_status
             else status
           end
     where id = v_bill_id;
  end if;

  -- Track how much of the receipt/payment is still sitting unapplied.
  if v_receipt_id is not null then
    update public.receipts r
       set unapplied_amount = r.amount - (
             select coalesce(sum(a.amount), 0)
               from public.payment_allocations a where a.receipt_id = r.id)
     where r.id = v_receipt_id;
  end if;

  if v_payment_id is not null then
    update public.purchase_payments p
       set unapplied_amount = p.amount - (
             select coalesce(sum(a.amount), 0)
               from public.payment_allocations a where a.payment_id = p.id)
     where p.id = v_payment_id;
  end if;

  return coalesce(new, old);
end;
$$;

create trigger apply_allocation after insert or update or delete on public.payment_allocations
  for each row execute function app.apply_allocation();

-- ---------------------------------------------------------------------
-- CRM: opportunity stage tracking
-- ---------------------------------------------------------------------
create or replace function app.track_opportunity_stage()
returns trigger
language plpgsql
as $$
declare
  v_stage public.pipeline_stages;
begin
  new.weighted_amount := round(coalesce(new.amount, 0) * coalesce(new.probability, 0) / 100.0, 2);

  if tg_op = 'UPDATE' and new.stage_id is distinct from old.stage_id then
    new.stage_changed_at := now();

    select * into v_stage from public.pipeline_stages where id = new.stage_id;
    if found then
      new.probability      := v_stage.probability;
      new.weighted_amount  := round(coalesce(new.amount, 0) * v_stage.probability / 100.0, 2);
      new.status := case v_stage.stage_type
        when 'won'  then 'won'
        when 'lost' then 'lost'
        else 'open'
      end;
      if v_stage.stage_type in ('won', 'lost') and new.actual_close_date is null then
        new.actual_close_date := current_date;
      end if;
    end if;

    insert into public.opportunity_stage_history (
      org_id, opportunity_id, from_stage_id, to_stage_id, days_in_stage, changed_by
    ) values (
      new.org_id, new.id, old.stage_id, new.stage_id,
      greatest(0, extract(day from now() - old.stage_changed_at)::integer),
      auth.uid()
    );
  end if;

  return new;
end;
$$;

create trigger track_stage before insert or update on public.opportunities
  for each row execute function app.track_opportunity_stage();
