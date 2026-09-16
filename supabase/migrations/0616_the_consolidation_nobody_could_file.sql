-- =====================================================================
-- iAkauntan :: the consolidation nobody could file
--
-- README: "Consolidated B2C e-Invoice: the monthly rollup now runs and
-- starts the 7-day clock, but submitting the consolidation is still
-- manual -- the scheduler does not hold MyInvois credentials."
--
-- That line is too kind to itself. Submitting it was not manual; it was
-- impossible. `consolidate_pos_einvoices` gathers the month's
-- unclaimed till sales into `einvoice_consolidations` and its items,
-- recomputes the count and the total, and stops.
-- `einvoice_consolidations.einvoice_id` has been nullable and null
-- since `0007`, and **nothing in this product has ever written it**.
--
-- The only thing that builds an `einvoice_documents` row from a
-- consolidation does not exist. `prepare_einvoice` takes ONE sales
-- document; `prepare_self_billed_einvoice` takes one purchase
-- document; a consolidation is neither and is many. So the screen's
-- "Consolidated, and queued for MyInvois" was describing something that
-- had not happened, and the seven-day clock it started ran out against
-- nothing.
--
-- ---------------------------------------------------------------------
-- Three faults, and the second is one `0615` introduced yesterday
--
-- **One.** There is no `prepare_consolidated_einvoice`. Built below.
--
-- **Two.** `0615` gave an administrator a way to set the e-Invoice
-- version to 1.1 and `app.einvoice_version_supported` still answers
-- false for it -- so switching to 1.1 made EVERY document preparation
-- raise `0A000`, e-Invoicing entirely broken by a dropdown. `0396`
-- anticipated this exactly and said what to do: *whoever implements the
-- XAdES signature changes `app.einvoice_version_supported` and nothing
-- else*. It was right, and 0615 did not do it. Done here, along with
-- the trigger's message, which says the signing step is not
-- implemented and has stopped being true.
--
-- **Three.** `einvoice_documents.source_table` admits two values and a
-- consolidation is a third kind of thing. Widened, deliberately and by
-- name, rather than by pretending a consolidation is a sales document.
--
-- ---------------------------------------------------------------------
-- What a consolidated e-Invoice looks like
--
-- Under the LHDN e-Invoice guideline a seller aggregates the period's
-- sales to buyers who did not ask for an invoice into one submission,
-- due within seven days of month end. The buyer is the general public:
-- LHDN's own TIN `EI00000000010`, "NA" for the registration number, and
-- no contact details, because there is no buyer to have any.
--
-- Each receipt is a LINE, with classification code `004`, which is
-- `ref_classification_codes`' "Consolidated e-Invoice" and exists for
-- nothing else. One line per receipt rather than one summary line: the
-- guideline's own worked example lists them, and a single line for a
-- month of till sales is not something a buyer -- or LHDN -- can trace
-- back to a receipt.
--
-- The figures come off the SALES DOCUMENTS rather than off
-- `einvoice_consolidation_items.amount`, which carries the gross only.
-- A consolidated e-Invoice has to state its tax, and a tax figure
-- derived by subtraction from a gross total is a tax figure that stops
-- agreeing with the ledger the first time a line is exempt.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Two, first, because nothing below can be prepared at 1.1 until it is
--
-- Widening what is allowed cannot invalidate a row already there, which
-- is why `0396` said this direction was safe to move in without
-- re-verifying the table.
-- ---------------------------------------------------------------------
create or replace function app.einvoice_version_supported(p_version text)
returns boolean
language sql
immutable
set search_path = pg_catalog, public, app, pg_temp
as $function$
  -- `1.1` since `0615`, which built the XAdES signature:
  -- `supabase/functions/_shared/xades.ts` signs the document and
  -- `_shared/der.ts` reads the certificate. This predicate is about
  -- what the BUILD can produce; whether a particular company has a
  -- certificate to produce it WITH is `set_einvoice_version`'s
  -- question, and it refuses 1.1 without one.
  select p_version in ('1.0', '1.1');
$function$;

comment on function app.einvoice_version_supported(text) is
  'The e-Invoice versions this build can actually produce. 1.1 since '
  '0615 implemented the XAdES signature. The check constraint and the '
  'trigger on einvoice_documents both read it, so they cannot come to '
  'disagree about what is supported.';

create or replace function app.check_einvoice_version()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  if not app.einvoice_version_supported(new.einvoice_version) then
    raise exception
      'This build submits e-Invoices at version 1.0 and 1.1. Version % '
      'is not one it can produce, so a document stamped % would reach '
      'LHDN claiming to follow a specification this software has never '
      'implemented. Set "einvoice_version" to 1.0 or 1.1.',
      new.einvoice_version, new.einvoice_version
      -- feature_not_supported, not a check violation: the value is not
      -- malformed, it is a thing this build cannot do.
      using errcode = '0A000';
  end if;
  return new;
end $function$;

-- ---------------------------------------------------------------------
-- Three. A consolidation is a third kind of source.
-- ---------------------------------------------------------------------
alter table public.einvoice_documents
  drop constraint if exists einvoice_documents_source_table_check;
alter table public.einvoice_documents
  add constraint einvoice_documents_source_table_check
  check (source_table in ('sales_documents', 'purchase_documents',
                          'einvoice_consolidations'));

comment on constraint einvoice_documents_source_table_check
  on public.einvoice_documents is
  'What an e-Invoice can be prepared FROM. Named rather than open, so '
  'a fourth kind is a migration and a decision. 0616 added the '
  'consolidation, which is one document standing for many receipts.';

-- ---------------------------------------------------------------------
-- One. The document a consolidation becomes.
-- ---------------------------------------------------------------------
-- The work, with no opinion about who is doing it.
--
-- Split the way `app.post_goods_received_internal` is, and for the same
-- reason: there are two callers with two different answers to "may
-- you". A person is asked `app.can_write_module`; the scheduler has no
-- `auth.uid()` to ask about and is trusted because it reached a
-- function nothing else may execute.
create or replace function app.prepare_consolidated_einvoice_internal(
  p_consolidation_id uuid,
  p_actor uuid)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_con    public.einvoice_consolidations;
  v_org    public.organizations;
  v_ei_id  uuid;
  v_total  numeric;
  v_net    numeric;
  v_tax    numeric;
  v_lines  integer;
begin
  select * into v_con from public.einvoice_consolidations
   where id = p_consolidation_id;
  if not found then
    raise exception 'No such consolidation' using errcode = 'P0002';
  end if;

  -- Already at LHDN. A sale that missed it needs its own e-Invoice --
  -- the same sentence `consolidate_pos_einvoices` uses, because it is
  -- the same rule and somebody reading one should not have to guess
  -- whether the other agrees.
  if v_con.status not in ('draft', 'generated') then
    raise exception
      'The consolidation for % has already been submitted. A sale that '
      'missed it needs its own e-Invoice.',
      to_char(v_con.period_start, 'Mon YYYY')
      using errcode = '23514';
  end if;

  select * into v_org from public.organizations where id = v_con.org_id;
  if not v_org.einvoice_enabled then
    raise exception 'e-Invoice is not enabled for this organization';
  end if;
  if coalesce(v_org.einvoice_tin, v_org.tin) is null then
    raise exception 'Set the organization TIN before submitting e-Invoices';
  end if;

  -- The figures, off the sales documents. Counted here as well as
  -- summed, because an empty consolidation is a thing to refuse rather
  -- than a zero-value e-Invoice for LHDN to wonder about.
  select count(*), coalesce(sum(d.subtotal), 0),
         coalesce(sum(d.tax_amount), 0), coalesce(sum(d.total_amount), 0)
    into v_lines, v_net, v_tax, v_total
    from public.einvoice_consolidation_items i
    join public.sales_documents d on d.id = i.sales_document_id
   where i.consolidation_id = v_con.id;

  if v_lines = 0 then
    raise exception
      'Nothing rolled into the consolidation for %, so there is nothing '
      'to file. Run the rollup first.',
      to_char(v_con.period_start, 'Mon YYYY')
      using errcode = '23514';
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
    v_con.org_id, 'einvoice_consolidations', v_con.id, '01',
    coalesce(v_org.settings ->> 'einvoice_version', '1.0'),
    -- One per period, and derived from the period rather than from a
    -- counter: re-running this must reach the same document rather
    -- than raise a second one for the same month.
    'CONS-' || to_char(v_con.period_start, 'YYYYMM'),
    -- Today, not the period end. The document is issued when it is
    -- issued; back-dating it into the closed month is a lie about when
    -- it was raised, and lateness is LHDN's to notice.
    app.today(),
    coalesce(v_org.base_currency, 'MYR'), 1,
    coalesce(v_org.legal_name, v_org.name),
    coalesce(v_org.einvoice_tin, v_org.tin),
    coalesce(v_org.einvoice_id_type, 'BRN'),
    coalesce(v_org.einvoice_id_value, v_org.registration_no),
    v_org.sst_registration_no, v_org.msic_code, v_org.business_activity,
    v_org.email, v_org.phone,
    jsonb_build_object('line1', v_org.address_line1, 'line2', v_org.address_line2,
      'line3', v_org.address_line3, 'city', v_org.city, 'postcode', v_org.postcode,
      'state', v_org.state_code, 'country', v_org.country_code),
    -- There is no buyer. LHDN's general public TIN, "NA" everywhere a
    -- buyer's details would go, and no contact details at all: a
    -- consolidated e-Invoice is not sent to anybody.
    'General Public', app.general_public_tin(), 'BRN', 'NA', null,
    null, null,
    jsonb_build_object('line1', 'NA', 'city', 'NA', 'postcode', 'NA',
      'state', coalesce(v_org.state_code, '17'),
      'country', coalesce(v_org.country_code, 'MYS')),
    v_net, v_total, 0, v_tax, 0, 0, v_total,
    'queued', p_actor
  )
  on conflict (org_id, source_table, source_id, einvoice_type_code) do update
    set status = 'queued',
        validation_errors = '[]'::jsonb,
        error_code = null,
        error_message = null,
        issue_date = excluded.issue_date,
        einvoice_version = excluded.einvoice_version,
        total_excl_tax = excluded.total_excl_tax,
        total_incl_tax = excluded.total_incl_tax,
        total_tax = excluded.total_tax,
        payable_amount = excluded.payable_amount
  returning id into v_ei_id;

  delete from public.einvoice_lines where einvoice_id = v_ei_id;

  -- One line per receipt, numbered in date then document order so the
  -- same consolidation prepared twice produces the same document.
  insert into public.einvoice_lines (
    org_id, einvoice_id, line_no, classification_code, description,
    quantity, uom_code, unit_price, subtotal, discount_rate, discount_amount,
    tax_type_code, tax_rate, tax_amount, total_excl_tax, total_incl_tax
  )
  select v_con.org_id, v_ei_id,
         row_number() over (order by d.doc_date, d.doc_no, d.id),
         '004',
         -- The receipt number. It is the only thing tying a line of
         -- this document back to a sale, and LHDN's guideline asks for
         -- it by name.
         coalesce(nullif(d.doc_no, ''), d.id::text),
         1, 'C62',
         d.subtotal, d.subtotal, 0, 0,
         -- `06` is "Not Applicable", which is what a till sale carrying
         -- no tax is. Where there IS tax the rate is derived from the
         -- document rather than assumed, because a shop may sell at two
         -- rates in one month.
         case when coalesce(d.tax_amount, 0) = 0 then '06' else '01' end,
         case when coalesce(d.subtotal, 0) = 0 then 0
              else round(coalesce(d.tax_amount, 0) / d.subtotal * 100, 2) end,
         coalesce(d.tax_amount, 0),
         d.subtotal, d.total_amount
    from public.einvoice_consolidation_items i
    join public.sales_documents d on d.id = i.sales_document_id
   where i.consolidation_id = v_con.id;

  update public.einvoice_consolidations
     set einvoice_id = v_ei_id,
         status = 'generated',
         generated_at = now(),
         document_count = v_lines,
         total_amount = v_total
   where id = v_con.id;

  return v_ei_id;
end;
$function$;

comment on function app.prepare_consolidated_einvoice_internal(uuid, uuid) is
  'Turns a month''s rolled-up till sales into the one e-Invoice LHDN '
  'wants for them: general public buyer, one line per receipt, '
  'classification 004. 0616 — until then nothing wrote '
  'einvoice_consolidations.einvoice_id and the seven-day clock ran out '
  'against nothing.';

-- ---------------------------------------------------------------------
-- The two ways in
--
-- A person, who is asked whether they may file for this company; and
-- the scheduler, which is not asked anything because nothing but the
-- service role may execute the function it calls. The second is a
-- separate function rather than a flag on the first: a boolean
-- argument meaning "skip the permission check" is one mistyped call
-- away from being the whole product's authorization.
-- ---------------------------------------------------------------------
create or replace function public.prepare_consolidated_einvoice(
  p_consolidation_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_org uuid;
begin
  select org_id into v_org from public.einvoice_consolidations
   where id = p_consolidation_id;
  if v_org is null then
    raise exception 'No such consolidation' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'einvoice') then
    raise exception 'not permitted to file e-Invoices for this organization'
      using errcode = '42501';
  end if;
  return app.prepare_consolidated_einvoice_internal(
    p_consolidation_id, auth.uid());
end;
$function$;

comment on function public.prepare_consolidated_einvoice(uuid) is
  'Prepares a consolidation for submission, for somebody who may file '
  'for the company. 0616.';

revoke all on function public.prepare_consolidated_einvoice(uuid)
  from public, anon;
grant execute on function public.prepare_consolidated_einvoice(uuid)
  to authenticated;

create or replace function public.scheduler_prepare_consolidated_einvoice(
  p_consolidation_id uuid)
returns uuid
language sql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  -- No actor. The row it writes says nobody raised it, which is true:
  -- a deadline did.
  select app.prepare_consolidated_einvoice_internal(p_consolidation_id, null);
$function$;

comment on function public.scheduler_prepare_consolidated_einvoice(uuid) is
  'The scheduler''s way in, because PostgREST only exposes `public`. '
  'Service role only: a client that could call it could file a '
  'consolidation for any company. 0616.';

revoke all on function public.scheduler_prepare_consolidated_einvoice(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- What the scheduler has to look at
--
-- Across every organization, which is why it is service-role only: no
-- signed-in user has a reason to ask what every OTHER company owes
-- LHDN, and `app.can_write_module` would be the wrong question anyway
-- because there is no caller to ask it about.
--
-- It answers whether the company can actually submit -- credentials,
-- and a certificate where the version needs one -- so the scheduler can
-- tell "nothing to do" apart from "cannot do it", and say which.
-- ---------------------------------------------------------------------
create or replace function public.einvoice_consolidations_due(
  p_within_days integer default 7)
returns table (
  org_id           uuid,
  org_name         text,
  consolidation_id uuid,
  period_start     date,
  period_end       date,
  due_date         date,
  days_left        integer,
  document_count   integer,
  total_amount     numeric,
  status           text,
  einvoice_id      uuid,
  environment      text,
  einvoice_version text,
  has_credentials  boolean,
  has_certificate  boolean)
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select c.org_id,
         o.name,
         c.id,
         c.period_start,
         c.period_end,
         c.due_date,
         (c.due_date - app.today())::integer,
         c.document_count,
         c.total_amount,
         c.status,
         c.einvoice_id,
         coalesce(o.einvoice_environment, 'sandbox'),
         coalesce(o.settings ->> 'einvoice_version', '1.0'),
         cr.client_id is not null and cr.client_secret is not null,
         cr.cert_pem is not null and cr.cert_private_key_pem is not null
    from public.einvoice_consolidations c
    join public.organizations o on o.id = c.org_id
    left join public.einvoice_credentials cr
      on cr.org_id = c.org_id
     and cr.environment = coalesce(o.einvoice_environment, 'sandbox')
   where c.status in ('draft', 'generated')
     and c.document_count > 0
     and o.einvoice_enabled
     -- Overdue ones are included however late, because a deadline that
     -- has passed is the one most worth acting on. `p_within_days`
     -- bounds the FUTURE, not the past.
     and c.due_date <= app.today() + p_within_days
   order by c.due_date, o.name;
$function$;

comment on function public.einvoice_consolidations_due(integer) is
  'Every consolidation coming due or already late, across all '
  'organizations, with whether the company can actually submit it. For '
  'the scheduler; service role only. 0616.';

revoke all on function public.einvoice_consolidations_due(integer)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- And the internal one is nobody's to call directly.
-- ---------------------------------------------------------------------
revoke all on function app.prepare_consolidated_einvoice_internal(uuid, uuid)
  from public, anon, authenticated;
