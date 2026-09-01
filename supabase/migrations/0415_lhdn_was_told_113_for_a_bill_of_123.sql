-- ---------------------------------------------------------------------
-- 0415  LHDN was told 113 for a bill of 123
-- ---------------------------------------------------------------------
--
-- `prepare_einvoice` maps a sales document onto the MyInvois header:
--
--     total_excl_tax   subtotal
--     total_discount   discount_amount
--     total_charges    shipping_amount
--     total_tax        tax_amount
--     rounding_amount  rounding_amount
--     payable_amount   total_amount
--
-- Those six are not independent. What a customer is billed is
--
--     excl_tax - discount + charges + tax + rounding = payable
--
-- and `app.recalc_sales_totals` maintains exactly that identity on the
-- document. `0410` added a second charge — the service charge a
-- Malaysian bill carries — put it in the total and into the ledger, and
-- did not put it in `total_charges`. The identity broke on the line
-- above.
--
-- Measured, on a restaurant bill of RM100 with RM5 delivery and a RM10
-- service charge at eight per cent:
--
--     doc:    sub 100.00  tax 8.00  ship 5.00  svc 10.00  total 123.00
--     e-inv:  excl 100.00  charges 5.00  tax 8.00  payable 123.00
--     told:   113.00        billed: 123.00
--
-- Ten ringgit of a hundred, on every bill a restaurant sends. MyInvois
-- validates the arithmetic on the document it is given, so the near
-- outcome is a rejected submission; the worse one is an accepted
-- document that understates what was charged.
--
-- ## Why nothing caught it
--
-- Nothing has ever asserted that the six reconcile. `total_charges`,
-- `total_excl_tax` and `payable_amount` appear in no test in this
-- repository — grepped, not recalled — so the mapping has been trusted
-- since it was written, and the day a seventh column joined the total
-- there was nothing to notice it.
--
-- `einvoice_totals_reconcile.sql` is that assertion, and it is written
-- as the identity rather than as six expected numbers, so the next
-- charge added to a document fails it too.
--
-- ## The defect is this session's own
--
-- `0410` is four migrations old. Recorded plainly because a fix that
-- reads as though it were repairing somebody else's old mistake is a
-- fix that teaches nothing: what this cost was one column not being
-- looked for in the four places a document's money is copied to, and
-- the shared invoice link in `0413` was the second of them.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.prepare_einvoice(p_sales_document_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
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
        payable_amount = excluded.payable_amount,
        rounding_amount = excluded.rounding_amount
  returning id into v_ei_id;

  delete from public.einvoice_lines where einvoice_id = v_ei_id;

  insert into public.einvoice_lines (
    org_id, einvoice_id, line_no, classification_code, description,
    quantity, uom_code, unit_price, subtotal, discount_rate, discount_amount,
    tax_type_code, tax_rate, tax_amount, tax_exemption_reason,
    total_excl_tax, total_incl_tax
  )
  select v_doc.org_id, v_ei_id, l.line_no,
         coalesce(l.classification_code, i.classification_code, '022'),
         coalesce(nullif(l.description, ''), i.name, 'Item'),
         l.quantity, coalesce(l.uom_code, i.uom_code, 'C62'), l.unit_price,
         round(l.quantity * l.unit_price, 2),
         l.discount_percent, l.discount_amount,
         coalesce(t.tax_type_code, '06'), l.tax_rate, l.tax_amount,
         case when t.is_exempt then t.exemption_reason else null end,
         l.line_subtotal, l.line_total
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
$function$;

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = 'public.prepare_einvoice(uuid)'::regprocedure;

  if v_src !~ 'service_charge_amount' then
    raise exception
      'FAIL 0415: the service charge still does not reach total_charges, '
      'so a document sent to LHDN does not add up to its own total';
  end if;

  -- And the shipping it used to be alone. A fix that replaced one
  -- charge with the other would satisfy the assertion above.
  if v_src !~ 'shipping_amount' then
    raise exception
      'FAIL 0415: the delivery charge has been lost from total_charges';
  end if;

  raise notice
    '0415: every charge on a document reaches the e-Invoice header';
end
$do$;
