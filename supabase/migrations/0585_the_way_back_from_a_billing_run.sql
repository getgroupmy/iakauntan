-- =====================================================================
-- iAkauntan :: 0585 the way back from a billing run
--
-- `0584` refused to raise a period twice and said, in its own header,
-- why it stopped short of an exclusion constraint: THERE IS NO WAY TO
-- UNDO A RUN. A period raised with the wrong dates could never be
-- raised correctly, by anybody, short of a migration. That is the
-- feature, and this is it.
--
-- ---------------------------------------------------------------------
-- Why voiding a run is all-or-nothing
--
-- `void_sales_document` refuses an invoice with a payment against it,
-- and one that LHDN has accepted. So a run where some tenants have paid
-- cannot be fully undone, and the tempting thing is to void what can be
-- voided and report the rest.
--
-- That would be wrong, and not merely untidy. Voiding a run makes its
-- period raisable again. A run with forty invoices voided and ten
-- standing, marked voided, would let somebody re-raise the period --
-- and those ten tenants would be billed a second time. The half-measure
-- reintroduces exactly the bug `0584` closed.
--
-- So it refuses, names how many invoices are in the way, and changes
-- nothing. The person deals with those ten and tries again.
--
-- ---------------------------------------------------------------------
-- Voided, not deleted, and what that costs
--
-- The run row stays: it is a record of something that happened, and
-- `rent_run_lines` still names which tenancy was billed what. But the
-- unique constraint on (site, period_from, period_to) would then block
-- re-raising the corrected period, so it becomes a PARTIAL unique index
-- over the live runs only. Both halves are needed; either alone leaves
-- the undo unable to undo anything.
--
-- The overlap check in `0584` learns the same word: a voided run covers
-- no days.
-- =====================================================================

alter table public.rent_runs
  add column voided_at timestamptz,
  add column voided_by uuid references auth.users(id),
  add column void_reason text;

alter table public.strata_charge_runs
  add column voided_at timestamptz,
  add column voided_by uuid references auth.users(id),
  add column void_reason text;

-- A voided run no longer holds its period. Partial, so the live runs
-- keep exactly the guarantee they had.
alter table public.rent_runs
  drop constraint rent_runs_site_id_period_from_period_to_key;
create unique index rent_runs_live_period_key
  on public.rent_runs (site_id, period_from, period_to)
  where voided_at is null;

alter table public.strata_charge_runs
  drop constraint strata_charge_runs_scheme_id_period_from_period_to_key;
create unique index strata_charge_runs_live_period_key
  on public.strata_charge_runs (scheme_id, period_from, period_to)
  where voided_at is null;

CREATE OR REPLACE FUNCTION public.raise_rent_invoices(p_site_id uuid, p_period_from date, p_period_to date, p_due_date date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org uuid;
  v_run uuid;
  v_line record;
  v_invoice uuid;
  v_due date;
  v_count integer := 0;
  v_total numeric(18, 2) := 0;
  v_rent_ac uuid;
  v_clash public.rent_runs;
begin
  select org_id into v_org from public.property_sites where id = p_site_id;
  if v_org is null then
    raise exception 'No such site' using errcode = 'P0002';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges to raise invoices'
      using errcode = '42501';
  end if;
  if not app.has_module(v_org, 'property_nonstrata') then
    raise exception
      'The non-strata property module is not switched on for this company'
      using errcode = '42501';
  end if;

  -- One raise at a time for this site. The check below reads
  -- `rent_runs` and then writes to it, and without the lock two people
  -- pressing the button together would both read "nothing yet" and both
  -- bill. A monthly button is not a busy one, so holding the site for
  -- the length of the transaction costs nothing anybody will notice.
  perform pg_advisory_xact_lock(hashtextextended(p_site_id::text, 0));

  -- Anything already raised that COVERS ANY OF THESE DAYS. The unique
  -- constraint on (site_id, period_from, period_to) already refused an
  -- identical period, but only an identical one: January, then the
  -- fifteenth of January to the fifteenth of February, billed the
  -- overlap twice and nothing said so.
  select * into v_clash from public.rent_runs rr
   where rr.site_id = p_site_id
     and rr.voided_at is null
     and daterange(rr.period_from, rr.period_to, '[]')
      && daterange(p_period_from, p_period_to, '[]')
   order by rr.period_from
   limit 1;

  if v_clash.id is not null then
    raise exception
      'Rent for this site has already been raised for % to % (run %, on '
      '%). Raising it again would invoice every tenant twice. Void that '
      'run''s invoices first if it was wrong.',
      v_clash.period_from, v_clash.period_to, v_clash.run_no,
      to_char(v_clash.raised_at, 'DD Mon YYYY')
      using errcode = '23505';
  end if;

  v_due := coalesce(p_due_date, p_period_from);
  v_rent_ac := app.property_income_account(v_org, 'rent');

  insert into public.rent_runs
    (org_id, site_id, run_no, period_from, period_to, raised_by)
  values (v_org, p_site_id,
          app.next_document_number_internal(v_org, 'rent_run'),
          p_period_from, p_period_to, auth.uid())
  returning id into v_run;

  for v_line in
    select * from public.rent_preview(p_site_id, p_period_from, p_period_to)
  loop
    insert into public.sales_documents (
      org_id, doc_type, doc_no, doc_date, due_date, contact_id,
      subject, reference, currency, exchange_rate, status)
    values (
      v_org, 'invoice',
      app.next_document_number_internal(v_org, 'invoice'),
      p_period_from, v_due, v_line.tenant_contact_id,
      format('Rent — %s', v_line.unit_no),
      format('%s to %s', v_line.charge_from, v_line.charge_to),
      app.base_currency(v_org), 1, 'draft')
    returning id into v_invoice;

    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description,
       quantity, unit_price, account_id, tax_rate)
    values (v_org, v_invoice, 1, 'item',
            format('Rent for %s, %s to %s',
                   v_line.unit_no, v_line.charge_from, v_line.charge_to),
            1, v_line.amount, v_rent_ac, 0);

    insert into public.rent_run_lines
      (org_id, run_id, tenancy_id, months, amount, invoice_id)
    values (v_org, v_run, v_line.tenancy_id, v_line.months, v_line.amount,
            v_invoice);

    perform app.post_sales_document_internal(v_invoice);

    v_count := v_count + 1;
    v_total := v_total + v_line.amount;
  end loop;

  if v_count = 0 then
    raise exception
      'No active tenancy at this site covers % to %.',
      p_period_from, p_period_to using errcode = 'P0002';
  end if;

  update public.rent_runs
     set tenancies = v_count, total_rent = v_total
   where id = v_run;

  return v_run;
end $function$;

CREATE OR REPLACE FUNCTION public.raise_strata_charges(p_scheme_id uuid, p_period_from date, p_period_to date, p_due_date date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  s public.strata_schemes;
  r public.strata_charge_rates;
  v_run uuid;
  v_months numeric;
  v_line record;
  v_invoice uuid;
  v_due date;
  v_parcels integer := 0;
  v_maint numeric(18, 2) := 0;
  v_sink numeric(18, 2) := 0;
  v_maint_ac uuid;
  v_sink_ac uuid;
  v_clash public.strata_charge_runs;
begin
  select * into s from public.strata_schemes where id = p_scheme_id;
  if not found then
    raise exception 'No such strata scheme' using errcode = 'P0002';
  end if;
  if not app.can_post(s.org_id) then
    raise exception 'Insufficient privileges to raise charges'
      using errcode = '42501';
  end if;
  if not app.has_module(s.org_id, 'property_strata') then
    raise exception 'The strata module is not switched on for this company'
      using errcode = '42501';
  end if;

  -- Same lock and same reason as `raise_rent_invoices`.
  perform pg_advisory_xact_lock(hashtextextended(p_scheme_id::text, 0));

  select * into v_clash from public.strata_charge_runs cr
   where cr.scheme_id = p_scheme_id
     and cr.voided_at is null
     and daterange(cr.period_from, cr.period_to, '[]')
      && daterange(p_period_from, p_period_to, '[]')
   order by cr.period_from
   limit 1;

  if v_clash.id is not null then
    raise exception
      'Charges for this scheme have already been raised for % to % (run '
      '%, on %). Raising them again would invoice every parcel twice. '
      'Void that run''s invoices first if it was wrong.',
      v_clash.period_from, v_clash.period_to, v_clash.run_no,
      to_char(v_clash.raised_at, 'DD Mon YYYY')
      using errcode = '23505';
  end if;

  r := app.strata_rate_on(p_scheme_id, p_period_from);
  if r.id is null then
    raise exception
      'No charge rate is in force on %. An AGM resolution sets the rate per '
      'share unit before charges can be raised.', p_period_from
      using errcode = 'P0002';
  end if;

  v_months := app.months_between(p_period_from, p_period_to);
  v_due := coalesce(p_due_date, p_period_from);

  v_maint_ac := app.property_income_account(s.org_id, 'maintenance');
  v_sink_ac := app.property_income_account(s.org_id, 'sinking');

  insert into public.strata_charge_runs
    (org_id, scheme_id, run_no, period_from, period_to, rate_id, months,
     raised_by)
  values (s.org_id, p_scheme_id,
          app.next_document_number_internal(s.org_id, 'strata_charge'),
          p_period_from, p_period_to, r.id, v_months, auth.uid())
  returning id into v_run;

  for v_line in
    select * from public.strata_charge_preview(
      p_scheme_id, p_period_from, p_period_to)
  loop
    if v_line.owner_contact_id is null then
      raise exception
        'Parcel % has no owner on record, so there is nobody to invoice. '
        'Set the owner before raising charges.', v_line.unit_no
        using errcode = '23502';
    end if;

    insert into public.sales_documents (
      org_id, doc_type, doc_no, doc_date, due_date, contact_id,
      subject, reference, currency, exchange_rate, status)
    values (
      s.org_id, 'invoice',
      app.next_document_number_internal(s.org_id, 'invoice'),
      p_period_from, v_due, v_line.owner_contact_id,
      format('Maintenance charges — %s', v_line.unit_no),
      format('%s to %s', p_period_from, p_period_to),
      app.base_currency(s.org_id), 1, 'draft')
    returning id into v_invoice;

    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description,
       quantity, unit_price, account_id, tax_rate)
    values
      (s.org_id, v_invoice, 1, 'item',
       format('Maintenance charges, %s share units at %s per unit per month',
              v_line.share_units, r.rate_per_share_unit),
       1, v_line.maintenance_amount, v_maint_ac, 0),
      (s.org_id, v_invoice, 2, 'item',
       format('Contribution to the sinking fund at %s%% of the charges',
              r.sinking_fund_percent),
       1, v_line.sinking_amount, v_sink_ac, 0);

    insert into public.strata_charge_lines
      (org_id, run_id, unit_id, share_units, maintenance_amount,
       sinking_amount, invoice_id)
    values (s.org_id, v_run, v_line.unit_id, v_line.share_units,
            v_line.maintenance_amount, v_line.sinking_amount, v_invoice);

    perform app.post_sales_document_internal(v_invoice);

    v_parcels := v_parcels + 1;
    v_maint := v_maint + v_line.maintenance_amount;
    v_sink := v_sink + v_line.sinking_amount;
  end loop;

  if v_parcels = 0 then
    raise exception
      'No parcel in this scheme is chargeable. A parcel needs allocated '
      'share units and an owner before it can be billed.'
      using errcode = 'P0002';
  end if;

  update public.strata_charge_runs
     set parcels = v_parcels, total_maintenance = v_maint, total_sinking = v_sink
   where id = v_run;

  return v_run;
end $function$;

create or replace function public.void_rent_run(
  p_run uuid, p_reason text default null)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_run  public.rent_runs;
  v_paid integer;
  v_line record;
  v_n    integer := 0;
begin
  select * into v_run from public.rent_runs where id = p_run;
  if v_run.id is null then
    raise exception 'No such rent run.' using errcode = 'P0002';
  end if;
  -- The same bar as raising it. Undoing a billing run is a posting
  -- decision, not a tidying one.
  if not app.can_post(v_run.org_id) then
    raise exception 'Insufficient privileges to void a rent run'
      using errcode = '42501';
  end if;
  if v_run.voided_at is not null then
    raise exception 'That run was already voided on %.',
      to_char(v_run.voided_at, 'DD Mon YYYY') using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception
      'Say why. A billing run undone without a reason is the one the '
      'auditor asks about.' using errcode = '23514';
  end if;

  -- Counted and refused before anything is touched, so the message can
  -- say how many are in the way rather than stopping partway through
  -- and leaving the caller to work out where.
  select count(*) into v_paid
    from public.rent_run_lines l
    join public.sales_documents d on d.id = l.invoice_id
   where l.run_id = p_run
     and (d.paid_amount > 0 or d.einvoice_status = 'valid');
  if v_paid > 0 then
    raise exception
      'This run cannot be undone: % of its invoices have been paid or '
      'accepted by LHDN. Deal with those first — voiding the rest would '
      'free the period to be billed again, and those tenants would be '
      'invoiced twice.', v_paid
      using errcode = '23514';
  end if;

  for v_line in
    select l.invoice_id from public.rent_run_lines l
     where l.run_id = p_run and l.invoice_id is not null
  loop
    perform public.void_sales_document(
      v_line.invoice_id,
      format('Rent run %s voided: %s', v_run.run_no, btrim(p_reason)));
    v_n := v_n + 1;
  end loop;

  update public.rent_runs
     set voided_at = now(), voided_by = auth.uid(),
         void_reason = btrim(p_reason)
   where id = p_run;

  return v_n;
end;
$function$;

create or replace function public.void_strata_charge_run(
  p_run uuid, p_reason text default null)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_run  public.strata_charge_runs;
  v_paid integer;
  v_line record;
  v_n    integer := 0;
begin
  select * into v_run from public.strata_charge_runs where id = p_run;
  if v_run.id is null then
    raise exception 'No such charge run.' using errcode = 'P0002';
  end if;
  if not app.can_post(v_run.org_id) then
    raise exception 'Insufficient privileges to void a charge run'
      using errcode = '42501';
  end if;
  if v_run.voided_at is not null then
    raise exception 'That run was already voided on %.',
      to_char(v_run.voided_at, 'DD Mon YYYY') using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception
      'Say why. A charge run undone without a reason is the one the '
      'auditor asks about.' using errcode = '23514';
  end if;

  select count(*) into v_paid
    from public.strata_charge_lines l
    join public.sales_documents d on d.id = l.invoice_id
   where l.run_id = p_run
     and (d.paid_amount > 0 or d.einvoice_status = 'valid');
  if v_paid > 0 then
    raise exception
      'This run cannot be undone: % of its invoices have been paid or '
      'accepted by LHDN. Deal with those first — voiding the rest would '
      'free the period to be billed again, and those owners would be '
      'invoiced twice.', v_paid
      using errcode = '23514';
  end if;

  for v_line in
    select l.invoice_id from public.strata_charge_lines l
     where l.run_id = p_run and l.invoice_id is not null
  loop
    perform public.void_sales_document(
      v_line.invoice_id,
      format('Charge run %s voided: %s', v_run.run_no, btrim(p_reason)));
    v_n := v_n + 1;
  end loop;

  update public.strata_charge_runs
     set voided_at = now(), voided_by = auth.uid(),
         void_reason = btrim(p_reason)
   where id = p_run;

  return v_n;
end;
$function$;

-- `0165` again: CREATE OR REPLACE fires the event trigger that strips
-- EXECUTE, and a new function never had it.
grant execute on function public.raise_rent_invoices(uuid, date, date, date) to authenticated;
grant execute on function public.raise_strata_charges(uuid, date, date, date) to authenticated;
grant execute on function public.void_rent_run(uuid, text) to authenticated;
grant execute on function public.void_strata_charge_run(uuid, text) to authenticated;

comment on function public.void_rent_run(uuid, text) is
  'Undoes a rent run: voids every invoice it raised, reversing each '
  'one''s journal, and frees the period to be raised again. Returns how '
  'many invoices were voided. ALL OR NOTHING — it refuses outright when '
  'any invoice has a payment against it or has been accepted by LHDN, '
  'and says how many, because voiding the rest would free the period '
  'while those invoices still stand and the tenants who hold them would '
  'be billed a second time. A reason is required: a billing run undone '
  'without one is the one the auditor asks about. The run row stays, '
  'marked voided, because it is a record of something that happened. '
  'Needs `can_post`, the same bar as raising it.';

comment on function public.void_strata_charge_run(uuid, text) is
  'The same for a strata charge run: voids every invoice, reverses '
  'every journal, frees the period, returns the count. Refuses outright '
  'when any invoice is paid or accepted by LHDN, for the same reason — '
  'a partly undone run whose period is free again bills those owners '
  'twice. A reason is required. Needs `can_post`.';
