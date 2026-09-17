-- ---------------------------------------------------------------------
-- 0439  The terms the customer agreed
-- ---------------------------------------------------------------------
-- The same predicate as `0437` and `0438`, run over dates instead of
-- rates: which function writes a due date from something other than the
-- agreement it is billing under. Two do.
--
-- **A fee note is due the day it is raised.** `app.bill_time_internal`
-- sets `due_date := coalesce(p_due, p_to)` and never touches
-- `payment_term_id`, so unless the caller supplies a date the invoice
-- falls due on its own doc_date. Measured on Sinar with a client set to
-- NET30: doc_date 2026-09-02, due_date 2026-09-02, and the document's
-- `payment_term_id` null. A client entitled to thirty days is in the
-- ageing from day one, and `report_ar_aging` -- which buckets on
-- `coalesce(due_date, doc_date)` -- shows them a month in arrears for a
-- month they were promised. Chasing a client for money they do not owe
-- yet is the kind of error a firm loses the client over.
--
-- **An intercompany bill is due on no date at all.**
-- `accept_intercompany_bill` copies the counterparty's invoice
-- faithfully -- doc_date, currency, exchange rate, subtotal, discount,
-- tax, total, base total, their number and their date -- and does not
-- copy `due_date` or `payment_term_id`. That is `0410`'s shape exactly:
-- a header column the copying function was never told about. The bill
-- lands with a null due date, and `report_ap_aging` ages a null from
-- `doc_date`, so a group company on thirty-day terms with itself shows
-- thirty days more overdue than it is, in every bucket, on both sides
-- of the same transaction.
--
-- The machinery to do this right already exists and neither function
-- used it. `app.due_date_from_terms` has handled `net`, `eom`, `cod`
-- and `prepaid` since the payment terms went in, and
-- `app.document_due_date_guard` fills a missing due date from the
-- document's own `payment_term_id`. What was missing is the step
-- before: nothing put the CONTACT's agreed terms onto the document. So
-- the guard had a null to work from and did nothing, correctly, for a
-- reason nobody could see.
--
-- A date the caller supplies still wins, in both. The guard's own
-- comment is the rule and it is the right one: "a due date somebody
-- typed is a date they negotiated, and overwriting it with the standard
-- terms would be the software correcting an agreement it knows nothing
-- about." This migration only fills the gap where nobody typed
-- anything.
--
-- Six mutants applied and measured, and the pattern in them is worth
-- naming. The three obvious ones -- the fee note back to due on the
-- day, the standard terms overriding a negotiated date, the
-- intercompany bill taking `doc_date` -- were all killed by this
-- migration's OWN apply-time guard before a test ran, because the guard
-- matches the very strings those mutants edit. That is the guard
-- working and it is not a test kill, so three more were written that
-- get past it and reach the assertions:
--
--   * the terms counted from the period start instead of the invoice
--     date -- killed, "a fee note falls due on the terms the client
--     agreed", got 2026-03-31 for 2026-04-30;
--   * the copied due date shifted by a month -- killed, "the date it
--     falls due, which the ageing buckets on";
--   * `payment_term_id` left null on the fee note while the date is
--     still right -- killed, "and records the terms it was raised on".
--     That one matters on its own: the settlement-discount functions
--     read the term off the document, so a fee note with the right date
--     and no term cannot say whether an early-payment discount applies.
--
-- Three other raisers were examined and are correct as they stand, and
-- are named so this is a decision rather than an oversight:
-- `raise_rent_invoices` and `raise_strata_charges` fall due on the
-- first day of the period they bill, which is what rent and
-- maintenance in advance means; `bill_statutory_charge` uses the
-- charge's own statutory due date, which is the land office's date and
-- not a matter of terms.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The fee note, restated to fall due when it should
-- ---------------------------------------------------------------------
-- Restated from the live `pg_get_functiondef`.

CREATE OR REPLACE FUNCTION app.bill_time_internal(p_org_id uuid, p_project_id uuid, p_matter_id uuid, p_contact_id uuid, p_subject text, p_from date, p_to date, p_due date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_invoice uuid;
  v_account uuid;
  v_tax uuid;
  v_term uuid;
  v_rate numeric := 0;
  v_line record;
  v_no integer := 0;
  v_total numeric(18, 2) := 0;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to raise an invoice'
      using errcode = '42501';
  end if;
  if p_contact_id is null then
    raise exception
      'There is no client on this engagement, so there is nobody to '
      'invoice.' using errcode = '23502';
  end if;
  if p_to < p_from then
    raise exception 'The period ends before it starts' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.time_entries t
     where t.org_id = p_org_id
       and t.project_id is not distinct from p_project_id
       and t.matter_id is not distinct from p_matter_id
       and t.entry_date between p_from and p_to
       and t.is_billable and not t.is_billed and t.amount > 0)
  then
    raise exception
      'No unbilled chargeable time on this engagement between % and %.',
      p_from, p_to using errcode = 'P0002';
  end if;

  v_account := app.time_income_account(p_org_id);

  -- 0437. The tax the firm registered for, if it was registered on the
  -- day this fee note is dated. Null for an unregistered company, and
  -- null for one whose registration began after `p_to` -- work done
  -- before a firm registered is billed without tax.
  v_tax := app.default_sales_tax(p_org_id, p_to);
  select coalesce(rate, 0) into v_rate from public.tax_codes
   where id = v_tax;

  -- 0439. The terms this client agreed, and the date they fall due
  -- under them. A date the caller supplied wins: that is a date
  -- somebody negotiated, and the standard terms must not overwrite it.
  -- Falling back to `p_to` when the client has no terms on file keeps
  -- the old behaviour for the only case it was ever right for.
  select payment_term_id into v_term from public.contacts
   where id = p_contact_id;

  insert into public.sales_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id,
    payment_term_id, subject, reference, currency, exchange_rate, status)
  values (
    p_org_id, 'invoice',
    app.next_document_number_internal(p_org_id, 'invoice'),
    p_to,
    coalesce(p_due, app.due_date_from_terms(v_term, p_to), p_to),
    p_contact_id, v_term,
    p_subject, format('%s to %s', p_from, p_to),
    app.base_currency(p_org_id), 1, 'draft')
  returning id into v_invoice;

  -- One line per person, with the hours on it. `sum(minutes)/60` is
  -- rounded once at the end rather than per entry, so six ten-minute
  -- calls bill as one hour and not as 0.996 of one.
  for v_line in
    select t.user_id,
           coalesce(p.full_name, p.email, 'Fee earner') as who,
           round(sum(t.minutes)::numeric / 60.0, 2) as hours,
           sum(t.amount) as amount
      from public.time_entries t
      left join public.profiles p on p.id = t.user_id
     where t.org_id = p_org_id
       and t.project_id is not distinct from p_project_id
       and t.matter_id is not distinct from p_matter_id
       and t.entry_date between p_from and p_to
       and t.is_billable and not t.is_billed and t.amount > 0
     group by t.user_id, p.full_name, p.email
     order by 2
  loop
    v_no := v_no + 1;
    -- `tax_rate` as well as `tax_code_id`. The rate is stored on the
    -- line, not looked up from the code when totals are recalculated,
    -- so a line naming ST8 without its 8 produces a fee note with no
    -- tax on it at all -- the same mistake `demo_books_sinar` made on
    -- the sales side and had to be measured to find.
    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description,
       quantity, unit_price, account_id, tax_code_id, tax_rate)
    values (p_org_id, v_invoice, v_no, 'item',
            format('%s — %s hours', v_line.who, v_line.hours),
            1, v_line.amount, v_account, v_tax, coalesce(v_rate, 0));
    v_total := v_total + v_line.amount;
  end loop;

  update public.time_entries t
     set is_billed = true, invoice_id = v_invoice
   where t.org_id = p_org_id
     and t.project_id is not distinct from p_project_id
     and t.matter_id is not distinct from p_matter_id
     and t.entry_date between p_from and p_to
     and t.is_billable and not t.is_billed and t.amount > 0;

  perform app.post_sales_document_internal(v_invoice);
  return v_invoice;
end $function$;

-- ---------------------------------------------------------------------
-- The intercompany bill, restated to copy the date as well
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.accept_intercompany_bill(p_sales_document_id uuid, p_org_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_row record;
  v_bill uuid;
  v_supplier uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'You cannot raise bills in this company'
      using errcode = '42501';
  end if;

  -- Read it back through the inbox rather than from the table, so the
  -- addressing rule is written once and cannot drift between what a
  -- person may see and what they may act on.
  select * into v_row from public.intercompany_inbox(p_org_id) i
   where i.sales_document_id = p_sales_document_id;

  -- FOUND rather than `v_row is null`: a record is null only when every
  -- column is, which is true here but by accident rather than by rule.
  if not found then
    raise exception
      'That invoice is not addressed to this company, or has not been '
      'posted yet' using errcode = '42501';
  end if;

  if v_row.already_billed then
    raise exception 'That invoice has already been billed here';
  end if;

  if v_row.supplier_contact_id is null then
    raise exception
      'Add a supplier in this company linked to %, then try again. A bill '
      'has to be owed to somebody on this company''s own books.',
      v_row.from_org;
  end if;
  v_supplier := v_row.supplier_contact_id;

  insert into public.purchase_documents (
    org_id, doc_type, doc_no, doc_date, due_date, payment_term_id,
    contact_id,
    supplier_doc_no, supplier_doc_date,
    currency, exchange_rate,
    subtotal, discount_amount, tax_amount, total_amount, base_total_amount,
    balance_amount, status, source_sales_document_id)
  select p_org_id, 'bill',
         app.next_document_number_internal(p_org_id, 'bill'),
         d.doc_date,
         -- 0439. Copied, like every other figure on this line. Without
         -- it the bill lands with no due date and `report_ap_aging`
         -- ages it from `doc_date`, so the group shows itself in
         -- arrears for the whole of the credit period it agreed.
         d.due_date, d.payment_term_id, v_supplier,
         -- Their number on our bill, which is what an SST audit and a
         -- self-billed e-Invoice both ask for.
         d.doc_no, d.doc_date,
         d.currency, d.exchange_rate,
         d.subtotal, d.discount_amount, d.tax_amount, d.total_amount,
         d.base_total_amount, d.total_amount, 'draft', d.id
    from public.sales_documents d
   where d.id = p_sales_document_id
  returning id into v_bill;

  insert into public.purchase_document_lines (
    org_id, document_id, line_no, line_type, description,
    quantity, uom_code, unit_price,
    discount_percent, discount_amount,
    tax_code_id, tax_rate, tax_amount, is_tax_inclusive,
    line_subtotal, line_total)
  select p_org_id, v_bill, l.line_no, l.line_type, l.description,
         l.quantity, l.uom_code, l.unit_price,
         l.discount_percent, l.discount_amount,
         -- Matched by code, not by id: the two companies have their own
         -- tax_codes rows, and an id from theirs would point at nothing
         -- here — or, worse, at one of ours by coincidence.
         (select t.id from public.tax_codes t
           where t.org_id = p_org_id
             and t.code = (select s.code from public.tax_codes s
                            where s.id = l.tax_code_id)),
         l.tax_rate, l.tax_amount, l.is_tax_inclusive,
         l.line_subtotal, l.line_total
    from public.sales_document_lines l
   where l.document_id = p_sales_document_id
   order by l.line_no;

  -- Deliberately not copied: `item_id` and `account_id`. Both are ids in
  -- the issuer's own masters. Which of our items this is, and which
  -- expense account it belongs in, are decisions for this company —
  -- which is why the bill arrives as a draft rather than posted.
  return v_bill;
end; $function$;

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = to_regprocedure(
     'app.bill_time_internal(uuid, uuid, uuid, uuid, text, date, date,'
     ' date)');

  if v_src !~ 'due_date_from_terms' then
    raise exception
      'FAIL 0439: a fee note still falls due the day it is raised, so a '
      'client on thirty-day terms is in the ageing from the first day';
  end if;

  -- A date the caller gave still wins. Dropping `p_due` from the
  -- coalesce would satisfy the check above and quietly overwrite a
  -- negotiated date with the standard terms.
  if v_src !~ 'coalesce\(p_due, app\.due_date_from_terms' then
    raise exception
      'FAIL 0439: the standard terms now override a date somebody '
      'negotiated, which is the software correcting an agreement';
  end if;

  -- And the term reaches the document, not just the date. The
  -- settlement-discount functions read `payment_term_id` off the
  -- document, so a fee note with the right date and no term still
  -- cannot say whether an early-payment discount applies.
  if v_src !~ 'payment_term_id' then
    raise exception
      'FAIL 0439: the fee note does not record which terms it was '
      'raised on';
  end if;

  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = to_regprocedure(
     'public.accept_intercompany_bill(uuid, uuid)');

  if v_src !~ 'd\.due_date' then
    raise exception
      'FAIL 0439: an intercompany bill still copies every figure on the '
      'invoice except the date it falls due';
  end if;
  if v_src !~ 'd\.payment_term_id' then
    raise exception
      'FAIL 0439: the intercompany bill does not carry the terms the '
      'invoice was raised on';
  end if;

  raise notice
    '0439: a document falls due when the parties agreed it would';
end
$do$;
