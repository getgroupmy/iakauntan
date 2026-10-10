-- =====================================================================
-- iAkauntan :: 0806 a billing run is undone by undoing it
--
-- `raise_rent_invoices` and `raise_strata_charges` invoice every
-- tenancy on a site, or every parcel in a scheme, for a period, and
-- record the run in `rent_runs` / `strata_charge_runs` with a line per
-- invoice. Each refuses a period that overlaps a run whose `voided_at`
-- is null -- "Raising it again would invoice every tenant twice" -- and
-- `void_rent_run` / `void_strata_charge_run` are the way back: they
-- refuse while any invoice is paid or accepted by LHDN, void each
-- invoice, and only then stamp the run. The app only reads the four
-- tables. But `authenticated` held insert, update and delete on all of
-- them, the policies asking `can_write_module` -- which `0501` found
-- answers 'write' for any member with no access type, most people.
--
-- Measured on 10 October 2026, locally, as the owner with the role
-- `authenticated`: January's rent raised for two tenancies (RM5,000),
-- the run's `voided_at` set by hand -- its invoices untouched -- and
-- January raised again: four live invoices, RM10,000, every tenant
-- invoiced twice. The strata run carries the same check on the same
-- column.
--
-- Answered "read-only to clients", as `0740` and `0804`: the grants are
-- revoked and the write policies dropped -- the tables' own and the
-- restrictive `module_gate_` ones, which `table_grants.sql` refuses to
-- see left behind a command nobody holds. Reading, and
-- `module_gate_select`, stay. The four functions are definers.
--
-- Production held no run of either kind on 10 October.
-- =====================================================================

revoke insert, update, delete on public.rent_runs from authenticated, anon;
drop policy if exists rent_runs_insert on public.rent_runs;
drop policy if exists rent_runs_update on public.rent_runs;
drop policy if exists rent_runs_delete on public.rent_runs;
drop policy if exists module_gate_insert on public.rent_runs;
drop policy if exists module_gate_update on public.rent_runs;
drop policy if exists module_gate_delete on public.rent_runs;

revoke insert, update, delete on public.rent_run_lines from authenticated, anon;
drop policy if exists rent_run_lines_insert on public.rent_run_lines;
drop policy if exists rent_run_lines_update on public.rent_run_lines;
drop policy if exists rent_run_lines_delete on public.rent_run_lines;
drop policy if exists module_gate_insert on public.rent_run_lines;
drop policy if exists module_gate_update on public.rent_run_lines;
drop policy if exists module_gate_delete on public.rent_run_lines;

revoke insert, update, delete on public.strata_charge_runs from authenticated, anon;
drop policy if exists strata_charge_runs_insert on public.strata_charge_runs;
drop policy if exists strata_charge_runs_update on public.strata_charge_runs;
drop policy if exists strata_charge_runs_delete on public.strata_charge_runs;
drop policy if exists module_gate_insert on public.strata_charge_runs;
drop policy if exists module_gate_update on public.strata_charge_runs;
drop policy if exists module_gate_delete on public.strata_charge_runs;

revoke insert, update, delete on public.strata_charge_lines from authenticated, anon;
drop policy if exists strata_charge_lines_insert on public.strata_charge_lines;
drop policy if exists strata_charge_lines_update on public.strata_charge_lines;
drop policy if exists strata_charge_lines_delete on public.strata_charge_lines;
drop policy if exists module_gate_insert on public.strata_charge_lines;
drop policy if exists module_gate_update on public.strata_charge_lines;
drop policy if exists module_gate_delete on public.strata_charge_lines;

comment on table public.rent_runs is
  'A month (or other period) of rent raised for a site''s tenancies. WRITTEN ONLY BY FUNCTION -- 0806 revoked '
  'insert, update and delete from clients and dropped the write policies; '
  'raise_rent_invoices writes it and void_rent_run undoes it, voiding the invoices first. Members '
  'with the module read it.';

comment on table public.rent_run_lines is
  'The invoice a rent run raised for one tenancy. WRITTEN ONLY BY FUNCTION -- 0806 revoked '
  'insert, update and delete from clients and dropped the write policies; '
  'raise_rent_invoices writes it and void_rent_run undoes it, voiding the invoices first. Members '
  'with the module read it.';

comment on table public.strata_charge_runs is
  'A period of maintenance and sinking fund charges raised for a scheme. WRITTEN ONLY BY FUNCTION -- 0806 revoked '
  'insert, update and delete from clients and dropped the write policies; '
  'raise_strata_charges writes it and void_strata_charge_run undoes it, voiding the invoices first. Members '
  'with the module read it.';

comment on table public.strata_charge_lines is
  'The invoice a strata charge run raised for one parcel. WRITTEN ONLY BY FUNCTION -- 0806 revoked '
  'insert, update and delete from clients and dropped the write policies; '
  'raise_strata_charges writes it and void_strata_charge_run undoes it, voiding the invoices first. Members '
  'with the module read it.';
