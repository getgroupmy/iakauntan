-- ---------------------------------------------------------------------
-- 0431  The exemption LHDN was told nothing about
-- ---------------------------------------------------------------------
-- `einvoice_lines.tax_exempted_amount` has existed since `0007`. No SQL
-- function has ever written it, so it is 0 on every line ever prepared.
-- One consumer reads it: `_shared/ubl.ts`, which rolls it up per tax
-- type and then, for the exempt category, SUBSTITUTES it for the
-- taxable amount it would otherwise send:
--
--     if (taxTypeCode === "E" && exemptedAmount > 0) {
--       subtotal.TaxableAmount = money(exemptedAmount, currency);
--     }
--
-- That is the `0410` shape once removed: not a column a consumer was
-- never told about, but a column no producer was ever told to fill,
-- whose only reader treats it as a statutory figure. Measured against
-- the real builder, with one exempt line of RM1,000:
--
--   * writing the line's taxable base (1,000) changes the payload not
--     at all -- byte-identical to today's zero, because the fallback
--     `TaxableAmount` is that same number;
--   * writing the tax that would have been charged (60) silently sends
--     LHDN **60.00** as the taxable amount of a RM1,000 exempt supply.
--
-- Both are defensible readings of LHDN's field name, "Amount Exempted
-- from Tax". The column has no producer to settle which, so whichever
-- a future writer picks, half the time the return is wrong and nothing
-- says so. `0415` was this exact failure already realised -- LHDN told
-- 113.00 for a bill of 123.00 -- and it was found by adding up a
-- payload, not by reading one.
--
-- So this migration gives the column a producer and one meaning: for a
-- line whose tax code is exempt, the amount exempted from tax is that
-- line's taxable amount, and there is no other candidate, because
-- `tax_codes.is_exempt` is a boolean -- this schema cannot express a
-- partial exemption. Zero on every line that is not exempt.
--
-- The substitution in `ubl.ts` goes, in the same commit. Once the
-- column is written by construction to equal the taxable base, the
-- branch can only ever be a no-op or a corruption, and a branch whose
-- best case is a no-op is worth less than the room it leaves for the
-- worst one. What LHDN receives does not change; what it can receive
-- by accident does.
--
-- Asserted in `supabase/tests/einvoice_totals_reconcile.sql`, on a
-- document carrying one exempt line and one taxed line so that "written
-- for exempt lines" can be told from "written for every line". Four
-- mutants applied to this migration and measured:
--
--   * the column back at its default 0 -- killed, "the exempt line says
--     how much of the supply was exempted", got 0.00;
--   * written on every line regardless of the code -- killed, "a line
--     that paid tax was exempted from nothing", got 50.00;
--   * written as the tax forgone (8% of the line) -- killed by the same
--     assertion as the first, got 8.00;
--   * the amount written and the ground for it dropped -- killed, "no
--     line in this file claims an exemption without naming its ground".
--
-- The fourth needed care: writing `null` in place of the reason removes
-- the string this migration's own apply-time guard looks for, so the
-- guard would have killed it before the test ran. It was applied as a
-- `case when false and ...` that keeps the text, which is the mutant
-- the assertion is actually for.
--
-- The identity assertion -- "it is the taxable amount of that line, not
-- the tax forgone" -- killed nothing of its own: both mutants that move
-- the figure trip the literal assertion first. It is the general form
-- of that literal and earns its place by surviving a change to the
-- fixture's amounts, not by catching a mutant the literal misses. Said
-- plainly because an assertion credited with a kill it did not make is
-- how a test file starts drifting from what it covers.
--
-- Not changed, and worth naming so the next sweep does not re-find it:
-- `einvoice_lines.charge_amount` is also written by nothing -- but it
-- is read by nothing either. It is declared in the TypeScript row
-- interface and never touched. A line-level charge cannot be entered
-- anywhere in the app, so the column is empty and consistent, not
-- empty and load-bearing. It stays as it is.
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
    tax_exempted_amount, total_excl_tax, total_incl_tax
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

comment on column public.einvoice_lines.tax_exempted_amount is
  'The amount exempted from tax on this line: its taxable amount when '
  'the tax code is exempt, 0 otherwise. Written by prepare_einvoice '
  'since 0431. Equal to total_excl_tax on an exempt line by '
  'construction -- both come from sales_document_lines.line_subtotal -- '
  'and nothing may substitute one for the other in a MyInvois payload.';

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = 'public.prepare_einvoice(uuid)'::regprocedure;

  if v_src !~ 'tax_exempted_amount' then
    raise exception
      'FAIL 0431: prepare_einvoice still leaves tax_exempted_amount at '
      'zero, so the column the UBL builder reads has no producer';
  end if;

  -- The reason and the amount are one claim in two columns. A fix that
  -- wrote the amount and dropped the ground for it would satisfy the
  -- assertion above and send LHDN an exemption with no authority named.
  if v_src !~ 'exemption_reason' then
    raise exception
      'FAIL 0431: the ground for the exemption has been lost from the '
      'e-Invoice line';
  end if;

  -- 0415's two charges are in the same statement and are the reason
  -- this function is being restated at all; losing one to a careless
  -- copy is the failure mode this migration is itself an instance of.
  if v_src !~ 'service_charge_amount' or v_src !~ 'shipping_amount' then
    raise exception
      'FAIL 0431: a charge has been dropped from total_charges, '
      'undoing 0415';
  end if;

  raise notice
    '0431: an exempt line says how much was exempted, and under what';
end
$do$;
