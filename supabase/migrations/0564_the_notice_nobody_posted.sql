-- =====================================================================
-- iAkauntan :: 0564 the notice nobody posted
--
-- `0018` seeded `maintenance_mode` and described it in its own row as
-- "Show a maintenance banner and block writes". It has never done
-- either. `0563` closed the same fault on `signup_enabled` the day
-- before this, and `0298` closed it on `nav_grouping` before that -- so
-- this is the third setting in one table that said what it did and did
-- nothing, and the last of them.
--
-- Two promises, and they are kept in two different places, because they
-- are two different kinds of thing.
--
-- ---------------------------------------------------------------------
-- The banner: one function, two audiences
--
-- The notice has to reach somebody standing at the sign-in page with no
-- session AND somebody already inside. Those are usually two different
-- carriers here -- `landing_payload` for the first, a table policy for
-- the second -- and using both would be the same sentence stored once
-- and read two ways, which is how the two come to disagree.
--
-- So: `maintenance_notice()`, granted to `anon` and `authenticated`,
-- returning null when there is nothing to say. What it exposes is that
-- the platform is about to be worked on, which is the one fact a
-- maintenance banner exists to publish.
--
-- ---------------------------------------------------------------------
-- Blocking writes: `can_write` and `can_admin`, and nothing else
--
-- Those two are this schema's own vocabulary for "may change things" --
-- `can_write` is documented as "anyone who may create or edit
-- operational documents" and `can_admin` is the settings above it. Every
-- policy that guards a write already asks one of them, so gating them
-- gates the writes, in two places rather than in four hundred.
--
-- `is_platform_admin` is deliberately NOT gated. The operator who
-- turned maintenance on has to be able to turn it off, and
-- `platform_settings` is guarded by that function alone -- so the
-- switch can always be reached, which is the property that stops this
-- being a way to brick the platform with one click.
--
-- Reads are untouched. Somebody who was looking at an invoice when the
-- shutter came down goes on looking at it.
--
-- ---------------------------------------------------------------------
-- What it costs on the hot path
--
-- `can_write` is called per row by every policy that guards a write,
-- so this adds a lookup to a hot function. `docs/performance.md`
-- measured the shape already: `org_members` takes 92,588 sequential
-- scans against 10 live rows and 8 kB, and its conclusion was that a
-- scan of a table that fits in one page is not what is slow here.
-- `platform_settings` is ten rows. The lookup is the same shape as the
-- one already in `org_role`, which is called from the same place.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Is the shutter down
--
-- Missing reads as open, for `0563`'s reason and more sharply: a
-- deleted row that stopped every write in the product would be the
-- failure of a lookup wearing the face of a decision, and this one
-- fails closed across the whole platform.
-- ---------------------------------------------------------------------
create or replace function app.in_maintenance()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select (value ->> 'enabled')::boolean
       from public.platform_settings
      where key = 'maintenance_mode'),
    false);
$$;

comment on function app.in_maintenance() is
  'Whether the platform is closed for work. Missing reads as open: a '
  'lookup that failed must not stop every write in the product. 0564.';

revoke all on function app.in_maintenance() from public, anon;
grant execute on function app.in_maintenance()
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- What it says, and to whom
--
-- Null when there is nothing to say, so a client cannot draw an empty
-- banner from a field that is always populated -- the same shape
-- `0563` gave the closed-registration notice.
--
-- Granted to `anon`: the person most in need of this is the one
-- standing at the sign-in page wondering why their password stopped
-- working. `supabase/tests/statutory.sql` holds the list of what a
-- stranger may call, and this is on it.
-- ---------------------------------------------------------------------
create or replace function public.maintenance_notice()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
    when not app.in_maintenance() then null
    else jsonb_build_object(
      'enabled', true,
      'message', coalesce(
        nullif(btrim((select value ->> 'message'
                        from public.platform_settings
                       where key = 'maintenance_mode')), ''),
        'iAkauntan is being worked on. You can still look at your '
        'books; saving changes is switched off until we are finished.'))
  end;
$$;

comment on function public.maintenance_notice() is
  'The maintenance banner, or null when there is nothing to say. Anon '
  'too: the person who most needs it is the one at the sign-in page. '
  '0564.';

revoke all on function public.maintenance_notice() from public;
grant execute on function public.maintenance_notice() to anon, authenticated;

-- ---------------------------------------------------------------------
-- And the two guards
--
-- `0018`'s definitions with one condition in front of each. The roles
-- they name are unchanged; what changes is that neither answers yes
-- while the platform is closed for work.
--
-- ---------------------------------------------------------------------
-- The grants below are not decoration, and this cost a red run
--
-- `0165` installed an event trigger that strips EXECUTE from PUBLIC and
-- `anon` on every CREATE FUNCTION in `app` and `public` -- and a
-- REPLACE fires it too. Both of these predate `0165` and had never been
-- granted to anything: they were reachable because Postgres grants
-- EXECUTE to PUBLIC on a new function and nobody had taken it away.
--
-- So replacing them took the only grant they had. Every policy in the
-- schema that guards a write calls one of them as `authenticated`, and
-- the whole suite went red with "permission denied for function
-- can_admin" -- which is `0165` working exactly as written, on two
-- functions that were relying on the thing it exists to remove.
--
-- The next person restating a helper this old should expect the same.
-- ---------------------------------------------------------------------
create or replace function app.can_write(p_org_id uuid)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select not app.in_maintenance()
     and app.has_org_role(p_org_id,
           array['owner','admin','accountant','accounts_clerk','sales',
                 'purchaser']::app.member_role[]);
$$;

comment on function app.can_write(uuid) is
  'Anyone who may create or edit operational documents, and nobody at '
  'all while the platform is closed for work. 0564.';

grant execute on function app.can_write(uuid) to authenticated, service_role;

create or replace function app.can_admin(p_org_id uuid)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select not app.in_maintenance()
     and app.has_org_role(p_org_id,
           array['owner','admin']::app.member_role[]);
$$;

comment on function app.can_admin(uuid) is
  'A company''s owner or administrator, and nobody at all while the '
  'platform is closed for work. Platform staff are deliberately not '
  'gated: somebody has to be able to turn it back off. 0564.';

grant execute on function app.can_admin(uuid) to authenticated, service_role;

-- Room for the operator's own words, if the seeded row has none.
update public.platform_settings
   set value = value || jsonb_build_object('message', '')
 where key = 'maintenance_mode'
   and jsonb_typeof(value) = 'object'
   and not (value ? 'message');
