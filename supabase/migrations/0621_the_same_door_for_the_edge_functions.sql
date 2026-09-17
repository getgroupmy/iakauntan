-- =====================================================================
-- iAkauntan :: 0621 the same door, for the edge functions
--
-- `0620` closed the hole for `authenticated`: nine functions that a
-- trigger, a unique index or a check constraint calls on somebody's
-- behalf, none of them reachable by the role doing the write. Three
-- screens were broken by it.
--
-- The same walk asked about `service_role` finds four more, and this is
-- the honest part: **none of them is reachable today.** The edge
-- functions write twenty-seven tables and not one of them is
-- `sales_document_lines`, `purchase_document_lines`, `time_entries`, or
-- anything `refuse_unapproved_posting` sits on. Nothing is broken. The
-- two tables the edge functions DO write that carry this shape --
-- `contacts` through `identifying_number`'s index, and
-- `einvoice_documents` through its version check -- were granted to
-- `service_role` by 0620 already, which is why `myinvois` and
-- `ssm-search` work.
--
-- So this is closing a door before somebody walks into it, and it is
-- worth doing for one reason: the failure is silent until it is a
-- production error, the next edge function to insert a document line is
-- an ordinary thing to write, and whoever writes it will have no reason
-- to suspect that `app.uom_qty` is the problem. The four are internal
-- derivations -- a unit conversion, a billing rate, whether an approval
-- is required, whether one was given -- and nothing about them is worth
-- withholding from the role that already bypasses row level security.
--
-- ---------------------------------------------------------------------
-- Two the walk named and this does NOT grant
--
-- `public.set_sst_registration` and `public.declarable_reliefs` are
-- matched by the same sweep and are false positives: each appears in a
-- trigger function only inside the text of a `raise exception`.
--
--   'SST registration is not a field to set. ... Use
--    set_sst_registration().'
--   '... the ones public.declarable_reliefs(%) lists.'
--
-- Naming the right function in a refusal is exactly what a good error
-- message does, and granting a privileged write RPC to the edge role on
-- the strength of one would be the sweep making policy. The test excuses
-- both by name AND checks the excuse: a name that appears anywhere
-- outside a quoted literal is not excused, so the day one of these is
-- really called the exception stops applying.
--
-- ---------------------------------------------------------------------
-- An assertion this file used to carry, and why it is gone
--
-- It also asserted the other half: that `set_sst_registration` is still
-- NOT reachable by `service_role`, so a later reader would not have to
-- take the paragraph above on trust. On the machine this was written on
-- that is true. **On the hosted project it is false**, and the
-- assertion failed the apply four times before anybody could see why.
--
-- `0145` grants that function to `authenticated` and to nobody else,
-- and `0181` replaces it and grants nothing. No migration in this
-- repository gives it to `service_role`. The hosted project has it
-- anyway, which means a `public` function there arrives with a grant
-- these migrations did not write -- Supabase's own default privileges,
-- of which `0165` revokes PUBLIC and anon and leaves whatever else is
-- there.
--
-- That drift is worth knowing and is NOT fixed here, because `c2d2d15`
-- is the record of fixing exactly this on a guess: a function default
-- privilege added to `_local_stack.sql` on the strength of 0165's
-- comment made this machine more generous than the real one and was
-- reverted. Measuring it needs a look at the hosted project, which this
-- machine cannot reach.
--
-- What the failure actually taught is smaller and applies to every
-- migration: **a migration must not assert what it cannot check.** The
-- four grants below are checked, because this file makes them. The
-- absence of a fifth was a claim about somebody else's database.
-- =====================================================================

grant execute on function app.uom_qty(uuid, numeric, text) to service_role;
grant execute on function app.billing_rate_for(uuid, uuid, uuid, uuid, date)
  to service_role;
grant execute on function app.approval_required(
  uuid, app.approval_entity, text, numeric) to service_role;
grant execute on function app.is_approved(uuid, app.approval_entity, uuid)
  to service_role;

do $do$
begin
  if not has_function_privilege('service_role',
       'app.uom_qty(uuid, numeric, text)', 'execute')
     or not has_function_privilege('service_role',
       'app.approval_required(uuid, app.approval_entity, text, numeric)',
       'execute') then
    raise exception
      'The edge role still cannot execute what a trigger will call on '
      'its behalf.';
  end if;

  -- What this file does NOT assert, and the header says why: that
  -- `set_sst_registration` is still out of the edge role's reach. It is
  -- here, it is not on the hosted project, and no migration in this
  -- repository put it there.
end
$do$;
