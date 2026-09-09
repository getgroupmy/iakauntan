-- Team & access embeds profiles through the FK names below
-- (requester:profiles!payslip_access_requests_requested_by_fkey, decider:profiles!..._decided_by_fkey).
-- Those constraints pointed at auth.users, which PostgREST cannot traverse, so the
-- request failed with PGRST200 and the page rebooted the app in a loop.
-- Keep the auth.users constraints under new names; give the expected names to FKs on public.profiles.

alter table public.payslip_access_requests
  rename constraint payslip_access_requests_requested_by_fkey
  to payslip_access_requests_requested_by_auth_fkey;

alter table public.payslip_access_requests
  rename constraint payslip_access_requests_decided_by_fkey
  to payslip_access_requests_decided_by_auth_fkey;

alter table public.payslip_access_requests
  add constraint payslip_access_requests_requested_by_fkey
  foreign key (requested_by) references public.profiles(id) on delete cascade;

alter table public.payslip_access_requests
  add constraint payslip_access_requests_decided_by_fkey
  foreign key (decided_by) references public.profiles(id);

notify pgrst, 'reload schema';
