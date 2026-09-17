-- =====================================================================
-- iAkauntan :: the grant that was never written
--
-- ---------------------------------------------------------------------
-- First, the correction. `0617` is wrong.
--
-- It says -- quoting `0165`, which says it was verified rather than
-- assumed -- that Supabase ships
--
--     alter default privileges in schema public grant all on functions
--     to anon, authenticated, service_role
--
-- so that a new `public` function arrives executable by every signed-in
-- user. On the strength of that, 0617 taught `_local_stack.sql` to model
-- the same default, and concluded that the thirteen functions which
-- appeared reachable by nobody were an artefact of the stub.
--
-- **CI refused it.** `supabase start` brings up the real stack, and
-- there the default ACL for functions in `public` is
--
--     {postgres=X/postgres}
--
-- -- postgres and nobody else. There is no grant to `authenticated` and
-- none to `service_role`. The stub, which had no row at all, reached the
-- same end state by a different route: PostgreSQL's built-in PUBLIC
-- default, which `0165`'s event trigger then revokes. Both give a new
-- function `{postgres=X}`, which is why every local run agreed with CI
-- until 0617 taught the stub to disagree with both.
--
-- 0165's sentence is most likely a misreading of its own evidence: the
-- nine functions it found still reachable by `anon` are the nine that
-- carry an explicit `grant execute ... to anon` in their own migrations.
-- An explicit grant explains the observation without a default
-- privilege, and there is no default privilege.
--
-- So the rule is the strict one: **a new `public` function is callable
-- by postgres and by nobody else until a migration says otherwise.**
-- `_local_stack.sql` is back to reproducing that, and 0617's line has
-- been taken out of it.
--
-- ---------------------------------------------------------------------
-- Which makes the thirteen real
--
-- They are not an artefact. Ten of them have a caller that cannot reach
-- them, and the failure is silent in every case: PostgREST answers
-- 42501, the edge function catches it, and the feature simply never
-- happens.
--
--   * **Push notifications have never been delivered.** `send-push`
--     reads its recipients with `admin.rpc("push_targets")` and retires
--     dead tokens with `forget_device_token`. Neither is granted to the
--     service role. `0141` and `0143` both revoked and neither granted.
--
--   * **A customer paying an invoice they were sent has never worked.**
--     `pay-invoice` calls `begin_shared_payment` and
--     `pay-invoice-callback` calls `settle_shared_payment`. `0413` and
--     `0491` revoked; neither granted.
--
--   * **A punch from a clock on the wall has never landed.** `0612`,
--     mine, two days old: `record_terminal_punch` and
--     `terminal_secret_matches` are called by `punch` and granted to
--     nobody. The migration's own comment says "service role only" and
--     the revoke is all it wrote.
--
--   * **The consolidated e-Invoice scheduler cannot file.** `0616`,
--     mine, yesterday: `scheduler_prepare_consolidated_einvoice` and
--     `einvoice_consolidations_due`, same mistake, copied from the same
--     pattern.
--
--   * **Two RPCs the app itself calls are refused.**
--     `declarable_reliefs` (`0408`) is the list of reliefs an employee
--     may put on a TP1, and `set_org_payment_settlement` (`0413`) says
--     where a gateway's takings land. Both are called from
--     `repository.dart` by a signed-in user and granted to nobody.
--
-- The ones that DO work are the ones that wrote the grant:
-- `ocr_finish`, `ingest_exchange_rates`, `receive_email` and
-- `settle_gateway_payment` all carry `grant execute ... to
-- service_role` in their own migrations, and all four work in
-- production. That is the whole difference, and it is the evidence that
-- this reading is the right one.
--
-- ---------------------------------------------------------------------
-- Three are unreachable on purpose and stay that way
--
-- `chat_expire_calls` and `prune_device_tokens` are called by
-- `app.run_daily_jobs`, inside the database, where the caller is the job
-- owner and PostgREST is not involved. `ticket_sla_sweep` is called
-- only by `app.demo_tickets_sinar`. Granting them would widen the
-- client surface for nothing.
--
-- `function_grants.sql` names all three, so the next function that
-- becomes unreachable is a failure rather than a fourth quiet one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The service role's own entry points
--
-- Each of these is already revoked from `public`, `anon` and
-- `authenticated` by the migration that created it, and each is called
-- by an edge function holding the service key. The grant is the half
-- that was never written.
-- ---------------------------------------------------------------------
grant execute on function public.push_targets(uuid, uuid) to service_role;
grant execute on function public.forget_device_token(text) to service_role;
grant execute on function public.begin_shared_payment(text, text, text, text)
  to service_role;
grant execute on function public.settle_shared_payment(
  text, text, boolean, numeric, jsonb) to service_role;
grant execute on function public.record_terminal_punch(
  uuid, text, timestamptz, text) to service_role;
grant execute on function public.terminal_secret_matches(uuid, text)
  to service_role;
grant execute on function public.scheduler_prepare_consolidated_einvoice(uuid)
  to service_role;
grant execute on function public.einvoice_consolidations_due(integer)
  to service_role;

-- ---------------------------------------------------------------------
-- The two the app calls
--
-- Both are SECURITY DEFINER and both guard themselves --
-- `set_org_payment_settlement` on `app.can_admin`, and
-- `declarable_reliefs` reads nothing tenant-shaped at all: it is
-- LHDN's relief list for a tax year, the same for everybody, and the
-- schedule it reads is the one in force. So the grant hands a
-- signed-in user exactly what the screen already tried to ask for.
-- ---------------------------------------------------------------------
grant execute on function public.declarable_reliefs(integer) to authenticated;
grant execute on function public.set_org_payment_settlement(
  uuid, text, text, uuid, text) to authenticated;
