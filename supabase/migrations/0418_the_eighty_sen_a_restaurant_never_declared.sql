-- =====================================================================
-- iAkauntan :: the eighty sen a restaurant charged and never declared
--
-- `0410` gave a Malaysian bill its service charge and taxed it. The tax
-- is charged, it is printed on the bill, and `post_sales_document` puts
-- it in output tax at 2130 with everything else. `report_sst_summary`
-- -- which is the SST-02 return -- sums `tax_amount` off the document
-- **lines**, and the charge is not a line. It is a percentage of all of
-- them, so its tax was on the header.
--
-- Measured on this stack before the change, on the worked example from
-- `pos_service_charge.sql`: RM100 of food, ten per cent for the table,
-- eight per cent service tax on the hundred and ten.
--
--     the document says output tax   8.80
--     the SST-02 return says         8.00
--     under-declared to Customs      0.80
--
-- Eighty sen in every hundred ringgit -- about a twelfth of a
-- restaurant's whole service tax liability -- left off a statutory
-- return, every taxable period, while the company's own ledger carries
-- the right figure. The two disagreeing is the only reason anybody
-- would ever have found it.
--
-- ## Why it could not simply be added up
--
-- The return is built **by tax type**: one row per code, taxable value
-- and tax. A figure folded into `tax_amount` with no tax code attached
-- to it cannot be put in a column of that return. `sales_documents`
-- recorded the charge but not what it had been charged under -- only
-- `pos_outlets.service_charge_tax_code_id` knew, two joins away and
-- only for a sale that came from a till.
--
-- So the document now carries both, `complete_pos_sale` writes them,
-- and the return reads them from the header where they are. The two
-- columns join `0238`'s frozen list for the reason the amount did: a
-- figure a return declares must not be editable after posting.
--
-- ## Not changed here
--
-- A service charge typed onto an ordinary sales document is still not
-- taxed -- `recalc_sales_totals` adds it to the total and stops. Only
-- the till charges tax on it, because only the outlet says at what
-- rate. That is a real gap and it is not this migration's: it needs a
-- rate on the document, and a screen to set it on, and nothing today
-- can put a service charge on a document except a till.
-- =====================================================================

alter table public.sales_documents
  add column if not exists service_charge_tax numeric(18, 2) not null default 0,
  add column if not exists service_charge_tax_code_id uuid
    references public.tax_codes(id);

comment on column public.sales_documents.service_charge_tax is
  'Service tax charged on service_charge_amount. Already inside '
  'tax_amount; kept separately so report_sst_summary can declare it '
  'under its own tax type. See 0418.';
comment on column public.sales_documents.service_charge_tax_code_id is
  'Which tax code the service charge was charged under. Without it the '
  'SST-02 return has nowhere to put the tax. See 0418.';

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
$function$

;

CREATE OR REPLACE FUNCTION public.report_sst_summary(p_org_id uuid, p_from date, p_to date)
 RETURNS TABLE(tax_type_code text, tax_type_name text, direction text, taxable_amount numeric, tax_amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with sales as (
    select t.tax_type_code as code, rt.description as descr,
           -- The signs app.post_sales_document uses, and for the same
           -- reason: a credit note undoes a sale.
           case when d.doc_type in ('credit_note', 'refund_note')
                then -1 else 1 end as sign,
           l.line_subtotal, l.tax_amount
      from public.sales_document_lines l
      join public.sales_documents d on d.id = l.document_id
      join public.tax_codes t on t.id = l.tax_code_id
      join public.ref_tax_types rt on rt.code = t.tax_type_code
     where d.org_id = p_org_id
       and d.doc_type in ('invoice', 'credit_note', 'debit_note',
                          'refund_note')
       and d.status not in ('draft', 'void')
       and d.doc_date between p_from and p_to
  ),
  -- The tax a Malaysian restaurant charges on the ten per cent is
  -- service tax like any other, it is in the ledger at 2130, and until
  -- `0418` it was on the document's `tax_amount` with no tax code on it
  -- -- so a return built by tax type could not put it anywhere, and did
  -- not. Eighty sen in every hundred ringgit, undeclared, every taxable
  -- period.
  --
  -- Read from the header rather than the lines because that is where it
  -- is: the charge is not a line on the bill, it is a percentage of all
  -- of them.
  service_charge as (
    select t.tax_type_code as code, rt.description as descr,
           case when d.doc_type in ('credit_note', 'refund_note')
                then -1 else 1 end as sign,
           d.service_charge_amount as line_subtotal,
           d.service_charge_tax as tax_amount
      from public.sales_documents d
      join public.tax_codes t on t.id = d.service_charge_tax_code_id
      join public.ref_tax_types rt on rt.code = t.tax_type_code
     where d.org_id = p_org_id
       and d.doc_type in ('invoice', 'credit_note', 'debit_note',
                          'refund_note')
       and d.status not in ('draft', 'void')
       and d.doc_date between p_from and p_to
       -- A charge with no tax on it is still not nothing: the stall in
       -- `pos_service_charge.sql` adds ten per cent and is not
       -- registered, so the taxable value is right and the tax is zero.
       -- A document with no charge at all has nothing to declare.
       and coalesce(d.service_charge_amount, 0) <> 0
  ),
  purchases as (
    select t.tax_type_code as code, rt.description as descr,
           case when d.doc_type = 'purchase_credit_note'
                then -1 else 1 end as sign,
           l.line_subtotal, l.tax_amount
      from public.purchase_document_lines l
      join public.purchase_documents d on d.id = l.document_id
      join public.tax_codes t on t.id = l.tax_code_id
      join public.ref_tax_types rt on rt.code = t.tax_type_code
     where d.org_id = p_org_id
       and d.doc_type in ('bill', 'purchase_credit_note',
                          'purchase_debit_note')
       and d.status not in ('draft', 'void')
       and d.doc_date between p_from and p_to
  )
  select o.code, o.descr, 'output'::text,
         round(sum(o.sign * o.line_subtotal), 2),
         round(sum(o.sign * o.tax_amount), 2)
    from (select * from sales
          union all
          select * from service_charge) o
   where app.is_org_member(p_org_id)
   group by o.code, o.descr
  union all
  select p.code, p.descr, 'input'::text,
         round(sum(p.sign * p.line_subtotal), 2),
         round(sum(p.sign * p.tax_amount), 2)
    from purchases p
   where app.is_org_member(p_org_id)
   group by p.code, p.descr;
$function$

;

CREATE OR REPLACE FUNCTION app.refuse_posted_document_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  -- The figures and identifiers the journal was built from. Same list
  -- for both tables; a column absent from one is skipped rather than
  -- assumed.
  c_frozen constant text[] := array[
    'id', 'org_id', 'doc_type', 'doc_no', 'doc_date',
    'currency', 'exchange_rate', 'subtotal', 'discount_amount',
    'discount_percent', 'tax_amount', 'shipping_amount',
    'rounding_amount', 'total_amount', 'base_total_amount',
    'branch_id', 'matter_id', 'posted_at', 'posted_by', 'gl_entry_id',
    'service_charge_amount',
    -- 0418. Frozen for the reason the amount above is: these two are
    -- what the SST-02 return declares, and a figure that can be edited
    -- after posting is a return that stops agreeing with the ledger.
    'service_charge_tax', 'service_charge_tax_code_id'];
  -- The same question asked of the line: which of its columns did the
  -- journal read? Everything else on a line goes on moving, and some of
  -- it has to -- `app.refresh_sales_progress` and
  -- `app.refresh_purchase_progress` write the four progress counters on
  -- the lines of a posted document every time something is transferred
  -- from or received against it, and `source_line_id` is the link they
  -- follow.
  c_line_frozen constant text[] := array[
    'id', 'org_id', 'document_id', 'line_no', 'line_type', 'item_id',
    'description', 'quantity', 'base_quantity', 'uom_code', 'unit_price',
    'discount_amount', 'discount_percent', 'tax_code_id', 'tax_rate',
    'is_tax_inclusive', 'line_subtotal', 'tax_amount', 'line_total',
    'account_id', 'warehouse_id', 'cost_amount',
    'service_start', 'service_end', 'project_code', 'department_code'];
  v_is_line boolean := tg_table_name like '%_lines';
  v_entry   uuid;
  v_no      text;
  v_org     uuid;
  v_old     jsonb := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
  v_new     jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end;
  v_col     text;
begin
  if v_is_line then
    select d.gl_entry_id, d.doc_no, d.org_id into v_entry, v_no, v_org
      from public.sales_documents d
     where tg_table_name = 'sales_document_lines'
       and d.id = coalesce((v_new ->> 'document_id')::uuid,
                           (v_old ->> 'document_id')::uuid);
    if v_no is null then
      select d.gl_entry_id, d.doc_no, d.org_id into v_entry, v_no, v_org
        from public.purchase_documents d
       where tg_table_name = 'purchase_document_lines'
         and d.id = coalesce((v_new ->> 'document_id')::uuid,
                             (v_old ->> 'document_id')::uuid);
    end if;
  else
    v_entry := (coalesce(v_old, v_new) ->> 'gl_entry_id')::uuid;
    v_no    := coalesce(v_old, v_new) ->> 'doc_no';
    v_org   := nullif(coalesce(v_old, v_new) ->> 'org_id', '')::uuid;
  end if;

  -- Not posted: this is an ordinary document and none of this applies.
  -- A line whose document has already gone is in the same position.
  if v_entry is null then
    return coalesce(new, old);
  end if;

  -- The company is already gone and these rows are cascading away
  -- behind it. `app.write_audit_log` makes the same check for the same
  -- reason, and only on a delete: an insert or an update cannot name an
  -- organization that does not exist, because the row's own foreign key
  -- has already said so.
  if tg_op = 'DELETE'
     and v_org is not null
     and not exists (select 1 from public.organizations o where o.id = v_org)
  then
    return old;
  end if;

  if tg_op = 'DELETE' then
    raise exception
      '% is posted: its journal is in the ledger, which `0238` made '
      'append-only, and deleting it would leave that journal with '
      'nothing to explain it. Void the document instead, which reverses '
      'the journal, or raise a credit note against it.', v_no
      using errcode = '42501';
  end if;

  if tg_op = 'INSERT' then
    raise exception
      'A line cannot be added to %, which is posted. Its journal was '
      'built from the lines it had. Raise a credit note or a further '
      'document instead.', v_no
      using errcode = '42501';
  end if;

  if v_is_line then
    foreach v_col in array c_line_frozen loop
      if (v_new ? v_col)
         and (v_new -> v_col) is distinct from (v_old -> v_col) then
        raise exception
          'Line % of % cannot be changed: % is posted and its journal '
          'was built from this line''s % (% -> %). Void the document or '
          'raise a credit note.',
          coalesce(v_new ->> 'line_no', '?'), v_no, v_no, v_col,
          coalesce(v_old ->> v_col, 'null'), coalesce(v_new ->> v_col, 'null')
          using errcode = '42501';
      end if;
    end loop;
    return new;
  end if;

  foreach v_col in array c_frozen loop
    if (v_new ? v_col)
       and (v_new -> v_col) is distinct from (v_old -> v_col) then
      -- `gl_entry_id` is worth its own sentence: clearing it is not a
      -- disagreement with the ledger, it is a second posting waiting to
      -- happen. `post_sales_document_internal` refuses to post twice by
      -- reading this column and nothing else.
      if v_col = 'gl_entry_id' then
        raise exception
          '% is already posted as journal %. Clearing the link would '
          'let it be posted a second time, and the company would carry '
          'the sale twice. Void the document, which reverses the '
          'journal through `reverse_gl_entry`.',
          v_no, (v_old ->> 'gl_entry_id')
          using errcode = '42501';
      end if;
      raise exception
        '% is posted and % is one of the figures its journal was built '
        'from (% -> %). The ledger is append-only, so this would leave '
        'the document and the accounts disagreeing with no way to '
        'reconcile them. Void the document or raise a credit note.',
        v_no, v_col,
        coalesce(v_old ->> v_col, 'null'), coalesce(v_new ->> v_col, 'null')
        using errcode = '42501';
    end if;
  end loop;

  return new;
end $function$

;

