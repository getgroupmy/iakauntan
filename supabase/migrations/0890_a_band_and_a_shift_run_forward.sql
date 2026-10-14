-- =====================================================================
-- iAkauntan :: 0890 a band and a shift run forward
--
-- Rules only the dialogs said. The leave-band dialog refuses a band that
-- ends before it starts and a negative number of days; the
-- shift-assignment dialog refuses an assignment that ends before it
-- starts. `leave_entitlement_bands` and `employee_shifts` took all
-- three.
--
-- Measured on 14 October 2026, locally, as the owner with the role
-- `authenticated`: a band for service years 5 to 2, a band of -3 days,
-- and a shift assignment ending a month before it starts, all stored. A
-- band that ends before it starts never matches, so
-- `app.leave_entitlement` quietly gives the leave type's default days
-- instead.
--
-- Production on 14 October: six bands, none of them backwards or
-- negative; no shift assignment.
--
-- Answered "add them as checks".
-- =====================================================================

alter table public.leave_entitlement_bands
  add constraint leave_entitlement_bands_years_ck
  check (service_years_from >= 0
         and (service_years_to is null
              or service_years_to >= service_years_from));

alter table public.leave_entitlement_bands
  add constraint leave_entitlement_bands_days_ck
  check (days >= 0);

comment on constraint leave_entitlement_bands_years_ck
  on public.leave_entitlement_bands is
  'A band of service runs forward from a year that is not negative. A '
  'band ending before it starts never matches and gives the default '
  'days; the dialog says so first. 0890.';

comment on constraint leave_entitlement_bands_days_ck
  on public.leave_entitlement_bands is
  'A band grants nothing or more. 0890.';

alter table public.employee_shifts
  add constraint employee_shifts_dates_ck
  check (effective_to is null or effective_to >= effective_from);

comment on constraint employee_shifts_dates_ck on public.employee_shifts is
  'An assignment ends on or after the day it starts; the dialog says so '
  'first. 0890.';
