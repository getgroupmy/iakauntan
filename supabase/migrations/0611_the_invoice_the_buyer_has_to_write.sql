-- =====================================================================
-- iAkauntan :: 0611 the invoice the buyer has to write
--
-- README: "Self-billed e-Invoice for foreign suppliers: schema supports
-- it, no UI." The schema half is real -- `ref_einvoice_types` has had
-- codes 11 to 14 since `0011`, `purchase_documents.requires_self_billed`
-- since `0006`, `einvoice_documents.is_self_billed` since `0007` -- and
-- it has never been reachable, because the only thing that ever built an
-- `einvoice_documents` row was `prepare_einvoice`, which takes a SALES
-- document.
--
-- ---------------------------------------------------------------------
-- What a self-billed e-Invoice is
--
-- Normally the seller issues the e-Invoice. Where the seller cannot --
-- a foreign supplier outside MyInvois, an individual who is not
-- registered, a payout to somebody who issues no invoice at all -- LHDN
-- requires the BUYER to issue one on their behalf. A Malaysian company
-- buying software from abroad owes LHDN an e-Invoice for a supply it
-- did not make.
--
-- ---------------------------------------------------------------------
-- The one thing that is easy to get backwards
--
-- The Supplier block still holds the SUPPLIER. It does not swap.
--
-- On a sale, `prepare_einvoice` puts our company in the supplier block
-- and the customer in the buyer block, because we are the seller. The
-- obvious mirror -- put the supplier where the customer was -- is
-- wrong in both halves: on a self-billed invoice we are the BUYER, so
-- our company goes in the buyer block, and the foreign supplier goes in
-- the supplier block, which is the same block it would have used if it
-- could have filed the document itself.
--
-- Getting it backwards produces a document that validates, balances,
-- and reports our own company as the vendor of a supply we bought.
-- `self_billed_einvoice.sql` asserts both blocks by name, in both
-- directions, because "it is the other way round from the sales one"
-- is exactly the sort of thing that is half-remembered.
--
-- ---------------------------------------------------------------------
-- A TIN this does not invent
--
-- A foreign supplier has no Malaysian TIN. LHDN publishes general TINs
-- for cases like this -- `0481` already records that `EI00000000010` is
-- the general public one and that 020, 040 and 030 exist -- and which
-- of them applies to a foreign supplier is not something this migration
-- knows well enough to hardcode into a statutory submission.
--
-- So it refuses, and the refusal names the field: put the TIN LHDN told
-- you to use on the supplier's contact record. A wrong TIN on a filed
-- document is worse than a document that would not file.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Which bills need one
--
-- A bill from a supplier outside Malaysia, unless somebody has said
-- otherwise. `requires_self_billed` has been a column since `0006` and
-- nothing has ever set it, so every bill in every database is `false` --
-- including the ones that owe LHDN a document.
--
-- Set on INSERT only, and only where the caller left it alone, so that
-- turning it off on a particular bill stays off. A company that buys
-- from a Malaysian supplier is untouched, which is almost every bill.
-- ---------------------------------------------------------------------
create or replace function app.suggest_self_billed()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_country text;
begin
  if new.requires_self_billed then
    return new;
  end if;
  if new.doc_type not in ('bill', 'purchase_credit_note',
                          'purchase_debit_note') then
    return new;
  end if;

  select c.country_code into v_country
    from public.contacts c where c.id = new.contact_id;

  -- Null country is not "foreign", and today it cannot happen:
  -- `contacts.country_code` is `not null default 'MYS'` and
  -- `purchase_documents.contact_id` is not null either, so the select
  -- above always finds a row with a country on it. The schema has
  -- already made the decision this branch would make.
  --
  -- It stays anyway. The cost is one comparison; the cost of it not
  -- being here, if either column is ever relaxed, is every bill in the
  -- database silently acquiring an e-Invoice obligation -- because
  -- `null <> 'MYS'` is null, which is not true, but `upper(null) <>
  -- 'MYS'` reads to a person as though it were. `self_billed_einvoice.sql`
  -- asserts the schema's half rather than this one, and says so.
  if v_country is not null and upper(v_country) <> 'MYS' then
    new.requires_self_billed := true;
  end if;

  return new;
end;
$function$;

comment on function app.suggest_self_billed() is
  'Marks a bill from a supplier outside Malaysia as owing a self-billed '
  'e-Invoice. On insert only, and only where the caller did not say, so '
  'switching it off on one bill stays off. 0611.';

drop trigger if exists suggest_self_billed on public.purchase_documents;
create trigger suggest_self_billed
  before insert on public.purchase_documents
  for each row execute function app.suggest_self_billed();

-- ---------------------------------------------------------------------
-- Saying so by hand
--
-- The trigger reads the supplier's country, which is right for the
-- common case and not the only case: an unregistered individual in
-- Malaysia owes one too, and a supplier who has since registered does
-- not. Somebody has to be able to say.
-- ---------------------------------------------------------------------
create or replace function public.set_requires_self_billed(
  p_document_id uuid,
  p_required boolean)
returns boolean
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_doc public.purchase_documents;
begin
  select * into v_doc from public.purchase_documents where id = p_document_id;
  if not found then
    raise exception 'Purchase document % not found', p_document_id
      using errcode = 'P0002';
  end if;
  if not app.can_write(v_doc.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if v_doc.einvoice_status in ('submitted', 'valid') then
    raise exception 'This bill''s self-billed e-Invoice is already with '
                    'LHDN. Cancel it there before changing whether one '
                    'is owed.'
      using errcode = '55000';
  end if;

  update public.purchase_documents
     set requires_self_billed = coalesce(p_required, false)
   where id = p_document_id;
  return true;
end;
$function$;

comment on function public.set_requires_self_billed(uuid, boolean) is
  'Says whether a bill owes LHDN a self-billed e-Invoice. Refuses once '
  'one has been submitted -- that is cancelled at MyInvois, not '
  'un-ticked here. 0611.';

revoke all on function public.set_requires_self_billed(uuid, boolean)
  from public, anon;
grant execute on function public.set_requires_self_billed(uuid, boolean)
  to authenticated;

-- ---------------------------------------------------------------------
-- Preparing one
--
-- The mirror of `prepare_einvoice`, and the blocks do not swap: the
-- supplier block holds the supplier and the buyer block holds us,
-- because on a self-billed document WE are the buyer. See the header.
-- ---------------------------------------------------------------------
create or replace function public.prepare_self_billed_einvoice(
  p_purchase_document_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_doc      public.purchase_documents;
  v_org      public.organizations;
  v_supplier public.contacts;
  v_type     text;
  v_ei_id    uuid;
  v_existing public.einvoice_documents;
begin
  select * into v_doc from public.purchase_documents
   where id = p_purchase_document_id;
  if not found then
    raise exception 'Purchase document % not found', p_purchase_document_id
      using errcode = 'P0002';
  end if;
  if not app.can_write(v_doc.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select * into v_org from public.organizations where id = v_doc.org_id;
  select * into v_supplier from public.contacts where id = v_doc.contact_id;

  if not v_org.einvoice_enabled then
    raise exception 'e-Invoice is not enabled for this company';
  end if;
  if coalesce(v_org.einvoice_tin, v_org.tin) is null then
    raise exception 'Set the company TIN before submitting e-Invoices';
  end if;
  if v_doc.status = 'draft' then
    raise exception 'Post % before submitting it to MyInvois', v_doc.doc_no;
  end if;
  if not v_doc.requires_self_billed then
    raise exception '% is not marked as owing a self-billed e-Invoice. '
                    'A supplier who files their own does not need one '
                    'from us.', v_doc.doc_no
      using errcode = '22023';
  end if;

  -- The codes for the buyer's own document: 11 to 14, against 01 to 04
  -- for a seller's. `ref_einvoice_types` has had all eight since 0011.
  v_type := case v_doc.doc_type
    when 'bill'                 then '11'
    when 'purchase_credit_note' then '12'
    when 'purchase_debit_note'  then '13'
    else null
  end;
  if v_type is null then
    raise exception 'A % is not a self-billed e-Invoice document',
      v_doc.doc_type
      using errcode = '22023';
  end if;

  -- A foreign supplier has no Malaysian TIN and this does not invent
  -- one. See the header: LHDN publishes general TINs for cases like
  -- this and which one applies is not something to guess into a
  -- statutory filing.
  --
  -- NOT `app.identifying_number`, which is the obvious helper and is
  -- the wrong one. `0481` built it to decide whether two contacts are
  -- the SAME COMPANY, and for that a general TIN has to reduce to null
  -- -- `EI00000000010` identifies nobody in particular, so two
  -- contacts carrying it are not each other. Here the general TIN is
  -- precisely the right answer, and reusing that function refused
  -- exactly the case this migration exists for.
  --
  -- What is left is the first half of the same rule: a placeholder is
  -- not a number. `N/A`, `NIL`, `NONE`, a dash and an empty cell all
  -- fail `[1-9]`; `EI00000000020` and `C12345678901` both pass.
  if coalesce(nullif(btrim(v_supplier.tin), ''), '') = ''
     or v_supplier.tin !~ '[1-9]' then
    raise exception 'A self-billed e-Invoice needs the supplier''s TIN. '
                    'Put the number LHDN told you to use for % on their '
                    'contact record — for a foreign supplier that is one '
                    'of LHDN''s general TINs, not a made-up one.',
      coalesce(v_supplier.name, 'this supplier')
      using errcode = '23514';
  end if;

  select * into v_existing from public.einvoice_documents
   where org_id = v_doc.org_id
     and source_table = 'purchase_documents'
     and source_id = v_doc.id
     and einvoice_type_code = v_type;
  if found and v_existing.status in ('valid', 'submitted', 'queued') then
    raise exception 'The self-billed e-Invoice for % is already %',
      v_doc.doc_no, v_existing.status
      using errcode = '55000';
  end if;

  insert into public.einvoice_documents (
    org_id, source_table, source_id, einvoice_type_code, einvoice_version,
    is_self_billed,
    internal_doc_no, issue_date, currency, exchange_rate,
    supplier_name, supplier_tin, supplier_id_type, supplier_id_value,
    supplier_sst_no, supplier_email, supplier_phone, supplier_address,
    buyer_name, buyer_tin, buyer_id_type, buyer_id_value, buyer_sst_no,
    buyer_email, buyer_phone, buyer_address,
    total_excl_tax, total_incl_tax, total_discount, total_tax,
    total_charges, rounding_amount, payable_amount,
    status, created_by
  ) values (
    v_doc.org_id, 'purchase_documents', v_doc.id, v_type,
    coalesce(v_org.settings ->> 'einvoice_version', '1.0'),
    true,
    v_doc.doc_no, v_doc.doc_date, v_doc.currency, v_doc.exchange_rate,

    -- THE SUPPLIER BLOCK: the supplier. Not us. See the header.
    coalesce(v_supplier.legal_name, v_supplier.name),
    v_supplier.tin,
    coalesce(v_supplier.id_type, 'BRN'),
    coalesce(v_supplier.id_value, v_supplier.registration_no, 'NA'),
    v_supplier.sst_registration_no, v_supplier.email, v_supplier.phone,
    jsonb_build_object(
      'line1', v_supplier.address_line1, 'line2', v_supplier.address_line2,
      'line3', v_supplier.address_line3, 'city', v_supplier.city,
      'postcode', v_supplier.postcode, 'state', v_supplier.state_code,
      'country', v_supplier.country_code),

    -- THE BUYER BLOCK: us, because on a self-billed document we are the
    -- buyer. `prepare_einvoice` puts this same company in the SUPPLIER
    -- block, and that is not a contradiction -- it is the difference
    -- between selling and buying.
    coalesce(v_org.legal_name, v_org.name),
    coalesce(v_org.einvoice_tin, v_org.tin),
    coalesce(v_org.einvoice_id_type, 'BRN'),
    coalesce(v_org.einvoice_id_value, v_org.registration_no),
    v_org.sst_registration_no, v_org.email, v_org.phone,
    jsonb_build_object(
      'line1', v_org.address_line1, 'line2', v_org.address_line2,
      'line3', v_org.address_line3, 'city', v_org.city,
      'postcode', v_org.postcode, 'state', v_org.state_code,
      'country', v_org.country_code),

    v_doc.subtotal, v_doc.total_amount, v_doc.discount_amount,
    v_doc.tax_amount,
    -- Every charge on the bill that no line carries. `0415` measured
    -- what leaving shipping out costs on the sales side -- LHDN told
    -- 113.00 for a bill of 123.00 -- and a purchase document has the
    -- same column.
    coalesce(v_doc.shipping_amount, 0),
    v_doc.rounding_amount, v_doc.total_amount,
    'queued', auth.uid()
  )
  on conflict (org_id, source_table, source_id, einvoice_type_code) do update
    set status = 'queued',
        is_self_billed = true,
        validation_errors = '[]'::jsonb,
        error_code = null,
        error_message = null,
        internal_doc_no = excluded.internal_doc_no,
        issue_date = excluded.issue_date,
        total_excl_tax = excluded.total_excl_tax,
        total_incl_tax = excluded.total_incl_tax,
        total_tax = excluded.total_tax,
        total_charges = excluded.total_charges,
        total_discount = excluded.total_discount,
        payable_amount = excluded.payable_amount,
        rounding_amount = excluded.rounding_amount
  returning id into v_ei_id;

  delete from public.einvoice_lines where einvoice_id = v_ei_id;

  insert into public.einvoice_lines (
    org_id, einvoice_id, line_no, classification_code, description,
    quantity, uom_code, unit_price, subtotal, discount_rate,
    discount_amount, tax_type_code, tax_rate, tax_amount,
    tax_exemption_reason, tax_exempted_amount, total_excl_tax,
    total_incl_tax
  )
  select v_doc.org_id, v_ei_id, l.line_no,
         coalesce(l.classification_code, i.classification_code, '022'),
         coalesce(nullif(l.description, ''), i.name, 'Item'),
         l.quantity, coalesce(l.uom_code, i.uom_code, 'C62'), l.unit_price,
         round(l.quantity * l.unit_price, 2),
         l.discount_percent, l.discount_amount,
         coalesce(t.tax_type_code, '06'), l.tax_rate, l.tax_amount,
         case when t.is_exempt then t.exemption_reason else null end,
         case when t.is_exempt then l.line_subtotal else 0 end,
         l.line_subtotal, l.line_total
    from public.purchase_document_lines l
    left join public.items i on i.id = l.item_id
    left join public.tax_codes t on t.id = l.tax_code_id
   where l.document_id = v_doc.id
     and l.line_type = 'item'
   order by l.line_no;

  update public.purchase_documents
     set einvoice_id = v_ei_id, einvoice_status = 'pending'
   where id = v_doc.id;

  return v_ei_id;
end;
$function$;

comment on function public.prepare_self_billed_einvoice(uuid) is
  'Builds the e-Invoice a BUYER owes LHDN for a supply the seller '
  'cannot file -- a foreign supplier, an unregistered individual. '
  'Codes 11 to 14. The supplier block holds the supplier and the buyer '
  'block holds this company, which is the opposite way round from '
  'prepare_einvoice and is the whole difference between selling and '
  'buying. 0611.';

revoke all on function public.prepare_self_billed_einvoice(uuid)
  from public, anon;
grant execute on function public.prepare_self_billed_einvoice(uuid)
  to authenticated;
