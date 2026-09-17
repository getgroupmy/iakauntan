-- =====================================================================
-- iAkauntan :: 0584 billing a month twice
--
-- `0582` documented these two as "not safe to run twice" and said
-- nothing looks for a run already covering the period. That was too
-- strong, and getting it exactly right is the whole of this migration.
--
-- What was already true: both tables carry a unique constraint on
-- (site or scheme, period_from, period_to), and the run row is inserted
-- BEFORE any invoice is written. So re-raising an IDENTICAL period was
-- already refused, atomically, with nothing billed. `0582` implied
-- otherwise and this corrects it.
--
-- What was actually broken is narrower and worse for being narrower:
-- the constraint compares three columns for equality, so it catches
-- only the identical period. January, and then the fifteenth of January
-- to the fifteenth of February, are different rows. Both are allowed.
-- Every tenant is billed twice for the overlap, the invoices are
-- POSTED, and nothing says a word.
--
-- Overlap is not a hypothetical shape. It is what a change of billing
-- cycle looks like, and what a correction looks like when somebody
-- decides the period should have started on the fifteenth.
--
-- ---------------------------------------------------------------------
-- What this does instead
--
-- An explicit check for a run covering ANY of the days asked for,
-- refusing with the run number and the date it was raised -- so the
-- answer is "run RR-0006, raised 3 Feb" rather than a unique-violation
-- on a constraint name, which is what the identical-period case used to
-- give and is no way to tell a property manager anything.
--
-- And an advisory lock on the site or scheme for the transaction,
-- because the check reads the table and then writes to it: without it,
-- two people pressing the button together both read "nothing yet" and
-- both bill. A monthly button is not a busy one.
--
-- ---------------------------------------------------------------------
-- Why not an exclusion constraint, which would be airtight
--
-- `btree_gist` is installed and `exclude using gist (site_id with =,
-- daterange(...) with &&)` would enforce this in the schema rather than
-- in a function. It is the better tool and it is deliberately not used
-- here.
--
-- There is NO WAY TO UNDO A RUN in this schema -- no `void_rent_run`,
-- nothing. The invoices can be voided one at a time; the run row stays
-- for ever. A permanent overlap constraint would mean a period raised
-- with the wrong dates can never be raised correctly, by anybody, with
-- no way out short of a migration. The refusal below can at least be
-- reasoned about and, if a company genuinely needs it, lifted for one
-- call by somebody who understands what they are doing.
--
-- The right answer is an undo, and that is a feature rather than a
-- guard. Written down here so the next person knows the constraint was
-- considered and why it is absent.
--
-- Restated from `pg_get_functiondef`, not retyped: `0565` rewrote
-- policies from stale text and silently undid two later migrations.
-- =====================================================================

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

-- `0165`'s event trigger strips EXECUTE from PUBLIC and anon on every
-- CREATE FUNCTION in these schemas, and CREATE OR REPLACE fires it. A
-- restated function that is not re-granted is a function nobody can
-- call.
grant execute on function public.raise_rent_invoices(uuid, date, date, date) to authenticated;
grant execute on function public.raise_strata_charges(uuid, date, date, date) to authenticated;

comment on function public.raise_rent_invoices(uuid, date, date, date) is
  'Invoices every active tenancy at a site for a period, POSTS each '
  'invoice, and returns the run. REFUSES A PERIOD ALREADY COVERED by an '
  'earlier run — any overlap at all, not only the same dates — and '
  'names the run and when it was raised, because the whole cost of '
  'getting this wrong is every tenant invoiced twice. Holds an advisory '
  'lock on the site, so two people pressing the button together cannot '
  'both pass the check. Refuses when no tenancy covers the period, and '
  'that is the only guard against an accidental press on the right '
  'dates. `rent_preview` shows what would be raised. The due date '
  'defaults to the start of the period. NOTE there is no way to undo a '
  'run: the invoices can be voided one at a time, the run row stays. '
  'Needs `can_post` and the `property_nonstrata` module.';

comment on function public.raise_strata_charges(uuid, date, date, date) is
  'Charges every parcel in a scheme for a period — maintenance at the '
  'rate per share unit, plus the sinking fund contribution as a second '
  'line — POSTS each invoice, and returns the run. REFUSES A PERIOD '
  'ALREADY COVERED by an earlier run, overlapping or identical, naming '
  'it. Holds an advisory lock on the scheme. Refuses outright when no '
  'rate is in force on the period start — an AGM resolution sets the '
  'rate before charges can be raised — and refuses when any parcel has '
  'no owner on record, rather than skipping it, because a parcel '
  'silently left out of a charge run is one nobody discovers until the '
  'fund is short. `strata_charge_preview` shows what would be raised. '
  'NOTE there is no way to undo a run. Needs `can_post` and the '
  '`property_strata` module.';
