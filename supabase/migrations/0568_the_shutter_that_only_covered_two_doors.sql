-- =====================================================================
-- iAkauntan :: 0568 the shutter that only covered two doors
--
-- `0564` made `maintenance_mode` real after five hundred migrations of
-- it being decoration, and said this in its own header:
--
--   BLOCKING WRITES is `can_write` and `can_admin` and nothing else.
--   Those two are this schema's own vocabulary for "may change
--   things", and every policy that guards a write already asks one of
--   them -- so gating them gates the writes.
--
-- The second half of that sentence is false, and counting says how
-- false. `can_write_module` alone guards **162 policies**; `can_post`
-- guards 50, `can_manage_hr` 52 and `can_run_payroll` 21. None of them
-- asks `can_write`, because `0127` built the per-module permission as
-- its own answer to "may this person change things here" and `0018`
-- built `can_post` as its own answer to "may this person put something
-- in the ledger".
--
-- So with the shutter down: a till kept selling, a journal could be
-- posted, a payroll run could be approved, and an employee record
-- could be changed. What actually stopped was invoices and settings.
--
-- ---------------------------------------------------------------------
-- Which is worse than never having built it
--
-- `0396` states the rule this breaks, and `0564` quoted it while
-- breaking it: **a control that appears to have been applied is worse
-- than one that is absent.** An operator who turns maintenance on and
-- watches the banner appear has been told the writes stopped. They did
-- not, and the half that did not stop is the half that touches the
-- ledger.
--
-- ---------------------------------------------------------------------
-- What is gated, and what is deliberately not
--
-- Gated: every remaining guard that answers "may this person change
-- something" --  `can_post`, `can_write_module`, `can_run_payroll`,
-- `can_manage_hr`, `can_void_pos`, `can_discount_pos`,
-- `can_add_company` and `can_manage_firm`.
--
-- Not gated, and each for its own reason:
--
--   `can_read_ledger`, `can_read_module`, `can_read_attachment` are
--   reads. `0564` is explicit that somebody looking at an invoice when
--   the shutter comes down goes on looking at it.
--
--   `is_platform_admin` stays open, as `0564` left it, because the
--   operator who turned maintenance on has to be able to turn it off.
--
--   `can_attach_to`'s bug-report path stays open. `0460` made a
--   screenshot on a fault report reachable by somebody holding no
--   write permission at all, and maintenance is precisely when people
--   file them. The rest of that function already routes through
--   `can_write` and is therefore already shut.
--
-- ---------------------------------------------------------------------
-- The grant trap, for the second time
--
-- `0165` strips EXECUTE from PUBLIC on every CREATE FUNCTION in `app`
-- and `public`, and a REPLACE fires it. Four of these eight
-- (`can_post`, `can_run_payroll`, `can_manage_hr`, `can_manage_firm`)
-- carry no grant of their own and are reachable only through that
-- implicit PUBLIC one -- the same state `can_write` and `can_admin`
-- were in when `0564` restated them and took the whole suite down with
-- "permission denied for function can_admin". Every grant below is
-- explicit for that reason, and `maintenance_mode.sql` asserts them.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Putting something in the ledger
-- ---------------------------------------------------------------------
create or replace function app.can_post(p_org_id uuid)
returns boolean language sql stable
set search_path = public, pg_temp
as $$
  select not app.in_maintenance()
     and app.has_org_role(p_org_id,
           array['owner','admin','accountant']::app.member_role[]);
$$;

comment on function app.can_post(uuid) is
  'Anyone who may post to the ledger, and nobody at all while the '
  'platform is closed for work. 0568.';

grant execute on function app.can_post(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- The per-module write permission
--
-- The one that matters most by volume: 162 policies ask it, and until
-- now every one of them said yes with the shutter down.
-- ---------------------------------------------------------------------
create or replace function app.can_write_module(p_org_id uuid, p_module text)
returns boolean language sql stable
set search_path = public, pg_temp
as $$
  select not app.in_maintenance()
     and app.module_access(p_org_id, p_module) = 'write';
$$;

comment on function app.can_write_module(uuid, text) is
  'Whether this person may change things in this module, and nobody '
  'may while the platform is closed for work. 0568.';

grant execute on function app.can_write_module(uuid, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Payroll and personnel
-- ---------------------------------------------------------------------
create or replace function app.can_run_payroll(p_org_id uuid)
returns boolean language sql stable
set search_path = public, pg_temp
as $$
  select not app.in_maintenance()
     and app.has_org_role(p_org_id,
           array['owner','admin','hr_manager','accountant']::app.member_role[]);
$$;

comment on function app.can_run_payroll(uuid) is
  'Anyone who may run payroll, and nobody while the platform is closed '
  'for work. Approving a run is the write that pays people. 0568.';

grant execute on function app.can_run_payroll(uuid)
  to authenticated, service_role;

create or replace function app.can_manage_hr(p_org_id uuid)
returns boolean language sql stable
set search_path = public, pg_temp
as $$
  select not app.in_maintenance()
     and app.has_org_role(p_org_id,
           array['owner','admin','hr_manager']::app.member_role[]);
$$;

comment on function app.can_manage_hr(uuid) is
  'Anyone who may change personnel records, and nobody while the '
  'platform is closed for work. 0568.';

grant execute on function app.can_manage_hr(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- The till
--
-- Neither of these guards a policy; both are asked inside functions
-- that write. A shutter that stopped the invoices and left the till
-- taking money would be the most visible version of this fault.
-- ---------------------------------------------------------------------
create or replace function app.can_void_pos(p_org_id uuid)
returns boolean language sql stable
set search_path = public, pg_temp
as $$
  select not app.in_maintenance()
     and app.has_permission(p_org_id, 'pos_void');
$$;

grant execute on function app.can_void_pos(uuid)
  to authenticated, service_role;

create or replace function app.can_discount_pos(p_org_id uuid)
returns boolean language sql stable
set search_path = public, pg_temp
as $$
  select not app.in_maintenance()
     and app.has_permission(p_org_id, 'pos_discount');
$$;

grant execute on function app.can_discount_pos(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Standing up a company, and a practice's own membership
-- ---------------------------------------------------------------------
create or replace function app.can_add_company()
returns boolean language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select not app.in_maintenance()
     and auth.uid() is not null
     and (
       -- Nobody's first company is an add-on. Ownership, not
       -- membership: being invited into a colleague's books is not
       -- something the person spent anything on.
       not exists (
         select 1 from public.org_members m
          where m.user_id = auth.uid()
            and m.role = 'owner' and m.status = 'active')
       or exists (
         select 1 from public.org_members m
          where m.user_id = auth.uid()
            and m.role = 'owner' and m.status = 'active'
            and app.has_module(m.org_id, 'multi_company')));
$$;

grant execute on function app.can_add_company()
  to authenticated, service_role;

create or replace function app.can_manage_firm(p_firm_id uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp
as $$
  select not app.in_maintenance()
     and exists (
       select 1 from public.firm_members m
        where m.firm_id = p_firm_id
          and m.user_id = auth.uid()
          and m.status = 'active'
          -- `partner`, not `owner`. A practice's roles are its own
          -- vocabulary and not the company roles used everywhere else.
          and m.role in ('partner', 'manager'));
$$;

grant execute on function app.can_manage_firm(uuid)
  to authenticated, service_role;
