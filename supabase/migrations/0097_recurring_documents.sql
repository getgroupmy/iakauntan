-- =====================================================================
-- iAkauntan :: 0097 recurring invoices and bills
--
-- `recurring_journals` has run since 0004 and is the only thing in the
-- system that repeats. A monthly retainer invoice is typed by hand
-- twelve times a year next to a scheduler that was already awake.
--
-- Three decisions worth stating, because each had a plausible
-- alternative:
--
-- **The schedule owns a snapshot, not a pointer.** A recurring invoice
-- could have pointed at a template document and copied it on each run.
-- That template would have been a draft invoice sitting in the invoice
-- list with a Post button next to it, and editing or voiding it would
-- have changed next month's billing silently. Instead
-- `create_recurring_document` copies an existing document into the
-- schedule's own `template` and the two stop being connected. Changing
-- what gets billed is `update_recurring_template`, which is a decision
-- somebody makes rather than a side effect of tidying up a document.
--
-- **Lines are snapshotted whole.** `to_jsonb(line)` less the columns
-- that belong to a particular document, restored with
-- `jsonb_populate_record`. Enumerating the columns by hand would mean a
-- line column added in some later migration silently stops being
-- carried, and the failure would be a wrong invoice rather than an
-- error.
--
-- **The scheduler posts through the same code a person does.** A run at
-- three in the morning has no `auth.uid()`, so `app.can_post` says no
-- to it. Rather than let the runner write journals itself and skip the
-- fiscal period, balance and credit-limit rules with them, the bodies
-- of `post_sales_document` and `post_purchase_document` move down into
-- `app.*_internal` and the public functions become the permission check
-- plus a call — the same split 0056 made for `create_gl_entry`. One
-- implementation, two doors, and the internal door is closed to every
-- API role.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. A posting path the scheduler can use
--
-- Both bodies below are 0013's, moved rather than rewritten: the
-- permission check is gone from the top and the two calls that carry
-- their own check — `create_gl_entry` and `next_document_number` —
-- point at the internal pair 0056 created for exactly this. Nothing
-- else about how a document posts has changed.
-- ---------------------------------------------------------------------
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

create or replace function app.post_purchase_document_internal(p_id uuid)
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
           app.next_document_number_internal(v_doc.org_id, 'stock_movement'),
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

-- The public pair keep their names, their signatures and their errors,
-- and become the check plus the call.
create or replace function public.post_sales_document(p_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid;
begin
  select org_id into v_org from public.sales_documents where id = p_id;
  if v_org is null then
    raise exception 'Sales document % not found', p_id;
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  return app.post_sales_document_internal(p_id);
end; $$;

create or replace function public.post_purchase_document(p_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid;
begin
  select org_id into v_org from public.purchase_documents where id = p_id;
  if v_org is null then
    raise exception 'Purchase document % not found', p_id;
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  return app.post_purchase_document_internal(p_id);
end; $$;

-- Reaching the internal pair from an API key would be posting with the
-- permission check taken off.
revoke all on function app.post_sales_document_internal(uuid)
  from public, anon, authenticated;
revoke all on function app.post_purchase_document_internal(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Queueing a document email from a job
--
-- `public.email_document` checks membership, which the scheduler does
-- not have. `app.queue_overdue_reminders` already worked around that
-- inline; this lifts that body out so the reminder run and the
-- recurring run cannot drift into sending differently shaped mail.
--
-- Returns null rather than raising when there is nobody to send to, or
-- when the organization has not switched email on. Neither is an error
-- worth stopping a nightly run for.
-- ---------------------------------------------------------------------
create or replace function app.queue_document_email(
  p_document_id uuid, p_code text, p_dedupe_key text)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_doc public.sales_documents;
  v_settings public.email_settings;
  t record;
  v_to text;
  v_link text;
  v_vars jsonb;
  v_id uuid;
begin
  select * into v_doc from public.sales_documents where id = p_document_id;
  if not found then return null; end if;

  select * into v_settings from public.email_settings where org_id = v_doc.org_id;
  if not found or not v_settings.is_enabled then return null; end if;

  v_to := coalesce(
    (select cp.email::text from public.contact_persons cp
      where cp.contact_id = v_doc.contact_id and cp.is_primary limit 1),
    (select c.email::text from public.contacts c where c.id = v_doc.contact_id));
  if v_to is null then return null; end if;

  select * into t from app.email_template(v_doc.org_id, p_code);
  v_link := app.share_url(app.issue_share_token(p_document_id, 45, v_to));
  v_vars := app.document_email_vars(p_document_id, v_link);

  begin
    insert into public.email_outbox
      (org_id, to_email, subject, body, reply_to, from_name,
       template_code, document_id, dedupe_key)
    values (
      v_doc.org_id, v_to,
      app.render_email(t.subject, v_vars),
      app.render_email(t.body, v_vars),
      v_settings.reply_to, v_settings.from_name, p_code, p_document_id,
      p_dedupe_key)
    returning id into v_id;
  exception when unique_violation then
    -- Already queued under this key. Nothing to do and nothing wrong.
    return null;
  end;

  return v_id;
end; $$;

revoke all on function app.queue_document_email(uuid, text, text)
  from public, anon, authenticated;

-- The reminder run, now going through the helper rather than round it.
create or replace function app.queue_overdue_reminders(p_on date default current_date)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r record;
  v_n integer := 0;
begin
  for r in
    select d.id, d.org_id, (p_on - d.due_date) as days_over
      from public.sales_documents d
      join public.email_settings s on s.org_id = d.org_id
      join public.organizations o on o.id = d.org_id
     where s.is_enabled
       and array_length(s.reminder_days, 1) is not null
       and coalesce(o.status, 'active') = 'active'
       and d.deleted_at is null
       and d.doc_type = 'invoice'
       and d.status in ('posted', 'partial')
       and d.balance_amount > 0
       and d.due_date is not null
       and d.balance_amount >= s.reminder_min_amount
       and (p_on - d.due_date) = any (s.reminder_days)
  loop
    if app.queue_document_email(
         r.id, 'invoice_reminder',
         'reminder:' || r.id::text || ':' || r.days_over::text) is not null then
      v_n := v_n + 1;
    end if;
  end loop;

  return v_n;
end; $$;

revoke all on function app.queue_overdue_reminders(date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. The schedule
--
-- `end_date` and `max_occurrences` are Akaunting's "limit by" in the
-- two forms anybody uses. Both null means it runs until somebody turns
-- it off, which is what a retainer is.
-- ---------------------------------------------------------------------
create table if not exists public.recurring_documents (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations (id) on delete cascade,
  name           text not null,

  -- 'sales' raises an invoice, 'purchase' raises a bill. Nothing else
  -- repeats: a quotation or a purchase order that arrived on a schedule
  -- would be a document nobody asked for.
  kind           text not null check (kind in ('sales', 'purchase')),
  contact_id     uuid not null references public.contacts (id) on delete restrict,

  -- The snapshot: {"header": {...}, "lines": [...]}.
  template       jsonb not null,

  -- Days from the document date to the due date. Taken from the gap on
  -- the document this was copied from, so a schedule made from a
  -- thirty-day invoice keeps thirty days.
  payment_terms_days integer not null default 30
                     check (payment_terms_days >= 0),

  frequency      text not null
                 check (frequency in ('daily','weekly','monthly','quarterly','yearly')),
  interval_count integer not null default 1 check (interval_count >= 1),
  start_date     date not null,
  end_date       date,
  max_occurrences integer check (max_occurrences is null or max_occurrences > 0),
  occurrences    integer not null default 0,

  next_run_date  date not null,
  last_run_date  date,
  last_document_id uuid,

  -- Off by default, both of them. A schedule that posts and emails from
  -- the day it is created is a schedule somebody has to apologise for.
  auto_post      boolean not null default false,
  auto_email     boolean not null default false,
  is_active      boolean not null default true,

  last_error     text,
  last_error_at  timestamptz,

  created_by     uuid references auth.users (id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists recurring_documents_due
  on public.recurring_documents (org_id, next_run_date) where is_active;

drop trigger if exists set_updated_at on public.recurring_documents;
create trigger set_updated_at before update on public.recurring_documents
  for each row execute function app.set_updated_at();

alter table public.recurring_documents enable row level security;

drop policy if exists recurring_documents_select on public.recurring_documents;
create policy recurring_documents_select on public.recurring_documents
  for select to authenticated using (app.is_org_member(org_id));
drop policy if exists recurring_documents_write on public.recurring_documents;
create policy recurring_documents_write on public.recurring_documents
  for all to authenticated
  using (app.can_post(org_id)) with check (app.can_post(org_id));

-- Supabase grants every table privilege on a new public table to `anon`
-- and `authenticated` by default, which leaves RLS as the only barrier.
-- A schedule carries a customer, prices and terms.
revoke all on public.recurring_documents from anon;
revoke all on public.recurring_documents from authenticated;
grant select, insert, update, delete on public.recurring_documents to authenticated;

-- ---------------------------------------------------------------------
-- 4. Making one from a document that already exists
--
-- The whole point of copying rather than composing: everything an
-- invoice can express — items, tax codes, price levels, dimensions,
-- delivery addresses — is already expressible, and a second editor
-- would only be able to express some of it.
-- ---------------------------------------------------------------------
create or replace function app.snapshot_document(p_document_id uuid, p_kind text)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_header jsonb;
  v_lines jsonb;
begin
  if p_kind = 'sales' then
    select jsonb_build_object(
             'contact_id', d.contact_id,
             'contact_person_id', d.contact_person_id,
             'shipping_address_id', d.shipping_address_id,
             'subject', d.subject,
             'reference', d.reference,
             'currency', d.currency,
             'payment_term_id', d.payment_term_id,
             'discount_percent', d.discount_percent,
             'discount_amount', d.discount_amount,
             'shipping_amount', d.shipping_amount,
             'salesperson_id', d.salesperson_id,
             'notes', d.notes,
             'terms_conditions', d.terms_conditions,
             'custom_fields', d.custom_fields)
      into v_header
      from public.sales_documents d where d.id = p_document_id;

    -- Everything on the line except what belongs to the document it
    -- came off. Listing what to keep instead would quietly drop any
    -- column added after today.
    select jsonb_agg(to_jsonb(l)
             - 'id' - 'org_id' - 'document_id' - 'created_at' - 'updated_at'
             - 'quantity_fulfilled' - 'quantity_invoiced' - 'cost_amount'
             order by l.line_no)
      into v_lines
      from public.sales_document_lines l where l.document_id = p_document_id;
  else
    select jsonb_build_object(
             'contact_id', d.contact_id,
             'contact_person_id', d.contact_person_id,
             'reference', d.reference,
             'currency', d.currency,
             'payment_term_id', d.payment_term_id,
             'discount_percent', d.discount_percent,
             'discount_amount', d.discount_amount,
             'shipping_amount', d.shipping_amount,
             'requires_self_billed', d.requires_self_billed,
             'notes', d.notes,
             'custom_fields', d.custom_fields)
      into v_header
      from public.purchase_documents d where d.id = p_document_id;

    select jsonb_agg(to_jsonb(l)
             - 'id' - 'org_id' - 'document_id' - 'created_at' - 'updated_at'
             - 'quantity_fulfilled' - 'quantity_invoiced' - 'cost_amount'
             order by l.line_no)
      into v_lines
      from public.purchase_document_lines l where l.document_id = p_document_id;
  end if;

  if v_header is null then
    raise exception 'Document % not found', p_document_id using errcode = 'P0002';
  end if;
  if v_lines is null then
    raise exception 'A schedule needs a document with lines on it'
      using errcode = '22023';
  end if;

  return jsonb_build_object('header', v_header, 'lines', v_lines);
end; $$;

revoke all on function app.snapshot_document(uuid, text) from public, anon, authenticated;

create or replace function public.create_recurring_document(
  p_document_id uuid,
  p_name text,
  p_frequency text,
  p_start_date date,
  p_interval_count integer default 1,
  p_end_date date default null,
  p_max_occurrences integer default null,
  p_auto_post boolean default false,
  p_auto_email boolean default false)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_kind text;
  v_org uuid;
  v_contact uuid;
  v_doc_date date;
  v_due date;
  v_id uuid;
begin
  select 'sales', d.org_id, d.contact_id, d.doc_date, d.due_date
    into v_kind, v_org, v_contact, v_doc_date, v_due
    from public.sales_documents d
   where d.id = p_document_id and d.doc_type = 'invoice' and d.deleted_at is null;

  if v_kind is null then
    select 'purchase', d.org_id, d.contact_id, d.doc_date, d.due_date
      into v_kind, v_org, v_contact, v_doc_date, v_due
      from public.purchase_documents d
     where d.id = p_document_id and d.doc_type = 'bill' and d.deleted_at is null;
  end if;

  if v_kind is null then
    raise exception 'Only an invoice or a bill can be made recurring'
      using errcode = '22023';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'A schedule needs a name' using errcode = '22023';
  end if;
  if p_end_date is not null and p_end_date < p_start_date then
    raise exception 'The end date is before the start date' using errcode = '22023';
  end if;

  insert into public.recurring_documents
    (org_id, name, kind, contact_id, template, payment_terms_days,
     frequency, interval_count, start_date, end_date, max_occurrences,
     next_run_date, auto_post, auto_email, created_by)
  values (
    v_org, trim(p_name), v_kind, v_contact,
    app.snapshot_document(p_document_id, v_kind),
    -- The gap this customer was given last time, rather than a number
    -- somebody has to remember to type.
    greatest(coalesce(v_due - v_doc_date, 30), 0),
    p_frequency, greatest(coalesce(p_interval_count, 1), 1),
    p_start_date, p_end_date, p_max_occurrences,
    p_start_date, coalesce(p_auto_post, false), coalesce(p_auto_email, false),
    auth.uid())
  returning id into v_id;

  return v_id;
end; $$;

-- Changing what gets billed, from a document rather than a form: last
-- month's invoice with the new price on it is the natural thing to
-- point at.
create or replace function public.update_recurring_template(
  p_id uuid, p_document_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r public.recurring_documents;
  v_doc_org uuid;
  v_contact uuid;
begin
  select * into r from public.recurring_documents where id = p_id;
  if not found then
    raise exception 'Schedule not found' using errcode = 'P0002';
  end if;
  if not app.can_post(r.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  if r.kind = 'sales' then
    select d.org_id, d.contact_id into v_doc_org, v_contact
      from public.sales_documents d
     where d.id = p_document_id and d.doc_type = 'invoice' and d.deleted_at is null;
  else
    select d.org_id, d.contact_id into v_doc_org, v_contact
      from public.purchase_documents d
     where d.id = p_document_id and d.doc_type = 'bill' and d.deleted_at is null;
  end if;

  if v_doc_org is null then
    raise exception 'No % document % to copy from', r.kind, p_document_id
      using errcode = '22023';
  end if;
  -- Copying across organizations would put one company's prices into
  -- another company's billing.
  if v_doc_org <> r.org_id then
    raise exception 'That document belongs to another organization'
      using errcode = '42501';
  end if;

  update public.recurring_documents
     set template = app.snapshot_document(p_document_id, r.kind),
         contact_id = v_contact
   where id = p_id;
end; $$;

-- ---------------------------------------------------------------------
-- 5. Raising one document from a schedule
--
-- Totals are not passed in. The line trigger normalises each line and
-- the header trigger foots the document, which is the same arithmetic
-- the editor gets and the only copy of it.
-- ---------------------------------------------------------------------
create or replace function app.raise_recurring_document(
  p_id uuid, p_on date)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r public.recurring_documents;
  v_header jsonb;
  v_line jsonb;
  v_doc uuid;
  v_rate numeric(18, 8);
  v_currency char(3);
  v_base char(3);
  v_no integer := 0;
begin
  select * into r from public.recurring_documents where id = p_id;
  if not found then
    raise exception 'Schedule not found' using errcode = 'P0002';
  end if;

  v_header := r.template -> 'header';
  v_currency := coalesce(v_header ->> 'currency', 'MYR');
  select base_currency into v_base from public.organizations where id = r.org_id;

  -- A retainer billed in dollars is billed at the rate on the day it is
  -- raised, not the rate on the day the schedule was made.
  v_rate := case when v_currency = coalesce(v_base, 'MYR') then 1
                 else app.exchange_rate_for(r.org_id, v_currency, p_on) end;

  if r.kind = 'sales' then
    insert into public.sales_documents (
      org_id, doc_type, doc_no, doc_date, due_date,
      contact_id, contact_person_id, shipping_address_id,
      subject, reference, currency, exchange_rate, payment_term_id,
      discount_percent, discount_amount, shipping_amount, salesperson_id,
      notes, terms_conditions, custom_fields, status)
    values (
      r.org_id, 'invoice',
      app.next_document_number_internal(r.org_id, 'invoice'),
      p_on, p_on + r.payment_terms_days,
      r.contact_id,
      (v_header ->> 'contact_person_id')::uuid,
      (v_header ->> 'shipping_address_id')::uuid,
      v_header ->> 'subject', v_header ->> 'reference',
      v_currency, v_rate, (v_header ->> 'payment_term_id')::uuid,
      coalesce((v_header ->> 'discount_percent')::numeric, 0),
      coalesce((v_header ->> 'discount_amount')::numeric, 0),
      coalesce((v_header ->> 'shipping_amount')::numeric, 0),
      (v_header ->> 'salesperson_id')::uuid,
      v_header ->> 'notes', v_header ->> 'terms_conditions',
      coalesce(v_header -> 'custom_fields', '{}'::jsonb), 'draft')
    returning id into v_doc;

    for v_line in select * from jsonb_array_elements(r.template -> 'lines')
    loop
      v_no := v_no + 1;
      -- The columns dropped from the snapshot have to come back with
      -- values: `jsonb_populate_record` leaves a missing key null, and
      -- this insert names every column, so a null reaches a NOT NULL.
      insert into public.sales_document_lines
      select (jsonb_populate_record(
                null::public.sales_document_lines,
                v_line || jsonb_build_object(
                  'id', gen_random_uuid(),
                  'org_id', r.org_id,
                  'document_id', v_doc,
                  'line_no', v_no,
                  'quantity_fulfilled', 0,
                  'quantity_invoiced', 0,
                  'cost_amount', 0,
                  'created_at', now(),
                  'updated_at', now()))).*;
    end loop;
  else
    insert into public.purchase_documents (
      org_id, doc_type, doc_no, doc_date, due_date,
      contact_id, contact_person_id, reference,
      currency, exchange_rate, payment_term_id,
      discount_percent, discount_amount, shipping_amount,
      requires_self_billed, notes, custom_fields, status)
    values (
      r.org_id, 'bill',
      app.next_document_number_internal(r.org_id, 'bill'),
      p_on, p_on + r.payment_terms_days,
      r.contact_id, (v_header ->> 'contact_person_id')::uuid,
      v_header ->> 'reference',
      v_currency, v_rate, (v_header ->> 'payment_term_id')::uuid,
      coalesce((v_header ->> 'discount_percent')::numeric, 0),
      coalesce((v_header ->> 'discount_amount')::numeric, 0),
      coalesce((v_header ->> 'shipping_amount')::numeric, 0),
      coalesce((v_header ->> 'requires_self_billed')::boolean, false),
      v_header ->> 'notes',
      coalesce(v_header -> 'custom_fields', '{}'::jsonb), 'draft')
    returning id into v_doc;

    for v_line in select * from jsonb_array_elements(r.template -> 'lines')
    loop
      v_no := v_no + 1;
      -- The columns dropped from the snapshot have to come back with
      -- values: `jsonb_populate_record` leaves a missing key null, and
      -- this insert names every column, so a null reaches a NOT NULL.
      insert into public.purchase_document_lines
      select (jsonb_populate_record(
                null::public.purchase_document_lines,
                v_line || jsonb_build_object(
                  'id', gen_random_uuid(),
                  'org_id', r.org_id,
                  'document_id', v_doc,
                  'line_no', v_no,
                  'quantity_fulfilled', 0,
                  'quantity_invoiced', 0,
                  'cost_amount', 0,
                  'created_at', now(),
                  'updated_at', now()))).*;
    end loop;
  end if;

  if r.auto_post then
    if r.kind = 'sales' then
      perform app.post_sales_document_internal(v_doc);
    else
      perform app.post_purchase_document_internal(v_doc);
    end if;
  end if;

  -- Only a posted invoice is worth sending: a draft has no number the
  -- customer can pay against and may still be changed.
  if r.auto_email and r.kind = 'sales' and r.auto_post then
    perform app.queue_document_email(
      v_doc, 'document_new', 'recurring:' || v_doc::text);
  end if;

  return v_doc;
end; $$;

revoke all on function app.raise_recurring_document(uuid, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. The runs
--
-- One schedule at a time, and one schedule that cannot raise its
-- document must not stop the others — nor fail silently. On an error
-- `next_run_date` is left where it was and the reason is written down,
-- so it is retried once whatever is in the way is cleared: a closed
-- period, a credit limit, a customer somebody deleted.
--
-- The loop inside catches up rather than raising one document per run,
-- because a scheduler that was down for a week owes a week of invoices
-- rather than one. The cap is what stops a schedule dormant since 2020
-- from raising two thousand documents the night somebody switches it
-- back on; hitting it is not an error, it just carries on tomorrow.
-- ---------------------------------------------------------------------
create or replace function app.advance_recurring_document(p_id uuid, p_on date)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r public.recurring_documents;
  v_doc uuid;
  v_n integer := 0;
begin
  loop
    select * into r from public.recurring_documents where id = p_id;
    exit when not found;
    exit when not r.is_active;
    exit when r.next_run_date > p_on;
    exit when r.end_date is not null and r.next_run_date > r.end_date;
    exit when r.max_occurrences is not null and r.occurrences >= r.max_occurrences;
    exit when v_n >= 60;

    begin
      v_doc := app.raise_recurring_document(r.id, r.next_run_date);

      update public.recurring_documents
         set last_run_date = r.next_run_date,
             last_document_id = v_doc,
             occurrences = r.occurrences + 1,
             next_run_date = app.advance_schedule(
               r.next_run_date, r.frequency, r.interval_count),
             -- A schedule that has produced everything it was asked for
             -- stops rather than sitting due forever.
             is_active = case
               when r.max_occurrences is not null
                    and r.occurrences + 1 >= r.max_occurrences then false
               else true end,
             last_error = null, last_error_at = null
       where id = r.id;
      v_n := v_n + 1;
    exception when others then
      update public.recurring_documents
         set last_error = sqlerrm, last_error_at = now()
       where id = r.id;
      raise warning 'recurring document % (%) skipped: %', r.name, r.id, sqlerrm;
      -- `next_run_date` is untouched, so leaving now is what makes this
      -- terminate rather than retrying the same failure forever.
      exit;
    end;
  end loop;

  return v_n;
end; $$;

revoke all on function app.advance_recurring_document(uuid, date)
  from public, anon, authenticated;

create or replace function app.run_recurring_documents(p_on date default current_date)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r record;
  v_n integer := 0;
begin
  for r in
    select d.id from public.recurring_documents d
      join public.organizations o on o.id = d.org_id
     where d.is_active
       and coalesce(o.status, 'active') = 'active'
       and d.next_run_date <= p_on
  loop
    v_n := v_n + app.advance_recurring_document(r.id, p_on);
  end loop;

  return v_n;
end; $$;

revoke all on function app.run_recurring_documents(date)
  from public, anon, authenticated;

-- The same run for one organization, driven by somebody who is signed
-- in — a schedule that failed on a closed period and has been fixed at
-- four in the afternoon should not have to wait for tonight.
--
-- Deliberately not a wrapper around `app.run_recurring_documents`: that
-- one walks every organization in the database, and a signed-in user
-- may only raise documents in their own.
create or replace function public.run_recurring_documents_for(
  p_org_id uuid, p_on date default current_date)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r record;
  v_n integer := 0;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;

  for r in
    select id from public.recurring_documents
     where org_id = p_org_id and is_active and next_run_date <= p_on
  loop
    v_n := v_n + app.advance_recurring_document(r.id, p_on);
  end loop;

  return v_n;
end; $$;

-- ---------------------------------------------------------------------
-- 7. Into the job that already runs every night
-- ---------------------------------------------------------------------
create or replace function app.run_daily_jobs(p_on date default current_date)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare o record;
begin
  perform app.run_recurring_journals(p_on);
  -- The one new line. Everything below is 0095's, unchanged.
  perform app.run_recurring_documents(p_on);
  perform app.queue_overdue_reminders(p_on);

  for o in select id from public.organizations where coalesce(status, 'active') = 'active'
  loop
    if extract(month from p_on) = 1 and extract(day from p_on) = 1 then
      perform app.roll_leave_year(o.id, extract(year from p_on)::integer);
    end if;

    if extract(day from p_on) = 1 and app.has_module(o.id, 'einvoice') then
      perform app.roll_einvoice_consolidation(
        o.id, (p_on - interval '1 month')::date);
    end if;
  end loop;
end;
$$;

revoke all on function app.run_daily_jobs(date) from public, anon, authenticated;

revoke all on function public.create_recurring_document(
  uuid, text, text, date, integer, date, integer, boolean, boolean)
  from public, anon;
revoke all on function public.update_recurring_template(uuid, uuid) from public, anon;
revoke all on function public.run_recurring_documents_for(uuid, date) from public, anon;
grant execute on function public.create_recurring_document(
  uuid, text, text, date, integer, date, integer, boolean, boolean) to authenticated;
grant execute on function public.update_recurring_template(uuid, uuid) to authenticated;
grant execute on function public.run_recurring_documents_for(uuid, date) to authenticated;
