-- =====================================================================
-- iAkauntan :: 0897 an officer and a charge run forward
--
-- Rules only the sheets said. The officer sheet will not pick a
-- cessation before the appointment; the charge sheet will not pick a
-- lodgement or a satisfaction before the charge was created, nor a
-- memorandum of satisfaction before the satisfaction it records. The
-- tables, which the client writes directly, took all four.
--
-- Measured on 14 October 2026, locally, as the owner with the role
-- `authenticated`: a director ceasing thirty days before appointment;
-- charges lodged and satisfied thirty days before they were created;
-- a memorandum filed twenty days before the satisfaction. All stored.
--
-- Production on 14 October: none out of order -- no officer has
-- ceased, and there are no charges.
--
-- Answered "the four the sheets hold, as checks". The same day is
-- allowed, as in `0890`; a date not given is not compared. A
-- beneficial owner ceasing before entering the register was stored as
-- well, but that sheet states no such rule, and it is left for when it
-- does.
-- =====================================================================

alter table public.corp_officers
  add constraint corp_officers_ceased_after_appointed_ck
  check (resigned_on >= appointed_on);

alter table public.corp_charges
  add constraint corp_charges_lodged_after_created_ck
  check (registered_on >= created_on);

alter table public.corp_charges
  add constraint corp_charges_satisfied_after_created_ck
  check (satisfied_on >= created_on);

alter table public.corp_charges
  add constraint corp_charges_memorandum_after_satisfied_ck
  check (satisfaction_filed_on >= satisfied_on);

comment on constraint corp_officers_ceased_after_appointed_ck
  on public.corp_officers is
  'An officer ceases on or after the day of appointment. The officer '
  'sheet says so first. 0897.';

comment on constraint corp_charges_lodged_after_created_ck
  on public.corp_charges is
  'A charge is lodged with SSM on or after the day it was created. 0897.';

comment on constraint corp_charges_satisfied_after_created_ck
  on public.corp_charges is
  'A charge is satisfied on or after the day it was created. 0897.';

comment on constraint corp_charges_memorandum_after_satisfied_ck
  on public.corp_charges is
  'The memorandum of satisfaction is filed on or after the day the '
  'charge was satisfied. 0897.';
