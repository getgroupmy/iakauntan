-- =====================================================================
-- iAkauntan :: 0642 the other number a hotel has to print
--
-- `organizations.tourism_tax_reg_no` has been a column since `0001`,
-- sitting on the line after `sst_registration_no`, and nothing has ever
-- written to it or read it. No form asks for it, no PDF prints it, no
-- function returns it. A company registered under the Tourism Tax Act
-- 2017 has nowhere in this product to record the number RMCD issued it.
--
-- Its neighbour is reachable from everywhere by comparison: the
-- onboarding form asks for it, the SST card edits it, `pdf_kit`'s
-- letterhead prints it on every document, the shared document page
-- shows it to the customer, and the self-billed e-Invoice sends it to
-- LHDN. The two columns were written on consecutive lines of the same
-- migration and only one of them was ever wired up.
--
-- Found by the same sweep that found `tax_codes.is_inclusive` in 0641:
-- every column in `public` that nothing at all mentions.
--
-- ---------------------------------------------------------------------
-- What this migration does, and what it does not
--
-- Only the SHARED DOCUMENT PAGE needs SQL. Everything else is client
-- side: the company form writes `organizations` straight through
-- PostgREST under the `organizations_update` policy, which has checked
-- `can_admin` since `0010`, and the PDF reads the row the client
-- already holds. So this is one key added to one payload, restated from
-- the applied function with nothing else changed.
--
-- The page and the PDF are the same document seen two ways, and they
-- had drifted: the letterhead carried the SST number and the page
-- carried it too, so adding a registration to one and not the other is
-- how a customer opening the link sees a different tax invoice from the
-- one in their inbox.
--
-- It is deliberately NOT added to the MyInvois payloads. LHDN's
-- supplier block has fields for the TIN, the SSM registration and the
-- SST registration, and no field for this one; inventing a place to put
-- it is how a submission gets rejected for a reason nobody can read.
-- =====================================================================

create or replace function public.open_shared_document(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  l public.document_share_links;
  d public.sales_documents;
  o public.organizations;
  c public.contacts;
  v_state text;
  v_pay jsonb;
begin
  select * into l from public.document_share_links
   where token_hash = app.corp_token_hash(p_token);

  if l.id is null then
    return jsonb_build_object('state', 'invalid');
  end if;

  select * into d from public.sales_documents where id = l.document_id;
  select * into o from public.organizations where id = l.org_id;
  select * into c from public.contacts where id = d.contact_id;

  v_state := case
    when l.revoked_at is not null then 'revoked'
    when l.expires_at < now() then 'expired'
    when d.id is null or d.deleted_at is not null then 'withdrawn'
    when d.status in ('void', 'rejected') then 'withdrawn'
    else 'open'
  end;

  -- Recorded even when the answer is 'expired': that somebody tried is
  -- worth as much as that somebody read it.
  update public.document_share_links
     set opened_at = coalesce(opened_at, now()),
         last_opened_at = now(),
         open_count = open_count + 1,
         ip_address = coalesce(ip_address, nullif(split_part(coalesce(
           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet),
         user_agent = coalesce(user_agent, app.request_header('user-agent'))
   where id = l.id;

  if v_state <> 'open' then
    return jsonb_build_object('state', v_state);
  end if;

  -- Whether this customer can pay it here, and with which acquirers.
  -- Names only: nothing about a gateway that is not already on the
  -- button the customer is about to press.
  -- Aliased `g`, not `o`: this function already has an `o` of its own
  -- for the organization, and plpgsql resolves the variable ahead of
  -- the alias, so `o.code` asks the organizations row for a column it
  -- does not have.
  select coalesce(jsonb_agg(jsonb_build_object('code', g.code, 'name', g.name)
                            order by g.code), '[]'::jsonb)
    into v_pay
    from public.shared_payment_options(p_token) g;

  return jsonb_build_object(
    'state', 'open',
    'pay_with', case when coalesce(d.balance_amount, 0) > 0
                     then v_pay else '[]'::jsonb end,
    'company', jsonb_build_object(
      'name', coalesce(o.legal_name, o.name),
      'registration_no', o.registration_no,
      'tin', o.tin,
      'sst_registration_no', o.sst_registration_no,
      -- The other registration a tax invoice carries, and the
      -- only one that was on the PDF and not on this page. An
      -- accommodation operator registered under the Tourism Tax
      -- Act prints it beside the SST number.
      'tourism_tax_reg_no', o.tourism_tax_reg_no,
      'address', concat_ws(E'\n', o.address_line1, o.address_line2,
                           o.address_line3,
                           nullif(concat_ws(' ', o.postcode, o.city), ''),
                           o.state_code),
      'email', o.email,
      'phone', o.phone,
      'website', o.website,
      'logo_url', o.logo_url),
    'contact', jsonb_build_object(
      'name', c.name,
      'address', concat_ws(E'\n', c.address_line1, c.address_line2,
                           nullif(concat_ws(' ', c.postcode, c.city), ''),
                           c.state_code)),
    'document', jsonb_build_object(
      'doc_type', d.doc_type,
      'doc_no', d.doc_no,
      'doc_date', d.doc_date,
      'due_date', d.due_date,
      'reference', d.reference,
      'subject', d.subject,
      'currency', d.currency,
      'subtotal', d.subtotal,
      'discount_amount', d.discount_amount,
      'tax_amount', d.tax_amount,
      'shipping_amount', d.shipping_amount,
      -- `0410` added this and `0411` prints it on a receipt; a customer
      -- reading the shared invoice was left with a total that did not
      -- add up from the figures above it.
      'service_charge_amount', d.service_charge_amount,
      'rounding_amount', d.rounding_amount,
      'total_amount', d.total_amount,
      'paid_amount', d.paid_amount,
      'balance_amount', d.balance_amount,
      'status', d.status,
      -- `notes` is what the sender wrote for the customer to read.
      -- `internal_notes` is not, and is deliberately absent.
      'notes', d.notes,
      'terms_conditions', d.terms_conditions),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'line_no', li.line_no,
               'description', li.description,
               'quantity', li.quantity,
               'uom_code', li.uom_code,
               'unit_price', li.unit_price,
               'discount_amount', li.discount_amount,
               'tax_amount', li.tax_amount,
               'line_total', li.line_total)
             order by li.line_no)
        from public.sales_document_lines li
       where li.document_id = d.id), '[]'::jsonb));
end;
$function$;


-- Restated, and NOT decoration. `anon` loses its execute privilege when
-- this function is replaced -- `{postgres=X,authenticated=X}` is what
-- `proacl` reads immediately afterwards -- so a restatement without this
-- line leaves the share link opening for a signed-in member and
-- answering nothing to the customer it was emailed to. `0413` restated
-- the same function and re-granted it on the next line for the same
-- reason. `document_share.sql` asserts the privilege, which is how this
-- was caught rather than shipped.
grant execute on function public.open_shared_document(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
begin
  -- The key is in the payload the function builds. Read out of the
  -- source rather than by opening a link, because there is no org, no
  -- document and no token at migration time -- and a migration that
  -- created one to check itself would leave it behind.
  if (select prosrc from pg_proc where proname = 'open_shared_document')
       not like '%tourism_tax_reg_no%' then
    raise exception 'the shared document payload lost the Tourism Tax number';
  end if;

  if not has_function_privilege('anon',
       'public.open_shared_document(text)', 'execute') then
    raise exception 'anon can no longer open a share link';
  end if;
end $do$;
