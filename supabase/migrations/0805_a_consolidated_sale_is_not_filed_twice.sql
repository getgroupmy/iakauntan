-- =====================================================================
-- iAkauntan :: 0805 a consolidated sale is not filed twice
--
-- A month's counter sales with no identified buyer go to LHDN as one
-- consolidated e-Invoice: `consolidate_pos_einvoices` (and the monthly
-- job's `roll_einvoice_consolidation`) put each sale in
-- `einvoice_consolidation_items`, and the consolidated document carries
-- one line per sale. `request_einvoice_for_sale` refuses to name a buyer
-- for a sale already there -- "This sale has already gone into a
-- consolidated e-Invoice. Raise a credit note and re-issue it if the
-- buyer needs their own." -- but `prepare_einvoice`, which the
-- document's own "Submit e-Invoice" button calls through MyInvois,
-- never asked; and consolidating marks nothing on the invoice, so the
-- button is offered.
--
-- Measured on 10 October 2026, locally, as the owner with the role
-- `authenticated`: three counter sales consolidated (RM60.00), the
-- consolidated e-Invoice accepted by LHDN, and then `prepare_einvoice`
-- on one RM10.00 sale queued an individual e-Invoice for it -- LHDN
-- would hold the same RM10.00 twice. A completed counter sale is paid,
-- so `void_sales_document` already refuses it.
--
-- Answered "refuse it, in the same words". `prepare_einvoice` refuses a
-- sales document that is in any consolidation, as
-- `request_einvoice_for_sale` does, with its sentence. Restated from
-- `0770` (production hash identical).
--
-- Production held no consolidation and no e-Invoice on 10 October.
-- =====================================================================

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
  -- 0770. A sale that was voided is not one LHDN should validate: a
  -- valid e-Invoice for it would then need cancelling inside 72 hours.
  if v_doc.status = 'void' or v_doc.deleted_at is not null then
    raise exception
      '% has been voided, so there is no sale to submit to MyInvois.',
      v_doc.doc_no
      using errcode = '23514';
  end if;
  -- 0805. Already told LHDN this sale had no identified buyer: the
  -- month's consolidated e-Invoice carries it, and one of its own would
  -- report it twice. The rule and the sentence are
  -- `request_einvoice_for_sale`'s, which asks it of a counter sale
  -- before naming the buyer; this is the road the document's own
  -- Submit button takes, and every other.
  if exists (select 1 from public.einvoice_consolidation_items ci
              where ci.sales_document_id = v_doc.id) then
    raise exception
      'This sale has already gone into a consolidated e-Invoice. Raise a '
      'credit note and re-issue it if the buyer needs their own.'
      using errcode = '23514';
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

comment on function public.prepare_einvoice(uuid) is
  'Snapshots a posted sales document into MyInvois e-Invoice form and '
  'queues it for submission. Refuses a void or deleted one (0770), and '
  'one already carried by a consolidated e-Invoice, in the words '
  'request_einvoice_for_sale uses (0805).';
