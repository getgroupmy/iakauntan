-- =====================================================================
-- iAkauntan :: the monthly bill that quietly billed less than the one
--              it was made from
--
-- `app.snapshot_document` freezes a document into the template a
-- recurring schedule replays. Its two halves do the same job in
-- opposite directions, and one of them says so:
--
--     -- Everything on the line except what belongs to the document it
--     -- came off. Listing what to keep instead would quietly drop any
--     -- column added after today.
--
-- That comment is on the *lines*, which subtract. The *header* lists
-- what to keep -- the thing the comment warns against -- and it had
-- already quietly dropped three columns.
--
-- Measured on this stack before the change. A property manager sets up
-- one monthly bill: RM300 maintenance, RM12 delivery, a RM45 service
-- charge, on the Kuala Lumpur branch.
--
--     template  ship 12.00  service charge 45.00  branch set   total 381.00
--     raised    ship 12.00  service charge  0.00  branch null  total 336.00
--
-- RM45 short, every month, on every parcel, and the invoice lands
-- outside the branch it belongs to. A monthly service charge billed to
-- every owner is not an edge case in Malaysia -- it is what a strata
-- management company does all day.
--
-- Three columns, and each was dropped the same way:
--
--   * `service_charge_amount` -- `0410`, six migrations ago, mine.
--   * `branch_id` -- `0131`, thirty-four migrations after `0097` built
--     the template. Missing on the buying side as well.
--   * `matter_id` -- `0021`, which predates the template, so this one
--     was never carried rather than dropped. A firm's monthly retainer
--     billed against a matter belongs on that matter's ledger.
--
-- ## What this does not fix
--
-- Schedules already stored keep the header they were snapshotted with.
-- `recurring_documents` holds no reference to the document a template
-- was made from -- `last_document_id` is the last invoice raised, which
-- is itself missing the columns -- so there is nothing to re-derive
-- them from. Saving the template again (`update_recurring_template`)
-- picks them up. The replay coalesces a missing key rather than
-- failing, so those schedules go on billing exactly what they billed
-- yesterday.
--
-- ## What stops it happening again
--
-- `supabase/tests/recurring_template_carries_the_document.sql` builds a
-- document with every header column set, snapshots it, and requires
-- each column of `sales_documents` and `purchase_documents` to be
-- either in the snapshot or in a list of columns written down as not
-- replayed with the reason. A column added to either table and not
-- decided about turns that test red. The whitelist is kept -- a header
-- has forty-odd columns and most of them are identity, computed totals
-- and lifecycle that must never be replayed, so subtracting would be
-- the more dangerous direction here. What was missing was not the
-- blacklist; it was anything at all that noticed.
-- =====================================================================

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
             -- `0410` put a service charge on the header. It was not
             -- added here, so every raise of a schedule made from a
             -- document carrying one billed short by exactly that
             -- amount -- see this migration's header.
             'service_charge_amount', d.service_charge_amount,
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
end; $function$

;

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
      discount_percent, discount_amount, shipping_amount,
      service_charge_amount, branch_id, matter_id, salesperson_id,
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
      -- `coalesce` and not a bare cast, because a schedule snapshotted
      -- before this migration has no such key and a missing key reads
      -- as null. Those schedules keep billing what they always billed
      -- until somebody saves the template again; there is nothing on
      -- `recurring_documents` pointing back at the document they were
      -- made from, so they cannot be re-derived here.
      coalesce((v_header ->> 'service_charge_amount')::numeric, 0),
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
      discount_percent, discount_amount, shipping_amount, branch_id,
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
end; $function$

;

-- The restatement is long and copied, so this checks the three columns
-- actually reached both halves of both functions rather than trusting
-- that they did. It is a source check and it proves only that the names
-- are present; that the *values* survive a round trip is
-- `recurring_template_carries_the_document.sql`, which raises a real
-- invoice from a real schedule and compares the money.
do $$
declare
  v_snap text;
  v_raise text;
begin
  select prosrc into v_snap from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'snapshot_document';
  select prosrc into v_raise from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'raise_recurring_document';

  if v_snap is null or v_raise is null then
    raise exception '0416: a function it restates is not there';
  end if;

  -- Twice for branch_id: once in each half, sales and purchases.
  if (length(v_snap) - length(replace(v_snap, '''branch_id''', ''))) 
     / length('''branch_id''') <> 2 then
    raise exception '0416: branch_id is not in both halves of the snapshot';
  end if;
  if v_snap not like '%''service_charge_amount''%'
     or v_snap not like '%''matter_id''%' then
    raise exception '0416: the snapshot header is still missing a column';
  end if;

  if (length(v_raise) - length(replace(v_raise, 'branch_id', '')))
     / length('branch_id') <> 4 then
    -- Named once in the column list and once in the values list, on
    -- each of the two sides.
    raise exception '0416: the replay does not put branch_id back on both sides';
  end if;
  if v_raise not like '%service_charge_amount%'
     or v_raise not like '%matter_id%' then
    raise exception '0416: the replay is still dropping a column';
  end if;
end $$;
