-- ---------------------------------------------------------------------
-- 0441  The service tax a retainer dropped every month
-- ---------------------------------------------------------------------
-- The `0410` shape a fifth time, and this one is `0418`'s defect
-- resurrected on the path `0416` had just finished repairing.
--
-- `app.snapshot_document` freezes what a recurring template should
-- reproduce every month. `0416` found it had never been told about
-- `service_charge_amount` and added it -- and two migrations later
-- `0418` put two more columns on the same header,
-- `service_charge_tax_code_id` and `service_charge_tax`, and the
-- snapshot was never told about those either.
--
-- Measured on Sinar, which is registered at ST8. A monthly retainer
-- with a RM100 service charge taxed at RM8:
--
--     TEMPLATE svc=100.00 svc_tax=8.00 code_set=t
--     RAISED   svc=100.00 svc_tax=0.00 code_set=f
--
-- The charge survives; the tax and the code do not. And the
-- consequence is larger than the eight ringgit, because
-- `report_sst_summary` -- `0418`'s own return -- reaches the service
-- charge through an INNER JOIN:
--
--     join public.tax_codes t on t.id = d.service_charge_tax_code_id
--
-- With no code there is no row, so the WHOLE RM100 disappears from the
-- return: not just the tax, the taxable value with it. A serviced
-- office or a restaurant on a monthly retainer under-declares both, in
-- every taxable period, and the return balances against itself
-- perfectly while doing it. `0418`'s header called this "eighty sen in
-- every hundred ringgit, undeclared, every taxable period"; on the
-- recurring path it was a hundred ringgit as well.
--
-- Both columns are carried, not one. Carrying the code alone would put
-- the RM100 back on the return with RM0.00 of tax against it, which is
-- a different wrong number and a worse one -- a taxable supply declared
-- as bearing no tax. Nothing outside the POS path computes
-- `service_charge_tax`: `app.recalc_sales_totals` adds the charge to the
-- total and does not touch the tax on it, and only
-- `app.recalc_pos_sale`, `public.set_pos_service_charge` and
-- `public.complete_pos_sale` ever write it. On a fixed monthly
-- retainer that is exactly right -- the charge is the same figure every
-- month, so the tax on it is too, and reproducing the template
-- reproduces both.
--
-- The limit that leaves, named rather than built: a service charge that
-- is a PERCENTAGE of a bill that varies month to month would need its
-- tax recomputed at each raise, and nothing outside POS can do that.
-- A general mechanism for taxing a header charge is a product decision
-- with tax advice behind it, not a line to slot in here, and this
-- migration does not pretend to make one.
--
-- Not an oversight, which is the part worth reading twice. The test
-- file `recurring_template_carries_the_document.sql` has a list of
-- columns a schedule deliberately does not carry, and these two were on
-- it, with a reason: "derived at the till from the outlet's rate, not
-- chosen on the document ... whatever raises the invoice works them out
-- again." The first half is true. The second is not, and measuring is
-- how that came out: `app.recalc_sales_totals` adds the charge to the
-- total and does not touch the tax on it, and only
-- `app.recalc_pos_sale`, `public.set_pos_service_charge` and
-- `public.complete_pos_sale` ever write it. A recurring raise is not a
-- till, so nothing worked them out again. The exemption and its comment
-- are both replaced rather than quietly deleted.
--
-- And the worry that exemption recorded is real, so it is answered
-- rather than dismissed: a schedule replaying a tax figure asserts a
-- tax nobody worked out this month. For a FIXED retainer -- which is
-- what a snapshot is -- the charge is the same figure every month and
-- so is the tax, and reproducing the template reproduces both
-- correctly. For a charge that is a percentage of a bill that varies,
-- neither carrying nor dropping is right; the answer is recomputation,
-- and that is the limit named above.
--
-- Three mutants applied and measured, each killed by a test assertion
-- for its own reason: the snapshot freezing the code while the raise
-- ignores it -- killed, "the code it is taxed under"; the code carried
-- and the tax figure zeroed -- killed, "the tax on it", got 0.00; the
-- snapshot no longer freezing the code -- killed by the first
-- assertion again, which is the right one for it.
--
-- The fourth assertion -- that the charge reaches `report_sst_summary`
-- -- made no kill of its own, and could not: every mutant that removes
-- the code trips the column assertion first. It is the statement of
-- WHY the columns matter, and it guards that inner join staying an
-- inner join, which is a change somebody could make in the report
-- without ever looking here. Worth having on those terms, not as a
-- kill it did not make.
--
-- The purchase half of the snapshot was checked the same way and is
-- clean: every column it does not carry is per-instance -- the
-- supplier's own number and date, the expected date, the approval, the
-- e-Invoice state, the attachments and the intercompany link. A
-- negative result, recorded so the next sweep does not re-derive it.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The snapshot, restated to freeze the tax as well as the charge
-- ---------------------------------------------------------------------
-- Restated from the live `pg_get_functiondef`.

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

-- ---------------------------------------------------------------------
-- And the raise, restated to read them
-- ---------------------------------------------------------------------
-- Both halves. The snapshot writes the keys and the raise names the
-- columns it inserts, so adding one without the other changes
-- nothing -- measured: after the snapshot alone the raised document
-- still came out `svc_tax=0.00 code_set=f`.

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
end; $function$;

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = to_regprocedure('app.snapshot_document(uuid, text)');

  if v_src !~ 'service_charge_tax_code_id' then
    raise exception
      'FAIL 0441: a recurring template still forgets which tax the '
      'service charge is under, so report_sst_summary drops the whole '
      'charge from the return';
  end if;
  if v_src !~ 'service_charge_tax' then
    raise exception
      'FAIL 0441: the template carries the tax code and not the tax, so '
      'the return declares a taxable supply bearing no tax';
  end if;

  -- `0416`'s column is still there. This function is restated from a
  -- copy, and losing the charge itself while adding the tax on it would
  -- be a fine joke at the next reader''s expense.
  if v_src !~ 'service_charge_amount' then
    raise exception
      'FAIL 0441: 0416''s service charge has been dropped from the '
      'snapshot';
  end if;

  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = to_regprocedure('app.raise_recurring_document(uuid, date)');
  if v_src !~ 'service_charge_tax_code_id' or v_src !~ 'service_charge_tax' then
    raise exception
      'FAIL 0441: the snapshot freezes the tax and the raise does not '
      'read it, which changes nothing at all';
  end if;

  raise notice
    '0441: a retainer reproduces the tax on its service charge';
end
$do$;
