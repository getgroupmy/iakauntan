-- =====================================================================
-- iAkauntan :: 0636 the code the customs officer reads
--
-- G3(c) on the AutoCount list: "tariff/HS code". The matrix was right
-- that it is missing, and right that `items.classification_code` is a
-- different thing — LHDN's list of what a purchase IS, for relief
-- purposes, not what it is for customs. It was wrong about where the
-- hole is.
--
-- ---------------------------------------------------------------------
-- The column exists. The emitter exists. Nothing fills it.
--
-- `einvoice_lines.product_tariff_code` has been a column since 0007,
-- described there as one of the "optional product traceability fields
-- supported by MyInvois". `supabase/functions/_shared/ubl.ts` reads it
-- and emits it correctly, with `listID="PTC"`, and `ubl_test.ts`
-- asserts that it does.
--
-- And no INSERT anywhere names the column. All three writers of
-- `einvoice_lines` — `prepare_einvoice` (0538),
-- `prepare_self_billed_einvoice` (0611), and the consolidated one in
-- 0616 — list their columns explicitly and this is not among them. So
-- the value is null on every line ever written, the emitter's `if`
-- never fires, and a test asserting the emitter works passes while the
-- feature does not exist.
--
-- This is the sixth verdict in this audit to turn on the difference
-- between a column existing and a column being written. It is worth
-- saying plainly: a schema search answers "is there somewhere to put
-- it", which is not the question.
--
-- ---------------------------------------------------------------------
-- The source is the item, because a tariff code is a fact about a
-- product
--
-- An HS code belongs to the goods, not to the sale: the same product
-- has the same code on every invoice, and asking a clerk to retype it
-- per line is asking for a different code on two lines of one
-- delivery. So `items.tariff_code` is where it is maintained and the
-- e-Invoice takes it from there.
--
-- `country_of_origin` is added in the same place and for the same
-- reason. It is the other half of the pair in 0007, it has been null
-- just as long, and `ubl.ts` already defaults it to MYS — so carrying
-- it changes nothing until somebody sets it, and then it says what
-- they set.
--
-- ---------------------------------------------------------------------
-- Not validated against a list, and why
--
-- Malaysia's tariff codes live in the PDK — thousands of lines,
-- revised on a schedule of its own, and not published as anything this
-- repository can seed and keep current. A `references` to a table we
-- could not maintain would refuse codes that are correct, which is
-- worse than accepting one that is wrong: the first stops an invoice
-- that should go, the second is caught by the customs officer who
-- reads it.
--
-- So the constraint is on SHAPE, not membership: digits and dots, four
-- to fourteen characters, which admits `1234`, `1234.56` and
-- `1234.56.78.90` and refuses a description somebody pasted into the
-- wrong box. That last is the realistic error and the only one a
-- check can catch here.
--
-- ---------------------------------------------------------------------
-- Consolidated e-Invoices deliberately do not get one
--
-- A consolidated line is one whole till receipt, classification `004`,
-- with no single item behind it. There is no tariff code that is true
-- of it, and inventing the first item's would be a false statement to
-- LHDN about what was sold. `0616` is left alone.
-- =====================================================================

alter table public.items
  add column tariff_code text
    constraint items_tariff_code_shape
    check (tariff_code is null or tariff_code ~ '^[0-9]{4}[0-9.]{0,10}$'),
  add column country_of_origin char(3)
    references public.ref_countries (code);

comment on column public.items.tariff_code is
  'The customs tariff / HS code for this product, carried onto an '
  'e-Invoice line as product_tariff_code. NOT classification_code, '
  'which is LHDN''s list of what a purchase is for relief purposes. '
  'Shape-checked rather than validated against the PDK, which this '
  'repository cannot keep current. 0636.';

comment on column public.items.country_of_origin is
  'Where the goods were made. Null means unstated, and ubl.ts then '
  'emits MYS as it always has. 0636.';

-- ---------------------------------------------------------------------
-- The two line writers that have an item behind each line
--
-- Restated verbatim from the live bodies -- `prepare_einvoice` from
-- 0538 and `prepare_self_billed_einvoice` from 0611 -- with the two
-- columns added to the insert and the two values added to the select.
-- Nothing else differs.
--
-- Both take the value from `items`, joined already for the name, the
-- unit of measure and the classification code. Every existing item has
-- null in both columns, so every document that could be prepared
-- before this migration prepares to the same UBL after it: `ubl.ts`
-- omits the tariff element when the value is null, and already
-- defaults the country to MYS.
-- ---------------------------------------------------------------------

create or replace function public.prepare_einvoice(p_sales_document_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'app', 'pg_temp'
AS $function$
declare
  v_doc      public.sales_documents;
  v_org      public.organizations;
  v_buyer    public.contacts;
  v_type     text;
  v_ei_id    uuid;
  v_existing public.einvoice_documents;
begin
  select * into v_doc from public.sales_documents where id = p_sales_document_id;
  if not found then
    raise exception 'Sales document % not found', p_sales_document_id;
  end if;
  if not app.can_write(v_doc.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select * into v_org from public.organizations where id = v_doc.org_id;
  select * into v_buyer from public.contacts where id = v_doc.contact_id;

  if not v_org.einvoice_enabled then
    raise exception 'e-Invoice is not enabled for this organization';
  end if;
  if coalesce(v_org.einvoice_tin, v_org.tin) is null then
    raise exception 'Set the organization TIN before submitting e-Invoices';
  end if;
  if v_doc.status = 'draft' then
    raise exception 'Post % before submitting it to MyInvois', v_doc.doc_no;
  end if;

  v_type := case v_doc.doc_type
    when 'invoice'     then '01'
    when 'credit_note' then '02'
    when 'debit_note'  then '03'
    when 'refund_note' then '04'
    else null
  end;
  if v_type is null then
    raise exception 'Document type % is not an e-Invoice document', v_doc.doc_type;
  end if;

  -- A validated document is immutable; it must be cancelled instead.
  select * into v_existing from public.einvoice_documents
   where org_id = v_doc.org_id
     and source_table = 'sales_documents'
     and source_id = v_doc.id
     and einvoice_type_code = v_type;
  if found and v_existing.status in ('valid', 'submitted', 'queued') then
    raise exception 'e-Invoice for % is already %', v_doc.doc_no, v_existing.status;
  end if;

  insert into public.einvoice_documents (
    org_id, source_table, source_id, einvoice_type_code, einvoice_version,
    internal_doc_no, issue_date, currency, exchange_rate,
    supplier_name, supplier_tin, supplier_id_type, supplier_id_value,
    supplier_sst_no, supplier_msic_code, supplier_business_activity,
    supplier_email, supplier_phone, supplier_address,
    buyer_name, buyer_tin, buyer_id_type, buyer_id_value, buyer_sst_no,
    buyer_email, buyer_phone, buyer_address,
    total_excl_tax, total_incl_tax, total_discount, total_tax,
    total_charges, rounding_amount, payable_amount,
    status, created_by
  ) values (
    v_doc.org_id, 'sales_documents', v_doc.id, v_type,
    coalesce(v_org.settings ->> 'einvoice_version', '1.0'),
    v_doc.doc_no, v_doc.doc_date, v_doc.currency, v_doc.exchange_rate,
    coalesce(v_org.legal_name, v_org.name),
    coalesce(v_org.einvoice_tin, v_org.tin),
    coalesce(v_org.einvoice_id_type, 'BRN'),
    coalesce(v_org.einvoice_id_value, v_org.registration_no),
    v_org.sst_registration_no, v_org.msic_code, v_org.business_activity,
    v_org.email, v_org.phone,
    jsonb_build_object('line1', v_org.address_line1, 'line2', v_org.address_line2,
      'line3', v_org.address_line3, 'city', v_org.city, 'postcode', v_org.postcode,
      'state', v_org.state_code, 'country', v_org.country_code),
    coalesce(v_buyer.legal_name, v_buyer.name),
    -- B2C sales fall back to the LHDN general public TIN.
    coalesce(nullif(v_buyer.tin, ''), app.general_public_tin()),
    coalesce(v_buyer.id_type, 'BRN'),
    coalesce(v_buyer.id_value, v_buyer.registration_no, 'NA'),
    v_buyer.sst_registration_no, v_buyer.email, v_buyer.phone,
    jsonb_build_object('line1', v_buyer.address_line1, 'line2', v_buyer.address_line2,
      'line3', v_buyer.address_line3, 'city', v_buyer.city, 'postcode', v_buyer.postcode,
      'state', v_buyer.state_code, 'country', v_buyer.country_code),
    v_doc.subtotal, v_doc.total_amount, v_doc.discount_amount, v_doc.tax_amount,
    -- Every charge the customer is billed that no line carries, which
    -- since `0410` is two of them. Shipping alone left the header not
    -- adding up: LHDN was told 113.00 for a bill of 123.00, measured
    -- rather than reasoned about.
    coalesce(v_doc.shipping_amount, 0) + coalesce(v_doc.service_charge_amount, 0),
    v_doc.rounding_amount, v_doc.total_amount,
    'queued', auth.uid()
  )
  on conflict (org_id, source_table, source_id, einvoice_type_code) do update
    set status = 'queued',
        validation_errors = '[]'::jsonb,
        error_code = null,
        error_message = null,
        internal_doc_no = excluded.internal_doc_no,
        issue_date = excluded.issue_date,
        total_excl_tax = excluded.total_excl_tax,
        total_incl_tax = excluded.total_incl_tax,
        total_tax = excluded.total_tax,
        -- The two that were missing. A payable amount that moved and a
        -- charge that did not is a header that does not add up, which
        -- is the whole of what 0410 was about.
        total_charges = excluded.total_charges,
        total_discount = excluded.total_discount,
        payable_amount = excluded.payable_amount,
        rounding_amount = excluded.rounding_amount
  returning id into v_ei_id;

  delete from public.einvoice_lines where einvoice_id = v_ei_id;

  insert into public.einvoice_lines (
    org_id, einvoice_id, line_no, classification_code, description,
    quantity, uom_code, unit_price, subtotal, discount_rate, discount_amount,
    tax_type_code, tax_rate, tax_amount, tax_exemption_reason,
    tax_exempted_amount, total_excl_tax, total_incl_tax,
    product_tariff_code, country_of_origin
  )
  select v_doc.org_id, v_ei_id, l.line_no,
         coalesce(l.classification_code, i.classification_code, '022'),
         coalesce(nullif(l.description, ''), i.name, 'Item'),
         l.quantity, coalesce(l.uom_code, i.uom_code, 'C62'), l.unit_price,
         round(l.quantity * l.unit_price, 2),
         l.discount_percent, l.discount_amount,
         coalesce(t.tax_type_code, '06'), l.tax_rate, l.tax_amount,
         case when t.is_exempt then t.exemption_reason else null end,
         -- The amount exempted from tax is the taxable amount of the
         -- line that was exempted. `tax_codes.is_exempt` is a boolean:
         -- a line is exempt or it is not, so there is nothing else the
         -- figure could be. Written with the same expression that
         -- feeds `total_excl_tax` below, so the two are equal by
         -- construction rather than by agreement.
         case when t.is_exempt then l.line_subtotal else 0 end,
         l.line_subtotal, l.line_total,
         -- From the ITEM, never the line: an HS code is a fact about
         -- the product, and the same product typed twice must not
         -- reach LHDN under two codes. Null until somebody sets one,
         -- and ubl.ts omits the element entirely when it is null --
         -- so no document already preparable changes shape.
         i.tariff_code, i.country_of_origin
    from public.sales_document_lines l
    left join public.items i on i.id = l.item_id
    left join public.tax_codes t on t.id = l.tax_code_id
   where l.document_id = v_doc.id
     and l.line_type = 'item'
   order by l.line_no;

  update public.sales_documents
     set einvoice_id = v_ei_id, einvoice_status = 'pending'
   where id = v_doc.id;

  return v_ei_id;
end;
$function$
;

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
    total_incl_tax, product_tariff_code, country_of_origin
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
         l.line_subtotal, l.line_total,
         -- The same on the self-billed side. A foreign supplier's
         -- goods are exactly the case where a tariff code is asked
         -- for, so leaving this one out would have missed the half
         -- that matters most.
         i.tariff_code, i.country_of_origin
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
