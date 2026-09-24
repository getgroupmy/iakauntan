-- =====================================================================
-- iAkauntan :: 0706 the supplier did not round, and we did
--
-- Reported with the supplier's own PDF attached:
--
--   supplier invoice scanned in with no round up or round down, make
--   round up or round down automatic but not for all cases AI SmartScan
--   should be smart enough to identify
--
-- The paper, Google Asia Pacific tax invoice 5665871390:
--
--   Subtotal in MYR      MYR 1,086.12
--   Service tax (8%)     MYR    86.89
--   Total in MYR         MYR 1,173.01
--
-- and `BILL-2026-00016` in this system showed
--
--   Subtotal  RM 1,086.12    SST  RM 86.89
--   Rounding  RM    -0.01    Nearest 5 sen
--   Total     RM 1,173.00
--
-- A rounding adjustment of one sen that the supplier never made, on a
-- bill this company owes 1,173.01 of. Pay the rounded figure and the
-- supplier's statement is a sen short for ever.
--
-- ---------------------------------------------------------------------
-- What was actually wrong
--
-- `app.round_amount`'s own comment, written in `0009`, has said the
-- right thing all along:
--
--   'Bank Negara rounding mechanism: cash totals round to the nearest
--    5 sen.'
--
-- CASH totals. Bank Negara's rounding mechanism, in force since 1 April
-- 2008, applies to the amount payable in CASH at the counter, because
-- there is no 1 sen coin to pay it with. A bill settled by transfer,
-- card or on credit terms is paid to the sen and is not rounded by
-- anybody.
--
-- But `organizations.rounding_method` is one switch for the whole
-- company, and both recalculation triggers applied it to every document
-- ever raised or received. A company that takes cash over a counter --
-- which is why the switch is set -- had that setting silently restating
-- every supplier bill it received as well.
--
-- ---------------------------------------------------------------------
-- The document decides, and the paper tells it what to decide
--
-- A nullable `rounding_method` on each document table:
--
--   null  -- exactly as before: the company's setting applies. Every
--            row in every existing database is null, so nothing that
--            anybody has already posted or raised changes by one sen.
--   set   -- this document rounds this way, whatever the company does.
--
-- and both triggers resolve `coalesce(document, organization)`.
--
-- What sets it is the app, from the SCAN, and it is not a guess: the
-- paper's own total is printed on the paper. `roundingThePaperApplied`
-- compares the stated total against what the lines come to under each
-- method and takes the one that matches -- and returns nothing at all
-- when two of them match, because a bill that lands on a 5 sen boundary
-- is no evidence either way. `0705` reads the stated total; this is the
-- second thing worth doing with it.
--
-- So the Google bill above stores `none` and totals 1,173.01, and a
-- cash receipt that prints its own "Rounding -0.02" stores
-- `nearest_5cent` and agrees with the till it came out of.
-- =====================================================================

alter table public.sales_documents
  add column if not exists rounding_method text;
alter table public.purchase_documents
  add column if not exists rounding_method text;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'sales_documents_rounding_method_ck') then
    alter table public.sales_documents
      add constraint sales_documents_rounding_method_ck
      check (rounding_method is null
          or rounding_method in ('none', 'nearest_5cent', 'nearest_10cent'));
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'purchase_documents_rounding_method_ck') then
    alter table public.purchase_documents
      add constraint purchase_documents_rounding_method_ck
      check (rounding_method is null
          or rounding_method in ('none', 'nearest_5cent', 'nearest_10cent'));
  end if;
end $$;

comment on column public.sales_documents.rounding_method is
  'How THIS document rounds, overriding the company setting. Null means '
  'the company''s, which is what every document raised before 0706 has. '
  'Set from the scanned paper''s own stated total where it can be told '
  'apart -- Bank Negara''s mechanism rounds CASH, and a document settled '
  'any other way is paid to the sen. 0706.';
comment on column public.purchase_documents.rounding_method is
  'How THIS document rounds, overriding the company setting. Null means '
  'the company''s. A supplier''s bill states its own total and that '
  'total is the amount owed; rounding it to the nearest 5 sen made this '
  'company underpay by a sen and the supplier''s statement never clear. '
  '0706.';

-- ---------------------------------------------------------------------
-- The recalculation, now callable by id
--
-- Split out of the two trigger functions so that a change to the HEADER
-- can run it as well. Until now only a LINE moving recomputed a total,
-- which is why `rounding_method` needs this: it is set on the header,
-- and a column that only takes effect when somebody happens to edit a
-- line afterwards is a column that lies.
-- ---------------------------------------------------------------------
create or replace function app.recalc_sales_totals_for(p_doc_id uuid)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_subtotal  numeric(18, 2);
  v_tax       numeric(18, 2);
  v_doc       public.sales_documents;
  v_method    text;
  v_discount  numeric(18, 2);
  v_raw_total numeric(18, 2);
  v_rounded   numeric(18, 2);
begin
  select * into v_doc from public.sales_documents where id = p_doc_id;
  if not found then
    return;
  end if;

  select coalesce(sum(line_subtotal), 0), coalesce(sum(tax_amount), 0)
    into v_subtotal, v_tax
    from public.sales_document_lines
   where document_id = p_doc_id;

  -- The document's own answer first, the company's behind it. `0706`.
  if v_doc.rounding_method is not null then
    v_method := v_doc.rounding_method;
  else
    select rounding_method into v_method
      from public.organizations where id = v_doc.org_id;
  end if;

  if coalesce(v_doc.discount_percent, 0) > 0 then
    v_discount := round(v_subtotal * v_doc.discount_percent / 100.0, 2);
  else
    v_discount := coalesce(v_doc.discount_amount, 0);
  end if;

  -- The service charge rides beside the shipping: both are amounts the
  -- customer is charged that no line carries. The tax that belongs to
  -- the charge is already in `tax_amount` -- `complete_pos_sale` puts it
  -- there, because Malaysian service tax is charged on the bill after
  -- the service charge and not on the food alone.
  v_raw_total := v_subtotal - v_discount + v_tax
               + coalesce(v_doc.shipping_amount, 0)
               + coalesce(v_doc.service_charge_amount, 0);
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
   where id = p_doc_id;
end;
$$;

create or replace function app.recalc_purchase_totals_for(p_doc_id uuid)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_subtotal  numeric(18, 2);
  v_tax       numeric(18, 2);
  v_doc       public.purchase_documents;
  v_method    text;
  v_discount  numeric(18, 2);
  v_raw_total numeric(18, 2);
  v_rounded   numeric(18, 2);
begin
  select * into v_doc from public.purchase_documents where id = p_doc_id;
  if not found then
    return;
  end if;

  select coalesce(sum(line_subtotal), 0), coalesce(sum(tax_amount), 0)
    into v_subtotal, v_tax
    from public.purchase_document_lines
   where document_id = p_doc_id;

  if v_doc.rounding_method is not null then
    v_method := v_doc.rounding_method;
  else
    select rounding_method into v_method
      from public.organizations where id = v_doc.org_id;
  end if;

  if coalesce(v_doc.discount_percent, 0) > 0 then
    v_discount := round(v_subtotal * v_doc.discount_percent / 100.0, 2);
  else
    v_discount := coalesce(v_doc.discount_amount, 0);
  end if;

  v_raw_total := v_subtotal - v_discount + v_tax
               + coalesce(v_doc.shipping_amount, 0);
  v_rounded   := app.round_amount(v_raw_total, coalesce(v_method, 'none'));

  update public.purchase_documents
     set subtotal          = v_subtotal,
         discount_amount   = v_discount,
         tax_amount        = v_tax,
         rounding_amount   = v_rounded - v_raw_total,
         total_amount      = v_rounded,
         base_total_amount = round(v_rounded * coalesce(v_doc.exchange_rate, 1), 2),
         balance_amount    = v_rounded - coalesce(v_doc.paid_amount, 0)
   where id = p_doc_id;
end;
$$;

comment on function app.recalc_sales_totals_for(uuid) is
  'Recomputes one sales document''s header figures from its lines. Split '
  'out of the line trigger by 0706 so a header change -- the rounding '
  'method -- can run it too.';
comment on function app.recalc_purchase_totals_for(uuid) is
  'Recomputes one purchase document''s header figures from its lines. '
  'Split out of the line trigger by 0706.';

create or replace function app.recalc_sales_totals()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  perform app.recalc_sales_totals_for(coalesce(new.document_id,
                                               old.document_id));
  return coalesce(new, old);
end;
$$;

create or replace function app.recalc_purchase_totals()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  perform app.recalc_purchase_totals_for(coalesce(new.document_id,
                                                  old.document_id));
  return coalesce(new, old);
end;
$$;

-- And the header. `update of rounding_method` fires when that column is
-- in the SET list, and the recalculation above never sets it, so this
-- cannot recurse.
create or replace function app.recalc_sales_totals_header()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  perform app.recalc_sales_totals_for(new.id);
  return null;
end;
$$;

create or replace function app.recalc_purchase_totals_header()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  perform app.recalc_purchase_totals_for(new.id);
  return null;
end;
$$;

drop trigger if exists recalc_totals_on_rounding on public.sales_documents;
create trigger recalc_totals_on_rounding
  after update of rounding_method on public.sales_documents
  for each row execute function app.recalc_sales_totals_header();

drop trigger if exists recalc_totals_on_rounding on public.purchase_documents;
create trigger recalc_totals_on_rounding
  after update of rounding_method on public.purchase_documents
  for each row execute function app.recalc_purchase_totals_header();

-- ---------------------------------------------------------------------
-- Frozen once posted
--
-- `rounding_method` decides `rounding_amount` and `total_amount`, both
-- of which are already frozen and both of which the journal was built
-- from -- the rounding goes to 4990 on the sales side and to its
-- purchase counterpart. A method that could be changed afterwards is a
-- document that stops agreeing with its own posting.
--
-- Restated in full from `0691`, which is where the list stands.
-- ---------------------------------------------------------------------
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
    'service_charge_tax', 'service_charge_tax_code_id',
    -- 0706. `rounding_method` decides `rounding_amount` and
    -- `total_amount`, both already on this list, and the journal
    -- carries the rounding line the two of them produce. A method
    -- changed after posting is a document that stops agreeing with
    -- its own entry.
    'rounding_method'];
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

-- ---------------------------------------------------------------------
-- And the grants that come with splitting them out
--
-- A trigger function needs no EXECUTE to fire, which is why the two
-- `recalc_*_totals` triggers have never needed one. The first thing
-- they now call inside IS checked, against the role that caused the
-- write -- `supabase/tests/trigger_reachable_grants.sql` walks exactly
-- this and refused until these were here. `service_role` as well,
-- because an edge function bypasses row level security and does not
-- bypass a function privilege.
-- ---------------------------------------------------------------------
grant execute on function app.recalc_sales_totals_for(uuid)
  to authenticated, service_role;
grant execute on function app.recalc_purchase_totals_for(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- A standing order meets the same supplier every month
--
-- `supabase/tests/recurring_template_carries_the_document.sql` walks the
-- real table and refuses a column the template neither carries nor
-- declines. This one is CARRIED: a schedule billing Google every month
-- meets the same rounding habit every month, and one that dropped it
-- would put back the sen the first bill proved was not rounded.
--
-- Both restated in full from what is in the database.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.snapshot_document(p_document_id uuid, p_kind text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
             -- 0706. How the document rounds. A standing order from
             -- the same supplier meets the same rounding habit
             -- every month, and a schedule that dropped it would
             -- put back the sen the first bill proved was not
             -- rounded. Null on a snapshot taken before 0706,
             -- which reads as the company's own setting -- the
             -- behaviour those schedules already have.
             'rounding_method', d.rounding_method,
             -- `0410` put a service charge on the header. It was not
             -- added here, so every raise of a schedule made from a
             -- document carrying one billed short by exactly that
             -- amount -- see `0416`'s header.
             'service_charge_amount', d.service_charge_amount,
             -- `0418` put the tax on that charge beside it, two
             -- migrations after `0416` added the line above, and this
             -- was not told about either. Without the code
             -- `report_sst_summary` joins to nothing and drops the
             -- whole charge from the return -- see `0441`'s header.
             'service_charge_tax_code_id', d.service_charge_tax_code_id,
             'service_charge_tax', d.service_charge_tax,
             -- `0131` and `0021`. A schedule that forgets which branch
             -- or which matter the work belongs to puts every future
             -- invoice in the wrong place in the reports it feeds.
             'branch_id', d.branch_id,
             'matter_id', d.matter_id,
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
             -- 0706. How the document rounds. A standing order from
             -- the same supplier meets the same rounding habit
             -- every month, and a schedule that dropped it would
             -- put back the sen the first bill proved was not
             -- rounded. Null on a snapshot taken before 0706,
             -- which reads as the company's own setting -- the
             -- behaviour those schedules already have.
             'rounding_method', d.rounding_method,
             -- `0131`, the same omission on the buying side. There is
             -- no service charge on a purchase document: a supplier's
             -- is a line on their bill, not a header amount of ours.
             'branch_id', d.branch_id,
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
end; $function$;

CREATE OR REPLACE FUNCTION app.raise_recurring_document(p_id uuid, p_on date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
      discount_percent, discount_amount, shipping_amount, rounding_method,
      service_charge_amount, service_charge_tax_code_id, service_charge_tax,
      branch_id, matter_id, salesperson_id,
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
      -- 0706. Plain text and no `coalesce`: null is a value here and
      -- means the company's own setting, which is exactly what a
      -- schedule snapshotted before 0706 has and should keep.
      v_header ->> 'rounding_method',
      -- `coalesce` and not a bare cast, because a schedule snapshotted
      -- before this migration has no such key and a missing key reads
      -- as null. Those schedules keep billing what they always billed
      -- until somebody saves the template again; there is nothing on
      -- `recurring_documents` pointing back at the document they were
      -- made from, so they cannot be re-derived here.
      coalesce((v_header ->> 'service_charge_amount')::numeric, 0),
      -- `0441`. The tax on that charge and the code it is under, for
      -- the same reason and with the same `coalesce`: a schedule
      -- snapshotted before `0441` has neither key, and a missing key
      -- reads as null. Those keep billing what they always billed --
      -- untaxed on the return -- until somebody saves the template
      -- again, which is the same limit `0416` recorded and for the same
      -- reason: nothing on `recurring_documents` points back at the
      -- document the snapshot was taken from.
      (v_header ->> 'service_charge_tax_code_id')::uuid,
      coalesce((v_header ->> 'service_charge_tax')::numeric, 0),
      (v_header ->> 'branch_id')::uuid,
      (v_header ->> 'matter_id')::uuid,
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
      discount_percent, discount_amount, shipping_amount, rounding_method,
      branch_id,
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
      -- 0706. Plain text and no `coalesce`: null is a value here and
      -- means the company's own setting, which is exactly what a
      -- schedule snapshotted before 0706 has and should keep.
      v_header ->> 'rounding_method',
      (v_header ->> 'branch_id')::uuid,
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
end; $function$;
