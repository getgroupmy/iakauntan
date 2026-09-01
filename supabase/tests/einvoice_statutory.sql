-- =====================================================================
-- iAkauntan :: the LHDN rules the e-Invoice tables encode
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/einvoice_statutory.sql
--
-- Two figures in the e-Invoice schema are LHDN's rather than ours, and
-- neither had a test:
--
--   * the 72 hours a supplier has to cancel a validated document, and
--   * EI00000000010, the general public TIN that stands in for a buyer
--     who did not give one.
--
-- 0180 exists solely to restore the comment recording the first of
-- those, and argues that the rule matters because it "is LHDN's limit
-- rather than one this application chose and could therefore relax".
-- Nothing stopped it being relaxed. A comment is not an assertion.
--
-- The third section covers `app.sync_einvoice_status`, the trigger that
-- copies a submission's outcome back onto the document somebody is
-- looking at. It decides what the invoice screen says about LHDN, and
-- it too was named by no test.
--
-- The fourth is the version stamped on the document. `prepare_einvoice`
-- read it straight out of free-form organization settings, which any
-- admin may write, and the column's default was `1.1` -- the signed
-- version -- on a build with no signing step. The fixture below has
-- never named the column, so every row this file made was stamped 1.1.
-- Nobody looked. 0396 puts what the build can produce in one predicate
-- and refuses the rest.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- A document in e-Invoice form, in whatever state the caller needs.
-- Inserted rather than prepared, because `prepare_einvoice` needs a
-- posted sales document and most of what is asserted here is the
-- trigger on the table, not the snapshot that fills it.
create or replace function pg_temp.einvoice_row(
  p_org uuid, p_validated timestamptz, p_status text default 'valid',
  p_source_table text default 'sales_documents', p_source uuid default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.einvoice_documents
    (org_id, source_table, source_id, einvoice_type_code, internal_doc_no,
     issue_date, supplier_name, supplier_tin, buyer_name, buyer_tin,
     status, validated_at)
  values (p_org, p_source_table, coalesce(p_source, gen_random_uuid()),
          '01', 'INV-0001', current_date, 'Penjual Sdn Bhd', 'C1234567890',
          'Pembeli Sdn Bhd', 'C0987654321', p_status::app.einvoice_status, p_validated)
  returning id into v_id;
  return v_id;
end;
$$;

-- A posted sales invoice for one contact, which is what
-- `prepare_einvoice` needs before it will snapshot anything.
create or replace function pg_temp.sales_doc(p_org uuid, p_contact uuid)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', 'INV-' || substr(gen_random_uuid()::text, 1, 8),
          current_date, current_date + 30, p_contact, 'MYR', 1,
          100, 100, 100, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price, line_total)
  values (p_org, v_doc, 1, 'Barang', 1, 100, 100);
  perform public.post_sales_document(v_doc);
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- Seventy-two hours from validation
--
-- Not from issue, and not from submission. A document issued on Monday
-- and validated on Friday may be cancelled until Monday, which is the
-- distinction the column name does not carry and the comment does.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('e-Invoice Sdn Bhd');
  v_doc uuid;
  v_validated timestamptz := timestamptz '2026-03-02 09:15:00+08';
begin
  v_doc := pg_temp.einvoice_row(v_org, v_validated);
  perform pg_temp.check_eq('cancellation closes 72 hours after validation',
    (select cancel_deadline from public.einvoice_documents where id = v_doc)::text,
    (v_validated + interval '72 hours')::text);

  -- Stated again as a wall-clock date, so a change of interval unit —
  -- 72 minutes, 72 days — is caught by something a person can read.
  perform pg_temp.check_eq('which for a Monday morning is the Thursday',
    (select cancel_deadline from public.einvoice_documents where id = v_doc)::text,
    (timestamptz '2026-03-05 09:15:00+08')::text);

  -- Issued weeks earlier and validated late: the clock still starts at
  -- validation.
  update public.einvoice_documents
     set issue_date = date '2026-01-05' where id = v_doc;
  perform pg_temp.check_eq('and does not move when the issue date does',
    (select cancel_deadline from public.einvoice_documents where id = v_doc)::text,
    (v_validated + interval '72 hours')::text);

  -- Validated again — resubmitted after a rejection — and the window
  -- runs from the new validation.
  update public.einvoice_documents
     set validated_at = v_validated + interval '10 days' where id = v_doc;
  perform pg_temp.check_eq('a revalidation restarts it',
    (select cancel_deadline from public.einvoice_documents where id = v_doc)::text,
    (v_validated + interval '10 days' + interval '72 hours')::text);
end $$;

-- ---------------------------------------------------------------------
-- Nothing validated has no deadline
--
-- A queued or rejected document was never accepted, so there is nothing
-- to cancel and no window to be inside or outside of. A zero or a
-- now()-based default here would put every unsubmitted document either
-- permanently cancellable or permanently past its deadline, and the
-- index on (org_id, cancel_deadline) where status = 'valid' is what a
-- screen listing "still cancellable" reads.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Unvalidated Sdn Bhd');
  v_doc uuid;
begin
  v_doc := pg_temp.einvoice_row(v_org, null, 'queued');
  perform pg_temp.check_true('a document never validated has no deadline',
    (select cancel_deadline is null from public.einvoice_documents where id = v_doc));

  update public.einvoice_documents
     set validated_at = now() where id = v_doc;
  perform pg_temp.check_true('validating it gives it one',
    (select cancel_deadline is not null from public.einvoice_documents where id = v_doc));

  update public.einvoice_documents
     set validated_at = null where id = v_doc;
  perform pg_temp.check_true('and withdrawing the validation takes it away again',
    (select cancel_deadline is null from public.einvoice_documents where id = v_doc));
end $$;

-- ---------------------------------------------------------------------
-- The rule is written down as well as enforced
--
-- 0180's argument, which is why this is asserted and not only the
-- arithmetic: `cancel_deadline` is a bare timestamptz on a table full of
-- them, and somebody reading the schema to answer "can this still be
-- cancelled" needs to know both that the clock starts at validation and
-- that the limit is LHDN's. Matched on substrings rather than the whole
-- sentence, so the wording can be improved without failing.
-- ---------------------------------------------------------------------
do $$
declare v_comment text;
begin
  select col_description('public.einvoice_documents'::regclass, a.attnum)
    into v_comment
    from pg_attribute a
   where a.attrelid = 'public.einvoice_documents'::regclass
     and a.attname = 'cancel_deadline';
  perform pg_temp.check_true('the column says whose limit it is',
    v_comment ilike '%LHDN%');
  perform pg_temp.check_true('and how long', v_comment ilike '%72 hours%');
  perform pg_temp.check_true('and what it runs from',
    v_comment ilike '%validation%');
end $$;

-- ---------------------------------------------------------------------
-- EI00000000010, for a buyer who did not give a TIN
--
-- LHDN's general public TIN. A consolidated month of counter sales
-- carries it on every line, so a typo is not one rejected document but
-- a rejected submission.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Kedai Runcit Sdn Bhd');
  v_named uuid; v_walkin uuid; v_doc uuid; v_ein uuid;
begin
  perform pg_temp.check_eq('the general public TIN is LHDN''s literal',
    app.general_public_tin(), 'EI00000000010');

  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  update public.organizations
     set einvoice_enabled = true, tin = 'C1234567890' where id = v_org;

  insert into public.contacts (org_id, code, contact_type, name, tin)
  values (v_org, 'C-NAMED', 'customer', 'Syarikat Berdaftar Sdn Bhd', 'C5555555555')
  returning id into v_named;
  insert into public.contacts (org_id, code, contact_type, name)
  values (v_org, 'C-WALKIN', 'customer', 'Pelanggan kaunter') returning id into v_walkin;

  -- A buyer who gave one keeps it. Asserted first, because a
  -- `prepare_einvoice` that stamped the general public TIN on every
  -- document would satisfy the fallback assertion below on its own.
  v_doc := pg_temp.sales_doc(v_org, v_named);
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq('a buyer who gave a TIN keeps it',
    (select buyer_tin from public.einvoice_documents where id = v_ein),
    'C5555555555');

  -- One who did not gets the general public TIN rather than a blank,
  -- which LHDN rejects.
  v_doc := pg_temp.sales_doc(v_org, v_walkin);
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq('a walk-in gets the general public TIN',
    (select buyer_tin from public.einvoice_documents where id = v_ein),
    app.general_public_tin());

  -- An empty string is the same as absent. The contact editor writes
  -- one when somebody tabs through the field, and `''` submitted as a
  -- TIN is rejected exactly as a null would be.
  update public.contacts set tin = '' where id = v_walkin;
  v_doc := pg_temp.sales_doc(v_org, v_walkin);
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq('and so does a TIN typed as an empty string',
    (select buyer_tin from public.einvoice_documents where id = v_ein),
    app.general_public_tin());
end $$;

-- ---------------------------------------------------------------------
-- What LHDN said, shown on the document somebody is looking at
--
-- `app.sync_einvoice_status` copies the submission's outcome back onto
-- the sales or purchase document. It is the whole of what the invoice
-- screen knows about LHDN, and every branch of it was unasserted.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Status Sdn Bhd');
  v_contact uuid; v_doc uuid; v_ein uuid;
  v_state text;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  update public.organizations
     set einvoice_enabled = true, tin = 'C1234567890' where id = v_org;
  insert into public.contacts (org_id, code, contact_type, name, tin)
  values (v_org, 'C-1', 'customer', 'Pembeli Sdn Bhd', 'C1111111111') returning id into v_contact;
  v_doc := pg_temp.sales_doc(v_org, v_contact);
  v_ein := public.prepare_einvoice(v_doc);

  foreach v_state in array array['submitted','valid','invalid','rejected','cancelled'] loop
    update public.einvoice_documents set status = v_state::app.einvoice_status where id = v_ein;
    perform pg_temp.check_eq('the invoice shows ' || v_state,
      (select einvoice_status from public.sales_documents where id = v_doc), v_state);
  end loop;

  -- Anything else — a status the submission is passing through rather
  -- than an outcome — reads as pending rather than as the last outcome,
  -- so a resubmission does not leave "valid" on screen while LHDN is
  -- still deciding.
  update public.einvoice_documents set status = 'queued'::app.einvoice_status where id = v_ein;
  perform pg_temp.check_eq('and anything in between reads as pending',
    (select einvoice_status from public.sales_documents where id = v_doc), 'pending');

  -- A document edited without its status moving leaves the invoice
  -- alone. Two things stop it and either would do on its own: the
  -- trigger is declared `after update of status`, and the function
  -- checks the status actually changed. So this assertion pins the
  -- pair rather than one of them — removing both is what makes it
  -- fail, and removing either alone does not.
  update public.sales_documents set einvoice_status = 'valid' where id = v_doc;
  update public.einvoice_documents set internal_doc_no = 'INV-RENAMED' where id = v_ein;
  perform pg_temp.check_eq('an edit that is not a status change touches nothing',
    (select einvoice_status from public.sales_documents where id = v_doc), 'valid');
end $$;

-- ---------------------------------------------------------------------
-- And the same for a bill
--
-- The trigger has a second branch for `purchase_documents`, reached
-- when a supplier's self-billed document is submitted. It is the same
-- mapping written out twice, which is exactly the shape that rots: a
-- status added to one branch and not the other leaves half the
-- application showing an outcome LHDN never returned.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Bil Sdn Bhd');
  v_supplier uuid; v_bill uuid; v_ein uuid; v_state text;
begin
  insert into public.contacts (org_id, code, contact_type, name, tin)
  values (v_org, 'S-1', 'supplier', 'Pembekal Sdn Bhd', 'C2222222222')
  returning id into v_supplier;
  insert into public.purchase_documents (org_id, doc_type, doc_no, contact_id)
  values (v_org, 'bill', 'BILL-0001', v_supplier) returning id into v_bill;

  v_ein := pg_temp.einvoice_row(v_org, null, 'queued', 'purchase_documents', v_bill);

  foreach v_state in array array['submitted','valid','invalid','rejected','cancelled'] loop
    update public.einvoice_documents
       set status = v_state::app.einvoice_status where id = v_ein;
    perform pg_temp.check_eq('the bill shows ' || v_state,
      (select einvoice_status from public.purchase_documents where id = v_bill), v_state);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- A version this build cannot sign
--
-- The version on a document is a claim about that document. Version 1.1
-- is the one carrying an XAdES signature from a Malaysian certificate
-- authority; 0015's own comment on the certificate columns says so and
-- README says the signing step is not implemented. A document stamped
-- 1.1 with no signature in it is not a rejected filing, it is a filed
-- one with a false statement of what it is.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Versi Sdn Bhd');
  v_contact uuid; v_doc uuid; v_ein uuid; v_msg text;
begin
  perform pg_temp.check_true('1.0 is what this build produces',
    app.einvoice_version_supported('1.0'));
  perform pg_temp.check_true('and 1.1 is not, while nothing signs',
    not app.einvoice_version_supported('1.1'));

  -- The default `0007` set the other way round. This fixture has never
  -- named the column, which is how a test suite came to be full of
  -- documents claiming the signed version.
  v_ein := pg_temp.einvoice_row(v_org, null);
  perform pg_temp.check_eq('a row that does not name a version gets 1.0',
    (select einvoice_version from public.einvoice_documents where id = v_ein),
    '1.0');

  -- Written straight to the table, which is the path a future insert or
  -- an incident fix would take.
  begin
    update public.einvoice_documents
       set einvoice_version = '1.1' where id = v_ein;
    raise exception 'FAIL: a document was stamped 1.1 with nothing to sign it';
  exception when sqlstate '0A000' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and the refusal names the signature',
      v_msg like '%XAdES signature%');
    raise notice 'ok   a version this build cannot sign is refused';
  end;
  perform pg_temp.check_eq('and the document is unchanged',
    (select einvoice_version from public.einvoice_documents where id = v_ein),
    '1.0');

  -- Not only 1.1. The settings key is free-form text and anything in it
  -- was going onto a tax document verbatim.
  begin
    update public.einvoice_documents
       set einvoice_version = 'banana' where id = v_ein;
    raise exception 'FAIL: an arbitrary string was accepted as a version';
  exception when sqlstate '0A000' then
    raise notice 'ok   and so is anything else somebody types';
  end;

  -- End to end: the settings key an admin can write, through
  -- prepare_einvoice, which is where it actually gets on the document.
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  update public.organizations
     set einvoice_enabled = true, tin = 'C1234567890',
         settings = coalesce(settings, '{}'::jsonb)
                    || jsonb_build_object('einvoice_version', '1.1')
   where id = v_org;
  insert into public.contacts (org_id, code, contact_type, name, tin)
  values (v_org, 'C-1', 'customer', 'Pembeli Sdn Bhd', 'C1111111111')
  returning id into v_contact;
  v_doc := pg_temp.sales_doc(v_org, v_contact);
  begin
    perform public.prepare_einvoice(v_doc);
    raise exception
      'FAIL: an organization setting put 1.1 on a document with no signature';
  exception when sqlstate '0A000' then
    raise notice 'ok   nor can an organization setting reach it';
  end;
  perform pg_temp.check_eq('and no document was prepared',
    (select count(*) from public.einvoice_documents
      where source_id = v_doc), 0);

  -- The constraint and the trigger read the same predicate, so no
  -- behaviour can tell them apart: dropping the constraint leaves every
  -- assertion above passing, which the mutation run confirmed. That is
  -- why both are asserted structurally rather than inferred. The
  -- trigger is the sentence somebody reads; the constraint is the
  -- invariant a schema dump shows and a future migration has to remove
  -- on purpose.
  perform pg_temp.check_eq('the invariant is declared on the table',
    (select count(*) from pg_constraint
      where conrelid = 'public.einvoice_documents'::regclass
        and conname = 'einvoice_documents_version_supported'), 1);
  perform pg_temp.check_eq('and the trigger that explains it is there too',
    (select count(*) from pg_trigger
      where tgrelid = 'public.einvoice_documents'::regclass
        and tgname = 'check_einvoice_version' and not tgisinternal), 1);

  -- With the setting removed it prepares, at the version the build can
  -- actually produce. Asserted so the guard is shown to refuse the one
  -- case and not the whole feature.
  update public.organizations set settings = settings - 'einvoice_version'
   where id = v_org;
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq('the ordinary case still prepares, at 1.0',
    (select einvoice_version from public.einvoice_documents where id = v_ein),
    '1.0');
end $$;

-- ---------------------------------------------------------------------
-- What the business does, which every document said was `NA`
--
-- organizations.business_activity was written by nothing:
-- create_organization takes the parameter and the onboarding form does
-- not pass it, and updateCompanyDetails writes msic_code and omits this
-- column beside it. ubl.ts emits `name: businessActivity || "NA"`, so
-- every e-Invoice from every company told LHDN `NA` -- while
-- ref_msic_codes has held the description of that very code since 0002.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Sawit Sdn Bhd');
  v_contact uuid; v_doc uuid; v_ein uuid;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  update public.organizations
     set einvoice_enabled = true, tin = 'C1234567890',
         msic_code = '01261', business_activity = null
   where id = v_org;
  insert into public.contacts (org_id, code, contact_type, name, tin)
  values (v_org, 'C-1', 'customer', 'Pembeli Sdn Bhd', 'C1111111111')
  returning id into v_contact;

  perform pg_temp.check_eq('the description comes from the picked code',
    app.business_activity_of(v_org), 'Growing of oil palm (estate)');

  v_doc := pg_temp.sales_doc(v_org, v_contact);
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq('and it reaches the document',
    (select supplier_business_activity from public.einvoice_documents
      where id = v_ein), 'Growing of oil palm (estate)');

  -- A company that has said what it does in its own words keeps them.
  update public.organizations
     set business_activity = 'Oil palm, smallholder' where id = v_org;
  perform pg_temp.check_eq('an organization''s own wording wins',
    app.business_activity_of(v_org), 'Oil palm, smallholder');
  v_doc := pg_temp.sales_doc(v_org, v_contact);
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq('and that is what is filed',
    (select supplier_business_activity from public.einvoice_documents
      where id = v_ein), 'Oil palm, smallholder');

  -- A caller that supplies one is believed, the same way 0393's
  -- set_filed_by believes a caller that names somebody: an import knows
  -- what the company did at the time better than today's reference list
  -- does. Without this the trigger could overwrite it and nothing would
  -- notice.
  insert into public.einvoice_documents
    (org_id, source_table, source_id, einvoice_type_code, internal_doc_no,
     issue_date, supplier_name, supplier_tin, supplier_business_activity,
     buyer_name, buyer_tin, status)
  values (v_org, 'sales_documents', gen_random_uuid(), '01', 'INV-HIST',
          current_date, 'Sawit Sdn Bhd', 'C1234567890',
          'What it did in 2019', 'Pembeli Sdn Bhd', 'C1111111111',
          'valid')
  returning id into v_ein;
  perform pg_temp.check_eq('an activity given on the row is kept',
    (select supplier_business_activity from public.einvoice_documents
      where id = v_ein), 'What it did in 2019');

  -- But a blank on the row is not a given one. prepare_einvoice inserts
  -- the organization's column straight through, so an organization
  -- holding '' would put '' on the document -- and ubl.ts renders that
  -- as `NA`, which is the whole defect coming back by a side door.
  insert into public.einvoice_documents
    (org_id, source_table, source_id, einvoice_type_code, internal_doc_no,
     issue_date, supplier_name, supplier_tin, supplier_business_activity,
     buyer_name, buyer_tin, status)
  values (v_org, 'sales_documents', gen_random_uuid(), '01', 'INV-BLANK',
          current_date, 'Sawit Sdn Bhd', 'C1234567890', '   ',
          'Pembeli Sdn Bhd', 'C1111111111', 'valid')
  returning id into v_ein;
  perform pg_temp.check_eq('a blank on the row is filled in, not left',
    (select supplier_business_activity from public.einvoice_documents
      where id = v_ein), 'Oil palm, smallholder');

  -- Blank is not a wording. The company card writes '' when somebody
  -- tabs through a field, and '' on a document is `NA` with extra steps.
  update public.organizations set business_activity = '   ' where id = v_org;
  perform pg_temp.check_eq('a blank falls back to the code''s description',
    app.business_activity_of(v_org), 'Growing of oil palm (estate)');

  -- No code and no wording is genuinely nothing to say, and ubl.ts
  -- emits no classification block at all without a code -- so null here
  -- is right and must not become the literal 'NA'.
  update public.organizations
     set msic_code = null, business_activity = null where id = v_org;
  perform pg_temp.check_true('nothing said stays nothing, not the word NA',
    app.business_activity_of(v_org) is null);
  v_doc := pg_temp.sales_doc(v_org, v_contact);
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_true('and the document carries no activity either',
    (select supplier_business_activity from public.einvoice_documents
      where id = v_ein) is null);
end $$;

rollback;
