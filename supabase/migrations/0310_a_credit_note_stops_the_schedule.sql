-- ---------------------------------------------------------------------
-- A credit note stops the schedule it cancels
--
-- 0309 shipped a defect, and it is worse than "the schedule keeps
-- running". Checked against the schema before this was written:
--
--   an invoice of RM 1,200 deferred over a year, three months
--   recognised, then credited in full — and the credit note built a
--   *second* twelve-month schedule of its own, carrying a positive
--   amount. Deferred revenue went to −295.89 immediately, twenty-one
--   periods were left pending, and releasing them would have *added*
--   revenue for an invoice that had been cancelled.
--
-- Two separate mistakes, fixed separately.
--
-- ## A credit note does not defer
--
-- Deferral belongs to the document that creates the obligation. A
-- credit note is a reversal — it takes revenue back — so it posts to
-- the revenue account like any other credit note, and never opens a
-- schedule. `v_sign` already tells the posting path which kind of
-- document it is holding, so this is one condition.
--
-- ## And it stops the one it cancels
--
-- On posting, a credit note that names an `original_invoice_id` takes
-- back the unreleased part of that invoice's schedule and returns it to
-- revenue in a journal of its own.
--
-- The pair nets out correctly, which is the point:
--
--   credit note   Dr Revenue 1,200.00   Cr Receivable 1,200.00
--   cancellation  Dr Deferred  904.11   Cr Revenue      904.11
--                 ------------------------------------------
--   revenue moves by −295.89, exactly what had been recognised;
--   deferred revenue clears to nil; the receivable falls by 1,200.00.
--
-- Two journals rather than one split line, because that keeps the
-- credit note itself ordinary — it posts the way every other credit
-- note posts — and puts the deferral unwind where somebody reading the
-- ledger can see it named.
--
-- ## Partly credited
--
-- Scaled by value: a credit note for half the invoice takes half of
-- what is left of each unreleased period. The cancelled figure is the
-- sum of the individual reductions rather than a percentage of the
-- total, so the journal balances to the sen by construction rather
-- than by rounding luck.
--
-- ## What is kept
--
-- `amount` is never rewritten. The cancellation is recorded beside it,
-- so "the schedule sums to the invoice" stays true for the life of the
-- row and the reduction is visible rather than inferred. What can still
-- be released is `amount - cancelled_amount`.
-- ---------------------------------------------------------------------

alter table public.revenue_schedule_periods
  add column if not exists cancelled_amount numeric(18, 2) not null default 0,
  add column if not exists cancelled_by_id uuid references public.sales_documents (id);

do $$ begin
  if not exists (select 1 from pg_constraint
                  where conname = 'revenue_schedule_cancel_ck') then
    alter table public.revenue_schedule_periods
      add constraint revenue_schedule_cancel_ck
      check (cancelled_amount >= 0 and cancelled_amount <= amount);
  end if;
end $$;

comment on column public.revenue_schedule_periods.cancelled_amount is
  'How much of this period a credit note took back. `amount` is left as '
  'first scheduled so it still sums to the invoice; what remains to be '
  'released is amount - cancelled_amount.';

-- ---------------------------------------------------------------------
-- Taking back what has not been earned
-- ---------------------------------------------------------------------
create or replace function app.cancel_revenue_schedule(p_credit_note_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_cn      public.sales_documents;
  v_inv     public.sales_documents;
  v_ratio   numeric;
  v_row     record;
  v_take    numeric(18, 2);
  v_total   numeric(18, 2) := 0;
  v_credits jsonb := '[]'::jsonb;
  v_defer   uuid;
begin
  select * into v_cn from public.sales_documents where id = p_credit_note_id;
  if v_cn.original_invoice_id is null then
    return 0;
  end if;

  select * into v_inv from public.sales_documents
   where id = v_cn.original_invoice_id;
  if v_inv.id is null or coalesce(v_inv.subtotal, 0) = 0 then
    return 0;
  end if;

  -- By value, and never more than the whole. A credit note larger than
  -- the invoice cancels it and no more; the excess is a matter for the
  -- receivable, not for the schedule.
  v_ratio := least(coalesce(v_cn.subtotal, 0) / v_inv.subtotal, 1);
  if v_ratio <= 0 then
    return 0;
  end if;

  for v_row in
    select id, revenue_account_id, amount - cancelled_amount as remaining
      from public.revenue_schedule_periods
     where document_id = v_inv.id
       and gl_entry_id is null
       and amount > cancelled_amount
     order by period_end
  loop
    v_take := round(v_row.remaining * v_ratio, 2);
    if v_take <= 0 then
      continue;
    end if;

    update public.revenue_schedule_periods
       set cancelled_amount = cancelled_amount + v_take,
           cancelled_by_id  = p_credit_note_id
     where id = v_row.id;

    v_total := v_total + v_take;
    v_credits := v_credits || jsonb_build_object(
      'account_id', v_row.revenue_account_id,
      'description', 'Deferred revenue cancelled',
      'debit', 0, 'credit', v_take);
  end loop;

  if v_total = 0 then
    return 0;
  end if;

  -- Dr the liability, Cr the revenue accounts the periods would have
  -- credited. Summed from the individual reductions, so it balances by
  -- construction.
  v_defer := app.deferred_revenue_account(v_cn.org_id);
  perform public.create_gl_entry(
    v_cn.org_id,
    v_cn.doc_date,
    'revenue_recognition'::app.journal_source,
    jsonb_build_array(jsonb_build_object(
      'account_id', v_defer,
      'description', 'Deferred revenue cancelled by ' || coalesce(v_cn.doc_no, ''),
      'debit', v_total, 'credit', 0)) || v_credits,
    'Deferred revenue cancelled by ' || coalesce(v_cn.doc_no, ''),
    'revenue_schedule_periods', p_credit_note_id,
    v_cn.doc_no, app.base_currency(v_cn.org_id), 1);

  return v_total;
end;
$$;

revoke all on function app.cancel_revenue_schedule(uuid)
  from public, anon, authenticated;

create or replace function app.post_sales_document_internal(p_id uuid)
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
        'department_code', v_line.department_code
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
$$;

create or replace function public.recognise_revenue(
  p_org_id uuid, p_upto date default null)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_upto  date := coalesce(p_upto, (now() at time zone 'Asia/Kuala_Lumpur')::date);
  v_row   record;
  v_defer uuid;
  v_entry uuid;
  v_n     integer := 0;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to recognise revenue'
      using errcode = '42501';
  end if;

  v_defer := app.deferred_revenue_account(p_org_id);

  -- One entry per period end, carrying every line that matures on it,
  -- rather than one per line: a monthly release is one journal in the
  -- ledger, which is what somebody reading it expects to see.
  for v_row in
    select period_end,
           jsonb_agg(jsonb_build_object(
             'account_id', revenue_account_id,
             'description', 'Revenue recognised',
             'debit', 0, 'credit', amount - cancelled_amount)
             order by revenue_account_id) as credits,
           sum(amount - cancelled_amount) as total,
           array_agg(id) as ids
      from public.revenue_schedule_periods
     where org_id = p_org_id
       and gl_entry_id is null
       -- 0310. A period the credit note took back in full has nothing
       -- left to release, and must not produce a zero-value line.
       and amount > cancelled_amount
       and period_end <= v_upto
     group by period_end
     order by period_end
  loop
    if v_row.total = 0 then
      continue;
    end if;

    v_entry := public.create_gl_entry(
      p_org_id,
      v_row.period_end,
      'revenue_recognition'::app.journal_source,
      jsonb_build_array(jsonb_build_object(
        'account_id', v_defer,
        'description', 'Deferred revenue released',
        'debit', v_row.total, 'credit', 0)) || v_row.credits,
      'Revenue recognised to ' || to_char(v_row.period_end, 'DD Mon YYYY'),
      'revenue_schedule_periods', null, null,
      -- Already in the ledger's own currency: the schedule was fixed at
      -- the document's rate when it was built, and a non-monetary
      -- liability is not retranslated afterwards.
      app.base_currency(p_org_id), 1);

    update public.revenue_schedule_periods
       set gl_entry_id = v_entry, recognised_on = v_row.period_end
     where id = any (v_row.ids);
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;