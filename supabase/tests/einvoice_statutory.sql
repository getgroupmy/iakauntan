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

-- A posted document of any type, for the parts of `prepare_einvoice`
-- that depend on which type it is. `pg_temp.sales_doc` above makes an
-- invoice and nothing else, which is why every type-code mutation
-- survived the sweep this block answers.
create or replace function pg_temp.typed_doc(
  p_org uuid, p_contact uuid, p_type text, p_post boolean default true)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, p_type::app.sales_doc_type,
          upper(left(p_type, 3)) || '-' || substr(gen_random_uuid()::text, 1, 8),
          current_date, current_date + 30, p_contact, 'MYR', 1,
          100, 100, 100, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price, line_total)
  values (p_org, v_doc, 1, 'Barang', 1, 100, 100);
  if p_post then
    update public.sales_documents set status = 'posted' where id = v_doc;
  end if;
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

-- ---------------------------------------------------------------------
-- The thirty-four a mutation sweep found
--
-- Fifty-one one-line mutants of `prepare_einvoice` against fifty-one
-- test files -- every file that touches a sale can reach this function.
-- Seventeen died. That is the worst ratio of this programme, and it is
-- on the one function whose output is a statutory filing.
--
-- Every mutant that died is a MONEY TOTAL or the buyer TIN. Those two
-- were asserted well: the tax, the discount, the charges, the rounding,
-- the payable amount, the exempted amount, the general public TIN and
-- its blank-string case all had tests. Nothing else did.
--
-- Including all four DOCUMENT TYPE CODES. An invoice could be submitted
-- as `02` and be a credit note in LHDN's records -- the customer's
-- return would show a credit they never received, against a sale that
-- was never reported. Every figure on it would be right.
--
-- The rest divide into what is snapshotted about the two parties, and
-- what a RESUBMISSION does. The second matters because a rejected
-- document is fixed and sent again, and every field the ON CONFLICT
-- branch does not refresh is the old attempt's answer sent as the new
-- one.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Sapu e-Invois Sdn Bhd');
  v_boss uuid; v_other uuid;
  v_buyer uuid; v_bare uuid; v_doc uuid; v_ein uuid; v_msg text;
  v_item uuid; v_tax uuid;
begin
  v_boss := (select user_id from public.org_members
              where org_id = v_org and role = 'owner' limit 1);
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  update public.organizations
     set einvoice_enabled = true,
         tin              = 'C1111111111',
         einvoice_tin     = 'C2222222222',
         legal_name       = 'Sapu e-Invois Sendirian Berhad',
         registration_no  = '202601000001',
         einvoice_id_type = null,
         einvoice_id_value = null
   where id = v_org;

  insert into public.contacts
    (org_id, code, contact_type, name, legal_name, tin, registration_no)
  values (v_org, 'C-1', 'customer', 'Pembeli', 'Pembeli Sendirian Berhad',
          'C3333333333', '202601000002')
  returning id into v_buyer;
  -- A buyer with nothing but a name, for the last-resort fallbacks.
  insert into public.contacts (org_id, code, contact_type, name)
  values (v_org, 'C-2', 'customer', 'Kaunter') returning id into v_bare;

  -- ==================================================================
  -- 1. Which document LHDN is being told about
  --
  -- The codes are LHDN's: 01 invoice, 02 credit note, 03 debit note,
  -- 04 refund note. Asserted as a set rather than one at a time,
  -- because any single one of them could otherwise be swapped for
  -- another and the assertion for the swapped-to code would still pass.
  -- ==================================================================
  -- prepare_einvoice is assigned to a variable and never called from a
  -- WHERE clause: it is volatile, so the planner may invoke it once per
  -- row scanned, and the second invocation meets its own already-queued
  -- guard.
  v_doc := pg_temp.typed_doc(v_org, v_buyer, 'invoice');
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq('an invoice is submitted as 01',
    (select einvoice_type_code from public.einvoice_documents
      where id = v_ein), '01');

  v_doc := pg_temp.typed_doc(v_org, v_buyer, 'credit_note');
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq('a credit note as 02',
    (select einvoice_type_code from public.einvoice_documents
      where id = v_ein), '02');

  v_doc := pg_temp.typed_doc(v_org, v_buyer, 'debit_note');
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq('a debit note as 03',
    (select einvoice_type_code from public.einvoice_documents
      where id = v_ein), '03');

  v_doc := pg_temp.typed_doc(v_org, v_buyer, 'refund_note');
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq('and a refund note as 04',
    (select einvoice_type_code from public.einvoice_documents
      where id = v_ein), '04');

  -- A quotation is not a document LHDN receives at all.
  v_doc := pg_temp.typed_doc(v_org, v_buyer, 'quotation');
  begin
    perform public.prepare_einvoice(v_doc);
    raise exception 'a quotation was submitted to LHDN';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a quotation is not an e-Invoice document',
      v_msg like 'Document type quotation is not an e-Invoice document');
  end;

  -- ==================================================================
  -- 2. The front door
  -- ==================================================================
  v_doc := pg_temp.typed_doc(v_org, v_buyer, 'invoice', false);
  begin
    perform public.prepare_einvoice(v_doc);
    raise exception 'a draft was submitted to LHDN';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a draft is posted before it is submitted',
      v_msg like 'Post %  before submitting it to MyInvois'
        or v_msg like 'Post % before submitting it to MyInvois');
  end;

  begin
    perform public.prepare_einvoice(gen_random_uuid());
    raise exception 'an e-Invoice was prepared for nothing';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a document that does not exist',
      v_msg like 'Sales document % not found');
  end;

  v_other := pg_temp.another_user('reader@einvois.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_other, 'viewer');
  perform pg_temp.sign_in_as(v_other);
  v_doc := pg_temp.typed_doc(v_org, v_buyer, 'invoice');
  begin
    perform public.prepare_einvoice(v_doc);
    v_msg := null;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_eq('somebody who may not write may not submit',
    v_msg, 'Insufficient privileges');

  -- ==================================================================
  -- 3. Who the seller says it is
  --
  -- All fallbacks, and every one of them the kind that is right in
  -- every test because every test uses the default. The e-Invoice TIN
  -- is the one that matters most: a company that files under a TIN
  -- different from the one on its ordinary record has said so in the
  -- e-Invoice settings, and ignoring it files the whole year under the
  -- wrong taxpayer.
  -- ==================================================================
  v_doc := pg_temp.typed_doc(v_org, v_buyer, 'invoice');
  v_ein := public.prepare_einvoice(v_doc);

  perform pg_temp.check_eq('the seller files under its e-Invoice TIN',
    (select supplier_tin from public.einvoice_documents where id = v_ein),
    'C2222222222');
  perform pg_temp.check_eq('under its legal name, not its trading one',
    (select supplier_name from public.einvoice_documents where id = v_ein),
    'Sapu e-Invois Sendirian Berhad');
  perform pg_temp.check_eq('identified by BRN when it says nothing else',
    (select supplier_id_type from public.einvoice_documents where id = v_ein),
    'BRN');
  perform pg_temp.check_eq('and by its registration number',
    (select supplier_id_value from public.einvoice_documents where id = v_ein),
    '202601000001');

  -- And the guard on the TIN reads the same pair. A company with an
  -- e-Invoice TIN and no ordinary one is a company that can file.
  declare
    v_org2 uuid; v_c2 uuid; v_d2 uuid; v_e2 uuid;
  begin
    v_org2 := pg_temp.test_org('Only e-Invois TIN Sdn Bhd');
    perform public.create_fiscal_year(v_org2, date_trunc('year', current_date)::date);
    update public.organizations
       set einvoice_enabled = true, tin = null, einvoice_tin = 'C9999999999'
     where id = v_org2;
    insert into public.contacts (org_id, code, contact_type, name)
    values (v_org2, 'C-1', 'customer', 'Pembeli') returning id into v_c2;
    v_d2 := pg_temp.typed_doc(v_org2, v_c2, 'invoice');
    v_e2 := public.prepare_einvoice(v_d2);
    perform pg_temp.check_eq(
      'a company with only an e-Invoice TIN may still file',
      (select supplier_tin from public.einvoice_documents
        where id = v_e2), 'C9999999999');

    -- With neither, it may not.
    update public.organizations set einvoice_tin = null where id = v_org2;
    v_d2 := pg_temp.typed_doc(v_org2, v_c2, 'invoice');
    begin
      perform public.prepare_einvoice(v_d2);
      raise exception 'a company with no TIN filed anyway';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.check_eq('and with neither it may not',
        v_msg, 'Set the organization TIN before submitting e-Invoices');
    end;

    -- Nor may one that never turned e-Invoice on.
    update public.organizations
       set einvoice_tin = 'C9999999999', einvoice_enabled = false
     where id = v_org2;
    v_d2 := pg_temp.typed_doc(v_org2, v_c2, 'invoice');
    begin
      perform public.prepare_einvoice(v_d2);
      raise exception 'a company that never enabled e-Invoice submitted one';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.check_eq('nor one that never turned e-Invoice on',
        v_msg, 'e-Invoice is not enabled for this organization');
    end;
  end;

  -- ==================================================================
  -- 4. Who the buyer is said to be
  -- ==================================================================
  perform pg_temp.check_eq('the buyer is named by its legal name',
    (select buyer_name from public.einvoice_documents where id = v_ein),
    'Pembeli Sendirian Berhad');
  perform pg_temp.check_eq('identified by BRN when it says nothing else',
    (select buyer_id_type from public.einvoice_documents where id = v_ein),
    'BRN');
  perform pg_temp.check_eq('and by its registration number',
    (select buyer_id_value from public.einvoice_documents where id = v_ein),
    '202601000002');

  -- A buyer with no registration number at all still needs an
  -- identifier: LHDN takes 'NA', and takes nothing else, so a null
  -- here is a rejected submission.
  v_doc := pg_temp.typed_doc(v_org, v_bare, 'invoice');
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq('a buyer with no number is identified as NA',
    (select buyer_id_value from public.einvoice_documents
      where id = v_ein), 'NA');

  -- ==================================================================
  -- 5. What the lines say
  -- ==================================================================
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, classification_code)
  values (v_org, 'ITM', 'Barang Berdaftar', 'stock', false, 'KGM', 7,
          '004')
  returning id into v_item;

  v_doc := pg_temp.typed_doc(v_org, v_buyer, 'invoice');
  update public.sales_document_lines
     set item_id = v_item, description = '', uom_code = null,
         classification_code = null, quantity = 3, unit_price = 7
   where document_id = v_doc;
  -- A second line that is not an item: LHDN receives the goods and
  -- services, not the comment somebody typed between them.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, unit_price, line_total)
  values (v_org, v_doc, 2, 'description', 'Terima kasih', 0, 0, 0);
  v_ein := public.prepare_einvoice(v_doc);

  perform pg_temp.check_eq('only the item lines are submitted',
    (select count(*) from public.einvoice_lines where einvoice_id = v_ein), 1);
  perform pg_temp.check_eq(
    'a line with no classification takes the item''s',
    (select classification_code from public.einvoice_lines
      where einvoice_id = v_ein), '004');
  perform pg_temp.check_eq('a blank description takes the item''s name',
    (select description from public.einvoice_lines where einvoice_id = v_ein),
    'Barang Berdaftar');
  perform pg_temp.check_eq('and a blank unit of measure takes the item''s',
    (select uom_code from public.einvoice_lines where einvoice_id = v_ein),
    'KGM');
  perform pg_temp.check_eq('the line subtotal is quantity times price',
    (select subtotal from public.einvoice_lines where einvoice_id = v_ein), 21);
  -- A reason belongs to an exemption, not to a tax code. The guard is
  -- `case when t.is_exempt then t.exemption_reason else null end`, and
  -- the case it exists for is a code that CARRIES a reason and is not
  -- exempt -- which is what a code edited from exempt to standard
  -- leaves behind, its old wording still in the column. Declared on a
  -- taxable line, it tells LHDN a sale was relieved of tax that was
  -- charged on it.
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, is_exempt, exemption_reason)
  values (v_org, 'SST-WAS-EX', 'Was exempt, now standard', '01', 6, false,
          'Exempted under Schedule A')
  returning id into v_tax;

  v_doc := pg_temp.typed_doc(v_org, v_buyer, 'invoice');
  update public.sales_document_lines
     set tax_code_id = v_tax where document_id = v_doc;
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_true('a line that is not exempt gives no reason',
    (select tax_exemption_reason is null from public.einvoice_lines
      where einvoice_id = v_ein));
  perform pg_temp.check_eq('and declares nothing exempted',
    (select tax_exempted_amount from public.einvoice_lines
      where einvoice_id = v_ein), 0::numeric);

  -- The lines are submitted in the order they are numbered. The ORDER
  -- BY on the insert is EQUIVALENT and is the ninth of this programme:
  -- einvoice_lines carries l.line_no across, and every reader orders by
  -- it, so the order rows were inserted in cannot be observed. Left in
  -- place because it is what makes that true -- a later change taking
  -- the line number from a sequence instead would need it. The
  -- assertion below is of the numbering, which is the thing a customer
  -- matching the government copy against their own actually reads.
  v_doc := pg_temp.typed_doc(v_org, v_buyer, 'invoice');
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price, line_total)
  values (v_org, v_doc, 2, 'Kedua', 1, 50, 50),
         (v_org, v_doc, 3, 'Ketiga', 1, 25, 25);
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq('the lines are submitted in their own order',
    (select string_agg(description, ',' order by line_no)
       from public.einvoice_lines where einvoice_id = v_ein),
    'Barang,Kedua,Ketiga');

  -- ==================================================================
  -- 6. What a resubmission is
  --
  -- A rejected document is corrected and sent again, onto the same row.
  -- Every field the ON CONFLICT branch does not refresh is the old
  -- attempt's answer sent as the new one -- and the errors it does not
  -- clear are last time's complaints shown against this time's figures.
  -- ==================================================================
  v_doc := pg_temp.typed_doc(v_org, v_buyer, 'invoice');
  v_ein := public.prepare_einvoice(v_doc);
  update public.einvoice_documents
     set status            = 'invalid',
         validation_errors = '[{"code":"CF321","message":"Wrong TIN"}]'::jsonb,
         error_code        = 'CF321',
         error_message     = 'Wrong TIN'
   where id = v_ein;
  -- Corrected, and the totals with it.
  update public.sales_documents
     set subtotal = 250, total_amount = 250, tax_amount = 15,
         balance_amount = 250
   where id = v_doc;

  perform pg_temp.check_eq('a resubmission lands on the same row',
    public.prepare_einvoice(v_doc), v_ein);
  perform pg_temp.check_eq('and is queued again',
    (select status::text from public.einvoice_documents where id = v_ein),
    'queued');
  perform pg_temp.check_eq('carrying the corrected total',
    (select total_incl_tax from public.einvoice_documents where id = v_ein), 250);
  perform pg_temp.check_eq('and the corrected tax',
    (select total_tax from public.einvoice_documents where id = v_ein), 15);
  perform pg_temp.check_true('with last time''s complaints cleared',
    (select validation_errors = '[]'::jsonb and error_code is null
        and error_message is null
       from public.einvoice_documents where id = v_ein));
  perform pg_temp.check_eq('and last time''s lines gone rather than doubled',
    (select count(*) from public.einvoice_lines where einvoice_id = v_ein), 1);

  -- A document already accepted by LHDN is immutable. It is cancelled,
  -- not overwritten -- and the same is true of one still in flight,
  -- because sending a second copy of a document under submission is
  -- how a duplicate gets validated.
  update public.einvoice_documents set status = 'valid' where id = v_ein;
  begin
    perform public.prepare_einvoice(v_doc);
    raise exception 'a validated e-Invoice was overwritten';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a validated e-Invoice cannot be replaced',
      v_msg like 'e-Invoice for % is already valid');
  end;

  update public.einvoice_documents set status = 'submitted' where id = v_ein;
  begin
    perform public.prepare_einvoice(v_doc);
    raise exception 'a submitted e-Invoice was overwritten';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('nor one still with LHDN',
      v_msg like 'e-Invoice for % is already submitted');
  end;

  update public.einvoice_documents set status = 'queued' where id = v_ein;
  begin
    perform public.prepare_einvoice(v_doc);
    raise exception 'a queued e-Invoice was overwritten';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('nor one already waiting to go',
      v_msg like 'e-Invoice for % is already queued');
  end;

  -- The lookup is by TYPE as well as by document. A credit note against
  -- an invoice is a different filing, and finding the invoice's row in
  -- its place would refuse the credit note as already sent.
  --
  -- The type in that predicate is EQUIVALENT today and is the eighth of
  -- this programme: it separates two rows sharing one source_id, and a
  -- source_id cannot change type, because doc_type is one of the
  -- columns `refuse_posted_document_change` freezes and only a posted
  -- document reaches here. It is kept as the correctness of the lookup
  -- rather than as a live guard. The assertion below is of the
  -- behaviour it exists to protect, reached the way it actually
  -- happens: a separate credit note, filed while the invoice's own
  -- submission stands validated.
  update public.einvoice_documents set status = 'valid' where id = v_ein;
  -- Its own credit note, raised against this invoice's customer and
  -- never submitted, so the only row that could block it is the
  -- invoice's -- which is what the type in the lookup is there to stop.
  declare v_cn uuid; v_ce uuid;
  begin
    v_cn := pg_temp.typed_doc(v_org, v_buyer, 'credit_note');
    v_ce := public.prepare_einvoice(v_cn);
    perform pg_temp.check_eq(
      'a credit note is not blocked by an invoice already filed',
      (select einvoice_type_code from public.einvoice_documents
        where id = v_ce), '02');
  end;

  -- ==================================================================
  -- 7. And the document knows what was sent
  -- ==================================================================
  v_doc := pg_temp.typed_doc(v_org, v_buyer, 'invoice');
  v_ein := public.prepare_einvoice(v_doc);
  perform pg_temp.check_eq('the document points at what was queued',
    (select einvoice_id from public.sales_documents where id = v_doc), v_ein);
  perform pg_temp.check_eq('and reads as pending until LHDN answers',
    (select einvoice_status from public.sales_documents where id = v_doc),
    'pending');

  raise notice 'ok   e-Invoice: the thirty-four a sweep found';
end $$;


rollback;
