-- ---------------------------------------------------------------------
-- What day a sale happened on
--
-- `0419` pinned every STABLE function to `app.today()` and said the
-- VOLATILE ones -- the ones that read the clock to stamp a date on a row
-- they are writing -- were a separate migration with their own
-- reasoning. This is the first of four that do them. The reasoning is
-- here; `0421`, `0422` and `0423` carry the rest of the functions and
-- point back at it.
--
-- ## What is wrong
--
-- `current_date` is today in the session's time zone and on Supabase the
-- session is UTC. Malaysia is UTC+8. So between midnight and eight in
-- the morning in Kuala Lumpur, a row written now is stamped yesterday.
--
-- A mamak open at half past midnight rings up nasi lemak. The sale, the
-- invoice raised from it and the ledger entry behind it are all dated
-- the previous day. Every day, for the whole of that eight-hour window.
-- The money is right and the date is wrong, which is why nothing has
-- ever complained.
--
-- ## The two things this was said to run into
--
-- **Fiscal period control.** `0399` measured the guard and quoted it:
-- "Fiscal period for 2026-01-01 is closed". A shop that closes August on
-- the last day of August cannot ring up a sale between midnight and
-- eight on the first of September, because the entry it writes is dated
-- the thirty-first. That is not a risk of this change -- it is the
-- present behaviour, and the change removes it. The sale happened in
-- September in the country it happened in.
--
-- **Document numbers already issued.** `app.next_document_number_internal`
-- builds `INV-202609-0001` from `to_char(current_date, 'YYYYMM')` and
-- resets the counter when that key changes. Numbers already issued are
-- untouched: the key is part of the number, and a sequence that resets
-- at Malaysian midnight rather than eight hours later cannot collide
-- with one that has already been handed out under the old key. What
-- changes is that the first invoice of September is numbered as
-- September's, which is what a Malaysian business means by it.
--
-- Neither is a reason to leave it. Both are reasons to say what moves.
--
-- ## What moves
--
-- For eight hours of every day, the date on a POS sale, on the invoice
-- it raises, on a credit note, on a document transferred from another,
-- on the stock a plate takes out of the store, and on a membership
-- period -- and the month in the number each of them is given.
--
-- Near a month end that is also a change of month, and near a period
-- close it is the difference between a refusal and a posting. Both were
-- wrong before.
--
-- ## What does not move
--
-- Anything the caller dates itself. Every one of these functions that
-- takes a date parameter still honours it; `app.today()` only replaces
-- the fallback. A backdated invoice stays backdated.
--
-- ## The guard
--
-- `supabase/tests/malaysian_clock.sql` completes a sale under two
-- session time zones twenty-six hours apart -- never on the same date,
-- at any instant -- and requires the same document date and the same
-- ledger date. That separates a pinned implementation from a
-- session-clock one at every instant.
--
-- It also asserts the month in the number, and says in as many words
-- that this one is weaker: two zones twenty-six hours apart share a
-- `YYYYMM` for all but a day or so either side of a month end, so for
-- most of the month that assertion passes either way. Reverting
-- `app.next_document_number_internal` was measured against it and
-- survived. What catches it is the rule `0423` closes: no function in
-- `public` or `app` asks the session what day it is, with no exceptions
-- left.
-- ---------------------------------------------------------------------

-- The invoice and the sale a till writes when the drawer opens.
CREATE OR REPLACE FUNCTION public.complete_pos_sale(p_sale uuid, p_tenders jsonb, p_contact uuid DEFAULT NULL::uuid)
 RETURNS TABLE(sale_id uuid, invoice_no text, total numeric, cash_due numeric, change_due numeric, rounding numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
  -- What of this basket is going on somebody's account rather than
  -- into the drawer. Counted separately from `v_noncash` because the
  -- two answer different questions: `v_noncash` is what the rounding
  -- rule works from -- an on-account amount is not cash and rounds the
  -- same way a card does -- and this is what no receipt may be written
  -- for.
  v_onacct   numeric := 0;
  v_recv     numeric;
  v_block    text;
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

  -- Worked out again here, not trusted from the screen. A bill parked
  -- at ten to eleven and settled at five past is settled outside the
  -- happy hour, and the customer is charged what the shop's own rule
  -- says at the moment the money changes hands. Re-read afterwards,
  -- because this is what moves the total.
  perform app.refresh_pos_promotions(p_sale);
  perform app.recalc_pos_sale(p_sale);
  select * into v_sale from public.pos_sales where id = p_sale;

  -- The zone minimum, checked at the one moment the basket is final.
  -- Refusing at the door would refuse the wrong thing: every shop with
  -- a minimum takes the address first and the order second.
  v_block := app.pos_delivery_blocked(p_sale);
  if v_block is not null then
    raise exception '%', v_block using errcode = '23514';
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
      if v_kind = 'on_account' then
        v_onacct := v_onacct + v_t.amount;
      end if;
    end if;
    v_n := v_n + 1;
  end loop;

  -- A basket covered entirely by points has nothing left to tender,
  -- and that is a completed sale rather than an unpaid one. Without
  -- this, a customer with enough points to clear the till could put
  -- them all against the basket and then find the sale could not be
  -- rung up at all -- a dead end reachable from the screen that offers
  -- the redemption.
  if v_n = 0 and v_sale.total_amount > 0 then
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

  -- The walk-in contact is not an account. It is one row every
  -- anonymous sale in the outlet is billed to, so putting a basket on
  -- it would build a receivable balance belonging to nobody, that
  -- nobody would ever be chased for. An on-account sale has to name a
  -- customer, which is why this checks what was passed rather than
  -- `v_contact` -- the fallback above is exactly what must not count.
  if v_onacct > 0 and coalesce(p_contact, v_sale.contact_id) is null then
    raise exception
      'A sale on account has to name the customer whose account it goes '
      'on.'
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
    v_sale.org_id, 'invoice', v_no, app.today(), app.today(), v_contact,
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
         -- The redemption AND the bill discount, on the header rather
         -- than spread across the lines. `sales_documents.discount_amount`
         -- is exactly the field for a discount that belongs to the
         -- document, and `prepare_einvoice` already maps it to the
         -- MyInvois total discount, so what LHDN is told matches what
         -- was charged. Both are added because both came off the same
         -- header: reporting only one of them would understate the
         -- discount on every bill a manager touched.
         discount_amount = coalesce(v_sale.loyalty_discount, 0)
                         + coalesce(v_sale.bill_discount, 0)
                         + coalesce(v_sale.promo_discount, 0),
         -- The ride, on the field the ledger already knows what to do
         -- with. 0013 posts shipping_amount to 4900 on its own, so the
         -- courier charge lands in its own revenue account instead of
         -- in food sales, and the journal still balances because the
         -- receivable was always the header total.
         shipping_amount = coalesce(v_sale.delivery_fee, 0),
         -- The service charge, on its own header field so it posts to
         -- 4250 rather than disappearing into food sales, and its tax
         -- added to what the lines already carry. The lines' trigger
         -- owns `tax_amount` and recomputes it from the lines; this
         -- runs after the last line and the document is frozen the
         -- moment it posts, so the addition stands. Same bargain as
         -- `rounding_amount` two fields up, and for the same reason.
         service_charge_amount = coalesce(v_sale.service_charge, 0),
         -- 0418. The tax on the charge, and the code it was charged
         -- under, kept on the document rather than only inside the
         -- header total. The SST-02 return is built by tax type, and a
         -- figure folded into `tax_amount` with no code on it cannot be
         -- put in a column of that return -- which is how eighty sen in
         -- every hundred ringgit went undeclared.
         service_charge_tax = coalesce(v_sale.service_charge_tax, 0),
         service_charge_tax_code_id = v_outlet.service_charge_tax_code_id,
         tax_amount = round(coalesce(d.tax_amount, 0)
                          + coalesce(v_sale.service_charge_tax, 0), 2),
         total_amount    = round(v_sale.total_amount + v_adj, 2),
         base_total_amount = round(v_sale.total_amount + v_adj, 2),
         balance_amount  = round(v_sale.total_amount + v_adj, 2)
   where d.id = v_inv;

  perform app.post_sales_document_internal(v_inv);

  -- --------------------------------------------------------------
  -- The receipt, and the debt closing behind it
  -- --------------------------------------------------------------
  -- What actually arrived. An on-account tender is a promise, so the
  -- receipt is for the rest of the basket and the remainder stays on
  -- the invoice for the customer to settle later.
  v_recv := round(v_sale.total_amount + v_adj - v_onacct, 2);

  -- Banked against the first tender's account, skipping any that went
  -- on account -- those have no bank account and never will, and a null
  -- one falls back to the current account, which is the whole failure
  -- being fixed here. A shop splitting one sale across two accounts is
  -- real and is not this migration's problem; what matters is that the
  -- money lands somewhere named rather than in the current account by
  -- default.
  select tt.bank_account_id, tt.payment_mode_code
    into v_bank, v_mode
    from jsonb_array_elements(p_tenders) with ordinality as e(t, ord)
    join public.pos_tender_types tt on tt.id = (t ->> 'type')::uuid
   where tt.kind <> 'on_account'
   order by e.ord
   limit 1;

  -- A receipt unless the whole basket went on account. Not `v_recv > 0`
  -- on its own: a basket cleared entirely by loyalty points also comes
  -- to nothing, and `0212` deliberately gives that one a receipt for
  -- zero so the sale is a completed sale rather than a stuck one. The
  -- two zeroes mean different things and only one of them means no
  -- money was taken.
  if v_onacct = 0 or v_recv > 0 then
    v_no := app.next_document_number_internal(v_sale.org_id, 'receipt');

    insert into public.receipts (
      org_id, receipt_no, receipt_date, contact_id, payment_mode_code,
      bank_account_id, currency, exchange_rate, amount, base_amount,
      status, notes, created_by)
    values (
      v_sale.org_id, v_no, app.today(), v_contact, v_mode, v_bank,
      'MYR', 1, v_recv, v_recv,
      'draft', 'Counter sale ' || v_sale.sale_no, v_sale.sold_by)
    returning id into v_rcp;
  end if;

  -- Only when there is something to allocate. `payment_allocations`
  -- checks that its amount is positive, and it is right to: an
  -- allocation of nothing is not an allocation. A basket cleared by
  -- points leaves an invoice for zero, which already owes nothing, so
  -- there is nothing for a receipt to settle against it.
  if v_recv > 0 then
    insert into public.payment_allocations
      (org_id, receipt_id, invoice_id, amount, allocated_by)
    values
      (v_sale.org_id, v_rcp, v_inv, v_recv, v_sale.sold_by);
  end if;

  if v_rcp is not null then
    perform app.post_receipt_internal(v_rcp);
  end if;

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
         receipt_id = v_rcp,
         on_account_amount = v_onacct
   where s.id = p_sale;

  -- --------------------------------------------------------------
  -- And the points, last
  -- --------------------------------------------------------------
  -- Nothing above this line touches the loyalty ledger. A parked sale
  -- holds no points: it can be abandoned, and a customer whose balance
  -- fell when a cashier changed their mind has been robbed by a
  -- transaction that never happened.
  -- On the food, not on the ride. A shop that pays points on a courier
  -- charge is paying points on money it hands straight to a rider.
  perform app.pos_settle_loyalty(
    p_sale,
    greatest(round(v_sale.total_amount + v_adj
                   - coalesce(v_sale.delivery_fee, 0), 2), 0));

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
$function$

;

-- And the YYYYMM in the number it is given.
create or replace function app.next_document_number_internal(
  p_org_id uuid, p_doc_type text)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_seq public.number_sequences;
  v_period_key text;
  v_number bigint;
  v_body text;
begin
  insert into public.number_sequences (org_id, doc_type, prefix)
  values (p_org_id, p_doc_type, app.default_doc_prefix(p_doc_type))
  on conflict (org_id, doc_type) do nothing;

  select * into v_seq from public.number_sequences
   where org_id = p_org_id and doc_type = p_doc_type for update;

  v_period_key := case v_seq.reset_policy
    when 'yearly' then to_char(app.today(), 'YYYY')
    when 'monthly' then to_char(app.today(), 'YYYYMM')
    else null end;

  if v_seq.reset_policy <> 'never' and v_seq.period_key is distinct from v_period_key then
    v_number := 1;
  else
    v_number := v_seq.next_value;
  end if;

  update public.number_sequences
     set next_value = v_number + 1, period_key = v_period_key
   where id = v_seq.id;

  v_body := lpad(v_number::text, v_seq.padding, '0');
  return v_seq.prefix || coalesce(v_period_key || '-', '') || v_body || v_seq.suffix;
end; $$;

-- A credit note is dated the day it is raised.
create or replace function public.credit_sales_invoice(
  p_invoice uuid,
  p_lines   jsonb default null,
  p_reason  text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
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
    v_doc.org_id, 'credit_note', v_no, app.today(), app.today(),
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

  perform app.post_sales_document_internal(v_note);
  return v_note;
end;
$$;

-- So is a supplier one.
create or replace function public.credit_purchase_bill(
  p_bill  uuid,
  p_lines jsonb default null,
  p_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
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
    v_doc.org_id, 'purchase_credit_note', v_no, app.today(), app.today(),
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

  perform app.post_purchase_document_internal(v_note);
  return v_note;
end;
$$;

-- The document raised from another, its due date, and whether the quotation it came from is still live.
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
      v_sales.contact_id, v_sales.contact_person_id, v_sales.shipping_address_id,
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
$function$

;

-- The stock movement a plate takes out of the store.
create or replace function app.pos_deplete_recipes(p_sale uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale   public.pos_sales;
  v_wh     uuid;
  v_row    record;
  v_cost   numeric := 0;
  v_lines  jsonb := '[]'::jsonb;
  v_cogs   uuid;
  v_inv    uuid;
  v_entry  uuid;
  v_moved  numeric;
  v_qty    numeric;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    return null;
  end if;

  select coalesce(o.warehouse_id,
                  (select w.id from public.warehouses w
                    where w.org_id = v_sale.org_id and w.is_default limit 1))
    into v_wh
    from public.pos_outlets o where o.id = v_sale.outlet_id;
  if v_wh is null then
    return null;
  end if;

  for v_row in
    with need as (
      select c.item_id, sum(c.quantity) as quantity
        from public.pos_sale_lines l
        cross join lateral app.pos_recipe_components(l.item_id, l.quantity) c
       where l.sale_id = p_sale and l.item_id is not null
       group by c.item_id
      union all
      select c.item_id, sum(c.quantity)
        from public.pos_sale_lines l
        join public.pos_sale_line_modifiers m on m.line_id = l.id
        join public.pos_modifiers pm on pm.id = m.modifier_id
        cross join lateral app.pos_item_consumption(
          pm.recipe_item_id,
          app.uom_qty(pm.recipe_item_id,
                      coalesce(pm.recipe_quantity, 0),
                      coalesce(pm.recipe_uom_code,
                               (select i.uom_code from public.items i
                                 where i.id = pm.recipe_item_id)))
            * m.quantity * l.quantity) c
       where l.sale_id = p_sale
         and pm.recipe_item_id is not null
         and coalesce(pm.recipe_quantity, 0) > 0
       group by c.item_id
    )
    select n.item_id, sum(n.quantity) as quantity, i.name, i.tracking
      from need n join public.items i on i.id = n.item_id
     where i.track_inventory
     group by n.item_id, i.name, i.tracking
     having sum(n.quantity) > 0
  loop
    v_qty := round(v_row.quantity, 4);

    -- The one new clause. See the header.
    if v_row.tracking is not null and v_row.tracking <> 'none' then
      v_qty := least(v_qty, round(app.lot_available(v_row.item_id, v_wh), 4));
    end if;
    if v_qty <= 0 then
      continue;
    end if;

    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id,
      warehouse_id, quantity, unit_cost, source_table, source_id, notes)
    values (
      v_sale.org_id,
      app.next_document_number_internal(v_sale.org_id, 'stock_movement'),
      coalesce(v_sale.completed_at::date, app.today()),
      'assembly_out', v_row.item_id, v_wh, -v_qty, 0,
      'pos_sales', p_sale, 'Recipe ' || v_sale.sale_no);

    select sm.total_cost into v_moved
      from public.stock_movements sm
     where sm.source_table = 'pos_sales' and sm.source_id = p_sale
       and sm.item_id = v_row.item_id
     order by sm.created_at desc limit 1;

    v_cost := v_cost + coalesce(v_moved, 0);
  end loop;

  if round(v_cost, 2) = 0 then
    return null;
  end if;

  select a.id into v_cogs from public.accounts a
   where a.org_id = v_sale.org_id and a.code = '5200';
  select a.id into v_inv from public.accounts a
   where a.org_id = v_sale.org_id and a.code = '1310';
  if v_cogs is null or v_inv is null then
    return null;
  end if;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_cogs,
      'description', 'Food cost ' || v_sale.sale_no,
      'debit', greatest(-v_cost, 0), 'credit', greatest(v_cost, 0)),
    jsonb_build_object('account_id', v_inv,
      'description', 'Ingredients ' || v_sale.sale_no,
      'debit', greatest(v_cost, 0), 'credit', greatest(-v_cost, 0)));

  v_entry := app.create_gl_entry_internal(
    v_sale.org_id,
    coalesce(v_sale.completed_at::date, app.today()),
    'stock_movement', v_lines,
    'Recipe consumption ' || v_sale.sale_no, 'pos_sales', p_sale);

  update public.stock_movements sm
     set gl_entry_id = v_entry
   where sm.source_table = 'pos_sales' and sm.source_id = p_sale
     and sm.gl_entry_id is null;

  return v_entry;
end;
$$;

-- Refusing a new validity date that is already in the past.
create or replace function public.extend_document_validity(
  p_document uuid, p_valid_until date)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_d public.sales_documents;
begin
  select * into v_d from public.sales_documents
   where id = p_document and deleted_at is null;
  if v_d.id is null then
    raise exception 'No such document.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_d.org_id) then
    raise exception 'not permitted to change this document'
      using errcode = '42501';
  end if;
  if v_d.doc_type not in ('quotation', 'proforma') then
    raise exception
      'Only a quotation or a proforma has a validity. % is a %.',
      v_d.doc_no, v_d.doc_type using errcode = '22023';
  end if;
  if p_valid_until is null then
    raise exception 'Give the new date it is good until.'
      using errcode = '23514';
  end if;
  -- A date already gone is not an extension, it is a typo. Refusing it
  -- here means the only way past the transfer guard is a date somebody
  -- meant.
  if p_valid_until < app.today() then
    raise exception
      'That date has already passed. An extension has to be to a day the '
      'price still holds.' using errcode = '23514';
  end if;
  if p_valid_until < v_d.doc_date then
    raise exception
      'A quotation cannot expire before the day it was raised (%).',
      to_char(v_d.doc_date, 'DD Mon YYYY') using errcode = '23514';
  end if;

  update public.sales_documents
     set valid_until = p_valid_until, updated_at = now()
   where id = p_document;
end $$;

-- The day a membership was used against a line.
create or replace function public.cover_line_with_membership(
  p_line         uuid,
  p_subscription uuid)
returns numeric
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_line public.pos_sale_lines;
  v_stat app.pos_sale_status;
  v_sub  public.pos_membership_subscriptions;
  v_mem  public.pos_memberships;
  v_left integer;
  v_cov  numeric;
begin
  select * into v_line from public.pos_sale_lines where id = p_line;
  if v_line.id is null then
    raise exception 'No such line.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_line.org_id, 'memberships') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  select s.status into v_stat from public.pos_sales s where s.id = v_line.sale_id;
  if v_stat <> 'parked' then
    raise exception 'That bill is % and cannot be changed.', v_stat
      using errcode = '23514';
  end if;

  select * into v_sub from public.pos_membership_subscriptions where id = p_subscription;
  if v_sub.id is null or v_sub.org_id <> v_line.org_id then
    raise exception 'No such membership.' using errcode = 'P0002';
  end if;
  if v_sub.status <> 'active' then
    raise exception 'That membership is %.', v_sub.status using errcode = '23514';
  end if;

  select * into v_mem from public.pos_memberships where id = v_sub.membership_id;

  -- An empty list means everything, which is what unlimited is.
  if exists (select 1 from public.membership_items mi
              where mi.membership_id = v_mem.id)
     and not exists (select 1 from public.membership_items mi
                      where mi.membership_id = v_mem.id and mi.item_id = v_line.item_id) then
    raise exception '% does not cover %.', v_mem.name, v_line.description
      using errcode = '23514';
  end if;

  if v_mem.sessions_included is not null then
    select b.remaining into v_left from public.membership_balance(p_subscription) b;
    if coalesce(v_left, 0) < 1 then
      raise exception
        'That membership has no sessions left this period.'
        using errcode = '23514';
    end if;
  end if;

  -- The whole line, discounted away. Computed from the line rather than
  -- passed in, because a caller that could name the amount could cover
  -- a fifty-ringgit treatment with a ten-ringgit membership.
  v_cov := round(v_line.unit_price * v_line.quantity, 2);

  update public.pos_sale_lines l set discount_amount = v_cov where l.id = p_line;
  perform app.reprice_pos_line(p_line);

  insert into public.pos_membership_sessions
    (org_id, subscription_id, sale_id, line_id, used_on)
  values (v_line.org_id, p_subscription, v_line.sale_id, p_line, app.today());

  return v_cov;
end;
$$;

-- The day one begins, and the period it begins in.
create or replace function public.start_membership(
  p_sale       uuid,
  p_membership uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale public.pos_sales;
  v_mem  public.pos_memberships;
  v_sub  uuid;
  v_rec  uuid;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'memberships') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'completed' then
    raise exception
      'Take the money first. A membership that starts before the sale '
      'completes is an entitlement nobody paid for.'
      using errcode = '23514';
  end if;
  if v_sale.contact_id is null then
    raise exception 'A membership needs a member. Say who the customer is.'
      using errcode = '23502';
  end if;

  select * into v_mem from public.pos_memberships
   where id = p_membership and org_id = v_sale.org_id and is_active;
  if v_mem.id is null then
    raise exception 'That membership is not on offer.' using errcode = 'P0002';
  end if;

  -- The membership has to have been bought on this sale. Otherwise
  -- "start a membership" is a button that gives one away.
  if not exists (select 1 from public.pos_sale_lines l
                  where l.sale_id = p_sale and l.item_id = v_mem.item_id) then
    raise exception
      'This sale does not include %. Ring it up first.', v_mem.name
      using errcode = '23514';
  end if;

  insert into public.pos_membership_subscriptions
    (org_id, membership_id, contact_id, started_on, origin_sale_id, created_by)
  values (v_sale.org_id, p_membership, v_sale.contact_id,
          coalesce(v_sale.completed_at::date, app.today()), p_sale, auth.uid())
  returning id into v_sub;

  -- The renewal schedule, from the invoice the customer just paid --
  -- which already carries the right price, tax code and terms.
  if v_sale.invoice_id is not null and app.can_post(v_sale.org_id) then
    begin
      v_rec := public.create_recurring_document(
        v_sale.invoice_id,
        v_mem.name || ' — ' || to_char(app.today(), 'YYYY'),
        v_mem.period,
        (select (p.period_end + 1)::date from app.membership_period(v_sub, app.today()) p),
        1, null, null, false, false);
      update public.pos_membership_subscriptions s
         set recurring_document_id = v_rec where s.id = v_sub;
    exception when others then
      -- Reported rather than fatal. The member has paid; the schedule
      -- is a thing somebody with the right role can add afterwards, and
      -- `membership_billing_gaps` is how they find out they need to.
      null;
    end;
  end if;

  return v_sub;
end;
$$;

-- And the day it ends.
create or replace function public.set_membership_status(
  p_subscription uuid,
  p_status       app.pos_membership_status)
returns app.pos_membership_status
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sub public.pos_membership_subscriptions;
begin
  select * into v_sub from public.pos_membership_subscriptions where id = p_subscription;
  if v_sub.id is null then
    raise exception 'No such membership.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sub.org_id, 'memberships') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  update public.pos_membership_subscriptions s
     set status = p_status,
         ends_on = case when p_status in ('cancelled', 'expired')
                        then coalesce(s.ends_on, app.today()) else s.ends_on end
   where s.id = p_subscription;

  -- The billing stops with the membership. A cancelled member who keeps
  -- receiving invoices is the complaint that reaches the regulator.
  if p_status in ('cancelled', 'expired') and v_sub.recurring_document_id is not null then
    update public.recurring_documents r
       set is_active = false where r.id = v_sub.recurring_document_id;
  end if;

  return p_status;
end;
$$;
