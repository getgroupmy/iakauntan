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

  -- And the two this deliberately did not grant are deliberately still
  -- not granted, which is the half a later reader would otherwise have
  -- to take on trust.
  if has_function_privilege('service_role',
       'public.set_sst_registration(uuid, boolean, date, text, text)',
       'execute') then
    raise exception
      'set_sst_registration is reachable by the edge role. 0621 says it '
      'is a false positive of the sweep, not a call.';
  end if;
end
$do$;
