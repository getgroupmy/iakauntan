-- =====================================================================
-- iAkauntan :: 0696 one transfer between matters, not two
--
-- `0690` added `transfer_between_matters(uuid, uuid, numeric, text,
-- date, text)` to a database that had carried
-- `transfer_between_matters(uuid, uuid, numeric, date, text)` since
-- `0358`. Different signatures, so `create or replace` did not replace
-- anything: it made a second function beside the first.
--
-- This reverts `0690` entirely. The function it added is the only thing
-- it added.
--
-- ---------------------------------------------------------------------
-- What that broke, and why nothing noticed
--
-- Two overloads are harmless until somebody calls with NAMED arguments,
-- and then:
--
--     select transfer_between_matters(
--       p_from => ..., p_to => ..., p_amount => ...,
--       p_date => ..., p_description => ...)
--     ERROR:  function ... is not unique
--
-- because `p_reference` on the newer one has a default, so five named
-- arguments fit both. PostgREST calls every function by name, so the
-- matter screen's transfer stopped working the moment `0690` applied.
--
-- `matter_transfer.sql` went on passing. It calls POSITIONALLY --
-- `transfer_between_matters(v_sale, v_lease, 3000)` -- and Postgres
-- resolves that to `0358`'s without complaint. So the assertions
-- covering this feature were all green while the feature was dead in
-- every client, which is the exact shape `docs/widget-tests.md` warns
-- about in Dart and had not been written down for SQL.
--
-- The assertion added alongside this calls it the way the APP calls it.
-- `scripts/check_ambiguous_overloads.py` is the general answer.
--
-- ---------------------------------------------------------------------
-- And `0358` is the one to keep, on the merits
--
-- Not merely because it came first. `0690`'s header claimed
-- `transfer_in` and `transfer_out` had never been written, which was
-- simply wrong -- `0358` wrote both, and its own header opens by saying
-- the enum had carried them since `0021`.
--
-- The substantive difference is the one that matters:
--
--   * `0358` REFUSES A TRANSFER BETWEEN TWO CLIENTS, and names both so
--     somebody who picked the wrong row can see which. The Legal
--     Profession (Accounts) Rules turn on money held for one client
--     being that client's; between two matters of one client this is
--     bookkeeping, and between two clients it is a breach -- and the
--     ordinary way a breach happens is a mistyped matter number with
--     both matters open in the same list.
--   * `0690` allowed it, on the reasoning that `app.assert_client_funds`
--     would catch an overdraw. It would. An overdraw is not the
--     objection: a transfer between two clients that leaves both in
--     credit breaks the rule and trips no trigger.
--
-- So the newer one is not a better version of the older. It is a
-- looser one.
-- =====================================================================

drop function if exists public.transfer_between_matters(
  uuid, uuid, numeric, text, date, text);

-- Left where anybody looking for the removed one will find it.
comment on function public.transfer_between_matters(
  uuid, uuid, numeric, date, text) is
  'Moves client money between two matters OF THE SAME CLIENT, as two '
  'legs written together. Refuses two different clients by naming '
  'both, refuses a matter that does not hold the amount, and refuses '
  'the same matter twice. The ledger finishes where it started: '
  'nothing leaves the bank, and what moves is which matter the firm '
  'holds it against. 0358, and the only one -- 0690 added a second '
  'signature beside this and 0696 removed it.';
