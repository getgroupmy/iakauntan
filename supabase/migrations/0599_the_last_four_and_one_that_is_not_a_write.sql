-- =====================================================================
-- iAkauntan :: 0599 the last four, and one of them is not a write
--
-- The thirteenth and last slice of the undocumented writes. `0569`
-- started at 278; this takes the budget to zero.
--
-- Three of the four write. The fourth,
-- `org_payment_gateway_status`, has been counted as a write for its
-- whole life and has never written anything: it is a plpgsql function
-- that reads four columns and returns them, and plpgsql's DEFAULT
-- VOLATILITY IS VOLATILE. Postgres assumes the worst unless told
-- otherwise, and nobody told it.
--
-- So the honest fix there is not a paragraph describing a write that
-- does not happen. It is `alter function ... stable`, which is what the
-- function has always been, plus a description of the read -- because
-- it IS published surface and a caller still needs to know what comes
-- back.
--
-- ---------------------------------------------------------------------
-- The pair this makes with `check_stable_writers.py`
--
-- That check exists for the mistake in the other direction: a function
-- declared STABLE that writes, which PostgREST runs in a read-only
-- transaction and which fails with 25006 at the door while passing
-- every test run from psql. `public.platform_feedback` did exactly
-- that for the life of the platform console.
--
-- This is the same mislabelling with the sign flipped, and it is
-- cheaper: a read declared VOLATILE costs a planner optimisation and a
-- place in a list of writes. Nothing breaks. Which is why it survived
-- six hundred migrations.
--
-- It is not one function. On the applied schema, 37 functions in
-- `public` that a signed-in user can reach are declared VOLATILE and
-- contain no writing verb anywhere in their body:
--
--   select p.proname
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.prokind = 'f'
--      and p.provolatile = 'v'
--      and has_function_privilege('authenticated', p.oid, 'execute')
--      and not exists (select 1 from pg_depend dp
--                       where dp.objid = p.oid and dp.deptype = 'e')
--      and p.prosrc !~* '\m(insert|update|delete|truncate|nextval|setval
--                           |create|drop|alter|grant|revoke)\M';
--
-- This migration fixes ONE of them -- the one the counter was looking
-- at, read line by line first. The other 36 are deliberately left,
-- because that query is generous in the dangerous direction: a function
-- whose own body is clean but which CALLS a writer reads as a pure read
-- here, and marking that one STABLE is how you get the 25006. They are
-- findable with the query above and each needs its callees followed
-- before it is touched. A sweep is a separate piece of work, not a
-- footnote to this one.
--
-- ---------------------------------------------------------------------
-- What the three writes are actually about
--
-- `dispose_fixed_asset` is where the depreciation nobody has posted yet
-- gets posted. An asset depreciates every day and the schedule only
-- runs monthly, so on the day it leaves there is almost always a
-- catch-up owing. It goes into the SAME journal as the disposal, and it
-- is also filed as a `depreciation_runs` row pointing at that journal,
-- so the asset's history is whole. If there is a catch-up and no 6400
-- in the chart the whole thing refuses -- because the alternative is
-- relieving that amount off the balance sheet without it ever reaching
-- the profit and loss, which is a loss that silently never happened.
--
-- What it does NOT do is touch the bank feed. Proceeds debit the bank
-- account's GL account, and no `bank_transactions` row is written, so
-- the money is in the ledger and absent from the reconciliation until
-- the real credit arrives on the statement -- which is correct, and is
-- not what somebody looking for it will assume.
--
-- `update_recurring_template` re-photographs a schedule off a document
-- raised today, and the reason that matters is `app.snapshot_document`:
-- its header is a WHITELIST. A column added to `sales_documents` after
-- a snapshot was taken is not in that snapshot and is not in anything
-- raised from it. `0416` and `0441` are both that bug -- a service
-- charge, then the tax on it -- each billing short on every schedule
-- made before the column existed. Re-pointing an old schedule at a
-- current document is the repair.
--
-- It also quietly moves the customer. `contact_id` is overwritten from
-- the source document, so copying from an invoice raised for somebody
-- else re-aims the schedule at them.
--
-- `org_save_login_page` writes the only text on this platform that a
-- stranger reads BEFORE SIGNING IN. The table is closed to `anon`, but
-- `workspace_by_host` is not, and it publishes `title` and `body` to
-- anyone who names the company's web address. Whatever is typed here is
-- public.
-- =====================================================================

comment on function public.dispose_fixed_asset(uuid, date, numeric, uuid) is
  'Takes a fixed asset off the books on `p_date` and returns the id of '
  'the journal entry it posted. The entry carries TWO things, not one: '
  'the disposal itself -- accumulated depreciation and any proceeds '
  'debited, the asset relieved at cost, the difference to gain or loss '
  'through `app.disposal_account` -- and THE DEPRECIATION NOBODY HAS '
  'POSTED YET. An asset depreciates daily and the schedule runs '
  'monthly, so on the day it leaves there is almost always a catch-up '
  'owing; it is charged to 6400 here, in this same journal, and filed '
  'as a `depreciation_runs` row pointing at it so the asset''s history '
  'is whole. If there is a catch-up and the chart has no 6400 THE '
  'WHOLE DISPOSAL REFUSES rather than relieving that amount off the '
  'balance sheet without it ever reaching the profit and loss. '
  'Accounts come off the asset where it names them, else 1510, 1590 '
  'and 6400 from the seeded chart (1510 and not 1500, which is a '
  'header nothing may post to). `p_proceeds` debits `p_bank_account_id`'
  '''s GL account, or 1120 if none is named -- it is booked as CASH, '
  'never as a receivable, so a disposal on credit puts money in the '
  'ledger that has not arrived. NO `bank_transactions` ROW IS WRITTEN: '
  'the proceeds are invisible to bank reconciliation until the real '
  'credit lands on the statement. Accumulated depreciation is never '
  'reduced -- the greater of the computed and the stored figure is '
  'used. Refuses a disposal dated before acquisition, and refuses an '
  'asset already disposed of, so it cannot be run twice. Needs posting '
  'rights.';

comment on function public.update_recurring_template(uuid, uuid) is
  'Re-photographs a recurring schedule''s template from an existing '
  'document, which must be an invoice for a sales schedule or a bill '
  'for a purchase one, not deleted, AND BELONGING TO THE SAME COMPANY '
  '-- copying across organizations would put one company''s prices '
  'into another''s billing. The snapshot is taken once, here: later '
  'edits to that document do not reach the schedule. This is also the '
  'repair for a schedule that bills short, because '
  '`app.snapshot_document` whitelists the header columns it copies, so '
  'a column added to the document table after the snapshot was taken '
  'is missing from everything raised off it -- `0416` (service charge) '
  'and `0441` (the tax on it) were both that, and re-pointing the '
  'schedule at a document raised today picks them up. IT ALSO MOVES '
  'THE CUSTOMER: `contact_id` is overwritten from the source document, '
  'so copying from an invoice raised for somebody else re-aims every '
  'future run at them. Nothing else about the schedule changes -- '
  'frequency, next run date and occurrence count are left alone. Needs '
  'posting rights.';

comment on function public.org_save_login_page(uuid, text, text) is
  'Writes the heading and body shown on this company''s own sign-in '
  'page, creating the row on first save. WHAT IS TYPED HERE IS PUBLIC: '
  'the table is closed to `anon`, but `workspace_by_host` is not, and '
  'it hands `title` and `body` to anyone who names the company''s web '
  'address, before anybody has signed in to anything. Both arguments '
  'distinguish absent from empty -- null leaves the current wording '
  'alone, and a blank or whitespace-only string clears it back to null,'
  ' which the screen reads as "use the platform''s wording". Owner or '
  'administrator only, and refuses unless the company has the '
  '`workspace_address` module, because without its own web address '
  'there is no sign-in page of its own to write on. Records who saved '
  'it and when.';

-- ---------------------------------------------------------------------
-- The one that is not a write.
--
-- `alter function` rather than `create or replace`, so the body stays
-- exactly as applied and this migration cannot become a place where it
-- silently changed.
alter function public.org_payment_gateway_status(uuid) stable;

comment on function public.org_payment_gateway_status(uuid) is
  'Lists this company''s payment gateway set-up, one row per gateway '
  'and mode, so an administrator can see what is configured without '
  'being shown the credentials. NEVER RETURNS A KEY: `has_api_key` and '
  '`has_signature_key` are booleans saying whether one is stored. '
  '`collection_ref` IS returned, deliberately -- a collection id is '
  'useless to anybody without the key beside it, and somebody checking '
  'their set-up needs to see which pot they pointed payments at. '
  'Administrator only. Reads only; declared STABLE since `0599`, '
  'having been VOLATILE by plpgsql''s default since it was written.';

-- `0165` strips EXECUTE from PUBLIC and `anon` on create-or-replace in
-- these schemas. `alter function` is a different command tag and this
-- one only changes volatility, but the grant is restated rather than
-- assumed: the cost of a redundant grant is nothing and the cost of a
-- missing one is a screen that 403s.
grant execute on function public.org_payment_gateway_status(uuid)
  to authenticated;
