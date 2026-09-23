-- =====================================================================
-- iAkauntan :: 0691 the matter a bill and an invoice belong to
--
-- `0687` put `matter_id` on `gl_lines`, `0688` made every posting path
-- carry it, and `0690` wrote the first entries that use it. A journal
-- can name a matter. NOTHING A FIRM ACTUALLY BILLS OR BUYS CAN.
--
-- That is most of a law firm's ledger. A fee note is a sales invoice, a
-- searches fee from a land office is a purchase bill, and both reach
-- `gl_lines` through the two functions below -- which build their
-- entries from `sales_document_lines` and `purchase_document_lines`,
-- neither of which has ever had a column to put a matter in.
--
-- So `report_matter_ledger` and `report_matter_trial_balance`, both
-- added six migrations ago, could report on a matter's journals and on
-- its client money and on nothing else. A matter's own FEES were
-- missing from its own ledger.
--
-- ---------------------------------------------------------------------
-- Per line, on both sides, like the other two dimensions
--
-- `project_code` and `department_code` are columns on the line tables
-- and the editors set them from the document. The matter is added in
-- exactly that shape, for the reason `0687` gave: one bill can carry
-- disbursements for two files, and a firm that bills a client for four
-- matters on one fee note is ordinary rather than exotic.
--
-- Nothing below is invented. Both functions were pulled out of the
-- applied database -- `post_sales_document_internal` as `0410` left it,
-- `post_purchase_document_internal` as `0609` left it -- and restated
-- with one key added to one `jsonb_build_object`. Everything else is
-- byte for byte what is already live, which is the only way to be sure
-- a restatement does not quietly revert something.
--
-- ---------------------------------------------------------------------
-- The revenue and cost legs, and nothing else
--
-- The same line `0639` drew for the department, for the same reason.
-- The receivable, the payable, the output and input tax, the rounding
-- and the header discount carry no matter.
--
-- A receivable is not a matter COST or a matter FEE -- it is what the
-- client owes the firm, and 1210 belongs to the client rather than to
-- the file. Put the matter on it and every matter's trial balance
-- reports its own debtor twice: once as the fee it earned and once as
-- the money it is owed for that fee. The tax legs are the firm's
-- liability to the Customs Department and are not the client's at all.
--
-- Cost of sales is left out for a different reason: it is ONE entry
-- summed across every line of the document, so there is no single
-- matter it could carry. A firm that needs stock costed per matter is a
-- firm that should be raising the cost as a disbursement.
--
-- ---------------------------------------------------------------------
-- Where a matter still cannot reach, and it is not a new gap
--
-- A line with a service period defers, and `recognise_revenue` releases
-- it month by month from `revenue_schedule_periods`. That release
-- carries NO dimension at all -- not the project, not the department,
-- and now not the matter. It is the pre-existing shape rather than
-- something this migration breaks, and it is written down here because
-- a deferred fee is exactly the kind of thing a retainer produces.
-- Fixing it means putting the dimensions on the schedule rows, which is
-- its own migration and its own assertions.
-- =====================================================================

alter table public.sales_document_lines
  add column if not exists matter_id uuid;

alter table public.purchase_document_lines
  add column if not exists matter_id uuid;

-- The composite key, and the column named on the delete action. A bare
-- `on delete set null` on `(org_id, matter_id)` nulls `org_id` too and
-- `org_id` is NOT NULL, so deleting a matter would raise rather than
-- detach the line. `tenant_foreign_keys.sql` refuses the bare form;
-- `0681` and `0687` both hit it.
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'sales_document_lines_matter_same_org') then
    alter table public.sales_document_lines
      add constraint sales_document_lines_matter_same_org
      foreign key (org_id, matter_id)
      references public.matters (org_id, id)
      on delete set null (matter_id);
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'purchase_document_lines_matter_same_org') then
    alter table public.purchase_document_lines
      add constraint purchase_document_lines_matter_same_org
      foreign key (org_id, matter_id)
      references public.matters (org_id, id)
      on delete set null (matter_id);
  end if;
end $$;

comment on column public.sales_document_lines.matter_id is
  'Which matter this invoice line is billed for, or null for work that '
  'belongs to no file. Nullable, like the project and the department '
  'beside it: most companies are not law firms and a mandatory matter '
  'would be a matter people invent. Reaches `gl_lines.matter_id` '
  'through `app.post_sales_document_internal`. 0691.';

comment on column public.purchase_document_lines.matter_id is
  'Which matter this bill line was bought for -- a search fee, a '
  'stamping, counsel''s fee -- or null for the firm''s own costs. '
  'Reaches `gl_lines.matter_id` through '
  '`app.post_purchase_document_internal`. 0691.';

-- Every read filters by matter within an org, the same shape as
-- `gl_lines_matter_idx`.
create index if not exists sales_document_lines_matter_idx
  on public.sales_document_lines (org_id, matter_id)
  where matter_id is not null;

create index if not exists purchase_document_lines_matter_idx
  on public.purchase_document_lines (org_id, matter_id)
  where matter_id is not null;

-- ---------------------------------------------------------------------
-- What `0021` already had, and nothing read
--
-- `sales_documents.matter_id` has existed since the legal module was
-- written, and `bill_matter_time` sets it on every fee note raised off
-- a matter's time entries. It reached no ledger line, because the
-- posting path reads its dimensions off the LINE. So the one document
-- in the product that always knew its matter was also one whose journal
-- never mentioned it.
--
-- The sales path below therefore coalesces the line over the document,
-- which is the order `post_expense` has used for the project and the
-- department since `0639`. `purchase_documents` has no such column and
-- is left alone.
--
-- ---------------------------------------------------------------------
-- And a posted document's matter stops moving
--
-- `app.refuse_posted_document_change` freezes every line column the
-- journal was built from, and `posted_document_is_frozen.sql` fails on
-- any column it has no opinion about -- which is how this migration was
-- caught adding one. `matter_id` is now read when the entry is built,
-- so it belongs in the frozen list: changing it after posting would
-- leave the ledger saying one file and the invoice saying another, with
-- nothing to reconcile them.
--
-- Restated from `0418`, where the applied version lives.
-- ---------------------------------------------------------------------

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

create or replace function app.post_purchase_document_internal(p_id uuid)
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
    'service_start', 'service_end', 'project_code', 'department_code',
    'matter_id'];
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
end $function$;
