-- ---------------------------------------------------------------------
-- Revenue earned, rather than revenue invoiced
--
-- An invoice raised in January for a year of support is not January's
-- revenue. Under MFRS 15 it is earned as the service is delivered, and
-- until then the money is a liability: the company owes eleven more
-- months of work. iAkauntan has had no way to say that. `0097` gives
-- recurring documents, which raise an invoice on a schedule — that is
-- billing, and billing is not recognition.
--
-- The argument reaches well past software subscriptions. Maintenance
-- contracts, annual licences, retainers and service plans are all sold
-- by Malaysian SMEs and all span periods.
--
-- ## How a line is deferred
--
-- By carrying a service period. `service_start` and `service_end` on
-- the line, both or neither. A line without them is exactly what it has
-- always been and posts to revenue on the day — which is every line
-- this system has ever written, so nothing already asserted moves.
--
-- A line with them credits `2127 Deferred Revenue` instead, and gets a
-- schedule that releases it.
--
-- ## The arithmetic, and the trap in it
--
-- Straight-line across the service period, prorated **by days**. A
-- contract starting on the 12th earns eighteen days of that month, not
-- a whole one and not none.
--
-- The trap is rounding. Twelve months of RM 1,000.00 is not twelve
-- times RM 83.33, and a schedule that does not add back to the invoice
-- leaves deferred revenue holding sen forever — a liability nobody can
-- clear and an auditor's question.
--
-- Rounding each period on its own days and giving the last one the
-- remainder fixes the total and breaks something else: seven sen over a
-- year rounds up to a sen in each of eleven months, and the twelfth is
-- handed minus four. That was written first and the tests caught it.
--
-- Each period is therefore the cumulative amount earned to its end,
-- less everything allocated before it. The cumulative figure only ever
-- rises, so no period is negative, and the last one's cumulative figure
-- is the whole amount, so the schedule adds back exactly. Asserted over
-- a range of awkward amounts and lengths in `revenue_recognition.sql`.
--
-- ## What is recognised, and in what currency
--
-- `line_subtotal`, which is net of tax: tax is not revenue. Converted
-- at the document's own rate and fixed there.
--
-- Fixed deliberately. Deferred revenue is a *non-monetary* liability
-- under MFRS 121 — it is an obligation to deliver a service, not to pay
-- an amount — so it is not retranslated at closing rates. Nothing had
-- to be done to arrange that here: `fx_revaluation_preview` works from
-- open sales and purchase documents rather than from account balances,
-- checked rather than assumed, so it never sees this account.
--
-- ## Recognising it
--
-- `public.recognise_revenue(org, up_to)` posts one journal per period
-- that has come due and has not been posted — Dr Deferred Revenue, Cr
-- the revenue account the line would have used. It goes through
-- `create_gl_entry`, so fiscal period control applies exactly as it
-- does to anything else: a closed month refuses the posting rather than
-- quietly writing into it.
--
-- Running it twice does nothing the second time. Each period row keeps
-- the `gl_entry_id` that recognised it, which is the same state guard
-- `post_document` uses and the reason this needs no idempotency key.
-- ---------------------------------------------------------------------

-- The ledger names its own sources, and a release is not a manual
-- journal. Added before anything uses it; the value is only referenced
-- inside a function body, which is not evaluated at definition time.
alter type app.journal_source add value if not exists 'revenue_recognition';

alter table public.sales_document_lines
  add column if not exists service_start date,
  add column if not exists service_end   date;

do $$ begin
  if not exists (select 1 from pg_constraint
                  where conname = 'sales_document_lines_service_period_ck') then
    alter table public.sales_document_lines
      add constraint sales_document_lines_service_period_ck check (
        (service_start is null and service_end is null)
        or (service_start is not null and service_end is not null
            and service_end >= service_start));
  end if;
end $$;

comment on column public.sales_document_lines.service_start is
  'First day of the period this line is earned over. Null means earned '
  'on the invoice date, which is the default and the behaviour every '
  'line had before 0309.';

-- ---------------------------------------------------------------------
-- The liability account, made when it is first needed
--
-- Modelled on `app.deposit_account`: created lazily rather than added
-- to the seeded chart, so the hundreds of existing organizations get it
-- the first time they defer something and not before.
-- ---------------------------------------------------------------------
create or replace function app.deferred_revenue_account(p_org_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid; v_parent uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '2127';
  if v_id is not null then
    return v_id;
  end if;

  select id into v_parent from public.accounts
   where org_id = p_org_id and code = '2100';

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, parent_id,
     is_group, is_system, is_active)
  values (p_org_id, '2127', 'Deferred Revenue', 'liability',
          'current_liability', v_parent, false, true, true)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- The schedule
-- ---------------------------------------------------------------------
create table if not exists public.revenue_schedule_periods (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations (id) on delete cascade,
  document_id  uuid not null references public.sales_documents (id) on delete cascade,
  line_id      uuid not null references public.sales_document_lines (id) on delete cascade,
  -- The account the line would have credited had it been earned at
  -- once. Held here so a later change to the item's mapping cannot
  -- silently re-point revenue already sitting in the liability.
  revenue_account_id uuid not null references public.accounts (id),
  period_end   date not null,
  amount       numeric(18, 2) not null,
  gl_entry_id  uuid references public.gl_entries (id),
  recognised_on date,
  created_at   timestamptz not null default now(),
  unique (line_id, period_end)
);

create index if not exists revenue_schedule_due_idx
  on public.revenue_schedule_periods (org_id, period_end)
  where gl_entry_id is null;

comment on table public.revenue_schedule_periods is
  'What each deferred invoice line earns in each month, and the journal '
  'that released it. Sums exactly to the line net amount: 0309 gives '
  'the last period the rounding remainder.';

alter table public.revenue_schedule_periods enable row level security;

drop policy if exists revenue_schedule_read on public.revenue_schedule_periods;
create policy revenue_schedule_read on public.revenue_schedule_periods
  for select to authenticated using (app.is_org_member(org_id));

-- Written only by the posting path and the recognition run, both
-- SECURITY DEFINER. Supabase's defaults would otherwise hand the table
-- to the client, which 0299 exists to remember.
revoke insert, update, delete on public.revenue_schedule_periods
  from anon, authenticated;
grant select on public.revenue_schedule_periods to authenticated;

-- ---------------------------------------------------------------------
-- Building it
--
-- One row per calendar month the service period touches. `p_rate` is
-- the document's own rate, passed in rather than looked up again so the
-- schedule cannot disagree with the entry that created it.
-- ---------------------------------------------------------------------
create or replace function app.build_revenue_schedule(
  p_document_id uuid, p_rate numeric)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_doc    public.sales_documents;
  v_line   record;
  v_total  numeric(18, 2);
  v_days   integer;
  v_month  date;
  v_from   date;
  v_to     date;
  v_amt    numeric(18, 2);
  v_run    numeric(18, 2);
  v_last   date;
  v_rev    uuid;
  v_n      integer := 0;
begin
  select * into v_doc from public.sales_documents where id = p_document_id;

  for v_line in
    select l.*, i.sales_account_id
      from public.sales_document_lines l
      left join public.items i on i.id = l.item_id
     where l.document_id = p_document_id
       and l.line_type = 'item'
       and l.service_start is not null
     order by l.line_no
  loop
    -- Net of tax, in the ledger's currency, and fixed at this rate.
    v_total := round(v_line.line_subtotal * p_rate, 2);
    v_days  := (v_line.service_end - v_line.service_start) + 1;
    if v_total = 0 or v_days <= 0 then
      continue;
    end if;

    v_rev := app.resolve_account(
      v_doc.org_id, v_line.account_id, v_line.item_id, 'sales_account_id', '4100');

    -- Allocated on the running total, not period by period.
    --
    -- The obvious way — round each period on its own days and give the
    -- last one whatever is left — is wrong, and wrong in a way that
    -- only shows on small amounts. Seven sen over a year rounds up to a
    -- sen in each of eleven months, which is eleven sen, and the last
    -- period is then handed *minus four*. A negative month of revenue
    -- is not a rounding artefact anybody should have to explain.
    --
    -- So each period is the difference between the cumulative amount
    -- earned to its end and everything allocated before it. The
    -- cumulative figure is non-decreasing, so no period can be
    -- negative; and the final period's cumulative figure is the whole
    -- amount, so the schedule adds back to the invoice exactly. Both
    -- are asserted in `revenue_recognition.sql` over amounts and
    -- lengths chosen to break the naive version.
    v_last := (date_trunc('month', v_line.service_end))::date;
    v_run  := 0;
    v_month := (date_trunc('month', v_line.service_start))::date;

    while v_month <= v_last loop
      v_from := greatest(v_month, v_line.service_start);
      v_to   := least((v_month + interval '1 month' - interval '1 day')::date,
                      v_line.service_end);

      -- Days from the start of the service period to the end of this
      -- month, over the whole period.
      v_amt := round(v_total * ((v_to - v_line.service_start) + 1)::numeric
                     / v_days, 2) - v_run;
      v_run := v_run + v_amt;

      insert into public.revenue_schedule_periods
        (org_id, document_id, line_id, revenue_account_id, period_end, amount)
      values (v_doc.org_id, p_document_id, v_line.id, v_rev,
              least((v_month + interval '1 month' - interval '1 day')::date,
                    v_line.service_end),
              v_amt)
      on conflict (line_id, period_end) do nothing;
      v_n := v_n + 1;

      v_month := (v_month + interval '1 month')::date;
    end loop;
  end loop;

  return v_n;
end;
$$;
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
    if v_line.service_start is not null then
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

  return v_entry_id;
end;
$$;
-- ---------------------------------------------------------------------
-- Releasing it
--
-- One journal per period that has come due and has not been posted.
-- Through `create_gl_entry`, so period control, the balance check and
-- the audit trail all apply as they do to any other posting.
-- ---------------------------------------------------------------------
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
             'debit', 0, 'credit', amount)
             order by revenue_account_id) as credits,
           sum(amount) as total,
           array_agg(id) as ids
      from public.revenue_schedule_periods
     where org_id = p_org_id
       and gl_entry_id is null
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

comment on function public.recognise_revenue(uuid, date) is
  'Release deferred revenue that has been earned up to a date, one '
  'journal per period. Safe to run repeatedly: a period already '
  'carrying a gl_entry_id is skipped, the same guard post_document '
  'uses.';

grant execute on function public.recognise_revenue(uuid, date) to authenticated;
revoke all on function app.build_revenue_schedule(uuid, numeric)
  from public, anon, authenticated;
revoke all on function app.deferred_revenue_account(uuid)
  from public, anon, authenticated;
