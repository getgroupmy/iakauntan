-- =====================================================================
-- iAkauntan :: 0357 a counter sale the customer has not paid for yet
--
-- `app.pos_tender_kind` has had `on_account` since `0208` and
-- `complete_pos_sale` has never known what it means. Every tender that
-- is not cash is lumped into `v_noncash`, and the sale then writes a
-- receipt for the whole basket and posts it. So a bill put on a
-- customer's account came out as:
--
--   Dr Receivables   Cr Revenue, Cr Tax     -- the invoice, correct
--   Dr Bank          Cr Receivables         -- the receipt, invented
--
-- and the debt the first entry raised was cleared by the second. The
-- bank in question is whatever `pos_tender_types.bank_account_id`
-- points at, which for an on-account tender is nothing, so
-- `post_receipt_internal` falls through to its default and the money
-- lands in the current account (1120). A shop running accounts for
-- regulars would show cash it never took, a debtors ledger that never
-- grew, and a bank reconciliation with a phantom deposit on every
-- account sale.
--
-- Nothing crashed and nothing was out of balance, which is why it
-- survived: the journal is internally consistent and describes a
-- transaction that did not happen.
--
-- ---------------------------------------------------------------------
-- What it does now
--
-- The invoice is unchanged — the customer is billed either way, and the
-- credit limit trigger from `0086` already fires on it, so an account
-- sale past the limit is refused by machinery that already exists. What
-- changes is the receipt: it is written for the basket **less** what
-- went on account, and not written at all when the whole basket did.
-- The invoice keeps its balance and is settled later through the
-- ordinary receipts path, like any other invoice.
--
-- ---------------------------------------------------------------------
-- Two things that had to move with it
--
-- `pos_sales_documents_ck` said a completed sale has both an invoice and
-- a receipt — "anything else is a sale that took money and recorded
-- nothing". That is right for cash and for a card, and precisely wrong
-- here: an account sale takes no money, so there is nothing for a
-- receipt to record. The constraint is replaced rather than dropped,
-- because the thing it was guarding is still worth guarding. It now
-- needs `on_account_amount`, which is added for it and earns its place
-- twice over: it is also the only way to ask what a shop sold on
-- account without unpicking `pos_tenders`.
--
-- And the receipt's bank account was taken from the *first* tender.
-- With an account sale that is the tender with no bank account, so a
-- mixed basket — half cash, half on the account — would have banked the
-- cash half into the fallback current account. It now takes the first
-- tender that is not on account.
-- =====================================================================

alter table public.pos_sales
  add column if not exists on_account_amount numeric(18, 2) not null default 0;

comment on column public.pos_sales.on_account_amount is
  'How much of this sale went on the customer''s account rather than '
  'into the drawer. No receipt is written for it; the invoice keeps '
  'that much of its balance.';

alter table public.pos_sales drop constraint if exists pos_sales_documents_ck;
alter table public.pos_sales add constraint pos_sales_documents_ck check (
  status <> 'completed'
  or (invoice_id is not null
      and (receipt_id is not null or on_account_amount >= total_amount)));

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
      v_sale.org_id, v_no, current_date, v_contact, v_mode, v_bank,
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
$$;

comment on function public.complete_pos_sale(uuid, jsonb, uuid) is
  'Settles a parked sale: raises and posts the invoice, writes and '
  'posts a receipt for whatever was actually paid, records the tenders '
  'and awards the points. An on_account tender is not payment — it '
  'leaves that much on the invoice and requires a named customer, '
  'because the outlet''s walk-in contact is not an account anybody '
  'would ever be chased on.';
