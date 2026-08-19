-- Completing a sale: a real invoice, a real receipt, one act.
--
-- ## Selling is not the same permission as posting
--
-- `public.post_sales_document` and `public.post_receipt` both check
-- `app.can_post`, and rightly — posting to the ledger is an
-- accountant's authority. A cashier does not have it and should not.
--
-- But a cashier ringing up a sale *must* produce a posted invoice and a
-- posted receipt, or the shop takes money and records nothing. The
-- authority to sell across a counter is a real authority; it is simply
-- a narrower one than "post anything".
--
-- 0056 met this exact problem for documents and answered it by
-- splitting the function: `app.*_internal` does the work,
-- `public.*` checks first and delegates, and only guarded callers reach
-- the internal one. Receipts never got the same treatment because
-- nothing until now needed to post one on somebody's behalf.
--
-- So this splits `post_receipt` the same way. The body below is 0079's,
-- verbatim, with exactly one thing removed: the three-line permission
-- check. It was produced by transforming the file rather than retyped —
-- 0206 is a fresh reminder of what happens when a function is restated
-- from memory or from the wrong version — and 0079's body was confirmed
-- byte-identical to what production is running before it was touched.
--
-- ## What a completed sale is
--
-- An invoice, posted: stock leaves the outlet's warehouse, revenue and
-- SST hit the ledger, the walk-in owes the money for an instant. Then a
-- receipt, posted and allocated to it in full: the cash account takes
-- the money and the debt closes.
--
-- Both, or neither. It runs in one transaction, so a till that dies
-- between the two leaves no invoice at all rather than an unpaid one.
--
-- ## The rounding the trigger would otherwise impose
--
-- `app.recalc_sales_totals` recomputes `rounding_amount` from the
-- *organization's* method every time a line changes. For a shop set to
-- `nearest_5cent` that would round a card-only sale, which 0208 exists
-- to prevent.
--
-- The lines go in first and the header's rounding is written after,
-- because the trigger fires on line changes and not on header ones. It
-- is a real seam and worth naming rather than hiding: POS is asserting
-- authority over a number the trigger normally owns, and the test in
-- the next migration checks the invoice total equals what the customer
-- actually paid.

create or replace function app.post_receipt_internal(p_id uuid)
returns uuid
language plpgsql security definer
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
  v_fx         numeric(18, 2) := 0;
begin
  select * into v_rcp from public.receipts where id = p_id;
  if not found then raise exception 'Receipt % not found', p_id; end if;
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

  -- The currency movement between invoice and receipt.
  --
  -- fc_debit and fc_credit are stated as zero rather than left to be
  -- derived: this is a ringgit adjustment with no foreign amount behind
  -- it, and deriving one would invent dollars that were never invoiced.
  v_fx := app.realised_fx_on_settlement(p_id, true, v_rcp.currency, v_rate);

  if v_fx > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_ar_acct, 'description', 'Exchange gain on ' || v_rcp.receipt_no,
      'debit', v_fx, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,
      'contact_id', v_rcp.contact_id);
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(v_rcp.org_id, true),
      'description', 'Exchange gain on ' || v_rcp.receipt_no,
      'debit', 0, 'credit', v_fx, 'fc_debit', 0, 'fc_credit', 0);
  elsif v_fx < 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(v_rcp.org_id, false),
      'description', 'Exchange loss on ' || v_rcp.receipt_no,
      'debit', -v_fx, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_ar_acct, 'description', 'Exchange loss on ' || v_rcp.receipt_no,
      'debit', 0, 'credit', -v_fx, 'fc_debit', 0, 'fc_credit', 0,
      'contact_id', v_rcp.contact_id);
  end if;

  v_entry_id := public.create_gl_entry(
    v_rcp.org_id, v_rcp.receipt_date, 'receipt'::app.journal_source, v_entries,
    'Receipt ' || v_rcp.receipt_no, 'receipts', v_rcp.id, v_rcp.reference,
    v_rcp.currency, v_rate);

  update public.receipts
     set gl_entry_id = v_entry_id, status = 'posted',
         base_amount = round(v_rcp.amount * v_rate, 2),
         fx_gain_loss = v_fx,
         posted_at = now(), posted_by = auth.uid()
   where id = p_id;

  update public.bank_accounts
     set current_balance = current_balance + v_net
   where id = v_rcp.bank_account_id;

  return v_entry_id;
end;
$$;
-- The public entry point keeps the check it always had, and delegates.
create or replace function public.post_receipt(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select org_id into v_org from public.receipts where id = p_id;
  if v_org is null then
    raise exception 'Receipt % not found', p_id using errcode = 'P0002';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  return app.post_receipt_internal(p_id);
end;
$$;

-- Reaching the internal one from an API key would be posting with the
-- permission check taken off, which is the whole point of splitting it.
revoke all on function app.post_receipt_internal(uuid)
  from public, anon, authenticated;
revoke all on function public.post_receipt(uuid) from public, anon;
grant execute on function public.post_receipt(uuid) to authenticated;

comment on function app.post_receipt_internal(uuid) is
  '0079''s post_receipt with the permission check removed, for guarded '
  'callers that have already established a narrower authority — a till '
  'completing its own sale. Same split, and same reason, as 0056 made '
  'for documents.';

-- ---------------------------------------------------------------------
-- Starting a basket
-- ---------------------------------------------------------------------
create or replace function public.open_pos_sale(
  p_register    uuid,
  p_contact     uuid default null,
  p_client_uuid uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid; v_outlet uuid; v_shift uuid; v_sale uuid; v_no text;
begin
  select r.org_id, r.outlet_id into v_org, v_outlet
    from public.pos_registers r
   where r.id = p_register and r.deleted_at is null and r.is_active;
  if v_org is null then
    raise exception 'That register does not exist, or has been retired.'
      using errcode = 'P0002';
  end if;

  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  select s.id into v_shift from public.pos_shifts s
   where s.register_id = p_register and s.status <> 'closed';
  if v_shift is null then
    raise exception
      'No shift is open on this till. Count the float in before selling.'
      using errcode = '23514';
  end if;

  -- The till may have sent this before and not heard back. Hand the
  -- same sale back rather than starting a second basket, which is the
  -- whole reason the id is generated on the device.
  if p_client_uuid is not null then
    select s.id into v_sale from public.pos_sales s
     where s.org_id = v_org and s.client_uuid = p_client_uuid;
    if v_sale is not null then
      return v_sale;
    end if;
  end if;

  v_no := app.next_document_number_internal(v_org, 'pos_sale');

  insert into public.pos_sales
    (org_id, shift_id, register_id, outlet_id, sale_no, status,
     client_uuid, contact_id, sold_by)
  values
    (v_org, v_shift, p_register, v_outlet, v_no, 'parked',
     p_client_uuid, p_contact, auth.uid())
  returning id into v_sale;

  return v_sale;
end;
$$;

revoke all on function public.open_pos_sale(uuid, uuid, uuid) from public, anon;
grant execute on function public.open_pos_sale(uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Ringing something up
-- ---------------------------------------------------------------------
--
-- Prices from the item unless the till says otherwise, and taxes from
-- the item's own sales tax code. A price passed in is honoured, because
-- a manager overriding at the counter is an ordinary thing; what is not
-- honoured is a price the client invents for an item it did not look
-- up, which is why the item must exist and belong to this company.
create or replace function public.add_pos_sale_line(
  p_sale     uuid,
  p_item     uuid,
  p_quantity numeric default 1,
  p_price    numeric default null,
  p_discount numeric default 0,
  p_note     text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid; v_status app.pos_sale_status; v_outlet uuid;
  v_incl boolean; v_wh uuid;
  v_item record; v_rate numeric := 0; v_taxcode uuid;
  v_price numeric; v_line uuid; v_no integer;
  v_gross numeric; v_net numeric; v_tax numeric;
begin
  select s.org_id, s.status, s.outlet_id into v_org, v_status, v_outlet
    from public.pos_sales s where s.id = p_sale;
  if v_org is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_status <> 'parked' then
    raise exception
      'That sale is % and cannot be added to.', v_status using errcode = '23514';
  end if;
  if coalesce(p_quantity, 0) <= 0 then
    raise exception 'A line needs a quantity.' using errcode = '23514';
  end if;

  select o.prices_include_tax, o.warehouse_id into v_incl, v_wh
    from public.pos_outlets o where o.id = v_outlet;

  select i.id, i.name, i.uom_code, i.unit_price, i.sales_tax_code_id
    into v_item
    from public.items i
   where i.id = p_item and i.org_id = v_org and i.deleted_at is null;
  if v_item.id is null then
    raise exception 'That item is not on this company''s list.'
      using errcode = 'P0002';
  end if;

  v_price := coalesce(p_price, v_item.unit_price, 0);
  v_taxcode := v_item.sales_tax_code_id;
  if v_taxcode is not null then
    select t.rate into v_rate from public.tax_codes t
     where t.id = v_taxcode and t.is_active;
    if v_rate is null then
      v_taxcode := null; v_rate := 0;
    end if;
  end if;

  -- The same split app.calc_document_line performs, done here because
  -- a POS line is not a document line yet and the till has to show the
  -- customer a total before either exists.
  v_gross := round(v_price * p_quantity, 2) - coalesce(p_discount, 0);
  if v_incl and v_rate > 0 then
    v_net := round(v_gross / (1 + v_rate / 100.0), 2);
    v_tax := round(v_gross - v_net, 2);
  else
    v_net := round(v_gross, 2);
    v_tax := round(v_net * v_rate / 100.0, 2);
  end if;

  select coalesce(max(l.line_no), 0) + 1 into v_no
    from public.pos_sale_lines l where l.sale_id = p_sale;

  insert into public.pos_sale_lines (
    org_id, sale_id, line_no, item_id, description, quantity, uom_code,
    unit_price, discount_amount, tax_code_id, tax_rate, tax_amount,
    is_tax_inclusive, line_subtotal, line_total, warehouse_id, note)
  values (
    v_org, p_sale, v_no, p_item, v_item.name, p_quantity, v_item.uom_code,
    v_price, coalesce(p_discount, 0), v_taxcode, v_rate, v_tax,
    coalesce(v_incl, false), v_net, v_net + v_tax, v_wh, p_note)
  returning id into v_line;

  perform app.recalc_pos_sale(p_sale);
  return v_line;
end;
$$;

revoke all on function public.add_pos_sale_line(uuid, uuid, numeric, numeric, numeric, text)
  from public, anon;
grant execute on function public.add_pos_sale_line(uuid, uuid, numeric, numeric, numeric, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- What the basket comes to
-- ---------------------------------------------------------------------
--
-- Recomputed from the lines every time one changes, never accumulated,
-- for the reason every other running total in this database is derived:
-- a counter is wrong the moment a line is removed.
create or replace function app.recalc_pos_sale(p_sale uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_sub numeric; v_tax numeric; v_disc numeric;
begin
  select coalesce(sum(l.line_subtotal), 0),
         coalesce(sum(l.tax_amount), 0),
         coalesce(sum(l.discount_amount), 0)
    into v_sub, v_tax, v_disc
    from public.pos_sale_lines l where l.sale_id = p_sale;

  update public.pos_sales s
     set subtotal = v_sub,
         tax_amount = v_tax,
         discount_amount = v_disc,
         -- The exact basket. Rounding is decided at tender time and
         -- written then, because until somebody chooses how to pay
         -- there is no answer to give.
         total_amount = round(v_sub + v_tax, 2)
   where s.id = p_sale;
end;
$$;

revoke all on function app.recalc_pos_sale(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Taking the money
-- ---------------------------------------------------------------------
--
-- `p_tenders` is `[{"type": uuid, "amount": n, "reference": "..."}]`,
-- in the order the customer offered them. The last cash tender is the
-- one that gives change, because that is what happens across a counter:
-- the card goes first for a round amount and the notes settle the rest.
--
-- Returns the sale. Raises rather than half-completing: a till that
-- takes money and records nothing is the failure this whole module is
-- arranged to prevent, so every step below is in one transaction and
-- any one of them failing takes the others with it.
create or replace function public.complete_pos_sale(
  p_sale    uuid,
  p_tenders jsonb,
  p_contact uuid default null)
returns table (
  sale_id     uuid,
  invoice_no  text,
  total       numeric,
  cash_due    numeric,
  change_due  numeric,
  rounding    numeric)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale     public.pos_sales;
  v_outlet   public.pos_outlets;
  v_round    boolean;
  v_noncash  numeric := 0;
  v_cashin   numeric := 0;
  v_cashdue  numeric;
  v_adj      numeric;
  v_change   numeric;
  v_contact  uuid;
  v_inv      uuid;
  v_rcp      uuid;
  v_no       text;
  v_line     record;
  v_t        record;
  v_n        integer := 0;
  v_kind     app.pos_tender_kind;
  v_bank     uuid;
  v_mode     text;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'parked' then
    raise exception 'That sale is already %.', v_sale.status
      using errcode = '23514';
  end if;
  -- Aliased, because `sale_id` is also an OUT parameter of this
  -- function and plpgsql cannot tell which one an unqualified reference
  -- means. It refuses rather than guessing, which is the right choice
  -- and only says so at run time.
  if not exists (select 1 from public.pos_sale_lines l where l.sale_id = p_sale) then
    raise exception 'There is nothing on this sale to pay for.'
      using errcode = '23514';
  end if;

  select * into v_outlet from public.pos_outlets where id = v_sale.outlet_id;
  select coalesce(ps.round_cash_to_5sen, true) into v_round
    from public.pos_settings ps where ps.org_id = v_sale.org_id;
  v_round := coalesce(v_round, true);

  -- --------------------------------------------------------------
  -- What is being paid with what
  -- --------------------------------------------------------------
  for v_t in
    select (e ->> 'type')::uuid   as type_id,
           (e ->> 'amount')::numeric as amount,
            e ->> 'reference'     as reference
      from jsonb_array_elements(coalesce(p_tenders, '[]'::jsonb)) e
  loop
    if v_t.amount is null or v_t.amount <= 0 then
      raise exception 'A tender needs an amount.' using errcode = '23514';
    end if;
    select tt.kind into v_kind from public.pos_tender_types tt
     where tt.id = v_t.type_id and tt.org_id = v_sale.org_id and tt.is_active;
    if v_kind is null then
      raise exception 'That is not a tender this company accepts.'
        using errcode = 'P0002';
    end if;
    if v_kind = 'cash' then
      v_cashin := v_cashin + v_t.amount;
    else
      v_noncash := v_noncash + v_t.amount;
    end if;
    v_n := v_n + 1;
  end loop;

  if v_n = 0 then
    raise exception 'A sale has to be paid for.' using errcode = '23514';
  end if;

  -- 0208's rule: round what is left after everything that is not cash.
  v_cashdue := app.pos_cash_due(v_sale.total_amount, v_noncash, v_round);
  v_adj     := app.pos_rounding_adjustment(v_sale.total_amount, v_noncash, v_round);
  v_change  := round(v_cashin - v_cashdue, 2);

  if v_change < 0 then
    raise exception
      'Short by %. The customer still owes that much.', -v_change
      using errcode = '23514';
  end if;
  -- Non-cash cannot over-pay: a card charged more than the basket is a
  -- refund waiting to happen, not a sale.
  if v_noncash > v_sale.total_amount + 0.005 and v_cashin = 0 then
    raise exception
      'That is more than the basket comes to. Charge the card the right '
      'amount, or take the difference as a refund.'
      using errcode = '23514';
  end if;

  v_contact := coalesce(p_contact, v_sale.contact_id, v_outlet.walk_in_contact_id);
  if v_contact is null then
    raise exception
      'This outlet has no walk-in customer set, so an anonymous sale has '
      'nobody to bill. Set one on the outlet.'
      using errcode = '23502';
  end if;

  -- --------------------------------------------------------------
  -- The invoice
  -- --------------------------------------------------------------
  v_no := app.next_document_number_internal(v_sale.org_id, 'invoice');

  -- No salesperson. `sales_documents.salesperson_id` points at
  -- `public.salespeople` — a commission record — and not at the user
  -- who rang the sale up. A cashier is not automatically one of those,
  -- and 0105 has a trigger that says so. Who served the customer is on
  -- `pos_sales.sold_by`, which is the right place for it; a shop that
  -- pays counter commission can map the two later.
  insert into public.sales_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
    exchange_rate, status, notes, created_by)
  values (
    v_sale.org_id, 'invoice', v_no, current_date, current_date, v_contact,
    'MYR', 1, 'draft',
    'Counter sale ' || v_sale.sale_no, v_sale.sold_by)
  returning id into v_inv;

  for v_line in
    select * from public.pos_sale_lines l where l.sale_id = p_sale order by l.line_no
  loop
    insert into public.sales_document_lines (
      org_id, document_id, line_no, line_type, item_id, description,
      quantity, uom_code, unit_price, discount_amount, tax_code_id,
      tax_rate, is_tax_inclusive, warehouse_id)
    values (
      v_sale.org_id, v_inv, v_line.line_no, 'item', v_line.item_id,
      v_line.description, v_line.quantity, v_line.uom_code,
      v_line.unit_price, v_line.discount_amount, v_line.tax_code_id,
      v_line.tax_rate, v_line.is_tax_inclusive, v_line.warehouse_id);
  end loop;

  -- After the lines, because the totals trigger fires on line changes
  -- and would otherwise impose the organization's rounding on a card
  -- sale. See the header: this is POS taking a number the trigger
  -- normally owns, and the test asserts the result.
  update public.sales_documents d
     set rounding_amount = v_adj,
         total_amount    = round(v_sale.total_amount + v_adj, 2),
         base_total_amount = round(v_sale.total_amount + v_adj, 2),
         balance_amount  = round(v_sale.total_amount + v_adj, 2)
   where d.id = v_inv;

  perform app.post_sales_document_internal(v_inv);

  -- --------------------------------------------------------------
  -- The receipt, and the debt closing behind it
  -- --------------------------------------------------------------
  -- Banked against the first tender's account. A shop splitting one
  -- sale across two accounts is real and is not this migration's
  -- problem; what matters here is that the money lands somewhere named
  -- rather than in the current account by default.
  select tt.bank_account_id, tt.payment_mode_code
    into v_bank, v_mode
    from public.pos_tender_types tt
   where tt.id = ((p_tenders -> 0) ->> 'type')::uuid;

  v_no := app.next_document_number_internal(v_sale.org_id, 'receipt');

  insert into public.receipts (
    org_id, receipt_no, receipt_date, contact_id, payment_mode_code,
    bank_account_id, currency, exchange_rate, amount, base_amount,
    status, notes, created_by)
  values (
    v_sale.org_id, v_no, current_date, v_contact, v_mode, v_bank,
    'MYR', 1,
    round(v_sale.total_amount + v_adj, 2),
    round(v_sale.total_amount + v_adj, 2),
    'draft', 'Counter sale ' || v_sale.sale_no, v_sale.sold_by)
  returning id into v_rcp;

  insert into public.payment_allocations
    (org_id, receipt_id, invoice_id, amount, allocated_by)
  values
    (v_sale.org_id, v_rcp, v_inv, round(v_sale.total_amount + v_adj, 2),
     v_sale.sold_by);

  perform app.post_receipt_internal(v_rcp);

  -- --------------------------------------------------------------
  -- And the tenders, now that they are known to be good
  -- --------------------------------------------------------------
  for v_t in
    select (e ->> 'type')::uuid as type_id,
           (e ->> 'amount')::numeric as amount,
            e ->> 'reference' as reference,
           row_number() over () as rn,
           count(*) over () as total_rows
      from jsonb_array_elements(p_tenders) e
  loop
    select tt.kind into v_kind from public.pos_tender_types tt
     where tt.id = v_t.type_id;
    insert into public.pos_tenders
      (org_id, sale_id, tender_type_id, kind, amount, change_given, reference)
    values
      (v_sale.org_id, p_sale, v_t.type_id, v_kind, v_t.amount,
       -- Change comes out of the last tender offered, which is the one
       -- the customer is standing there waiting for.
       case when v_t.rn = v_t.total_rows then v_change else 0 end,
       v_t.reference);
  end loop;

  update public.pos_sales s
     set status = 'completed',
         completed_at = now(),
         contact_id = v_contact,
         rounding_amount = v_adj,
         total_amount = round(v_sale.total_amount + v_adj, 2),
         invoice_id = v_inv,
         receipt_id = v_rcp
   where s.id = p_sale;

  sale_id := p_sale;
  select d.doc_no into invoice_no from public.sales_documents d where d.id = v_inv;
  -- Scaled to the sen on the way out. `numeric` with no declared scale
  -- is exact and prints as 10.8500000000000000, which reaches the till
  -- as a string and is the one number a customer reads back off a
  -- receipt. Correct is not the same as legible.
  total := round(v_sale.total_amount + v_adj, 2);
  cash_due := round(v_cashdue, 2);
  change_due := round(v_change, 2);
  rounding := round(v_adj, 2);
  return next;
end;
$$;

revoke all on function public.complete_pos_sale(uuid, jsonb, uuid) from public, anon;
grant execute on function public.complete_pos_sale(uuid, jsonb, uuid) to authenticated;

comment on function public.complete_pos_sale(uuid, jsonb, uuid) is
  'Takes the money and produces a posted invoice and a posted receipt '
  'allocated to it, in one transaction. Both or neither: a till that '
  'dies between them leaves no invoice rather than an unpaid one.';
