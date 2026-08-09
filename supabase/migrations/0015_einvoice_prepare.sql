-- =====================================================================
-- iAkauntan :: 0015 e-Invoice preparation
-- Credential storage plus the function that snapshots a posted sales
-- document into MyInvois form and queues it for the edge function.
-- =====================================================================

-- Per-org MyInvois API credentials. RLS is enabled with NO policies, so
-- only the service role (edge functions) can read this table; the client
-- can never fetch a client secret.
create table public.einvoice_credentials (
  org_id uuid primary key references public.organizations (id) on delete cascade,
  environment text not null default 'sandbox'
               check (environment in ('sandbox', 'production')),
  client_id text not null,
  client_secret text not null,
  -- PKCS#12 material for the XAdES signature required by version 1.1
  cert_pem text,
  cert_private_key_pem text,
  cert_serial_number text,
  cert_issuer_name text,
  cert_expires_at timestamptz,
  updated_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.einvoice_credentials enable row level security;

comment on table public.einvoice_credentials is
  'MyInvois client credentials and signing certificate. RLS enabled with no policies: service role only.';

create trigger set_updated_at before update on public.einvoice_credentials
  for each row execute function app.set_updated_at();

-- LHDN placeholder TIN for consumers who do not supply one (B2C).
create or replace function app.general_public_tin()
returns text
language sql
immutable
as $$ select 'EI00000000010'::text $$;

-- ---------------------------------------------------------------------
-- Snapshot a sales document into e-Invoice form
--
-- The snapshot is deliberately a copy rather than a view: LHDN validates
-- what was transmitted, so the supplier and buyer details must be frozen
-- at submission time even if the master records change later.
-- ---------------------------------------------------------------------
create or replace function public.prepare_einvoice(p_sales_document_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
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
    v_doc.shipping_amount, v_doc.rounding_amount, v_doc.total_amount,
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
$$;

comment on function public.prepare_einvoice is
  'Snapshots a posted sales document into MyInvois e-Invoice form and queues it for submission.';

-- Mirror MyInvois status back onto the originating document so list
-- screens can show it without a join.
create or replace function app.sync_einvoice_status()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status then
    if new.source_table = 'sales_documents' then
      update public.sales_documents
         set einvoice_status = case new.status
               when 'valid'     then 'valid'
               when 'invalid'   then 'invalid'
               when 'cancelled' then 'cancelled'
               when 'rejected'  then 'rejected'
               when 'submitted' then 'submitted'
               else 'pending'
             end
       where id = new.source_id;
    elsif new.source_table = 'purchase_documents' then
      update public.purchase_documents
         set einvoice_status = case new.status
               when 'valid'     then 'valid'
               when 'invalid'   then 'invalid'
               when 'cancelled' then 'cancelled'
               when 'rejected'  then 'rejected'
               when 'submitted' then 'submitted'
               else 'pending'
             end
       where id = new.source_id;
    end if;
  end if;
  return new;
end;
$$;

create trigger sync_status after update of status on public.einvoice_documents
  for each row execute function app.sync_einvoice_status();
